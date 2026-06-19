defmodule BBMcuhub.BBHub.Sensor do
  @moduledoc """
  A `BB.Sensor` view over a hub's sense port (§09).

  A thin VIEW and almost nothing else: the link owner has already decoded inbound
  frames into the `(node, port)` registry slot; this view's whole job is to pull
  that slot on **its own beat** (BB has no built-in poll loop), ask the born-stale
  monitor "did `seq` advance?" (§04), and lift a *fresh* value into a typed
  `BB.Message` on BeamBots' PubSub.

  It holds no socket, names no transport, and cannot tell whether the value came
  from the root hub's own I²C or a leaf three CAN hops down. **Born stale:**
  nothing is published until this view personally witnesses `seq` advance since
  its own boot — so a restart never republishes a leftover reading.

  Required options (validated by `options_schema`):
    * `:hub`, `:port` — the symbolic hub + port name (resolved to the wire id)
    * `:fresh_for` — the freshness window in beats
    * `:beat_ms` — how often this view samples its slot

  v1 hand-writes this small module; generating it from the contract is deferred
  (SAFeD), holding to the rules above: pure-lift, born-stale, no socket.
  """
  use BB.Sensor,
    options_schema: [
      hub: [type: :atom, required: true, doc: "the hub name (resolved to a NODE id)"],
      port: [type: :atom, required: true, doc: "the sense port name on that hub"],
      fresh_for: [type: :pos_integer, default: 3, doc: "freshness window in beats"],
      beat_ms: [type: :pos_integer, default: 20, doc: "sample period for this view"]
    ]

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{Monitor, NodeRegistry}
  alias BBMcuhub.ValueType

  @impl BB.Sensor
  def init(opts) do
    bb = Keyword.fetch!(opts, :bb)
    hub = Keyword.fetch!(opts, :hub)
    port = Keyword.fetch!(opts, :port)

    case PortIndex.resolve(hub, port) do
      {:ok, {node_id, port_id}} ->
        beat_ms = opts[:beat_ms] || 20
        fresh_for = opts[:fresh_for] || 3
        :timer.send_interval(beat_ms, :beat)

        {:ok,
         %{
           bb: bb,
           node_id: node_id,
           port_id: port_id,
           value_type: lookup_value_type(node_id, port_id),
           mon: Monitor.new(node_id, port_id, fresh_for)
         }}

      :error ->
        {:stop, {:unknown_port, {hub, port}}}
    end
  end

  # Each beat: update the freshness monitor; publish only if fresh.
  @impl BB.Sensor
  def handle_info(:beat, st) do
    mon = Monitor.check(st.mon)

    if Monitor.fresh?(mon) do
      {value, _seq, _t_dev} = NodeRegistry.get(st.node_id, st.port_id)
      # value-type-agnostic: the port's value-type lifts the raw slot map to a
      # typed BB.Message payload (§09) — no per-atom clause here.
      payload = st.value_type.lift(value)
      BB.publish(st.bb.robot, [:sensor | st.bb.path], wrap(payload, st.bb))
    end

    {:noreply, %{st | mon: mon}}
  end

  def handle_info(_other, st), do: {:noreply, st}

  # build the BB.Message envelope directly around the already-validated payload
  defp wrap(payload, bb) do
    frame_id = List.last(bb.path) || :sensor

    %BB.Message{
      monotonic_time: System.monotonic_time(:nanosecond),
      wall_time: System.system_time(:nanosecond),
      node: Node.self(),
      frame_id: frame_id,
      payload: payload,
      robot: bb.robot
    }
  end

  # resolve the port's value-type atom to its module once, at init
  defp lookup_value_type(node_id, port_id) do
    {:ok, type} = PortIndex.type_for(node_id, port_id)
    ValueType.resolve(type)
  end
end
