defmodule BBMCUHub.Observer.Sink.Fun do
  @moduledoc """
  The function sink — the simplest sink primitive.

  A stateless sink whose "state" IS a `fun.(slot, value, meta)`: every sample is
  handed straight to that function and the same function is threaded as the next
  state (it never mutates). Great for tests (`fn slot, value, meta -> send(test,
  {:sample, slot, value, meta}) end`) and ad-hoc wiring.

  Callers rarely name this directly — `BBMCUHub.Observer.Sink.normalize/1` wraps a
  bare `fun/3` into `{#{inspect(__MODULE__)}, fun}` automatically, so an observer
  accepts `sink: fn slot, value, meta -> ... end` as-is.
  """

  @behaviour BBMCUHub.Observer.Sink

  @impl BBMCUHub.Observer.Sink
  def handle_sample(slot, value, meta, fun) when is_function(fun, 3) do
    _ = fun.(slot, value, meta)
    fun
  end
end
