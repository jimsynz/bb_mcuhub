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

  /* Fail-closed on an over-wide value (defence-in-depth, candidate 2). The
   * compile-time ceilings (the §06 512-byte frame check + FLOOR_MAX_VALUE=64
   * payload bound) already keep `n` in range, so an `n > FLOOR_MAX_VALUE` here
   * is a should-never-happen (a generator/layout drift, or a future
   * device-mocked path). The floor MUST NOT memcpy past its `safe`/`target`
   * buffers onto the dead-man's own state — it stays disarmed and drives
   * nothing instead. We sentinel the bytes straddling the buffer boundary and
   * assert they are untouched. */
  {
    /* A struct laid out exactly like Floor so we can place a guard field right
     * after the two value buffers and detect a memcpy that runs past them. */
    struct {
      Floor f;
      uint8_t guard[16];
    } box;
    memset(&box, 0xA5, sizeof(box)); /* sentinel everything */
    uint8_t want_guard[16];
    memset(want_guard, 0xA5, sizeof(want_guard));

    /* init with an over-wide safe value: must clamp to nothing, stay disarmed,
     * and never write past safe[FLOOR_MAX_VALUE]. The `over` source is larger
     * than the buffers so an unchecked memcpy would smash `box.guard`. */
    uint8_t over[FLOOR_MAX_VALUE + 16];
    memset(over, 0x5A, sizeof(over));
    floor_init(&box.f, WINDOW, over, FLOOR_MAX_VALUE + 16);
    CHECK(memcmp(box.guard, want_guard, sizeof(want_guard)) == 0,
          "over-wide safe value does not overrun the floor buffers (init)");
    CHECK(!box.f.armed, "over-wide init stays disarmed (fail-closed)");

    uint8_t n = floor_tick(&box.f, 0, out);
    CHECK(n == 0 && !box.f.armed,
          "over-wide init drives nothing, latched disarmed");

    /* A valid floor that is then handed an over-wide command must ignore it:
     * no overrun, no spurious arm (the bad command never advances the seq). */
    Floor g;
    floor_init(&g, WINDOW, safe, N);
    floor_on_command(&g, 1, target, N);
    floor_tick(&g, 0, out); /* baseline */
    floor_on_command(&g, 2, target, N);
    floor_tick(&g, 20, out); /* armed on a good command */
    CHECK(out_is(out, target, N) && g.armed, "armed on a good command (setup)");

    uint8_t bigger[FLOOR_MAX_VALUE + 16];
    memset(bigger, 0x33, sizeof(bigger));
    floor_on_command(&g, 3, bigger, FLOOR_MAX_VALUE + 16); /* must be ignored */
    floor_tick(&g, 40, out);
    CHECK(out_is(out, target, N),
          "over-wide command is ignored → still drives the last good target");
    /* and silence past the window still floors it (the bad command was inert)
     */
    floor_tick(&g, 40 + WINDOW + 1, out);
    CHECK(out_is(out, safe, N) && !g.armed,
          "over-wide command did not refresh the dead-man → floors on silence");
  }

  if (g_fail == 0) {
    printf("\nALL C FLOOR CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C FLOOR CHECK(S) FAILED\n", g_fail);
  return 1;
}
