defmodule BBMCUHub.Host do
  @moduledoc """
  The generic host launcher (§07/§09) — one place that stands up everything a
  robot needs on the host, so a consumer runs ONE thing instead of hand-writing a
  slot-resolution supervisor (ADR-0003).

  Given a `robot:` module it supervises, together, the two pieces that must share
  a fate boundary:

    * the **BeamBots supervision tree** for that robot — the views, controllers,
      and commands, plus the PubSub + process registries; and
    * the **`LinkOwner`** (`BBMCUHub.Host.LinkOwner`) — the one process that owns
      the host↔root-hub UART, decodes inbound frames into the registry, and drains
      the robot's command slots outbound.

  `LinkOwner` is kept here, beside the robot tree, NOT under
  `BBMCUHub.Application` — so it survives a view or law crash and the link stays
  open through a fault (§07). It is started AFTER the BB tree so the views exist
  before any inbound frame could be routed. Both are children of this one
  supervisor; if the whole robot is torn down, the UART is closed with it.

  The `LinkOwner` is registered under its default name (`BBMCUHub.Host.LinkOwner`)
  so the actuator views — the sole writers of the command slots (§04) — can
  notify it on each write exactly as in production.

  ## Command slots are derived from the IR (not hand-listed)

  A command slot is the wire `{node, port_id}` of every IR row that is an actuator
  command port: `dir: :in` AND `has_safe_action: true` — exactly the floored
  command ports of §05/ADR-0005 (the same predicate `BBMCUHub.Gen.WireGen` uses to
  find actuators).
  Each such row already carries its `node` and `port_id`, so the slots are simply
  `Enum.map(actuator_rows, &{&1.node, &1.port_id})`. Deriving them from the IR
  means a contract move can never desync the watched slots from the wire ids — and
  there is no hand-listed slot that could fail to resolve.

  A robot can legitimately be **sensor-only** (no actuators). In that case the
  derived slot list is `[]` and the `LinkOwner` runs as a telemetry-only drain
  that watches nothing — this is VALID, not an error, so `command_slots/1` returns
  `[]` rather than raising.

  `PortIndex.build/1` is pointed at the robot first (it defaults to a fixture
  otherwise) so the actuator views resolve their slots against this robot's ids.

  ## Transport (parameterised)

  The transport defaults to the production `BBMCUHub.Host.Transport.UART`, but is
  parameterised so a test can inject `BBMCUHub.Host.Transport.Loopback` and run the
  whole host stack with no hardware. Pass `transport:` / `transport_opts:`.

  ## Usage

      BBMCUHub.Host.start_link(robot: MyRobot, transport_opts: [port: "ttyAMA0"])

  A consumer's robot-specific launcher can shrink to a thin wrapper that forwards
  to this one (see the worked example's `SegbyV1.Host` in `examples/segby_v1`).
  """
  use Supervisor

  alias BBMCUHub.Contract.PortIndex
  alias BBMCUHub.Host.LinkOwner
  alias BBMCUHub.Robot.Info

  @doc """
  Start the supervised host tree for `robot`: the BeamBots supervision tree plus
  the `LinkOwner` (which owns the host↔root-hub UART).

  ## Options

    * `:robot` — the robot module (REQUIRED).
    * `:transport` — a `BBMCUHub.Host.Transport` module (default
      `BBMCUHub.Host.Transport.UART`); tests inject
      `BBMCUHub.Host.Transport.Loopback`.
    * `:transport_opts` — passed to the transport (`[port: "ttyAMA0", baud:
      1_000_000]` for the UART).
    * `:bb_opts` — extra options forwarded to `BB.Supervisor.start_link/2`
      (e.g. `:params`, `:simulation`).
    * `:name` — this supervisor's name (default `__MODULE__`).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The command `(node, port_id)` slots the `LinkOwner` drains for `robot`, derived
  from its IR: every actuator command port (`dir: :in` AND `has_safe_action: true`).

  Builds the `PortIndex` for `robot` as a side effect (so the actuator views
  resolve their slots against this robot's ids). Returns `[]` for a sensor-only
  robot — that is a valid telemetry-only host, not a misconfiguration, so this
  never raises.
  """
  @spec command_slots(module()) :: [{0..255, 0..255}]
  def command_slots(robot) do
    PortIndex.build(robot)

    robot
    |> Info.ir()
    |> Enum.filter(&(&1.dir == :in and &1.has_safe_action == true))
    |> Enum.map(&{&1.node, &1.port_id})
  end

  @impl true
  def init(opts) do
    robot = Keyword.fetch!(opts, :robot)
    transport = Keyword.get(opts, :transport, BBMCUHub.Host.Transport.UART)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    bb_opts = Keyword.get(opts, :bb_opts, [])

    slots = command_slots(robot)

    children = [
      # The BeamBots tree first: views, controllers, commands, the PubSub +
      # process registries.
      %{
        id: BB.Supervisor,
        start: {BB.Supervisor, :start_link, [robot, bb_opts]},
        type: :supervisor
      },
      # The link owner beside the tree (§07) — owns the UART, drains the derived
      # command slots. Default-named so the actuator views notify it.
      %{
        id: LinkOwner,
        start:
          {LinkOwner, :start_link,
           [[transport: transport, transport_opts: transport_opts, command_slots: slots]]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
