defmodule SegbyV1.Test.HarnessRobot do
  @moduledoc """
  A **view-less** twin of `SegbyV1.Robot` (test-only) — same hubs, same NODE/PORT
  layout, but a topology that declares the joint skeleton and **no sensor/actuator
  view child_specs**, and no controllers/commands.

  Why it exists: a test that drives a `ViewHarness` actuator view by hand needs a
  real BeamBots PubSub for the view's `BB.subscribe` to resolve — but the full
  `SegbyV1.Robot` also starts that robot's production actuator views, which would
  contend with the harness view for a command slot's sole writer (§07, candidate
  5 in bb_mcuhub). Standing up BB.Supervisor on this view-less twin gives the
  PubSub without a competing view, so the harness view is the one writer — exactly
  as in production (one view per slot). Same hubs ⇒ same PortIndex slots.
  """
  use BB, extensions: [BBMcuhub.Dsl]

  hubs do
    hub(:blaster, SegbyV1.Hubs.Blaster, node: 0x02, parent: :host)
    hub(:wheels, SegbyV1.Hubs.Wheels, node: 0x05, parent: :blaster, uplink: :uart)
  end

  topology do
    # The joint skeleton of SegbyV1.Robot with NO view child_specs — BB.Supervisor
    # starts no views, so a harness view is the sole writer of any slot it drives.
    link :base_link do
      joint :left_wheel do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(20 radian_per_second))
        end

        link :left_wheel_link do
        end
      end

      joint :right_wheel do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(20 radian_per_second))
        end

        link :right_wheel_link do
        end
      end
    end
  end
end
