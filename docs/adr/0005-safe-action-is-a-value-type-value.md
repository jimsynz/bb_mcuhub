# A safe action is a value of the port's value-type, and the floor is byte-generic

A floored command port's **`safe_action`** is declared in the DSL as a **literal
value of that port's own value-type** — the same `[{field, wire_type}]` **layout**
the wire carries — not as a free-floating atom. The **generator packs it to bytes
through the existing layout codec** (the one the parity vectors already use), and
the on-chip **floor stores and drives opaque bytes**, never a `float`. The
**verifier** validates `safe_action` as it would any value-type value and
**requires** it on every floored command port.

This is recorded because it changes a safety-critical contract on **both strata**
(the Elixir DSL/IR and the C floor), is hard to reverse once robots ship against it,
and replaces a convention that was silently wrong.

## The problem

In the v1 implementation `safe_action` is a bare atom on a `dir: :in` port, and the
generator maps it to a C `float` through `safe_action_value/1`
(`lib/bb_mcuhub/gen/wire_gen.ex`). Three things were wrong, all **silent**:

- **Any unknown atom became `0.0`.** `safe_action_value(_other) -> "0.0"` — so
  `safe_action: :full_extend` compiled to a floor that drives `0.0`, beside a
  generated comment `/* :full_extend */` that _looks_ like confirmation but is a lie.
  The safe-state path — the floor's whole job — degraded silently.
- **Omitting `safe_action` silently removed the floor.** `floored_command?` was
  `dir == :in and safe_action != nil`; a command port with no `safe_action` was
  classified non-floored and got a direct-drive path with **no dead-man at all**. A
  user could author a motor with no floor and get no error — the opposite of the
  design's "motion is continuously earned" guarantee.
- **The floor was structurally `float`-only.** `floor.h` held `float target;
float safe_action;` and `on_command` did `be_get_f32(&payload[0])` for _every_
  floored port regardless of its layout. A multi-field floored command (a servo's
  neutral position + a brake bool; an RGB-with-enable) was **unrepresentable in the
  floor yet representable in the DSL** — and silently mis-decoded.

The verifier — documented as the check that makes "the bug cannot ship" — caught
none of these. It checks **wire framing** well-formedness; it did not check
**role/safety** well-formedness. The danger was that the one path you most want loud
was the quietest.

## The decision

**A safe action is just a valid command value.** The floor's job is to drive the
plant to a known-safe value on `seq` silence; that value is, by definition, an
instance of the same value-type the command carries. So:

- **DSL — a literal field-map, not a function.** `safe_action: %{nm: 0.0}` for a
  float effort; `safe_action: %{pos: 90.0, brake: true}` for a servo. It is a
  **literal value** so it serializes into the IR, the C, and the parity vectors — a
  function (a closure) could not, and would break the single-authored-model property
  (ADR-0002): everything is generated from one inspectable model.
- **Generator — reuse the codec, emit bytes.** At `mix wire.gen` the generator packs
  `safe_action` with the **same** `Codec.encode_fields(value_type.layout, value)`
  that produces the wire bytes and the parity vectors, and emits the result as a C
  byte initializer (`static const uint8_t SAFE_<hub>_<port>[] = { … };`). No new
  translation layer — the packer is already the cross-language-witnessed one, so the
  safe action's bytes are byte-correct by the same proof that protects the wire.
- **Floor — opaque bytes, value-type-agnostic.** `floor.h` holds `uint8_t safe[N]`
  and `uint8_t target[N]` (N from the layout's packed size); `floor_on_command` and
  `floor_tick` swap byte buffers and watch the `seq`, exactly as before — the floor
  **never knew the value was a torque** and now doesn't pretend to. The `_drive` hook
  receives the packed value and the device-specific code unpacks it (mirroring how a
  sense hook already packs into a struct). The scalar case is just `N = 4`.
- **A `dir: :in` port declares its role explicitly with `has_safe_action`.** The
  floored-vs-not distinction is no longer inferred from whether `safe_action` happens
  to be present — it is a **required boolean** on every command port. `has_safe_action:
true` means the port is floored: a `safe_action` value **must** be given and the port
  gets a Floor. `has_safe_action: false` means a non-floored actuator (e.g. the LED):
  `safe_action` must be **absent** and the port is direct-drive. Because the flag is
  required, **omitting it is a compile error** — a motor can no longer silently lose
  its dead-man by a forgotten keyword. (The name says exactly what it gates; it reads
  truer than "floored.")
- **Verifier — validate and require.** When `has_safe_action: true`, `safe_action` is
  validated as any value-type value (every layout field present, right types) → an
  unknown field or wrong shape is a **compile error**, not a silent default; and it
  must be present. When `has_safe_action: false`, a stray `safe_action` is a compile
  error (the role and the value must agree). A genuinely non-floored actuator remains
  expressible — but as the explicit `has_safe_action: false` role, never as the absence
  of a keyword.

The net effect: the safe-state contract becomes a value the user states once, the
verifier checks, and the generator renders identically into C and into the parity
witness — and the three silent failures become loud or impossible.

## Considered options

- **Keep the float floor; make `safe_action` a closed validated atom set.** A
  closed enum (`:zero_torque | :hold | …`) the verifier checks, each mapping to a
  known float. This kills the silent-`0.0` cheaply and leaves the C floor untouched —
  but it does **not** fix multi-field floored commands (they stay unrepresentable),
  it keeps a second vocabulary (atoms) divorced from the value-type the port already
  has, and it leaves "the safe state is a float" baked in. Rejected as a stopping
  point: it treats the symptom (unknown atom) not the cause (safe action and command
  value are the same kind of thing, modeled as two different things).
- **A tagged union in the floor (`float | bytes`).** Keep a fast float path for
  scalar floors, bytes for multi-field. Rejected: two code paths in the
  safety-critical floor for a marginal simplicity/perf win — the byte path subsumes
  the float path (`N = 4`) with no measured cost, and one path is easier to verify.
- **`safe_action` names fields + their off-values (`[nm: 0.0]`).** A middle form.
  Folded into the chosen design — a value-type **value** _is_ the field-map; making
  it the value-type's own value (rather than an ad-hoc keyword list) gets the
  verifier's value-type validation for free.

## Consequences

- **The floor becomes genuinely value-type-agnostic** — truer to CONTEXT.md's
  definition ("drives the plant to its `safe_action`," never "drives a torque"). A
  servo, brake, or latching-solenoid safe state is now expressible.
- **The silent failures are gone**: unknown/under-specified `safe_action` →
  compile error; a floored port without a safe action → compile error; a multi-field
  floored command → packed correctly, not truncated.
- **Multi-stratum, hard-to-reverse change** touching the safety-critical core:
  `floor.h`/`floor.c` (float → bytes), the generator (pack + emit byte initializers),
  the verifier (validate + require), the C harness `test_floor.c`, the firmware
  `_drive` hook signature, and the test-only **VirtualHub NIF** (wraps the float
  floor today). The parity/drift witnesses extend to cover `safe_action` bytes.
- **Migration:** existing `safe_action: :zero_torque` becomes `safe_action:
%{nm: 0.0}` (or the port's value-type's zero). The example (`segby_v1`) and the
  fixture robot are updated; the drift test enforces the regeneration.
- **Not yet decided / out of scope:** this ADR fixes the safe-action contract. It
  does **not** address the related role-validation gaps surfaced in the same review
  (root-hub inferred from `Enum.min(node)`; the actuator view hard-coding
  `Effort`) — those are separate decisions.
