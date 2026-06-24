defmodule BBMCUHub.Host.Transport.Loopback do
  @moduledoc """
  An in-process loopback transport (§07) — the dev/test sibling of
  `BBMCUHub.Host.Transport.UART`, for running the whole host stack with **no
  hardware**.

  It implements the `BBMCUHub.Host.Transport` behaviour, so a consumer points
  their `BBMCUHub.Host` launcher (or a bare `LinkOwner`) at it via
  `transport: BBMCUHub.Host.Transport.Loopback` in a test and exercises the real
  host pipeline: views → command-slot writes → the link owner's drain → this
  transport's framing.

  Outbound bodies are carried through the **real** `BBMCUHub.Wire.FramingCOBS`
  encode→bytes→decode path and recorded, so a test sees exactly the bytes that
  would have gone on the wire (CRC and COBS included), decoded back to the body.
  Inbound bodies are injected with `inject/2` — simulating a hub producing a
  value — and delivered to the owner as `{:circuits_uart, :loopback, body}`, the
  same message shape `BBMCUHub.Host.Transport.UART` delivers, so the link owner's
  receive path is unchanged.

  This ships in the library (not test-only) precisely so a downstream consumer can
  test their host stack headless without hand-rolling a transport. The library's
  own suite and the example both use it the same way.

      {:ok, sup} =
        BBMCUHub.Host.start_link(
          robot: MyRobot,
          transport: BBMCUHub.Host.Transport.Loopback
        )
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

  @doc "Bodies sent out through the framing layer (decoded back to the body)."
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
