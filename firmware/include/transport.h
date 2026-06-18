/* The framing seam, C side (§03) — the analog of BBMcuhub.Wire.FramingCOBS.
 *
 * Outbound: a CRC-covered body in → COBS(body || CRC16(body)) || 0x00 out.
 * Inbound: a streaming decoder accumulates bytes, splits on 0x00, COBS-decodes,
 * checks the CRC, and hands up only verified bodies. A bad CRC / truncated COBS
 * is dropped and counted — nothing above the seam sees a corrupt frame, so a
 * corrupted seq can never fake an advance (§04). */
#ifndef BB_MCUHUB_TRANSPORT_H
#define BB_MCUHUB_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "frame.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Frame a body for the wire. Returns the wire length, or 0 if it would not fit. */
size_t transport_encode(const uint8_t *body, size_t body_len, uint8_t *out, size_t out_cap);

/* A callback invoked with each verified body the decoder peels off. */
typedef void (*transport_on_body_fn)(const uint8_t *body, size_t body_len, void *ctx);

typedef struct {
  uint8_t buf[FRAME_MAX_WIRE];
  size_t len;
  uint32_t rx_drop; /* corrupt frames dropped at the seam (legible, §03) */
} TransportDecoder;

void transport_decoder_init(TransportDecoder *d);

/* Feed raw bytes; for every complete, CRC-clean frame, `on_body` is called. */
void transport_decoder_feed(TransportDecoder *d, const uint8_t *bytes, size_t n,
                            transport_on_body_fn on_body, void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_TRANSPORT_H */
