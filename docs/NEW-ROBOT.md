# Build a new robot on bb_mcuhub

An **ordered, step-by-step** recipe for going from nothing to a flashable robot on
`bb_mcuhub`. This is the build procedure the [`README`](../README.md) (reference)
and the example's [`BRINGUP.md`](../examples/segby_v1/BRINGUP.md) (on-hardware
bring-up) do not give: the README is reference-shaped, and `BRINGUP.md` starts
_after_ you have a green build to flash. This doc owns **software assembly**
(value-types → hubs → robot → generate → device hooks → envs → host) and hands off
to `BRINGUP.md` for the **on-hardware** stages.

The glossary terms in bold below (**hub**, **value-type**, **root hub**, **link**,
**floor**, **safe action**, **firmware hook**, …) are defined in
[`CONTEXT.md`](../CONTEXT.md); the architecture and `§` section numbers are in
[`docs/hub-design.html`](hub-design.html). Decisions are recorded in the ADRs —
this guide leans on [ADR-0003](adr/0003-library-example-split.md)
(library/example split), [ADR-0005](adr/0005-safe-action-is-a-value-type-value.md)
(safe-action is a value-type value), and
[ADR-0006](adr/0006-links-are-declared-not-inferred.md) (declared topology).

You write your robot in **your own Mix app**, which depends on `bb_mcuhub` exactly
as the worked example does (a Mix `path`/registry dep on the host side, a
PlatformIO `lib_deps` dep on the firmware side). You never edit the library. The
canonical, complete reference for every step is
[`examples/segby_v1/`](../examples/segby_v1/) — a two-wheel self-balancing bot;
each step below cites the real file to copy from.

> **The dependency order is the spine.** Each step produces what the next one
> consumes: a **value-type** is named by a **port**; ports are declared on a **hub
> module**; hub modules are placed and wired by the **robot**; the robot is the
> input to **`mix wire.gen`**, which emits the headers your **device hooks** and
> **platformio.ini** consume; the **host launcher** runs the robot's IR. Do them
> in order.

> **Planned scaffold (not yet built):** a `mix bb_mcuhub.gen.robot` generator is
> planned to collapse the manual value-type/hub/robot/platformio boilerplate of
> Steps 1–3 and 6 into a scaffold — but it does not exist yet, so this guide is
> the manual path.

---

## Step 0 — your app and its dependency on the library

Create a Mix app (your own root namespace, e.g. `MyApp.*`) and depend on
`bb_mcuhub`, `bb`, and — if you want the dashboard — `bb_tui`. The example's
[`mix.exs`](../examples/segby_v1/mix.exs) is the shape to mirror:

```elixir
defp deps do
  [
    {:bb_mcuhub, path: "../.."},      # a path dep in-tree; a registry dep later, no shape change
    {:bb, "~> 0.20"},                 # the BeamBots framework — the seam the robot sits on
    {:bb_tui, github: "lostbean/bb_tui", branch: "feat/consumer-renderers"}  # optional dashboard
  ]
end
```

**Why this order:** everything else is authored against `BBMCUHub.*` and `BB.*`
modules, so the deps come first. The boundary between what you write and what the
library provides is the product (ADR-0003); the [`README`](../README.md) table
"What a consumer writes vs. what the library provides" is the map.

---

## Step 1 — Value-types (your wire vocabulary)

A **value-type** (`use BBMCUHub.ValueType`) is a standalone, reusable module that
owns _what bytes a kind of value puts on the wire and how those bytes become a
typed `BB.Message`_ — and nothing else (§06, CONTEXT.md → **Value-type**). It
carries:

1. an ordered `layout field: :wire_type, ...` (the bytes on the wire);
2. a host-side `lift/1` (raw `%{field => number}` map → a typed `BB.Message`
   payload) and its inverse `unlift/1`;
3. for a **command** value-type only, `command_message/0` naming the one
   `BB.Message` command struct it accepts.

The library ships a lean stock set — `:imu`, `:effort`, `:status` — and you add
your own with **no library edit**. A sense-only value-type leaves `command_message`
absent (it defaults to `nil`).

Worked reference — the example's `range` value-type, a sense-only `:f32`
([`value_types/range.ex`](../examples/segby_v1/lib/segby_v1/value_types/range.ex)):

```elixir
defmodule SegbyV1.ValueTypes.Range do
  use BBMCUHub.ValueType

  layout(
    distance_m: :f32
  )

  @impl BBMCUHub.ValueType
  def lift(map) when is_map(map), do: map

  @impl BBMCUHub.ValueType
  def unlift(map) when is_map(map), do: map
end
```

A **command** value-type also names its own command message. The example's `led`
value-type ([`value_types/led.ex`](../examples/segby_v1/lib/segby_v1/value_types/led.ex))
is the full consumer-defined-command demonstration — an own value-type **and** its
own `BB.Message` command
([`messages/led_color.ex`](../examples/segby_v1/lib/segby_v1/messages/led_color.ex)):

```elixir
defmodule SegbyV1.ValueTypes.Led do
  use BBMCUHub.ValueType

  layout(
    r: :u8,
    g: :u8,
    b: :u8
  )

  @impl BBMCUHub.ValueType
  def lift(%{r: r, g: g, b: b}), do: %SegbyV1.Messages.LedColor{r: r, g: g, b: b}

  @impl BBMCUHub.ValueType
  def unlift(%SegbyV1.Messages.LedColor{r: r, g: g, b: b}), do: %{r: r, g: g, b: b}

  # The command struct this value-type accepts; an actuator view derives its
  # PubSub subscribe from this — the view never hard-codes a struct (the
  # value-type names it).
  @impl BBMCUHub.ValueType
  def command_message, do: SegbyV1.Messages.LedColor
end
```

The verifier requires a non-`nil` `command_message` on every command (`dir: :in`)
port, so a sense value-type on a command port fails loud at compile time.

**Why first:** a value-type is named by a **port** (Step 2). The same value-type
composes across many hubs and robots, so it is the unit you author first and reuse.

---

## Step 2 — Hub modules (the ports on a node)

A **hub module** (`use BBMCUHub.Hub`) declares one hub's ports and their
**intrinsic wire facts** — everything true about the _device_, independent of where
it is deployed (CONTEXT.md → **Hub module**). Each `port(:name, ...)` in a
`ports do ... end` block names its `dir` (`:in` command / `:out` produced), value
`type` (a stock atom or a value-type module), and `rate` (Hz). A produced port may
carry `t_dev: true` to ship the producer's µs stamp (§04), and may declare a
`sample:` MFA. A command port may declare a `step:` MFA.

A **command** port (`dir: :in`) that drives hardware states its floored role
explicitly with the **required** `has_safe_action` boolean (ADR-0005):

- `has_safe_action: true` ⇒ floored — you MUST give a `safe_action` value (a
  `%{field => number}` map, a literal value of the port's own value-type — the
  **dead-man floor**'s safe state, the same **layout** the command rides on the
  wire). The port gets an on-chip **floor**.
- `has_safe_action: false` ⇒ a non-floored actuator (e.g. a decorative LED): no
  floor, no `safe_action`.

Because the flag is required, a floored port is never silently floorless — a
forgotten safe action is a compile error.

Worked reference — the leaf **Wheels** hub, two `:effort` command ports (each
floored to zero torque) + two `:status` ports
([`hubs/wheels.ex`](../examples/segby_v1/lib/segby_v1/hubs/wheels.ex)):

```elixir
defmodule SegbyV1.Hubs.Wheels do
  use BBMCUHub.Hub

  ports do
    port(:motor_left,
      dir: :in,
      type: :effort,
      rate: 50,
      has_safe_action: true,
      safe_action: %{nm: 0.0},        # zero torque (ADR-0005), the floor's safe state
      step: {SegbyV1.Hubs.Wheels.Floor, :step}
    )

    port(:motor_right, dir: :in, type: :effort, rate: 50,
      has_safe_action: true, safe_action: %{nm: 0.0},
      step: {SegbyV1.Hubs.Wheels.Floor, :step})

    port(:status_left, dir: :out, type: :status, rate: 50)
    port(:status_right, dir: :out, type: :status, rate: 50)
  end
end
```

And the root **Blaster** hub — sense ports + a non-floored LED actuator
([`hubs/blaster.ex`](../examples/segby_v1/lib/segby_v1/hubs/blaster.ex)):

```elixir
defmodule SegbyV1.Hubs.Blaster do
  use BBMCUHub.Hub

  ports do
    port(:pose, dir: :out, type: :imu, rate: 100, t_dev: true,
      sample: {SegbyV1.Hubs.Blaster.SamplePose, :sample})

    port(:range_front, dir: :out, type: SegbyV1.ValueTypes.Range, rate: 20,
      sample: {SegbyV1.Hubs.Blaster.SampleRange, :sample})

    port(:status_led, dir: :in, type: SegbyV1.ValueTypes.Led, rate: 20,
      has_safe_action: false)        # decorative — non-floored (ADR-0005)
  end
end
```

A port names a stock value-type by atom (`type: :imu`) or a consumer value-type by
module (`type: SegbyV1.ValueTypes.Led`); `BBMCUHub.ValueType.resolve/1` maps atoms
to modules and passes modules through unchanged. The `sample`/`step` MFA refs are
**declared data only** — the host never invokes them; they travel into the
generated per-hub schedule for the firmware.

**Why second:** a hub module's ports reference the value-types from Step 1; the
robot (Step 3) places these hub modules on nodes.

---

## Step 3 — The robot (place hubs, declare topology)

The robot is a `use BB, extensions: [BBMCUHub.Dsl]` module. The hub-gateway DSL
(`BBMCUHub.Dsl`) adds two blocks alongside BeamBots' own. The canonical, complete
reference is [`lib/segby_v1/robot.ex`](../examples/segby_v1/lib/segby_v1/robot.ex)
— mirror its shape.

### `hubs do ... end` — place each hub on a node, declare topology

Each `hub(:name, MyApp.Hubs.Foo, node: 0xNN, parent:, uplink:)` places a hub module
on a **NODE** id and DECLARES the **link** to its parent (ADR-0006: topology is
declared, not inferred). The **root hub** declares `parent: :host` — it is the one
hub that owns the host UART, and it declares **no** `uplink` (its uplink is the
host UART, fixed). A non-root hub declares both `parent: :some_hub` and an
`uplink: :uart | :can` (the transport of its parent **link**).

```elixir
use BB, extensions: [BBMCUHub.Dsl]

hubs do
  # The root (parent: :host) owns the host UART; the wheels leaf hangs off it
  # over a UART link (ADR-0006).
  hub(:blaster, SegbyV1.Hubs.Blaster, node: 0x02, parent: :host)
  hub(:wheels, SegbyV1.Hubs.Wheels, node: 0x05, parent: :blaster, uplink: :uart)
end
```

> Do **not** use any `transport:` key — that was the pre-ADR-0006 model. The
> current DSL is `parent:` / `uplink:`. The **Topology validation** verifier checks
> the tree at compile time (exactly one `parent: :host` root, the root declares no
> `uplink`, every non-root declares one, every parent resolves, no cycles, fully
> connected) — a malformed tree refuses to compile.

### `topology do ... end` — the BeamBots links/joints and the views

This is BeamBots' own topology, where `sensor(...)` / `actuator(...)` views name
the **hub + port** they read. A sensor view names `{BBMCUHub.BBHub.Sensor, hub:,
port:, fresh_for:, beat_ms:}`; an actuator view names `{BBMCUHub.BBHub.Actuator,
hub:, port:, status_port:, fresh_for:}` (its `status_port:` is the hub's matching
**Status slot**, read for liveness rather than inferred from "we sent a command").
`fresh_for` is the consumer's freshness window as a multiple of the producer
period (§04, CONTEXT.md → **fresh_for · born-stale**).

```elixir
topology do
  link :base_link do
    sensor(:chassis_imu,
      {BBMCUHub.BBHub.Sensor, hub: :blaster, port: :pose, fresh_for: 3, beat_ms: 10})

    joint :left_wheel do
      type(:continuous)
      axis do end
      limit do
        effort(~u(10 newton_meter))
        velocity(~u(20 radian_per_second))
      end

      actuator(:left_drive,
        {BBMCUHub.BBHub.Actuator,
         hub: :wheels, port: :motor_left, status_port: :status_left, fresh_for: 5})

      link :left_wheel_link do end
    end
    # ... right_wheel mirrors left
  end
end
```

The full file also carries the `controllers do` (the host balance loop) and
`commands do` (operator teleop) blocks — read it for the complete shape. The
verifier reconciles every `(hub, port)` a view names against exactly one producer
in the IR.

**Why third:** the robot consumes the hub modules (Step 2). It is also the **input
to the generator** (Step 4) — the one authored model the wire artifacts derive
from.

---

## Step 4 — Generate the wire artifacts (`mix wire.gen`)

From the one robot model a generator emits the C side so the C and Elixir codecs
**cannot drift**. A consumer adds a `wire.gen` alias to `mix.exs` wrapping the
library task `wire.gen.run` with its own robot, slug, and output base. The real
example alias ([`mix.exs`](../examples/segby_v1/mix.exs)):

```elixir
defp aliases do
  [
    "wire.gen": [
      "wire.gen.run --robot SegbyV1.Robot --slug segby_v1 " <>
        "--gen-dir firmware/gen --fixtures-dir test/fixtures"
    ]
  ]
end
```

- `--robot MyApp.Robot` — your robot module (generation is always explicit-robot;
  there is no library default).
- `--slug my_app` — the per-robot artifact dir name; headers land under
  `firmware/gen/<slug>/`.
- `--gen-dir firmware/gen` / `--fixtures-dir test/fixtures` — resolved relative to
  your app root, so artifacts land in **your** tree, not the library's (ADR-0003).

Run `mix wire.gen`. Into `firmware/gen/<slug>/` it writes:

- **`wire_contract.h`** — the packed value structs + facts, including the generated
  `ROOT_NODE` (from the hub that declared `parent: :host`), the per-link transport
  facts (`LINK<k>_TRANSPORT_UART`), the port ids, and the per-actuator floor window.
- **`<hub>.glue.h`** (per hub) — the generated main-loop glue (route table,
  `hub_on_body`, command dispatch, the floor plumbing, the schedule).
- **`<hub>.device.h`** (per hub) — the **device-hook prototypes** you must
  implement (Step 5).

A **drift test** gates that committed artifacts match fresh generation. So the rule
after any contract or topology change is one command: **`mix wire.gen` + commit.**

**Why fourth:** the generator needs the complete robot (Step 3). Its outputs are
what Steps 5 and 6 consume.

---

## Step 5 — Device hooks (the only firmware you hand-write)

Everything mechanical — the router table, `hub_on_body`, command dispatch, the
floor `init`/`on_command`/`control_tick`/status plumbing, the schedule — is
**generated** into `<hub>.glue.h` from the IR, so the safety-critical seq/floor
wiring is never hand-written (CONTEXT.md → **Firmware hook**). You hand-write only
the thin **firmware hook** seam: implement the prototypes the generator emitted into
`gen/<slug>/<hub>.device.h`, in `mcu/<hub>.{c,cpp}`.

> **The gen/ vs mcu/ split is the rule.** Everything under any `gen/` is
> **generated and drift-tested — never hand-edited**; everything under `mcu/` is
> **hand-authored** device hooks. This is the only firmware a consumer writes.

The generated prototypes (e.g.
[`gen/segby_v1/wheels.device.h`](../examples/segby_v1/firmware/gen/segby_v1/wheels.device.h))
are well-known C names the glue calls — `<hub>_device_setup()` plus, per port, a
`<hub>_<port>_read` (sense) or `<hub>_<port>_drive` (act) hook, and an optional
`<hub>_post_control()`. The hook _signature_ is owned by the port's value-type
(e.g. a single numeric field passes by value; a multi-field value as a `const
<Struct> *`):

```c
/* GENERATED into wheels.device.h — the contract you implement in mcu/wheels.cpp */
void wheels_device_setup(void);          /* one-time bring-up; the WDT is armed AFTER this */
void wheels_motor_left_drive(float);     /* apply to the plant */
void wheels_motor_right_drive(float);    /* apply to the plant */
void wheels_post_control(void);          /* OPTIONAL per-loop telemetry */
```

Implement them in `mcu/<hub>.cpp` (worked references:
[`firmware/mcu/wheels.cpp`](../examples/segby_v1/firmware/mcu/wheels.cpp),
[`firmware/mcu/blaster.cpp`](../examples/segby_v1/firmware/mcu/blaster.cpp)). Two
rules the chassis enforces: `<hub>_device_setup()` may run as long as it needs (the
task watchdog is armed **after** setup, so a slow `initFOC`/I²C settle never
boot-loops the chip — §08), and every `_read`/`_drive` tick must be **bounded** (no
spin/blocking; a read that can't complete returns `false` and goes stale, legible).

**Why fifth:** the prototypes you implement come from Step 4's generation. The
hooks are compiled by Step 6's envs.

---

## Step 6 — `platformio.ini` envs (one env per hub)

One PlatformIO env per hub. Each env: `-Igen/<slug>` (find the generated headers),
`-DMY_NODE=0xNN` (this hub's node id — **required**, and now also drives root-ness
via the generated `ROOT_NODE`), `build_src_filter +<mcu/<hub>.cpp>` (compile only
this hub's device file), `lib_deps symlink://<path>/firmware` (pull the C chassis),
and on the **root** env `-DHOST_UART_BAUD`. There is **no `-DROOT_HUB`** — root-ness
is generated: the chassis computes `IS_ROOT = (MY_NODE == ROOT_NODE)`, where
`ROOT_NODE` is generated from the DSL's `parent: :host` (ADR-0006), so the root
env's `MY_NODE` must equal the declared root node.

A fully-commented, ready-to-adapt template lives at
[`docs/templates/platformio.ini.example`](templates/platformio.ini.example) — copy
it to `<your-app>/firmware/platformio.ini` and replace the marked placeholders
(`<slug>`, `<hub>`, `<path>`, `0xNN`, `<baud>`). The example's real file is
[`examples/segby_v1/firmware/platformio.ini`](../examples/segby_v1/firmware/platformio.ini).
The root env, distilled:

```ini
[env:blaster_root]
build_flags =
  ${env.build_flags}
  -Igen/segby_v1            ; the generated-headers include path
  -DMY_NODE=0x02            ; this hub's node id; == ROOT_NODE, so this is the root
  -DHOST_UART_BAUD=115200   ; ROOT ENV ONLY; must match the host transport baud
build_src_filter =
  +<mcu/blaster.cpp>        ; compile ONLY this hub's device file
```

Note the `[env]` base carries `platform = <pioarduino fork>` and `lib_deps =
symlink://../../../firmware`: the **pioarduino fork** of `platform-espressif32` is
required for arduino-esp32 3.x / ESP-IDF 5.x (where the TWAI/CAN driver the chassis
uses lives), and `lib_deps` pulls the chassis (codec/scheduler/router/transport/
floor/segment + the esp32 link layer + the generic main loop) as a PlatformIO
library, not by globbing the library's sources.

**Why sixth:** an env needs both the generated headers (Step 4) and the device file
(Step 5) to compile.

---

## Step 7 — Host launcher (a thin wrapper over `BBMCUHub.Host`)

The generic launcher `BBMCUHub.Host` derives the command slots from the robot's IR
and wires the standard `BB.Supervisor` + **LinkOwner** (the process that owns the
host↔root-hub UART) tree. Your launcher is a thin wrapper that just forwards
`robot: MyApp.Robot` plus the operator's transport opts. Worked reference —
[`lib/segby_v1/host.ex`](../examples/segby_v1/lib/segby_v1/host.ex):

```elixir
defmodule SegbyV1.Host do
  alias BBMCUHub.Host

  @robot SegbyV1.Robot

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Host.start_link([robot: @robot] ++ opts)
  end
end
```

`start_link/1` accepts `:transport` (a `BBMCUHub.Host.Transport` module, default
`BBMCUHub.Host.Transport.UART`), `:transport_opts` (e.g. `[port: "ttyAMA0", baud:
115_200]`), `:bb_opts`, and `:name`. The transport baud here must match the root
firmware's `-DHOST_UART_BAUD` (Step 6). A test can inject a loopback transport to
run the whole host stack with no hardware.

**Why last on the software side:** the launcher runs the robot's IR (Step 3) over
the transport that talks to the firmware you flashed (Steps 4–6).

---

## What's next — hand off to BRINGUP.md

At this point your robot host-builds and your firmware envs compile (`mix test`,
`cd firmware/test && make` for the chassis harnesses, and `pio run -e <hub>_root` /
`pio run -e <hub>_leaf` for each env — see [`CLAUDE.md`](../CLAUDE.md) → Build &
test). Software assembly is done.

Take it onto hardware with the example's
[`BRINGUP.md`](../examples/segby_v1/BRINGUP.md), which owns the **on-hardware**
stages — flashing, wiring the links, confirming frames cross, motor-sign
calibration, IMU + closed-loop bring-up, and the dashboard — in independently
verifiable Stages −1 → 5. (Two things only hardware/QEMU can prove are deliberately
out of the host-test scope: the WDT boot-loop and motor-sign calibration.)

### Cross-references

- [`README.md`](../README.md) — reference: the consumer-vs-library table, the
  spines, the port-flow diagram.
- [`CONTEXT.md`](../CONTEXT.md) — the domain glossary (Hub, Value-type, Link,
  Floor, Safe action, Firmware hook, …).
- [`docs/hub-design.html`](hub-design.html) — the full architecture and `§`
  sections.
- ADRs: [0003](adr/0003-library-example-split.md) (library/example split),
  [0005](adr/0005-safe-action-is-a-value-type-value.md) (safe-action is a
  value-type value), [0006](adr/0006-links-are-declared-not-inferred.md) (declared
  topology).
