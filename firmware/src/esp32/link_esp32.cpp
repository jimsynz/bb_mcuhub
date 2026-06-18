/* ESP32 link layer (§03): UART (host↔root hub) and CAN/TWAI (backplane), both
 * carrying the SAME COBS+CRC frame. Mirrors the reference climber transport
 * (CanLink via TWAI, SerialNodeLink via UART) but conforms to the new design:
 * one frame, big-endian body, end-to-end CRC across the re-framing boundary, and
 * a 29-bit CAN id [NODE:8][PORT:8][rsv:13] generated from the contract.
 *
 * Build-time role:
 *   -DROOT_HUB  → UP is UART to the host, DOWN is CAN to children
 *   (default)   → UP is CAN to the parent, no DOWN link (a leaf)
 *
 * This file only compiles under the Arduino/ESP32 framework (PlatformIO). The
 * pure codec it rides on (frame/transport/crc16/cobs) is the same host-tested C. */
#if defined(ARDUINO)

#include <Arduino.h>
#include "driver/twai.h"
extern "C" {
#include "frame.h"
#include "transport.h"
#include "segment.h"
#include "link.h"
}

#ifndef HOST_UART_BAUD
#define HOST_UART_BAUD 1000000
#endif
#ifndef CAN_BITRATE
#define CAN_BITRATE 1000000
#endif
#ifndef CAN_TX_PIN
#define CAN_TX_PIN 16
#endif
#ifndef CAN_RX_PIN
#define CAN_RX_PIN 17
#endif

/* Callback the runtime sets: a verified body arrived from some link. */
static void (*g_on_body)(const uint8_t *body, size_t len) = nullptr;

/* The CAN backplane is segmented (§03): a wide body splits across CAN frames on
 * TX and is reassembled, CRC-checked, in order on RX. The fragment metadata rides
 * the 13 reserved id bits; the data field stays 100% body bytes. */
static SegReasm g_can_rx;

/* Legible failure counters (§03), exposed for telemetry / a future status port:
 *  - tx_oversize: a body over the 512-byte ceiling — refused, never truncated
 *    (a should-never-happen belt to the §06 boot size-check), or a TWAI TX that
 *    failed mid-body so the body is abandoned (the RX side drops the partial).
 *  - rx_*: the CAN seam's analog of the UART seam's rx_drop. */
static uint32_t g_tx_oversize_drop = 0;
uint32_t link_tx_oversize_drops(void) { return g_tx_oversize_drop; }
uint32_t link_rx_frag_orphan(void) { return g_can_rx.rx_frag_orphan; }
uint32_t link_rx_frag_drop(void) { return g_can_rx.rx_frag_drop; }
uint32_t link_rx_crc_fail(void) { return g_can_rx.rx_crc_fail; }

/* Reassembler → runtime: a complete, CRC-clean CAN body (CRC already stripped). */
static void can_body_cb(const uint8_t *body, size_t len, void *) {
  if (g_on_body) g_on_body(body, len);
}

#if defined(ROOT_HUB)
static TransportDecoder g_uart_rx; /* the UART seam — only the root hub has one */

static void uart_body_cb(const uint8_t *body, size_t len, void *) {
  if (g_on_body) g_on_body(body, len);
}
#endif

void link_set_on_body(void (*cb)(const uint8_t *body, size_t len)) { g_on_body = cb; }

void link_begin(void) {
  seg_reasm_init(&g_can_rx); /* the CAN backplane reassembler (every role has CAN) */
#if defined(ROOT_HUB)
  transport_decoder_init(&g_uart_rx);

  /* UART to the host */
  Serial.begin(HOST_UART_BAUD);

  /* CAN/TWAI to children */
  twai_general_config_t g =
      TWAI_GENERAL_CONFIG_DEFAULT((gpio_num_t)CAN_TX_PIN, (gpio_num_t)CAN_RX_PIN, TWAI_MODE_NORMAL);
  twai_timing_config_t t = TWAI_TIMING_CONFIG_1MBITS();
  twai_filter_config_t fcfg = TWAI_FILTER_CONFIG_ACCEPT_ALL();
  twai_driver_install(&g, &t, &fcfg);
  twai_start();
#else
  /* a leaf: CAN to the parent only */
  twai_general_config_t g =
      TWAI_GENERAL_CONFIG_DEFAULT((gpio_num_t)CAN_TX_PIN, (gpio_num_t)CAN_RX_PIN, TWAI_MODE_NORMAL);
  twai_timing_config_t t = TWAI_TIMING_CONFIG_1MBITS();
  twai_filter_config_t fcfg = TWAI_FILTER_CONFIG_ACCEPT_ALL();
  twai_driver_install(&g, &t, &fcfg);
  twai_start();
#endif
}

/* Send a frame UP (toward parent/host). On the root hub that is the UART;
 * deeper, it is CAN. The body is identical; only the transport differs. */
void link_send_up(const Frame *f) {
  uint8_t body[FRAME_MAX_BODY];
  size_t body_len = frame_encode_body(f, body, sizeof(body));
  if (body_len == 0) return;

#if defined(ROOT_HUB)
  uint8_t wire[FRAME_MAX_WIRE];
  size_t w = transport_encode(body, body_len, wire, sizeof(wire));
  Serial.write(wire, w);
#else
  /* The CAN backplane is segmented (§03): split body || CRC into ordered frames,
   * fragment metadata in the 13 reserved id bits. ESP32's built-in TWAI is classic
   * CAN (8-byte data field), so even a small body fragments (an 8-byte body → 10
   * with CRC → 2 frames); a CAN-FD board would carry up to 512 B with fewer frames.
   * The whole body crosses byte-identical — never truncated. */
  CanFrame frags[SEG_MAX_FRAGS];
  size_t n_frags = 0;
  if (!seg_split(f->node, f->port, f->seq, body, body_len, frags, SEG_MAX_FRAGS, &n_frags)) {
    g_tx_oversize_drop++; /* over the 512-byte ceiling — the §06 size-check should forbid this */
    return;
  }
  /* Emit all fragments of this body back-to-back, in index order, before
   * returning — strict per-(node,port) FIFO (§04). If a transmit fails mid-body,
   * abandon it: the receiver's FIRST-seeded reassembler drops the now-incomplete
   * body cleanly, exactly as a bus loss would (count it as oversize/abandoned). */
  for (size_t i = 0; i < n_frags; i++) {
    twai_message_t m = {};
    m.identifier = frags[i].id;
    m.extd = 1;
    m.data_length_code = frags[i].len;
    for (size_t j = 0; j < frags[i].len; j++) m.data[j] = frags[i].data[j];
    if (twai_transmit(&m, pdMS_TO_TICKS(1)) != ESP_OK) {
      g_tx_oversize_drop++; /* abandoned mid-body — receiver drops the partial */
      return;
    }
  }
#endif
}

/* Pump inbound bytes/frames toward g_on_body. Call every loop. */
void link_pump(void) {
#if defined(ROOT_HUB)
  while (Serial.available() > 0) {
    uint8_t b = (uint8_t)Serial.read();
    transport_decoder_feed(&g_uart_rx, &b, 1, uart_body_cb, nullptr);
  }
#endif
  /* CAN: feed each frame into the reassembler. It calls g_on_body only with a
   * complete, CRC-clean, in-order body (CRC stripped) — a gap/reorder/orphan/CRC
   * failure is dropped and counted, never delivered partial (§03/§04). */
  twai_message_t m;
  while (twai_receive(&m, 0) == ESP_OK) {
    CanFrame cf;
    cf.id = m.identifier;
    cf.len = m.data_length_code > SEG_CAN_DATA ? SEG_CAN_DATA : m.data_length_code;
    for (size_t i = 0; i < cf.len; i++) cf.data[i] = m.data[i];
    seg_reasm_feed(&g_can_rx, &cf, can_body_cb, nullptr);
  }
}

#endif /* ARDUINO */
