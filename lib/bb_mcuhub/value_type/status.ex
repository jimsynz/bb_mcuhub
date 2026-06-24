defmodule BBMCUHub.ValueType.Status do
  @moduledoc """
  The `status` value-type (§05) — an actuator hub's reported truth: `applied_seq`
  plus a `floored?` flag, the authoritative source of "is this hub actually
  driving?".

  Status has **no `BB.Message` form**: the actuator view reads its fields *directly*
  from the registry slot (gated by a born-stale monitor — see
  `BBMCUHub.BBHub.Actuator.live/1`), never through `lift/1`. So `lift/1`/`unlift/1`
  are an identity passthrough on the raw field map — implemented for the behaviour's
  completeness but not on any value path today.
  """
  use BBMCUHub.ValueType

  layout(
    # the actuator's reported truth (§05)
    applied_seq: :u16,
    floored: :bool
  )

  @impl BBMCUHub.ValueType
  def lift(map) when is_map(map), do: map

  @impl BBMCUHub.ValueType
  def unlift(map) when is_map(map), do: map
end
