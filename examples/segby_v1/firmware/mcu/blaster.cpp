/* Blaster hub — DEVICE HOOKS ONLY (§09, ADR-0003 Shape 1).
 *
 * The segby_v1 Blaster board is the ROOT HUB on a DOIT V1 ESP32: it senses its
 * own pose (MPU-9250 @ 100 Hz) + a forward range (HC-SR04 @ 20 Hz), drives a
 * decorative WS2812 status strip, AND bridges the host UART to the UART
 * backplane (the wheels leaf, NODE 0x05). ALL the mechanical wiring (the root
 * route table, hub_on_body relay, the sense ticks, the LED command dispatch,
 * the schedule, hub_setup/hub_tasks) is GENERATED into
 * firmware/gen/segby_v1/blaster.glue.h from the IR. This file supplies only the
 * device-specific hooks:
 *
 *   * blaster_device_setup()       — strip dark at boot (peripherals
 * lazy-init).
 *   * blaster_pose_read()          — the REAL MPU-9250 I²C burst → Imu struct.
 *   * blaster_range_front_read()   — the REAL HC-SR04 trig/echo → Range struct.
 *   * blaster_status_led_drive()   — apply an RGB triple to the WS2812 strip.
 *
 * The IMU read is the REAL MPU-9250 I²C driver: WHO_AM_I sanity-check, wake
 * + PLL clock, then a 14-byte burst from ACCEL_XOUT_H, big-endian hi/lo. The
 * raw int16 LSB are scaled HERE into the BB.Message.Sensor.Imu engineering
 * units the :imu layout wants — accel m/s², gyro rad/s — with an IDENTITY
 * orientation quaternion (the MCU does not fuse; the host's complementary
 * filter recovers pitch from accel+gyro). The HC-SR04 range read is the real
 * trig/echo dance. WS2812 pixel push
 * is still a no-op (the decode path is fully wired; only the RMT/NeoPixel write
 * is unbound — a decorative LED has no floor, §09).
 *
 * Including blaster.glue.h pulls in the generated
 * hub_setup/hub_on_body/hub_tasks (C linkage). ARDUINO-guarded so the host C
 * harnesses still build. */
#if defined(ARDUINO)

#include <Arduino.h>
#include <Wire.h>

#include "blaster.glue.h"

/* --- segby_v1 Blaster pin map (DOIT V1 ESP32) — hardware-verified.
 * The host UART (Serial) and the UART backplane (Serial2) pins are owned by the
 * link layer (link_esp32.cpp): backplane defaults TX 26 / RX 27 on a root hub
 * (backplane UART on UART2). --- */
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

/* --- MPU-9250 register map + scaling (InvenSense datasheet §3;
 * hardware-verified). --- */
#define MPU9250_ADDR 0x68         /* AD0 → GND */
#define MPU9250_REG_WHO_AM_I 0x75 /* → 0x71 (9250) / 0x73 (9255) */
#define MPU9250_REG_PWR_MGMT_1 0x6B
#define MPU9250_REG_ACCEL_XOUT_H 0x3B /* 14-byte burst → GYRO_ZOUT_L */
#define MPU9250_CLKSEL_PLL 0x01       /* PWR_MGMT_1: clear sleep, PLL clock */
#define MPU9250_I2C_HZ 400000u
/* ±2g full-scale → 16384 LSB/g; ±250°/s → 131 LSB/(°/s) (MPU-9250
 * datasheet defaults). */
#define MPU9250_ACCEL_LSB_PER_G 16384.0f
#define MPU9250_GYRO_LSB_PER_DPS 131.0f
#define MPU9250_G_MS2 9.80665f                   /* one g in m/s² */
#define MPU9250_DEG_TO_RAD 0.017453292519943295f /* π/180 */

/* --- MPU-9250 I²C helpers. --- */
static bool mpu_write_u8(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU9250_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0; /* 0 = ACK */
}

/* Read `n` bytes starting at `reg` into `buf` (repeated-start). True on a full
 * read. */
static bool mpu_read(uint8_t reg, uint8_t *buf, uint8_t n) {
  Wire.beginTransmission(MPU9250_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0)
    return false; /* repeated-start */
  uint8_t got = (uint8_t)Wire.requestFrom((int)MPU9250_ADDR, (int)n);
  if (got != n)
    return false;
  for (uint8_t i = 0; i < n; i++)
    buf[i] = (uint8_t)Wire.read();
  return true;
}

/* --- device: strip dark at boot; peripherals are lazy-init'd on first read.
 * The floors n/a here (the Blaster has no actuator floor — the LED is
 * decorative). */
extern "C" void blaster_device_setup(void) {
  Led off = {0, 0, 0};
  blaster_status_led_drive(
      &off); /* strip dark at boot (no floor; just a clean start) */
}

/* --- device: the REAL MPU-9250 read on Wire(SDA 21 / SCL 22) @ addr 0x68.
 * Lazy
 * one-time bring-up (open the bus, WHO_AM_I sanity-check, wake + PLL clock); a
 * failed init retries next tick. The 14-byte burst from ACCEL_XOUT_H keeps the
 * sample coherent: accel hi/lo (6) · temp (2, skipped) · gyro hi/lo (6), all
 * big-endian.
 *
 * The raw int16 LSB are scaled HERE into the BB.Message.Sensor.Imu engineering
 * units the :imu layout carries: linear_acceleration in m/s² (raw / 16384 · g),
 * angular_velocity in rad/s (raw / 131 · π/180). The MCU does NOT compute
 * orientation — it packs an IDENTITY quaternion (qw=1) and the host recovers
 * pitch from accel+gyro (complementary filter). On a bounded-read failure it
 * returns false so pose's seq stalls and the reader goes stale (legible). ---
 */
extern "C" bool blaster_pose_read(Imu *out) {
  static bool inited = false;
  if (!inited) {
    Wire.begin(IMU_I2C_SDA_PIN, IMU_I2C_SCL_PIN, MPU9250_I2C_HZ);
    uint8_t who = 0;
    if (!mpu_read(MPU9250_REG_WHO_AM_I, &who, 1))
      return false; /* part absent → stall */
    if (!mpu_write_u8(MPU9250_REG_PWR_MGMT_1, MPU9250_CLKSEL_PLL))
      return false;
    delay(10);
    inited = true;
  }

  uint8_t b[14];
  if (!mpu_read(MPU9250_REG_ACCEL_XOUT_H, b, 14))
    return false; /* bounded read failed */

  int16_t raw_ax = (int16_t)(((uint16_t)b[0] << 8) | b[1]);
  int16_t raw_ay = (int16_t)(((uint16_t)b[2] << 8) | b[3]);
  int16_t raw_az = (int16_t)(((uint16_t)b[4] << 8) | b[5]);
  /* b[6..7] = temperature, skipped. */
  int16_t raw_gx = (int16_t)(((uint16_t)b[8] << 8) | b[9]);
  int16_t raw_gy = (int16_t)(((uint16_t)b[10] << 8) | b[11]);
  int16_t raw_gz = (int16_t)(((uint16_t)b[12] << 8) | b[13]);

  /* Identity orientation — the MCU does not fuse; the host's complementary
   * filter recovers pitch from accel+gyro (LOCKED design, §09). */
  out->qw = 1.0f;
  out->qx = 0.0f;
  out->qy = 0.0f;
  out->qz = 0.0f;

  /* gyro → rad/s, accel → m/s² (engineering units the :imu layout wants). */
  out->wx = (float)raw_gx / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  out->wy = (float)raw_gy / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  out->wz = (float)raw_gz / MPU9250_GYRO_LSB_PER_DPS * MPU9250_DEG_TO_RAD;
  out->ax = (float)raw_ax / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  out->ay = (float)raw_ay / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  out->az = (float)raw_az / MPU9250_ACCEL_LSB_PER_G * MPU9250_G_MS2;
  return true;
}

/* --- device: the REAL HC-SR04 range read on TRIG 18 / ECHO 32.
 * The trig dance (2 µs low, 10 µs high, low)
 * then a HARD-timeout pulseIn on ECHO; pulse width → metres via the speed of
 * sound (≈343 m/s, /2 for the round trip). pulseIn returns 0 on no echo within
 * the timeout (bounded by construction, never spins) → return false so
 * range_front's seq stalls. Range is NOT in the balance loop, so this is
 * best-effort. --- */
#define RANGE_ECHO_TIMEOUT_US 30000u /* ~5 m round-trip ceiling */
extern "C" bool blaster_range_front_read(Range *out) {
  /* TRIG is configured lazily here; the pin defaults are harmless before. */
  pinMode(RANGE_TRIG_PIN, OUTPUT);
  pinMode(RANGE_ECHO_PIN, INPUT);

  digitalWrite(RANGE_TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(RANGE_TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(RANGE_TRIG_PIN, LOW);

  uint32_t pulse_us =
      (uint32_t)pulseIn(RANGE_ECHO_PIN, HIGH, RANGE_ECHO_TIMEOUT_US);
  if (pulse_us == 0)
    return false; /* no echo within the timeout → seq stalls */

  /* distance (m) = pulse_us · speed_of_sound (m/s) / 2, in seconds: us·1e-6. */
  out->distance_m = (float)pulse_us * 1.0e-6f * 343.0f / 2.0f;
  return true;
}

/* --- device: apply an RGB triple to the WS2812 status strip. Decorative — no
 * floor, a stale LED command is harmless (§09). The pixel PUSH is still a
 * no-op; the decode path (on the command port) is fully wired, only the
 * RMT/NeoPixel write is unbound. The hook takes the packed Led struct (the
 * value-type owns the signature — a multi-field value → a struct pointer). ---
 */
extern "C" void blaster_status_led_drive(const Led *v) {
  /* The decode is wired; binding the WS2812 strip on STATUS_LED_PIN (25) via
   * Adafruit_NeoPixel or the RMT peripheral is the only remaining hardware step
   * for the decorative status strip. */
  (void)v->r;
  (void)v->g;
  (void)v->b;
}

#endif /* ARDUINO */
