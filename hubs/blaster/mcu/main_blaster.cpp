/* Blaster hub sketch (§09). In the segby_v1 slice the Blaster board is the ROOT
 * HUB on a DOIT V1 ESP32: it senses its own pose (MPU-9250 at 100 Hz) + a
 * forward range (HC-SR04 at 20 Hz), drives a decorative WS2812 status strip, AND
 * bridges the host UART to the children-facing UART backplane (the wheels leaf,
 * NODE 0x05). Build with -DROOT_HUB -DMY_NODE=0x02.
 *
 * Mirrors hubs/imu/mcu/main_imu.cpp, extended for two OUT ports + one IN port.
 * The backplane is UART (not CAN): BACKPLANE_TRANSPORT_UART=1 comes from the
 * generated firmware/gen/segby_v1/wire_contract.h, so the link layer brings up
 * Serial2 as the backplane. A host-bound frame goes UP over the host UART; a
 * frame for NODE 0x05 goes DOWN over the backplane (§03/§04).
 *
 * This sketch supplies the board glue the generic hub_main expects: the schedule
 * table, hub_setup(), the inbound-body router (+ the LED command delivery), and
 * the bounded device reads (imu_read / range_read).
 *
 * The IMU read is the REAL MPU-9250 I²C driver, ported from climber's
 * Mpu9250Backend.cpp (the bot deployed on hardware): WHO_AM_I sanity-check, wake
 * + PLL clock, then a 14-byte burst from ACCEL_XOUT_H, big-endian hi/lo. The raw
 * int16 LSB are scaled HERE into the BB.Message.Sensor.Imu engineering units the
 * :imu layout wants — accel m/s², gyro rad/s — with an IDENTITY orientation
 * quaternion (the MCU does not fuse; the host's complementary filter recovers
 * pitch from accel+gyro). The HC-SR04 range read is the real trig/echo dance,
 * ported from climber's Hcsr04Component.cpp. WS2812 pixel push is still a no-op
 * (the decode path is fully wired; only the RMT/NeoPixel write is unbound — a
 * decorative LED has no floor, §09). All real-device calls are
 * ARDUINO-guarded; the host build keeps a deterministic stub so the pure-C sense
 * ticks (blaster_sensors.c) still host-compile. */
#if defined(ARDUINO)

#include <Arduino.h>
#include <Wire.h>
extern "C" {
#include "frame.h"
#include "scheduler.h"
#include "router.h"
#include "link.h"
#include "wire_contract.h"
}

/* the hub's pure-ish ticks (hubs/blaster/mcu/blaster_sensors.c) */
extern "C" void pose_sample_tick(uint32_t now_us);
extern "C" void range_front_sample_tick(uint32_t now_us);
extern "C" void status_led_cmd_tick(uint32_t now_us); /* no-op: LED is event-driven */

#include "schedule.gen.h" /* static Task tasks[]; N_TASKS — pose, range_front, status_led */

/* --- segby_v1 Blaster pin map (DOIT V1 ESP32), from bots/segby_v1/README.md
 * "Pin map" + blaster/BoardSupport.cpp — hardware-verified on the deployed bot.
 * The host UART (Serial) and the UART backplane (Serial2) pins are owned by the
 * link layer (link_esp32.cpp): backplane defaults TX 26 / RX 27 on a root hub,
 * which matches the README's "Cog UART TX 26 / RX 27 (UART2)". --- */
#ifndef IMU_I2C_SDA_PIN
#define IMU_I2C_SDA_PIN 21 /* MPU-9250 SDA (ESP32 chip-default I²C) */
#endif
#ifndef IMU_I2C_SCL_PIN
#define IMU_I2C_SCL_PIN 22 /* MPU-9250 SCL */
#endif
#ifndef RANGE_TRIG_PIN
#define RANGE_TRIG_PIN 18 /* HC-SR04 TRIG (output) */
#endif
#ifndef RANGE_ECHO_PIN
#define RANGE_ECHO_PIN 32 /* HC-SR04 ECHO (input-only pin) */
#endif
#ifndef STATUS_LED_PIN
#define STATUS_LED_PIN 25 /* WS2812 data */
#endif

/* --- MPU-9250 register map + scaling (InvenSense datasheet §3; verified on the
 * deployed bot via climber's Mpu9250Backend.cpp + ImuEstimator defaults). --- */
#define MPU9250_ADDR        0x68   /* AD0 → GND */
#define MPU9250_REG_WHO_AM_I 0x75  /* → 0x71 (9250) / 0x73 (9255) */
#define MPU9250_REG_PWR_MGMT_1 0x6B
#define MPU9250_REG_ACCEL_XOUT_H 0x3B /* 14-byte burst → GYRO_ZOUT_L */
#define MPU9250_CLKSEL_PLL  0x01   /* PWR_MGMT_1: clear sleep, PLL clock */
#define MPU9250_I2C_HZ      400000u
/* ±2g full-scale → 16384 LSB/g; ±250°/s → 131 LSB/(°/s) (ImuEstimator defaults). */
#define MPU9250_ACCEL_LSB_PER_G   16384.0f
#define MPU9250_GYRO_LSB_PER_DPS  131.0f
#define MPU9250_G_MS2             9.80665f      /* one g in m/s² */
#define MPU9250_DEG_TO_RAD        0.017453292519943295f /* π/180 */

/* --- MPU-9250 I²C helpers (ARDUINO-only), lifted verbatim from the reference. --- */
static bool mpu_write_u8(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU9250_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0; /* 0 = ACK */
}

/* Read `n` bytes starting at `reg` into `buf` (repeated-start). True on a full read. */
static bool mpu_read(uint8_t reg, uint8_t *buf, uint8_t n) {
  Wire.beginTransmission(MPU9250_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false; /* repeated-start */
  uint8_t got = (uint8_t)Wire.requestFrom((int)MPU9250_ADDR, (int)n);
  if (got != n) return false;
  for (uint8_t i = 0; i < n; i++) buf[i] = (uint8_t)Wire.read();
  return true;
}

/* --- board: the REAL MPU-9250 read on Wire(SDA 21 / SCL 22) @ addr 0x68, ported
 * from climber's Mpu9250Backend.cpp (deployed on this rig). Lazy one-time
 * bring-up (open the bus, WHO_AM_I sanity-check, wake + PLL clock); a failed
 * init retries next tick. The 14-byte burst from ACCEL_XOUT_H keeps the sample
 * coherent: accel hi/lo (6) · temp (2, skipped) · gyro hi/lo (6), all big-endian.
 *
 * The raw int16 LSB are scaled HERE into the BB.Message.Sensor.Imu engineering
 * units the :imu layout carries: linear_acceleration in m/s² (raw / 16384 · g),
 * angular_velocity in rad/s (raw / 131 · π/180). The MCU does NOT compute
 * orientation — it packs an IDENTITY quaternion (qw=1) and the host recovers
 * pitch from accel+gyro (complementary filter). On a bounded-read failure it
 * returns false so pose's seq stalls and the reader goes stale (legible). --- */
extern "C" bool imu_read(float *qw, float *qx, float *qy, float *qz,
                         float *wx, float *wy, float *wz,
                         float *ax, float *ay, float *az) {
  static bool inited = false;
  if (!inited) {
    Wire.begin(IMU_I2C_SDA_PIN, IMU_I2C_SCL_PIN, MPU9250_I2C_HZ);
    uint8_t who = 0;
    if (!mpu_read(MPU9250_REG_WHO_AM_I, &who, 1)) return false; /* part absent → stall */
    if (!mpu_write_u8(MPU9250_REG_PWR_MGMT_1, MPU9250_CLKSEL_PLL)) return false;
    delay(10);
    inited = true;
  }

  uint8_t b[14];
  if (!mpu_read(MPU9250_REG_ACCEL_XOUT_H, b, 14)) return false; /* bounded read failed */

  int16_t raw_ax = (int16_t)(((uint16_t)b[0] << 8) | b[1]);
  int16_t raw_ay = (int16_t)(((uint16_t)b[2] << 8) | b[3]);
  int16_t raw_az = (int16_t)(((uint16_t)b[4] << 8) | b[5]);
  /* b[6..7] = temperature, skipped. */
  int16_t raw_gx = (int16_t)(((uint16_t)b[8] << 8) | b[9]);
  int16_t raw_gy = (int16_t)(((uint16_t)b[10] << 8) | b[11]);
  int16_t raw_gz = (int16_t)(((uint16_t)b[12] << 8) | b[13]);

  /* Identity orientation — the MCU does not fuse; the host's complementary
   * filter recovers pitch from accel+gyro (LOCKED design, §09). */
  *qw = 1.0f; *qx = 0.0f; *qy = 0.0f; *qz = 0.0f;

  /* gyro → rad/s, accel → m/s² (engineering units the :imu layout wants). */
  *wx = (float)raw_gx / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  *wy = (float)raw_gy / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  *wz = (float)raw_gz / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  *ax = (float)raw_ax / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  *ay = (float)raw_ay / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  *az = (float)raw_az / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  return true;
}

/* --- board: the REAL HC-SR04 range read on TRIG 18 / ECHO 32, ported from
 * climber's Hcsr04Component.cpp. The trig dance (2 µs low, 10 µs high, low) then
 * a HARD-timeout pulseIn on ECHO; pulse width → metres via the speed of sound
 * (≈343 m/s, /2 for the round trip). pulseIn returns 0 on no echo within the
 * timeout (bounded by construction, never spins) → return false so range_front's
 * seq stalls. Range is NOT in the balance loop, so this is best-effort. --- */
#define RANGE_ECHO_TIMEOUT_US 30000u /* ~5 m round-trip ceiling */
extern "C" bool range_read(float *distance_m) {
  digitalWrite(RANGE_TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(RANGE_TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(RANGE_TRIG_PIN, LOW);

  uint32_t pulse_us = (uint32_t)pulseIn(RANGE_ECHO_PIN, HIGH, RANGE_ECHO_TIMEOUT_US);
  if (pulse_us == 0) return false; /* no echo within the timeout → seq stalls */

  /* distance (m) = pulse_us · speed_of_sound (m/s) / 2, in seconds: us·1e-6. */
  *distance_m = (float)pulse_us * 1.0e-6f * 343.0f / 2.0f;
  return true;
}

/* --- board: apply an RGB triple to the WS2812 status strip. Decorative — no
 * floor, a stale LED command is harmless (§09). The pixel PUSH is still a no-op
 * (mirroring the reference Ws2812Component's hw_show_pixels_ no-op hook); the
 * decode path (on the command port) is fully wired, only the RMT/NeoPixel write
 * is unbound. --- */
extern "C" void status_led_apply(uint8_t r, uint8_t g, uint8_t b) {
  /* The decode is wired; binding the WS2812 strip on STATUS_LED_PIN (25) via
   * Adafruit_NeoPixel or the RMT peripheral is the only remaining hardware step
   * for the decorative status strip. */
  (void)r; (void)g; (void)b;
}

/* Root-hub routing: this hub owns NODE 0x02. The wheels leaf (0x05) is reached
 * DOWN over the UART backplane; host-bound frames go UP over the host UART. */
static Router g_router;

static void deliver_local(const Frame *f, void *) {
  /* the Blaster's only inbound (command) port is status_led — decode the RGB
   * triple and apply it. No floor: a decorative LED needs no safe-state (§09). */
  if (f->port == PORT_BLASTER_STATUS_LED && f->payload_len >= 3) {
    status_led_apply(f->payload[0], f->payload[1], f->payload[2]);
  }
}
static void fwd_up(const Frame *f, void *) { link_send_up(f); }
static void fwd_down(const Frame *f, void *) {
  /* re-frame onto the backplane (UART here) — the link layer handles transport */
  link_send_up(f);
}

extern "C" void hub_on_body(const uint8_t *body, size_t len) {
  /* A relay is meaning-blind (§04): peek only the base header for (node, port) to
   * decide the link, and forward the body VERBATIM. We learn t_dev-ness per port
   * just-in-time, so a forwarding hub never needs to understand a payload it
   * relays. The status_led command, addressed to THIS node, is delivered local. */
  if (len < FRAME_HEADER_BASE_SIZE) return;
  Frame f;
  bool stamped = wire_port_stamped(body[0], body[1]);
  if (!frame_decode_body(body, len, stamped, &f)) return; /* CRC-clean at the seam */
  RouterSinks sinks = {deliver_local, fwd_up, fwd_down, nullptr};
  router_route(&g_router, &f, &sinks);
}

extern "C" void hub_setup(void) {
  g_router.my_node = MY_NODE;
  for (int i = 0; i < 256; i++) g_router.route_table[i] = LINK_UP; /* default: toward host */
  g_router.route_table[MY_NODE] = LINK_LOCAL;
  /* the wheels leaf (0x05) is reachable DOWN over the UART backplane */
  g_router.route_table[0x05] = LINK_DOWN;

  status_led_apply(0, 0, 0); /* strip dark at boot (no floor; just a clean start) */
}

extern "C" Task *hub_tasks(size_t *n_tasks) {
  *n_tasks = N_TASKS;
  return tasks;
}

#endif /* ARDUINO */
