defmodule BBMCUHub.Observer.Sink do
  @moduledoc """
  Where an observer's samples go (ADR-0004 · "hand to a sink").

  An observer's one job is *sample + reduce + hand to a sink* — the observer
  mechanism is type-agnostic, and **what to do** with a sampled value lives here,
  in a pluggable sink (a PubSub republish, a disk log, an event database, a UI
  feed). The library ships the two general primitives (`Fun`, `PubSub`); a disk
  log / event DB is consumer territory and explicitly out of library scope
  (ADR-0004 · Consequences).

  ## Two sink shapes, one behaviour

  A sink is one of:

    * a **function sink** — a stateless `fun.(slot, value, meta)`, the simplest
      primitive, great for tests and ad-hoc wiring; wrapped by `normalize/1` into
      the stateful form below so the observer only ever calls `handle_sample/4`.
    * a **stateful sink** — `{module, state}` where `module` implements this
      behaviour. `handle_sample/4` is called per sample and returns the next sink
      state, so a sink can accumulate (a counter, a buffer, a connection handle).

  The observer keeps the sink as `{module, state}` internally and threads the
  returned state, so both shapes are uniform at the call site.

  ## The sample handed to a sink

    * `slot` — the symbolic `{hub, port}` pair the observer selected (the friendly
      form the views use; the wire `{node, port_id}` is in `meta`).
    * `value` — the **raw slot value** (the `%{field => number}` map as written by
      the link owner). v1 hands the raw value: `filter`/`project` (which would lift
      via the value-type) are deferred (ADR-0004 · "v1 does two [axes]"), so the
      observer keeps a value-type handle in `meta` for a sink that wants it, but
      does not lift for you.
    * `meta` — enough context for a sink to be useful: the wire ids, the producer's
      `seq`, the device stamp, the observer's freshness verdict, and the value-type.

  ## Sink isolation (ADR-0004 · Consequences)

  The sink runs in the **observer's own process** — a slow or blocking sink (fsync,
  DB insert, socket) degrades only *that* observer (it falls behind its timer), and
  a sink that raises crashes only *that* observer's child. It can never apply
  backpressure to the control plane: that isolation is structural (the observer
  reads via a direct `:ets.lookup`). v1 does no per-sample task spawning and no
  unbounded buffering — keep a sink bounded / non-blocking.
  """

  @typedoc "The symbolic slot an observer selected — the friendly `{hub, port}` form."
  @type slot :: {hub :: atom(), port :: atom()}

  @typedoc "The raw slot value (the `%{field => number}` map; v1 does not lift it)."
  @type value :: term()

  @typedoc """
  Per-sample context handed alongside the value:

    * `:slot` — the symbolic `{hub, port}` (same as the `slot` argument).
    * `:node`, `:port_id` — the resolved wire ids of the slot.
    * `:seq` — the producer's sequence counter for this value (§04).
    * `:t_dev` — the device stamp on the row (0 for an unstamped port).
    * `:freshness` — the observer's own born-stale verdict for this sample
      (`:fresh`; a sample is only handed to a sink when fresh, so this is always
      `:fresh` in v1, but it is carried explicitly so a sink never infers it).
    * `:value_type` — the resolved value-type MODULE for the slot (the seam
      `filter`/`project` will use; a sink may lift via it, the observer does not).
    * `:observer` — the observer's name, for a sink that fans several observers
      into one place (e.g. a topic path segment).
  """
  @type meta :: %{
          slot: slot(),
          node: 0..255,
          port_id: 0..255,
          seq: 0..0xFFFF,
          t_dev: non_neg_integer(),
          freshness: :fresh | :stale,
          value_type: module(),
          observer: term()
        }

  @typedoc "A stateful sink: a behaviour module plus its threaded state."
  @type stateful :: {module(), state :: term()}

  @typedoc "A function sink: called `fun.(slot, value, meta)`; its return is ignored."
  @type fun_sink :: (slot(), value(), meta() -> any())

  @typedoc "Any accepted sink shape, before `normalize/1`."
  @type spec :: stateful() | fun_sink()

  @doc """
  Handle one sample, returning the next sink state.

  Called in the observer's own process, once per fresh sample, for a stateful
  sink. Keep it bounded / non-blocking (see the moduledoc on isolation).
  """
  @callback handle_sample(slot(), value(), meta(), state :: term()) :: state :: term()

  # --- normalization: collapse both shapes into {module, state} ---

  @doc """
  Normalize any accepted sink `spec` into the uniform `{module, state}` form the
  observer threads.

  A `{module, state}` is returned unchanged. A bare function `fun/3` is wrapped in
  `#{inspect(__MODULE__)}.Fun` with the function as its (immutable) state — so the
  observer has exactly one call shape (`handle_sample/4`) regardless of which shape
  the caller passed.
  """
  @spec normalize(spec()) :: stateful()
  def normalize({module, _state} = stateful) when is_atom(module), do: stateful

  def normalize(fun) when is_function(fun, 3), do: {__MODULE__.Fun, fun}

  @doc """
  Invoke a normalized `{module, state}` sink for one sample, returning the next
  `{module, state}`.
  """
  @spec call(stateful(), slot(), value(), meta()) :: stateful()
  def call({module, state}, slot, value, meta) do
    {module, module.handle_sample(slot, value, meta, state)}
  end
end
