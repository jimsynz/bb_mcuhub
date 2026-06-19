defmodule BBMcuhub.Host.Transport.Loopback do
  @moduledoc """
  An in-process loopback transport (§07) — the dev/test sibling of
  `BBMcuhub.Host.Transport.UART`, for running the whole host stack with **no
  hardware**.

  It implements the `BBMcuhub.Host.Transport` behaviour, so a consumer points
  their `BBMcuhub.Host` launcher (or a bare `LinkOwner`) at it via
  `transport: BBMcuhub.Host.Transport.Loopback` in a test and exercises the real
  host pipeline: views → command-slot writes → the link owner's drain → this
  transport's framing.

  Outbound bodies are carried through the **real** `BBMcuhub.Wire.FramingCOBS`
  encode→bytes→decode path and recorded, so a test sees exactly the bytes that
  would have gone on the wire (CRC and COBS included), decoded back to the body.
  Inbound bodies are injected with `inject/2` — simulating a hub producing a
  value — and delivered to the owner as `{:circuits_uart, :loopback, body}`, the
  same message shape `BBMcuhub.Host.Transport.UART` delivers, so the link owner's
  receive path is unchanged.

  This ships in the library (not test-only) precisely so a downstream consumer can
  test their host stack headless without hand-rolling a transport. The library's
  own suite and the example both use it the same way.

      {:ok, sup} =
        BBMcuhub.Host.start_link(
          robot: MyRobot,
          transport: BBMcuhub.Host.Transport.Loopback
        )
  """
  @behaviour BBMcuhub.Host.Transport
  use GenServer
  import Kernel, except: [send: 2]

  alias BBMcuhub.Wire.FramingCOBS

  # --- Transport behaviour ---

  @impl BBMcuhub.Host.Transport
  def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

  @impl BBMcuhub.Host.Transport
  def send(pid, body), do: GenServer.call(pid, {:send, body})

  @impl BBMcuhub.Host.Transport
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
