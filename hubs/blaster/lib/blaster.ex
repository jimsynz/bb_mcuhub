defmodule BBMcuhub.Hubs.Blaster do
  @moduledoc """
  The Blaster hub (§09) — segby_v1's ROOT hub on a DOIT V1 ESP32.

  The comms hub that owns segby's direct peripherals and bridges down to the
  wheels leaf over a UART backplane:

    * `pose` (out): a full `:imu` value (orientation + angular velocity + linear
      acceleration, mirroring `BB.Message.Sensor.Imu`) at 100 Hz from the
      MPU-9250. Carries `t_dev: true` — it feeds the balance estimator's
      fusion/replay, so it ships the producer's µs stamp (§04).
    * `range_front` (out): a `:range` value (forward distance, metres) at 20 Hz
      from the HC-SR04 rangefinder.
    * `status_led` (in): a `:led` command (an RGB triple) driving the WS2812
      status strip. It is decorative — not a motor — so it carries no
      `safe_action`/floor; a stale LED command is harmless.

  The declared `sample` MFA refs are data only; the firmware has the on-device
  equivalents under `hubs/blaster/mcu/`.
  """
  use BBMcuhub.Hub

  ports do
    port :pose,
      dir: :out,
      type: :imu,
      rate: 100,
      t_dev: true,
      sample: {BBMcuhub.Hubs.Blaster.SamplePose, :sample}

    port :range_front,
      dir: :out,
      type: :range,
      rate: 20,
      sample: {BBMcuhub.Hubs.Blaster.SampleRange, :sample}

    port :status_led,
      dir: :in,
      type: :led,
      rate: 20
  end
end
