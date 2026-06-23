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

  alias BBMcuhub.BBHub
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{LinkOwner, Monitor, NodeRegistry}
  alias BBMcuhub.Test.{ViewHarness, VirtualHub}
  alias BBMcuhub.Wire.{Codec, Stats}

  @robot BBMcuhub.Test.Fixtures.Robot
  # The fixture actuator's floor window (FLOOR_MISSES × CMD_PERIOD; §05). The exact
  # number is a generated contract detail — what matters is that silence past it fires.
  @window_ms 100

  setup do
    :ets.delete_all_objects(NodeRegistry.table())
    PortIndex.build(@robot)
    Stats.setup()

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

  describe "the floor drives the actual SAFE_ACTION value on fire (physical guarantee)" do
    test "armed → drives the target; floored → drives the safe action", ctx do
      command(ctx, 1, 0.7)
      VirtualHub.tick(ctx.vhub, 10)
      command(ctx, 2, 0.7)
      VirtualHub.tick(ctx.vhub, 20)

      # Armed: the real C floor passes the commanded target THROUGH to the plant.
      assert VirtualHub.armed?(ctx.vhub, ctx.eff_port)

      assert_in_delta VirtualHub.drive(ctx.vhub, ctx.eff_port),
                      0.7,
                      0.0001,
                      "armed floor drives the commanded target"

      # Silence past the window: the floor must drive the SAFE ACTION (0.0), not the
      # last target — the guarantee is the *value* applied to the plant, not a flag.
      VirtualHub.tick(ctx.vhub, 200)
      refute VirtualHub.armed?(ctx.vhub, ctx.eff_port)

      assert VirtualHub.drive(ctx.vhub, ctx.eff_port) == 0.0,
             "a fired floor drives the safe action (0 torque), never the stale target"
    end
  end

  describe "seq wraparound survives the full host→C-floor path" do
    test "a command seq crossing 0xFFFF → 0 is still a witnessed advance", ctx do
      # Baseline + advance near the u16 ceiling so the floor is armed and primed.
      command(ctx, 0xFFFE, 0.5)
      VirtualHub.tick(ctx.vhub, 10)
      command(ctx, 0xFFFF, 0.5)
      VirtualHub.tick(ctx.vhub, 20)
      assert VirtualHub.armed?(ctx.vhub, ctx.eff_port), "armed at the seq ceiling"

      # WRAP: 0xFFFF → 0. The body's u16 seq encodes/decodes through the real wire,
      # and the floor's plain-inequality advance test (CONTEXT.md · Advance) must
      # treat 0 ≠ 0xFFFF as a new write — so the wheel stays armed across the wrap.
      command(ctx, 0, 0.5)
      VirtualHub.tick(ctx.vhub, 40)

      assert VirtualHub.armed?(ctx.vhub, ctx.eff_port),
             "seq wraparound (0xFFFF → 0) is an advance — the floor stays armed"
    end
  end

  describe "corrupt wire is dropped + counted end-to-end (host framing seam)" do
    test "a bit-flipped status frame is rejected + counted, clean frames still flow",
         ctx do
      # Earn motion so a real status frame exists to corrupt.
      command(ctx, 1, 0.5)
      VirtualHub.tick(ctx.vhub, 10)
      command(ctx, 2, 0.5)
      VirtualHub.tick(ctx.vhub, 20)
      _ = :sys.get_state(ctx.owner)
      assert {%{floored: false}, _, _} = NodeRegistry.get(ctx.a_node, ctx.status_port)

      # Take a REAL C-framed status frame and flip a byte in its middle (corrupting
      # the CRC-covered body). Inject it at the host's framing seam.
      wire = VirtualHub.status_wire(ctx.vhub, ctx.eff_port)
      dropped_before = total_dropped()
      flipped = flip_a_byte(wire)
      VirtualHub.inject_wire(ctx.vhub, flipped)
      _ = :sys.get_state(ctx.owner)

      # WHICH drop counter fires depends on whether the flipped byte breaks the COBS
      # run (rx_drop / cobs_truncated) or just the body (crc_fail) — frame-layout
      # dependent. The invariant is the SUM: a corrupted frame is dropped + counted
      # at the seam, never delivered.
      assert total_dropped() > dropped_before,
             "a corrupted frame must be dropped + counted at the framing seam"

      # The stream is NOT desynced: a subsequent CLEAN status still lands.
      command(ctx, 3, 0.5)
      VirtualHub.tick(ctx.vhub, 40)
      _ = :sys.get_state(ctx.owner)

      assert {%{applied_seq: 3}, 3, _} = NodeRegistry.get(ctx.a_node, ctx.status_port),
             "a clean frame after corruption still delivers — no desync"
    end

    test "garbage bytes between delimiters never reach the registry", ctx do
      # Pure noise framed as a delimited junk frame: COBS/CRC must reject it.
      drop_before = Stats.get(:rx_drop)
      VirtualHub.inject_wire(ctx.vhub, <<0xDE, 0xAD, 0xBE, 0xEF, 0x00>>)
      _ = :sys.get_state(ctx.owner)

      assert Stats.get(:rx_drop) > drop_before, "junk is dropped + counted"
      assert NodeRegistry.get(ctx.a_node, ctx.status_port) == nil, "no value reached a slot"
    end

    test "a truncated COBS frame is counted as cobs_truncated", ctx do
      # A code byte (0x05) claims 4 following bytes, but only one precedes the 0x00
      # delimiter — the COBS decoder reports :truncated, a distinct counter from a
      # CRC drop. (This is the one wire counter the rest of the suite never exercises.)
      trunc_before = Stats.get(:cobs_truncated)
      VirtualHub.inject_wire(ctx.vhub, <<0x05, 0x11, 0x00>>)
      _ = :sys.get_state(ctx.owner)

      assert Stats.get(:cobs_truncated) > trunc_before,
             "a truncated COBS run is counted as cobs_truncated"

      assert NodeRegistry.get(ctx.a_node, ctx.status_port) == nil
    end
  end

  describe "torn + interleaved frames reassemble through the host decoder" do
    test "a status frame split across two injections is held then delivered", ctx do
      command(ctx, 1, 0.5)
      VirtualHub.tick(ctx.vhub, 10)
      command(ctx, 2, 0.5)
      VirtualHub.tick(ctx.vhub, 20)

      wire = VirtualHub.status_wire(ctx.vhub, ctx.eff_port)
      half = div(byte_size(wire), 2)
      <<part1::binary-size(half), part2::binary>> = wire

      # First half: incomplete, nothing should be delivered yet.
      VirtualHub.inject_wire(ctx.vhub, part1)
      _ = :sys.get_state(ctx.owner)
      # (we can't easily assert "nothing" without a baseline; clear the slot first)
      :ets.delete(NodeRegistry.table(), {ctx.a_node, ctx.status_port})

      # Second half completes the frame → the body is delivered + decoded.
      VirtualHub.inject_wire(ctx.vhub, part2)
      _ = :sys.get_state(ctx.owner)

      assert {%{applied_seq: 2}, 2, _} = NodeRegistry.get(ctx.a_node, ctx.status_port),
             "a frame torn across two reads is reassembled and delivered"
    end

    test "two interleaved frames (status + sensor) both reassemble", ctx do
      {:ok, {p_node, p_port}} = PortIndex.resolve(:sensor_hub, :pose)

      command(ctx, 1, 0.5)
      VirtualHub.tick(ctx.vhub, 10)
      command(ctx, 2, 0.5)
      VirtualHub.tick(ctx.vhub, 20)

      status = VirtualHub.status_wire(ctx.vhub, ctx.eff_port)

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

      pose_body = Codec.encode_body(p_node, p_port, 5, 5, :imu, pose, true)
      sensor = BBMcuhub.Test.VHubNif.transport_encode(pose_body)

      :ets.delete(NodeRegistry.table(), {ctx.a_node, ctx.status_port})

      # A complete sensor frame, then a status frame TORN across the next two reads.
      # Each frame is delimiter-terminated (0x00), so the framer peels the whole
      # sensor frame off the first read and reassembles the torn status across the
      # second and third. (Concatenating a *partial* frame in front of a complete one
      # would glue their bytes — that is corruption, not interleaving.)
      sh = div(byte_size(status), 2)
      <<s1::binary-size(sh), s2::binary>> = status
      VirtualHub.inject_wire(ctx.vhub, sensor <> s1)
      _ = :sys.get_state(ctx.owner)
      VirtualHub.inject_wire(ctx.vhub, s2)
      _ = :sys.get_state(ctx.owner)

      assert {%{az: az}, 5, _} = NodeRegistry.get(p_node, p_port)
      assert_in_delta az, 9.81, 0.001

      assert {%{applied_seq: 2}, 2, _} = NodeRegistry.get(ctx.a_node, ctx.status_port),
             "the interleaved status frame still reassembled"
    end
  end

  describe "the actuator VIEW's live/1 verdict tracks the real status stream" do
    # Unlike slice_test (which pokes the status slot directly), this drives the real
    # BB.Actuator view's freshness-gated live/1 over a status stream emitted by the
    # REAL C floor through the wire: floored → driving → back to unknown when the
    # stream goes stale. We drive the view's :status_beat by hand for determinism.
    setup ctx do
      # The actuator view's init/1 subscribes on the robot's BB PubSub, so the
      # BeamBots supervision tree must be up for this group (the floor/wire groups
      # above don't need it).
      start_supervised!(%{id: BB.Supervisor, start: {BB.Supervisor, :start_link, [@robot]}})

      {:ok, view} =
        ViewHarness.start(BBHub.Actuator,
          bb: %{robot: @robot, path: [:base_link, :drive_joint, :drive]},
          hub: :act_hub,
          port: :effort_cmd,
          status_port: :act_status,
          status_fresh_for: 2,
          # never auto-fire the status beat; we tick it explicitly
          beat_ms: 600_000
        )

      on_exit(fn -> if Process.alive?(view), do: GenServer.stop(view) end)
      {:ok, view: view}
    end

    test ":floored_or_unknown until a fresh not-floored status is witnessed, then :driving",
         ctx do
      beat = fn -> send(ctx.view, :status_beat) && :sys.get_state(ctx.view) end
      live = fn -> BBHub.Actuator.live(ViewHarness.view_state(ctx.view)) end

      # Born stale: nothing witnessed.
      beat.()
      assert live.() == :floored_or_unknown

      # Earn motion in the real C floor so it emits a fresh, advancing, not-floored
      # status stream. The view must witness an advance (born-stale) before :driving.
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      beat.()
      assert live.() == :floored_or_unknown, "first status seq is baseline — not yet trusted"

      command(ctx, 2, 0.5)
      tick_and_read(ctx, 20)
      beat.()
      assert live.() == :driving, "fresh, not-floored status from the real floor → driving"
    end

    test "when the status stream stops, live/1 returns to :floored_or_unknown (no false green)",
         ctx do
      beat = fn -> send(ctx.view, :status_beat) && :sys.get_state(ctx.view) end
      live = fn -> BBHub.Actuator.live(ViewHarness.view_state(ctx.view)) end

      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      beat.()
      command(ctx, 2, 0.5)
      tick_and_read(ctx, 20)
      beat.()
      assert live.() == :driving

      # The hub goes silent — no more status emitted (the VirtualHub stops ticking).
      # The view keeps beating; after status_fresh_for beats the leftover not-floored
      # value must NOT read as driving (the §05 false-green guard), e2e.
      beat.()
      beat.()
      beat.()

      assert live.() == :floored_or_unknown,
             "a frozen 'not floored' status must never stay a confident green"
    end
  end

  describe "host UART drop + recover (born-stale re-witness across a comms gap)" do
    test "a monitor that was fresh goes stale on a gap, then re-witnesses on recovery",
         ctx do
      # A host-side consumer of the status slot (its own born-stale monitor, ticked on
      # its own beats — the same machinery a view/observer uses).
      mon = Monitor.new(ctx.a_node, ctx.status_port, 2)

      # Status flows from the real floor → the monitor witnesses an advance → fresh.
      command(ctx, 1, 0.5)
      tick_and_read(ctx, 10)
      mon = Monitor.check(mon)
      command(ctx, 2, 0.5)
      tick_and_read(ctx, 20)
      mon = Monitor.check(mon)
      command(ctx, 3, 0.5)
      tick_and_read(ctx, 40)
      mon = Monitor.check(mon)
      assert Monitor.fresh?(mon), "fresh while status flows"

      # UART DROP: the transport dies. No new status reaches the registry.
      GenServer.stop(ctx.owner)

      # The consumer keeps beating against the frozen slot → goes stale within
      # fresh_for beats. A comms gap must not leave a stale value trusted.
      mon = mon |> Monitor.check() |> Monitor.check() |> Monitor.check()
      refute Monitor.fresh?(mon), "a dropped link makes the consumer go stale"

      # RECOVER: a fresh host stack + VirtualHub comes up (a new root-hub link). The
      # status stream resumes and the SAME consumer must RE-WITNESS an advance before
      # it trusts again — born-stale across the gap, not an instant re-trust.
      {:ok, owner2} =
        LinkOwner.start_link(
          transport: VirtualHub,
          transport_opts: [ports: [{ctx.a_node, ctx.eff_port, @window_ms, ctx.status_port}]],
          command_slots: [{ctx.a_node, ctx.eff_port}],
          name: nil
        )

      vhub2 = :sys.get_state(owner2).transport
      on_exit(fn -> if Process.alive?(owner2), do: GenServer.stop(owner2) end)
      ctx2 = %{ctx | owner: owner2, vhub: vhub2}

      command(ctx2, 10, 0.5)
      tick_and_read(ctx2, 100)
      mon = Monitor.check(mon)
      command(ctx2, 11, 0.5)
      tick_and_read(ctx2, 120)
      mon = Monitor.check(mon)

      assert Monitor.fresh?(mon),
             "after recovery the consumer re-witnesses an advance and trusts again"
    end
  end

  # Every way the framing seam can reject a frame, summed — so an assertion about
  # "a corrupted frame is dropped + counted" doesn't depend on WHICH counter
  # (rx_drop / crc_fail / cobs_truncated) a particular corruption happens to hit.
  defp total_dropped, do: Stats.get(:rx_drop) + Stats.get(:crc_fail) + Stats.get(:cobs_truncated)

  # Flip one byte in the middle of a wire frame (before its trailing 0x00 delimiter),
  # corrupting the CRC-covered body without removing the delimiter.
  defp flip_a_byte(wire) do
    mid = div(byte_size(wire), 2)
    <<pre::binary-size(mid), b, post::binary>> = wire
    <<pre::binary, Bitwise.bxor(b, 0xFF), post::binary>>
  end
end
