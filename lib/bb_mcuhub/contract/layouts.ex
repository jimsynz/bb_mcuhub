defmodule BBMCUHub.Contract.Layouts do
  @moduledoc """
  The wire-primitive types and their byte widths (§06).

  This module owns the *primitives* a value-type's layout is built from — the
  `wire_type`/`layout` typespecs and the byte width of each wire type. The
  per-value-type layouts themselves no longer live here: each value-type module
  (`use BBMCUHub.ValueType`) owns its own ordered `[{field, wire_type}]` layout, and
  `BBMCUHub.ValueType.resolve/1` resolves a port's value-type atom to its module.
  The Elixir codec, the C struct, and the parity-vector bytes are still all derived
  from that one declaration, so a reordered field is a single-line change that
  ripples everywhere consistently.

  Wire types and their byte widths (big-endian, the network/AVR-friendly order):

      :f32 → 4 · :f64 → 8 · :u8 → 1 · :u16 → 2 · :u32 → 4 · :u64 → 8 · :bool → 1
  """

  @type wire_type :: :f32 | :f64 | :u8 | :u16 | :u32 | :u64 | :bool
  @type layout :: [{atom(), wire_type()}]

  @widths %{f32: 4, f64: 8, u8: 1, u16: 2, u32: 4, u64: 8, bool: 1}

  @doc "Byte width of a wire type."
  @spec width(wire_type()) :: pos_integer()
  def width(wire_type), do: Map.fetch!(@widths, wire_type)

  @doc "Total payload byte size of a `[{field, wire_type}]` layout."
  @spec payload_size(layout()) :: non_neg_integer()
  def payload_size(layout) do
    Enum.reduce(layout, 0, fn {_f, wt}, acc -> acc + width(wt) end)
  end

  @doc "All wire types and their widths (for the C/codec renderers)."
  @spec widths() :: %{wire_type() => pos_integer()}
  def widths, do: @widths
end
