defmodule BBMcuhub.Application do
  @moduledoc """
  The library's OTP application.

  `bb_mcuhub` is the host-side platform (§07): a small per-`(node, port)`
  registry, the link owner that owns the UART to the root hub, and the BeamBots
  views (§09) that surface hub ports as `BB.Sensor` / `BB.Actuator` components.

  The link owner is *not* started here unconditionally — a robot wires it into
  its own supervision tree via its BeamBots topology so it survives a view or law
  crash (§07). This application only stands up the shared, robot-independent
  pieces: the wire drop/fail counters and the node registry.
  """
  use Application

  @impl true
  def start(_type, _args) do
    BBMcuhub.Wire.Stats.setup()

    children = [
      BBMcuhub.Host.NodeRegistry
    ]

    opts = [strategy: :one_for_one, name: BBMcuhub.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
