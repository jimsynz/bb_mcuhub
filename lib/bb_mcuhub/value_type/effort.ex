defmodule BBMcuhub.ValueType.Effort do
  @moduledoc """
  The `effort` value-type (§09) — a single `:f32` torque/force in motor-space,
  mirroring `BB.Message.Actuator.Command.Effort`.

  This is a command value-type: the actuator view is the single writer of its slot,
  so the hot path is `unlift/1` (a published `Effort` → the wire field map). `lift/1`
  is the inverse, for symmetry and host-side replay.
  """
  use BBMcuhub.ValueType

  layout(
    # BB.Message.Actuator.Command.Effort.effort — Nm or N, motor-space
    nm: :f32
  )

  @impl BBMcuhub.ValueType
  def lift(%{nm: nm}), do: %BB.Message.Actuator.Command.Effort{effort: nm}

  @impl BBMcuhub.ValueType
  def unlift(%BB.Message.Actuator.Command.Effort{effort: nm}), do: %{nm: nm * 1.0}
end
