defmodule BBMcuhub.Host.SoftFaultE2ETest do
  @moduledoc """
  The soft-fault resilience catalog, end-to-end against the **real firmware C
  floor + C wire path** (Option B — `BBMcuhub.Test.VirtualHub` over
  `BBMcuhub.Test.VHubNif`). Unlike the C harnesses (which test the floor in
  isolation) and preflight (which models the floor host-side), this drives the
  REAL host stack — LinkOwner draining command slots through genuine COBS+CRC
  bytes — into the ACTUAL C floor, and reads the floor's authoritative status back
  up. It proves the host↔hub floor path that no isolated test reaches.

  Time is explicit: `VirtualHub.tick(vhub, now_ms)` is the only clock. Every
  assertion is deterministic — no wall-clock sleeps gate a result.

  The catalog (each fault + its RECOVERY):

    1. **Command-silence floors a wheel.** While commands flow, the floor is armed
       (status: not floored). Stop commanding → on the next tick past the floor
       window, the real C floor de-energises and reports floored.
    2. **Broadcast disarm floors everyone.** The NODE 0x00 e-stop resolves to
       command-silence at every actuator (CONTEXT.md · e-stop) → all floors fire.
    3. **One hub silent, another flows.** Silencing one port's commands floors only
       it; a second port still being commanded stays armed (per-slot isolation, on
       the real floors).
    4. **Recovery is born-disarmed.** After a fault clears, a floored wheel does NOT
       spring back: it must witness a fresh command-seq advance again before it
       re-arms (the born-disarmed guarantee, in the real C floor).
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{LinkOwner, NodeRegistry}
  alias BBMcuhub.Test.VirtualHub
  alias BBMcuhub.Wire.Codec

  @robot BBMcuhub.Test.Fixtures.Robot
  # The fixture actuator's floor window (FLOOR_MISSES × CMD_PERIOD; §05). The exact
  # number is a generated contract detail — what matters is that silence past it fires.
  @window_ms 100

  setup do
    :ets.delete_all_objects(NodeRegistry.table())
    PortIndex.build(@robot)

    {:ok, {a_node, eff_port}} = PortIndex.resolve(:act_hub, :effort_cmd)
    {:ok, {^a_node, status_port}} = PortIndex.resolve(:act_hub, :act_status)

    # Stand up the real LinkOwner over the VirtualHub, configured with one floored
    # actuator port (effort_cmd) reporting on act_status.
    {:ok, owner} =
      LinkOwner.start_link(
        transport: VirtualHub,
        transport_opts: [ports: [{a_node, eff_port, @window_ms, status_port}]],
        command_slots: [{a_node, eff_port}],
        name: nil
      )

    vhub = :sys.get_state(owner).transport
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    {:ok, owner: owner, vhub: vhub, a_node: a_node, eff_port: eff_port, status_port: status_port}
  end

  # Write an effort command to its slot and notify the LinkOwner to drain it (this
  # is exactly what the actuator view — the slot's sole writer — does). The seq
  # advances each call so the floor witnesses the advance.
  defp command(ctx, seq, nm) do
    NodeRegistry.put(ctx.a_node, ctx.eff_port, %{nm: nm}, seq, 0)
    LinkOwner.notify_command_slot(ctx.owner, ctx.a_node, ctx.eff_port)
    # let the drain + the VirtualHub's send round-trip run
    _ = :sys.get_state(ctx.owner)
    _ = :sys.get_state(ctx.vhub)
    :ok
  end

  # Tick the simulated clock, then drain the status the VirtualHub emitted up to the
  # host owner; return the latest floored? for the actuator from the registry.
  defp tick_and_read(ctx, now_ms) do
    VirtualHub.tick(ctx.vhub, now_ms)
    # the status bodies were delivered to the LinkOwner; flush its mailbox so it
    # decodes them into the registry before we read.
    _ = :sys.get_state(ctx.owner)

    case NodeRegistry.get(ctx.a_node, ctx.status_port) do
      {%{floored: floored?}, _seq, _t} -> floored?
      nil -> :no_status
    end
  end

  describe "(1) command-silence floors a wheel (real C floor, e2e)" do
    test "armed while commanded; floors when commands stop", ctx do
      # Earn motion: two advancing commands (baseline + advance), each ticked inside
      # the window so the real floor sees them fresh.
      command(ctx, 1, 0.5)
      assert tick_and_read(ctx, 10) == true, "born-disarmed: floored before a witnessed advance"

      command(ctx, 2, 0.5)
      assert tick_and_read(ctx, 20) == false, "armed after a witnessed advance → not floored"

      # Keep commanding inside the window: stays armed.
      command(ctx, 3, 0.5)
      assert tick_and_read(ctx, 40) == false
      command(ctx, 4, 0.5)
      assert tick_and_read(ctx, 60) == false

      # SILENCE: stop commanding. Tick past the window from the last advance (60ms).
      # 60 + 100 = 160; tick at 170 → the real C floor fires.
      assert tick_and_read(ctx, 170) == true,
             "command silence past the window must floor the wheel"
    end
  end

  describe "(4) recovery is born-disarmed (no spring-back)" do
    test "a floored wheel re-earns motion only on a fresh witnessed advance", ctx do
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      command(ctx, 2, 0.5)
      assert tick_and_read(ctx, 20) == false, "armed"

      # Silence → floor fires.
      assert tick_and_read(ctx, 200) == true, "floored on silence"

      # Recovery: a SINGLE command after the fault is only a baseline to the
      # re-armed-from-stale floor logic — but the floor never reset, so it has its
      # baseline; the next DIFFERENT seq is the witnessed advance. Either way, one
      # fresh advancing command inside a fresh window must re-earn motion.
      command(ctx, 3, 0.5)
      # tick inside the window from this advance
      assert tick_and_read(ctx, 210) == false, "a fresh advancing command re-earns motion"
    end

    test "a board reset boots born-disarmed and must witness an advance to re-arm", ctx do
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      command(ctx, 2, 0.5)
      assert tick_and_read(ctx, 20) == false

      # A board reset: the floor re-inits born-disarmed (armed=false, output at the
      # safe action), its arming history forgotten. With no fresh command witnessed
      # since the reset, it reads floored — a reboot cannot inherit motion.
      VirtualHub.reset_floor(ctx.vhub, ctx.eff_port)
      assert tick_and_read(ctx, 25) == true, "post-reset: born-disarmed (floored) until re-earned"

      # Motion is re-earned only by witnessing a fresh command-seq advance since the
      # reset — exactly the born-disarmed guarantee, now in the freshly-booted floor.
      command(ctx, 3, 0.5)

      assert tick_and_read(ctx, 30) == false,
             "a fresh witnessed advance after reset re-earns motion"
    end
  end

  describe "(2) broadcast disarm floors the actuator" do
    test "after disarm, command silence at the actuator fires its floor", ctx do
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      command(ctx, 2, 0.5)
      assert tick_and_read(ctx, 20) == false, "armed"

      # Broadcast disarm: the e-stop resolves to command-silence at the actuator
      # (CONTEXT.md · e-stop is an accelerator, not a second path). Further commands
      # are dropped before reaching the floor.
      VirtualHub.broadcast_disarm(ctx.vhub)
      command(ctx, 3, 0.5)
      command(ctx, 4, 0.5)

      # Tick past the window from the last DELIVERED advance (20ms) → floored.
      assert tick_and_read(ctx, 130) == true, "broadcast disarm → the floor fires"
    end
  end

  describe "(3) one hub silent, another flows (per-floor isolation, real C floors)" do
    # Two REAL C floors in one VirtualHub: silence one, keep commanding the other,
    # and assert each floor's arm state is independent — one going stale cannot
    # affect the sibling. Each C `Floor` is its own struct, so this proves isolation
    # on the actual safety code. Port A is the fixture's host-wired effort port; port
    # B is a second floor driven directly (its contract isn't in the host PortIndex —
    # the claim under test is floor independence, which lives in the floors).
    setup ctx do
      port_b = ctx.eff_port + 1
      status_b = ctx.status_port + 1
      GenServer.stop(ctx.owner)

      {:ok, owner} =
        LinkOwner.start_link(
          transport: VirtualHub,
          transport_opts: [
            ports: [
              {ctx.a_node, ctx.eff_port, @window_ms, ctx.status_port},
              {ctx.a_node, port_b, @window_ms, status_b}
            ]
          ],
          command_slots: [{ctx.a_node, ctx.eff_port}],
          name: nil
        )

      vhub = :sys.get_state(owner).transport
      on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
      {:ok, owner: owner, vhub: vhub, port_b: port_b}
    end

    test "silencing one floor leaves the other armed", ctx do
      # Arm BOTH: baseline + witnessed advance on each, ticking between. Port A goes
      # through the full host stack; port B is fed directly.
      command(ctx, 1, 0.5)
      VirtualHub.command_direct(ctx.vhub, ctx.port_b, 1, 0.5)
      VirtualHub.tick(ctx.vhub, 10)

      command(ctx, 2, 0.5)
      VirtualHub.command_direct(ctx.vhub, ctx.port_b, 2, 0.5)
      VirtualHub.tick(ctx.vhub, 20)

      assert VirtualHub.armed?(ctx.vhub, ctx.eff_port), "port A armed"
      assert VirtualHub.armed?(ctx.vhub, ctx.port_b), "port B armed"

      # SILENCE only port A; keep commanding port B inside the window.
      VirtualHub.silence(ctx.vhub, ctx.eff_port)

      for {now, seq} <- [{40, 3}, {60, 4}, {80, 5}, {100, 6}, {120, 7}] do
        VirtualHub.command_direct(ctx.vhub, ctx.port_b, seq, 0.5)
        VirtualHub.tick(ctx.vhub, now)
      end

      # Port A went stale (silenced past its window) → its floor fired.
      refute VirtualHub.armed?(ctx.vhub, ctx.eff_port),
             "the silenced floor fired (commands stopped past its window)"

      # Port B, still commanded, is untouched by its sibling's floor — stays armed.
      assert VirtualHub.armed?(ctx.vhub, ctx.port_b),
             "a sibling floor firing must not affect a port that is still commanded"
    end
  end

  # Body-shape sanity: the VirtualHub frames status with the real C encoder and the
  # host decodes it with the real Elixir decoder — a genuine two-codec round-trip.
  describe "wire fidelity (C encodes ↔ Elixir decodes)" do
    test "status emitted by the C-framed VirtualHub decodes on the host", ctx do
      # Earn motion (baseline then a witnessed advance, ticking between) so the status
      # the C floor reports is the interesting 'driving' case.
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      command(ctx, 2, 0.5)
      VirtualHub.tick(ctx.vhub, 20)
      _ = :sys.get_state(ctx.owner)

      assert {%{floored: false, applied_seq: 2}, _seq, _t} =
               NodeRegistry.get(ctx.a_node, ctx.status_port)
    end

    test "a sensor body injected by the VirtualHub reaches the registry", ctx do
      {:ok, {p_node, p_port}} = PortIndex.resolve(:sensor_hub, :pose)

      pose = %{
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

      VirtualHub.emit_sensor(ctx.vhub, p_node, p_port, 7, {:imu, pose, true})
      _ = :sys.get_state(ctx.owner)

      assert {%{az: az}, 7, _t} = NodeRegistry.get(p_node, p_port)
      assert_in_delta az, 9.81, 0.001
      # silence the unused-codec warning
      _ = &Codec.decode_body/1
    end
  end
end
