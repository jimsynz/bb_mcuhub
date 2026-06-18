defmodule BBMcuhub.Hubs.Wheels do
  @moduledoc """
  The Wheels hub (§09) — segby_v1's LEAF hub on an MKS Dual FOC v3.2 ESP32.

  ONE node driving BOTH wheels: the Dual FOC board runs SimpleFOC on two
  motors (M0 = left, M1 = right), so a single hub exposes two independent
  command ports and two status ports — each motor its own slot and its own
  on-chip floor (§05).

    * `motor_left` / `motor_right` (in): an `:effort` command at 50 Hz each.
      `safe_action: :zero_torque` drives each motor's own on-chip floor (§05);
      the consumer freshness window (`fresh_for`) lives on the actuator views in
      the robot topology, not here.
    * `status_left` / `status_right` (out): each motor's reported truth
      (applied_seq, floored?) at 50 Hz — the source of "is it actually
      driving?", read instead of inferred from "we sent a command".

  The declared `step` MFA refs are data only; the authoritative floors live on
  the Dual FOC board's own chip (`hubs/wheels/mcu/`).
  """
  use BBMcuhub.Hub

  ports do
    port :motor_left,
      dir: :in,
      type: :effort,
      rate: 50,
      safe_action: :zero_torque,
      step: {BBMcuhub.Hubs.Wheels.Floor, :step}

    port :motor_right,
      dir: :in,
      type: :effort,
      rate: 50,
      safe_action: :zero_torque,
      step: {BBMcuhub.Hubs.Wheels.Floor, :step}

    port :status_left,
      dir: :out,
      type: :status,
      rate: 50

    port :status_right,
      dir: :out,
      type: :status,
      rate: 50
  end
end
