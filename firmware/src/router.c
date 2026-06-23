#include "router.h"

void router_route(const Router *r, const Frame *f, const RouterSinks *sinks) {
  if (f->node == r->my_node) {
    if (sinks->deliver_local)
      sinks->deliver_local(f, sinks->ctx);
    return;
  }

  uint8_t link = r->route_table[f->node];

  if (link == LINK_LOCAL_IDX) {
    /* a node mapped local (e.g. a multi-port hub addressing itself) */
    if (sinks->deliver_local)
      sinks->deliver_local(f, sinks->ctx);
    return;
  }

  /* meaning-blind: forward verbatim onto the local link that reaches this node
   * (link 0 = up-link toward the parent/host; downlinks 1..N). seq/t_dev are
   * never touched. An unrealized link is a no-op stub on the board (ADR-0006).
   */
  if (sinks->send_on_link)
    sinks->send_on_link(link, f, sinks->ctx);
}
