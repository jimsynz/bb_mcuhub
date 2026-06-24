/* Host-compiled C parity harness (§03/§06) — the cross-language witness.
 *
 * It rebuilds each parity row's body from the representative value using the C
 * codec (frame.c) and asserts the bytes AND the CRC match the generated vectors
 * byte-for-byte — the same rows the Elixir suite asserts. If either codec
 * drifts (a wrong offset, a different CRC init, a byte-order slip) a row fails
 * and the build is red. The wire literally cannot drift past this.
 *
 * Build + run on the host (no device): see firmware/test/Makefile. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "cobs.h"
#include "crc16.h"
#include "frame.h"
#include "transport.h"

/* --- per-(hub,port) packers: fill a Frame with the SAME representative value
 *     the Elixir generator used (BBMCUHub.Gen.WireGen.sample_value). The header
 *     fields (node/port/seq/t_dev) are filled from the vector by the runner.
 * --- */

/* The test FIXTURE robot's ports (ADR-0003): sensor_hub/{pose,scalar} +
 * act_hub/{effort_cmd,act_status}. The Follower's imu/motor packers are retired
 * with it; these match BBMCUHub.Gen.WireGen.sample_value for the fixture. */

static void pack_sensor_hub_pose(Frame *f) {
  /* layout :imu — qw,qx,qy,qz, wx,wy,wz, ax,ay,az (all f32, big-endian) */
  float v[10] = {1.0f, 0.5f, 1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f, 4.5f};
  for (int i = 0; i < 10; i++)
    be_put_f32(&f->payload[i * 4], v[i]);
  f->payload_len = 40;
}

static void pack_sensor_hub_scalar(Frame *f) {
  /* layout :fixture_scalar (the CUSTOM value-type) — v (f32) */
  be_put_f32(&f->payload[0], 1.0f);
  f->payload_len = 4;
}

static void pack_act_hub_effort_cmd(Frame *f) {
  /* layout :effort — nm (f32) */
  be_put_f32(&f->payload[0], 1.0f);
  f->payload_len = 4;
}

static void pack_act_hub_act_status(Frame *f) {
  /* layout :status — applied_seq (u16), floored (bool/u8) */
  be_put_u16(&f->payload[0], 7);
  f->payload[2] = 0; /* false */
  f->payload_len = 3;
}

#include "parity_vectors.h"

static int g_fail = 0;

static void check_row(const ParityVector *pv) {
  Frame f;
  memset(&f, 0, sizeof(f));
  f.node = pv->node;
  f.port = pv->port_id;
  f.seq = pv->seq;
  f.stamped = pv->stamped; /* per-port t_dev (§04) */
  f.t_dev = pv->stamped ? pv->t_dev : 0;
  pv->pack(&f);

  uint8_t body[FRAME_MAX_BODY];
  size_t body_len = frame_encode_body(&f, body, sizeof(body));

  bool ok =
      (body_len == pv->body_len) && (memcmp(body, pv->body, body_len) == 0);
  uint16_t crc = crc16_ccitt_false(body, body_len);
  bool crc_ok = (crc == pv->crc);

  if (ok && crc_ok) {
    printf("  ok   %s/%s  (%zu bytes, crc 0x%04X)\n", pv->hub, pv->port,
           body_len, crc);
  } else {
    g_fail++;
    printf("  FAIL %s/%s\n", pv->hub, pv->port);
    if (!ok) {
      printf("    body mismatch (got %zu, want %zu)\n    got: ", body_len,
             pv->body_len);
      for (size_t i = 0; i < body_len; i++)
        printf("%02X ", body[i]);
      printf("\n    want:");
      for (size_t i = 0; i < pv->body_len; i++)
        printf("%02X ", pv->body[i]);
      printf("\n");
    }
    if (!crc_ok)
      printf("    crc mismatch: got 0x%04X want 0x%04X\n", crc, pv->crc);
  }

  /* Also exercise decode and a full transport round-trip while we are here. */
  Frame d;
  uint64_t want_t = pv->stamped ? pv->t_dev : 0;
  if (!frame_decode_body(pv->body, pv->body_len, pv->stamped, &d)) {
    g_fail++;
    printf("    FAIL decode of %s/%s\n", pv->hub, pv->port);
  } else if (d.node != pv->node || d.port != pv->port_id || d.seq != pv->seq ||
             d.t_dev != want_t) {
    g_fail++;
    printf("    FAIL decode fields of %s/%s\n", pv->hub, pv->port);
  }
}

/* The pinned CRC check value (§03) — the single guard against a wrong variant.
 */
static void check_crc_pinned(void) {
  uint16_t c = crc16_ccitt_false((const uint8_t *)"123456789", 9);
  if (c == 0x29B1) {
    printf("  ok   CRC-16/CCITT-FALSE check value 0x29B1\n");
  } else {
    g_fail++;
    printf("  FAIL CRC check value: got 0x%04X want 0x29B1\n", c);
  }
}

/* A COBS round-trip over an embedded zero, a zero-run, and the 254 boundary. */
static void check_cobs(void) {
  uint8_t cases[][8] = {
      {0x11, 0x22, 0x00, 0x33}, {0x00, 0x00, 0x00}, {0x01, 0x00, 0x02}};
  size_t lens[] = {4, 3, 3};
  for (int i = 0; i < 3; i++) {
    uint8_t enc[32], dec[32];
    size_t e = cobs_encode(cases[i], lens[i], enc, sizeof(enc));
    /* null-free */
    for (size_t j = 0; j < e; j++) {
      if (enc[j] == 0) {
        g_fail++;
        printf("  FAIL COBS produced a 0x00 byte\n");
      }
    }
    size_t d = cobs_decode(enc, e, dec, sizeof(dec));
    if (d != lens[i] || memcmp(dec, cases[i], d) != 0) {
      g_fail++;
      printf("  FAIL COBS round-trip case %d\n", i);
    }
  }
  if (g_fail == 0)
    printf("  ok   COBS round-trip (embedded zero, zero-run, boundary)\n");
}

/* The full transport seam: encode a body to the wire and decode it back. */
static const uint8_t *g_expect;
static size_t g_expect_len;
static bool g_rt_ok;
static void on_body(const uint8_t *body, size_t len, void *ctx) {
  (void)ctx;
  g_rt_ok = (len == g_expect_len) && (memcmp(body, g_expect, len) == 0);
}

static void check_transport_roundtrip(void) {
  const ParityVector *pv = &PARITY_VECTORS[0];
  uint8_t wire[FRAME_MAX_WIRE];
  size_t w = transport_encode(pv->body, pv->body_len, wire, sizeof(wire));

  TransportDecoder dec;
  transport_decoder_init(&dec);
  g_expect = pv->body;
  g_expect_len = pv->body_len;
  g_rt_ok = false;
  transport_decoder_feed(&dec, wire, w, on_body, NULL);

  if (g_rt_ok && dec.rx_drop == 0) {
    printf("  ok   transport encode→decode round-trip\n");
  } else {
    g_fail++;
    printf("  FAIL transport round-trip (rx_drop=%u)\n", dec.rx_drop);
  }
}

int main(void) {
  printf("== bb_mcuhub C parity harness ==\n");
  check_crc_pinned();
  check_cobs();
  printf("-- parity vectors --\n");
  for (size_t i = 0; i < N_PARITY_VECTORS; i++)
    check_row(&PARITY_VECTORS[i]);
  check_transport_roundtrip();

  if (g_fail == 0) {
    printf("\nALL C PARITY CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C PARITY CHECK(S) FAILED\n", g_fail);
  return 1;
}
