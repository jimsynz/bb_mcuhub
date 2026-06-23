#include "floor.h"
#include <string.h>

void floor_init(Floor *f, uint32_t window_ms, const uint8_t *safe, uint8_t n) {
  f->window_ms = window_ms;
  f->cmd_seq = 0;
  f->last_seq = 0;
  f->last_advance_ms = 0;
  f->armed = false;         /* born disarmed */
  f->have_baseline = false; /* no first seq recorded yet */
  f->seen_advance = false;  /* nothing witnessed yet */

  /* Fail-closed on an over-wide value (defence-in-depth): the §06 frame-size
   * check + the FLOOR_MAX_VALUE payload ceiling already bound `n` at compile
   * time, so `n > FLOOR_MAX_VALUE` is a should-never-happen (a generator/layout
   * drift, or a future device-mocked path). Rather than memcpy past `safe[]`/
   * `target[]` and corrupt the dead-man's own state, we drive NOTHING (n = 0)
   * and stay disarmed — born-disarmed already, so the safe behaviour is to
   * energise nothing. */
  if (n > FLOOR_MAX_VALUE) {
    f->n = 0;
    return;
  }
  f->n = n;
  memcpy(f->safe, safe, n);
  memcpy(f->target, safe, n); /* born-disarmed → safe value selected */
}

void floor_on_command(Floor *f, uint16_t seq, const uint8_t *value, uint8_t n) {
  /* Fail-closed (see floor_init): an over-wide command is ignored entirely —
   * neither the target nor the seq is updated, so it cannot overrun the buffer
   * and cannot count as an advance. The dead-man then floors on silence, since
   * a bad command never refreshes it. */
  if (n > FLOOR_MAX_VALUE)
    return;

  f->cmd_seq = seq; /* watch the seq, not the value */
  f->n = n;
  memcpy(f->target, value, n);
}

uint8_t floor_tick(Floor *f, uint32_t now_ms, uint8_t *out) {
  /* Born-disarmed, STRICT (matches the host monitor's §04 choice): the first
   * command seq we ever see only records a baseline; trust begins on a later,
   * DIFFERENT seq — so a stale command sitting in a buffer at boot cannot
   * energise us. "Advanced?" is a plain inequality, sound because every path to
   * this chip is in-order (§04); no magnitude test ⇒ counter wrap is harmless.
   */
  if (!f->have_baseline) {
    f->have_baseline = true;
    f->last_seq = f->cmd_seq;
  } else if (f->cmd_seq != f->last_seq) {
    f->last_seq = f->cmd_seq;
    f->seen_advance = true;
    f->last_advance_ms = now_ms;
  }

  bool fresh =
      f->seen_advance && (uint32_t)(now_ms - f->last_advance_ms) < f->window_ms;

  if (!fresh) {
    f->armed = false; /* silence (or not-yet-earned) → safe, latched */
    memcpy(out, f->safe, f->n);
    return f->n;
  }

  f->armed = true; /* a fresh, in-window command earns motion */
  memcpy(out, f->target, f->n);
  return f->n;
}
