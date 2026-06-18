# The motor hub's contract (§06) — an act leaf that also reports its own truth.
#
#   * `motor_target` (in): an `:effort` command at 50 Hz. fresh_for: 5 and
#     safe_action: :zero_torque drive the on-chip floor (§05) — if the command
#     seq stops advancing for 5 periods, the floor de-energises and latches
#     disarmed. Born-disarmed: it earns motion only by witnessing a fresh,
#     in-window command since its own boot.
#   * `motor_status` (out): the actuator's reported truth (applied_seq, floored?)
#     at 50 Hz — the source of "is it actually driving?", read instead of
#     inferred from "we sent it a command".
%{
  hub: :motor,
  ports: %{
    motor_target: %{
      dir: :in,
      type: :effort,
      rate: 50,
      fresh_for: 5,
      safe_action: :zero_torque
    },
    motor_status: %{dir: :out, type: :status, rate: 50}
  },
  step: {BBMcuhub.Hubs.Motor.Floor, :step}
}
