defmodule BBMcuhub.Hubs.Motor.Floor do
  @moduledoc """
  The host-side reference of the motor floor's decision (§05).

  The authoritative floor lives on the actuator hub's own chip (`hubs/motor/mcu/
  floor.c` via `firmware/src/floor.c`). This pure module mirrors its logic so the
  born-disarmed / dead-man behaviour can be reasoned about and tested on the host,
  and so a host-based actuator sim degrades the same way the device does.

  Pure: `step/2` takes the floor state and an observation and returns the next
  state plus the value to drive. Born-disarmed, strict (a single command seq is a
  baseline; a *second, distinct* seq earns motion), fail-passive on silence — the
  same choice as `BBMcuhub.Host.Monitor` (§04).
  """

  @enforce_keys [:window, :safe_action]
  defstruct [
    :window,
    :safe_action,
    last_seq: nil,
    have_baseline?: false,
    seen_advance?: false,
    last_advance_t: 0,
    armed?: false
  ]

  @type t :: %__MODULE__{
          window: pos_integer(),
          safe_action: number(),
          last_seq: 0..0xFFFF | nil,
          have_baseline?: boolean(),
          seen_advance?: boolean(),
          last_advance_t: number(),
          armed?: boolean()
        }

  @doc "A born-disarmed floor with `window` (time units) and a `safe_action`."
  @spec new(pos_integer(), number()) :: t()
  def new(window, safe_action), do: %__MODULE__{window: window, safe_action: safe_action}

  @doc """
  One tick at time `now` given the latest command `{seq, target}` (or `:none` if
  no command has been seen). Returns `{drive_value, next_floor}`.
  """
  @spec step(t(), {0..0xFFFF, number()} | :none, number()) :: {number(), t()}
  def step(%__MODULE__{} = f, command, now) do
    f = observe(f, command, now)
    fresh? = f.seen_advance? and now - f.last_advance_t < f.window

    if fresh? do
      target = elem(command, 1)
      {target, %{f | armed?: true}}
    else
      {f.safe_action, %{f | armed?: false}}
    end
  end

  defp observe(f, :none, _now), do: f

  defp observe(f, {seq, _target}, now) do
    cond do
      not f.have_baseline? ->
        %{f | have_baseline?: true, last_seq: seq}

      seq != f.last_seq ->
        %{f | last_seq: seq, seen_advance?: true, last_advance_t: now}

      true ->
        f
    end
  end
end
