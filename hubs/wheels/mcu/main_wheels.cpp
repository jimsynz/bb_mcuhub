/* Wheels hub sketch (§09). In the segby_v1 slice the wheels board is a UART LEAF
 * on an MKS Dual FOC v3.2 (ESP32 Lolin32-Lite): ONE node (0x05) driving BOTH
 * wheels (M0 = left, M1 = right) with SimpleFOC, each motor behind its OWN
 * on-chip floor (§05). Build with -DMY_NODE=0x05 (no -DROOT_HUB → leaf; the
 * backplane is UART because the generated wire_contract.h sets
 * BACKPLANE_TRANSPORT_UART=1, so the link layer talks Serial2 to the parent).
 *
 * Mirrors hubs/motor/mcu/main_motor.cpp, doubled, with the real FOC port from
 * climber's SimpleFocNode.cpp: two BLDCMotor + BLDCDriver3PWM + MagneticSensorI2C
 * (AS5600) channels in torque-voltage mode. control_loop_tick() runs loopFOC() +
 * move() on both with motor.target = each floor's output torque (interpreted as a
 * q-axis voltage, the reference's "honest first-cut" torque→Uq mapping).
 *
 * Host-portability: every SimpleFOC call is #if defined(ARDUINO)-guarded (like
 * the reference), so the command-decode + floor path (wheels_hub.c) stays
 * host-compilable. Off-target, drive_left/right are no-ops; the floors + decode
 * are exercised on the host.
 *
 * Supplies the board glue: the schedule table, hub_setup() (init both floors +
 * both FOC channels), the inbound router (delivers each motor command to its
 * own floor), and drive_left()/drive_right(). */
#if defined(ARDUINO)

#include <Arduino.h>
#include <SimpleFOC.h>
#include <Wire.h>
extern "C" {
#include "frame.h"
#include "scheduler.h"
#include "router.h"
#include "link.h"
#include "wire_contract.h"
}

/* the hub's logic (hubs/wheels/mcu/wheels_hub.c) */
extern "C" void wheels_hub_init(void);
extern "C" void on_command_left(const Frame *f);
extern "C" void on_command_right(const Frame *f);
extern "C" void control_loop_tick(uint32_t now_us);
extern "C" void motor_left_cmd_tick(uint32_t now_us);
extern "C" void motor_right_cmd_tick(uint32_t now_us);
extern "C" void status_left_sample_tick(uint32_t now_us);
extern "C" void status_right_sample_tick(uint32_t now_us);

#include "schedule.gen.h" /* static Task tasks[]; N_TASKS — motor_{l,r} + status_{l,r} */

/* --- Bench-verified electrical params (climber foc_bench/PARAMS.md). The MKS
 * Dual FOC v3.2 runs a 30-slot/20-pole outrunner (10 pole pairs) at 12 V. --- */
static const int   kPolePairs    = 10;   /* TODO(hw): confirm for segby's wheels */
static const float kVbusV        = 12.0f;
static const float kDriverVLimit = 6.0f; /* half VBUS */
static const float kMotorVLimit  = 4.0f; /* caps the applied q-axis voltage */
static const float kMotorVAlign  = 8.0f; /* dominates this rotor's cogging */
static const uint32_t kI2cHz     = 400000;

/* --- MKS Dual FOC v3.2 pin map ---
 * Driver pins from climber's SimpleFocNode constructor (mirrors the board's
 * reference): M0 = pwm a/b/c 32/33/25, M1 = pwm a/b/c 26/27/14, shared enable 12.
 * AS5600 encoders from bots/segby_v1/README.md: each AS5600 shares addr 0x36, so
 * each rides its OWN I²C bus — M0 on Wire (SDA 19 / SCL 18), M1 on Wire1
 * (SDA 23 / SCL 5). */
#define M0_PWM_A 32
#define M0_PWM_B 33
#define M0_PWM_C 25
#define M1_PWM_A 26
#define M1_PWM_B 27
#define M1_PWM_C 14
#define M_ENABLE 12          /* shared driver enable */
#define M0_ENC_SDA 19
#define M0_ENC_SCL 18
#define M1_ENC_SDA 23
#define M1_ENC_SCL 5

/* M0 = left wheel, M1 = right wheel. */
static BLDCMotor        m0_motor(kPolePairs);
static BLDCDriver3PWM   m0_driver(M0_PWM_A, M0_PWM_B, M0_PWM_C, M_ENABLE);
static MagneticSensorI2C m0_sensor(AS5600_I2C);
static BLDCMotor        m1_motor(kPolePairs);
static BLDCDriver3PWM   m1_driver(M1_PWM_A, M1_PWM_B, M1_PWM_C, M_ENABLE);
static MagneticSensorI2C m1_sensor(AS5600_I2C);

static bool m0_ready = false; /* M0 encoder present + initFOC ok */
static bool m1_ready = false;

/* AS5600 presence probe: a single, bounded I²C address-poll. GATES initFOC() —
 * calling initFOC on an absent encoder spins SimpleFOC's sensor-align on a
 * NACKing bus and hangs boot (no link, no telemetry). Lifted from the reference
 * (SimpleFocNode.cpp::as5600_present_). */
static const uint8_t kAs5600Addr = 0x36;
static bool as5600_present(TwoWire &w) {
  w.beginTransmission(kAs5600Addr);
  return w.endTransmission() == 0; /* 0 = ACK */
}

static void configure_motor(BLDCMotor &m) {
  m.voltage_limit = kMotorVLimit;
  m.voltage_sensor_align = kMotorVAlign;
  m.controller = MotionControlType::torque;
  m.torque_controller = TorqueControlType::voltage;
}

/* --- board: apply effort to each motor and run its FOC loop. In torque-voltage
 * mode SimpleFOC takes motor.target as Uq directly; we reuse the floor's torque
 * output as a q-axis voltage (the reference's honest first-cut), clamped to the
 * motor voltage limit. Touching a skipped motor's loopFOC/move would read its
 * dead sensor, so we drive ONLY the motors that aligned. --- */
static float torque_to_uq(float t) {
  if (t > kMotorVLimit) t = kMotorVLimit;
  if (t < -kMotorVLimit) t = -kMotorVLimit;
  return t;
}

extern "C" void drive_left(float effort) {
  if (!m0_ready) return;
  m0_motor.target = torque_to_uq(effort);
  m0_motor.loopFOC();
  m0_motor.move();
}

extern "C" void drive_right(float effort) {
  if (!m1_ready) return;
  m1_motor.target = torque_to_uq(effort);
  m1_motor.loopFOC();
  m1_motor.move();
}

static Router g_router;

static void deliver_local(const Frame *f, void *) {
  /* two command ports on this one leaf — each to its own floor (§05) */
  if (f->port == PORT_WHEELS_MOTOR_LEFT) on_command_left(f);
  else if (f->port == PORT_WHEELS_MOTOR_RIGHT) on_command_right(f);
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
  wheels_hub_init(); /* both floors born-disarmed, safe action selected */

  /* arduino-esp32 3.x i2c-ng needs the HAL settled before Wire.begin (800 ms is
   * the empirical floor — climber foc_bench). Two AS5600s share addr 0x36, so
   * each rides its own bus. */
  delay(800);
  Wire.begin(M0_ENC_SDA, M0_ENC_SCL, kI2cHz);
  Wire1.begin(M1_ENC_SDA, M1_ENC_SCL, kI2cHz);

  bool m0_enc = as5600_present(Wire);
  bool m1_enc = as5600_present(Wire1);

  /* bring up + align ONLY the motors whose encoder answered (§05): a motor with
   * an absent AS5600 stays disabled, never energised — born-disarmed is the
   * default, and a skipped motor never reaches drive_*(). */
  if (m0_enc) {
    m0_sensor.init(&Wire);
    m0_motor.linkSensor(&m0_sensor);
    m0_driver.voltage_power_supply = kVbusV;
    m0_driver.voltage_limit = kDriverVLimit;
    m0_driver.init();
    m0_motor.linkDriver(&m0_driver);
    configure_motor(m0_motor);
    m0_motor.init();
    m0_ready = m0_motor.initFOC();
    m0_motor.target = 0.0f;
  }
  if (m1_enc) {
    m1_sensor.init(&Wire1);
    m1_motor.linkSensor(&m1_sensor);
    m1_driver.voltage_power_supply = kVbusV;
    m1_driver.voltage_limit = kDriverVLimit;
    m1_driver.init();
    m1_motor.linkDriver(&m1_driver);
    configure_motor(m1_motor);
    m1_motor.init();
    m1_ready = m1_motor.initFOC();
    m1_motor.target = 0.0f;
  }

  g_router.my_node = MY_NODE;
  for (int i = 0; i < 256; i++) g_router.route_table[i] = LINK_LOCAL;
}

/* The generated schedule lists the contract's ports; the two-motor floor drive
 * loop (control_loop_tick) runs EVERY loop (period 0) and is added here by the
 * firmware, never starved (§08). */
static Task wheels_tasks[N_TASKS + 1];

extern "C" Task *hub_tasks(size_t *n_tasks) {
  wheels_tasks[0] = (Task){0, 0, control_loop_tick}; /* period 0 → every loop pass */
  for (size_t i = 0; i < N_TASKS; i++) wheels_tasks[i + 1] = tasks[i];
  *n_tasks = N_TASKS + 1;
  return wheels_tasks;
}

#endif /* ARDUINO */
