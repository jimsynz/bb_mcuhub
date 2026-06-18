/* The IMU hub's sense tick (§08): one bounded read, one pure sample, one write.
 *
 * The scheduler calls this AT its period (schedule.gen.h), so the tick owns no
 * timer of its own. The producing hub owns the seq; it advances only on a real
 * new value. A bounded read that fails simply returns and writes nothing — the
 * seq stalls, the reader goes stale (legible, not a hang).
 *
 * This file is host-portable: the actual I²C read is behind imu_read(), which the
 * board sketch provides. The pure sample is sample_pose(). */
#include <stdint.h>
#include <stdbool.h>
#include "frame.h"
#include "link.h"
#include "wire_contract.h"

/* Provided by the board sketch (real IMU) or a test (synthetic). Returns false
 * on a bounded-read failure (timeout) → no write, seq stalls. */
extern bool imu_read(float *qw, float *qx, float *qy, float *qz,
                     float *wx, float *wy, float *wz,
                     float *ax, float *ay, float *az);

/* This hub's flat NODE id, baked at flash time. */
#ifndef MY_NODE
#define MY_NODE 0x02
#endif

static uint16_t pose_seq = 0;

void pose_sample_tick(uint32_t now_us) {
  float qw, qx, qy, qz, wx, wy, wz, ax, ay, az;
  if (!imu_read(&qw, &qx, &qy, &qz, &wx, &wy, &wz, &ax, &ay, &az)) {
    return; /* bounded read failed → no write → reader goes stale */
  }

  Frame f;
  f.node = MY_NODE;
  f.port = PORT_IMU_POSE;
  f.seq = ++pose_seq;               /* advance only on a real new value */
  f.stamped = PORT_IMU_POSE_STAMPED; /* pose carries t_dev (§04) */
  f.t_dev = now_us;                  /* this hub's own µs, same-device use only */

  /* pack the Imu payload, field order = Contract.Layouts[:imu], big-endian */
  float v[10] = {qw, qx, qy, qz, wx, wy, wz, ax, ay, az};
  for (int i = 0; i < 10; i++) be_put_f32(&f.payload[i * 4], v[i]);
  f.payload_len = 40;

  link_send_up(&f);
}
