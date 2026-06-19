/* The floor (§05) — the safety core, on the actuator hub's OWN chip.
 *
 * It watches the seq of its own command against a compiled-in window on its own
 * monotonic clock. If the seq stops advancing for the window, it drives the
 * plant to its safe action and latches disarmed. It needs no inbound frame, so
 * it fires even if the parent, the tree above, or the host is entirely gone.
 *
 * Born-disarmed: armed is false at every boot, output already at the safe
 * action; motion is earned only by witnessing a fresh, in-window command seq
 * advancing SINCE THIS chip's boot.
 *
 * Pure logic, no hardware — the firmware binds drive()/safe-action to pins;
 * this is unit-tested on the host. "Advanced?" is a plain inequality (seq !=
 * last), sound because every path to this chip is in-order (§04). */
#ifndef BB_MCUHUB_FLOOR_H
#define BB_MCUHUB_FLOOR_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint32_t window_ms; /* FLOOR_MISSES * CMD_PERIOD_MS, from the contract */
  uint16_t cmd_seq;   /* last command seq received (set by on_command) */
  uint16_t last_seq;  /* last seq the tick observed */
  uint32_t last_advance_ms;
  bool armed;         /* false at boot — born disarmed */
  bool have_baseline; /* have we recorded a first seq to compare against? */
  bool seen_advance;  /* has the seq advanced (since boot) at least once? */
  float target;       /* commanded setpoint */
  float safe_action;  /* the value driven when disarmed (e.g. 0 torque) */
} Floor;

/* Initialise born-disarmed with the safe action already selected. */
void floor_init(Floor *f, uint32_t window_ms, float safe_action);

/* A new command frame for this hub's actuator port: record target + its seq. */
void floor_on_command(Floor *f, uint16_t seq, float target);

/* Run one control tick at monotonic time `now_ms`. Returns the value to DRIVE:
 * the target while armed, the safe action otherwise. Updates arm/disarm state.
 */
float floor_tick(Floor *f, uint32_t now_ms);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_FLOOR_H */
