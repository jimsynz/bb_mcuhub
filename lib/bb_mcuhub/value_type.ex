defmodule BBMCUHub.ValueType do
  @moduledoc """
  A value-type — the wire-vocabulary extensibility seam (§06/ADR-0003).

  A value-type is a standalone, reusable module owning *what bytes a kind of value
  puts on the wire and how those bytes become a typed `BB.Message`* — and nothing
  else. It carries three things:

    1. an ordered `[{field, wire_type}]` **layout** (the bytes on the wire);
    2. a host-side `lift/1` (raw `%{field => number}` map → a typed `BB.Message`
       payload struct) and its inverse `unlift/1`;
    3. the **firmware-hook shape**: the same `layout/0` drives the generator's C
       side — it emits the packed value struct (`wire_contract.h`) and, from that
       layout, the device-hook parameter (a single numeric field → the scalar by
       value, a multi-field value → a `const <Struct> *`; see the generator's
       `drive_param`). The value-type owns this contract; the generator realises
       it. Hand-written hooks live in `mcu/<hub>.{c,cpp}` against those prototypes.

  It names no node, pin, rate, or bot, so the **same** value-type composes across
  many hubs and robots. A port references its value-type; the library ships a lean
  stock set (`imu`, `effort`, `status`) and a consumer adds their own value-type in
  their own project with no library edit — exactly the seam ADR-0003 records.

  ## Authoring one

      defmodule MyApp.ValueType.Range do
        use BBMCUHub.ValueType

        layout distance_m: :f32

        @impl true
        def lift(%{distance_m: d}), do: %BB.Message.Sensor.Range{range: d, ...}

        @impl true
        def unlift(%BB.Message.Sensor.Range{range: d}), do: %{distance_m: d}
      end

  `use BBMCUHub.ValueType` defines `layout/0` from the `layout ...` declaration and
  registers the behaviour; `lift/1` and `unlift/1` are normal `@impl` functions the
  module implements.

  ## Resolution (atom → module)

  For ergonomics the authored DSL surface keeps the stock atom names (`:imu`,
  `:effort`, …) — hub modules write `type: :imu`. `resolve/1` maps those atoms to
  their value-type modules and passes modules through unchanged, so the codec,
  views, and generator all reach `layout/0`/`lift/1`/`unlift/1` through one seam.
  """

  @type wire_type :: BBMCUHub.Contract.Layouts.wire_type()
  @type layout :: BBMCUHub.Contract.Layouts.layout()

  @doc "The ordered `{field, wire_type}` layout — the bytes this value puts on the wire."
  @callback layout() :: layout()

  @doc "A raw `%{field => number}` slot map → a typed `BB.Message` payload (host-side)."
  @callback lift(map()) :: struct() | map()

  @doc "The inverse of `lift/1`: a typed `BB.Message` payload → a raw `%{field => number}` map."
  @callback unlift(struct() | map()) :: map()

  @doc """
  The `BB.Message` command struct this value-type accepts, or `nil`.

  A **command** value-type (placed on a `dir: :in` port) overrides this to return
  the `BB.Message` struct module its `unlift/1` pattern-matches — the same struct a
  BeamBots controller publishes. The actuator **Component** derives its PubSub
  subscribe `message_types` from this, so a consumer's own command flows through the
  generic view, never a hard-coded `Effort` (finding #1 / the agnostic Component).

  A **sense/status** value-type leaves it `nil` (the overridable default): it puts
  no command on the wire, so it has no command message. The verifier requires a
  non-`nil` `command_message` on every `dir: :in` port, so a sense value-type on a
  command port fails loud at compile time.
  """
  @callback command_message() :: module() | nil

  # The stock value-types the library ships (ADR-0003: imu, effort, status).
  # Anything else is a CONSUMER-defined value-type, named by MODULE (the example's
  # SegbyV1.ValueTypes.{Range,Led}, the fixture's Scalar) — resolved by the
  # module-passthrough clause below, no stock entry needed.
  @stock %{
    imu: BBMCUHub.ValueType.Imu,
    effort: BBMCUHub.ValueType.Effort,
    status: BBMCUHub.ValueType.Status
  }

  @doc """
  Resolve a value-type reference to its module.

  A stock atom (`:imu`, `:effort`, `:status`) maps to its value-type module; a
  module is passed through unchanged, so a consumer can name their own value-type
  module directly.
  """
  @spec resolve(atom() | module()) :: module()
  def resolve(ref) when is_map_key(@stock, ref), do: Map.fetch!(@stock, ref)
  def resolve(module) when is_atom(module), do: module

  @doc """
  Does this reference resolve to a REAL value-type module?

  A reference is real iff `resolve/1` yields a loaded module that implements the
  value-type behaviour — i.e. exports `layout/0`. A typo'd stock atom (`:effor`)
  resolves to the bare atom `:effor`, which exports no `layout/0`, so this returns
  `false` — letting the verifier reject it at compile time with a named error
  rather than crashing late in the generator/codec (parse-don't-scan, finding #6).
  """
  @spec resolved?(atom() | module()) :: boolean()
  def resolved?(ref) do
    module = resolve(ref)
    Code.ensure_loaded?(module) and function_exported?(module, :layout, 0)
  end

  @doc "The stock atom → module aliases (read-only; for introspection/tests)."
  @spec stock() :: %{atom() => module()}
  def stock, do: @stock

  defmacro __using__(_opts) do
    quote do
      @behaviour BBMCUHub.ValueType

      import BBMCUHub.ValueType, only: [layout: 1]

      # Every value-type gets `command_message/0` without being forced to implement
      # it — a sense/status value-type leaves this nil; a COMMAND value-type defines
      # its own `def command_message`, which overrides this default (the
      # `defoverridable` idiom). The verifier requires a non-nil command_message on
      # every command (:in) port, so the default is only valid on sense/status ports.
      @impl BBMCUHub.ValueType
      def command_message, do: nil
      defoverridable command_message: 0
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
      @impl BBMCUHub.ValueType
      def layout, do: unquote(fields)
    end
  end
end
