defmodule BBMcuhub.Test.VirtualHub do
  @moduledoc """
  A test transport that plays the role of the ESP32 hub tree behind the wire, using
  the **real firmware C floor + C wire path** (Option B, via `BBMcuhub.Test.VHubNif`).
  It implements `BBMcuhub.Host.Transport`, so the *real* host stack (LinkOwner,
  views, registry) drives it end-to-end over genuine COBS+CRC bytes — and the
  safety behaviour it exhibits is the ACTUAL C floor, not an Elixir mock that could
  drift.

  ## What it simulates

    * **Inbound commands** (host → hub): the host's framed bytes go through the C
      `transport` decoder; each verified body is C-decoded to `(node, port, seq)`
      and fed to that actuator port's real C `floor_on_command`. A *silenced* port
      drops inbound commands (the "host stopped commanding" / "wire pulled" fault).
    * **The floor**, per actuator port: a real C `Floor`, advanced by `tick/2` at
      **explicit simulated time** (no wall clock — the e2e test owns the clock).
    * **Status up** (hub → host): on each `tick`, every actuator port emits a
      `status` body (`applied_seq`, `floored?`) reflecting the real floor's state,
      framed by the C encoder and delivered to the host owner. This is the
      authoritative liveness the host's actuator view reads (§05).
    * **Sensors up**: `emit_sensor/5` injects a scripted sensor body (pose, etc.),
      C-framed, so multi-actor "one stream flows while another is silent" scenarios
      are expressible.

  ## Faults it can inject

    * `silence/2` — stop accepting commands for a port (its floor goes stale → fires).
    * `unsilence/2` — resume; the floor must RE-EARN motion (born-disarmed), not
      spring back, because it has to witness a fresh seq advance again.
    * `broadcast_disarm/1` — drop commands for ALL ports (the NODE 0x00 e-stop
      resolves to the same command-silence at every actuator; §05 e-stop).
    * `reset_floor/2` — re-init a port's C floor born-disarmed (a board reset).

  Time is explicit: nothing here reads a real clock. `tick(vhub, now_ms)` is the
  only thing that advances floors and emits status, so e2e tests are deterministic.
  """
  @behaviour BBMcuhub.Host.Transport
  use GenServer

  alias BBMcuhub.Test.VHubNif
  alias BBMcuhub.Wire.{Codec, FramingCOBS}

  # One simulated actuator port running a real C floor.
  defp new_port(node, port_id, window_ms, status_port_id) do
    %{
      node: node,
      port_id: port_id,
      status_port_id: status_port_id,
      window_ms: window_ms,
      safe_action: 0.0,
      floor: VHubNif.floor_init(window_ms, 0.0),
      silenced: false,
      last_seq: 0,
      armed: false,
      drive: 0.0
    }
  end

  # --- Transport behaviour ---

  @impl BBMcuhub.Host.Transport
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts})

  @impl BBMcuhub.Host.Transport
  def send(pid, body), do: GenServer.call(pid, {:send, body})

  @impl BBMcuhub.Host.Transport
  def close(pid), do: GenServer.stop(pid)

  # --- test/fault API ---

  @doc "Advance simulated time to `now_ms`: tick every floor, emit each status up."
  @spec tick(pid(), non_neg_integer()) :: :ok
  def tick(pid, now_ms), do: GenServer.call(pid, {:tick, now_ms})

  @doc """
  Feed a port's floor a command DIRECTLY (seq + target), bypassing the host wire.
  For multi-floor isolation tests where a second floor isn't wired into the host's
  contract — the claim under test is the floors' independence, which lives here.
  """
  @spec command_direct(pid(), 0..255, 0..0xFFFF, float()) :: :ok
  def command_direct(pid, port_id, seq, target),
    do: GenServer.call(pid, {:command_direct, port_id, seq, target})

  @doc "Inject a scripted sensor body up (C-framed), as a sensing hub would."
  @spec emit_sensor(pid(), 0..255, 0..255, 0..0xFFFF, {atom(), map(), boolean()}) :: :ok
  def emit_sensor(pid, node, port_id, seq, {type, value, stamped?}),
    do: GenServer.call(pid, {:emit_sensor, node, port_id, seq, type, value, stamped?})

  @doc "Stop accepting commands for an actuator port (silence → its floor fires)."
  @spec silence(pid(), 0..255) :: :ok
  def silence(pid, port_id), do: GenServer.call(pid, {:silence, port_id, true})

  @doc "Resume accepting commands; the floor must RE-EARN motion (born-disarmed)."
  @spec unsilence(pid(), 0..255) :: :ok
  def unsilence(pid, port_id), do: GenServer.call(pid, {:silence, port_id, false})

  @doc "Broadcast disarm (NODE 0x00 e-stop): silence EVERY actuator port at once."
  @spec broadcast_disarm(pid()) :: :ok
  def broadcast_disarm(pid), do: GenServer.call(pid, {:broadcast_silence, true})

  @doc "Lift a broadcast disarm: every floor must re-earn motion independently."
  @spec broadcast_rearm(pid()) :: :ok
  def broadcast_rearm(pid), do: GenServer.call(pid, {:broadcast_silence, false})

  @doc "Reset a port's floor born-disarmed (a board reset / power-cycle)."
  @spec reset_floor(pid(), 0..255) :: :ok
  def reset_floor(pid, port_id), do: GenServer.call(pid, {:reset_floor, port_id})

  @doc "The current armed state the floor is in (for white-box assertions)."
  @spec armed?(pid(), 0..255) :: boolean()
  def armed?(pid, port_id), do: GenServer.call(pid, {:armed?, port_id})

  @doc """
  The actual value the floor commands the plant to DRIVE as of the last `tick/2` —
  the target while armed, the safe action while floored. This is the physical
  guarantee (what torque/voltage is applied), not just the `floored?` flag.
  """
  @spec drive(pid(), 0..255) :: float()
  def drive(pid, port_id), do: GenServer.call(pid, {:drive, port_id})

  @doc """
  Inject RAW wire bytes into the host-bound framing seam (the same seam the real
  UART driver's framing module runs). Pass a corrupt/torn frame to exercise the
  host's CRC/COBS rejection (`rx_drop` / `cobs_truncated`) end-to-end.
  """
  @spec inject_wire(pid(), binary()) :: :ok
  def inject_wire(pid, bytes), do: GenServer.call(pid, {:inject_wire, bytes})

  @doc "The wire bytes a status frame for `port_id` would put on the wire (C-framed)."
  @spec status_wire(pid(), 0..255) :: binary()
  def status_wire(pid, port_id), do: GenServer.call(pid, {:status_wire, port_id})

  # --- GenServer ---

  @impl GenServer
  def init({owner, opts}) do
    # :ports — [{node, port_id, window_ms, status_port_id}] for each floored actuator.
    ports =
      opts
      |> Keyword.get(:ports, [])
      |> Map.new(fn {node, port_id, window_ms, status_port_id} ->
        {port_id, new_port(node, port_id, window_ms, status_port_id)}
      end)

    # The host-bound direction runs through the REAL framing seam (FramingCOBS),
    # exactly as Circuits.UART does internally: we emit C-framed wire bytes, deframe
    # them here, and deliver only verified bodies up — so injected corruption is
    # dropped + counted (rx_drop/cobs_truncated) just like production.
    {:ok, rx_framing} = FramingCOBS.init([])

    {:ok,
     %{
       owner: owner,
       decoder: VHubNif.decoder_new(),
       rx_framing: rx_framing,
       ports: ports,
       now_ms: 0
     }}
  end

  @impl GenServer
  def handle_call({:send, body_bytes}, _from, st) do
    # The host hands us a BODY (the LinkOwner sends bodies; the transport frames).
    # We frame it with the REAL C encoder, then feed our REAL C decoder — exercising
    # the full wire path on the hub side, byte-for-byte, before reading the command.
    wire = VHubNif.transport_encode(body_bytes)
    {decoder, bodies, _drop} = VHubNif.decoder_feed(st.decoder, wire)
    ports = Enum.reduce(bodies, st.ports, &on_command(&1, &2))
    {:reply, :ok, %{st | decoder: decoder, ports: ports}}
  end

  def handle_call({:tick, now_ms}, _from, st) do
    {ports, st} =
      Enum.map_reduce(st.ports, st, fn {pid, p}, st ->
        {floor, drive, armed} = VHubNif.floor_tick(p.floor, now_ms)
        p = %{p | floor: floor, armed: armed, drive: drive}
        st = emit_status(st, p)
        {{pid, p}, st}
      end)

    {:reply, :ok, %{st | ports: Map.new(ports), now_ms: now_ms}}
  end

  def handle_call({:emit_sensor, node, port_id, seq, type, value, stamped?}, _from, st) do
    body = Codec.encode_body(node, port_id, seq, seq, type, value, stamped?)
    {:reply, :ok, deliver_body(st, body)}
  end

  def handle_call({:inject_wire, bytes}, _from, st) do
    # Feed raw bytes straight into the host-bound framing seam — corrupt frames are
    # dropped + counted there; any clean body rides up to the owner.
    {:reply, :ok, deframe_and_deliver(st, bytes)}
  end

  def handle_call({:status_wire, port_id}, _from, st) do
    p = st.ports[port_id]
    body = status_body(p)
    {:reply, VHubNif.transport_encode(body), st}
  end

  def handle_call({:drive, port_id}, _from, st),
    do: {:reply, st.ports[port_id].drive, st}

  def handle_call({:command_direct, port_id, seq, target}, _from, st) do
    {:reply, :ok,
     put_in_port(st, port_id, fn p ->
       if p.silenced do
         p
       else
         %{p | floor: VHubNif.floor_on_command(p.floor, seq, target), last_seq: seq}
       end
     end)}
  end

  def handle_call({:silence, port_id, flag}, _from, st),
    do: {:reply, :ok, put_in_port(st, port_id, &%{&1 | silenced: flag})}

  def handle_call({:broadcast_silence, flag}, _from, st) do
    ports = Map.new(st.ports, fn {pid, p} -> {pid, %{p | silenced: flag}} end)
    {:reply, :ok, %{st | ports: ports}}
  end

  def handle_call({:reset_floor, port_id}, _from, st) do
    {:reply, :ok,
     put_in_port(st, port_id, fn p ->
       %{p | floor: VHubNif.floor_init(p.window_ms, 0.0), armed: false, last_seq: 0}
     end)}
  end

  def handle_call({:armed?, port_id}, _from, st),
    do: {:reply, st.ports[port_id].armed, st}

  # --- internals ---

  # A decoded inbound body → feed the matching actuator port's floor (unless silenced).
  defp on_command(body, ports) do
    case VHubNif.frame_decode_body(body, false) do
      {:ok, _node, port_id, seq} ->
        case ports[port_id] do
          nil ->
            ports

          %{silenced: true} = _p ->
            # silence/e-stop/pulled-wire: the command never reaches the floor, so
            # its seq stops advancing and the floor will fire on the next tick.
            ports

          p ->
            target = command_target(body)
            floor = VHubNif.floor_on_command(p.floor, seq, target)
            Map.put(ports, port_id, %{p | floor: floor, last_seq: seq})
        end

      :error ->
        ports
    end
  end

  # Decode the effort payload (f32) out of the body to feed as the floor's target.
  # The floor watches the SEQ for arming; the target is just the value to drive.
  defp command_target(body) do
    case Codec.decode_body(body) do
      {:ok, %{value: %{nm: nm}}} -> nm * 1.0
      _ -> 0.0
    end
  end

  # This port's status body (applied_seq, floored?), C-encodable.
  defp status_body(p) do
    value = %{applied_seq: p.last_seq, floored: not p.armed}
    Codec.encode_body(p.node, p.status_port_id, p.last_seq, p.last_seq, :status, value, false)
  end

  # Emit this port's status up to the host through the REAL framing seam.
  defp emit_status(st, p), do: deliver_body(st, status_body(p))

  # Frame a body with the REAL C encoder, then push the wire bytes through the host's
  # framing seam (FramingCOBS) — mirroring the production UART driver, so a clean body
  # rides up and any corruption would be dropped + counted there.
  defp deliver_body(st, body) do
    wire = VHubNif.transport_encode(body)
    deframe_and_deliver(st, wire)
  end

  # Run inbound wire bytes through FramingCOBS.remove_framing (bumps rx_drop /
  # cobs_truncated on corruption), delivering each verified body to the host owner in
  # the same message shape the UART transport uses.
  defp deframe_and_deliver(st, bytes) do
    {_in_frame, bodies, rx_framing} = FramingCOBS.remove_framing(bytes, st.rx_framing)
    for body <- bodies, do: Kernel.send(st.owner, {:circuits_uart, :vhub, body})
    %{st | rx_framing: rx_framing}
  end

  defp put_in_port(st, port_id, fun) do
    case st.ports[port_id] do
      nil -> st
      p -> %{st | ports: Map.put(st.ports, port_id, fun.(p))}
    end
  end
end
