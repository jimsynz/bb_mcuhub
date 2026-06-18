defmodule BBMcuhub.BBHub.Lift do
  @moduledoc """
  Pure lifts between a wire **slot value** (a plain `field => number` map from the
  codec, §03) and a concrete `BB.Message` payload (§09).

  Per the project decision to reuse existing BeamBots definitions, the wire layout
  mirrors the `BB.Message` structs, so these lifts are 1:1 and lossless:

    * `:imu` slot ↔ `BB.Message.Sensor.Imu` (orientation `Quaternion`, angular
      velocity + linear acceleration `Vec3`).
    * `:effort` slot ↔ `BB.Message.Actuator.Command.Effort`.
    * `:status` slot — actuator truth; not a BB message, read directly (§05).

  Quaternion/Vec3 are Nx-tensor backed; we wrap on the way out via `new/4`/`new/3`
  and read back through the accessors. `Quaternion.new` normalises, which is exact
  for the already-unit orientations an IMU produces.
  """

  alias BB.Math.{Quaternion, Vec3}

  @doc "A wire `:imu` slot value → a `BB.Message.Sensor.Imu` payload struct."
  @spec imu_to_bb(map()) :: struct()
  def imu_to_bb(%{
        qw: qw,
        qx: qx,
        qy: qy,
        qz: qz,
        wx: wx,
        wy: wy,
        wz: wz,
        ax: ax,
        ay: ay,
        az: az
      }) do
    %BB.Message.Sensor.Imu{
      orientation: Quaternion.new(qw, qx, qy, qz),
      angular_velocity: Vec3.new(wx, wy, wz),
      linear_acceleration: Vec3.new(ax, ay, az)
    }
  end

  @doc "A `BB.Message.Actuator.Command.Effort` → a wire `:effort` slot value."
  @spec effort_from_bb(struct()) :: map()
  def effort_from_bb(%BB.Message.Actuator.Command.Effort{effort: nm}), do: %{nm: nm * 1.0}

  @doc "A wire `:effort` slot value → a `BB.Message.Actuator.Command.Effort`."
  @spec effort_to_bb(map()) :: struct()
  def effort_to_bb(%{nm: nm}), do: %BB.Message.Actuator.Command.Effort{effort: nm}
end
