defmodule BBMcuhub.Contract do
  @moduledoc """
  The wire contract (§06): the single in-memory model the generator renders into
  four artifacts (Elixir codec, C header, per-hub schedule, parity vectors).

  A **hub contract** is small data describing one hub — its ports, each port's
  value `type`, its `rate` (a single nominal Hz number), its `dir` (`:in`/`:out`),
  plus `safe_action` and `fresh_for` for actuator command ports. A **topology**
  maps each hub to its flat, whole-tree-unique `NODE` id (§03).

  This module owns the header layout that frames every value and the reserved-id
  facts, and it builds the per-port IR rows the generator consumes.

  ## `t_dev` is opt-in per port (§04)

  The producer's `t_dev` (8 bytes) is the largest field, and only same-device
  fusion/replay uses it — so it is carried only on the ports that declare
  `t_dev: true`. Command and status ports omit it and stay small. A port's header
  is therefore one of two shapes, chosen by its `t_dev` flag; the decoder learns
  the shape from the same per-`(node, port)` index it uses to find the value type
  (`PortIndex`), so an unstamped frame is never misread as a stamped one.
  """

  alias BBMcuhub.Contract.Layouts

  # The header before the payload (§03). LEN precedes it and CRC follows; both are
  # added by the frame codec, not part of the CRC-covered "body header". The CRC
  # covers NODE..PAYLOAD, so the body the codec hashes starts at NODE.
  @base_header [node: :u8, port: :u8, seq: :u16]
  @t_dev_field {:t_dev, :u64}

  @reserved_node_broadcast 0x00
  @host_logical_id 0

  @type hub_name :: atom()
  @type port_name :: atom()
  @type dir :: :in | :out
  @type hub_contract :: %{
          required(:hub) => hub_name(),
          required(:ports) => %{port_name() => port_spec()},
          optional(:sample) => mfa_ref(),
          optional(:step) => mfa_ref()
        }
  @type port_spec :: %{
          required(:dir) => dir(),
          required(:type) => atom(),
          required(:rate) => pos_integer(),
          optional(:t_dev) => boolean(),
          optional(:fresh_for) => pos_integer(),
          optional(:safe_action) => atom()
        }
  @type mfa_ref :: {module(), atom()}

  @type ir_row :: %{
          hub: hub_name(),
          node: 0..255,
          port: port_name(),
          port_id: 0..255,
          dir: dir(),
          type: atom(),
          layout: Layouts.layout(),
          stamped: boolean(),
          rate: pos_integer(),
          fresh_for: pos_integer() | nil,
          safe_action: atom() | nil
        }

  @doc """
  The header field layout that frames a payload, for a `stamped?` port.

  Unstamped (the default — commands, status): `node·port·seq`. Stamped (sensors
  that opt in with `t_dev: true`): `node·port·seq·t_dev`.
  """
  @spec header(boolean()) :: [{atom(), Layouts.wire_type()}]
  def header(stamped?)
  def header(true), do: @base_header ++ [@t_dev_field]
  def header(false), do: @base_header

  @doc "Byte size of the header for a `stamped?` port — the start of the body."
  @spec header_size(boolean()) :: pos_integer()
  def header_size(stamped?) do
    Enum.reduce(header(stamped?), 0, fn {_f, wt}, acc -> acc + Layouts.width(wt) end)
  end

  @doc "Whether a port carries `t_dev` by default, given its spec (§04)."
  @spec stamped?(port_spec()) :: boolean()
  def stamped?(spec), do: Map.get(spec, :t_dev, false)

  @doc "The reserved broadcast / e-stop NODE id (lowest, wins CAN arbitration)."
  @spec broadcast_node() :: 0
  def broadcast_node, do: @reserved_node_broadcast

  @doc "The host's logical id — it sits above the tree and is not a hub (§01)."
  @spec host_logical_id() :: 0
  def host_logical_id, do: @host_logical_id

  @doc """
  A stable small integer port id for a `(hub, port)` pair.

  v1 uses a deterministic hash into the 0x10..0xEF band (0x00 reserved, low ids
  kept clear). This is generated, never hand-assigned — the drift test pins it.
  """
  @spec port_id(hub_name(), port_name()) :: 0x10..0xEF
  def port_id(hub, port) do
    <<n::16, _::binary>> = :crypto.hash(:sha256, "#{hub}/#{port}")
    0x10 + rem(n, 0xEF - 0x10 + 1)
  end

  @doc """
  Build the per-port IR rows from the hub contracts + a topology.

  Each row carries everything the four renderers need: the node id (from the
  topology), the generated `port_id`, the shared layout (from `Layouts`), the
  rate, and the actuator's `fresh_for`/`safe_action`. Rows are sorted by
  `{node, port_id}` so every artifact is deterministic.
  """
  @spec build_ir([hub_contract()], %{hub_name() => 0..255}) :: [ir_row()]
  def build_ir(contracts, topology) do
    for %{hub: hub, ports: ports} <- contracts, {pname, p} <- ports do
      %{
        hub: hub,
        node: Map.fetch!(topology, hub),
        port: pname,
        port_id: port_id(hub, pname),
        dir: Map.fetch!(p, :dir),
        type: Map.fetch!(p, :type),
        layout: Layouts.fetch!(Map.fetch!(p, :type)),
        stamped: stamped?(p),
        rate: Map.fetch!(p, :rate),
        fresh_for: Map.get(p, :fresh_for),
        safe_action: Map.get(p, :safe_action)
      }
    end
    |> Enum.sort_by(&{&1.node, &1.port_id})
  end
end
