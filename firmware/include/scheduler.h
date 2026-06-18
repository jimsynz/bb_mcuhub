/* The per-port cooperative scheduler (§08). Each port is a {period, tick} row
 * generated from the contract (hubs/<hub>/mcu/schedule.gen.h). One loop fires
 * each row when its period has elapsed — cooperative, non-preemptive, no
 * per-device timer, no RTOS task.
 *
 * The one rule that makes this safe: every tick is BOUNDED by construction (no
 * spin, no blocking wait; a read that times out simply returns and writes
 * nothing, so its seq stalls and the reader goes stale — legible, not a hang).
 * A hardware watchdog fed at the top of the loop is the backstop: a wedged loop
 * resets the chip, which comes up born-disarmed (§05). */
#ifndef BB_MCUHUB_SCHEDULER_H
#define BB_MCUHUB_SCHEDULER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint32_t period_us;
  uint32_t last_us;
  void (*tick)(uint32_t now_us);
} Task;

/* Fire every task in `tasks` that is due at `now_us`. The actuator floor runs
 * every loop and is invoked directly by the main loop, not via this table. */
void scheduler_run(Task *tasks, size_t n_tasks, uint32_t now_us);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_SCHEDULER_H */
