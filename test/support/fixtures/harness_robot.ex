defmodule BBMCUHub.Test.Fixtures.HarnessRobot do
  @moduledoc """
  A **view-less** twin of `BBMCUHub.Test.Fixtures.Robot` (test-only) — same hubs,
  same NODE/PORT layout, but a topology that declares the link/joint structure and
  **no sensor/actuator view child_specs**.

  Why it exists: several tests start `BB.Supervisor` only to get a real PubSub +
  robot registration, then drive a `ViewHarness` view by hand. On the standard
  fixture, `BB.Supervisor` ALSO starts that robot's production views — so the
  supervised actuator view and the harness view would both claim one command slot,
  which the sole-writer capability (§07, candidate 5) correctly refuses. Pointing
  those tests at this view-less robot means BB.Supervisor starts the infrastructure
  but no competing views, so the harness view is the **one** writer — exactly as in
  production (one view per slot).

  The hubs (and therefore the IR / PortIndex slots) are identical to the standard
  fixture, so `PortIndex.build/1` and `resolve/2` behave the same. The verifier is
  satisfied because reconciliation is reader→producer: a producer with no reader
  view is well-formed (a view-less robot is just an unmonitored producer set).
  """
  use BB, extensions: [BBMCUHub.Dsl]

  hubs do
    hub(:sensor_hub, BBMCUHub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)

    hub(:act_hub, BBMCUHub.Test.Fixtures.ActuatorHub,
      node: 0x05,
      parent: :sensor_hub,
      uplink: :uart
    )
  end

  topology do
    # the same structural skeleton as the standard fixture, but with NO view
    # child_specs — BB.Supervisor starts no views, so a harness view is the sole
    # writer of any slot the test drives.
    link :base_link do
      joint :drive_joint do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(1 radian_per_second))
        end

        link :drive_link do
        end
      end
    end
  end
end
