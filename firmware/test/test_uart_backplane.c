/* Host-compiled test of the UART backplane (§03). When a robot's backplane is a
 * plain UART (BACKPLANE_TRANSPORT_UART == 1) the root hub ↔ children link carries
 * the SAME COBS+CRC frame as the host↔root seam, with NO CAN segmentation: COBS
 * already frames arbitrary-length bodies, so a wide body (the 54-byte IMU) rides
 * one frame. This harness exercises the exact path link_esp32.cpp's UART backplane
 * uses — transport_encode on TX, transport_decoder_feed on RX (transport.c) — and
 * proves a wide body round-trips byte-identical without fragmentation. Pure logic,
 * no hardware. */
#include <stdio.h>
#include <string.h>
#include "transport.h"
#include "crc16.h"

static int g_fail = 0;
#define CHECK(cond, msg)                          \
  do {                                            \
    if (cond) { printf("  ok   %s\n", msg); }     \
    else { g_fail++; printf("  FAIL %s\n", msg); }\
  } while (0)

/* capture what the decoder delivered */
static int g_delivered;
static uint8_t g_body[FRAME_MAX_BODY + 2];
static size_t g_body_len;
static void on_body(const uint8_t *body, size_t len, void *ctx) {
  (void)ctx;
  g_delivered++;
  g_body_len = len;
  memcpy(g_body, body, len);
}
static void reset_capture(void) { g_delivered = 0; g_body_len = 0; }

/* a representative 54-byte IMU body: NODE PORT SEQ T_DEV(8) + 42-byte payload
 * (the stamped IMU value — 10 floats = 40 B is the contract; here we use a wide
 * 42-byte fill so the body lands at 54 to mirror the brief's worst case). */
static size_t make_imu_body(uint8_t *out, uint16_t seq) {
  size_t n = 0;
  out[n++] = 0x02;             /* NODE (imu) */
  out[n++] = 0xEF;             /* PORT (imu/pose) */
  out[n++] = (uint8_t)(seq >> 8);
  out[n++] = (uint8_t)seq;     /* SEQ */
  for (int i = 0; i < 8; i++) out[n++] = (uint8_t)(0xA0 + i);   /* T_DEV (stamped) */
  for (int i = 0; i < 42; i++) out[n++] = (uint8_t)(i * 7 + 1); /* payload */
  return n; /* 54 */
}

int main(void) {
  printf("== bb_mcuhub C UART backplane harness ==\n");

  /* TRACER: a 54-byte IMU body, COBS+CRC framed via transport_encode (the exact
   * TX path the UART backplane uses), fed back through a TransportDecoder, round-
   * trips byte-identical in ONE frame — no segmentation. */
  uint8_t body[FRAME_MAX_BODY];
  size_t blen = make_imu_body(body, 42);
  CHECK(blen == 54, "IMU body is 54 bytes (12 header + 42 payload)");

  uint8_t wire[FRAME_MAX_WIRE];
  size_t w = transport_encode(body, blen, wire, sizeof(wire));
  CHECK(w > 0, "transport_encode frames the 54-byte body (COBS+CRC || 0x00)");
  CHECK(wire[w - 1] == 0x00, "the wire frame ends in the single 0x00 COBS delimiter");

  /* exactly ONE delimiter in the whole frame → exactly ONE COBS frame, no
   * fragmentation: a wide body crosses a UART backplane in a single frame. */
  size_t n_delims = 0;
  for (size_t i = 0; i < w; i++) if (wire[i] == 0x00) n_delims++;
  CHECK(n_delims == 1, "the wide body rides ONE COBS frame (no CAN-style fragmentation)");

  TransportDecoder d;
  transport_decoder_init(&d);
  reset_capture();
  transport_decoder_feed(&d, wire, w, on_body, NULL);
  CHECK(g_delivered == 1, "the decoder delivers exactly one body");
  CHECK(g_body_len == blen && memcmp(g_body, body, blen) == 0,
        "the delivered body is byte-identical to the original (CRC stripped)");
  CHECK(d.rx_drop == 0, "a clean frame is never counted as a drop");

  /* feeding byte-at-a-time (as link_pump does over Serial2) delivers identically */
  {
    TransportDecoder dd; transport_decoder_init(&dd); reset_capture();
    for (size_t i = 0; i < w; i++) transport_decoder_feed(&dd, &wire[i], 1, on_body, NULL);
    CHECK(g_delivered == 1 && g_body_len == blen && memcmp(g_body, body, blen) == 0,
          "byte-at-a-time feed (the link_pump path) round-trips byte-identical");
  }

  /* two back-to-back bodies on the same stream both deliver, in order */
  {
    uint8_t b1[FRAME_MAX_BODY]; size_t l1 = make_imu_body(b1, 100);
    uint8_t b2[FRAME_MAX_BODY]; size_t l2 = make_imu_body(b2, 101);
    uint8_t w1[FRAME_MAX_WIRE]; size_t n1 = transport_encode(b1, l1, w1, sizeof(w1));
    uint8_t w2[FRAME_MAX_WIRE]; size_t n2 = transport_encode(b2, l2, w2, sizeof(w2));

    TransportDecoder dd; transport_decoder_init(&dd);
    int got_1 = 0, got_2 = 0;
    reset_capture();
    transport_decoder_feed(&dd, w1, n1, on_body, NULL);
    got_1 = (g_delivered == 1 && g_body_len == l1 && memcmp(g_body, b1, l1) == 0);
    reset_capture();
    transport_decoder_feed(&dd, w2, n2, on_body, NULL);
    got_2 = (g_delivered == 1 && g_body_len == l2 && memcmp(g_body, b2, l2) == 0);
    CHECK(got_1 && got_2, "two back-to-back framed bodies both deliver, in order");
  }

  /* fail-closed: a one-bit flip in a framed body fails the CRC and is dropped,
   * never delivered partial — the same guarantee the host↔root seam gives (§04). */
  {
    uint8_t b[FRAME_MAX_BODY]; size_t l = make_imu_body(b, 202);
    uint8_t wb[FRAME_MAX_WIRE]; size_t nb = transport_encode(b, l, wb, sizeof(wb));
    wb[5] ^= 0x40; /* corrupt a COBS-encoded byte mid-frame */

    TransportDecoder dd; transport_decoder_init(&dd); reset_capture();
    transport_decoder_feed(&dd, wb, nb, on_body, NULL);
    CHECK(g_delivered == 0, "CRC corruption: a corrupted body is NEVER delivered");
    CHECK(dd.rx_drop == 1, "CRC corruption: dropped and counted at the seam");
  }

  if (g_fail == 0) {
    printf("\nALL C UART BACKPLANE CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C UART BACKPLANE CHECK(S) FAILED\n", g_fail);
  return 1;
}
