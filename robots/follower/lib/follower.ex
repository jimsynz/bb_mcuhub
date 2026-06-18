defmodule BBMcuhub.Robots.Follower do
  @moduledoc """
  The follower robot (§09) — the design's example, defined in the BeamBots DSL.

  BeamBots sees ordinary components; it never sees the root hub, the CAN
  backplane, or the tree below it. Each hub port surfaces as a thin
  `BBMcuhub.BBHub.Sensor` / `BBMcuhub.BBHub.Actuator` view; below that seam runs
  our wire — the same COBS+CRC frame over UART to the root hub and CAN to
  everything below, carrying `seq` and `t_dev`, with the floor on the wheel hub's
  own chip.

  The IMU (NODE 0x02) senses pose; the wheel motor (NODE 0x05) takes an effort
  command and reports its own status. The host's `LinkOwner` owns the UART and is
  wired into the application supervisor (not here), so it survives a view crash.

  The hub-gateway DSL (`BBMcuhub.Dsl`) composes alongside BeamBots' own: the
  `hubs do` block places each hub on a NODE id and the views in `topology` name
  the hub+port they read. The extension projects both into one IR (§06).
  """
  use BB, extensions: [BBMcuhub.Dsl]

  hubs do
    hub :imu, BBMcuhub.Hubs.Imu, node: 0x02
    hub :motor, BBMcuhub.Hubs.Motor, node: 0x05
  end

  topology do
    link :base_link do
      # the chassis IMU — a BB.Sensor view over the imu hub's pose port
      sensor :chassis_imu,
             {BBMcuhub.BBHub.Sensor, hub: :imu, port: :pose, fresh_for: 3, beat_ms: 20}

      joint :left_wheel do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(1 radian_per_second))
        end

        # the wheel motor — a BB.Actuator view over the motor hub's command port.
        # status_port names the hub's reported-truth slot, the source of "is it
        # live?" (§05). fresh_for is the command's consumer window (§04); the hub's
        # own floor is the safe-state mechanism.
        actuator :wheel,
                 {BBMcuhub.BBHub.Actuator,
                  hub: :motor, port: :motor_target, status_port: :motor_status, fresh_for: 5}

        link :wheel_link do
        end
      end
    end
  end
end
