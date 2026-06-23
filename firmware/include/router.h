/* Meaning-blind flat-NODE routing (§03/§04/§08, ADR-0006).
 *
 * NODE is a whole-tree-unique id, never a path. A hub forwards a frame onto the
 * LOCAL LINK that reaches the dest node — a child link is NOT a port. Topology
 * is DECLARED, not inferred: the generated route table maps each NODE to a
 * specific per-hub-local LINK INDEX (link 0 is always the up-link toward the
 * parent/host; downlinks are 1..N). A shared CAN bus is ONE link; each
 * point-to-point UART child its own link. The router does NOT decode the
 * payload and does NOT touch seq/t_dev.
 *
 * Forwarding is strict FIFO, in arrival order, re-framing for the destination
 * link's transport and re-CRCing the SAME body — never reorder/hold/dedup. That
 * in-order guarantee is what makes the floor's seq!=last_seq test sound (§04).
 */
#ifndef BB_MCUHUB_ROUTER_H
#define BB_MCUHUB_ROUTER_H

#include "frame.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The route-table sentinel for "this node is local to me" — delivered to a port
 * on THIS hub, never sent on a link. A real link index is 0..N (0 = up-link).
 */
#define LINK_LOCAL_IDX 0xFF

/* A hub's view of the tree: which LOCAL LINK INDEX reaches each NODE. Generated
 * from the DECLARED topology (ADR-0006). Link 0 is the up-link (toward the
 * parent/host); downlinks are 1..N. MY_NODE → LINK_LOCAL_IDX; an ancestor or an
 * unknown node → 0 (the up-link); a descendant via downlink k → k. */
typedef struct {
  uint8_t my_node;
  /* route_table[node] → a LOCAL LINK INDEX, or LINK_LOCAL_IDX for self/local */
  uint8_t route_table[256];
} Router;

/* Callbacks the firmware supplies to actually move bytes on each link. The link
 * index is per-hub-local (0 = up-link); send_on_link maps it to that hub's
 * peripheral. A board realizes the links it physically has and stubs the rest
 * (ADR-0006). */
typedef struct {
  void (*deliver_local)(const Frame *f,
                        void *ctx); /* an endpoint port on THIS hub */
  void (*send_on_link)(uint8_t link, const Frame *f,
                       void *ctx); /* a local link index → bytes on that link */
  void *ctx;
} RouterSinks;

/* Route one frame by its NODE, in order, meaning-blind. seq/t_dev untouched. */
void router_route(const Router *r, const Frame *f, const RouterSinks *sinks);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_ROUTER_H */
