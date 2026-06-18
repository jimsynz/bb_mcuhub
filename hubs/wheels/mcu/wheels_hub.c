/* The Wheels hub's act + status (§05/§08) — ONE leaf, TWO motors.
 *
 * ONE MKS Dual FOC v3.2 board drives both wheels (M0 = left, M1 = right). So
 * this hub has TWO independent command ports (motor_left / motor_right), each
 * with its OWN on-chip floor, and TWO status ports (status_left / status_right).
 * Mirrors hubs/motor/mcu/motor_hub.c, doubled.
 *
 *   * on_command_left/right() — a command frame for our motor_{left,right} port:
 *     decode the effort and hand its seq + value to THAT motor's floor.
 *   * control_loop_tick()     — runs EVERY loop (period 0): each floor decides
 *     arm vs safe, and we drive both plants. Born-disarmed; fail-passive on
 *     command silence. Two floors, two independent safe states (§05).
 *   * status_{left,right}_sample_tick() — each motor's reported truth
 *     {applied_seq, floored?} up the wire, so the host reads truth, not inference.
 *
 * Host-portable: the two motor channels and the real FOC drive live behind the
 * board sketch (main_wheels.cpp), via drive_left()/drive_right(). The command
 * decode + floor logic here stays pure C, host-testable, with no SimpleFOC. */
#include <stdint.h>
#include <stdbool.h>
#include "frame.h"
#include "floor.h"
#include "link.h"
#include "wire_contract.h"

/* board: apply effort (q-axis voltage target in torque-voltage mode) to each
 * motor and run its FOC loop. Provided by main_wheels.cpp. */
extern void drive_left(float effort);
extern void drive_right(float effort);

#ifndef MY_NODE
#define MY_NODE 0x05
#endif

/* Each motor's floor window is generated from one number (§05/§06). */
#ifndef FLOOR_WINDOW_MS_LEFT
#define FLOOR_WINDOW_MS_LEFT (FLOOR_MISSES_WHEELS_MOTOR_LEFT * CMD_PERIOD_MS_WHEELS_MOTOR_LEFT)
#endif
#ifndef FLOOR_WINDOW_MS_RIGHT
#define FLOOR_WINDOW_MS_RIGHT (FLOOR_MISSES_WHEELS_MOTOR_RIGHT * CMD_PERIOD_MS_WHEELS_MOTOR_RIGHT)
#endif

static Floor g_floor_left;
static Floor g_floor_right;
static uint16_t status_left_seq = 0;
static uint16_t status_right_seq = 0;
static uint16_t g_applied_seq_left = 0;
static uint16_t g_applied_seq_right = 0;

void wheels_hub_init(void) {
  /* two independent floors, both born-disarmed at the :zero_torque safe action */
  floor_init(&g_floor_left, FLOOR_WINDOW_MS_LEFT, 0.0f);
  floor_init(&g_floor_right, FLOOR_WINDOW_MS_RIGHT, 0.0f);
}

/* Called by the router when a frame for THIS hub's left/right command port
 * arrives. Each watches its OWN floor's seq, not the value (§04/§05). */
void on_command_left(const Frame *f) {
  if (f->port != PORT_WHEELS_MOTOR_LEFT) return;
  if (f->payload_len < 4) return;
  float effort = be_get_f32(&f->payload[0]);
  floor_on_command(&g_floor_left, f->seq, effort);
  g_applied_seq_left = f->seq;
}

void on_command_right(const Frame *f) {
  if (f->port != PORT_WHEELS_MOTOR_RIGHT) return;
  if (f->payload_len < 4) return;
  float effort = be_get_f32(&f->payload[0]);
  floor_on_command(&g_floor_right, f->seq, effort);
  g_applied_seq_right = f->seq;
}

/* The ~kHz drive loop — period 0 so it runs every loop pass, never starved.
 * Each floor gates its own motor: target while armed, safe action otherwise
 * (default safe). drive_*() runs the per-motor FOC loop on-target. */
void control_loop_tick(uint32_t now_us) {
  uint32_t now_ms = now_us / 1000u;
  drive_left(floor_tick(&g_floor_left, now_ms));
  drive_right(floor_tick(&g_floor_right, now_ms));
}

/* IN ports handled event-driven via on_command_*(); the scheduled cmd ticks
 * (the generated schedule lists every port) have nothing periodic to do. */
void motor_left_cmd_tick(uint32_t now_us) { (void)now_us; }
void motor_right_cmd_tick(uint32_t now_us) { (void)now_us; }

/* Report each actuator's own truth (§05): applied_seq + floored?. */
void status_left_sample_tick(uint32_t now_us) {
  (void)now_us; /* status omits t_dev, so the tick needs no clock */
  Frame f;
  f.node = MY_NODE;
  f.port = PORT_WHEELS_STATUS_LEFT;
  f.seq = ++status_left_seq;
  f.stamped = PORT_WHEELS_STATUS_LEFT_STAMPED; /* status omits t_dev (§04) */
  f.t_dev = 0;

  be_put_u16(&f.payload[0], g_applied_seq_left);
  f.payload[2] = g_floor_left.armed ? 0 : 1; /* floored? = not armed */
  f.payload_len = 3;

  link_send_up(&f);
}

void status_right_sample_tick(uint32_t now_us) {
  (void)now_us;
  Frame f;
  f.node = MY_NODE;
  f.port = PORT_WHEELS_STATUS_RIGHT;
  f.seq = ++status_right_seq;
  f.stamped = PORT_WHEELS_STATUS_RIGHT_STAMPED;
  f.t_dev = 0;

  be_put_u16(&f.payload[0], g_applied_seq_right);
  f.payload[2] = g_floor_right.armed ? 0 : 1;
  f.payload_len = 3;

  link_send_up(&f);
}
