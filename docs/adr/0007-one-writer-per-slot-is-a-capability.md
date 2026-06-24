# One writer per slot is enforced by a write-scoped capability, the mirror of the Reader

The "exactly one writer per slot" rule (§07) — the precondition that makes
`seq`-as-trust sound — is enforced **structurally** by a slot-scoped **write
capability** (`BBMcuhub.Host.Registry.Writer`), the write-side mirror of the
read-only `Registry.Reader` that ADR-0004 gave observers. A writer is minted for
one `(node, port_id)` via `NodeRegistry.writer!/2`; its `put/4` carries no node/port
argument (writing another slot is unrepresentable), and a second live mint for the
same slot raises `Writer.Taken`. The two real writers — the actuator **view** (its
command slot) and the **LinkOwner** (each inbound slot, minted lazily on first
decode) — write through the capability.

This is recorded because it changes a safety-critical contract from a convention
into a structural invariant, mirrors a prior decision (ADR-0004), and carries a
deliberate, load-bearing limitation (the `:public` ETS table is kept) that a future
review would otherwise re-litigate.

## The problem

The slot registry's whole trust model rests on `seq`: freshness ("did `seq` advance
on my own beats?") and the on-chip **floor** ("did the command `seq` advance?") both
arm on a `seq` advance. The soundness of that rests on a single rule — **exactly one
writer per slot** (CONTEXT.md · _Slot_): if a second actor wrote a slot, it could
mint a bogus `seq` advance and drive a motor with a command the controller never
issued (the inbound mirror: forge a fresh sensor reading, or rewind `seq` so a real
advance reads as "no change").

That rule was **only a docstring** on a `:public` ETS table. The _read_ side already
had a structural guard — ADR-0004's `Registry.Reader` exposes only `get`/`dump`, so
"an observer writes a slot" is unrepresentable — but the _write_ side had no
symmetric guard. Any module could call `NodeRegistry.put(node, port, …)` for **any**
slot, or `:ets.insert` the table directly. Nothing tied a writer to the slots it
owns. (A review surfaced this; it also surfaced that several tests were silently
running **two** writers on one command slot — the exact anti-pattern.)

## The decision

A **write capability** scoped to one slot, symmetric with the Reader:

- **`BBMcuhub.Host.Registry.Writer`** is bound to one `(node, port_id)` at mint time.
  Its `put/4` takes `(writer, value, seq, t_dev)` — **no node/port** — so a holder
  can write only the slot it was minted for. "Write some _other_ slot" is
  unrepresentable, not merely discouraged.
- **`NodeRegistry.writer!/2`** mints it and enforces **uniqueness**: the registry
  process tracks `slot → {writer_pid, monitor_ref}`; a second _live_ mint for a slot
  raises `BBMcuhub.Host.Registry.Writer.Taken`. The claimant is **monitored**, so a
  crashed writer's slot is freed for its replacement (a restarted view), and a
  claim-time liveness check makes this robust to monitor-message timing.
- The **two real writers** mint and write through it: the actuator view mints its
  command-slot writer at `init` (a second view on the same slot now **fails loud at
  init**, not a silently-shared slot); the LinkOwner mints an inbound-slot writer
  lazily on first decode of each slot, preserving its read-only-_drain_ posture for
  command slots (it never writes a command slot).

**The accepted limitation.** The registry ETS table stays **`:public`**. The views
and the LinkOwner read+write the table directly to stay **lock-free on the control
hot path** — routing every write through the owning GenServer would make it a
serialization point on the command cascade. So the **raw `:ets.insert` escape hatch
is not sealed**: the capability raises the bar against honest mistakes _through the
API_ (and makes a duplicate writer fail loud), but not against code that
deliberately bypasses the registry. This is the price of keeping writes lock-free,
and it is the asymmetry with the Reader (a stray _read_ cannot corrupt state, so the
read side has no equivalent hole that matters).

## Considered options

- **Keep it a convention (status quo).** Rejected: a safety-critical invariant
  enforced only by a comment and code review, on a `:public` table — and demonstrably
  already violated by test fixtures.
- **Make the table `:protected`, route every write through the owner.** Fully seals
  the `:ets.insert` hole _and_ lets the owner enforce uniqueness — but every write
  becomes a GenServer round-trip, making the owner a throughput bottleneck on the
  control hot path. Rejected for v1: the lock-free direct write is load-bearing for
  the command cascade; the capability gets most of the protection without it.
- **A dev/test-only sole-writer assertion inside `put/5`.** Cheaper, and it catches
  the actual failure (a stray second writer) including the raw-`:ets` path — but it
  is a runtime assert, not unrepresentability, and only fires if the bad path runs
  under test. Folded in spirit (the uniqueness guard _is_ a runtime check) but the
  capability is the primary, type-level guard.

## Consequences

- **"One writer per slot" is structural, not a convention** — symmetric with
  ADR-0004's Reader. Writing another slot is unrepresentable; a duplicate writer
  fails loud at `init` with a named `Writer.Taken`, naming the slot and the holder.
- **The `seq`-as-trust path can no longer be forged through the API** — a second
  actor cannot manufacture a `seq` advance via `writer!`/`put`. The floor and
  freshness keep their precondition.
- **The `:ets.insert` hole remains, by choice** — documented here and on
  `NodeRegistry.put/5`. Sealing it (a `:protected` table) is a future decision if the
  hot-path cost is ever acceptable.
- **Test fallout fixed by view-less robot twins** — the review found
  BB.Supervisor/Host's production view and a hand-driven `ViewHarness` view
  contending for one command slot in four test files (library + example). Each now
  uses a view-less robot twin (`Test.Fixtures.HarnessRobot` /
  `SegbyV1.Test.HarnessRobot`, same hubs/PortIndex, no view child_specs) so the
  harness view is the sole writer — the tests now mirror production (one view per
  slot). Tests use `NodeRegistry.reset/0` (routed through the owner, clears rows
  **and** claims) instead of raw `:ets.delete_all_objects`.
- **Not part of the wire contract** — purely host-side; generates no firmware, no
  wire artifacts, drift-test-neutral.
