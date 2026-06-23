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
  f->n = n;
  memcpy(f->safe, safe, n);
  memcpy(f->target, safe, n); /* born-disarmed → safe value selected */
}

void floor_on_command(Floor *f, uint16_t seq, const uint8_t *value, uint8_t n) {
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
