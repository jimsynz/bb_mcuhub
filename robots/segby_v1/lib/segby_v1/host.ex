defmodule BBMcuhub.Robots.SegbyV1.Host do
  @moduledoc """
  The segby_v1 host launcher (§07/§09) — one place that stands up everything the
  self-balancing bot needs on the host, so an operator runs ONE thing.

  It supervises, together, the two pieces that must share a fate boundary:

    * the **BeamBots supervision tree** for `BBMcuhub.Robots.SegbyV1` — the views
      (the chassis IMU sensor, the two wheel actuators), the `:balance` controller
      (born DISABLED), and the `:teleop` command; and
    * the **`LinkOwner`** (`BBMcuhub.Host.LinkOwner`) — the one process that owns
      the host↔root-hub UART, decodes inbound frames into the registry, and drains
      the two wheel command slots outbound.

  `LinkOwner` is kept here, beside the robot tree, NOT under
  `BBMcuhub.Application` — so it survives a view or law crash and the link stays
  open through a fault (§07). It is started AFTER the BB tree (it depends on the
  PubSub registry only indirectly, but ordering it last means the views exist
  before any inbound frame could be routed). Both are children of this one
  supervisor; if the whole robot is torn down, the UART is closed with it.

  The `LinkOwner` is registered under its default name (`BBMcuhub.Host.LinkOwner`)
  so the actuator views — the sole writers of the command slots (§04) — can
  notify it on each write exactly as in production.

  ## Command slots

  The two wheel command `(node, port_id)`s are resolved at boot from the segby
  IR via `BBMcuhub.Contract.PortIndex` (`{:wheels, :motor_left}` and
  `{:wheels, :motor_right}`), so a contract move can never desync the watched
  slots from the wire ids. `PortIndex.build/1` is pointed at segby first (it
  defaults to the Follower), and the resolved slots are passed to `LinkOwner` as
  `:command_slots`.

  ## Transport (parameterised)

  The transport defaults to the production `BBMcuhub.Host.Transport.UART`, but is
  parameterised so a test can inject `BBMcuhub.Test.LoopbackTransport` and run the
  whole host stack with no hardware. Pass `transport:` / `transport_opts:`.

  ## Running it

      # Production / on the Pi — start the supervised tree, then attach bb_tui.
      BBMcuhub.Robots.SegbyV1.Host.start_link(transport_opts: [port: "ttyAMA0"])
      # ...then, in a foreground shell (bb_tui owns stdin/stdout):
      $ mix bb.tui --robot BBMcuhub.Robots.SegbyV1

  `bb_tui` is launched as a FOREGROUND process (the `mix bb.tui` task or
  `BB.TUI.run/1`), never a supervised child of the robot — it takes over
  stdin/stdout and would conflict with IEx (its own docs note local dashboards
  are not supervised). The launcher stands up the robot + `LinkOwner`; bb_tui then
  attaches to the already-running tree over the standard BB PubSub paths.

  ## bb_tui ↔ segby wiring (what the operator sees)

  `bb_tui` subscribes to `[:state_machine], [:sensor], [:param], [:actuator],
  [:command]` and snapshots the runtime on mount. Driven by segby it populates:

    * **joints** — the two wheels, from the actuator views' published commands;
    * **sensor / status bar** — chassis IMU pose + forward range, from the sensor
      views on `[:sensor | _]`;
    * **safety** — arm/disarm (`a`/`d`), which gate the on-chip floor (§05);
    * **commands** — the declared `:teleop` command. Running it (Commands panel)
      publishes a `Twist` onto the balance controller's teleop topic, which biases
      the per-wheel effort — this is how an operator drives segby (see
      `BBMcuhub.Robots.SegbyV1.Teleop`). `bb_tui` has no built-in teleop concept;
      this command IS the teleop seam.

  Enable balance live from IEx with `BBMcuhub.Segby.Balance.enable(BBMcuhub.Robots.SegbyV1)`.

  ## On the Raspberry Pi, under Nerves (wiring facts — built in the hardware phase)

  The host is plain OTP under Nerves on a Raspberry Pi (the design's HOST, which
  sits ABOVE the hub tree and is not itself a hub). The hardware Nerves firmware
  build needs a Pi and is a separate phase; the wiring is:

    * **UART device** — the Pi's PL011 on GPIO 14 (TXD) / GPIO 15 (RXD),
      i.e. `/dev/ttyAMA0` (the PL011, not the mini-UART — disable the serial
      console and `enable_uart=1` so the PL011 is routed to the GPIO header).
    * **Baud** — `1_000_000` (1 Mbit/s), the `BBMcuhub.Host.Transport.UART`
      default; it must match the root hub (the Blaster, NODE 0x02) firmware.
    * **Framing** — COBS+CRC (`BBMcuhub.Wire.FramingCOBS`), owned below the
      transport seam; the `LinkOwner` only ever sees clean bodies.
    * **Ownership** — the `LinkOwner` (started here) owns that one UART. It is the
      single decode + route seam (§07); no other process touches the device.
    * **Launch on the Pi** — start this launcher (`transport_opts: [port:
      "ttyAMA0"]`) from the Nerves app's tree, then run
      `mix bb.tui --robot BBMcuhub.Robots.SegbyV1` (locally over the console, or
      `--ssh` / `--node` to attach a dashboard from a workstation — see `BB.TUI`).

  NOTE: this phase wires + documents the Pi/Nerves path only. It does NOT add a
  Nerves `MIX_TARGET` project — that is the hardware phase, which needs a Pi to
  verify.
  """
  use Supervisor

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.LinkOwner

  @robot BBMcuhub.Robots.SegbyV1

  @doc "The segby robot module this launcher supervises."
  @spec robot() :: module()
  def robot, do: @robot

  @doc """
  Start the supervised host tree: the BeamBots supervision tree for segby plus
  the `LinkOwner` (which owns the host↔root-hub UART).

  ## Options

    * `:transport` — a `BBMcuhub.Host.Transport` module (default
      `BBMcuhub.Host.Transport.UART`); tests inject `LoopbackTransport`.
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
  The two wheel command `(node, port_id)` slots the `LinkOwner` drains, resolved
  from the segby IR. Builds the `PortIndex` for segby as a side effect (it
  defaults to the Follower otherwise). Raises if a slot can't be resolved — a
  contract change that drops a wheel port must fail loudly here, not silently
  watch nothing.
  """
  @spec command_slots() :: [{0..255, 0..255}]
  def command_slots do
    PortIndex.build(@robot)

    for port <- [:motor_left, :motor_right] do
      case PortIndex.resolve(:wheels, port) do
        {:ok, slot} -> slot
        :error -> raise "segby_v1 host: cannot resolve wheels/#{port} command slot"
      end
    end
  end

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, BBMcuhub.Host.Transport.UART)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    bb_opts = Keyword.get(opts, :bb_opts, [])

    slots = command_slots()

    children = [
      # The BeamBots tree first: views, the :balance controller, the :teleop
      # command, the PubSub + process registries.
      %{
        id: BB.Supervisor,
        start: {BB.Supervisor, :start_link, [@robot, bb_opts]},
        type: :supervisor
      },
      # The link owner beside the tree (§07) — owns the UART, drains the two
      # wheel command slots. Default-named so the actuator views notify it.
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
