defmodule SegbyV1.ValueTypes.Range do
  @moduledoc """
  The `range` value-type (§09) — a forward distance, a single `:f32` metres (the
  HC-SR04 rangefinder's reading on segby_v1).

  This is a CONSUMER-defined value-type (`use BBMcuhub.ValueType`): the library
  ships only `imu`/`effort`/`status` as stock, and segby adds its own wire
  vocabulary here with no library edit — the extension seam ADR-0003 records. A
  port names it BY MODULE (`type: SegbyV1.ValueTypes.Range`), which
  `BBMcuhub.ValueType.resolve/1` passes through unchanged.

  Range has **no `BB.Message` form on any current value path**: the only reader is
  segby_v1's `range_front` sensor view, which is never made fresh in the suite, and
  the value-type-agnostic sensor view publishes the raw field map. So `lift/1`/
  `unlift/1` are an identity passthrough on the raw `%{distance_m: …}` map rather
  than fabricating a `BB.Message.Sensor.Range` from facts (radiation type, FOV,
  min/max) the wire never carries. (A real example could lift to a typed message.)
  """
  use BBMcuhub.ValueType

  layout(
    # HC-SR04 forward distance — metres (§09)
    distance_m: :f32
  )

  @impl BBMcuhub.ValueType
  def lift(map) when is_map(map), do: map

  @impl BBMcuhub.ValueType
  def unlift(map) when is_map(map), do: map
end
