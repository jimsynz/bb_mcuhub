/* Host-compiled test of the floor (§05): born-disarmed, dead-man on command-seq,
 * fail-passive. Pure logic, no hardware. */
#include <stdio.h>
#include "floor.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                  \
  do {                                                    \
    if (cond) {                                           \
      printf("  ok   %s\n", msg);                         \
    } else {                                              \
      g_fail++;                                           \
      printf("  FAIL %s\n", msg);                         \
    }                                                     \
  } while (0)

#define WINDOW 100 /* FLOOR_MISSES(5) * CMD_PERIOD_MS(20) */
#define SAFE 0.0f
#define TARGET 0.5f

int main(void) {
  printf("== bb_mcuhub C floor harness ==\n");

  /* Born disarmed: with no command at all, the floor drives the safe action. */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    CHECK(floor_tick(&f, 0) == SAFE && !f.armed, "born disarmed → safe action, no arm");
    CHECK(floor_tick(&f, 1000) == SAFE && !f.armed, "still safe with no command");
  }

  /* A single command (one seq) is only a baseline — it must NOT arm (strict). */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    floor_on_command(&f, 10, TARGET);
    float out = floor_tick(&f, 0);
    CHECK(out == SAFE && !f.armed, "first command seq is a baseline → not armed");
  }

  /* A second, distinct command seq earns motion: armed, drives the target. */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    floor_on_command(&f, 10, TARGET);
    floor_tick(&f, 0); /* baseline */
    floor_on_command(&f, 11, TARGET);
    float out = floor_tick(&f, 20);
    CHECK(out == TARGET && f.armed, "second distinct seq → armed, drives target");
  }

  /* Command silence past the window → de-energise and latch disarmed. */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    floor_on_command(&f, 10, TARGET);
    floor_tick(&f, 0);
    floor_on_command(&f, 11, TARGET);
    floor_tick(&f, 20); /* armed */
    /* now the command goes silent: same seq, time advances past the window */
    float out = floor_tick(&f, 20 + WINDOW + 1);
    CHECK(out == SAFE && !f.armed, "command silence past window → safe, latched disarmed");
  }

  /* Stays armed while the seq keeps advancing within the window. */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    floor_on_command(&f, 10, TARGET);
    floor_tick(&f, 0);
    bool ok = true;
    for (uint16_t i = 1; i <= 20; i++) {
      floor_on_command(&f, 10 + i, TARGET);
      float out = floor_tick(&f, 20 * i);
      if (!(out == TARGET && f.armed)) ok = false;
    }
    CHECK(ok, "stays armed while command seq advances each period");
  }

  /* A re-arrival of the SAME seq is not an advance → eventually floors. */
  {
    Floor f;
    floor_init(&f, WINDOW, SAFE);
    floor_on_command(&f, 10, TARGET);
    floor_tick(&f, 0);
    floor_on_command(&f, 11, TARGET);
    floor_tick(&f, 20); /* armed */
    /* same seq re-sent repeatedly (a relay re-arrival); time passes the window */
    floor_on_command(&f, 11, TARGET);
    float out = floor_tick(&f, 20 + WINDOW + 1);
    CHECK(out == SAFE && !f.armed, "re-arrival of same seq does not refresh → floors");
  }

  if (g_fail == 0) {
    printf("\nALL C FLOOR CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C FLOOR CHECK(S) FAILED\n", g_fail);
  return 1;
}
