defmodule SegbyV1.ValueTypes.Led do
  @moduledoc """
  The `led` value-type (§09) — a WS2812 status command, an RGB triple `{r, g, b}`
  as three `:u8`s (segby_v1's decorative status strip's command payload).

  This is a CONSUMER-defined value-type (`use BBMcuhub.ValueType`): the library
  ships only `imu`/`effort`/`status` as stock, and segby adds its own here with no
  library edit. A port names it BY MODULE (`type: SegbyV1.ValueTypes.Led`), which
  `BBMcuhub.ValueType.resolve/1` passes through unchanged.

  Led is a command value-type with **no `BB.Message` form on any current value
  path**: segby_v1's `status_led` port is declared (`dir: :in`) but no actuator view
  is wired to it, so `unlift/1` is never called today. So `lift/1`/`unlift/1` are an
  identity passthrough on the raw field map. (A real example could unlift from a
  typed command message.)
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
