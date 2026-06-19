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
- **A generated contract** — one model renders the C header, the per-hub
  schedule, and the parity vectors; a drift test fails the build if the C and
  Elixir sides could disagree.

## Status — v1 walking skeleton

A tracer bullet runs end-to-end through both languages: an IMU sense port and a
motor effort port, with the real wire, the real floor, the real generated
contract, and the two BeamBots views. Everything below is verified:

| Layer         | What                                       | Verified by                        |
| ------------- | ------------------------------------------ | ---------------------------------- |
| Wire (Elixir) | CRC-16, COBS, framing seam                 | `test/wire/` (incl. property test) |
| Wire (C)      | byte-identical codec + floor               | `firmware/test/` host harnesses    |
| Contract      | generator + drift + parity                 | `test/gen/`                        |
| Host          | registry, monitor (born-stale), link owner | `test/host/`                       |
| BeamBots      | `BB.Sensor` / `BB.Actuator` views          | `test/slice_test.exs`              |
| Firmware      | ESP32 images (`imu_root`, `motor_leaf`)    | `pio run` (both build)             |

The **cross-language witness**: `mix test` builds and runs the C harness, which
asserts the C codec produces the _same_ bytes and CRC as the Elixir parity
vectors. The wire cannot drift past it.

Deferred items (arm-nonce, `fw_id`/board-identity, conflation/backpressure,
wire-budget, host coordination, CAN-FD segmentation, …) are named in the design,
default to the safe behaviour, and are not yet implemented.

## Layout

```
lib/bb_mcuhub/        the host platform (every robot gets this, never edits it)
  wire/               crc16 · cobs · framing_cobs · codec · stats
  contract/           layouts · source · port_index   (+ contract.ex)
  gen/                wire_gen — the one generator (§06)
  host/               node_registry · monitor · link_owner · transport
  bb_hub/             sensor · actuator · lift — the BeamBots seam (§09)
hubs/                 one folder per capability: a pure sample/step + a contract
  imu/                lib/sample_pose.ex · mcu/*.c · contract.exs · schedule.gen.h
  motor/              lib/floor.ex · mcu/*.c · contract.exs · schedule.gen.h
robots/               a robot = BeamBots topology
  follower/           lib/follower.ex · topology.exs
firmware/             the C hub chassis (shared by every hub)
  include/ src/       crc16 · cobs · frame · transport · scheduler · router · floor
  src/esp32/          link_esp32 · hub_main (Arduino/ESP32 glue)
  test/               host-compiled parity + floor harnesses
  platformio.ini      two envs: imu_root (root hub), motor_leaf (CAN leaf)
```

`platform → hubs → robots`; the dependency arrow points only downward. The wire
contract is **generated, never hand-written**.

## Build & test

### Host (Elixir)

```sh
mix deps.get
mix test            # runs the full suite incl. the host-compiled C parity witness
mix wire.gen        # regenerate the contract artifacts (C header, schedule, vectors)
```

Requires Elixir 1.18+. (The `bb` dependency requests 1.19; it runs fine on 1.18 —
the requirement is a compile-time warning only.)

### Firmware (C, host-compiled)

```sh
cd firmware/test && make    # build + run the parity and floor harnesses (clang/gcc)
```

### Firmware (ESP32, PlatformIO)

Toolchain matches the pioarduino fork for arduino-esp32 3.x (ESP-IDF 5.x):

```sh
cd firmware
pio run -e imu_root      # the IMU board, built as the root hub (UART↔CAN + sense)
pio run -e motor_leaf    # the wheel motor, a CAN leaf with the on-chip floor
pio run -e imu_root -t upload   # flash
```

## How a port flows (the slice)

```
IMU hub  --sample-->  frame (seq, t_dev)  --COBS+CRC-->  UART/CAN
   |                                                        |
   |                                          host LinkOwner decodes -> registry
   |                                                        |
   |                          Sensor view: born-stale gate -> BB.Message.Sensor.Imu
   v                                                        v
 (a leaf on the tree)                              BeamBots PubSub

BeamBots Effort command  ->  Actuator view (sole writer) -> command slot
   ->  LinkOwner drains on seq advance  ->  COBS+CRC  ->  wire  ->  motor hub
   ->  the on-chip floor decides arm vs safe (born-disarmed, dead-man on seq)
```

See `docs/hub-design.html` for the full rationale.
