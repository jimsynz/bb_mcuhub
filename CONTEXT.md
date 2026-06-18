# Context — the hub gateway

A glossary of the load-bearing terms in the hub gateway: the design for reaching
microcontroller hardware from the BeamBots (`bb`) ecosystem through one recursive
abstraction. Definitions only — no implementation details. See `docs/hub-design.html`
for the full architecture.

> This supersedes the earlier "cog framework" vocabulary (cog · manifest · Master ·
> CogBus). Where you see those terms elsewhere, read: cog → **hub**, manifest →
> **BeamBots topology + contract**, Master → **host**.

## Terms

### Hub
The one MCU node type, and the whole topology model. A hub does any subset of three
jobs — **sense** (read a device, `sample` a typed value, publish it up with a `seq`),
**act** (drive a local actuator behind a floor), and **route** (forward frames for
child hubs, meaning-blind). Because a hub can be a parent, a tree of any depth is built
by composing this one shape — there is no separate gateway, leaf, or router type. A hub
with children is a branch; a hub with none is a leaf. See **Root hub**, **Contract**.

### Root hub
The hub that owns the host link: it speaks **UART** upward to the host and **CAN**
downward to its child hubs, bridging the serial link to the CAN backplane. It is still
an ordinary hub (it may sense or act while it bridges) — not a fourth node kind, just
the one hub that happens to hold the host connection.

### Host
The board above the tree (a Raspberry Pi running Elixir/OTP under Nerves and the
BeamBots application). It is **not a hub** — it sits above the hub tree, reaches every
node through one UART to the root hub, and holds the robot's truth in a small
per-`(node, port)` registry. Logical id 0.

### Contract
The small data a hub ships describing itself: its ports, each port's value `type` and
`rate` (a single nominal number), its `safe_action`, and its `fresh_for` needs, plus
the pure core (`sample` for a sensor, `step`/safe-action for an actuator). A generator
reads every hub's contract plus the topology and emits **three** artifacts of one model
— the C headers, the per-hub schedule, and the parity vectors (the Elixir codec is
data-driven, reading the model at runtime, so it cannot drift within Elixir) — so the C
and Elixir sides cannot drift. A hub's contract is its public face.

### NODE / PORT (the wire identity)
A value's identity on the wire is `(NODE, PORT)`. **NODE** is a flat, whole-tree-unique
address — never a path; routing is a flat table lookup, `route_table[node] → local link`.
**PORT** names a sense/act endpoint on that node and nothing else — a child link is
**not** a port (a downstream hub is reached by addressing its own NODE). On CAN the two
pack into a generated 29-bit extended id `[NODE:8][PORT:8][rsv:13]`, so the controller
filters in hardware and id-range doubles as arbitration priority. `NODE 0x00` is the
reserved broadcast/e-stop address — the lowest id, so it wins bus arbitration.

### Slot (the registry row)
A named place keyed by `(node, port)` holding exactly one value plus two stamps: `seq`
(a per-write counter the producing hub bumps +1 on every real new value) and `t_dev`
(the producer's own 64-bit monotonic microseconds at the write). Overwrite-only; reads
never block and return the latest. **Exactly one writer per slot.**

### seq · t_dev (the two stamps)
`seq` is the **only** stamp in the trust path: a consumer judges freshness by "did `seq`
advance within my `fresh_for` window, on my own beats?" — never a cross-board clock
comparison. `t_dev` is a passenger for **same-device** math only (aligning a single
device's samples, jitter, replay); it is never compared across nodes and never read by
the freshness check. The split is strict: `seq` decides trust, `t_dev` is carried but
inert to it.

### Advance (the freshness/floor test)
"`seq` advanced" is the plain inequality `seq != last_seq` — any change is a new write.
This is **sound only because every path is in-order**: point-to-point UART/CAN preserve
order and the relay is a strict FIFO byte pump (see **Relay**). No magnitude test means
counter wrap is a non-issue. If a future relay may reorder, this test must become a
windowed forward compare.

### Relay (the router discipline)
A branch hub forwarding a child's frame copies `seq` and `t_dev` **verbatim** (a relay
never mints a `seq`) **and** forwards in **arrival order** — a strict FIFO byte pump
that never reorders, holds, batches, or dedupes. This in-order guarantee is the
precondition that makes the **advance** test sound. Conflation (deferred) may drop
superseded frames but must preserve per-`(node, port)` order.

### fresh_for · born-stale
Each consumer declares a `fresh_for` window as a multiple of the producer's nominal
period (so "a window shorter than one write" cannot be expressed). A freshly started or
restarted consumer is **born stale**: it distrusts whatever value sits in a slot until
it *personally* witnesses `seq` advance since its own boot. This is what makes a restart
safe — a rebooted board never trusts a leftover reading.

### The floor (dead-man)
The authoritative safe-state mechanism, on each actuator hub's **own chip**. It watches
the `seq` of *its own* command against a compiled-in window on its own clock; if the
`seq` stops advancing, it drives the plant to its `safe_action` and latches disarmed.
It needs no inbound frame, so it fires even if the parent, the tree above, or the host
is entirely gone. It is the guarantee; everything host-side is best-effort on top of it.

### Born-disarmed
Every actuator hub boots `armed = false` with its output already at the safe action. It
begins driving only after it witnesses a fresh, in-window command `seq` advancing since
its own boot. A reboot, power glitch, or stale buffered frame cannot energise it —
**motion is continuously earned, never a default**.

### The e-stop (accelerator, not mechanism)
The heartbeat and broadcast disarm share **one** tested code path with the floor: a
broadcast disarm, a missed heartbeat, a pulled wire, or a dead parent all resolve to the
same thing at the actuator — *its command `seq` stops advancing* → the floor fires. The
e-stop only makes the silence happen faster (and, as `NODE 0x00`, wins CAN arbitration);
it is never a second "react to the stop frame" path that could itself fail.

### Status slot
A slot an actuator hub produces (`{applied_seq, floored?}` at minimum) flowing *up* the
wire. It is the authoritative source of "is this hub actually driving?" — read (gated by
the same born-stale check) instead of inferred from "we sent it a command," so the host
never shows a confident green while a wheel sits floored.

### The frame
The on-wire shape: a body — `NODE · PORT · SEQ(2B) · [T_DEV(8B)] · PAYLOAD` — guarded by
a **real, pinned CRC-16/CCITT-FALSE** (check value `0x29B1` over `"123456789"`). `T_DEV`
is **per-port** (present only on stamped ports; see **seq · t_dev**). On UART the body is
`0x00`-delimited and COBS-framed; on CAN it is segmented (see **Segment**). The same body
rides both transports; the root hub re-frames UART↔CAN without touching
NODE/SEQ/T_DEV/PAYLOAD. The CRC covers the whole body and is **always present and verified
on both transports** — on CAN it travels as the body's 2-byte trailer, so a re-framing
bit-flip a hop's hardware CRC cannot reach is still caught. A corrupt frame is counted and
dropped at the seam before any value (or any `seq`) is read.

### Segment (CAN fragmentation)
A body wider than a CAN data field (8 B on the ESP32's classic-CAN TWAI; 64 B on CAN FD)
is **segmented by the bridge** into ordered fragments, one per CAN frame, and reassembled
**before** the CRC check (the CRC is over the whole reassembled body, never per-fragment).
Fragment metadata rides the **13 reserved id bits**, never the data field, so the CAN body
bytes are byte-identical to the UART body and the **parity vectors** hold across both
transports. The layout is `[FIRST:1][LAST:1][SEQLO:5][FRAG_IDX:6]`: a 6-bit index (≤ 64
fragments → a hard **512-byte body ceiling**, asserted by the §06 boot size-check), FIRST
on index 0, LAST on the final fragment, and the body `seq`'s low 5 bits binding every
fragment to its body. Reassembly is **fail-closed and strictly sequential**: a buffer is
seeded only by a FIRST fragment; any gap, reorder, `SEQLO` mismatch, or CRC failure
**drops the whole body** (counted, never delivered partial) — a lost body is a
stale-making non-event the **advance** test already tolerates, but a partial body must
never reach a **slot**. A bridge **never truncates**; it refuses-and-counts only the
should-never-happen case of a body over the 512-byte ceiling (`tx_oversize`). No
reassembly timeout in v1 — a stalled partial is reclaimed structurally by the next FIRST
for that `(node, port)` (a timeout is a conflation-era refinement, SAFeD).

### Parity vectors
A generated, committed fixture of `{port, payload, framed_bytes, crc}` rows asserted by
*both* the Elixir suite and a host-compiled C harness — the cross-language witness that
both codecs agree byte-for-byte. The wire cannot drift past it; hand-editing a row is the
tell.

### LinkOwner
The OTP process (under Nerves, beside the BeamBots tree) that owns the host UART to the
root hub. It decodes inbound frames into `(node, port)` slots and drains outbound
commands to the wire. It is placed to survive a view or law crash, so telemetry keeps
flowing through a fault. **It is a read-only drain of command slots** — never their
writer — so it can never manufacture a `seq` advance.

### Component (the BeamBots view)
A thin `BB.Sensor` / `BB.Actuator` that surfaces a hub's port to BeamBots. A *view*: it
reads/writes slots through the LinkOwner, lifts to/from typed `BB.Message`, and carries
the hub contract in its `options_schema`. It owns no socket and names no transport, so it
runs unchanged whether the port is on the root hub's own I²C or a CAN leaf three hops
down. A sensor view publishes only when born-stale freshness passes; an **actuator view
is the single writer of its command slot**.

### SAFeD (Safe-by-Default, elaborate later)
The rule for deferred work: a stub must default to the *safe* behaviour (disarmed, stale,
refused) so elaborating it later only ever *adds* permission, never removes a guarantee.
Deferred items are named in the text, not hidden. Notable v1 holes left explicit: node
identity is **trust-on-first-use** (a mis-flashed/duplicate board is undetected until the
deferred `fw_id` check), and right-rate enforcement (wire-budget + conflation) is deferred
— v1 permits right-rate but does not yet enforce it.
