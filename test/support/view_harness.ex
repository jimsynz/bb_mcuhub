defmodule BBMCUHub.Test.ViewHarness do
  @moduledoc """
  A minimal GenServer that drives a BB view callback module (`BB.Sensor` /
  `BB.Actuator`) in isolation for tests.

  In production BeamBots wraps a view in `BB.Sensor.Server` / `BB.Actuator.Server`
  and delegates to its callbacks. Here we delegate `init/1` and `handle_info/2`
  ourselves, so a test can `send/2` the view a `:beat` or a `{:bb, ...}` command
  and observe the effect, without standing up the whole BB supervision tree.

  Like the real servers, opts are run through `BB.Component.OptionsSchema.validate`
  before `init/1`, so the view sees **schema-validated** opts with defaults filled —
  exactly what production hands it. (Without this the harness would call `init/1`
  with raw opts, so any value sourced from a schema default would be `nil` here and
  the view's behaviour would silently diverge from production.) `:bb` is the only
  framework-injected key the views read (they never touch sensor/motor profiles).
  """
  use GenServer

  alias BB.Component.OptionsSchema

  @framework_keys [:bb]

  def start(module, opts), do: GenServer.start_link(__MODULE__, {module, opts})

  @doc "The current view (callback-module) state — for asserting on view internals."
  def view_state(pid), do: GenServer.call(pid, :__view_state__)

  @impl true
  def init({module, opts}) do
    with {:ok, opts} <- OptionsSchema.validate(module, opts, @framework_keys) do
      init_view(module, opts)
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp init_view(module, opts) do
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
  def handle_info(msg, st) do
    case st.module.handle_info(msg, st.view) do
      {:noreply, view} -> {:noreply, %{st | view: view}}
      {:noreply, view, _extra} -> {:noreply, %{st | view: view}}
      {:stop, reason, view} -> {:stop, reason, %{st | view: view}}
    end
  end
end
