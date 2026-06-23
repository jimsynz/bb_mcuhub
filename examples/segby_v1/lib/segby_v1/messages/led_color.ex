defmodule SegbyV1.Messages.LedColor do
  @moduledoc """
  A consumer-defined `BB.Message` command for an RGB status LED.

  segby_v1's `status_led` port is a non-floored actuator whose value-type
  (`SegbyV1.ValueTypes.Led`) carries an RGB triple. The library ships no
  LED/color command struct, so the EXAMPLE defines its own here and wires
  `Led` to it (`command_message/0`) — demonstrating the full consumer path:
  an own value-type AND its own command message.

  Like `BB.Message.Actuator.Command.Effort`, this is a plain `BB.Message`
  payload: routing is by the actuator topic path the view subscribes on
  (`[:actuator | path]`), not by the struct's module namespace, so a
  consumer struct is a valid actuator command once a value-type names it.

  ## Fields

  - `r`, `g`, `b` - Channel intensities, 0-255 each.

  ## Examples

      alias BB.Message
      alias SegbyV1.Messages.LedColor

      {:ok, msg} = Message.new(LedColor, :status_strip,
        r: 0,
        g: 255,
        b: 0
      )
  """

  defstruct [:r, :g, :b]

  use BB.Message,
    schema: [
      r: [
        type: :non_neg_integer,
        required: true,
        doc: "Red channel intensity (0-255)"
      ],
      g: [
        type: :non_neg_integer,
        required: true,
        doc: "Green channel intensity (0-255)"
      ],
      b: [
        type: :non_neg_integer,
        required: true,
        doc: "Blue channel intensity (0-255)"
      ]
    ]

  @type t :: %__MODULE__{
          r: 0..255,
          g: 0..255,
          b: 0..255
        }
end
