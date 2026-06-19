defmodule SegbyV1.RobotTest do
  @moduledoc """
  The segby_v1 robot (§09) compiles clean — its compile-time verifier did NOT
  raise, which is the proof the topology is well-formed: reconciliation, unique
  non-reserved nodes (0x02/0x05), no `port_id` collision, every `fresh_for >= 1`.
  (A malformed segby would fail to compile and this file would never load.)

  Beyond that, this asserts the IR `SegbyV1.Robot` projects (§06): the two-hub,
  dual-port-one-node, UART-backplane shape locked for segby_v1.

    * Blaster (NODE 0x02), the root comms hub: `pose` (out/imu, stamped),
      `range_front` (out/`SegbyV1.ValueTypes.Range`), `status_led`
      (in/`SegbyV1.ValueTypes.Led`, decorative — no floor).
    * Wheels (NODE 0x05), ONE Dual FOC leaf driving both wheels: `motor_left` /
      `motor_right` (in/effort, each its own floor) + `status_left` /
      `status_right` (out/status).

  The range/led ports name CONSUMER-defined value-types BY MODULE (the extension
  seam, ADR-0003): `BBMcuhub.ValueType.resolve/1` passes a module through, so the
  IR carries the module as the port's `type`.

  Both hubs sit on a `:uart` backplane (no CAN transceiver, §03/ADR-0002).
  """
  use ExUnit.Case, async: true

  alias BBMcuhub.Robot.Info

  @robot SegbyV1.Robot

  setup_all do
    ir = Info.ir(@robot)
    # one IR row per declared hub port, keyed by {hub, port} for assertions
    %{ir: ir, by_port: Map.new(ir, &{{&1.hub, &1.port}, &1})}
  end

  test "the segby_v1 robot projects a non-empty IR (it compiled — the verifier passed)",
       %{ir: ir} do
    assert is_list(ir)
    # 3 blaster ports (pose, range_front, status_led) + 4 wheels ports
    # (motor_left/right, status_left/right)
    assert length(ir) == 7
  end

  test "every IR row carries the UART backplane (§03)", %{ir: ir} do
    assert Enum.all?(ir, &(&1.transport == :uart))
  end

  test "the Blaster (NODE 0x02) projects pose, range_front and status_led", %{by_port: by} do
    pose = Map.fetch!(by, {:blaster, :pose})
    assert pose.node == 0x02
    assert pose.dir == :out
    assert pose.type == :imu
    assert pose.transport == :uart
    # pose feeds fusion/replay, so it ships the producer's µs stamp (§04)
    assert pose.stamped == true

    range = Map.fetch!(by, {:blaster, :range_front})
    assert range.node == 0x02
    assert range.dir == :out
    # a CONSUMER value-type named BY MODULE (the extension seam) — the IR carries
    # the module as the type.
    assert range.type == SegbyV1.ValueTypes.Range
    assert range.transport == :uart

    led = Map.fetch!(by, {:blaster, :status_led})
    assert led.node == 0x02
    assert led.dir == :in
    assert led.type == SegbyV1.ValueTypes.Led
    assert led.transport == :uart
    # the LED is decorative — a command port with NO floor (§05)
    assert led.safe_action == nil
  end

  test "the Wheels (NODE 0x05) is ONE node with two command + two status ports",
       %{by_port: by} do
    left = Map.fetch!(by, {:wheels, :motor_left})
    right = Map.fetch!(by, {:wheels, :motor_right})

    for cmd <- [left, right] do
      assert cmd.node == 0x05
      assert cmd.dir == :in
      assert cmd.type == :effort
      assert cmd.transport == :uart
      # each motor carries its own floor: zero torque on command silence (§05)
      assert cmd.safe_action == :zero_torque
      # the consumer freshness window from the actuator view (§04)
      assert cmd.fresh_for == 5
    end

    # two distinct command ports under one node — each its own wire id (§03)
    assert left.port_id != right.port_id

    sl = Map.fetch!(by, {:wheels, :status_left})
    sr = Map.fetch!(by, {:wheels, :status_right})

    for status <- [sl, sr] do
      assert status.node == 0x05
      assert status.dir == :out
      assert status.type == :status
      assert status.transport == :uart
    end

    assert sl.port_id != sr.port_id
  end

  test "no two ports share a wire identity {node, port_id} (§03)", %{ir: ir} do
    ids = Enum.map(ir, &{&1.node, &1.port_id})
    assert ids == Enum.uniq(ids)
  end
end
