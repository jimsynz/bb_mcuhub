# Design changelog

Decision history and rationale for the hub-gateway design. The design doc
(`docs/hub-design.html`) is kept **stateless** — it always describes the current
intended design with no history or "we changed X" framing. This file is where the
*why* and the *when* live: each entry says what changed in the design and the
reason it changed.

Format: newest first. Dates are absolute.

---

## 2026-06-18 — Single-source DSL: contract authored in BeamBots' DSL; boot checks become a compile-time verifier (§06, §09)

The walking skeleton kept **two parallel models** that had to agree: the
producer-side wire facts in `hubs/*/contract.exs` (loaded by `Source`, projected
by `Contract.build_ir/2`) and the reader-side BeamBots `topology do` (the
`sensor`/`actuator` views naming `(hub, port)`). They were reconciled only
implicitly, at view `init/1`, via `PortIndex.resolve/2`. Authoring the same system
in two places is the sync hazard this change removes.

Decision (grilled with the user): **make the BeamBots DSL the single authored
source of truth, and ship the hub gateway as a Spark extension to it.** A user
imports the `bb` packages plus this library and gets new vocabulary to declare
hubs, place them, and wire their ports — focusing on structure/config, while the
library owns the communication logic (wire, floor, freshness, segmentation).

### What changes
- **Hub modules.** A hub is a reusable module (`use BBMcuhub.Hub`, a small Spark
  DSL) declaring its ports' **intrinsic wire facts** — `dir`, `type`, `rate`,
  `t_dev`, `safe_action`, and the pure `sample`/`step` core. Everything true about
  the device, deployment-independent. Read back via `BBMcuhub.Hub.Info`.
- **Placement in a sibling `hubs do` block.** A `hub :name, Module, node: 0xNN`
  entity lives in a top-level `hubs do` section our extension owns, composed onto
  `use BB, extensions: [BBMcuhub.Dsl]` (no `bb` fork). It places hubs on nodes;
  the existing `topology do` wires their ports to components. (The first-choice
  shape — injecting `hub` directly into BeamBots' `topology` section via
  `Spark.Dsl.Patch.AddEntity` — is blocked: `bb` 0.20.3's `topology` section is
  not `patchable?`, so the patch is silently dropped, and making it patchable
  would fork `bb`. A sibling section is the no-fork equivalent.) The view option
  `node:` is renamed `hub:` (it always named the hub, not a wire id; `node` is now
  strictly the placed id).
- **IR is projected, not authored.** A Spark **transformer** in the extension
  walks the `hub` + `sensor`/`actuator` entities, reads producer facts via
  `Hub.Info`, and **persists the IR row shape** into the robot's DSL state, read
  back via `BBMcuhub.Robot.Info`. The IR row shape (the seam `WireGen`/`PortIndex`
  and the parity/drift tests already trust) is **kept unchanged** — only its
  source changes — so the entire C/firmware/parity side stays green.
- **`build_ir`, `Source`, `contract.exs` are dissolved.** There is no file to
  load; the hub modules and the robot module are the source.
- **Boot checks → a compile-time verifier.** §06's checks move from "runtime, run
  before the link opens" to a Spark **verifier** (runs after the transformer, so
  it validates the persisted IR): reader↔producer reconciliation (every named
  `(hub, port)` has exactly one producer), node-id uniqueness + reserved ids (host
  0, broadcast `0x00`) unclaimed, `fresh_for` ≥ one writer period, no
  `(node, port_id)` collision, and the frame-size ceiling (`header + payload +
  CRC` ≤ **512 B**, one named constant matching the C `SEG_MAX_BODY`). A violation
  raises `Spark.Error.DslError` naming the offending pair — **the bug cannot
  compile, never mind reach the bus.** This is a strict strengthening of the
  design (earlier = ship-then-refuse-at-boot).

### Why
- One authored model: a fact is stated once, in the DSL, so the producer and
  reader sides cannot fall out of sync (the failure the two-file scheme invited).
- Reuses the BeamBots ecosystem instead of paralleling it: Spark `dsl_patches` +
  verifiers + InfoGenerators are the upstream-blessed extension surface, so the
  library composes with `bb` rather than shadowing it.
- The IR seam is preserved deliberately: it is the proven, drift-tested boundary
  to the C side, which has no business reading the BeamBots DSL. Keeping it means
  the refactor is "swap the front-end that produces the IR," not a wire rewrite.

ADR-0002 records the single-source-of-truth / Spark-extension architecture
(hard to reverse). §06 and §09 of the doc are reconciled in-place to describe the
DSL-authored model and the compile-time verifier; CONTEXT.md gains **Hub module**
and **Topology validation** and sharpens **Contract**.

---

## 2026-06-18 — CAN segmentation/reassembly: on-wire encoding pinned (§03, §06)

`docs/hub-design.html` §03 had already moved frame **segmentation into v1** (out of
SAFeD) but deliberately left the on-wire encoding open ("the bridge segments
it"). Before implementing, the encoding was pinned in a grilling session and the
doc was sharpened **in-place** to describe the now-fixed design. The decisions:

### 1. The end-to-end CRC-16 is present and checked on the CAN path — always
- **Was (code):** single-frame CAN RX handed the raw CAN data field straight up
  as a "verified body," trusting only CAN's own per-frame hardware CRC. (The doc
  always *claimed* the CRC guards the body across the re-framing boundary; the
  code did not honour it on CAN.)
- **Now:** our CRC-16 rides the body across CAN as its 2-byte trailer and is
  checked at **every** CAN receive, single- and multi-frame alike — the same
  "nothing unverified above the seam" invariant the UART seam already has.
- **Why:** CAN's per-frame CRC guards one bus segment but **cannot survive the
  re-framing** at a branch hub (decode → rebuild in RAM → re-transmit). A bit-flip
  in the hub between RX and TX is exactly what an end-to-end CRC catches and the
  hardware CRC cannot. A corrupted `seq` slipping through would poison freshness
  (§04), so the gate must hold on CAN too.

### 2. Fragment metadata rides the 13 reserved id bits, not the data field
- **Layout pinned:** `[NODE:8][PORT:8][FIRST:1][LAST:1][SEQLO:5][FRAG_IDX:6]`.
  6-bit index → **≤ 64 fragments → 512-byte body ceiling**; FIRST on index 0; LAST
  on the final fragment; the body `seq`'s low 5 bits bind every fragment to its
  body. A single-frame body sets FIRST+LAST, index 0.
- **Why id bits, not a data sub-header:** keeping the data field 100% body bytes
  makes the CAN body **byte-identical to the UART body** for the same logical
  value, so the parity vectors (§06) — the cross-language drift witness — hold
  across both transports unchanged. A data-field sub-header would have forked the
  vectors per transport. The reserved bits were already earmarked for exactly this
  ("deeper-CAN-segment id / priority band"). Fragment bits sit *below* NODE/PORT,
  so they never disturb the `(NODE,PORT)` hardware filter and never outrank
  arbitration — `NODE 0x00` (e-stop) still wins the bus.

### 3. Reassembly is fail-closed, FIRST-seeded, strictly sequential, no timeout
- One in-flight buffer per `(node,port)`. A buffer is **seeded only by a FIRST
  fragment**; a non-first fragment with no open buffer is dropped+counted
  (`rx_frag_orphan`) — a stray/garbage fragment can never seed a body.
- Each subsequent fragment must have `FRAG_IDX == expected_next` **and** matching
  `SEQLO`; any gap/reorder/alias **abandons the whole partial** (`rx_frag_drop`)
  and only a FIRST may re-seed. Completion is the LAST fragment → CRC over the
  reassembled body → deliver only on pass (else `rx_crc_fail`).
- **No reassembly timeout in v1** — a stalled partial is reclaimed structurally by
  the next FIRST for that key (a timeout is a conflation-era refinement, SAFeD).
- **Why:** losing one fragment loses the **whole body** (no ARQ, no partial). A
  lost body is a stale-making non-event the freshness/born-stale machinery (§04)
  already tolerates; a *partial* body reaching a slot would be silent corruption.
  Fail-closed is the only safe choice, and the structural reclaim avoids a timer.

### 4. `tx_oversize` re-aimed at the 512-byte ceiling
- **Was:** `tx_oversize` counted any classic-CAN body > 8 B (the refuse-don't-
  truncate stopgap). The 54-byte IMU was on the reject path.
- **Now:** segmentation **is** the > 8 B path; `tx_oversize` is re-aimed at the
  should-never-happen body > 512 B (over 64 fragments) — a belt to the §06 boot
  size-check, not a normal-frame reject. New CAN-seam counters: `rx_frag_orphan`,
  `rx_frag_drop`, `rx_crc_fail`.

### Doc reconciliation (in-place, stateless)
§03's "the one transport detail" callout, its byte diagram (reserved → segment),
and the §06 boot-check bullet were rewritten to describe the pinned encoding as
the current design. `CONTEXT.md` gained a **Segment** term and had **The frame**
and **Contract** sharpened (per-port `t_dev`; three artifacts; CRC always on CAN).
ADR-0001 records the wire-format trade-offs (hard to reverse).

---

## 2026-06-18 — Corrections from building the v1 walking skeleton

Building `bb_mcuhub` (the Elixir host stack, host-compiled + ESP32 firmware, and
the BeamBots views, with a cross-language parity witness) surfaced five places
where the design as written was wrong, underspecified, or made a claim reality
contradicted. All five were folded **in-place** into `docs/hub-design.html` so the
doc still reads as a single stateless source of truth. The changes:

### 1. CAN-FD is a hardware requirement; frame size is a real v1 constraint (§03, §06)
- **Was:** "use CAN FD … v1 sizes every value type to fit one frame, so
  segmentation is SAFeD and the common path never needs it."
- **Now:** CAN FD is stated as a hardware dependency on the MCU + transceiver.
  Frame size is a real constraint: a value type that overruns the chosen
  controller's single-frame size is **segmented by the bridge** (moved out of
  SAFeD into v1), and a bridge **never truncates** — it refuses and counts an
  oversized frame (`tx_oversize`). A per-frame **size check** was added to the §06
  boot checks, kept explicitly distinct from the (still-SAFeD) link-bandwidth
  wire-budget.
- **Why:** ESP32's built-in TWAI is **classic CAN (8-byte data field), not CAN
  FD**. The very first port broke the "fits one frame" promise: reusing the
  canonical `BB.Message.Sensor.Imu` (quaternion + two vectors) is a 40-byte
  payload → 54-byte wire body. That fits CAN FD's 64 but is ~7× over classic
  CAN's 8. Silent truncation would poison decode and the freshness counter (§04),
  so refuse-and-count is the only safe v1 behaviour on a classic-CAN board.

### 2. `t_dev` is opt-in per port (§04, §03)
- **Was:** `t_dev` (8 bytes) is carried on every frame; "costs 8 bytes and zero
  gate complexity."
- **Now:** `t_dev` is a **per-port** contract flag. Sensors that feed
  fusion/replay carry it; command and status ports omit it and stay small.
- **Why:** With a 12-byte header (8 of them `t_dev`), the header is 75%
  timestamp; a 16-byte effort command was half a `t_dev` the design itself says
  commands never use. Making it per-port more than halves command/status frames
  and eases the single-frame budget (item 1). The freshness rule is unaffected —
  `seq` was always the only trust stamp.

### 3. The Elixir codec is data-driven, not generated — "three artifacts" (§06)
- **Was:** the generator emits "four renderings of one model," one of them the
  Elixir codec (`codec.ex`, GENERATED).
- **Now:** the host Elixir codec is **data-driven** (reads the layout/header
  tables at runtime); the generator emits **three** artifacts — the C header, the
  per-hub schedule, and the parity vectors — and drift-tests them.
- **Why:** a codec that interprets the single source of truth cannot drift from it
  *within* Elixir, so there is no generated `.ex` to fall stale. The drift surface
  collapses to exactly the cross-language boundary the in-language guarantee can't
  reach, which the parity vectors witness directly. Same guarantee, smaller
  surface.

### 4. §09 rewritten against the real `bb` 0.20.3 API
- **Was:** an invented `HubView.Sensor`/`HubView.Actuator` API: a `path:` option,
  `BB.publish/3` by path, manual `BB.subscribe` + `BB.Safety.register` in `init`
  described as "REQUIRED — silent no-op if forgotten," `live?/1` reading the raw
  status slot.
- **Now:** matches the real package — `use BB.Sensor` / `use BB.Actuator`
  **callback modules** (not GenServers) with `options_schema:`; `:bb`
  (`%{robot:, path:}`) and `:motor_profile` **auto-injected**; **no built-in poll
  loop** (the view drives its own beat); `BB.publish(robot, [:sensor | path],
  msg)`; the actuator **server auto-subscribes** the command topic and
  auto-registers `disarm/1`, so the "forgotten subscribe" gotcha is gone;
  messages are concrete `BB.Message.Sensor.Imu` / `BB.Message.Actuator.Command.
  Effort` with Nx-tensor-backed `Quaternion`/`Vec3`.
- **Why:** the doc's §09 was illustrative pseudo-code written before the real
  dependency was pinned. Coding against `bb` 0.20.3 showed the real shape, which
  is in several ways simpler (no manual subscribe to forget) and in one way
  different that matters (callback module, not GenServer).

### 5. Born-stale resolved strict, with its cost stated (§04, §05)
- **Was:** "born stale … until it personally sees `seq` advance since its own
  boot" — left implicit how a consumer tells a pre-boot leftover value from the
  producer's first post-boot value, which look identical on first observation.
- **Now:** the **strict** rule is explicit: the first observed `seq` is only a
  baseline; trust begins on the first *change* from it. A leftover value is never
  trusted, at the cost of up to one extra producer period of first-trust latency.
  The monitor code block (§04) and the firmware floor (§05) both reflect this.
- **Why:** it is the literal reading of "advance since its own boot" and the safe
  one. A boot-epoch / generation marker that distinguishes the two cases (and so
  trusts a genuine first value immediately) is noted as a later SAFeD elaboration,
  since it only ever removes latency, never adds trust.

### Implementation bugs fixed alongside (code, not design)
These were defects in the reference implementation relative to the (correct)
design, fixed in the same pass:
- **`Actuator.live/1` was not freshness-gated** — a stale "not floored" status
  read as `:driving` (the "confident green while floored" failure §05 warns
  against). Now gated by a born-stale status monitor on the view's own beat.
- **Classic-CAN silent truncation** — the TWAI TX path truncated bodies >8 B to 8.
  Now refuses and counts them (item 1).
- **Added a 2-hop router test** — verifies the relay invariant (forward by NODE,
  `seq`/`t_dev`/payload verbatim, meaning-blind), which had no end-to-end test.

### Per-port `t_dev` (item 2) — now implemented
The code was brought in line with the design: `t_dev` is a per-port contract flag
(`t_dev: true`), and the header is one of two shapes. The change rippled through
the Elixir contract/codec/`PortIndex`, the generator (a `wire_port_stamped`
lookup + `PORT_*_STAMPED` defines + `WIRE_HEADER_BASE_SIZE`/`_STAMPED_SIZE`), the
C `frame.c`/`frame.h` (`Frame.stamped`, `frame_decode_body(..., stamped, ...)`),
the parity vectors, and the firmware. Result: the IMU pose stays stamped (52-byte
body); the effort command dropped 16 B → **8 B** (and now fits classic CAN) and
status 15 B → **7 B**. The decoder learns a frame's shape from the per-`(node,
port)` index (host) / `wire_port_stamped` (firmware) after peeking the base
header, so an unstamped frame is never misread. The cross-language parity witness
confirms the new byte layouts agree C↔Elixir.

### Known gaps recorded (not yet built, beyond the design's own SAFeD list)
- **Frame-size check / segmentation (item 1):** the design moves these into v1;
  the code currently refuses-and-counts oversized classic-CAN frames (the safe
  half) but does not yet segment or run the boot-time size check. *(Segmentation +
  reassembly now built — see the 2026-06-18 segmentation entry above. The boot-time
  size check rides with the topology-validation gap below, still open.)*
- No on-hardware run yet; `imu_read`/`drive` are synthetic stand-ins.
- Inbound CAN multi-frame **reassembly** is unbuilt (waits on the segmentation
  work, item 1); undersized stray frames are safely rejected by the codec's
  header-size check. *(Now built — see the 2026-06-18 segmentation entry above.)*
- Boot-time **topology validation** (§06: one producer per `(node,port)`, unique
  ids, `fresh_for` ≥ one period, frame-size check) is specified but not yet
  implemented as a runtime boot check.
- The host command **drain is a 5 ms poll**, not event-driven — fine for v1 rates;
  revisit with conflation (SAFeD).

---

## (earlier) — initial design

`docs/hub-design.html` v1 authored; supersedes the earlier "cog framework" draft.
See `CONTEXT.md` for the glossary. Recent git history: design refinement,
hub-gateway v1 design added, hub gateway hardened / cog framework superseded.
