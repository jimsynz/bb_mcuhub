#include "segment.h"
#include "crc16.h"
#include "frame.h" /* be_put_u16 — the CRC trailer is big-endian, matching the wire */
#include <string.h>

/* --- id bit-field pack/unpack (the pinned §03 layout) ---
 *   [ NODE:8 ][ PORT:8 ][ FIRST:1 ][ LAST:1 ][ SEQLO:5 ][ FRAG_IDX:6 ] */
#define SEG_FIRST_BIT 12
#define SEG_LAST_BIT 11
#define SEG_SEQLO_SHIFT 6
#define SEG_SEQLO_MASK 0x1F
#define SEG_FRAG_MASK 0x3F

uint32_t seg_id_pack(uint8_t node, uint8_t port, bool first, bool last,
                     uint8_t seqlo, uint8_t frag_idx) {
  uint32_t id = ((uint32_t)node << 21) | ((uint32_t)port << 13);
  if (first) id |= (1u << SEG_FIRST_BIT);
  if (last) id |= (1u << SEG_LAST_BIT);
  id |= (uint32_t)(seqlo & SEG_SEQLO_MASK) << SEG_SEQLO_SHIFT;
  id |= (uint32_t)(frag_idx & SEG_FRAG_MASK);
  return id;
}

uint8_t seg_id_node(uint32_t id) { return (uint8_t)(id >> 21); }
uint8_t seg_id_port(uint32_t id) { return (uint8_t)(id >> 13); }
bool seg_id_first(uint32_t id) { return (id >> SEG_FIRST_BIT) & 1u; }
bool seg_id_last(uint32_t id) { return (id >> SEG_LAST_BIT) & 1u; }
uint8_t seg_id_seqlo(uint32_t id) { return (uint8_t)((id >> SEG_SEQLO_SHIFT) & SEG_SEQLO_MASK); }
uint8_t seg_id_frag_idx(uint32_t id) { return (uint8_t)(id & SEG_FRAG_MASK); }

/* --- TX --- */

bool seg_split(uint8_t node, uint8_t port, uint16_t seq, const uint8_t *body,
               size_t body_len, CanFrame *out, size_t out_cap, size_t *n_out) {
  *n_out = 0;

  /* body || CRC16(body) — the CRC rides as the body's trailer, over the whole
   * body, never per-fragment (§03). */
  size_t total = body_len + 2;
  if (total > SEG_MAX_BODY) return false; /* over the 512-byte ceiling: tx_oversize */

  uint8_t framed[SEG_MAX_BODY];
  memcpy(framed, body, body_len);
  be_put_u16(&framed[body_len], crc16_ccitt_false(body, body_len));

  size_t n_frags = (total + SEG_CAN_DATA - 1) / SEG_CAN_DATA;
  if (n_frags > out_cap || n_frags > SEG_MAX_FRAGS) return false;

  uint8_t seqlo = (uint8_t)(seq & SEG_SEQLO_MASK);
  for (size_t i = 0; i < n_frags; i++) {
    size_t off = i * SEG_CAN_DATA;
    size_t chunk = total - off;
    if (chunk > SEG_CAN_DATA) chunk = SEG_CAN_DATA;
    out[i].id = seg_id_pack(node, port, i == 0, i == n_frags - 1, seqlo, (uint8_t)i);
    memcpy(out[i].data, &framed[off], chunk);
    out[i].len = (uint8_t)chunk;
  }
  *n_out = n_frags;
  return true;
}

/* --- RX --- */

void seg_reasm_init(SegReasm *r) { memset(r, 0, sizeof(*r)); }

void seg_reasm_feed(SegReasm *r, const CanFrame *f,
                    void (*on_body)(const uint8_t *body, size_t len, void *ctx),
                    void *ctx) {
  uint8_t node = seg_id_node(f->id);
  uint8_t port = seg_id_port(f->id);
  bool first = seg_id_first(f->id);
  bool last = seg_id_last(f->id);
  uint8_t seqlo = seg_id_seqlo(f->id);
  uint8_t idx = seg_id_frag_idx(f->id);

  /* find the slot bound to this (node,port), or a free one for a FIRST */
  SegBuffer *slot = NULL;
  for (size_t i = 0; i < SEG_MAX_SLOTS; i++) {
    if (r->slots[i].active && r->slots[i].node == node && r->slots[i].port == port) {
      slot = &r->slots[i];
      break;
    }
  }

  if (first) {
    /* a FIRST seeds (or re-seeds) a buffer */
    if (!slot) {
      for (size_t i = 0; i < SEG_MAX_SLOTS; i++) {
        if (!r->slots[i].active) { slot = &r->slots[i]; break; }
      }
      if (!slot) { r->rx_frag_drop++; return; } /* all slots busy: drop new, fail-closed */
    }
    slot->active = true;
    slot->node = node;
    slot->port = port;
    slot->seqlo = seqlo;
    slot->next_idx = 0;
    slot->len = 0;
  } else if (!slot) {
    r->rx_frag_orphan++; /* non-first with no open buffer: a stray fragment */
    return;
  }

  /* strict sequential: index and seqlo must match what this body expects */
  if (idx != slot->next_idx || seqlo != slot->seqlo ||
      slot->len + f->len > SEG_MAX_BODY) {
    r->rx_frag_drop++;
    slot->active = false; /* abandon the partial (only a future FIRST may re-seed) */
    return;
  }

  memcpy(&slot->buf[slot->len], f->data, f->len);
  slot->len += f->len;
  slot->next_idx++;

  if (!last) return;

  /* LAST: the buffer holds body || CRC. Verify CRC over the body before delivery. */
  slot->active = false;
  if (slot->len < 2) { r->rx_frag_drop++; return; }
  size_t body_len = slot->len - 2;
  uint16_t want = be_get_u16(&slot->buf[body_len]);
  uint16_t have = crc16_ccitt_false(slot->buf, body_len);
  if (want != have) { r->rx_crc_fail++; return; }

  on_body(slot->buf, body_len, ctx);
}
