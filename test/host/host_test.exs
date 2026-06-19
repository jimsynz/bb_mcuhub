defmodule BBMcuhub.HostTest do
  @moduledoc """
  Proves the generic launcher derives command slots from a robot's IR (ADR-0003),
  not from a hand-listed set of ports. A command slot is the wire `{node,
  port_id}` of every actuator command port (`dir: :in` AND `safe_action != nil`).
  """
  # Not async: command_slots/1 builds the global PortIndex (:persistent_term).
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host
  alias BBMcuhub.Robots.SegbyV1
  alias BBMcuhub.Test.Fixtures.Robot, as: FixtureRobot

  describe "command_slots/1 derives actuator command slots from the IR" do
    test "segby_v1 derives its two wheel slots (equal to the resolved wheel ids)" do
      slots = Host.command_slots(SegbyV1)

      # both wheels, in {node, port_id} order (the IR is sorted by that key)
      assert slots == [{0x05, 0x18}, {0x05, 0xE0}]

      # and those are exactly the resolved wheels/motor_left + wheels/motor_right
      {:ok, left} = PortIndex.resolve(:wheels, :motor_left)
      {:ok, right} = PortIndex.resolve(:wheels, :motor_right)
      assert slots == [left, right]
    end

    test "the segby wrapper's no-arg command_slots/0 returns the same derived slots" do
      assert SegbyV1.Host.command_slots() == Host.command_slots(SegbyV1)
    end

    test "every derived slot is a floored command port (dir: :in, safe_action != nil)" do
      ir = BBMcuhub.Robot.Info.ir(SegbyV1)
      derived = MapSet.new(Host.command_slots(SegbyV1))

      for row <- ir, MapSet.member?(derived, {row.node, row.port_id}) do
        assert row.dir == :in
        assert row.safe_action != nil
      end

      # nothing that is NOT a floored command port leaks into the slots
      non_command =
        ir
        |> Enum.reject(&(&1.dir == :in and &1.safe_action != nil))
        |> Enum.map(&{&1.node, &1.port_id})
        |> MapSet.new()

      assert MapSet.disjoint?(derived, non_command)
    end

    test "the fixture robot derives its single actuator command slot (generic, not segby-specific)" do
      # The same derivation applied to a DIFFERENT robot yields that robot's one
      # actuator — proving it is generic, not hardcoded to segby's wheels.
      assert Host.command_slots(FixtureRobot) == [{0x05, 0x7B}]
      {:ok, effort} = PortIndex.resolve(:act_hub, :effort_cmd)
      assert Host.command_slots(FixtureRobot) == [effort]
    end
  end

  # A sensor-only robot (no actuators) would yield `[]` and a telemetry-only
  # LinkOwner that watches nothing — a VALID config, not an error (so the function
  # returns `[]`, never raises). Both robots present here have actuators, so the
  # empty-list path is asserted via the moduledoc contract rather than a fixture.
end
