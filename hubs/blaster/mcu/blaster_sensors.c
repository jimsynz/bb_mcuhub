/* The Blaster hub's sense ticks (§08): one bounded read, one pure sample, one
 * write — one tick per OUT port. Mirrors hubs/imu/mcu/imu_sensor.c.
 *
 * The scheduler calls these AT their period (schedule.gen.h), so the ticks own
 * no timer of their own. The producing hub owns each port's seq; it advances
 * only on a real new value. A bounded read that fails simply returns and writes
 * nothing — the seq stalls, the reader goes stale (legible, not a hang).
 *
 * This file is host-portable: the actual device reads are behind imu_read() /
 * range_read(), which the board sketch (main_blaster.cpp) provides.
 *
 *   pose       (out, :imu,   100 Hz, stamped) — the MPU-9250 chassis IMU.
 *   range_front(out, :range,  20 Hz)          — the HC-SR04 forward distance.
 */
#include <stdint.h>
#include <stdbool.h>
#include "frame.h"
#include "link.h"
#include "wire_contract.h"

/* Provided by the board sketch (real driver) or a test (synthetic). Returns
 * false on a bounded-read failure (timeout) → no write, seq stalls. */
extern bool imu_read(float *qw, float *qx, float *qy, float *qz,
                     float *wx, float *wy, float *wz,
                     float *ax, float *ay, float *az);

extern bool range_read(float *distance_m);

/* This hub's flat NODE id, baked at flash time. */
#ifndef MY_NODE
#define MY_NODE 0x02
#endif

static uint16_t pose_seq = 0;
static uint16_t range_seq = 0;

void pose_sample_tick(uint32_t now_us) {
  float qw, qx, qy, qz, wx, wy, wz, ax, ay, az;
  if (!imu_read(&qw, &qx, &qy, &qz, &wx, &wy, &wz, &ax, &ay, &az)) {
    return; /* bounded read failed → no write → reader goes stale */
  }

  Frame f;
  f.node = MY_NODE;
  f.port = PORT_BLASTER_POSE;
  f.seq = ++pose_seq;                  /* advance only on a real new value */
  f.stamped = PORT_BLASTER_POSE_STAMPED; /* pose carries t_dev (§04) */
  f.t_dev = now_us;                    /* this hub's own µs, same-device use only */

  /* pack the Imu payload, field order = Contract.Layouts[:imu], big-endian */
  float v[10] = {qw, qx, qy, qz, wx, wy, wz, ax, ay, az};
  for (int i = 0; i < 10; i++) be_put_f32(&f.payload[i * 4], v[i]);
  f.payload_len = 40;

  link_send_up(&f);
}

void range_front_sample_tick(uint32_t now_us) {
  float distance_m;
  if (!range_read(&distance_m)) {
    return; /* bounded read failed → no write → reader goes stale */
  }

  Frame f;
  f.node = MY_NODE;
  f.port = PORT_BLASTER_RANGE_FRONT;
  f.seq = ++range_seq;
  f.stamped = PORT_BLASTER_RANGE_FRONT_STAMPED; /* range omits t_dev (§04) */
  f.t_dev = 0;
  (void)now_us;

  /* pack the Range payload, field order = Contract.Layouts[:range], big-endian */
  be_put_f32(&f.payload[0], distance_m);
  f.payload_len = 4;

  link_send_up(&f);
}

/* status_led is an IN (command) port; its handling is event-driven via the
 * router → status_led_apply() in the board sketch, so this scheduled tick (the
 * generated schedule lists every port) has nothing periodic to do. Mirrors the
 * motor hub's motor_target_cmd_tick no-op. */
void status_led_cmd_tick(uint32_t now_us) { (void)now_us; }
