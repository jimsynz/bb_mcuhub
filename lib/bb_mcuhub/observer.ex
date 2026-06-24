defmodule BBMCUHub.Observer do
  @moduledoc """
  A host-side **observer** — the observability plane's pure reader (ADR-0004,
  CONTEXT.md · *Observer*).

  An observer **samples** one or more `(node, port)` **slots** at its **own
  independent cadence** and hands each fresh value to a pluggable **sink**. It is
  categorically distinct from a Component view: a view *pushes* every control beat
  onto BeamBots' PubSub; an observer *pulls the latest* from the host registry at
  its own timer, so it **structurally cannot slow the control plane** (the
  overwrite-only slot absorbs the rate gap, and the read is a direct
  `:ets.lookup`). N observers are N independent readers; adding one costs the
  others nothing.

  v1 implements **sample-state only**, along the **sample + select** axes
  (ADR-0004): poll the slot's latest value on the observer's own beat; dropping the
  values skipped between beats is *correct* (the slot is overwrite-only-latest — you
  want "now"). The lossless **stream-events** mode and the **filter** / **project**
  axes are deferred (SAFeD); the value-type handle this observer keeps per slot is
  the seam that lets `filter` / `project` be added later without an API break.

  ## What this observer is, structurally

    * **Pure reader.** It is handed a `BBMCUHub.Host.Registry.Reader` capability —
      `get` / `dump`, no `put` — so "an observer writes a slot" is *unrepresentable*,
      not merely forbidden (the registry is `:public` ETS). It also never issues a
      command (no command/publish call lives here — only the sink may publish, on
      the observer's *own* topic).
    * **Born stale, by its own cadence.** It holds one `BBMCUHub.Host.Monitor` per
      slot at *its* `fresh_for` (in *its* beats). A value sitting in a slot from
      before this observer booted is NOT handed to the sink until the observer
      personally witnesses `seq` advance — so a restart never republishes a leftover
      reading. (An observer's freshness is NOT the control plane's: a slow observer
      may report fresh for a slot the fast loop already floored — for "is the hub
      driving" read the Status slot, never an observer's verdict. ADR-0004.)
    * **Fail-loud select.** Every selected `{hub, port}` is resolved via
      `PortIndex.resolve` at init; an unknown port **stops** the observer
      (`{:stop, {:unknown_port, {hub, port}}}`) — never silently observe a typo'd
      port forever (mirrors `BBMCUHub.BBHub.Sensor`).
    * **Sink in-process.** The sink runs in this observer's own process: a slow sink
      degrades only this observer (it falls behind its timer) and a crashing sink
      takes down only this observer's child — by design (ADR-0004 · Consequences).
      v1 spawns no per-sample tasks and adds no unbounded buffering.

  ## Options (`start_link/1`)

    * `:robot` — the robot module (REQUIRED; `PortIndex` must be built for it, which
      the `BBMCUHub.Host` launcher and test setups do).
    * `:slots` — the slots to **select**, each the symbolic `{hub, port}` pair
      (REQUIRED, non-empty). The symbolic form matches the views and is friendlier
      than the wire `{node, port_id}`; it is resolved to the wire id at init.
    * `:sink` — where samples go: a `fun.(slot, value, meta)` (the primitive) or a
      `{module, state}` stateful sink (`BBMCUHub.Observer.Sink`). REQUIRED.
    * `:sample_ms` — the sample period in ms (default `100`, ~10 Hz, a UI cadence).
      Each tick samples every selected slot once.
    * `:fresh_for` — this observer's freshness window in *its own* beats (default
      `3`). Relative to `sample_ms`, not the control loop.
    * `:name` — a name for this observer; flows into each sample's `meta.observer`
      so a sink can fan several observers apart. Defaults to the registered process
      name if any, else `nil`.
    * `:reader` — the registry capability (default `Reader.default/0`, the real
      `NodeRegistry`); a test injects a fake to script slot rows.

  ## Supervision

  `child_spec/1` uses `restart: :transient` (justified): a config error (an unknown
  slot) **fail-louds at init** and must NOT be retried forever — `:transient` does
  not restart on a normal/`{:stop, _}` shutdown, so a typo'd slot stops once and
  stays stopped, while a genuine crash (a sink raising) still restarts. Each observer
  is its own supervised child, so one crashing never takes down a view or another
  observer (ADR-0004 · Consequences). Wiring a *specific* observer into a robot's
  tree is the consumer's job (the next phase) — the library just provides this
  startable module.
  """
  use GenServer

  alias BBMCUHub.Contract.PortIndex
  alias BBMCUHub.Host.Monitor
  alias BBMCUHub.Host.Registry.Reader
  alias BBMCUHub.Observer.Sink
  alias BBMCUHub.ValueType

  @default_sample_ms 100
  @default_fresh_for 3

  # One resolved, watched slot: the symbolic pair, its wire ids, its value-type
  # handle (kept for the deferred filter/project seam — unused in v1), and its
  # born-stale monitor (advanced one beat per tick).
  @type slot_state :: %{
          slot: {atom(), atom()},
          node: 0..255,
          port_id: 0..255,
          value_type: module(),
          mon: Monitor.t()
        }

  # --- API ---

  @doc "Start an observer (see the moduledoc for options)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), gen_opts)
  end

  @doc """
  Child spec for supervising one observer.

  `restart: :transient` — a fail-loud `{:stop, {:unknown_port, _}}` at init must not
  be retried forever (a config typo stops once), while a real crash still restarts.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    # :robot is REQUIRED so a misconfigured observer fails loud, and it documents
    # that PortIndex must be built for that robot (the Host launcher / test setup
    # does so); the resolve calls below read that already-built index.
    _robot = Keyword.fetch!(opts, :robot)
    raw_slots = Keyword.fetch!(opts, :slots)
    sink = Keyword.fetch!(opts, :sink)
    sample_ms = Keyword.get(opts, :sample_ms, @default_sample_ms)
    fresh_for = Keyword.get(opts, :fresh_for, @default_fresh_for)
    name = Keyword.get(opts, :name)
    reader = Keyword.get(opts, :reader) || Reader.default()

    case resolve_slots(raw_slots, fresh_for) do
      {:ok, slot_states} ->
        :timer.send_interval(sample_ms, :sample)

        {:ok,
         %{
           name: name,
           reader: reader,
           sink: Sink.normalize(sink),
           slots: slot_states
         }}

      {:error, {:unknown_port, slot}} ->
        # Fail loud: a typo'd select must not silently observe nil forever
        # (mirrors BBHub.Sensor's stop on {:unknown_port, _}).
        {:stop, {:unknown_port, slot}}
    end
  end

  @impl true
  def handle_info(:sample, st) do
    {slots, sink} =
      Enum.map_reduce(st.slots, st.sink, fn slot_state, sink ->
        sample_slot(slot_state, sink, st)
      end)

    {:noreply, %{st | slots: slots, sink: sink}}
  end

  def handle_info(_other, st), do: {:noreply, st}

  # --- internals ---

  # Resolve each symbolic {hub, port} to its wire ids + value-type + a fresh
  # (born-stale) monitor at THIS observer's fresh_for. Fail loud on the first
  # unknown slot.
  defp resolve_slots(raw_slots, fresh_for) do
    Enum.reduce_while(raw_slots, {:ok, []}, fn {hub, port} = slot, {:ok, acc} ->
      case PortIndex.resolve(hub, port) do
        {:ok, {node, port_id}} ->
          {:ok, type} = PortIndex.type_for(node, port_id)

          slot_state = %{
            slot: slot,
            node: node,
            port_id: port_id,
            # Resolve the value-type once at init and KEEP the handle — the seam
            # ADR-0004 requires so filter/project can be added later. v1 hands the
            # raw value to the sink and never lifts via this handle.
            value_type: ValueType.resolve(type),
            mon: Monitor.new(node, port_id, fresh_for)
          }

          {:cont, {:ok, [slot_state | acc]}}

        :error ->
          {:halt, {:error, {:unknown_port, slot}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # Sample one slot: read the row via the READER (never NodeRegistry directly),
  # advance the born-stale monitor via the PURE check_row/2, and hand the value to
  # the sink ONLY if fresh. Returns the updated slot_state + the threaded sink.
  defp sample_slot(slot_state, sink, st) do
    row = Reader.get(st.reader, slot_state.node, slot_state.port_id)
    mon = Monitor.check_row(slot_state.mon, row)
    slot_state = %{slot_state | mon: mon}

    if Monitor.fresh?(mon) do
      {value, seq, t_dev} = row

      meta = %{
        slot: slot_state.slot,
        node: slot_state.node,
        port_id: slot_state.port_id,
        seq: seq,
        t_dev: t_dev,
        freshness: :fresh,
        value_type: slot_state.value_type,
        observer: st.name
      }

      sink = Sink.call(sink, slot_state.slot, value, meta)
      {slot_state, sink}
    else
      # born-stale or gone-silent: never hand a leftover/never-witnessed value to
      # the sink. Dropping it is correct (sample-state semantics).
      {slot_state, sink}
    end
  end
end
