defmodule SegbyV1.Hubs.Blaster do
  @moduledoc """
  The Blaster hub (§09) — segby_v1's ROOT hub on a DOIT V1 ESP32.

  The comms hub that owns segby's direct peripherals and bridges down to the
  wheels leaf over a UART backplane:

    * `pose` (out): a full `:imu` value (orientation + angular velocity + linear
      acceleration, mirroring `BB.Message.Sensor.Imu`) at 100 Hz from the
      MPU-9250. Carries `t_dev: true` — it feeds the balance estimator's
      fusion/replay, so it ships the producer's µs stamp (§04).
    * `range_front` (out): a `SegbyV1.ValueTypes.Range` value (forward distance,
      metres) at 20 Hz from the HC-SR04 rangefinder — a CONSUMER-defined
      value-type named BY MODULE (the extension seam, ADR-0003).
    * `status_led` (in): a `SegbyV1.ValueTypes.Led` command (an RGB triple)
      driving the WS2812 status strip — also a consumer value-type. It is
      decorative — not a motor — so it declares `has_safe_action: false` (a
      non-floored actuator, ADR-0005): no floor, no safe_action; a stale LED
      command is harmless.

  The declared `sample` MFA refs are data only; the firmware has the on-device
  equivalents under `firmware/mcu/blaster.cpp`.
  """
  use BBMCUHub.Hub

  ports do
    port(:pose,
      dir: :out,
      type: :imu,
      rate: 100,
      t_dev: true,
      sample: {SegbyV1.Hubs.Blaster.SamplePose, :sample}
    )

    port(:range_front,
      dir: :out,
      type: SegbyV1.ValueTypes.Range,
      rate: 20,
      sample: {SegbyV1.Hubs.Blaster.SampleRange, :sample}
    )

    port(:status_led,
      dir: :in,
      type: SegbyV1.ValueTypes.Led,
      rate: 20,
      has_safe_action: false
    )
  end
end
