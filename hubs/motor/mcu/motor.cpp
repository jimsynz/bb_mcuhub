/* Motor hub — DEVICE HOOKS ONLY (§05, ADR-0003 Shape 1).
 *
 * The follower's motor is a CAN LEAF with the floor on its own chip. ALL the
 * mechanical wiring (router table, hub_on_body, the floor init/on_command/
 * control_tick/status plumbing, the schedule, hub_setup/hub_tasks) is GENERATED
 * into firmware/gen/follower/motor.glue.h from the IR. This file supplies only
 * the device-specific hooks that glue calls:
 *
 *   * motor_device_setup()       — bring up the LEDC PWM and park the output safe.
 *   * motor_motor_target_drive() — map an effort to a PWM duty (the plant).
 *
 * Including motor.glue.h pulls in the generated hub_setup/hub_on_body/hub_tasks
 * (C linkage) the generic hub_main.cpp links against. Everything is
 * ARDUINO-guarded so the host C harnesses (which never compile this) still build.
 *
 * Built as C++ (.cpp) so the generated glue's `extern "C"` / nullptr survive; the
 * device logic itself is plain Arduino. */
#if defined(ARDUINO)

#include <Arduino.h>

/* The generated glue defines hub_setup/hub_on_body/hub_tasks and declares the
 * hooks below (via motor.device.h). */
#include "motor.glue.h"

#ifndef MOTOR_PWM_PIN
#define MOTOR_PWM_PIN 25
#endif

/* --- device: bring up the motor PWM, output parked at the safe action. The
 * floor is already inited born-disarmed by the generated hub_setup BEFORE this
 * runs, so parking the duty at safe here makes the physical output match (§05). */
extern "C" void motor_device_setup(void) {
  /* arduino-esp32 3.x unified LEDC: attach(pin, freq_hz, resolution_bits) */
  ledcAttach(MOTOR_PWM_PIN, 20000 /* Hz */, 8 /* bits */);
  motor_motor_target_drive(0.0f); /* output already at the safe action at boot */
}

/* --- device: apply effort to the motor. A real driver maps Nm→PWM; here we map
 * effort [-1,1]-ish to an LEDC duty as a safe bring-up stand-in. --- */
extern "C" void motor_motor_target_drive(float effort) {
  if (effort > 1.0f) effort = 1.0f;
  if (effort < -1.0f) effort = -1.0f;
  int duty = (int)((effort * 0.5f + 0.5f) * 255.0f);
  /* arduino-esp32 3.x LEDC: address the pin, not a legacy channel number */
  ledcWrite(MOTOR_PWM_PIN, duty);
}

#endif /* ARDUINO */
