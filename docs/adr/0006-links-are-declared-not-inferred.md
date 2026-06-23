# Topology is declared by parent links, not inferred from node ids; a link is a first-class edge

A robot's tree is authored by each hub **declaring its parent and the transport of
the link up to that parent** — `parent: :blaster, uplink: :uart` — with the root
hub declaring `parent: :host` (the host link is always UART). A **link** (the edge
between a hub and its parent) is a **first-class entity**: it has a transport and a
peripheral, and the generated route table maps each downstream **node** to the
**specific link** that reaches it. The **verifier** checks the tree is well-formed
(exactly one root, every `parent:` resolves, no cycles, fully connected). Nothing
about the topology is inferred from node-id ordering anymore.

This is recorded because it replaces three **silent, inferred** topology facts with
**declared, verified** ones, changes the generated router from a 3-way classification
to a per-link table, and is hard to reverse once robots and firmware are authored
against the parent/link DSL.

## The problem

v1 has **no explicit topology**. The tree, the root, and the backplane transport
were all reverse-engineered at generate time:

- **Root-ness was `Enum.min(node_id)`** (`wire_gen.ex:828`). The hub that owns the
  host UART — a load-bearing identity (it bridges UART up to CAN/UART down) — was
  inferred as "the lowest node id." Assign the host-connected hub a higher id than a
  leaf and the generator silently makes the **leaf** the root: the leaf fills
  `route_table[*] = LINK_LOCAL`, forwards nothing, and the host is cut off — with no
  compile error.
- **Backplane transport was a robot-wide flag**, "`UART` iff any non-root hub is
  reached over `:uart`" (`wire_gen.ex:1072`). The per-hub `transport:` field _looked_
  per-hub but collapsed to one boolean, on the baked-in assumption (stated in the
  generator's own comment) that **the backplane is uniform per robot**. Declare two
  different transports and one silently wins; the field misleads.
- **Parent/child structure was implicit** — there was no way to say "this hub hangs
  off that hub." A leaf two hops down, a branch that bridges, a parent with several
  downstream links: none were expressible. The route table was "everything that isn't
  me is `DOWN`" (root) or "everything is `LOCAL`" (leaf) — a single-backplane, single-
  hop shape.

The verifier caught none of these: it validated **wire framing** (node uniqueness,
ids, frame size) but not **topology**. The tree's shape was an accident of how the
user numbered nodes.

## The decision

**A link is the edge between two hubs, and it is a first-class thing.** Transport is
a property of a _link_, not a hub or a robot — which is the real hardware truth: the
host talks UART to the first hub, and that hub may reach its children over a shared
CAN bus, a point-to-point UART, several UARTs, or a mix. A hub does not "have a
transport"; it sits at the end of a link that does.

- **Declaration — each hub names its parent + its uplink transport.**
  `hub(:wheels, MyApp.Wheels, node: 0x05, parent: :blaster, uplink: :uart)`. The
  **root** declares `parent: :host`; its uplink is the host UART (fixed, not a
  choice). The tree falls out of the parent pointers — no separate `links do` block;
  a link _is_ a parent edge.
- **Links are derived, first-class entities.** Each `parent → child` edge is a link
  with a transport. Children that share a parent **and** a CAN uplink share **one
  bus**; a UART uplink is a point-to-point link. A parent may own **any mix** — a CAN
  bus _and_ several UART links — because a link is just a typed edge the parent
  multiplexes. There is **no sibling-consistency constraint**: heterogeneous
  downlinks under one parent are valid (the earlier "all-CAN-or-one-UART" idea was an
  artifact of the wrong, per-hub transport model and is dropped).
- **Routing — the route table maps `node → link`.** The generator replaces the 3-way
  `LINK_UP | LINK_DOWN | LINK_LOCAL` fill with a per-node lookup of the **specific
  link** that reaches that node (the parent link toward an ancestor, the correct
  child link toward a descendant, local for self). The host link is link 0. This is
  what lets a parent route to the right one of several downlinks, and what makes
  multi-hop trees work.
- **Verifier — the tree is well-formed.** Exactly one hub declares `parent: :host`
  (one root); every `parent:` names a declared hub; no cycles; every hub is reachable
  from the root (connected). A violation refuses to compile, naming the offending
  hub — the topology bug cannot ship, the same standard the wire-framing checks
  already meet.

The net: who owns the host link, what each backplane is, and how the tree is shaped
all become things the user **states** and the verifier **checks**, rendered into the
router from one authored model — not inferred from id arithmetic.

## Considered options

- **Keep `Enum.min` root + uniform backplane, just add a verifier check.** Verify
  that the host-connected hub is the lowest id and the backplane is uniform. Cheapest,
  no DSL change — but it keeps a load-bearing identity implicit (a foot-gun made
  louder, not removed), and it permanently forecloses heterogeneous downlinks and
  multi-hop trees. Rejected: it cements the v1 simplification as the model.
- **Transport as a property of the root's single backplane (one per robot).** Declare
  `backplane: :can` once on the root; drop per-hub transport. Matches the generator's
  _current_ assumption and is simpler — but the real hardware isn't uniform: a hub may
  have one UART child and a CAN bus at once. Rejected as too narrow once the hardware
  truth was clear.
- **Per-hub `transport:` but verify uniformity.** Keep the field, reject a
  non-uniform backplane. Rejected: it leaves transport on the wrong entity (the hub,
  not the link) and bans valid heterogeneous configurations.
- **An explicit `links do` block** listing each link as a named entity with
  `from:`/`to:`/`transport:`. More explicit about buses (you see a shared CAN bus as
  one named thing) and the natural home for per-bus config (bitrate, termination) —
  but a second section to keep in sync with the hubs, and the parent-pointer form
  already derives the same links with less ceremony. Folded in as the likely future
  refinement _if_ buses gain their own configuration; the v1 surface is the parent
  pointer.

## Consequences

- **The three inferred topology facts become declared + verified.** Wrong-root,
  contradictory-backplane, and unexpressible-tree-shape all become compile errors or
  simply expressible — no id-ordering accidents.
- **Transport sits where it belongs** (the link), so heterogeneous downlinks (a CAN
  bus + N UARTs under one parent) and genuine multi-hop trees are first-class, not
  worked around.
- **The router generation changes shape** — from `LINK_UP/DOWN/LOCAL` to a
  `node → link` table — touching `wire_gen.ex` (route fill, the dropped `Enum.min`
  root + `backplane_transport_uart` inferences), the C router (`router.{h,c}`,
  multi-link dispatch), `link_esp32.cpp` (per-link peripherals/pins), and the
  per-link `-DROOT_HUB`/transport build flags. The router/relay C harnesses extend to
  multi-link routing.
- **DSL + verifier change**: the `hub` entity gains `parent:` and `uplink:` (and the
  root's `parent: :host`); the verifier gains the tree checks. `dsl.ex` and its IR
  projection carry the parent edges.
- **Migration:** the example (`segby_v1`, root `:blaster` + UART leaf `:wheels`) and
  the fixture robot declare `parent:`/`uplink:` explicitly; the drift test enforces
  regeneration. The existing single-hop trees are a trivial special case of the new
  model.
- **Relationship to the design's invariants:** routing stays a flat
  `route_table[node]` lookup (CONTEXT.md · NODE/PORT) — only its _values_ change from
  a direction to a link id. The **Relay** discipline (in-order FIFO, verbatim `seq`)
  is unchanged; a per-link table just picks which link to pump onto. The **Advance**
  soundness (every path in-order) is preserved per link.
- **Out of scope:** per-bus configuration (CAN bitrate, termination) and a named
  `links do` block remain a future refinement; v1 derives unconfigured links from
  parent edges. Node identity is still trust-on-first-use (the deferred `fw_id`
  check, unchanged).
