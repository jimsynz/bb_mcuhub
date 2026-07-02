defmodule BBMCUHub.Contract.IrRow do
  @moduledoc """
  One projected IR row — a **typed value**, not a loose map.

  An IR row is the frozen, per-port unit the generator (`BBMCUHub.Gen.WireGen`),
  the verifier (`BBMCUHub.Dsl.Verifier`), and the runtime `PortIndex` all consume.
  It is the safety-critical single source of truth that feeds the C generator, so
  an incomplete or mis-shaped row must fail at **projection time** (in
  `BBMCUHub.Dsl.IrTransformer`, with a clear message) — never late, as a `KeyError`
  deep inside a 1300-line emitter.

  ## Structural completeness vs. logical rules

  This struct enforces **structural completeness and per-field shape** through
  `@enforce_keys` and the `new/1` smart constructor: every field is present, and
  each carries a value of the right basic kind (a `node` in `0..255`, a `dir` of
  `:in | :out`, a `layout` that is a list of `{field, wire_type}` pairs, …). A row
  that cannot be built this way is a bug in the projection, raised on the spot.

  It deliberately does **not** re-implement the *logical, cross-field* rules — the
  `has_safe_action` floored-role contract, topology well-formedness,
  reader↔producer reconciliation, the frame-size ceiling. Those stay in
  `BBMCUHub.Dsl.Verifier`, which already raises a `Spark.Error.DslError` naming the
  offending `(hub, port)`. The split is: the struct guarantees the row is
  *well-formed*; the verifier guarantees the model is *well-configured*.

  Because struct field access (`row.node`) is identical to map access, every
  consumer that reads a row is unchanged — only construction is now gated.
  """

  alias BBMCUHub.Contract.Layouts

  @enforce_keys [
    :hub,
    :node,
    :parent,
    :uplink,
    :port,
    :port_id,
    :dir,
    :type,
    :layout,
    :stamped,
    :rate,
    :fresh_for,
    :has_safe_action,
    :safe_action
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hub: atom(),
          node: 0..255,
          parent: atom(),
          uplink: :can | :uart | nil,
          port: atom(),
          port_id: 0..255,
          dir: :in | :out,
          type: atom(),
          layout: Layouts.layout(),
          stamped: boolean(),
          rate: pos_integer(),
          fresh_for: pos_integer() | nil,
          has_safe_action: boolean() | nil,
          safe_action: %{atom() => number()} | nil
        }

  @doc """
  Build an IR row from a field map, validating structural completeness and the
  basic shape of every field. Raises `ArgumentError` (naming the `(hub, port)` and
  the offending field) if the projection produced a malformed row — a should-never-
  happen that, unguarded, would otherwise surface as a late crash in the generator.
  """
  @spec new(map()) :: t()
  def new(fields) when is_map(fields) do
    missing = @enforce_keys -- Map.keys(fields)

    if missing != [] do
      raise ArgumentError,
            "IR row #{label(fields)} is missing field(s) #{inspect(missing)} — " <>
              "the projection (BBMCUHub.Dsl.IrTransformer) must populate every IR field"
    end

    row = struct!(__MODULE__, fields)
    validate!(row)
    row
  end

  # Per-field shape checks — each illegal value names the row and the field. These
  # catch a projection bug (a wrong type, a nil where a value is required), not a
  # user authoring mistake (that is the verifier's job, with DslError messages).
  defp validate!(%__MODULE__{} = r) do
    check!(r, :node, r.node in 0..255, "must be a NODE id in 0..255")
    check!(r, :port_id, r.port_id in 0..255, "must be a PORT id in 0..255")
    check!(r, :hub, is_atom(r.hub) and not is_nil(r.hub), "must be the hub name atom")
    check!(r, :port, is_atom(r.port) and not is_nil(r.port), "must be the port name atom")
    check!(r, :parent, is_atom(r.parent) and not is_nil(r.parent), "must be the parent atom")
    check!(r, :uplink, r.uplink in [:can, :uart, nil], "must be :can | :uart | nil")
    check!(r, :dir, r.dir in [:in, :out], "must be :in | :out")
    check!(r, :type, is_atom(r.type) and not is_nil(r.type), "must be a value-type ref atom")
    check!(r, :layout, layout?(r.layout), "must be a [{field, wire_type}] layout")
    check!(r, :stamped, is_boolean(r.stamped), "must be a boolean")
    check!(r, :rate, is_integer(r.rate) and r.rate > 0, "must be a positive sample/command rate")

    check!(
      r,
      :fresh_for,
      is_nil(r.fresh_for) or (is_integer(r.fresh_for) and r.fresh_for >= 1),
      "must be nil or a freshness window >= 1"
    )

    check!(
      r,
      :has_safe_action,
      is_nil(r.has_safe_action) or is_boolean(r.has_safe_action),
      "must be nil or a boolean (the floored-role flag, ADR-0005)"
    )

    check!(
      r,
      :safe_action,
      is_nil(r.safe_action) or is_map(r.safe_action),
      "must be nil or a %{field => number} value-type value (ADR-0005)"
    )

    r
  end

  defp check!(_r, _field, true, _why), do: :ok

  defp check!(r, field, false, why) do
    raise ArgumentError,
          "IR row #{label(r)} field #{inspect(field)} #{why} — got #{inspect(Map.get(r, field))}"
  end

  # A layout is a list of {atom field, known wire_type} pairs.
  defp layout?(layout) when is_list(layout) do
    Enum.all?(layout, fn
      {field, wt} when is_atom(field) -> Map.has_key?(Layouts.widths(), wt)
      _ -> false
    end)
  end

  defp layout?(_), do: false

  defp label(%__MODULE__{hub: hub, port: port}), do: inspect({hub, port})
  defp label(fields) when is_map(fields), do: inspect({fields[:hub], fields[:port]})
end
