#include "scheduler.h"

void scheduler_run(Task *tasks, size_t n_tasks, uint32_t now_us) {
  for (size_t i = 0; i < n_tasks; i++) {
    /* unsigned subtraction handles micros() wrap correctly */
    if ((uint32_t)(now_us - tasks[i].last_us) >= tasks[i].period_us) {
      tasks[i].last_us = now_us;
      tasks[i].tick(now_us); /* tick gets `now`, so it needs no clock of its own */
    }
  }
}
