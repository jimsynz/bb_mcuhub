defmodule BBMCUHub.Host.Registry.Writer do
  @moduledoc """
  A **slot-scoped write capability** — the write-side mirror of
  `BBMCUHub.Host.Registry.Reader` (candidate 5 of the architecture review).

  "Exactly one writer per slot" (§07) is the precondition that makes `seq`-as-trust
  sound: freshness and the on-chip floor both arm on "did `seq` advance?", so a
  *second* writer of a slot could mint a bogus advance and energise a motor with a
  command the controller never issued. That rule used to be only a docstring on a
  `:public` ETS table.

  A `Writer` closes the **accidental cross-slot write through the API** path
  structurally: it is bound to ONE `(node, port_id)` at mint time and its `put/4`
  takes no node/port argument, so "write some OTHER slot" is *unrepresentable* — a
  holder can only ever write the slot it was minted for. It is minted by
  `BBMCUHub.Host.NodeRegistry.writer!/2`, which also enforces **uniqueness**: a
  second live mint for the same slot raises (`BBMCUHub.Host.Registry.Writer.Taken`),
  so two writers of one slot cannot coexist.

  ## What this does and does not guarantee

  It makes the *API* single-writer-safe and unique. It does NOT seal the raw
  `:ets.insert` escape hatch — the table stays `:public` so the views read+write
  without a GenServer round-trip on the control hot path (an accepted tradeoff:
  the capability raises the bar against honest mistakes, not against code that
  deliberately bypasses the registry). See CONTEXT.md · *Slot*.

  Like `Reader`, this is a capability (a value the writer keeps in its state), not
  a process: the sole writer mints one at init and never names `NodeRegistry.put`
  directly.
  """

  alias BBMCUHub.Host.NodeRegistry

  defmodule Taken do
    @moduledoc "Raised when a slot already has a live writer (the uniqueness guard)."
    defexception [:message]
  end

  @typedoc "A write capability scoped to a single `(node, port_id)` slot."
  @type t :: %__MODULE__{
          node: NodeRegistry.node_id(),
          port_id: NodeRegistry.port_id(),
          put: (term(), NodeRegistry.seq(), NodeRegistry.t_dev() -> :ok)
        }

  @enforce_keys [:node, :port_id, :put]
  defstruct [:node, :port_id, :put]

  @doc false
  # Built ONLY by NodeRegistry.writer!/2 (which holds the uniqueness registry).
  # The put fn closes over this slot's ids, so the capability cannot write another.
  @spec new(NodeRegistry.node_id(), NodeRegistry.port_id()) :: t()
  def new(node, port_id) do
    %__MODULE__{
      node: node,
      port_id: port_id,
      put: fn value, seq, t_dev -> NodeRegistry.put(node, port_id, value, seq, t_dev) end
    }
  end

  @doc """
  Write this writer's OWN slot. There is no node/port argument — the slot is fixed
  at mint, so a holder can never write a slot it does not own (§04/§07).
  """
  @spec put(t(), term(), NodeRegistry.seq(), NodeRegistry.t_dev()) :: :ok
  def put(%__MODULE__{put: put}, value, seq, t_dev), do: put.(value, seq, t_dev)

  @doc "The `(node, port_id)` slot this writer is bound to."
  @spec slot(t()) :: {NodeRegistry.node_id(), NodeRegistry.port_id()}
  def slot(%__MODULE__{node: node, port_id: port_id}), do: {node, port_id}
end
