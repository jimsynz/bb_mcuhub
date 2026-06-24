defmodule BBMCUHub.ValueType.Imu do
  @moduledoc """
  The `imu` value-type (§09) — a unit quaternion `(w,x,y,z)` plus two `BB.Math.Vec3`s
  (angular velocity, linear acceleration), each component an `:f32` on the wire
  (compact, one CAN-FD frame).

  The field order mirrors `BB.Message.Sensor.Imu`, so the lift is 1:1 and lossless:
  the host wraps via `BB.Math.Quaternion.new/4` and `BB.Math.Vec3.new/3` and reads
  back through the accessors. `Quaternion.new` normalises, which is exact for the
  already-unit orientations an IMU produces.
  """
  use BBMCUHub.ValueType

  alias BB.Math.{Quaternion, Vec3}

  layout(
    # orientation — BB.Math.Quaternion (w,x,y,z), already normalised
    qw: :f32,
    qx: :f32,
    qy: :f32,
    qz: :f32,
    # angular_velocity — BB.Math.Vec3, rad/s
    wx: :f32,
    wy: :f32,
    wz: :f32,
    # linear_acceleration — BB.Math.Vec3, m/s²
    ax: :f32,
    ay: :f32,
    az: :f32
  )

  @impl BBMCUHub.ValueType
  def lift(%{
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

  @impl BBMCUHub.ValueType
  def unlift(%BB.Message.Sensor.Imu{
        orientation: orientation,
        angular_velocity: angular_velocity,
        linear_acceleration: linear_acceleration
      }) do
    %{
      qw: Quaternion.w(orientation),
      qx: Quaternion.x(orientation),
      qy: Quaternion.y(orientation),
      qz: Quaternion.z(orientation),
      wx: Vec3.x(angular_velocity),
      wy: Vec3.y(angular_velocity),
      wz: Vec3.z(angular_velocity),
      ax: Vec3.x(linear_acceleration),
      ay: Vec3.y(linear_acceleration),
      az: Vec3.z(linear_acceleration)
    }
  end
end
