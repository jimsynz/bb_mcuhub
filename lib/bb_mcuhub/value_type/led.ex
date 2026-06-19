defmodule BBMcuhub.ValueType.Led do
  @moduledoc """
  The `led` value-type (§09) — a WS2812 status command, an RGB triple `{r, g, b}`
  as three `:u8`s (segby_v1's decorative status strip's command payload).

  > TEMP: this is a worked-example value-type, not a stock one. Per ADR-0003 only
  > `imu`/`effort`/`status` are stock; `led` moves out to the example app's own
  > namespace in the library/example split (Phase 5). It lives in the library for
  > now only because the in-tree example hubs still reference `:led`.

  Led is a command value-type with **no `BB.Message` form on any current value
  path**: segby_v1's `status_led` port is declared (`dir: :in`) but no actuator view
  is wired to it, so `unlift/1` is never called today and the pre-refactor codebase
  had no lift for it. To preserve that behaviour exactly, `lift/1`/`unlift/1` are an
  identity passthrough on the raw field map. (A real example would unlift from a
  typed command message; that is a Phase-5 decision once `led` moves into the
  example.)
  """
  use BBMcuhub.ValueType

  layout(
    # WS2812 status command — an RGB triple (§09)
    r: :u8,
    g: :u8,
    b: :u8
  )

  @impl BBMcuhub.ValueType
  def lift(map) when is_map(map), do: map

  @impl BBMcuhub.ValueType
  def unlift(map) when is_map(map), do: map
end
