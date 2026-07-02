# `firmware/` — the bb_mcuhub C chassis (a PlatformIO library)

This is a **self-contained PlatformIO library**, not a deployable PlatformIO
project. There is intentionally **no `platformio.ini`** here: the chassis has no
env of its own — it is consumed, not flashed.

- `library.json` packages `src/` + `include/` as a PlatformIO library a consumer
  pulls via `lib_deps`. `src/` is the shared
  chassis (codec, scheduler, router, transport, floor, segment) plus the
  arduino-esp32 link layer and generic hub main loop under `src/esp32/` (all
  `#if defined(ARDUINO)`-guarded so the host harnesses still build); `include/`
  is the chassis headers.
- A consumer's firmware build = this library (via `lib_deps`) + the consumer's own
  generated per-hub glue (`-Igen/<slug>`) + its hand-authored device hooks
  (`mcu/<hub>.cpp`). See
  [`examples/segby_v1/firmware/platformio.ini`](../examples/segby_v1/firmware/platformio.ini)
  for the worked example (envs `blaster_root` + `wheels_leaf`, both pulling this
  chassis), or start from
  [`docs/templates/platformio.ini.example`](../docs/templates/platformio.ini.example).

**To build against this chassis, two things are non-negotiable:**

1. the ESP32 platform must be the
   [`pioarduino`](https://github.com/pioarduino/platform-espressif32) fork of
   `platform-espressif32` (arduino-esp32 3.x / ESP-IDF 5.x) — the stock platform
   will not build it; and
2. every env must pass its hub's node id as a build flag, `-DMY_NODE=0xNN`,
   matching the `node:` declared in the robot's `hubs do` block.

Both are shown in the example `platformio.ini` and walked through in
[`docs/NEW-ROBOT.md`](../docs/NEW-ROBOT.md) (Step 6).

- `gen/robot/` holds the **test fixture robot's** generated artifacts (host-only;
  the fixture has no ESP32 env — it is a drift + C-parity witness, not a robot).
- `test/` is the **host-compiled C harness** (built with its own `Makefile`, not
  PlatformIO): it cross-validates the C codec against the fixture's generated
  parity vectors, plus the floor / router / segment / UART-backplane behaviour.
  Build it with `cd firmware/test && make` (or it runs inside `mix test`).

## Writing device hooks (the only firmware you author)

Everything mechanical — router, dispatch, floor plumbing, schedule, the host↔root
and backplane links — is **generated** into `gen/<slug>/<hub>.glue.h` from your
contract. You implement only a small set of hooks per hub, declared in the
generated `gen/<slug>/<hub>.device.h`:

- `void <hub>_device_setup(void)` — one-time hardware bring-up (pins, peripherals,
  FOC/encoder init).
- per sense port: `bool <hub>_<port>_read(<ValueStruct> *out)` — fill the value,
  return `false` to skip this sample.
- per command port: `void <hub>_<port>_drive(float v)` (single-field value) or
  `void <hub>_<port>_drive(const <ValueStruct> *v)` (multi-field).
- optional: `void <hub>_post_control(void)` — per-loop telemetry, run after the
  control tick. A no-op default is generated; to supply your own, `#define
<HUB>_POST_CONTROL_OVERRIDE` before `#include`-ing `<hub>.glue.h`.

Two rules to know, both already enforced by the chassis:

1. **`_device_setup()` may take as long as it needs.** A SimpleFOC `initFOC()`
   alignment spins the motor for seconds; an i2c-ng bus needs a settle delay; a
   sensor wants a calibration pass — all fine. The task watchdog is subscribed
   **after** setup completes, so it guards the steady-state loop, not bring-up.
   (Watchdogging setup is the classic FOC boot-loop: the chip resets
   mid-alignment, before the loop can ever feed the timer, and never finishes
   initialising — symptom: the ESP32 ROM banner repeating with
   `task_wdt … did not reset … Rebooting`. The chassis avoids it by construction;
   you need no watchdog code.)
2. **Every `_read`/`_drive` tick must be bounded** — no spin, no unbounded wait.
   Use a device-read timeout (e.g. `Wire.setTimeOut`) and return promptly; a read
   that can't complete returns `false` and writes nothing (its `seq` stalls, the
   reader goes stale — legible, not a hang). This is what keeps the cooperative
   scheduler and the on-chip floor timely.

See
[`examples/segby_v1/firmware/mcu/`](../examples/segby_v1/firmware/mcu/)
(`blaster.cpp`, `wheels.cpp`) for worked hooks (real MPU-9250, HC-SR04, and
dual-FOC bring-up), and [`docs/NEW-ROBOT.md`](../docs/NEW-ROBOT.md) for the
full ordered walkthrough this file is Step 5–6 of.
