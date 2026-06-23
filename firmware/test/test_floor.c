/* Host-compiled test of the floor (§05): born-disarmed, dead-man on
 * command-seq, fail-passive. Pure logic, no hardware.
 *
 * ADR-0005: the floor is byte-generic — it stores and drives the PACKED VALUE
 * of the port's value-type, never a float. Here we use a 4-byte packed value
 * (an f32, the scalar effort case, N=4) and assert the OUTPUT BYTES equal the
 * safe-bytes when floored / the target-bytes when armed. The behavioural cases
 * (born-disarmed, earns motion on a 2nd distinct seq, floors on silence, same
 * seq re-arrival doesn't refresh, stays armed while advancing) are unchanged.
 */
#include "floor.h"
#include "frame.h"
#include <stdio.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, msg)                                                       \
  do {                                                                         \
    if (cond) {                                                                \
      printf("  ok   %s\n", msg);                                              \
    } else {                                                                   \
      g_fail++;                                                                \
      printf("  FAIL %s\n", msg);                                              \
    }                                                                          \
  } while (0)

#define WINDOW 100 /* FLOOR_MISSES(5) * CMD_PERIOD_MS(20) */
#define N 4        /* the scalar effort case: one f32 */

/* Pack a float into a 4-byte big-endian buffer (the effort layout). */
static void pack(uint8_t *buf, float v) { be_put_f32(buf, v); }

/* Does the floor's `n`-byte output equal these bytes? */
static bool out_is(const uint8_t *out, const uint8_t *want, uint8_t n) {
  return memcmp(out, want, n) == 0;
}

int main(void) {
  printf("== bb_mcuhub C floor harness ==\n");

  uint8_t safe[N];
  uint8_t target[N];
  uint8_t out[FLOOR_MAX_VALUE];
  pack(safe, 0.0f);
  pack(target, 0.5f);

  /* Born disarmed: with no command at all, the floor drives the safe action. */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    uint8_t n = floor_tick(&f, 0, out);
    CHECK(n == N && out_is(out, safe, N) && !f.armed,
          "born disarmed → safe action, no arm");
    floor_tick(&f, 1000, out);
    CHECK(out_is(out, safe, N) && !f.armed, "still safe with no command");
  }

  /* A single command (one seq) is only a baseline — it must NOT arm (strict).
   */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    floor_on_command(&f, 10, target, N);
    floor_tick(&f, 0, out);
    CHECK(out_is(out, safe, N) && !f.armed,
          "first command seq is a baseline → not armed (drives safe)");
  }

  /* A second, distinct command seq earns motion: armed, drives the target. */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    floor_on_command(&f, 10, target, N);
    floor_tick(&f, 0, out); /* baseline */
    floor_on_command(&f, 11, target, N);
    floor_tick(&f, 20, out);
    CHECK(out_is(out, target, N) && f.armed,
          "second distinct seq → armed, drives target bytes");
  }

  /* Command silence past the window → de-energise and latch disarmed. */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    floor_on_command(&f, 10, target, N);
    floor_tick(&f, 0, out);
    floor_on_command(&f, 11, target, N);
    floor_tick(&f, 20, out); /* armed */
    /* now the command goes silent: same seq, time advances past the window */
    floor_tick(&f, 20 + WINDOW + 1, out);
    CHECK(out_is(out, safe, N) && !f.armed,
          "command silence past window → safe bytes, latched disarmed");
  }

  /* Stays armed while the seq keeps advancing within the window. */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    floor_on_command(&f, 10, target, N);
    floor_tick(&f, 0, out);
    bool ok = true;
    for (uint16_t i = 1; i <= 20; i++) {
      floor_on_command(&f, 10 + i, target, N);
      floor_tick(&f, 20 * i, out);
      if (!(out_is(out, target, N) && f.armed))
        ok = false;
    }
    CHECK(ok, "stays armed while command seq advances each period");
  }

  /* A re-arrival of the SAME seq is not an advance → eventually floors. */
  {
    Floor f;
    floor_init(&f, WINDOW, safe, N);
    floor_on_command(&f, 10, target, N);
    floor_tick(&f, 0, out);
    floor_on_command(&f, 11, target, N);
    floor_tick(&f, 20, out); /* armed */
    /* same seq re-sent repeatedly (a relay re-arrival); time passes the window
     */
    floor_on_command(&f, 11, target, N);
    floor_tick(&f, 20 + WINDOW + 1, out);
    CHECK(out_is(out, safe, N) && !f.armed,
          "re-arrival of same seq does not refresh → floors (safe bytes)");
  }

  /* A multi-byte packed value (here still 4B, but a distinct payload) is driven
   * VERBATIM when armed — the floor never reinterprets the bytes (ADR-0005). */
  {
    uint8_t neutral[N];
    uint8_t pose[N];
    pack(neutral, 90.0f); /* e.g. a servo neutral; safe = neutral */
    pack(pose, 30.0f);
    Floor f;
    floor_init(&f, WINDOW, neutral, N);
    floor_on_command(&f, 1, pose, N);
    floor_tick(&f, 0, out); /* baseline → safe = neutral */
    CHECK(out_is(out, neutral, N), "floored drives the safe value verbatim");
    floor_on_command(&f, 2, pose, N);
    floor_tick(&f, 10, out); /* armed → target = pose */
    CHECK(out_is(out, pose, N) && f.armed,
          "armed drives the commanded value verbatim (byte-generic)");
  }

  if (g_fail == 0) {
    printf("\nALL C FLOOR CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C FLOOR CHECK(S) FAILED\n", g_fail);
  return 1;
}
