# segby_v1 — hardware bring-up checklist

`segby_v1` is a two-wheel self-balancing bot ported onto `bb_mcuhub`: a Pi
**host** ↔ UART ↔ **Blaster** root hub (ESP32) ↔ UART backplane ↔ **Wheels** leaf
hub (MKS Dual FOC, dual SimpleFOC). This guide brings it up in independently
verifiable stages — do them in order; fix each before moving on. Everything below
host-builds green; this is the half only real hardware can prove.

> Authoritative facts (from the build): backplane is **UART** (no CAN —
> `BACKPLANE_TRANSPORT_UART 1`). Blaster = NODE `0x02` (root), Wheels = NODE `0x05`
> (leaf). All links COBS+CRC @ **1 Mbit/s**. Per-wheel floor window = 5 × 20 ms =
> **100 ms** of command silence → that wheel de-energises (born-disarmed).

## Boards & roles

| Board | Role | NODE | PlatformIO env |
| --- | --- | --- | --- |
| Pi Zero 2 W | host (Elixir/Nerves) | — (logical 0) | — (`mix bb.tui`) |
| DOIT V1 ESP32 | Blaster — root hub (IMU/range/LED + bridge) | 0x02 | `blaster_root` |
| MKS Dual FOC v3.2 (ESP32 Lolin32-Lite) | Wheels — leaf (dual FOC) | 0x05 | `wheels_leaf` |

## Wiring (3 links + motors)

**1. Host ↔ Blaster UART** (the seam `LinkOwner` owns):

| Pi | ↔ | Blaster |
| --- | --- | --- |
| GPIO 14 TXD | → | GPIO 16 (host RX) |
| GPIO 15 RXD | ← | GPIO 17 (host TX) |
| GND | — | GND |

Pi side: PL011 on `/dev/ttyAMA0` (NOT mini-UART) — `enable_uart=1`, disable the
serial console, `dtoverlay=disable-bt` (or `miniuart-bt`) so PL011 lands on 14/15.

**2. Backplane: Blaster ↔ Wheels UART** (cross TX↔RX + common GND):

| Blaster (root) | ↔ | Wheels (leaf) |
| --- | --- | --- |
| GPIO 26 (backplane TX) | → | GPIO 16 (leaf RX) |
| GPIO 27 (backplane RX) | ← | GPIO 17 (leaf TX) |
| GND | — | GND |

(Defaults from `link_esp32.cpp`: root `BACKPLANE_UART_TX_PIN 26 / RX 27`, leaf
`17/16`. No termination — it's a UART, not a CAN bus.)

**3. IMU: MPU-9250 on the Blaster I²C** — SDA 21, SCL 22, VCC 3V3, GND, AD0→GND
(addr 0x68). *(Synthetic stub today — see "What's stubbed" — wire it before
Stage 4.)*

**Motors + encoders (Wheels / MKS board)** — per `main_wheels.cpp`: M0 PWM
32/33/25, M1 PWM 26/27/14, shared enable 12; AS5600 M0 on Wire (SDA 19/SCL 18),
M1 on Wire1 (SDA 23/SCL 5); 12 V to VIN. **Confirm against the MKS v3.2
silkscreen** (pins are TODO-flagged in the firmware).

## Flash

```sh
cd firmware
# the toolchain is in .pio-venv / .pio-core (gitignored)
PIO="PLATFORMIO_CORE_DIR=$PWD/../.pio-core ../.pio-venv/bin/pio"
$PIO run -e blaster_root -t upload      # USB to the DOIT V1
$PIO run -e wheels_leaf  -t upload      # USB to the MKS board
$PIO device monitor -b 115200           # console (note: console=115200, links=1 Mbit/s)
```

Host: `mix bb.tui --robot BBMcuhub.Robots.SegbyV1` (the dashboard owns the UART
via `BBMcuhub.Robots.SegbyV1.Host`; on the Pi pass
`transport_opts: [port: "ttyAMA0"]`).

## Stages — verify each before the next

### Stage 0 — both ESP32s boot, no reset loop
Flash + monitor each. Expect a clean boot, no panic/reset loop. The Wheels board
runs an AS5600-presence probe before `initFOC` — if an encoder is absent that
motor stays disabled (born-disarmed) but the board still boots and the link comes
up. (A hung `initFOC` = a motor/encoder wiring problem, Stage 3 — but the UART
must still come up.)

### Stage 1 — loopback each board's backplane UART (no cross-wire yet)
Prove each board's own UART2 path before trusting the link. Jumper the board's own
backplane TX↔RX:
- **Blaster**: jumper GPIO 26 ↔ 27.
- **Wheels**: jumper GPIO 17 ↔ 16.
Every frame the board sends should echo straight back. A `tx` with no matching
`rx` ⇒ that board's UART path is broken (pin map / silicon), not the inter-board
wiring.

### Stage 2 — cross-wire the backplane, confirm frames cross
Wire link #2. With both monitors open: the Blaster should relay the Wheels'
status frames (NODE 0x05) upward, and the host (Stage 4) drives commands down. No
frames crossing ⇒ recheck TX↔RX crossed + common GND (the usual culprit is a
missing ground or an unseated Dupont pin).

### Stage 3 — motors (Wheels board), 12 V applied
Command a small effort to one wheel at a time and confirm each spins (M0 = left,
M1 = right). Each wheel is gated by its **own floor**: with no fresh command for
100 ms it de-energises. If a wheel won't align, sanity-check that motor + its
AS5600 (the firmware skips a motor whose encoder didn't ACK — check the boot log).
Confirm **pole pairs** (firmware assumes 10 — TODO) and the PWM/encoder pins match
the MKS silkscreen.

### Stage 4 — IMU + closed-loop balance
Wire the real MPU-9250 (link #3) and replace the synthetic `imu_read` (see below).
With the host up:
```sh
# on the Pi, confirm pose flows:
BB.subscribe(BBMcuhub.Robots.SegbyV1, [:sensor, :base_link, :chassis_imu])
# tilt the chassis → pitch should track tilt (non-zero, correct sign)
```
Then **enable balance**: `BBMcuhub.Segby.Balance.enable(BBMcuhub.Robots.SegbyV1)`
and confirm the wheels react to hold upright. PID gains (kp 0.5, ki 0.05, kd 0.1)
are placeholders — **tune on the real chassis**.

### Stage 5 — bb_tui dashboard + teleop
`mix bb.tui --robot BBMcuhub.Robots.SegbyV1`. Confirm the panels populate (joints,
safety, events). Operator drive is the declared **`teleop` command** (forward/turn)
in bb_tui's Commands panel — running it biases the balance output (forward leans
both wheels, turn differentials them). Arm/disarm from the safety panel; recall
the on-chip floor is the real safe-state — disarm/silence both resolve to wheels
de-energising within 100 ms.

## What's stubbed (replace for real flight)
- **Blaster device reads are synthetic**: `imu_read` returns a fixed upright pose,
  `range_read` a fixed distance (`hubs/blaster/mcu/main_blaster.cpp`). Bind the
  real MPU-9250 (I²C 0x68) + HC-SR04 drivers before Stage 4. The WS2812
  `status_led_apply` is a no-op (decode wired; bind a real LED lib if wanted).
- **Wheels FOC pins / pole-pairs** are from the reference + TODO-flagged — confirm
  against the actual MKS v3.2 board and motors.
- **torque→Uq** is the reference's honest first-cut (effort = q-axis voltage,
  clamped); revisit once a current-sense topology is chosen.

## Safety reminders
- **Born-disarmed**: every wheel boots de-energised and only drives after it
  witnesses a fresh, in-window command `seq` advancing since its own boot. A
  reboot/glitch cannot energise a wheel.
- **Floor is the guarantee**: command silence > 100 ms → that wheel floors.
  Everything host-side (balance, teleop, the dashboard) is best-effort on top.
- Keep the chassis on a stand / leash for the first powered balance test.
