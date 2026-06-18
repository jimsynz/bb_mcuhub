defmodule BBMcuhub.Hubs.Imu.SamplePose do
  @moduledoc """
  The IMU's pure sampler (§01/§07): raw readings → a typed `:imu` value, or
  `:invalid`. Pure — no process, no clock, no socket — so it is testable on a
  laptop and replayable from a log of values. The firmware has the on-device
  equivalent in `hubs/imu/mcu/imu_sensor.c`; this is the host-side reference and
  what a host-based sensor sim would call.
  """

  @typedoc "raw IMU read: quaternion + angular velocity (rad/s) + accel (m/s²)"
  @type raw :: %{
          q: {float(), float(), float(), float()},
          w: {float(), float(), float()},
          a: {float(), float(), float()}
        }

  @doc """
  Turn a raw read into the wire `:imu` value map (field order = the contract
  layout). Returns `:invalid` if any component is non-finite — a bad read writes
  nothing, its `seq` stalls, and the consumer goes stale (§04), never a bad pose.
  """
  @spec sample(raw()) :: {:ok, map()} | :invalid
  def sample(%{q: {qw, qx, qy, qz}, w: {wx, wy, wz}, a: {ax, ay, az}}) do
    nums = [qw, qx, qy, qz, wx, wy, wz, ax, ay, az]

    if Enum.all?(nums, &finite?/1) do
      {:ok,
       %{
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
       }}
    else
      :invalid
    end
  end

  def sample(_), do: :invalid

  defp finite?(x) when is_float(x), do: x == x and x != :infinity and x != :neg_infinity
  defp finite?(x) when is_integer(x), do: true
  defp finite?(_), do: false
end
