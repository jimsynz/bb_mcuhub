defmodule BBMcuhub.ValueType do
  @moduledoc """
  A value-type — the wire-vocabulary extensibility seam (§06/ADR-0003).

  A value-type is a standalone, reusable module owning *what bytes a kind of value
  puts on the wire and how those bytes become a typed `BB.Message`* — and nothing
  else. It carries three things:

    1. an ordered `[{field, wire_type}]` **layout** (the bytes on the wire);
    2. a host-side `lift/1` (raw `%{field => number}` map → a typed `BB.Message`
       payload struct) and its inverse `unlift/1`;
    3. (the firmware-hook signature — Phase 3, not yet).

  It names no node, pin, rate, or bot, so the **same** value-type composes across
  many hubs and robots. A port references its value-type; the library ships a lean
  stock set (`imu`, `effort`, `status`) and a consumer adds their own value-type in
  their own project with no library edit — exactly the seam ADR-0003 records.

  ## Authoring one

      defmodule MyApp.ValueType.Range do
        use BBMcuhub.ValueType

        layout distance_m: :f32

        @impl true
        def lift(%{distance_m: d}), do: %BB.Message.Sensor.Range{range: d, ...}

        @impl true
        def unlift(%BB.Message.Sensor.Range{range: d}), do: %{distance_m: d}
      end

  `use BBMcuhub.ValueType` defines `layout/0` from the `layout ...` declaration and
  registers the behaviour; `lift/1` and `unlift/1` are normal `@impl` functions the
  module implements.

  ## Resolution (atom → module)

  For ergonomics the authored DSL surface keeps the stock atom names (`:imu`,
  `:effort`, …) — hub modules write `type: :imu`. `resolve/1` maps those atoms to
  their value-type modules and passes modules through unchanged, so the codec,
  views, and generator all reach `layout/0`/`lift/1`/`unlift/1` through one seam.
  """

  @type wire_type :: BBMcuhub.Contract.Layouts.wire_type()
  @type layout :: BBMcuhub.Contract.Layouts.layout()

  @doc "The ordered `{field, wire_type}` layout — the bytes this value puts on the wire."
  @callback layout() :: layout()

  @doc "A raw `%{field => number}` slot map → a typed `BB.Message` payload (host-side)."
  @callback lift(map()) :: struct() | map()

  @doc "The inverse of `lift/1`: a typed `BB.Message` payload → a raw `%{field => number}` map."
  @callback unlift(struct() | map()) :: map()

  # The stock value-types the library ships (ADR-0003: imu, effort, status).
  @stock %{
    imu: BBMcuhub.ValueType.Imu,
    effort: BBMcuhub.ValueType.Effort,
    status: BBMcuhub.ValueType.Status,
    # TEMP: moves to the example in the library/example split (Phase 5).
    range: BBMcuhub.ValueType.Range,
    # TEMP: moves to the example in the library/example split (Phase 5).
    led: BBMcuhub.ValueType.Led
  }

  @doc """
  Resolve a value-type reference to its module.

  A stock atom (`:imu`, `:effort`, `:status`, and — until Phase 5 — `:range`,
  `:led`) maps to its value-type module; a module is passed through unchanged, so a
  consumer can name their own value-type module directly.
  """
  @spec resolve(atom() | module()) :: module()
  def resolve(ref) when is_map_key(@stock, ref), do: Map.fetch!(@stock, ref)
  def resolve(module) when is_atom(module), do: module

  @doc "The stock atom → module aliases (read-only; for introspection/tests)."
  @spec stock() :: %{atom() => module()}
  def stock, do: @stock

  defmacro __using__(_opts) do
    quote do
      @behaviour BBMcuhub.ValueType

      import BBMcuhub.ValueType, only: [layout: 1]
    end
  end

  @doc """
  Declare this value-type's ordered wire layout.

  `layout qw: :f32, qx: :f32, ...` defines `layout/0` returning that ordered
  `[{field, wire_type}]` list — the single declaration the C struct, the Elixir
  codec, and the parity bytes all derive from.
  """
  defmacro layout(fields) do
    quote do
      @impl BBMcuhub.ValueType
      def layout, do: unquote(fields)
    end
  end
end
