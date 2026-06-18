defmodule BBMcuhub.Robots.SegbyV1 do
  @moduledoc """
  The segby_v1 robot (§09) — a two-wheel self-balancing bot, defined in the
  BeamBots DSL over a UART backplane (no CAN transceiver on hand).

  BeamBots sees ordinary components; it never sees the root hub or the wire tree
  below it. Each hub port surfaces as a thin `BBMcuhub.BBHub.Sensor` /
  `BBMcuhub.BBHub.Actuator` view; below that seam runs our COBS+CRC frame over
  UART, carrying `seq` and (for the IMU) `t_dev`, with the floor on the wheels
  hub's own chip.

  Two hubs, both on a `:uart` backplane (§03/ADR-0002):

    * the **Blaster** (NODE 0x02) is the root comms hub — it senses pose (the
      MPU-9250 IMU) and a forward range (the HC-SR04), and drives a decorative
      WS2812 status strip. Its children-facing backplane to the wheels is UART.
    * the **Wheels** (NODE 0x05) is the leaf — ONE MKS Dual FOC board driving
      both wheels, so it takes two effort commands (left/right) and reports two
      statuses. Its parent link is UART.

  A balance controller is a later phase; this module wires only the sensors and
  actuators so the topology is well-formed and projects a complete IR (§06).

  The hub-gateway DSL (`BBMcuhub.Dsl`) composes alongside BeamBots' own: the
  `hubs do` block places each hub on a NODE id and the views in `topology` name
  the hub+port they read.
  """
  use BB, extensions: [BBMcuhub.Dsl]

  hubs do
    hub :blaster, BBMcuhub.Hubs.Blaster, node: 0x02, transport: :uart
    hub :wheels, BBMcuhub.Hubs.Wheels, node: 0x05, transport: :uart
  end

  topology do
    link :base_link do
      # the chassis IMU — a BB.Sensor view over the blaster hub's pose port
      sensor :chassis_imu,
             {BBMcuhub.BBHub.Sensor, hub: :blaster, port: :pose, fresh_for: 3, beat_ms: 10}

      # the forward rangefinder — a BB.Sensor view over the blaster's range port
      sensor :range_front,
             {BBMcuhub.BBHub.Sensor, hub: :blaster, port: :range_front, fresh_for: 3, beat_ms: 50}

      # left wheel — a BB.Actuator view over the wheels hub's left command port,
      # reading its left status slot for liveness (§05). fresh_for is the
      # command's consumer window (§04); the hub's own floor is the safe state.
      joint :left_wheel do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(20 radian_per_second))
        end

        actuator :left_drive,
                 {BBMcuhub.BBHub.Actuator,
                  hub: :wheels, port: :motor_left, status_port: :status_left, fresh_for: 5}

        link :left_wheel_link do
        end
      end

      # right wheel — the mirror of the left
      joint :right_wheel do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(20 radian_per_second))
        end

        actuator :right_drive,
                 {BBMcuhub.BBHub.Actuator,
                  hub: :wheels, port: :motor_right, status_port: :status_right, fresh_for: 5}

        link :right_wheel_link do
        end
      end
    end
  end
end
