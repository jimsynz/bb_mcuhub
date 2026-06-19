/* IMU hub — DEVICE HOOKS ONLY (§01/§02, ADR-0003 Shape 1).
 *
 * The follower's IMU board is the ROOT HUB: it senses its own IMU at 50 Hz AND
 * bridges the host UART to the CAN backplane. ALL the mechanical wiring (the
 * root route table, hub_on_body relay, the sense tick + schedule, hub_setup/
 * hub_tasks) is GENERATED into firmware/gen/follower/imu.glue.h from the IR.
 * This file supplies only the device-specific hooks:
 *
 *   * imu_device_setup() — bring up the IMU peripheral (no-op for the synthetic
 *     bring-up read below; a real driver opens its I²C bus here).
 *   * imu_pose_read()    — a bounded read filling the Imu wire struct; false on
 *     a read failure (→ the seq stalls, the reader goes stale).
 *
 * Including imu.glue.h pulls in the generated hub_setup/hub_on_body/hub_tasks
 * (C linkage). ARDUINO-guarded so the host C harnesses still build. */
#if defined(ARDUINO)

#include <Arduino.h>

#include "imu.glue.h"

/* --- device: no peripheral bring-up for the synthetic read. A real MPU driver
 * would open its I²C bus / probe WHO_AM_I here (see the blaster hub for the real
 * MPU-9250 driver this follower stub stands in for). --- */
extern "C" void imu_device_setup(void) {}

/* --- device: a synthetic IMU read for bring-up (replace with a real I²C driver).
 * Returns a unit quaternion + zero rates + 1g down, so the host sees a valid pose
 * immediately. Bounded by construction (no blocking). Fills the generated Imu
 * wire struct (field order = the :imu layout). --- */
extern "C" bool imu_pose_read(Imu *out) {
  out->qw = 1.0f;
  out->qx = 0.0f;
  out->qy = 0.0f;
  out->qz = 0.0f;
  out->wx = 0.0f;
  out->wy = 0.0f;
  out->wz = 0.0f;
  out->ax = 0.0f;
  out->ay = 0.0f;
  out->az = 9.81f;
  return true;
}

#endif /* ARDUINO */
