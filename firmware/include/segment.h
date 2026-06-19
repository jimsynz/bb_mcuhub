/* CAN segmentation + fail-closed reassembly (§03).
 *
 * A logical body (NODE·PORT·SEQ·[T_DEV]·PAYLOAD) plus its 2-byte end-to-end
 * CRC-16 is often wider than a CAN data field (8 B on the ESP32's classic-CAN
 * TWAI). This module splits a body across CAN frames on TX and reassembles it
 * on RX, with the fragment metadata in the 13 reserved bits of the 29-bit id:
 *
 *   [ NODE:8 ][ PORT:8 ][ FIRST:1 ][ LAST:1 ][ SEQLO:5 ][ FRAG_IDX:6 ]
 *     28..21    20..13     bit12      bit11      10..6        5..0
 *
 * The CAN data field stays 100% body bytes (the CRC rides as the body's
 * trailer, never per-fragment metadata), so the CAN body is byte-identical to
 * the UART body and the parity vectors hold across both transports (§06). The
 * CRC is over the whole reassembled body, checked at every CAN receive —
 * single- and multi-frame alike — because CAN's own per-frame CRC cannot
 * survive a branch hub's decode-rebuild-retransmit (§03).
 *
 * Reassembly is fail-closed (§04): a buffer is seeded only by a FIRST fragment;
 * any gap, reorder, SEQLO mismatch, or CRC failure drops the WHOLE body
 * (counted, never delivered partial) — a lost body is a stale-making non-event
 * the freshness machinery already tolerates, whereas a partial body reaching a
 * slot would be silent corruption. No reassembly timeout in v1: a stalled
 * partial is reclaimed structurally by the next FIRST for that (node, port).
 *
 * Pure logic, no hardware — the firmware binds twai_transmit/twai_receive; this
 * is unit-tested on the host like router.c / floor.c. */
#ifndef BB_MCUHUB_SEGMENT_H
#define BB_MCUHUB_SEGMENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The segmentation ceiling: 6-bit index → 64 fragments × 8 B = 512-byte body
 * (the body the §06 boot size-check is asserted against). */
#define SEG_MAX_FRAGS 64
#define SEG_CAN_DATA 8
#define SEG_MAX_BODY (SEG_MAX_FRAGS * SEG_CAN_DATA) /* 512 */
#define SEG_MAX_SLOTS 8 /* in-flight (node,port) buffers */

/* One CAN frame as the segmenter produces / consumes it: a 29-bit extended id
 * and up to 8 data bytes. (Mirrors the fields of twai_message_t the firmware
 * uses.) */
typedef struct {
  uint32_t id;
  uint8_t data[SEG_CAN_DATA];
  uint8_t len;
} CanFrame;

/* --- id bit-field pack/unpack (the pinned layout above) --- */
uint32_t seg_id_pack(uint8_t node, uint8_t port, bool first, bool last,
                     uint8_t seqlo, uint8_t frag_idx);
uint8_t seg_id_node(uint32_t id);
uint8_t seg_id_port(uint32_t id);
bool seg_id_first(uint32_t id);
bool seg_id_last(uint32_t id);
uint8_t seg_id_seqlo(uint32_t id);
uint8_t seg_id_frag_idx(uint32_t id);

/* --- TX: split a CRC-covered body into ordered CAN frames --- */

/* Append the 2-byte CRC-16 trailer to `body` (the NODE…PAYLOAD bytes), split
 * the result into ordered fragments, and write the segment id bits. Fragments
 * go into out[0..*n_out). Returns true on success; false (and *n_out = 0) if
 * body+CRC exceeds the 512-byte / 64-fragment ceiling — the should-never-happen
 * tx_oversize case the §06 boot size-check forbids. The producer's `seq`
 * supplies SEQLO. */
bool seg_split(uint8_t node, uint8_t port, uint16_t seq, const uint8_t *body,
               size_t body_len, CanFrame *out, size_t out_cap, size_t *n_out);

/* --- RX: fail-closed reassembler --- */

typedef struct {
  bool active; /* is a body currently being reassembled in this slot? */
  uint8_t node,
      port;      /* the (node,port) key this slot is bound to while active */
  uint8_t seqlo; /* the body's seq low-5-bits, binding fragments to one body */
  uint8_t next_idx; /* the FRAG_IDX expected next (strict sequential) */
  size_t len;       /* bytes accumulated so far */
  uint8_t buf[SEG_MAX_BODY];
} SegBuffer;

typedef struct {
  SegBuffer slots[SEG_MAX_SLOTS];
  uint32_t
      rx_frag_orphan; /* non-first fragment with no open buffer for its key */
  uint32_t
      rx_frag_drop; /* a gap/reorder/alias/slot-pressure dropped a partial */
  uint32_t rx_crc_fail; /* a fully reassembled body failed its CRC-16 */
} SegReasm;

void seg_reasm_init(SegReasm *r);

/* Feed one received CAN frame. On a complete, CRC-clean, in-order body, calls
 * `on_body` with the CRC-stripped body (NODE…PAYLOAD). Otherwise drops +
 * counts; `on_body` is never called with a partial or corrupt body. */
void seg_reasm_feed(SegReasm *r, const CanFrame *f,
                    void (*on_body)(const uint8_t *body, size_t len, void *ctx),
                    void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_SEGMENT_H */
