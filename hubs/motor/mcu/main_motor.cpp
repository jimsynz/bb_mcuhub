/* Motor hub sketch (§05). In the follower slice the motor is a CAN LEAF with the
 * floor on its own chip. Build with -DMY_NODE=0x05 (no -DROOT_HUB → CAN-only).
 *
 * Supplies the board glue: the schedule table, hub_setup() (init the floor),
 * the inbound router (delivers commands to on_command), and drive(). */
#if defined(ARDUINO)

#include <Arduino.h>
extern "C" {
#include "frame.h"
#include "scheduler.h"
#include "router.h"
#include "link.h"
#include "wire_contract.h"
}

/* the hub's logic (hubs/motor/mcu/motor_hub.c) */
extern "C" void motor_hub_init(void);
extern "C" void on_command(const Frame *f);
extern "C" void control_tick(uint32_t now_us);
extern "C" void motor_target_cmd_tick(uint32_t now_us);
extern "C" void motor_status_sample_tick(uint32_t now_us);

#include "schedule.gen.h" /* static Task tasks[]; N_TASKS — motor_target + motor_status */

#ifndef MOTOR_PWM_PIN
#define MOTOR_PWM_PIN 25
#endif

/* --- board: apply effort to the motor. A real driver maps Nm→PWM; here we map
 * effort [-1,1]-ish to an LEDC duty as a safe bring-up stand-in. --- */
extern "C" void drive(float effort) {
  /* clamp and map to 8-bit duty around mid for a bring-up signal */
  if (effort > 1.0f) effort = 1.0f;
  if (effort < -1.0f) effort = -1.0f;
  int duty = (int)((effort * 0.5f + 0.5f) * 255.0f);
  /* arduino-esp32 3.x LEDC: address the pin, not a legacy channel number */
  ledcWrite(MOTOR_PWM_PIN, duty);
}

static Router g_router;

static void deliver_local(const Frame *f, void *) {
  if (f->port == PORT_MOTOR_MOTOR_TARGET) on_command(f);
}

extern "C" void hub_on_body(const uint8_t *body, size_t len) {
  if (len < FRAME_HEADER_BASE_SIZE) return;
  Frame f;
  bool stamped = wire_port_stamped(body[0], body[1]); /* per-port t_dev (§04) */
  if (!frame_decode_body(body, len, stamped, &f)) return;
  RouterSinks sinks = {deliver_local, nullptr, nullptr, nullptr}; /* leaf: local only */
  router_route(&g_router, &f, &sinks);
}

extern "C" void hub_setup(void) {
  /* arduino-esp32 3.x unified LEDC: attach(pin, freq_hz, resolution_bits) */
  ledcAttach(MOTOR_PWM_PIN, 20000 /* Hz */, 8 /* bits */);
  motor_hub_init(); /* born-disarmed floor, safe action selected */
  drive(0.0f);      /* output already at the safe action at boot */

  g_router.my_node = MY_NODE;
  for (int i = 0; i < 256; i++) g_router.route_table[i] = LINK_LOCAL;
}

/* The generated schedule lists the contract's ports; the floor's drive loop runs
 * EVERY loop (period 0) and is added here by the firmware, never starved (§08). */
static Task motor_tasks[N_TASKS + 1];

extern "C" Task *hub_tasks(size_t *n_tasks) {
  motor_tasks[0] = (Task){0, 0, control_tick}; /* period 0 → every loop pass */
  for (size_t i = 0; i < N_TASKS; i++) motor_tasks[i + 1] = tasks[i];
  *n_tasks = N_TASKS + 1;
  return motor_tasks;
}

#endif /* ARDUINO */
