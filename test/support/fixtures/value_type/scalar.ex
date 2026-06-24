defmodule BBMCUHub.Test.Fixtures.ValueType.Scalar do
  @moduledoc """
  A test-only **custom value-type** (`use BBMCUHub.ValueType`) — the library's own
  proof that the extension seam works in its suite without the example present
  (ADR-0003: "the library's test fixture defines its own custom type too").

  It is a single `:f32` scalar (`v`) — the smallest possible non-stock value-type.
  A port names it BY MODULE (`type: BBMCUHub.Test.Fixtures.ValueType.Scalar`), not
  by a stock atom, so it exercises `BBMCUHub.ValueType.resolve/1`'s module
  passthrough (`def resolve(module) when is_atom(module), do: module`).

  `lift/1`/`unlift/1` are a **passthrough** on the raw `%{v: float}` map — a
  scalar fixture has no natural `BB.Message` to wrap, and a passthrough is
  acceptable per the brief. The codec, the C struct, the parity bytes, and the
  generated firmware glue all derive from the one `layout/0` declaration exactly as
  they do for a stock value-type, so the seam is exercised end-to-end.
  """
  use BBMCUHub.ValueType

  layout(
    # a single scalar — torque, voltage, whatever a downstream fixture port means
    v: :f32
  )

  @impl BBMCUHub.ValueType
  def lift(%{v: v}), do: %{v: v}

  @impl BBMCUHub.ValueType
  def unlift(%{v: v}), do: %{v: v * 1.0}
end
