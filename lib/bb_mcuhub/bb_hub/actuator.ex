defmodule BBMcuhub.BBHub.Actuator do
  @moduledoc """
  A `BB.Actuator` view over a hub's act port (§09).

  The mirror image of the sensor view, and the **single writer** of its outbound
  command slot — the link owner only ever *drains* that slot to the wire, never
  writes it, so it can never manufacture a `seq` advance (§04). On each BeamBots
  command this view decodes the `BB.Message` and `put`s the command slot with a
  monotonically advancing `seq`. The hub's own floor (§05) does the safety work;
  this view never drives hardware directly.

  `disarm/1` is **best-effort intent**, not the safe-state mechanism (§05): it
  asks the link owner to send a broadcast disarm (a fast accelerator that wins CAN
  arbitration) and returns once that intent is delivered. The real guarantee is
  the on-chip floor. Liveness ("is it actually driving?") is read from the hub's
  *status* slot via `live/1`, never inferred from "we sent a command".

  Required options:
    * `:node`, `:port` — the command port (hub + port name)
    * `:status_port` — the hub's reported-truth slot name
    * `:command_seq_start` — the first seq this view assigns (default 1)
  """
  use BB.Actuator,
    options_schema: [
      node: [type: :atom, required: true, doc: "the hub name"],
      port: [type: :atom, required: true, doc: "the command port name"],
      status_port: [type: :atom, required: true, doc: "the hub's status slot name"],
      command_seq_start: [type: :non_neg_integer, default: 1],
      status_fresh_for: [type: :pos_integer, default: 5, doc: "status freshness window in beats"],
      beat_ms: [type: :pos_integer, default: 20, doc: "status-monitor beat period"]
    ]

  alias BBMcuhub.BBHub.Lift
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{LinkOwner, Monitor, NodeRegistry}

  @impl BB.Actuator
  def init(opts) do
    bb = Keyword.fetch!(opts, :bb)
    hub = Keyword.fetch!(opts, :node)
    port = Keyword.fetch!(opts, :port)
    status_port = Keyword.fetch!(opts, :status_port)

    with {:ok, {node_id, port_id}} <- PortIndex.resolve(hub, port),
         {:ok, {^node_id, status_id}} <- PortIndex.resolve(hub, status_port) do
      # the status slot is read THROUGH a born-stale monitor (§05): a stale "not
      # floored" must never read as driving, so the view ticks the monitor on its
      # own beat and live/1 reads the monitor's verdict, not the raw slot.
      :timer.send_interval(opts[:beat_ms] || 20, :status_beat)

      {:ok,
       %{
         bb: bb,
         node_id: node_id,
         port_id: port_id,
         status_id: status_id,
         seq: opts[:command_seq_start] || 1,
         status_mon: Monitor.new(node_id, status_id, opts[:status_fresh_for] || 5)
       }}
    else
      _ -> {:stop, {:unknown_port, {hub, port, status_port}}}
    end
  end

  # A BeamBots command → write our ONE command slot. The link owner drains it to
  # the wire; the floor decides whether the hub acts on it. We are the sole writer
  # of this slot, so each write advances the command seq exactly once.
  @impl BB.Actuator
  def handle_info(
        {:bb, _topic, %BB.Message{payload: %BB.Message.Actuator.Command.Effort{} = c}},
        st
      ) do
    {:noreply, write_command(st, Lift.effort_from_bb(c))}
  end

  # tick the status freshness monitor on our own beat (§04/§05)
  def handle_info(:status_beat, st) do
    {:noreply, %{st | status_mon: Monitor.check(st.status_mon)}}
  end

  def handle_info(_other, st), do: {:noreply, st}

  @impl BB.Actuator
  def handle_cast({:command, %BB.Message{payload: %BB.Message.Actuator.Command.Effort{} = c}}, st) do
    {:noreply, write_command(st, Lift.effort_from_bb(c))}
  end

  def handle_cast(_other, st), do: {:noreply, st}

  # disarm/1 runs WITHOUT GenServer state (BB calls it with the init opts) — so
  # everything it needs is in opts, and its return means "intent delivered", NOT
  # "the hardware is safe" (that is the on-chip floor's job, §05).
  @impl BB.Actuator
  def disarm(_opts) do
    LinkOwner.send_disarm()
    :ok
  rescue
    # best-effort: if the link owner is unavailable the floor still backstops
    _ -> :ok
  end

  @doc """
  The hub's reported truth, **gated by born-stale freshness** (§05): `:driving`
  only when the status slot is *fresh* AND says not floored. A stale status — the
  hub went silent, or this view just booted — reads as `:floored_or_unknown`,
  never a confident green while a wheel sits floored.
  """
  @spec live(map()) :: :driving | :floored_or_unknown
  def live(%{status_mon: mon, node_id: node_id, status_id: status_id}) do
    if Monitor.fresh?(mon) do
      case NodeRegistry.get(node_id, status_id) do
        {%{floored: false}, _seq, _t} -> :driving
        _ -> :floored_or_unknown
      end
    else
      :floored_or_unknown
    end
  end

  defp write_command(st, value) do
    NodeRegistry.put(st.node_id, st.port_id, value, st.seq, 0)
    %{st | seq: st.seq + 1}
  end
end
