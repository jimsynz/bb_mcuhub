defmodule SegbyV1.Test.ViewHarness do
  @moduledoc """
  A minimal GenServer that drives a BB view / controller callback module
  (`BB.Sensor` / `BB.Actuator` / `BB.Controller`) in isolation for the example's
  tests.

  In production BeamBots wraps a view in its server and delegates to its
  callbacks. Here we delegate `init/1` and `handle_info/2` ourselves, so a test
  can `send/2` the callback module a `:beat` or a `{:bb, ...}` message and observe
  the effect, without standing up the whole BB supervision tree.

  ## Safety-state transitions

  The real `BB.Controller.Server` delivers `[:state_machine]` transitions to a
  controller's `handle_info/2`: the controller subscribes to `[:state_machine]`
  itself and gates its own output on arm state (see `SegbyV1.Balance`). This
  harness does the same — every `{:bb, ...}` message, transitions included, goes
  straight to the module's `handle_info/2`, so a harness-driven controller
  exercises the SAME safety path as production.
  """
  use GenServer

  def start(module, opts), do: GenServer.start_link(__MODULE__, {module, opts})

  @doc "The current view (callback-module) state — for asserting on view internals."
  def view_state(pid), do: GenServer.call(pid, :__view_state__)

  @impl true
  def init({module, opts}) do
    case module.init(opts) do
      {:ok, view_state} -> {:ok, %{module: module, view: view_state}}
      {:ok, view_state, _extra} -> {:ok, %{module: module, view: view_state}}
      {:stop, reason} -> {:stop, reason}
      other -> {:stop, {:bad_init, other}}
    end
  end

  @impl true
  def handle_call(:__view_state__, _from, st), do: {:reply, st.view, st}

  @impl true
  def handle_info(msg, st), do: delegate_handle_info(msg, st)

  defp delegate_handle_info(msg, st) do
    case st.module.handle_info(msg, st.view) do
      {:noreply, view} -> {:noreply, %{st | view: view}}
      {:noreply, view, _extra} -> {:noreply, %{st | view: view}}
      {:stop, reason, view} -> {:stop, reason, %{st | view: view}}
    end
  end
end
