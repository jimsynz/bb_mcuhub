#include "router.h"

void router_route(const Router *r, const Frame *f, const RouterSinks *sinks) {
  if (f->node == r->my_node) {
    if (sinks->deliver_local)
      sinks->deliver_local(f, sinks->ctx);
    return;
  }

  switch (r->route_table[f->node]) {
  case LINK_UP:
    if (sinks->forward_up)
      sinks->forward_up(f, sinks->ctx);
    break;
  case LINK_DOWN:
    if (sinks->forward_down)
      sinks->forward_down(f, sinks->ctx);
    break;
  case LINK_LOCAL:
    if (sinks->deliver_local)
      sinks->deliver_local(f, sinks->ctx);
    break;
  case LINK_NONE:
  default:
    /* unknown node → drop (meaning-blind; no peer-name dispatch) */
    break;
  }
}
