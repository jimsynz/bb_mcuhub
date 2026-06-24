defmodule BBMCUHub.Contract do
  @moduledoc """
  The wire contract's frozen primitives (§06): the IR row shape, the header
  layout that frames every value, the reserved-id facts, and the stable `port_id`
  hash. The IR itself is authored in the BeamBots DSL and projected by
  `BBMCUHub.Dsl.IrTransformer` (a hub module's ports for the producer facts, the
  topology's reader views for the consumer freshness window); this module is the
  shared vocabulary those rows are built from and the renderers consume.

  An **IR row** carries one port's whole-tree identity: its `node` (from the
  `hubs do` placement), the hub's declared `parent` (another hub's name, or
  `:host` for the root) and `uplink` (the transport of this hub's link to its
  parent, `:can` | `:uart` | nil for the root) — the DECLARED topology of
  ADR-0006 — plus the generated `port_id`, value `type` + `layout`, `dir`,
  `rate`, `stamped`, the consumer `fresh_for`, the floored-role flag
  `has_safe_action`, and the `safe_action` value (a value of the port's
  value-type, ADR-0005).

  ## `t_dev` is opt-in per port (§04)

  The producer's `t_dev` (8 bytes) is the largest field, and only same-device
  fusion/replay uses it — so it is carried only on the ports that declare
  `t_dev: true`. Command and status ports omit it and stay small. A port's header
  is therefore one of two shapes, chosen by its `t_dev` flag; the decoder learns
  the shape from the same per-`(node, port)` index it uses to find the value type
  (`PortIndex`), so an unstamped frame is never misread as a stamped one.
  """

  alias BBMCUHub.Contract.Layouts

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

  # An IR row is a typed value (candidate 1): the struct + its smart constructor
  # live in `BBMCUHub.Contract.IrRow`, which fails loud at projection time on a
  # malformed row. This alias keeps the existing `Contract.ir_row()` spec name.
  @type ir_row :: BBMCUHub.Contract.IrRow.t()

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
