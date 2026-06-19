/* Host-compiled test of the router (§04/§08): meaning-blind flat-NODE dispatch,
 * and the relay invariant — a forwarded frame's body (incl. seq/t_dev) is
 * unchanged. Pure logic, no hardware. */
#include "frame.h"
#include "router.h"
#include <stdio.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, msg)                                                       \
  do {                                                                         \
    if (cond) {                                                                \
      printf("  ok   %s\n", msg);                                              \
    } else {                                                                   \
      g_fail++;                                                                \
      printf("  FAIL %s\n", msg);                                              \
    }                                                                          \
  } while (0)

/* capture which sink fired and on what frame */
static int g_local, g_up, g_down;
static Frame g_last;

static void on_local(const Frame *f, void *ctx) {
  (void)ctx;
  g_local++;
  g_last = *f;
}
static void on_up(const Frame *f, void *ctx) {
  (void)ctx;
  g_up++;
  g_last = *f;
}
static void on_down(const Frame *f, void *ctx) {
  (void)ctx;
  g_down++;
  g_last = *f;
}

static void reset(void) { g_local = g_up = g_down = 0; }

static Frame make(uint8_t node, uint8_t port, uint16_t seq, uint64_t t) {
  Frame f;
  memset(&f, 0, sizeof(f));
  f.node = node;
  f.port = port;
  f.seq = seq;
  f.stamped =
      true; /* the router is meaning-blind; it forwards the struct as-is */
  f.t_dev = t;
  f.payload[0] = 0xAB;
  f.payload[1] = 0xCD;
  f.payload_len = 2;
  return f;
}

int main(void) {
  printf("== bb_mcuhub C router harness ==\n");

  /* A branch hub at NODE 0x02 (the root): reaches 0x05 DOWN (CAN), default UP.
   */
  Router r;
  memset(&r, 0, sizeof(r));
  r.my_node = 0x02;
  for (int i = 0; i < 256; i++)
    r.route_table[i] = LINK_UP;
  r.route_table[0x02] = LINK_LOCAL;
  r.route_table[0x05] = LINK_DOWN;

  RouterSinks sinks = {on_local, on_up, on_down, NULL};

  /* a frame addressed to THIS hub → delivered locally */
  reset();
  Frame f_local = make(0x02, 0x10, 7, 1234);
  router_route(&r, &f_local, &sinks);
  CHECK(g_local == 1 && g_up == 0 && g_down == 0,
        "frame for my_node → deliver_local");

  /* a frame for a child node → forwarded DOWN, body verbatim */
  reset();
  Frame f_child = make(0x05, 0x28, 99, 555000);
  router_route(&r, &f_child, &sinks);
  CHECK(g_down == 1 && g_local == 0 && g_up == 0,
        "frame for a child node → forward_down");
  CHECK(g_last.node == 0x05 && g_last.port == 0x28 && g_last.seq == 99 &&
            g_last.t_dev == 555000,
        "forwarded frame: seq/t_dev/node/port VERBATIM (relay invariant §04)");
  CHECK(g_last.payload_len == 2 && g_last.payload[0] == 0xAB &&
            g_last.payload[1] == 0xCD,
        "forwarded frame: payload unchanged");

  /* a frame for an unknown node (host-bound by default) → UP */
  reset();
  Frame f_up = make(0x09, 0x11, 1, 1);
  router_route(&r, &f_up, &sinks);
  CHECK(g_up == 1 && g_local == 0 && g_down == 0,
        "frame for a non-child node → forward_up");

  /* a leaf hub: everything is local, nothing forwards */
  Router leaf;
  memset(&leaf, 0, sizeof(leaf));
  leaf.my_node = 0x05;
  for (int i = 0; i < 256; i++)
    leaf.route_table[i] = LINK_LOCAL;
  RouterSinks leaf_sinks = {on_local, on_up, on_down, NULL};

  reset();
  Frame f_leaf = make(0x05, 0x28, 3, 9);
  router_route(&leaf, &f_leaf, &leaf_sinks);
  CHECK(g_local == 1 && g_up == 0 && g_down == 0,
        "leaf: a command for it is delivered local");

  if (g_fail == 0) {
    printf("\nALL C ROUTER CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C ROUTER CHECK(S) FAILED\n", g_fail);
  return 1;
}
