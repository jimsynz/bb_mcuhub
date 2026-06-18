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

/* The generated 29-bit id: [NODE:8][PORT:8][rsv:13] (§03). */
static inline uint32_t can_id_of(const Frame *f) {
  return ((uint32_t)f->node << 21) | ((uint32_t)f->port << 13);
}

/* Callback the runtime sets: a verified body arrived from some link. */
static void (*g_on_body)(const uint8_t *body, size_t len) = nullptr;

/* Legible failure counters (§03): a frame too large for classic CAN is refused,
 * not truncated. Exposed for telemetry / a future status port. */
static uint32_t g_tx_oversize_drop = 0;
uint32_t link_tx_oversize_drops(void) { return g_tx_oversize_drop; }

#if defined(ROOT_HUB)
static TransportDecoder g_uart_rx; /* the UART seam — only the root hub has one */

static void uart_body_cb(const uint8_t *body, size_t len, void *) {
  if (g_on_body) g_on_body(body, len);
}
#endif

void link_set_on_body(void (*cb)(const uint8_t *body, size_t len)) { g_on_body = cb; }

void link_begin(void) {
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
  /* The design (§03) carries the whole body in ONE CAN-FD frame (≤64 B). ESP32's
   * built-in TWAI peripheral is CLASSIC CAN (8-byte data field) only, so a body
   * larger than 8 bytes CANNOT ride one frame here. v1 does NOT segment (SAFeD),
   * so we REFUSE and COUNT an oversized frame rather than silently truncating it
   * — a dropped frame is legible; a truncated one is silent corruption that would
   * poison decode/freshness (§04). A CAN-FD transceiver + segmentation lifts this;
   * until then a >8B port (e.g. the full IMU) must ride the UART hop or be split.
   *
   * NOTE: inbound reassembly of multi-frame bodies is likewise unbuilt — the CAN
   * RX path below only handles a body that fit one frame. */
  if (body_len > 8) {
    g_tx_oversize_drop++; /* legible: a frame too big for classic CAN was refused */
    return;
  }
  twai_message_t m = {};
  m.identifier = can_id_of(f);
  m.extd = 1;
  m.data_length_code = (uint8_t)body_len;
  for (size_t i = 0; i < body_len; i++) m.data[i] = body[i];
  twai_transmit(&m, pdMS_TO_TICKS(1));
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
  twai_message_t m;
  while (twai_receive(&m, 0) == ESP_OK) {
    if (g_on_body) g_on_body(m.data, m.data_length_code);
  }
}

#endif /* ARDUINO */
