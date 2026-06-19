/* The on-wire frame (§03), C side — mirrors BBMcuhub.Wire.Codec +
 * BBMcuhub.Wire.FramingCOBS exactly, byte-for-byte (the parity vectors prove
 * it).
 *
 * Body (the CRC-covered bytes):  NODE u8 · PORT u8 · SEQ u16 · T_DEV u64 ·
 * PAYLOAD Wire frame:  COBS( body || CRC16(body) ) || 0x00
 *
 * All multi-byte integers and floats are BIG-ENDIAN, the same order the Elixir
 * side serialises with. The payload bytes are the packed value struct from
 * wire_contract.h, written field-by-field big-endian (a packed struct alone is
 * host-endian, so we serialise explicitly). */
#ifndef BB_MCUHUB_FRAME_H
#define BB_MCUHUB_FRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Header is per-port (§04): the base NODE(1)+PORT(1)+SEQ(2) always present,
 * plus T_DEV(8) only on a STAMPED port. */
#define FRAME_HEADER_BASE_SIZE 4
#define FRAME_HEADER_STAMPED_SIZE 12
#define FRAME_HEADER_MAX_SIZE FRAME_HEADER_STAMPED_SIZE
#define FRAME_MAX_PAYLOAD 64
#define FRAME_MAX_BODY (FRAME_HEADER_MAX_SIZE + FRAME_MAX_PAYLOAD)
/* COBS worst case + the 2-byte CRC + the delimiter */
#define FRAME_MAX_WIRE (FRAME_MAX_BODY + 2 + ((FRAME_MAX_BODY + 2) / 254) + 2)

typedef struct {
  uint8_t node;
  uint8_t port;
  uint16_t seq;
  bool stamped;   /* does this frame carry t_dev? (§04) — a per-port fact */
  uint64_t t_dev; /* valid only when stamped */
  uint8_t payload[FRAME_MAX_PAYLOAD];
  size_t payload_len;
} Frame;

/* --- body (header+payload) serialise/parse, big-endian --- */

/* Write the CRC-covered body for `f` into `out` (cap `out_cap`). The header
 * shape follows f->stamped. Returns the body length, or 0 if it would not fit.
 */
size_t frame_encode_body(const Frame *f, uint8_t *out, size_t out_cap);

/* Parse a CRC-verified body into `f`. `stamped` says whether a t_dev follows
 * the base header — the caller knows this from the per-(node,port) contract,
 * exactly as the Elixir decoder learns it from PortIndex (§04). Returns true on
 * success. */
bool frame_decode_body(const uint8_t *body, size_t body_len, bool stamped,
                       Frame *f);

/* --- big-endian field helpers (used by per-type payload packers) --- */
void be_put_u16(uint8_t *p, uint16_t v);
void be_put_u32(uint8_t *p, uint32_t v);
void be_put_u64(uint8_t *p, uint64_t v);
void be_put_f32(uint8_t *p, float v);
uint16_t be_get_u16(const uint8_t *p);
uint32_t be_get_u32(const uint8_t *p);
uint64_t be_get_u64(const uint8_t *p);
float be_get_f32(const uint8_t *p);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_FRAME_H */
