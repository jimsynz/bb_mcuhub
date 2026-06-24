defmodule BBMCUHub.Test.Fixtures.SensorHub do
  @moduledoc """
  The fixture's sense hub (test-only) — a coverage-maximizing producer.

  Two OUT ports, deliberately spanning the stamped/unstamped + stock/custom axes:

    * `:pose` — an `:imu` value (stock type), `t_dev: true` (STAMPED), 50 Hz. This
      is the port `slice_test`'s sensor path exercises: a born-stale publish of a
      `BB.Message.Sensor.Imu`. Mirrors the retired Follower IMU's `:pose`.
    * `:scalar` — a CUSTOM value-type (`BBMCUHub.Test.Fixtures.ValueType.Scalar`,
      named by MODULE, not a stock atom), `t_dev: false` (UNSTAMPED), 10 Hz. This
      proves the value-type extension seam in the library's own suite: the codec,
      the C struct, the parity bytes, and the generated glue all flow from a
      consumer-style custom type with no library edit.

  Placed on the ROOT node with a `:can` backplane (see the robot), so it covers
  the CAN/stamped side of the wire surface.
  """
  use BBMCUHub.Hub

  ports do
    port(:pose,
      dir: :out,
      type: :imu,
      rate: 50,
      t_dev: true
    )

    port(:scalar,
      dir: :out,
      type: BBMCUHub.Test.Fixtures.ValueType.Scalar,
      rate: 10
    )
  end
end
