defmodule SegbyV1.ValueTypes.Led do
  @moduledoc """
  The `led` value-type (§09) — a WS2812 status command, an RGB triple `{r, g, b}`
  as three `:u8`s (segby_v1's decorative status strip's command payload).

  This is a CONSUMER-defined value-type (`use BBMcuhub.ValueType`): the library
  ships only `imu`/`effort`/`status` as stock, and segby adds its own here with no
  library edit. A port names it BY MODULE (`type: SegbyV1.ValueTypes.Led`), which
  `BBMcuhub.ValueType.resolve/1` passes through unchanged.

  Led is a command value-type that names its OWN command message,
  `SegbyV1.Messages.LedColor` (`command_message/0`) — a consumer-defined `BB.Message`
  the EXAMPLE provides, since the library ships no LED/color struct. This is the full
  consumer-defined-command demonstration: an own value-type AND its own command. The
  command-port verifier requires this non-nil command_message; an actuator view may or
  may not be wired to the `status_led` port, but the value-type now has a real command
  contract either way. `lift/1`/`unlift/1` are the genuine mapping between the typed
  `LedColor` struct and the wire field map.
  """
  use BBMcuhub.ValueType

  layout(
    # WS2812 status command — an RGB triple (§09)
    r: :u8,
    g: :u8,
    b: :u8
  )

  @impl BBMcuhub.ValueType
  def lift(%{r: r, g: g, b: b}), do: %SegbyV1.Messages.LedColor{r: r, g: g, b: b}

  @impl BBMcuhub.ValueType
  def unlift(%SegbyV1.Messages.LedColor{r: r, g: g, b: b}), do: %{r: r, g: g, b: b}

  # The command struct this value-type accepts — the same struct unlift/1 matches.
  # An actuator view (if wired to status_led) derives its PubSub subscribe from this.
  @impl BBMcuhub.ValueType
  def command_message, do: SegbyV1.Messages.LedColor
end
