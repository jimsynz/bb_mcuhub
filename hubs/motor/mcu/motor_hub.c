/* The motor hub's act + status (§05/§08).
 *
 *   * on_command()        — a command frame for our motor_target port: decode the
 *     effort and hand its seq + value to the floor (the floor watches the seq).
 *   * control_tick()      — runs EVERY loop (period 0): the floor decides arm vs
 *     safe, and we drive the plant. Born-disarmed; fail-passive on command
 *     silence. The floor is the safe-state mechanism, on THIS chip.
 *   * status_write_tick() — reports {applied_seq, floored?} up the wire, so the
 *     host reads truth instead of inferring it.
 *
 * Host-portable: drive() and the actual motor are behind the board sketch. */
#include <stdint.h>
#include <stdbool.h>
#include "frame.h"
#include "floor.h"
#include "link.h"
#include "wire_contract.h"

extern void drive(float effort); /* board: apply effort to the motor */

#ifndef MY_NODE
#define MY_NODE 0x05
#endif

/* The floor window is generated from one number (§05/§06). */
#ifndef FLOOR_WINDOW_MS
#define FLOOR_WINDOW_MS (FLOOR_MISSES_MOTOR_MOTOR_TARGET * CMD_PERIOD_MS_MOTOR_MOTOR_TARGET)
#endif

static Floor g_floor;
static uint16_t status_seq = 0;
static uint16_t g_applied_seq = 0;

void motor_hub_init(void) {
  floor_init(&g_floor, FLOOR_WINDOW_MS, 0.0f /* :zero_torque safe action */);
}

/* Called by the router when a frame for THIS hub's command port arrives. */
void on_command(const Frame *f) {
  if (f->port != PORT_MOTOR_MOTOR_TARGET) return;
  if (f->payload_len < 4) return;
  float effort = be_get_f32(&f->payload[0]);
  floor_on_command(&g_floor, f->seq, effort); /* watch the seq, not the value */
  g_applied_seq = f->seq;
}

/* The ~kHz drive loop — period 0 so it runs every loop pass, never starved. */
void control_tick(uint32_t now_us) {
  uint32_t now_ms = now_us / 1000u;
  float out = floor_tick(&g_floor, now_ms);
  drive(out); /* target while armed, safe action otherwise — default is safe */
}

void motor_target_cmd_tick(uint32_t now_us) {
  /* command handling is event-driven via on_command(); nothing periodic here */
  (void)now_us;
}

/* Report the actuator's own truth (§05): applied_seq + floored?. */
void motor_status_sample_tick(uint32_t now_us) {
  (void)now_us; /* status omits t_dev, so the tick needs no clock */
  Frame f;
  f.node = MY_NODE;
  f.port = PORT_MOTOR_MOTOR_STATUS;
  f.seq = ++status_seq;
  f.stamped = PORT_MOTOR_MOTOR_STATUS_STAMPED; /* status omits t_dev (§04) */
  f.t_dev = 0;

  be_put_u16(&f.payload[0], g_applied_seq);
  f.payload[2] = g_floor.armed ? 0 : 1; /* floored? = not armed */
  f.payload_len = 3;

  link_send_up(&f);
}
