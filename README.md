# bb_mcuhub

Reach microcontroller hardware from the [BeamBots](https://hex.pm/packages/bb)
ecosystem through one recursive abstraction: the **hub**. A hub can sense, act,
and route to child hubs — and because every hub is the same shape, hubs compose
into a tree of any depth, from a host (Raspberry Pi running Elixir) down to a
leaf on a wire.

This is the implementation of the design in [`docs/hub-design.html`](docs/hub-design.html);
the load-bearing vocabulary is glossed in [`CONTEXT.md`](CONTEXT.md). v1 is a
small, robust core that does four things well:

- **A correct frame** — `NODE · PORT · SEQ · T_DEV · PAYLOAD`, COBS-framed with a
  real, pinned **CRC-16/CCITT-FALSE** (check value `0x29B1`).
- **Clock-free freshness** — trust is a counter (`seq` advance), not a clock;
  consumers are _born stale_.
- **A fail-passive floor** — each actuator hub de-energises on command-`seq`
  silence, on its own chip; _born disarmed_, motion is earned.
- **A generated contract** — one model renders the C header, the per-hub firmware
  glue, and the parity vectors; a drift test fails the build if the C and Elixir
  sides could disagree.

## A reusable library + a worked example

`bb_mcuhub` is a **library** you pull in (alongside `bb`, `bb_tui`) to build your
_own_ robot, supplying only device-specific logic. The
[`examples/segby_v1/`](examples/segby_v1/) app is a separate Mix project that
depends on the library exactly as a downstream consumer would — a Mix `path`
dependency on the host side, a PlatformIO `lib_deps` dependency on the firmware
side — and is the worked example: a two-wheel self-balancing bot. The boundary is
the product (see [`docs/adr/0003-library-example-split.md`](docs/adr/0003-library-example-split.md)).

What a consumer writes vs. what the library provides:

| You write (your project)                                     | The library provides                                    |
| ------------------------------------------------------------ | ------------------------------------------------------- |
| **Value-types** (`use BBMcuhub.ValueType`) — your wire vocab | a stock set (`imu`, `effort`, `status`)                 |
| **Hub modules** (`use BBMcuhub.Hub`) — your ports            | the DSL, the IR projection + compile-time verifier      |
| **A robot** (`use BB, extensions: [BBMcuhub.Dsl]`)           | the generic `BBMcuhub.Host` launcher                    |
| **Device hooks** (`<hub>_<port>_read`/`_drive`, in C)        | the **generated** per-hub firmware glue + the C chassis |

The two extensibility spines: a **value-type** is a standalone, cross-bot module
(layout + host `lift`/`unlift` + the firmware-hook signature) — add your own with
no library edit; and the per-hub firmware **glue is generated from the IR**, so
the safety-critical seq/floor wiring is never hand-written.

Everything is verified:

| Layer             | What                                                                | Verified by                            |
| ----------------- | ------------------------------------------------------------------- | -------------------------------------- |
| Wire (Elixir)     | CRC-16, COBS, framing seam                                          | `test/wire/` (incl. property test)     |
| Wire (C)          | byte-identical codec + floor                                        | `firmware/test/` host harnesses        |
| Contract          | generator + drift + parity (per robot)                              | `test/gen/` + the example's drift test |
| Host              | registry, monitor (born-stale), link owner                          | `test/host/`                           |
| BeamBots          | `BB.Sensor` / `BB.Actuator` views (value-type-agnostic)             | `test/slice_test.exs`                  |
| Library self-test | a coverage-maximizing fixture robot (CAN+UART, a custom value-type) | `test/support/fixtures/`               |
| Example           | segby_v1 host + firmware as a real consumer                         | `examples/segby_v1/test/` + `pio run`  |

The **cross-language witness**: `mix test` builds and runs the C harness, which
asserts the C codec produces the _same_ bytes and CRC as the Elixir parity
vectors. The wire cannot drift past it. The library self-tests in isolation via
its fixture robot — which also defines its own custom value-type, so the
extension seam is CI-checked without the example present.

Deferred items (arm-nonce, `fw_id`/board-identity, conflation/backpressure,
wire-budget, host coordination, CAN-FD segmentation, …) are named in the design,
default to the safe behaviour, and are not yet implemented.

## Layout

```
lib/bb_mcuhub/        the library — every consumer gets this, never edits it
  wire/               crc16 · cobs · framing_cobs · codec · stats
  contract/           layouts (wire-type widths) · port_index   (+ contract.ex)
  value_type/         imu · effort · status — the stock value-types (§06)
  value_type.ex       the `use BBMcuhub.ValueType` behaviour + atom→module resolve
  dsl.ex              the `hubs do` extension: IR projection + compile-time verifier
  gen/                wire_gen — the one generator (§06)
  hub.ex              `use BBMcuhub.Hub` — declare a hub's ports
  host.ex             the generic `BBMcuhub.Host` launcher (derives slots from the IR)
  host/               node_registry · monitor · link_owner · transport (+ loopback)
  bb_hub/             sensor · actuator — the value-type-agnostic BeamBots seam (§09)
firmware/             the C chassis, packaged as a PlatformIO library (library.json)
  include/ src/       crc16 · cobs · frame · transport · scheduler · router · floor · segment
  src/esp32/          link_esp32 · hub_main (Arduino/ESP32 glue)
  test/               host-compiled parity/floor/router/segment/uart harnesses
  gen/robot/          the fixture robot's generated artifacts (drift witnesses)
test/support/fixtures/  a coverage-maximizing fixture robot — the library self-test

examples/segby_v1/    the worked example — a separate Mix app (a path-dep consumer)
  lib/segby_v1/       SegbyV1.Robot · Hubs.{Blaster,Wheels} · ValueTypes.{Range,Led}
                      · Balance · Teleop · Host (a thin wrapper over BBMcuhub.Host)
  firmware/mcu/       the hand-authored device hooks (the only firmware a consumer writes)
  firmware/gen/       the example's generated glue + headers (drift-tested)
  firmware/platformio.ini   blaster_root + wheels_leaf — consume the chassis via lib_deps
```

The dependency arrow points only downward: library ← example. Everything under any
`gen/` is **generated, never hand-written**; everything under `mcu/` is the
consumer's device hooks.

## Build & test

A reproducible toolchain (Elixir, PlatformIO, clang/make) is pinned in `flake.nix`
— run `nix develop` (or `direnv allow`) in any worktree first. See `CLAUDE.md`.

### Library (Elixir)

```sh
mix deps.get
mix test            # full suite incl. the host-compiled C parity witness + the fixture
mix wire.gen        # regenerate the fixture's artifacts (always explicit-robot;
                    #   a consumer runs `mix wire.gen --robot MyApp.MyRobot`)
```

### Library firmware (C, host-compiled)

```sh
cd firmware/test && make    # parity / floor / router / segment / uart harnesses
```

The library has no deployable ESP32 env of its own — `firmware/` is a chassis
**library** (`library.json`) a consumer pulls via `lib_deps`. The fixture robot is
host-tested only.

### The example (a consumer)

```sh
cd examples/segby_v1
mix deps.get && mix test                # the host stack, over the real framing seam
cd firmware && pio run -e blaster_root  # builds the chassis FROM the library via lib_deps
cd firmware && pio run -e wheels_leaf   # the dual-FOC leaf
```

Requires Elixir 1.18+. (The `bb` dependency requests 1.19; it runs fine on 1.18 —
the requirement is a compile-time warning only.)

## How a port flows

```
sense hub  --read hook-->  frame (seq, t_dev)  --COBS+CRC-->  UART/CAN
   |                                                        |
   |                                          host LinkOwner decodes -> registry
   |                                                        |
   |          Sensor view: born-stale gate -> value-type.lift -> BB.Message
   v                                                        v
 (a leaf on the tree)                              BeamBots PubSub

BeamBots command  ->  Actuator view (sole writer, value-type.unlift) -> command slot
   ->  LinkOwner drains on seq advance  ->  COBS+CRC  ->  wire  ->  actuator hub
   ->  the on-chip floor decides arm vs safe (born-disarmed, dead-man on seq)
```

See [`docs/hub-design.html`](docs/hub-design.html) for the full rationale and
[`CONTEXT.md`](CONTEXT.md) for the vocabulary.
