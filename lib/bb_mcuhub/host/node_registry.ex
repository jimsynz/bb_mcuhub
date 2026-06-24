defmodule BBMCUHub.Host.NodeRegistry do
  @moduledoc """
  The host's small truth (§07): one row per `(node, port)` holding exactly one
  value plus two stamps — `{value, seq, t_dev}`.

  Overwrite-only; reads never block and return the latest. **Exactly one writer
  per slot** (the link owner for inbound sensor slots; the actuator *view* for
  outbound command slots — never the link owner, §04). `put` is one atomic ETS
  write of the whole row, so a reader never sees a torn stamp.

  This module owns a public, read-concurrent ETS table. It is started under the
  application supervisor so the table outlives any view or law crash — telemetry
  keeps flowing through a fault (§07).
  """
  use GenServer

  @table :bb_mcuhub_nodes

  @type node_id :: 0..255
  @type port_id :: 0..255
  @type seq :: 0..0xFFFF
  @type t_dev :: non_neg_integer()
  @type row :: {value :: term(), seq(), t_dev()}

  # --- API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Mint the **sole** write capability for a `(node, port)` slot (candidate 5).

  Returns a `BBMCUHub.Host.Registry.Writer` bound to this slot — the holder can
  write only this slot, never another. Enforces "exactly one writer per slot"
  (§07): a second live mint for the same slot raises
  `BBMCUHub.Host.Registry.Writer.Taken`. The calling process is registered as the
  slot's writer and monitored, so if it crashes the slot is freed and its
  replacement (a restarted view) can re-mint.

  The sole writer mints one at init (the actuator view for its command slot, the
  link owner for each inbound slot) and thereafter writes through the capability,
  never naming `put/5` directly.
  """
  @spec writer!(node_id(), port_id()) :: BBMCUHub.Host.Registry.Writer.t()
  def writer!(node, port) do
    case GenServer.call(__MODULE__, {:claim_writer, {node, port}, self()}) do
      :ok ->
        BBMCUHub.Host.Registry.Writer.new(node, port)

      {:taken, pid} ->
        raise BBMCUHub.Host.Registry.Writer.Taken,
          message:
            "slot #{inspect({node, port})} already has a live writer (#{inspect(pid)}) — " <>
              "exactly one writer per slot (§07)"
    end
  end

  @doc """
  Write a `(node, port)` row. The `seq` comes **from the producer** — the writer
  never invents it (§04). One atomic insert of the whole row.

  Prefer minting a `BBMCUHub.Host.Registry.Writer` via `writer!/2` and writing
  through it — that makes "one writer per slot" structural. This raw entry point
  remains for the writer capability to delegate to (and is still reachable, since
  the table is `:public` by design — see `writer!/2`).
  """
  @spec put(node_id(), port_id(), term(), seq(), t_dev()) :: :ok
  def put(node, port, value, seq, t_dev) do
    :ets.insert(@table, {{node, port}, {value, seq, t_dev}})
    :ok
  end

  @doc """
  Read a `(node, port)` row, or `nil` if nothing has ever been written there.

  A reader that gets `nil` is *born stale* with respect to that slot (§04): there
  is no value to trust until a producer writes one and the consumer witnesses the
  `seq` advance.
  """
  @spec get(node_id(), port_id()) :: row() | nil
  def get(node, port) do
    case :ets.lookup(@table, {node, port}) do
      [{_key, row}] -> row
      [] -> nil
    end
  end

  @doc "Every row, as a map keyed by `{node, port}`. For debugging/telemetry."
  @spec dump() :: %{{node_id(), port_id()} => row()}
  def dump, do: @table |> :ets.tab2list() |> Map.new()

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Clear every slot row AND release every writer claim. Test-only — the production
  table lives for the VM's lifetime. Routed through the owner so it works whether
  the table is `:public` or not.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Delete one slot row (test-only — fault injection)."
  @spec delete(node_id(), port_id()) :: :ok
  def delete(node, port), do: GenServer.call(__MODULE__, {:delete, {node, port}})

  # --- GenServer ---

  @impl true
  def init(_opts) do
    # public so the link owner / views read+write directly without a round-trip;
    # this process is just the table's stable owner. The one-writer-per-slot
    # UNIQUENESS registry (slot -> {writer_pid, monitor_ref}) lives in this
    # process's state — claims/releases go through it, but writes stay lock-free.
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table, writers: %{}}}
  end

  # Claim the sole-writer slot for `pid`. Idempotent for the SAME pid (a re-mint by
  # the same writer is fine); a DIFFERENT live pid is refused. If the recorded owner
  # has already died but its :DOWN hasn't been processed yet, claim-time liveness
  # frees the slot and lets the new claim win — so the registry never wedges on a
  # dead writer regardless of monitor-message timing.
  @impl true
  def handle_call({:claim_writer, slot, pid}, _from, st) do
    case Map.get(st.writers, slot) do
      nil ->
        {:reply, :ok, claim(st, slot, pid)}

      {^pid, _ref} ->
        {:reply, :ok, st}

      {other, ref} ->
        # A recorded owner that has already died (its :DOWN may not have been
        # processed yet) does NOT hold the slot — free it and let this claim win.
        # This keeps claim-time the single source of truth, independent of monitor
        # message timing.
        if Process.alive?(other) do
          {:reply, {:taken, other}, st}
        else
          Process.demonitor(ref, [:flush])
          {:reply, :ok, claim(st, slot, pid)}
        end
    end
  end

  def handle_call(:reset, _from, st) do
    :ets.delete_all_objects(@table)
    for {_slot, {_pid, ref}} <- st.writers, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{st | writers: %{}}}
  end

  def handle_call({:delete, slot}, _from, st) do
    :ets.delete(@table, slot)
    {:reply, :ok, st}
  end

  # A writer process died → free its slot so a restart can re-mint it.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, st) do
    writers =
      st.writers
      |> Enum.reject(fn {_slot, {p, r}} -> p == pid and r == ref end)
      |> Map.new()

    {:noreply, %{st | writers: writers}}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp claim(st, slot, pid) do
    ref = Process.monitor(pid)
    put_in(st.writers[slot], {pid, ref})
  end
end
