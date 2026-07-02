defmodule BBMCUHub.Contract.PortIndex do
  @moduledoc """
  Runtime lookup from the wire identity `(node, port_id)` back to its value type
  and human port name (§03/§07).

  The decode seam (`BBMCUHub.Wire.Codec`) needs the value `type` to parse a
  payload, and the registry/views want the symbolic `port` name. Both come from
  the same IR the generator renders, built once at boot from the contracts +
  topology and cached in `:persistent_term` (read-mostly, never on the hot path
  after warm-up).

  An unknown `(node, port_id)` returns `:error` — the codec drops the frame and
  counts it (`decode_fail`), exactly like an unknown port id in the design (§07).
  """

  alias BBMCUHub.Contract
  alias BBMCUHub.Robot.Info

  @key {__MODULE__, :index}

  @type entry :: %{
          hub: atom(),
          port: atom(),
          type: atom(),
          dir: Contract.dir(),
          stamped: boolean()
        }

  @doc """
  Build (or rebuild) the index from a robot's contracts + topology and cache it.

  The robot is ALWAYS explicit (generation/index is explicit-robot,
  there is no library default). Call once at boot — the generic `BBMCUHub.Host`
  launcher does this for the consumer's robot; tests build for their robot in
  setup. Returns the index map.
  """
  @spec build(module()) :: %{{0..255, 0..255} => entry()}
  def build(robot) do
    ir = Info.ir(robot)

    index =
      Map.new(ir, fn row ->
        {{row.node, row.port_id},
         %{hub: row.hub, port: row.port, type: row.type, dir: row.dir, stamped: row.stamped}}
      end)

    :persistent_term.put(@key, index)
    index
  end

  @doc """
  The cached index. Raises if it was never built — there is no robot default to
  fall back to, so a caller must `build/1` for its robot first (the
  Host launcher and tests do).
  """
  @spec index() :: %{{0..255, 0..255} => entry()}
  def index do
    case :persistent_term.get(@key, nil) do
      nil ->
        raise "PortIndex not built — call BBMCUHub.Contract.PortIndex.build(robot) " <>
                "for the active robot first (the Host launcher and test setups do)"

      idx ->
        idx
    end
  end

  @doc "The value type for a wire `(node, port_id)`, or `:error` if unknown."
  @spec type_for(0..255, 0..255) :: {:ok, atom()} | :error
  def type_for(node, port_id) do
    case Map.fetch(index(), {node, port_id}) do
      {:ok, %{type: type}} -> {:ok, type}
      :error -> :error
    end
  end

  @doc "Whether a wire `(node, port_id)` carries `t_dev` (§04). False if unknown."
  @spec stamped?(0..255, 0..255) :: boolean()
  def stamped?(node, port_id) do
    case Map.fetch(index(), {node, port_id}) do
      {:ok, %{stamped: s}} -> s
      :error -> false
    end
  end

  @doc "The full entry for a wire `(node, port_id)`, or `:error` if unknown."
  @spec lookup(0..255, 0..255) :: {:ok, entry()} | :error
  def lookup(node, port_id), do: Map.fetch(index(), {node, port_id})

  @doc "Resolve a symbolic `(hub, port)` to its wire `(node, port_id)`."
  @spec resolve(atom(), atom()) :: {:ok, {0..255, 0..255}} | :error
  def resolve(hub, port) do
    index()
    |> Enum.find(fn {_k, e} -> e.hub == hub and e.port == port end)
    |> case do
      {key, _entry} -> {:ok, key}
      nil -> :error
    end
  end
end
