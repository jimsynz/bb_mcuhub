/* Host-compiled test of the router (§04/§08, ADR-0006): meaning-blind flat-NODE
 * dispatch onto a per-hub-local LINK INDEX, and the relay invariant — a
 * forwarded frame's body (incl. seq/t_dev) is unchanged. Topology is DECLARED:
 * the route table maps each NODE to the specific local link that reaches it
 * (link 0 = up-link; downlinks 1..N). Pure logic, no hardware. */
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

/* capture which sink fired, on what link, and on what frame */
static int g_local, g_sent;
static uint8_t g_last_link;
static Frame g_last;

static void on_local(const Frame *f, void *ctx) {
  (void)ctx;
  g_local++;
  g_last = *f;
}
static void on_send(uint8_t link, const Frame *f, void *ctx) {
  (void)ctx;
  g_sent++;
  g_last_link = link;
  g_last = *f;
}

static void reset(void) {
  g_local = g_sent = 0;
  g_last_link = 0xEE;
}

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

  /* A root hub at NODE 0x02: link 0 = up (host), link 1 = down to the child
   * 0x05. MY_NODE → LINK_LOCAL_IDX; everything else defaults to 0 (up). */
  Router r;
  memset(&r, 0, sizeof(r));
  r.my_node = 0x02;
  for (int i = 0; i < 256; i++)
    r.route_table[i] = 0; /* default: link 0, the up-link toward host */
  r.route_table[0x02] = LINK_LOCAL_IDX;
  r.route_table[0x05] = 1; /* the child hub reached over downlink 1 */

  RouterSinks sinks = {on_local, on_send, NULL};

  /* a frame addressed to THIS hub → delivered locally */
  reset();
  Frame f_local = make(0x02, 0x10, 7, 1234);
  router_route(&r, &f_local, &sinks);
  CHECK(g_local == 1 && g_sent == 0, "frame for my_node → deliver_local");

  /* a frame for a child node → forwarded on the child's downlink, body verbatim
   */
  reset();
  Frame f_child = make(0x05, 0x28, 99, 555000);
  router_route(&r, &f_child, &sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 1,
        "frame for a child node → send_on_link(1) (its downlink)");
  CHECK(g_last.node == 0x05 && g_last.port == 0x28 && g_last.seq == 99 &&
            g_last.t_dev == 555000,
        "forwarded frame: seq/t_dev/node/port VERBATIM (relay invariant §04)");
  CHECK(g_last.payload_len == 2 && g_last.payload[0] == 0xAB &&
            g_last.payload[1] == 0xCD,
        "forwarded frame: payload unchanged");

  /* a frame for an unknown node (host-bound by default) → up-link, link 0 */
  reset();
  Frame f_up = make(0x09, 0x11, 1, 1);
  router_route(&r, &f_up, &sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 0,
        "frame for a non-child node → send_on_link(0) (the up-link)");

  /* a leaf hub: everything but self is the up-link (link 0); self is local. */
  Router leaf;
  memset(&leaf, 0, sizeof(leaf));
  leaf.my_node = 0x05;
  for (int i = 0; i < 256; i++)
    leaf.route_table[i] = 0; /* default: link 0, up toward the parent */
  leaf.route_table[0x05] = LINK_LOCAL_IDX;
  RouterSinks leaf_sinks = {on_local, on_send, NULL};

  reset();
  Frame f_leaf = make(0x05, 0x28, 3, 9);
  router_route(&leaf, &f_leaf, &leaf_sinks);
  CHECK(g_local == 1 && g_sent == 0,
        "leaf: a command for it is delivered local");

  reset();
  Frame f_leaf_up = make(0x02, 0x10, 4, 9);
  router_route(&leaf, &f_leaf_up, &leaf_sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 0,
        "leaf: a frame for another node goes up (link 0)");

  /* NEW (ADR-0006): a branch with TWO downlinks — link 1 reaches node 0x03,
   * link 2 reaches node 0x05. This proves generic node→link routing: each
   * descendant routes to the CORRECT link index, not a single shared "down". */
  Router branch;
  memset(&branch, 0, sizeof(branch));
  branch.my_node = 0x02;
  for (int i = 0; i < 256; i++)
    branch.route_table[i] = 0; /* default: up-link */
  branch.route_table[0x02] = LINK_LOCAL_IDX;
  branch.route_table[0x03] = 1; /* downlink 1 */
  branch.route_table[0x05] = 2; /* downlink 2 */
  RouterSinks branch_sinks = {on_local, on_send, NULL};

  reset();
  Frame f_d1 = make(0x03, 0x20, 11, 100);
  router_route(&branch, &f_d1, &branch_sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 1,
        "multi-downlink: node 0x03 → send_on_link(1)");

  reset();
  Frame f_d2 = make(0x05, 0x21, 12, 200);
  router_route(&branch, &f_d2, &branch_sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 2,
        "multi-downlink: node 0x05 → send_on_link(2) (a DIFFERENT link)");

  reset();
  Frame f_dx = make(0x09, 0x22, 13, 300);
  router_route(&branch, &f_dx, &branch_sinks);
  CHECK(g_sent == 1 && g_local == 0 && g_last_link == 0,
        "multi-downlink: an unknown node still goes up (link 0)");

  if (g_fail == 0) {
    printf("\nALL C ROUTER CHECKS PASSED\n");
    return 0;
  }
  printf("\n%d C ROUTER CHECK(S) FAILED\n", g_fail);
  return 1;
}
