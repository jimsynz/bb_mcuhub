defmodule BBMCUHub.HostTest do
  @moduledoc """
  Proves the generic launcher derives command slots from a robot's IR (ADR-0003),
  not from a hand-listed set of ports. A command slot is the wire `{node,
  port_id}` of every actuator command port (`dir: :in` AND `has_safe_action: true`).

  The library tests this against its OWN fixture robot (segby_v1 moved to the
  example app, which tests the same derivation over its two-wheel IR).
  """
  # Not async: command_slots/1 builds the global PortIndex (:persistent_term).
  use ExUnit.Case, async: false

  alias BBMCUHub.Contract.PortIndex
  alias BBMCUHub.Host
  alias BBMCUHub.Test.Fixtures.Robot, as: FixtureRobot

  describe "command_slots/1 derives actuator command slots from the IR" do
    test "the fixture robot derives its single actuator command slot from the IR" do
      slots = Host.command_slots(FixtureRobot)

      # the one floored command port (act_hub/effort_cmd), as {node, port_id}
      assert slots == [{0x05, 0x7B}]

      # and that is exactly the resolved act_hub/effort_cmd wire id
      {:ok, effort} = PortIndex.resolve(:act_hub, :effort_cmd)
      assert slots == [effort]
    end

    test "every derived slot is a floored command port (dir: :in, has_safe_action: true)" do
      ir = BBMCUHub.Robot.Info.ir(FixtureRobot)
      derived = MapSet.new(Host.command_slots(FixtureRobot))

      for row <- ir, MapSet.member?(derived, {row.node, row.port_id}) do
        assert row.dir == :in
        assert row.has_safe_action == true
        assert row.safe_action != nil
      end

      # nothing that is NOT a floored command port leaks into the slots
      non_command =
        ir
        |> Enum.reject(&(&1.dir == :in and &1.has_safe_action == true))
        |> Enum.map(&{&1.node, &1.port_id})
        |> MapSet.new()

      assert MapSet.disjoint?(derived, non_command)
    end
  end

  # A sensor-only robot (no actuators) would yield `[]` and a telemetry-only
  # LinkOwner that watches nothing — a VALID config, not an error (so the function
  # returns `[]`, never raises). The fixture robot has an actuator, so the
  # empty-list path is asserted via the moduledoc contract rather than a fixture.
end
