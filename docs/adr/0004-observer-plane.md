# Observability is a separate plane: observers are pure registry-sampling readers

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

**Two modes, matching what a slot already is.** A slot is simultaneously a
latest-value and a monotonic advance-counter, so an observer reads one of two ways:

- **sample-state** (level) — read the latest _value_ at the observer's rate;
  dropping skipped values is correct. For "what is it now?" (pose, status, effort).
- **stream-events** (edge) — follow the slot's `seq` and emit one event per advance,
  catching **every** selected edge (the Advance invariant guarantees none are lost).
  For "what happened?" (every command, a floor firing, an arm/disarm) — an event
  database or disk log that must not miss one.

The concept _discovers_ this duality already present in the slot rather than adding
machinery.

**Four reduction axes; v1 does two.** An observer is a declarative reduction of the
firehose: **sample** (rate decimation; state mode), **select** (which slots / which
edges), **filter** (a value/event predicate), **project** (which fields). v1
implements **sample + select**; **filter** and **project** are designed and
documented as extensions of the same shape, so they slot in without rework.

**The protecting invariant — an observer is a PURE READER.** It never writes a slot,
never issues a command, and nothing in the control plane may depend on an observer
existing. This is what makes observability purely additive (a new observer touches
no producer, view, controller, or other observer) and what makes "observers cannot
perturb the control plane" structural rather than aspirational. An observer that
writes, or that the loop depends on, is a control-plane actor in disguise — forbidden.

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
- **The library owns the observer plane; the example demonstrates adoption.**
  `BBMcuhub.Observer` (imperative core; a declarative `observers do` section is later
  sugar over it) lives in the library. Wiring `bb_tui` onto an observer's slow topic —
  so the dashboard stops drinking the control firehose — is a consumer use case in
  the worked example.
- **The TUI lag that motivated this** is the control loop's 100 Hz pose + the
  controller's command cascade flooding the prefixes bb_tui subscribes to; the
  fix is to feed the dashboard from an observer at the dashboard's own rate, not to
  slow the loop.
