defmodule BBMcuhub.Host.NodeRegistry do
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
  Write a `(node, port)` row. The `seq` comes **from the producer** — the writer
  never invents it (§04). One atomic insert of the whole row.
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

  # --- GenServer ---

  @impl true
  def init(_opts) do
    # public so the link owner / views read+write directly without a round-trip;
    # this process is just the table's stable owner.
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end
end
