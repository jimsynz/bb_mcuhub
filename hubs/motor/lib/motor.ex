defmodule BBMcuhub.Hubs.Motor do
  @moduledoc """
  The motor hub (§06) — an act leaf that also reports its own truth.

    * `motor_target` (in): an `:effort` command at 50 Hz. `safe_action:
      :zero_torque` drives the on-chip floor (§05); the consumer freshness window
      (`fresh_for`) lives on the actuator view in the robot topology, not here.
    * `motor_status` (out): the actuator's reported truth (applied_seq, floored?)
      at 50 Hz — the source of "is it actually driving?", read instead of inferred
      from "we sent it a command".

  The declared `step` MFA is data only; the authoritative floor lives on the
  motor's own chip (`hubs/motor/mcu/`).
  """
  use BBMcuhub.Hub

  ports do
    port :motor_target,
      dir: :in,
      type: :effort,
      rate: 50,
      safe_action: :zero_torque,
      step: {BBMcuhub.Hubs.Motor.Floor, :step}

    port :motor_status,
      dir: :out,
      type: :status,
      rate: 50
  end
end
