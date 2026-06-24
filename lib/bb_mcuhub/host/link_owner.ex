defmodule BBMcuhub.Host.LinkOwner do
  @moduledoc """
  Owns the link to the root hub and is the one decode + route seam (§07).

  **Inbound:** the transport delivers already-CRC-verified bodies; the link owner
  decodes each `(node, port, seq, t_dev, value)` and writes it into the registry.
  A frame for an unknown `(node, port)` or with a bad payload is counted
  (`decode_fail`) and dropped — never guessed.

  **Outbound:** it is a **read-only drain** of command slots (§04). The actuator
  *view* is the sole writer of a command slot; after each write it *notifies* the
  link owner, which then reads that slot and, when its `seq` has advanced, encodes
  and sends it down the wire. The drain is **event-driven** — no poll — but the
  link owner still only ever *reads* command slots (the notification carries just
  the `(node, port)` to look at, never a value), so it can never manufacture a
  `seq` advance. The `seq`-inequality test still dedups, so a redundant
  notification with no new value sends nothing.

  Placed under a robot's supervisor so it survives a view or law crash — the link
  stays open and telemetry keeps flowing through a fault (§07).
  """
  use GenServer

  require Logger

  alias BBMcuhub.Contract
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.NodeRegistry
  alias BBMcuhub.Wire.{Codec, Stats}

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
  Notify the link owner that a watched command slot was just written, so it
  drains that slot now (event-driven, no poll).

  Fire-and-forget: the caller (the actuator *view*, the slot's sole writer) does
  not block. The link owner reads the slot itself and sends only if `seq`
  advanced, so a notification for an unchanged or unwatched slot is a no-op — the
  read-only-drain invariant (§04) is preserved.
  """
  @spec notify_command_slot(GenServer.server(), 0..255, 0..255) :: :ok
  def notify_command_slot(server \\ __MODULE__, node, port_id) do
    GenServer.cast(server, {:notify_command_slot, {node, port_id}})
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
    command_slots = Keyword.get(opts, :command_slots, [])

    case transport_mod.start_link(self(), transport_opts) do
      {:ok, transport} ->
        {:ok,
         %{
           transport_mod: transport_mod,
           transport: transport,
           # command slot -> last seq we drained (:unseen = never), so the first
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

  # OUTBOUND drain (event-driven): the slot's sole writer (the actuator view) just
  # wrote it. Read it; if its seq advanced past what we last drained, send it. A
  # notification for an unwatched slot, or one whose seq did not advance, is a
  # no-op — we only ever READ command slots (§04).
  @impl true
  def handle_cast({:notify_command_slot, slot}, st) do
    case Map.fetch(st.command_slots, slot) do
      {:ok, last_seq} ->
        {n, p} = slot

        case NodeRegistry.get(n, p) do
          {value, seq, t_dev} when seq != last_seq ->
            send_value(st, n, p, seq, t_dev, value)
            {:noreply, %{st | command_slots: Map.put(st.command_slots, slot, seq)}}

          _ ->
            {:noreply, st}
        end

      :error ->
        {:noreply, st}
    end
  end

  @impl true
  def handle_call({:watch_command_slot, slot}, _from, st) do
    {:reply, :ok, %{st | command_slots: Map.put_new(st.command_slots, slot, :unseen)}}
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

  # Encode one command slot's value and send it. DEFENSIVE: a malformed value (a
  # value-type value missing a layout field, or an unknown (node, port_id)) is a
  # producer bug, but it must not crash the link drain — that would take down
  # telemetry and every other slot's draining over one bad command. So an encode
  # failure is counted as `encode_fail` and the command is skipped: the floor
  # still backstops the unsent command, but the CAUSE stays legible (a counter)
  # rather than surfacing distantly as a floor firing (robustness candidate 4).
  defp send_value(st, node, port_id, seq, t_dev, value) do
    case PortIndex.type_for(node, port_id) do
      {:ok, type} ->
        stamped? = PortIndex.stamped?(node, port_id)
        body = Codec.encode_body(node, port_id, seq, t_dev, type, value, stamped?)
        st.transport_mod.send(st.transport, body)

      :error ->
        # a watched slot with no port-index entry — should never happen, count it
        Stats.bump(:encode_fail)
    end
  rescue
    e ->
      # a malformed value-type value (e.g. encode_fields' Map.fetch! on a missing
      # field) — count and skip, never crash the drain.
      Stats.bump(:encode_fail)

      Logger.warning(
        "command for #{inspect({node, port_id})} could not be encoded (#{Exception.message(e)}) — " <>
          "skipped, floor will backstop; check the value-type value"
      )
  end
end
