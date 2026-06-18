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
 * DEVICE READS ARE SYNTHETIC for this bring-up phase (the slice's existing
 * pattern — see main_imu.cpp): a unit quaternion + 1g down and a fixed range, so
 * the host sees valid pose/range immediately. Binding the real MPU-9250 /
 * HC-SR04 / WS2812 drivers is a hardware-bring-up detail; the pins are recorded
 * in the TODOs below from bots/segby_v1 BoardSupport.cpp + README. */
#if defined(ARDUINO)

#include <Arduino.h>
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
 * "Pin map" + blaster/BoardSupport.cpp. Recorded for the real-driver binding;
 * the host UART (Serial) and the UART backplane (Serial2) pins are owned by the
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

/* --- board: a synthetic IMU read for bring-up (replace with the real MPU-9250
 * I²C driver on SDA 21 / SCL 22, addr 0x68). Returns a unit quaternion + zero
 * rates + 1g down, so the host sees a valid pose immediately. Bounded by
 * construction (no blocking). --- */
extern "C" bool imu_read(float *qw, float *qx, float *qy, float *qz,
                         float *wx, float *wy, float *wz,
                         float *ax, float *ay, float *az) {
  /* TODO(hw): bind MPU-9250 on Wire(SDA=21, SCL=22) @ 0x68; on a bounded-read
   * timeout return false so pose's seq stalls and the reader goes stale. */
  *qw = 1.0f; *qx = 0.0f; *qy = 0.0f; *qz = 0.0f;
  *wx = 0.0f; *wy = 0.0f; *wz = 0.0f;
  *ax = 0.0f; *ay = 0.0f; *az = 9.81f;
  return true;
}

/* --- board: a synthetic range read for bring-up (replace with the real HC-SR04
 * trig/echo driver on TRIG 18 / ECHO 32). Returns a fixed 1.0 m. Bounded by
 * construction: a real driver must time the echo with a HARD timeout and return
 * false on no echo, never spin (§08). --- */
extern "C" bool range_read(float *distance_m) {
  /* TODO(hw): pulse TRIG 18, time ECHO 32 with a bounded timeout; on no echo
   * return false so range_front's seq stalls. */
  *distance_m = 1.0f;
  return true;
}

/* --- board: apply an RGB triple to the WS2812 status strip. Decorative — no
 * floor, a stale LED command is harmless (§09). A no-op stub for this phase,
 * mirroring the reference Ws2812Component's hw_show_pixels_ no-op hook; the
 * decode path (on the command port) is fully wired. --- */
extern "C" void status_led_apply(uint8_t r, uint8_t g, uint8_t b) {
  /* TODO(hw): drive the WS2812 strip on STATUS_LED_PIN (25) via Adafruit_NeoPixel
   * or the RMT peripheral. The decode is wired; only the pixel push is stubbed. */
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
