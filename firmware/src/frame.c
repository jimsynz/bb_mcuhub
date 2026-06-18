#include "frame.h"
#include <string.h>

/* --- big-endian field helpers --- */

void be_put_u16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)(v);
}

void be_put_u32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)(v);
}

void be_put_u64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (56 - 8 * i));
}

void be_put_f32(uint8_t *p, float v) {
  uint32_t bits;
  memcpy(&bits, &v, sizeof(bits)); /* IEEE-754, same as Elixir float-32 */
  be_put_u32(p, bits);
}

uint16_t be_get_u16(const uint8_t *p) {
  return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}

uint32_t be_get_u32(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

uint64_t be_get_u64(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
  return v;
}

float be_get_f32(const uint8_t *p) {
  uint32_t bits = be_get_u32(p);
  float v;
  memcpy(&v, &bits, sizeof(v));
  return v;
}

/* --- body serialise/parse --- */

size_t frame_encode_body(const Frame *f, uint8_t *out, size_t out_cap) {
  size_t hdr = f->stamped ? FRAME_HEADER_STAMPED_SIZE : FRAME_HEADER_BASE_SIZE;
  size_t need = hdr + f->payload_len;
  if (need > out_cap) return 0;

  out[0] = f->node;
  out[1] = f->port;
  be_put_u16(&out[2], f->seq);
  if (f->stamped) be_put_u64(&out[4], f->t_dev); /* t_dev only on a stamped port */
  memcpy(&out[hdr], f->payload, f->payload_len);
  return need;
}

bool frame_decode_body(const uint8_t *body, size_t body_len, bool stamped, Frame *f) {
  size_t hdr = stamped ? FRAME_HEADER_STAMPED_SIZE : FRAME_HEADER_BASE_SIZE;
  if (body_len < hdr) return false;
  size_t plen = body_len - hdr;
  if (plen > FRAME_MAX_PAYLOAD) return false;

  f->node = body[0];
  f->port = body[1];
  f->seq = be_get_u16(&body[2]);
  f->stamped = stamped;
  f->t_dev = stamped ? be_get_u64(&body[4]) : 0;
  f->payload_len = plen;
  memcpy(f->payload, &body[hdr], plen);
  return true;
}
