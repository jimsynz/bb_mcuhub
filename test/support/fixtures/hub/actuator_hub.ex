defmodule BBMCUHub.Test.Fixtures.ActuatorHub do
  @moduledoc """
  The fixture's act hub (test-only) — an actuator that also reports its own truth.

    * `:effort_cmd` (in): an `:effort` command at 50 Hz, FLOORED with
      `has_safe_action: true, safe_action: %{nm: 0.0}` (zero torque, ADR-0005/§05).
      This is the port `slice_test`'s actuator path exercises: command → slot →
      floor, with the floor's host-side reference (`BBMCUHub.Test.Fixtures.Floor`)
      degrading on silence. It is also the single derivable command slot the
      generic `BBMCUHub.Host` launcher finds in this robot's IR (`dir: :in` AND
      `has_safe_action: true`).
    * `:act_status` (out): the actuator's reported truth (applied_seq, floored?) at
      50 Hz — the source of "is it actually driving?", read by the actuator view's
      `live/1` born-stale liveness gate (§05).

  Placed on a LEAF node with a `:uart` backplane (see the robot), so it covers the
  UART side of the wire surface (flipping BACKPLANE_TRANSPORT_UART to 1) and the
  floor + status plumbing. Both its ports are UNSTAMPED, completing the stamped vs
  unstamped span alongside the sensor hub's stamped `:pose`.
  """
  use BBMCUHub.Hub

  ports do
    port(:effort_cmd,
      dir: :in,
      type: :effort,
      rate: 50,
      has_safe_action: true,
      safe_action: %{nm: 0.0}
    )

    port(:act_status,
      dir: :out,
      type: :status,
      rate: 50
    )
  end
end
