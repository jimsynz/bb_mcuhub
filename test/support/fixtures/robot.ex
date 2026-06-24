defmodule BBMCUHub.Test.Fixtures.Robot do
  @moduledoc """
  The library's **test fixture robot** (test-only — under `test/support/`, on
  `elixirc_paths` only in `:test`, so it is NOT compiled into the shipped library).

  It is a DROP-IN replacement for the retired Follower in the library's own tests
  AND a deliberately coverage-maximizing span of the wire surface (ADR-0003: the
  library is self-testing in isolation via a fresh fixture robot). It backs the
  drift, C-parity, slice, and verifier tests with no example present.

  Two hubs, chosen to span the wire surface (ADR-0006: topology is DECLARED by
  parent links, not inferred):

    * the **SensorHub** (`:sensor_hub`, NODE 0x02) is the ROOT comms hub
      (`parent: :host`) — it owns the host UART. It senses `:pose` (a stock
      `:imu` value, STAMPED with `t_dev: true`) and `:scalar` (a CUSTOM
      value-type named BY MODULE, UNSTAMPED) — covering stamped + the value-type
      extension seam.
    * the **ActuatorHub** (`:act_hub`, NODE 0x05) is the LEAF — it hangs off
      the root over a `:uart` link (`parent: :sensor_hub, uplink: :uart`). It
      takes a FLOORED `:effort` command (`has_safe_action: true, safe_action:
      %{nm: 0.0}`, ADR-0005) and reports an `:act_status` — covering the UART
      link + the floor + status + the derivable command slot the generic
      launcher finds.

  So the fixture covers a declared root + one UART-linked leaf (flipping the
  root's downlink-1 transport to UART), STAMPED and UNSTAMPED ports, a FLOORED
  actuator, and a consumer-style CUSTOM value-type — exactly the surface the
  library must test in isolation.

  Like the real robots, the hub-gateway DSL (`BBMCUHub.Dsl`) composes alongside
  BeamBots' own: `hubs do` places each hub on a NODE id; the views in `topology`
  name the hub+port they read; the extension projects both into one IR (§06).
  """
  use BB, extensions: [BBMCUHub.Dsl]

  hubs do
    # The ROOT comms hub (parent: :host) — owns the host UART (ADR-0006). It
    # senses pose/scalar; its one child act_hub hangs off it over a UART link.
    hub(:sensor_hub, BBMCUHub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
    # UART leaf — its uplink to the root is UART (flips LINK1_TRANSPORT_UART to
    # 1); covers the floor + status.
    hub(:act_hub, BBMCUHub.Test.Fixtures.ActuatorHub,
      node: 0x05,
      parent: :sensor_hub,
      uplink: :uart
    )
  end

  topology do
    link :base_link do
      # the chassis IMU — a BB.Sensor view over the sensor hub's stamped pose port
      # (the slice test's sensor path: a born-stale BB.Message.Sensor.Imu publish)
      sensor(
        :chassis_imu,
        {BBMCUHub.BBHub.Sensor, hub: :sensor_hub, port: :pose, fresh_for: 3, beat_ms: 20}
      )

      # a scalar telemetry view over the CUSTOM value-type port — proves the
      # value-type-agnostic Sensor view surfaces a consumer's own type unchanged
      # (its lift/1 is a passthrough, so the published payload is the raw map).
      sensor(
        :scalar_telemetry,
        {BBMCUHub.BBHub.Sensor, hub: :sensor_hub, port: :scalar, fresh_for: 3, beat_ms: 50}
      )

      # the actuator — a BB.Actuator view over the act hub's floored command port,
      # reading its status slot for liveness (§05). fresh_for is the command's
      # consumer window (§04); the hub's own floor is the safe-state mechanism.
      joint :drive_joint do
        type(:continuous)

        axis do
        end

        limit do
          effort(~u(10 newton_meter))
          velocity(~u(1 radian_per_second))
        end

        actuator(
          :drive,
          {BBMCUHub.BBHub.Actuator,
           hub: :act_hub, port: :effort_cmd, status_port: :act_status, fresh_for: 5}
        )

        link :drive_link do
        end
      end
    end
  end
end
