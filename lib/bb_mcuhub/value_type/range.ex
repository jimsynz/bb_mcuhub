defmodule BBMcuhub.ValueType.Range do
  @moduledoc """
  The `range` value-type (§09) — a forward distance, a single `:f32` metres (the
  HC-SR04 rangefinder's reading on segby_v1).

  > TEMP: this is a worked-example value-type, not a stock one. Per ADR-0003 only
  > `imu`/`effort`/`status` are stock; `range` moves out to the example app's own
  > namespace in the library/example split (Phase 5). It lives in the library for
  > now only because the in-tree example hubs still reference `:range`.

  Range has **no `BB.Message` form on any current value path**: the only reader is
  segby_v1's `range_front` sensor view, which is never made fresh in the suite, and
  the pre-refactor sensor view only ever lifted `:imu`. To preserve that behaviour
  exactly, `lift/1`/`unlift/1` are an identity passthrough on the raw field map —
  the value-type-agnostic view publishes the raw `%{distance_m: …}` rather than
  fabricating a `BB.Message.Sensor.Range` from facts (radiation type, FOV, min/max)
  the wire never carries. (A real example would lift to a typed message; that is a
  Phase-5 decision once `range` moves into the example.)
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
