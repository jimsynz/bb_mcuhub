# Observability is a separate plane: observers sample the slots, decoupled from the control loop

Monitoring, logging, and dashboards form an **observability plane** that is
architecturally separate from the **control plane** (the Components/views, the
controllers/laws, the command path, the floor). The two share the host
`(node, port)` **slots** and nothing else. An **observer** is the observability
plane's consumer: a **host-side, pure reader** that samples a slot directly from
the registry at its **own independent cadence** and hands the result to a
pluggable **sink**.

This is recorded because the decoupling is structural and the mechanism is
non-obvious (an observer bypasses BeamBots PubSub and reads the registry directly).

**Why a separate plane.** The control loop runs at control rate (e.g. 100 Hz pose,
plus the controller's command cascade). A consumer that wants a _different_ rate —
a UI at 10 Hz, a logger at full fidelity — must not be forced onto the loop's rate,
and must never be able to slow the loop. The overwrite-only slot is already a
perfect rate-decoupling buffer ("reads never block and return the latest"), so an
observer that _pulls the latest from a slot_ at its own timer is, by construction,
unable to apply backpressure to or slow the producer/control plane. N observers are
N independent readers; adding one costs the others nothing.

**Two modes — two DIFFERENT mechanisms, not one.** A slot is two things at once (a
latest-value and a monotonic advance-counter), but observing each correctly takes a
different mechanism — they are not the same reader:

- **sample-state** (level) — a **pure registry poll**: read the slot's latest _value_
  on the observer's own timer. Dropping the values skipped between polls is _correct_
  (the slot is overwrite-only-latest; you want "now"). For "what is it now?" (pose,
  status, effort). **This is the registry-direct pure reader, and it is all of v1.**
- **stream-events** (edge) — must catch **every** advance, with none lost. A polling
  reader **cannot** do this: between two polls the slot's `seq` can jump 1→5 and the
  overwrite-only slot has already discarded values 2–4 — the Advance invariant
  guarantees the _producer_ emits every edge, not that a _sampler_ sees them. So
  stream-events is **not** registry-sampling; it requires tapping the one place every
  decoded advance lands — the `LinkOwner` decode path (and, for commands, the
  outbound drain). The design: the `LinkOwner` publishes an **unconditional decode
  fan-out** (it always emits "a body for (node,port) was decoded," whether or not
  anyone listens); a stream-events observer subscribes to that fan-out. This keeps
  the dependency direction intact — the `LinkOwner` depends on "a fan-out exists,"
  never on "an observer exists." For "what happened?" (every command, a floor firing,
  an arm/disarm) — an event database or disk log that must not miss one.

`stream-events` is **deferred (SAFeD)**: v1 ships **sample-state only** (the pure
registry poll), with the decode-fan-out mechanism named here so the v1 observer API
is not shaped around a lossless guarantee a poller cannot keep.

**Four reduction axes; v1 does two.** An observer is a declarative reduction of the
firehose: **sample** (rate decimation; state mode), **select** (which slots / which
edges), **filter** (a value/event predicate), **project** (which fields). v1
implements **sample + select**; **filter** and **project** are designed as extensions
of the same shape. Crucially, `filter` and `project` operate on a value's _fields_,
which only the **value-type** knows (ADR-0003) — so they MUST resolve the slot's
value-type via `PortIndex.type_for` + `BBMCUHub.ValueType` exactly as the Component
view does (`sensor.ex`), never duplicate field knowledge. The v1 `sample + select`
API leaves room for this (a per-slot value-type handle), so adding `filter`/`project`
is additive, not a breaking change.

**The protecting invariant — an observer is a PURE READER, enforced structurally.**
It never writes a slot, never issues a command, and nothing in the control plane may
depend on an observer existing. This is not merely forbidden by convention: an
observer is handed a **read-only registry capability** (a `Reader` exposing only
`get`/`dump`, with `put` not in scope), so "an observer writes a slot" is
_unrepresentable_, not just discouraged — the registry being `:public` ETS means the
comment "exactly one writer per slot" is otherwise unenforced. The control-plane↔
observer dependency direction is enforced by the wiring (observers depend on the
registry + the LinkOwner's fan-out; never the reverse). An observer that writes, or
that the loop depends on, is a control-plane actor in disguise — forbidden, and made
structurally hard to build by accident.

## Considered Options

- **Downsample inside BeamBots PubSub** (an observer subscribes to `[:sensor]`
  like a Component and rate-limits) — rejected: it still _receives_ every published
  message before discarding (paying the delivery + fan-out cost), and it couples the
  observer to the control plane's publish rate, which is the coupling we are
  removing. Registry-direct sampling has neither cost.
- **Lower the control-plane publish rate to suit the dashboard** (e.g. drop the
  pose view to 20 Hz) — rejected as the general answer: it degrades the control loop
  to serve an observer, which is backwards. (A specific robot may still choose its
  view rates, but that is not how observability decouples.)
- **Observer as a Component variant** (same push-on-beat machinery, different rate/
  topic) — rejected: it keeps the shared-topic, shared-rate coupling and the broad
  PubSub fan-out. The observer is categorically a _pull-the-latest_ reader, not a
  _push-every-beat_ view.
- **A wire/firmware-level observer** (a board on the tree observing without the host)
  — rejected: the host holds the robot's truth in the registry; an observer samples
  that. Adding "observe" as a fourth hub job would muddy the recursive-hub model. The
  observer is host-side only.
- **Bend the design around bb_tui** (the existing dashboard subscribes to the broad
  `[:sensor]`/`[:actuator]` prefixes, so it eats the firehose regardless of an
  observer's topic) — rejected: the observer plane is a general library concept;
  pointing a specific dashboard at an observer topic is a consumer use case, shown in
  the worked example, not a constraint on the framework.

## Consequences

- **Observers are not part of the wire contract.** They are pure host runtime,
  generate no firmware and no wire artifacts, and are drift-test-neutral — so they
  can be added or removed without regenerating anything. This is what makes them
  freely additive.
- **The mechanism is type-agnostic; the sink decides what to do.** An observer's one
  job is sample + reduce + hand to a sink. A PubSub-republish (on the observer's own
  topic), a disk log, an event database, and a UI feed are all just sinks. The same
  born-stale **monitor** an observer holds per slot makes `fresh_for` relative to the
  observer's beats, so it never reports a leftover value.
- **An observer's freshness is NOT the control plane's freshness.** Because
  `fresh_for` is relative to the observer's own (slower) beats, a 10 Hz observer with
  `fresh_for: 3` (a 300 ms window) can legitimately report `:fresh` for a slot the
  100 Hz control plane already floored (its 30 ms window expired). This is correct —
  the observer answers "is what I'm showing recent by _my_ cadence" — but it means a
  dashboard must **read the Status slot's authoritative `floored?`** for "is the hub
  actually driving," never infer liveness from its own observer freshness (a green
  "FRESH" over a floored wheel would be dangerously misleading).
- **"Cannot slow the loop" is about backpressure, not robustness or CPU.** The
  registry read is a direct `:ets.lookup` on a `:public, read_concurrency: true`
  table, so an observer cannot block a producer's write or apply backpressure — that
  isolation is structural. But (a) the **sink runs in the observer's own process**: a
  slow/blocking sink (fsync, DB insert, socket) degrades _that observer_ (it falls
  behind its timer; a stream-events observer's mailbox can grow) — it must be bounded
  / non-blocking, with an explicit drop policy, and a failure degrades only that
  observer; and (b) N high-rate observers still **share the BEAM scheduler** with the
  loop — isolation is from backpressure, not CPU contention, so a pathological fleet
  of fast observers competes for cores like any other process. Each observer is its
  own supervised child (`:temporary`/`:transient`), so one crashing never takes down a
  view or another observer.
- **An observer resolves its `select` at start and fails loud on an unknown slot.**
  Mirror the Component view (`sensor.ex` stops on `{:unknown_port, …}`): a typo'd
  `(node, port)` must fail at startup, not silently observe `nil` forever
  (indistinguishable from a real-but-never-written slot).
- **The library owns the observer plane; the example demonstrates adoption.**
  `BBMCUHub.Observer` (imperative core; a declarative `observers do` section is later
  sugar over it) lives in the library. Wiring `bb_tui` onto an observer's slow topic —
  so the dashboard stops drinking the control firehose — is a consumer use case in
  the worked example.
- **The TUI lag that motivated this** is the control loop's 100 Hz pose + the
  controller's command cascade flooding the prefixes bb_tui subscribes to; the
  fix is to feed the dashboard from an observer at the dashboard's own rate, not to
  slow the loop.
