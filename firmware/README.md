# `firmware/` — the bb_mcuhub C chassis (a PlatformIO library)

This is a **self-contained PlatformIO library**, not a deployable PlatformIO
project. There is intentionally **no `platformio.ini`** here: the chassis has no
env of its own — it is consumed, not flashed.

- `library.json` packages `src/` + `include/` as a PlatformIO library a consumer
  pulls via `lib_deps` (see ADR-0003). `src/` is the shared chassis (codec,
  scheduler, router, transport, floor, segment) plus the arduino-esp32 link layer
  and generic hub main loop under `src/esp32/` (all `#if defined(ARDUINO)`-guarded
  so the host harnesses still build); `include/` is the chassis headers.
- A consumer's firmware build = this library (via `lib_deps`) + the consumer's own
  generated per-hub glue (`-Igen/<slug>`) + its hand-authored device hooks
  (`mcu/<hub>.cpp`). See `examples/segby_v1/firmware/platformio.ini` for the
  worked example (envs `blaster_root` + `wheels_leaf`, both pulling this chassis).
- `gen/robot/` holds the **test fixture robot's** generated artifacts (host-only;
  the fixture has no ESP32 env — it is a drift + C-parity witness, not a robot).
- `test/` is the **host-compiled C harness** (built with its own `Makefile`, not
  PlatformIO): it cross-validates the C codec against the fixture's generated
  parity vectors, plus the floor / router / segment / UART-backplane behaviour.
  Build it with `cd firmware/test && make` (or it runs inside `mix test`).
