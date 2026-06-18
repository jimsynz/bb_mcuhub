/* Meaning-blind flat-NODE routing (§03/§04/§08).
 *
 * NODE is a whole-tree-unique id, never a path. A branch hub forwards a frame
 * toward the local link that reaches the dest node — a child link is NOT a port.
 * The router does NOT decode the payload and does NOT touch seq/t_dev. On the
 * root hub, UP is UART (to the host) and DOWN is CAN; deeper, both are CAN.
 *
 * Forwarding is strict FIFO, in arrival order, re-framing for the destination
 * transport and re-CRCing the SAME body — never reorder/hold/dedup. That
 * in-order guarantee is what makes the floor's seq!=last_seq test sound (§04). */
#ifndef BB_MCUHUB_ROUTER_H
#define BB_MCUHUB_ROUTER_H

#include <stdint.h>
#include "frame.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { LINK_NONE = 0, LINK_LOCAL, LINK_UP, LINK_DOWN } LinkDir;

/* A hub's view of the tree: which local link reaches each NODE. Generated from
 * the topology; for a leaf, only MY_NODE is LINK_LOCAL and everything else is
 * LINK_UP (toward the parent/host). */
typedef struct {
  uint8_t my_node;
  /* route_table[node] → LinkDir; index by the frame's NODE */
  LinkDir route_table[256];
} Router;

/* Callbacks the firmware supplies to actually move bytes on each link. */
typedef struct {
  void (*deliver_local)(const Frame *f, void *ctx); /* an endpoint port on THIS hub */
  void (*forward_up)(const Frame *f, void *ctx);     /* toward parent/host */
  void (*forward_down)(const Frame *f, void *ctx);   /* toward a child link */
  void *ctx;
} RouterSinks;

/* Route one frame by its NODE, in order, meaning-blind. seq/t_dev untouched. */
void router_route(const Router *r, const Frame *f, const RouterSinks *sinks);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_ROUTER_H */
