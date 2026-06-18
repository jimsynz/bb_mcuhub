defmodule BBMcuhub.Host.LinkOwner do
  @moduledoc """
  Owns the link to the root hub and is the one decode + route seam (§07).

  **Inbound:** the transport delivers already-CRC-verified bodies; the link owner
  decodes each `(node, port, seq, t_dev, value)` and writes it into the registry.
  A frame for an unknown `(node, port)` or with a bad payload is counted
  (`decode_fail`) and dropped — never guessed.

  **Outbound:** it is a **read-only drain** of command slots (§04). The actuator
  *view* is the sole writer of a command slot; the link owner polls each
  registered command slot on a tick and, when its `seq` advances, encodes and
  sends it down the wire. Because it only ever *reads* command slots, it can never
  manufacture a `seq` advance.

  Placed under a robot's supervisor so it survives a view or law crash — the link
  stays open and telemetry keeps flowing through a fault (§07).
  """
  use GenServer

  alias BBMcuhub.Contract
  alias BBMcuhub.Host.NodeRegistry
  alias BBMcuhub.Wire.{Codec, Stats}

  @default_drain_ms 5

  @type cmd_slot :: {node :: 0..255, port_id :: 0..255}

  # --- API ---

  @doc """
  Start the link owner.

  Options:
    * `:transport` — a `BBMcuhub.Host.Transport` module (default
      `BBMcuhub.Host.Transport.UART`).
    * `:transport_opts` — passed to the transport's `start_link/2`.
    * `:command_slots` — `[{node, port_id}]` to drain outbound (the actuator
      views' command slots).
    * `:drain_ms` — how often to poll command slots (default #{@default_drain_ms}).
    * `:name` — process name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a command slot to be drained outbound (idempotent)."
  @spec watch_command_slot(GenServer.server(), 0..255, 0..255) :: :ok
  def watch_command_slot(server \\ __MODULE__, node, port_id) do
    GenServer.call(server, {:watch_command_slot, {node, port_id}})
  end

  @doc """
  Send a best-effort broadcast disarm — an *accelerator* for command-silence, not
  the safe-state mechanism (§05). Returns once the intent is on the wire.
  """
  @spec send_disarm(GenServer.server()) :: :ok
  def send_disarm(server \\ __MODULE__) do
    GenServer.call(server, :send_disarm)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    Stats.setup()
    transport_mod = Keyword.get(opts, :transport, BBMcuhub.Host.Transport.UART)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    drain_ms = Keyword.get(opts, :drain_ms, @default_drain_ms)
    command_slots = Keyword.get(opts, :command_slots, [])

    case transport_mod.start_link(self(), transport_opts) do
      {:ok, transport} ->
        if command_slots != [], do: schedule_drain(drain_ms)

        {:ok,
         %{
           transport_mod: transport_mod,
           transport: transport,
           drain_ms: drain_ms,
           # command slot -> last seq we drained (nil = never), born so the first
           # real value is sent once
           command_slots: Map.new(command_slots, &{&1, :unseen})
         }}

      {:error, reason} ->
        {:stop, {:transport_failed, reason}}
    end
  end

  # INBOUND: a CRC-verified body. Decode and write to the registry, or drop+count.
  @impl true
  def handle_info({:circuits_uart, _port, body}, st) do
    case Codec.decode_body(body) do
      {:ok, %{node: n, port_id: p, seq: seq, t_dev: t, value: value}} ->
        NodeRegistry.put(n, p, value, seq, t)
        {:noreply, st}

      :error ->
        Stats.bump(:decode_fail)
        {:noreply, st}
    end
  end

  # OUTBOUND drain: for each watched command slot, if its seq advanced, send it.
  @impl true
  def handle_info(:drain, st) do
    slots =
      Enum.reduce(st.command_slots, st.command_slots, fn {{n, p} = slot, last_seq}, acc ->
        case NodeRegistry.get(n, p) do
          {value, seq, t_dev} when seq != last_seq ->
            send_value(st, n, p, seq, t_dev, value)
            Map.put(acc, slot, seq)

          _ ->
            acc
        end
      end)

    schedule_drain(st.drain_ms)
    {:noreply, %{st | command_slots: slots}}
  end

  @impl true
  def handle_call({:watch_command_slot, slot}, _from, st) do
    started? = st.command_slots != %{}
    slots = Map.put_new(st.command_slots, slot, :unseen)
    unless started?, do: schedule_drain(st.drain_ms)
    {:reply, :ok, %{st | command_slots: slots}}
  end

  def handle_call(:send_disarm, _from, st) do
    # Broadcast disarm: NODE 0x00 — the lowest id, wins CAN arbitration, and
    # resolves to command-silence at every actuator (§05). It is the address that
    # carries the meaning; the body is the bare unstamped header, no payload.
    body = Codec.encode_header_only(Contract.broadcast_node(), 0x00, 0)
    st.transport_mod.send(st.transport, body)
    {:reply, :ok, st}
  end

  @impl true
  def terminate(_reason, st) do
    st.transport_mod.close(st.transport)
    :ok
  end

  # --- internals ---

  defp send_value(st, node, port_id, seq, t_dev, value) do
    alias BBMcuhub.Contract.PortIndex

    with {:ok, type} <- PortIndex.type_for(node, port_id) do
      stamped? = PortIndex.stamped?(node, port_id)
      body = Codec.encode_body(node, port_id, seq, t_dev, type, value, stamped?)
      st.transport_mod.send(st.transport, body)
    end
  end

  defp schedule_drain(ms), do: Process.send_after(self(), :drain, ms)
end
