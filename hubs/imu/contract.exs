# The IMU hub's contract (§06) — travels with the hub, feeds the generator.
#
# A sense-only leaf: it produces an `:imu` value (full orientation + angular
# velocity + linear acceleration, mirroring BB.Message.Sensor.Imu) at 50 Hz on
# its `:pose` port. The pure sampler turns a raw read into {:ok, value} |
# :invalid; the framework owns the scheduler, the link, and the seq.
%{
  hub: :imu,
  ports: %{
    # t_dev: true — pose feeds fusion/replay, so it carries the producer's µs
    # stamp (§04). Command and status ports omit t_dev and stay small.
    pose: %{dir: :out, type: :imu, rate: 50, t_dev: true}
  },
  sample: {BBMcuhub.Hubs.Imu.SamplePose, :sample}
}
