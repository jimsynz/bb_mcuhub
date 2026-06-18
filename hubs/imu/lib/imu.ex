defmodule BBMcuhub.Hubs.Imu do
  @moduledoc """
  The IMU hub (§06) — a sense-only leaf.

  It produces an `:imu` value (full orientation + angular velocity + linear
  acceleration, mirroring `BB.Message.Sensor.Imu`) at 50 Hz on its `:pose` port.
  `pose` carries `t_dev: true` — it feeds fusion/replay, so it ships the
  producer's µs stamp (§04). The declared `sample` MFA is data only; the firmware
  has the on-device equivalent in `hubs/imu/mcu/imu_sensor.c`.
  """
  use BBMcuhub.Hub

  ports do
    port :pose,
      dir: :out,
      type: :imu,
      rate: 50,
      t_dev: true,
      sample: {BBMcuhub.Hubs.Imu.SamplePose, :sample}
  end
end
