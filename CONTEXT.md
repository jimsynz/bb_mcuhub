# Context — the cog framework

A glossary of the load-bearing terms in the cog framework and its BeamBots (`bb`)
integration. Definitions only — no implementation details. See `docs/design.html` for the
architecture, `docs/reviews/` for decisions and prototype findings.

## Terms

### Cog
The reusable software unit an author writes: a pure core (a `cook`, a `step`, or a `floor`)
plus a **contract**. A cog is not a process and not a node; it is placed onto a node and
surfaced to BeamBots as one or more components. See **Contract**, **Node**.

### Contract
The data a cog ships describing itself: what slots it `consumes`/`produces` (typed), its
`rate` as a *range* (a limit, not a fixed number), its pure core, its `safe_action`,
`arm_gate`, `on_stale`, and `tunable` bounds. The bot manifest **picks** values inside a
contract; construction **validates** every pick. The contract is a cog's public face.

### Slot
A named place holding exactly one value plus two stamps: `seq` (a per-write counter, +1
every write) and `t_dev` (the producer's own 64-bit monotonic time at the write). Reads
never block and return the latest. Exactly one writer per slot. Freshness is "did `seq`
advance within the reader's window, on the reader's own clock" — never a cross-board clock
comparison.

### Node
A physical board hosting one or more cogs. May run the BEAM (the **Master**) or not (an
ESP32 running C, reached over a bus we define). Distinct from a cog.

### Master
The single node running the BEAM. Hosts the slot space and the BeamBots application. It is
irreducibly distinguished: the one node with no parent link.

### The floor (dead-man)
The authoritative safe-state mechanism. Lives on an actuator's **own chip**, drives the
plant to its `safe_action` when a command's `seq` stops advancing (goes stale). Fires even
if the Master is entirely gone. It is the guarantee; everything BEAM-side is best-effort or
observability on top of it.

### LinkOwner
The OTP process that owns one physical bus (UART / I²C / CAN) to a non-BEAM node. It is
**our** supervised process, living *beside* BeamBots' topology supervision tree, not inside
it (so it survives a BeamBots topology force-disarm). It fills inbound slots from decoded
frames and drains outbound commands to the wire. The BeamBots components for a node are thin
**views** onto the slots the LinkOwner mediates — they do not own the bus. One LinkOwner per
physical bus; the N cogs on a node share it.

### Component (BeamBots view)
A `BB.Sensor` or `BB.Actuator` that surfaces a cog to the BeamBots world. It is a *view*: it
reads/writes slots through the **LinkOwner**, lifts values to/from typed `BB.Message`
structs, and carries the cog **contract** in its `options_schema`. It does **not** own the
physical bus. Lives inside BeamBots' topology subtree (so it is force-disarmed with the
robot); the bus it reads through does not.

The boundary between a Component and the **LinkOwner** is a **slot, not a call API** — they
share only named ETS slots, never a reference or a message. This falls out of
transport-transparency (a reader cannot tell local from remote); a call API would rebuild the
deleted CogBus. So a `BB.Sensor` view is a thin beat loop (pull slot → born-stale witness →
lift to `BB.Message` → `BB.publish`); a `BB.Actuator` view is a thin handler (decode command
→ `Slot.put` the outbound command slot). All wire work — framing, conflation, status decode,
de-escalation — lives in the LinkOwner. **Outbound command slot: the Component (command
producer) is the single writer; the LinkOwner is a read-only drain to the wire** — forced,
because a LinkOwner that could *write* the command slot could bump `seq` and fake an advance,
breaking the "surviving LinkOwner is safe by construction" guarantee. The slot→`BB.Message`
type mapping is generated manifest data (drift-tested like the codecs), not hand glue.

### Status slot
A slot the actuator node produces (`floor_engaged`, `armed`, `applied_seq`, …) flowing *up*
the wire. It is the authoritative source of "is the hardware physically safe/live?" — never
`BB.Safety.armed?`, which is a feedback-free BEAM-side belief. Because the **LinkOwner**
survives a topology force-disarm, the status stream keeps flowing even after the robot goes
to `:error` — the robot fails *legibly*, not blindly.

### Safety de-escalation (the status→BB.Safety reconciliation)
The **LinkOwner** — which already decodes every **status slot** frame — calls
`BB.Safety.disarm/2` (idempotent, best-effort, fire-and-forget) whenever a node reports
floored or its status goes stale. It is **one-directional**: it may only ever drive BeamBots
*toward* disarmed, **never** call `arm/1`. Re-arm stays chip-gated (the nonce-echoing Point-5
sequence). This is not a separate process — it is one conditional inside the thing that
already holds the status. Safe-by-construction: if it lags or fails, BeamBots stays
stale-but-conservative and the **floor** on the chip is untouched — physical safety never
waits on it. It only ever repairs a *display* lie (BeamBots' `armed?`), never authorizes
torque. Because our `disarm/1` is best-effort and returns `:ok`, this always lands BeamBots
in `:disarmed` (not the `:error` lock).

### Coordination policy
Master-side **code** (tested, not a manifest knob and not a cog) that reads the **health
fold** and the raw floor reports and *decides* how to coordinate a stop across cogs. Distinct
from the fold: the fold states *facts* (per-scope `:nominal|:degraded|:safe`); the policy
applies *judgment* over those facts. It may **initiate** a stop (not only propagate one) —
e.g. a cog reporting "running hot" is a warning no reflex would catch, yet the policy may
choose to broadcast a preemptive stop. A cog only ever *reports* its own state ("I am cog X,
I floored / I am hot"); it never *requests* a sibling stop — it lacks the whole-system view.
The master owns coordination; the cog owns honest self-report.

The policy is **best-effort, not safety-critical** — it is strictly additive on top of the
**floor**. It lives inside BeamBots' topology subtree. An ordinary crash → supervised restart
→ it comes back **born-stale** and re-derives from the *current* fold (restart *is* the
recheck — no resume logic). The only state it does not auto-recover from is a topology
teardown (restart budget exhausted), and in that state BeamBots has already force-disarmed
everything, so there is no coordination decision left to make. Recovery is operator/external;
absent it, the floored-default simply persists.

**Shape (resolved):** one **robot-wide** instance — a pure `decide(fold, reports, couplings)`
function (the tested safety graph) plus a thin GenServer shell beside `HealthMonitor` on its
own beat. **Input:** the per-scope **fold** levels (hard facts) *plus* the raw soft-warning
fields the fold deliberately does not gate on (e.g. a `temp_c` field). **Output / actuation:**
`:none` (log) · `{:stop_scope, s}` (bump that scope's per-scope `:estop`) · `:stop_global`
(write the broadcast e-stop slot `0x0000`). It writes no command slot and never re-arms.
**Rule:** a soft warning *alone* is a log; a warning *plus* corroborating degradation, or a
declared dangerous **coupling**, is a stop; a coupling spanning >1 scope escalates to global.
It does **not** re-act to a scope the fold already calls `:safe` (the fold already floors
that) — the policy only *initiates* (warnings) and *escalates* (cross-scope couplings).
**Code vs manifest:** `decide/3` is tested code; the manifest adds only `couplings:` (named
sets of scopes dangerous-together) and soft-warning thresholds. A status field is **either**
fold-critical **or** policy-soft, never both (boot check). For a single-actuator bot
(`follower_segby`, no couplings) it degenerates to a near-empty pass-through that only logs.

### The safety stack (three layers, each a fallback for the one above)
1. **Coordination policy** (master, in BB tree) — preemptive & coordinated stops from
   whole-system judgment. Richest, least reliable, best-effort. May initiate.
2. **BeamBots force-disarm / broadcast e-stop** (master-driven) — blunt global stop when the
   topology collapses or an operator commands it. Drops commands → seq stops advancing.
3. **The floor** (on each chip) — reflexive, autonomous, survives total master loss. The
   guarantee. Never depends on layers 1–2.

The standing principle: **safe is the default state, motion is what must be continuously
earned.** No layer has to *act* to reach safety — each only ever *stops authorizing motion*,
and the chips floor on command-silence on their own. You never make the robot safe; you only
keep earning motion (a fresh, witnessed, in-window, chip-gated command).

### Born-stale (the witness rule)
A reader (a freshness/floor witness) distrusts whatever value sits in a slot until it
*personally* witnesses `seq` advance past the last value it recorded, on its own clock. This
is what makes **LinkOwner** surviving (B2) safe with no extra rule: stale command/arm state
surviving in BEAM memory and being re-streamed is the *same* `seq` re-arriving, never an
advance, so no consumer is moved by it. Safety is by *construction* (distrust the
un-witnessed), never by an active flush — flushing would make safety depend on recovery
succeeding, which §00 forbids.
