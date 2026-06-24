defmodule SegbyV1.ObserveRenderer do
  @moduledoc """
  Teaches `bb_tui` how to render this robot's observer-plane samples — without
  `bb_tui` knowing anything about `BBMCUHub.Observer.Sample` (ADR-0004).

  The observer plane republishes sampled slots on `[:observe | hub, port]`
  carrying a `BBMCUHub.Observer.Sample` payload (the raw value + context). `bb_tui`
  is a generic dashboard; it must not depend on this library's payload structs. So
  the dependency is inverted via `BB.TUI.Renderer`: `bb_tui` exposes the seam, and
  *this* module — which legitimately owns the `Observer.Sample` shape, because it
  is part of the same robot app — supplies how to render it.

  Registered on the TUI's `[:observe]` prefix via the `:renderers` option (see the
  Nerves host wiring). `bb_tui` calls back here for the event-log summary and the
  at-a-glance status-bar readout; it never pattern-matches the payload itself.
  """

  @behaviour BB.TUI.Renderer

  alias BBMCUHub.Observer.Sample

  @doc """
  A one-line event-log summary for an observer sample: `hub.port` + a short
  rendering of a few of the sampled value's fields (stale slots marked).
  """
  @impl BB.TUI.Renderer
  def summarize(_path, %Sample{slot: slot, value: value, freshness: freshness}) do
    "#{stale_mark(freshness)}#{format_slot(slot)}  #{summarize_value(value)}"
  end

  def summarize(_path, _payload), do: nil

  @doc """
  Feed the status-bar readout: one entry per slot (latest overwrites), keyed by the
  symbolic `{hub, port}`, carrying the freshness + `seq` the status bar uses to pick
  the freshest slot and dim stale ones.
  """
  @impl BB.TUI.Renderer
  def observed(_path, %Sample{slot: slot, value: value, seq: seq, freshness: freshness}) do
    {slot, %{label: "#{format_slot(slot)} #{summarize_value(value)}"},
     %{freshness: freshness, seq: seq}}
  end

  def observed(_path, _payload), do: nil

  # --- formatting (this app's choice for how its values read) ---

  defp format_slot({hub, port}), do: "#{hub}.#{port}"
  defp format_slot(other), do: inspect(other)

  defp stale_mark(:stale), do: "⚠ "
  defp stale_mark(_fresh), do: ""

  # The first few fields of the sampled value map, kept short — a glanceable
  # "ax=0.250 az=9.810" rather than a full inspect.
  defp summarize_value(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.take(3)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_field(v)}" end)
  end

  defp summarize_value(value), do: inspect(value, pretty: false, limit: 8)

  defp format_field(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 3)
  defp format_field(v), do: inspect(v)
end
