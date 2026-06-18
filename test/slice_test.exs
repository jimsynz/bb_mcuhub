defmodule BBMcuhub.SliceTest do
  @moduledoc """
  The walking-skeleton tracer bullet (§02/§09): one sensor port and one actuator
  port carried end-to-end through the REAL wire path.

    sensor:   simulated imu hub → loopback transport (real COBS+CRC) → LinkOwner
              → registry → Sensor view (born-stale gate) → BB.Message on PubSub
    actuator: BB Effort command → Actuator view (sole writer) → command slot
              → LinkOwner drain → wire (real COBS+CRC) → decodes back to Effort

  Plus the floor's host-side reference degrading on command silence (§05).
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.BBHub
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{LinkOwner, NodeRegistry}
  alias BBMcuhub.Test.LoopbackTransport
  alias BBMcuhub.Wire.Codec

  @robot BBMcuhub.Robots.Follower

  setup do
    :ets.delete_all_objects(NodeRegistry.table())
    PortIndex.build()

    # the BeamBots supervision tree for the follower gives us a real PubSub the
    # views publish/subscribe on (§09)
    start_supervised!(%{id: BB.Supervisor, start: {BB.Supervisor, :start_link, [@robot]}})
    :ok
  end

  describe "sensor path: a produced imu frame becomes a BB.Message.Sensor.Imu" do
    test "born-stale, then publishes a fresh lifted pose" do
      {:ok, {imu_node, imu_port}} = PortIndex.resolve(:imu, :pose)
      {:ok, owner} = LinkOwner.start_link(transport: LoopbackTransport, name: nil)
      transport = :sys.get_state(owner).transport

      # the Sensor view, attached to this robot/path, beating fast
      {:ok, view} =
        bb_init(BBHub.Sensor, [:base_link, :chassis_imu],
          hub: :imu,
          port: :pose,
          fresh_for: 3,
          beat_ms: 5
        )

      BB.subscribe(@robot, [:sensor, :base_link, :chassis_imu])

      # born stale: a beat before any value publishes nothing
      send(view, :beat)
      refute_receive {:bb, _, _}, 30

      # the imu hub produces two values (born-stale needs an advance to trust)
      inject_imu(transport, imu_node, imu_port, 1, az: 9.81)
      Process.sleep(10)
      send(view, :beat)
      inject_imu(transport, imu_node, imu_port, 2, az: 9.50)
      Process.sleep(10)
      send(view, :beat)

      assert_receive {:bb, [:sensor, :base_link, :chassis_imu], %BB.Message{payload: payload}},
                     200

      assert %BB.Message.Sensor.Imu{} = payload
      assert_in_delta BB.Math.Vec3.z(payload.linear_acceleration), 9.50, 1.0e-4
    end
  end

  describe "actuator path: a BB Effort command reaches the wire" do
    test "the view writes its command slot and the link owner drains it" do
      {:ok, {m_node, m_port}} = PortIndex.resolve(:motor, :motor_target)

      # Register under the DEFAULT name so the actuator view (which notifies the
      # link owner via that name, like disarm/1) reaches it — exactly as in
      # production. The drain is now event-driven: the view notifies on write.
      {:ok, owner} =
        LinkOwner.start_link(
          transport: LoopbackTransport,
          command_slots: [{m_node, m_port}]
        )

      on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
      transport = :sys.get_state(owner).transport

      {:ok, view} =
        bb_init(BBHub.Actuator, [:base_link, :left_wheel, :wheel],
          hub: :motor,
          port: :motor_target,
          status_port: :motor_status
        )

      # a BeamBots Effort command arrives at the view
      cmd = %BB.Message{payload: %BB.Message.Actuator.Command.Effort{effort: 0.42}}
      send(view, {:bb, [:actuator, :base_link, :left_wheel, :wheel], cmd})

      # the slot was written (the view is the sole writer), then drained to wire
      assert_eventually(fn ->
        case LoopbackTransport.sent(transport) do
          [body | _] ->
            match?(
              {:ok, %{node: ^m_node, port_id: ^m_port, type: :effort}},
              Codec.decode_body(body)
            )

          [] ->
            false
        end
      end)

      [body | _] = LoopbackTransport.sent(transport)
      {:ok, decoded} = Codec.decode_body(body)
      assert_in_delta decoded.value.nm, 0.42, 1.0e-5
    end

    test "live/1 is freshness-gated: a stale 'not floored' status reads as unknown (§05)" do
      {:ok, {m_node, _}} = PortIndex.resolve(:motor, :motor_target)
      {:ok, {^m_node, status_id}} = PortIndex.resolve(:motor, :motor_status)

      # a long beat so the timer never fires during the test — we drive the
      # status monitor's beats explicitly for determinism.
      {:ok, view} =
        bb_init(BBHub.Actuator, [:base_link, :left_wheel, :wheel],
          hub: :motor,
          port: :motor_target,
          status_port: :motor_status,
          status_fresh_for: 2,
          beat_ms: 60_000
        )

      beat = fn -> tick(view, :status_beat) end
      live = fn -> BBHub.Actuator.live(BBMcuhub.Test.ViewHarness.view_state(view)) end

      # born stale: no status witnessed → not driving even before any status exists
      beat.()
      assert live.() == :floored_or_unknown

      # the hub reports "not floored" — first seq is a baseline (strict born-stale),
      # the second, distinct seq earns trust (§04)
      NodeRegistry.put(m_node, status_id, %{applied_seq: 1, floored: false}, 1, 0)
      beat.()
      assert live.() == :floored_or_unknown, "baseline only — must not be trusted yet"

      NodeRegistry.put(m_node, status_id, %{applied_seq: 2, floored: false}, 2, 0)
      beat.()
      assert live.() == :driving, "fresh, not floored → driving"

      # the status goes silent (seq frozen): after fresh_for beats it must read
      # unknown, NOT a confident green from the leftover "not floored" value
      beat.()
      beat.()
      beat.()
      assert live.() == :floored_or_unknown, "stale status must never read as driving"
    end
  end

  describe "the floor degrades on command silence (§05, host reference)" do
    alias BBMcuhub.Hubs.Motor.Floor

    test "born-disarmed → earns motion → floors when the command goes silent" do
      f = Floor.new(100, 0.0)

      # born disarmed
      {out, f} = Floor.step(f, :none, 0)
      assert out == 0.0
      refute f.armed?

      # baseline (one seq) — still safe
      {out, f} = Floor.step(f, {1, 0.5}, 0)
      assert out == 0.0

      # second distinct seq earns motion
      {out, f} = Floor.step(f, {2, 0.5}, 20)
      assert out == 0.5
      assert f.armed?

      # command goes silent past the window → safe, disarmed
      {out, f} = Floor.step(f, {2, 0.5}, 200)
      assert out == 0.0
      refute f.armed?
    end
  end

  # --- helpers ---

  # drive a BB view's init/1 directly (the view is a callback module, not a
  # GenServer; for the test we wrap it in a bare GenServer that delegates handle_info)
  defp bb_init(module, path, opts) do
    full_opts = Keyword.put(opts, :bb, %{robot: @robot, path: path})
    BBMcuhub.Test.ViewHarness.start(module, full_opts)
  end

  defp inject_imu(transport, node, port, seq, overrides) do
    base = %{
      qw: 1.0,
      qx: 0.0,
      qy: 0.0,
      qz: 0.0,
      wx: 0.0,
      wy: 0.0,
      wz: 0.0,
      ax: 0.0,
      ay: 0.0,
      az: 9.81
    }

    value = Enum.into(overrides, base)
    body = Codec.encode_body(node, port, seq, seq * 100, :imu, value, true)
    LoopbackTransport.inject(transport, body)
  end

  # send a message to the view and block until it's processed (the following
  # view_state GenServer.call flushes the mailbox), so reads see the new state.
  defp tick(view, msg) do
    send(view, msg)
    _ = BBMcuhub.Test.ViewHarness.view_state(view)
    :ok
  end

  defp assert_eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(fun, tries - 1)
    end
  end
end
