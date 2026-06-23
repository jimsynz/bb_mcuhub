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
 * VALUE-TYPE-AGNOSTIC (ADR-0005): the floor stores and drives OPAQUE BYTES, the
 * packed value of the port's own value-type — never a float. The safe action is
 * just a valid command value, packed by the same layout codec the wire uses;
 * the floor swaps byte buffers and watches the seq, exactly as before, and
 * never knows whether the value is a torque, a servo pose, or an RGB triple.
 * The
 * `_drive` hook receives the packed value and the device code unpacks it. A
 * scalar effort floor is just N = 4.
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

/* Max packed value width the floor carries — the frame payload ceiling
 * (FRAME_MAX_PAYLOAD). Every value-type's packed size fits under this. */
#define FLOOR_MAX_VALUE 64

typedef struct {
  uint32_t window_ms; /* FLOOR_MISSES * CMD_PERIOD_MS, from the contract */
  uint16_t cmd_seq;   /* last command seq received (set by on_command) */
  uint16_t last_seq;  /* last seq the tick observed */
  uint32_t last_advance_ms;
  bool armed;         /* false at boot — born disarmed */
  bool have_baseline; /* have we recorded a first seq to compare against? */
  bool seen_advance;  /* has the seq advanced (since boot) at least once? */
  uint8_t n;          /* packed value width (bytes), from the layout */
  uint8_t target[FLOOR_MAX_VALUE]; /* commanded packed value */
  uint8_t safe[FLOOR_MAX_VALUE]; /* safe packed value (driven when disarmed) */
} Floor;

/* Initialise born-disarmed with the safe action already selected. `safe` is the
 * packed safe-action value (`n` bytes); it is copied into both `safe` and
 * `target`, so a born-disarmed floor drives the safe value before any command.
 *
 * Fail-closed on width: `n` must be <= FLOOR_MAX_VALUE (the compile-time frame
 * ceilings guarantee it). An over-wide `n` is NOT copied — the floor sets n = 0
 * and stays disarmed (drives nothing), rather than overrunning its own buffers
 * and corrupting the dead-man's state. */
void floor_init(Floor *f, uint32_t window_ms, const uint8_t *safe, uint8_t n);

/* A new command frame for this hub's actuator port: record the packed value
 * (`n` bytes) as the target + its seq. The floor watches the SEQ, not the
 * value.
 *
 * Fail-closed on width: an over-wide `n` (> FLOOR_MAX_VALUE) is IGNORED —
 * neither the target nor the seq is updated, so a malformed command can neither
 * overrun the buffer nor count as a seq advance; the dead-man then floors on
 * silence. */
void floor_on_command(Floor *f, uint16_t seq, const uint8_t *value, uint8_t n);

/* Run one control tick at monotonic time `now_ms`. Writes the value to DRIVE
 * into `out[0..n)` — the target while armed, the safe action otherwise — and
 * returns its width `n`. Updates arm/disarm state. */
uint8_t floor_tick(Floor *f, uint32_t now_ms, uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_FLOOR_H */
