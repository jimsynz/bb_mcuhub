/* IMU hub sketch (§01/§02). In the follower slice the IMU board is the ROOT HUB:
 * it senses its own IMU at 50 Hz AND bridges the host UART to the CAN backplane.
 * Build with -DROOT_HUB -DMY_NODE=0x02.
 *
 * This sketch supplies the board glue the generic hub_main expects: the schedule
 * table, hub_setup(), the inbound-body router, and the bounded imu_read(). */
#if defined(ARDUINO)

#include <Arduino.h>
extern "C" {
#include "frame.h"
#include "scheduler.h"
#include "router.h"
#include "link.h"
#include "wire_contract.h"
}

/* the hub's pure-ish tick (hubs/imu/mcu/imu_sensor.c) */
extern "C" void pose_sample_tick(uint32_t now_us);

/* status tick is unused on a sense-only hub, but the generated schedule for a
 * mixed board may reference siblings — the IMU schedule has only pose. */
#include "schedule.gen.h" /* defines: static Task tasks[]; N_TASKS */

/* --- board: a synthetic IMU read for bring-up (replace with real I²C driver).
 * Returns a unit quaternion + zero rates + 1g down, so the host sees a valid
 * pose immediately. Bounded by construction (no blocking). --- */
extern "C" bool imu_read(float *qw, float *qx, float *qy, float *qz,
                         float *wx, float *wy, float *wz,
                         float *ax, float *ay, float *az) {
  *qw = 1.0f; *qx = 0.0f; *qy = 0.0f; *qz = 0.0f;
  *wx = 0.0f; *wy = 0.0f; *wz = 0.0f;
  *ax = 0.0f; *ay = 0.0f; *az = 9.81f;
  return true;
}

/* Root-hub routing: this hub owns NODE 0x02; everything else is a child reached
 * DOWN over CAN, and host-bound frames go UP over UART. */
static Router g_router;

static void deliver_local(const Frame *f, void *) {
  /* the IMU hub has no inbound (command) ports; nothing to deliver locally */
  (void)f;
}
static void fwd_up(const Frame *f, void *) { link_send_up(f); }
static void fwd_down(const Frame *f, void *) { /* re-frame onto CAN — link layer */ link_send_up(f); }

extern "C" void hub_on_body(const uint8_t *body, size_t len) {
  /* A relay is meaning-blind (§04): peek only the base header for (node, port) to
   * decide the link, and forward the body VERBATIM. We learn t_dev-ness per port
   * just-in-time, so a forwarding hub never needs to understand a payload it
   * relays. (This hub has no local command ports, so deliver_local is a no-op.) */
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
  /* children (e.g. the motor on 0x05) are reachable DOWN over CAN */
  g_router.route_table[0x05] = LINK_DOWN;
}

extern "C" Task *hub_tasks(size_t *n_tasks) {
  *n_tasks = N_TASKS;
  return tasks;
}

#endif /* ARDUINO */
