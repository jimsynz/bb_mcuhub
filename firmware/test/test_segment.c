/* Host-compiled test of CAN segmentation + fail-closed reassembly (§03/§04).
 * Proves a wide body splits into ordered CAN frames and reassembles byte-
 * identical, and that every fail-closed path (lost fragment, reorder, orphan
 * non-first, CRC corruption, seqlo alias, oversize) drops the whole body rather
 * than delivering a partial. Pure logic, no hardware. */
#include <stdio.h>
#include <string.h>
#include "segment.h"
#include "crc16.h"

static int g_fail = 0;
#define CHECK(cond, msg)                          \
  do {                                            \
    if (cond) { printf("  ok   %s\n", msg); }     \
    else { g_fail++; printf("  FAIL %s\n", msg); }\
  } while (0)

/* capture what reassembly delivered */
static int g_delivered;
static uint8_t g_body[SEG_MAX_BODY];
static size_t g_body_len;
static void on_body(const uint8_t *body, size_t len, void *ctx) {
  (void)ctx;
  g_delivered++;
  g_body_len = len;
  memcpy(g_body, body, len);
}
static void reset_capture(void) { g_delivered = 0; g_body_len = 0; }

/* a representative 52-byte IMU body: NODE PORT SEQ T_DEV(8) + 40-byte payload */
static size_t make_imu_body(uint8_t *out, uint16_t seq) {
  size_t n = 0;
  out[n++] = 0x02;            /* NODE */
  out[n++] = 0xEF;            /* PORT (imu/pose) */
  out[n++] = (uint8_t)(seq >> 8);
  out[n++] = (uint8_t)seq;    /* SEQ */
  for (int i = 0; i < 8; i++) out[n++] = (uint8_t)(0xA0 + i); /* T_DEV */
  for (int i = 0; i < 40; i++) out[n++] = (uint8_t)(i * 7 + 1); /* payload */
  return n; /* 52 */
}

int main(void) {
  printf("== bb_mcuhub C segment harness ==\n");

  /* TRACER: a 52-byte body (→ 54 with CRC) splits into 7 ordered frames and
   * reassembles byte-identical. */
  uint8_t body[SEG_MAX_BODY];
  size_t blen = make_imu_body(body, 42);
  CHECK(blen == 52, "IMU body is 52 bytes (12 header + 40 payload)");

  CanFrame frames[SEG_MAX_FRAGS];
  size_t nf = 0;
  bool ok = seg_split(0x02, 0xEF, 42, body, blen, frames, SEG_MAX_FRAGS, &nf);
  CHECK(ok, "seg_split accepts a 52-byte body");
  CHECK(nf == 7, "52+2=54 bytes → 7 fragments (ceil(54/8))");

  SegReasm r;
  seg_reasm_init(&r);
  reset_capture();
  for (size_t i = 0; i < nf; i++) seg_reasm_feed(&r, &frames[i], on_body, NULL);
  CHECK(g_delivered == 1, "reassembly delivers exactly one body");
  CHECK(g_body_len == blen && memcmp(g_body, body, blen) == 0,
        "reassembled body is byte-identical to the original (CRC stripped)");

  /* the segment id bits round-trip and don't disturb (NODE,PORT) or arbitration */
  {
    uint32_t id = seg_id_pack(0x02, 0xEF, true, false, 0x1F, 0x2A);
    CHECK(seg_id_node(id) == 0x02 && seg_id_port(id) == 0xEF,
          "id pack/unpack: NODE and PORT survive in the top 16 bits");
    CHECK(seg_id_first(id) && !seg_id_last(id) && seg_id_seqlo(id) == 0x1F &&
              seg_id_frag_idx(id) == 0x2A,
          "id pack/unpack: FIRST/LAST/SEQLO/FRAG_IDX decode correctly");
    /* the (NODE,PORT) hardware-filter view is the top 16 bits, fragment-agnostic */
    uint32_t id2 = seg_id_pack(0x02, 0xEF, false, true, 0x07, 0x05);
    CHECK((id >> 13) == (id2 >> 13),
          "id: fragments of one (node,port) share the top-16-bit filter key");
    /* e-stop still wins: NODE 0x00 with any fragment bits < any data NODE's id */
    uint32_t estop = seg_id_pack(0x00, 0x00, true, true, 0x1F, 0x3F);
    uint32_t data_frame = seg_id_pack(0x01, 0x00, true, true, 0x00, 0x00);
    CHECK(estop < data_frame, "NODE 0x00 (e-stop) still wins arbitration over any data frame");
  }

  /* a single-frame-sized body (an 8-byte effort command → 10 with CRC → 2 frags)
   * still rides FIRST+LAST framing and reassembles */
  {
    uint8_t cmd[8] = {0x02, 0x28, 0x00, 0x07, 0x3F, 0x80, 0x00, 0x00};
    CanFrame fr[SEG_MAX_FRAGS]; size_t n = 0;
    bool sok = seg_split(0x02, 0x28, 7, cmd, sizeof(cmd), fr, SEG_MAX_FRAGS, &n);
    CHECK(sok && n == 2, "an 8-byte body → 10 with CRC → 2 fragments");
    CHECK(seg_id_first(fr[0].id) && !seg_id_last(fr[0].id) &&
              !seg_id_first(fr[1].id) && seg_id_last(fr[1].id),
          "FIRST set on frag 0, LAST set on the final frag");
    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    seg_reasm_feed(&rr, &fr[0], on_body, NULL);
    seg_reasm_feed(&rr, &fr[1], on_body, NULL);
    CHECK(g_delivered == 1 && g_body_len == sizeof(cmd) &&
              memcmp(g_body, cmd, sizeof(cmd)) == 0,
          "small body reassembles byte-identical");
  }

  /* --- fail-closed: a lost fragment loses the WHOLE body; next FIRST re-seeds --- */
  {
    uint8_t b1[SEG_MAX_BODY]; size_t l1 = make_imu_body(b1, 100);
    uint8_t b2[SEG_MAX_BODY]; size_t l2 = make_imu_body(b2, 101);
    CanFrame f1[SEG_MAX_FRAGS], f2[SEG_MAX_FRAGS]; size_t n1 = 0, n2 = 0;
    seg_split(0x02, 0xEF, 100, b1, l1, f1, SEG_MAX_FRAGS, &n1);
    seg_split(0x02, 0xEF, 101, b2, l2, f2, SEG_MAX_FRAGS, &n2);

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    /* body 100: deliver frags 0,1,2 then DROP frag 3 (bus glitch), then 4.. */
    seg_reasm_feed(&rr, &f1[0], on_body, NULL);
    seg_reasm_feed(&rr, &f1[1], on_body, NULL);
    seg_reasm_feed(&rr, &f1[2], on_body, NULL);
    /* skip f1[3] */
    seg_reasm_feed(&rr, &f1[4], on_body, NULL); /* idx 4 != expected 3 → abandon */
    CHECK(g_delivered == 0, "lost fragment: the gapped body is NEVER delivered");
    CHECK(rr.rx_frag_drop == 1, "lost fragment: the partial is dropped + counted");

    /* now body 101 arrives whole → re-seeds and delivers cleanly */
    for (size_t i = 0; i < n2; i++) seg_reasm_feed(&rr, &f2[i], on_body, NULL);
    CHECK(g_delivered == 1 && g_body_len == l2 && memcmp(g_body, b2, l2) == 0,
          "the next FIRST re-seeds: body 101 delivers byte-identical after the loss");
  }

  /* --- fail-closed: an orphan non-first fragment never seeds a body --- */
  {
    uint8_t b[SEG_MAX_BODY]; size_t l = make_imu_body(b, 200);
    CanFrame f[SEG_MAX_FRAGS]; size_t n = 0;
    seg_split(0x02, 0xEF, 200, b, l, f, SEG_MAX_FRAGS, &n);

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    /* a mid-stream fragment (not FIRST) arrives with no open buffer */
    seg_reasm_feed(&rr, &f[3], on_body, NULL);
    CHECK(g_delivered == 0, "orphan fragment: nothing delivered");
    CHECK(rr.rx_frag_orphan == 1, "orphan fragment: counted as rx_frag_orphan, not seeding a body");
    /* and a real body afterward still works — the orphan left no residue */
    for (size_t i = 0; i < n; i++) seg_reasm_feed(&rr, &f[i], on_body, NULL);
    CHECK(g_delivered == 1 && memcmp(g_body, b, l) == 0,
          "orphan fragment left no residue: a real body still reassembles");
  }

  /* --- fail-closed: a reordered fragment abandons the partial --- */
  {
    uint8_t b[SEG_MAX_BODY]; size_t l = make_imu_body(b, 201);
    CanFrame f[SEG_MAX_FRAGS]; size_t n = 0;
    seg_split(0x02, 0xEF, 201, b, l, f, SEG_MAX_FRAGS, &n);

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    seg_reasm_feed(&rr, &f[0], on_body, NULL);
    seg_reasm_feed(&rr, &f[2], on_body, NULL); /* out of order: expected 1, got 2 */
    CHECK(g_delivered == 0 && rr.rx_frag_drop == 1,
          "reorder: out-of-order fragment abandons the partial, drops + counts");
  }

  /* --- fail-closed: a bit-flip in a fragment fails the end-to-end CRC --- */
  {
    uint8_t b[SEG_MAX_BODY]; size_t l = make_imu_body(b, 202);
    CanFrame f[SEG_MAX_FRAGS]; size_t n = 0;
    seg_split(0x02, 0xEF, 202, b, l, f, SEG_MAX_FRAGS, &n);
    f[3].data[1] ^= 0x40; /* corrupt a payload byte mid-body (a re-frame bit-flip) */

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    for (size_t i = 0; i < n; i++) seg_reasm_feed(&rr, &f[i], on_body, NULL);
    CHECK(g_delivered == 0, "CRC corruption: a corrupted body is NEVER delivered");
    CHECK(rr.rx_crc_fail == 1, "CRC corruption: counted as rx_crc_fail (caught after reassembly)");
  }

  /* --- fail-closed: a fragment from a different body (seqlo alias) is rejected --- */
  {
    /* body N=32 (seqlo 0) and body N+32=64 (seqlo 0 again — same 5-bit seqlo!)
     * must NOT be confused; but the canonical alias guard is two CONSECUTIVE
     * bodies with DIFFERENT seqlo: a stale frag from body A splicing into body B. */
    uint8_t bA[SEG_MAX_BODY]; size_t lA = make_imu_body(bA, 10); /* seqlo 10 */
    uint8_t bB[SEG_MAX_BODY]; size_t lB = make_imu_body(bB, 11); /* seqlo 11 */
    CanFrame fA[SEG_MAX_FRAGS], fB[SEG_MAX_FRAGS]; size_t nA = 0, nB = 0;
    seg_split(0x02, 0xEF, 10, bA, lA, fA, SEG_MAX_FRAGS, &nA);
    seg_split(0x02, 0xEF, 11, bB, lB, fB, SEG_MAX_FRAGS, &nB);

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    /* open body B with its FIRST, then feed a leftover frag from body A at the
     * next expected index — same index, wrong seqlo → must be rejected */
    seg_reasm_feed(&rr, &fB[0], on_body, NULL);
    seg_reasm_feed(&rr, &fA[1], on_body, NULL); /* idx 1 ok, but seqlo 10 != 11 */
    CHECK(g_delivered == 0 && rr.rx_frag_drop == 1,
          "seqlo alias: a fragment from a different body is rejected, not spliced");
  }

  /* --- the 512-byte ceiling: the boundary fits, one byte over is refused --- */
  {
    uint8_t big[SEG_MAX_BODY + 4];
    for (size_t i = 0; i < sizeof(big); i++) big[i] = (uint8_t)i;
    CanFrame f[SEG_MAX_FRAGS]; size_t n = 0;

    /* body 510 + 2 CRC = 512 = exactly 64 fragments → fits */
    bool ok510 = seg_split(0x02, 0xEF, 1, big, 510, f, SEG_MAX_FRAGS, &n);
    CHECK(ok510 && n == 64, "ceiling: a 510-byte body (→512 with CRC) fits in exactly 64 fragments");
    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    for (size_t i = 0; i < n; i++) seg_reasm_feed(&rr, &f[i], on_body, NULL);
    CHECK(g_delivered == 1 && g_body_len == 510 && memcmp(g_body, big, 510) == 0,
          "ceiling: the 510-byte body reassembles byte-identical");

    /* body 511 + 2 CRC = 513 > 512 → refused (tx_oversize), never truncated */
    n = 999;
    bool ok511 = seg_split(0x02, 0xEF, 1, big, 511, f, SEG_MAX_FRAGS, &n);
    CHECK(!ok511 && n == 0, "ceiling: a 511-byte body is REFUSED (over 512), not truncated");
  }

  /* --- two (node,port) streams reassemble independently (per-key slots) ---
   * A branch hub relays many nodes; their fragments may interleave on the bus.
   * Each (node,port) has its own buffer, so interleaving must not corrupt either. */
  {
    uint8_t ba[SEG_MAX_BODY]; size_t la = make_imu_body(ba, 300); ba[0] = 0x05;
    uint8_t bb[SEG_MAX_BODY]; size_t lb = make_imu_body(bb, 301); bb[0] = 0x06;
    CanFrame fa[SEG_MAX_FRAGS], fb[SEG_MAX_FRAGS]; size_t na = 0, nb = 0;
    seg_split(0x05, 0xEF, 300, ba, la, fa, SEG_MAX_FRAGS, &na);
    seg_split(0x06, 0xEF, 301, bb, lb, fb, SEG_MAX_FRAGS, &nb);
    CHECK(na == nb, "both interleaved bodies have the same fragment count");

    SegReasm rr; seg_reasm_init(&rr);
    int delivered_a = 0, delivered_b = 0;
    /* interleave the two streams fragment-by-fragment */
    for (size_t i = 0; i < na; i++) {
      reset_capture();
      seg_reasm_feed(&rr, &fa[i], on_body, NULL);
      if (g_delivered) { delivered_a += (g_body_len == la && memcmp(g_body, ba, la) == 0); }
      reset_capture();
      seg_reasm_feed(&rr, &fb[i], on_body, NULL);
      if (g_delivered) { delivered_b += (g_body_len == lb && memcmp(g_body, bb, lb) == 0); }
    }
    CHECK(delivered_a == 1 && delivered_b == 1,
          "interleaved streams: both (node,port) bodies reassemble independently, byte-identical");
  }

  /* --- structural reclaim: a new FIRST mid-stream re-seeds (the no-timeout rule) ---
   * The "no reassembly timeout in v1" decision rests on this: a stalled partial is
   * reclaimed by the next FIRST for that key, not by a wall clock. */
  {
    uint8_t bA[SEG_MAX_BODY]; size_t lA = make_imu_body(bA, 400);
    uint8_t bB[SEG_MAX_BODY]; size_t lB = make_imu_body(bB, 401);
    CanFrame fA[SEG_MAX_FRAGS], fB[SEG_MAX_FRAGS]; size_t nA = 0, nB = 0;
    seg_split(0x02, 0xEF, 400, bA, lA, fA, SEG_MAX_FRAGS, &nA);
    seg_split(0x02, 0xEF, 401, bB, lB, fB, SEG_MAX_FRAGS, &nB);

    SegReasm rr; seg_reasm_init(&rr); reset_capture();
    /* open body A and feed a few frags, then ABANDON it by sending body B's FIRST
     * (e.g. body A's tail was lost on the bus and never arrived) */
    seg_reasm_feed(&rr, &fA[0], on_body, NULL);
    seg_reasm_feed(&rr, &fA[1], on_body, NULL);
    seg_reasm_feed(&rr, &fA[2], on_body, NULL);
    /* body B's FIRST re-seeds the same (node,port) slot — no timer needed */
    for (size_t i = 0; i < nB; i++) seg_reasm_feed(&rr, &fB[i], on_body, NULL);
    CHECK(g_delivered == 1 && g_body_len == lB && memcmp(g_body, bB, lB) == 0,
          "structural reclaim: a mid-stream FIRST re-seeds; body B delivers, A's partial discarded");
    CHECK(rr.rx_crc_fail == 0, "structural reclaim: no false CRC failure from spliced bytes");
  }

  if (g_fail == 0) {
    printf("\nALL C SEGMENT CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C SEGMENT CHECK(S) FAILED\n", g_fail);
  return 1;
}
