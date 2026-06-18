defmodule BBMcuhub.Contract do
  @moduledoc """
  The wire contract's frozen primitives (§06): the IR row shape, the header
  layout that frames every value, the reserved-id facts, and the stable `port_id`
  hash. The IR itself is authored in the BeamBots DSL and projected by
  `BBMcuhub.Dsl.IrTransformer` (a hub module's ports for the producer facts, the
  topology's reader views for the consumer freshness window); this module is the
  shared vocabulary those rows are built from and the renderers consume.

  An **IR row** carries one port's whole-tree identity: its `node` (from the
  `hubs do` placement), generated `port_id`, value `type` + `layout`, `dir`,
  `rate`, `stamped`, and the consumer `fresh_for` / `safe_action`.

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
end
