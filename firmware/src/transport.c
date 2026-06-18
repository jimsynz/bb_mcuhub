#include "transport.h"
#include "cobs.h"
#include "crc16.h"
#include <string.h>

size_t transport_encode(const uint8_t *body, size_t body_len, uint8_t *out, size_t out_cap) {
  /* body || CRC16(body), then COBS, then the 0x00 delimiter */
  uint8_t framed[FRAME_MAX_BODY + 2];
  if (body_len + 2 > sizeof(framed)) return 0;

  memcpy(framed, body, body_len);
  uint16_t crc = crc16_ccitt_false(body, body_len);
  be_put_u16(&framed[body_len], crc); /* CRC is big-endian on the wire, matching Elixir */

  if (out_cap < 1) return 0;
  size_t enc = cobs_encode(framed, body_len + 2, out, out_cap - 1);
  if (enc == 0) return 0;
  out[enc] = 0x00;
  return enc + 1;
}

void transport_decoder_init(TransportDecoder *d) {
  d->len = 0;
  d->rx_drop = 0;
}

static void handle_frame(TransportDecoder *d, transport_on_body_fn on_body, void *ctx) {
  if (d->len == 0) return; /* empty run between two delimiters → ignore */

  uint8_t decoded[FRAME_MAX_BODY + 2];
  size_t dec = cobs_decode(d->buf, d->len, decoded, sizeof(decoded));
  if (dec < 3) { /* need at least 1 body byte + 2 CRC */
    d->rx_drop++;
    return;
  }

  size_t body_len = dec - 2;
  uint16_t want = be_get_u16(&decoded[body_len]);
  uint16_t have = crc16_ccitt_false(decoded, body_len);
  if (want != have) {
    d->rx_drop++;
    return;
  }

  on_body(decoded, body_len, ctx);
}

void transport_decoder_feed(TransportDecoder *d, const uint8_t *bytes, size_t n,
                            transport_on_body_fn on_body, void *ctx) {
  for (size_t i = 0; i < n; i++) {
    uint8_t b = bytes[i];
    if (b == 0x00) {
      handle_frame(d, on_body, ctx);
      d->len = 0;
    } else if (d->len < sizeof(d->buf)) {
      d->buf[d->len++] = b;
    } else {
      /* overflow: a frame longer than any legal frame → resync at next delim */
      d->len = 0;
      d->rx_drop++;
    }
  }
}
