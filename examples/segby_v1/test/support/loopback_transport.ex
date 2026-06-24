defmodule SegbyV1.Test.LoopbackTransport do
  @moduledoc """
  An in-process transport for the example's tests (§07): it carries outbound
  bodies through the *real* `BBMCUHub.Wire.FramingCOBS` encode→bytes→decode path
  and back to the owner, so the host stack is exercised over the actual COBS+CRC
  seam without any hardware.

  It also lets a test inject inbound bodies (simulating a hub producing a value)
  via `inject/2`, delivered to the owner as `{:circuits_uart, :loopback, body}` —
  the same message shape the UART transport delivers.

  This is the CONSUMER's own copy of a loopback transport over the library's
  public `BBMCUHub.Host.Transport` behaviour. (The library ships no consumer
  loopback transport; see the host launcher's `:transport` option — a missing
  public dev/test helper the library could offer downstream.)
  """
  @behaviour BBMCUHub.Host.Transport
  use GenServer
  import Kernel, except: [send: 2]

  alias BBMCUHub.Wire.FramingCOBS

  # --- Transport behaviour ---

  @impl BBMCUHub.Host.Transport
  def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

  @impl BBMCUHub.Host.Transport
  def send(pid, body), do: GenServer.call(pid, {:send, body})

  @impl BBMCUHub.Host.Transport
  def close(pid), do: GenServer.stop(pid)

  # --- test helpers ---

  @doc "Simulate a hub producing `body`: deliver it to the owner as if received."
  @spec inject(pid(), binary()) :: :ok
  def inject(pid, body), do: GenServer.call(pid, {:inject, body})

  @doc "Bodies that have been sent out through the framing layer (decoded back)."
  @spec sent(pid()) :: [binary()]
  def sent(pid), do: GenServer.call(pid, :sent)

  # --- GenServer ---

  @impl GenServer
  def init(owner) do
    {:ok, fst} = FramingCOBS.init([])
    {:ok, %{owner: owner, framing: fst, sent: []}}
  end

  @impl GenServer
  def handle_call({:send, body}, _from, st) do
    # round-trip through real framing: add_framing → bytes → remove_framing
    {:ok, bytes, fst} = FramingCOBS.add_framing(body, st.framing)
    {_status, [decoded], fst} = FramingCOBS.remove_framing(bytes, fst)
    {:reply, :ok, %{st | framing: fst, sent: [decoded | st.sent]}}
  end

  def handle_call({:inject, body}, _from, st) do
    Kernel.send(st.owner, {:circuits_uart, :loopback, body})
    {:reply, :ok, st}
  end

  def handle_call(:sent, _from, st), do: {:reply, Enum.reverse(st.sent), st}
end
