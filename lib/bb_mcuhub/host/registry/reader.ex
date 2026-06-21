defmodule BBMcuhub.Host.Registry.Reader do
  @moduledoc """
  A **read-only registry capability** for the observability plane (ADR-0004).

  An observer is a PURE READER (CONTEXT.md · *Observer*): it samples a slot's
  latest value and never writes one. The registry is `:public` ETS, so "exactly
  one writer per slot" (§07) is otherwise just a comment. This struct closes that
  gap *structurally*: a `Reader` exposes only `get/3` and `dump/1` — there is no
  `put` — so an observer handed a `Reader` instead of `BBMcuhub.Host.NodeRegistry`
  directly **cannot represent** a slot write. "An observer writes a slot" is made
  unrepresentable, not merely discouraged (ADR-0004, the protecting invariant).

  The default reader (`default/0`) delegates the two read calls to the real
  `NodeRegistry`. A test injects a fake `Reader` (any module exposing the same
  `get/3` and `dump/1` shape) to feed an observer scripted slot rows without ETS —
  see the observer tests.

  This is a capability, not a process: it holds the read functions, so the
  observer keeps one in its state and never names `NodeRegistry` in observer code.
  """

  alias BBMcuhub.Host.NodeRegistry

  @typedoc "A `(node, port_id)` slot row, or `nil` if the slot was never written."
  @type row :: NodeRegistry.row() | nil

  @typedoc """
  The read-only registry capability: two read functions and nothing else. No
  `put` field exists, so an observer holding this cannot write a slot.
  """
  @type t :: %__MODULE__{
          get: (NodeRegistry.node_id(), NodeRegistry.port_id() -> row()),
          dump: (-> %{{NodeRegistry.node_id(), NodeRegistry.port_id()} => NodeRegistry.row()})
        }

  @enforce_keys [:get, :dump]
  defstruct [:get, :dump]

  @doc """
  The default reader: the read-only half of the real `NodeRegistry`.

  `get`/`dump` delegate to `NodeRegistry.get/2` and `NodeRegistry.dump/0`. There
  is deliberately no `put` — that write lives on `NodeRegistry` and is simply not
  reachable through this capability.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      get: &NodeRegistry.get/2,
      dump: &NodeRegistry.dump/0
    }
  end

  @doc """
  Read a `(node, port_id)` slot row through the capability, or `nil` if the slot
  has never been written (the reader is *born stale* w.r.t. it, §04).
  """
  @spec get(t(), NodeRegistry.node_id(), NodeRegistry.port_id()) :: row()
  def get(%__MODULE__{get: get}, node, port_id), do: get.(node, port_id)

  @doc "Every row through the capability, keyed by `{node, port_id}`. For debugging/telemetry."
  @spec dump(t()) :: %{{NodeRegistry.node_id(), NodeRegistry.port_id()} => NodeRegistry.row()}
  def dump(%__MODULE__{dump: dump}), do: dump.()
end
