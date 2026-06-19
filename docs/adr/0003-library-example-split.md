# `bb_mcuhub` is a reusable library; `segby_v1` is a consumer example

The hub gateway is split into a **publishable library** (`:bb_mcuhub`, at the repo
root) and a **separate example application** (`:segby_v1`, at `examples/segby_v1/`)
that depends on the library exactly as a real downstream consumer would — a Mix
`path` dependency on the host side, a PlatformIO `lib_deps` dependency on the
firmware side. The example owns its own root namespace (`SegbyV1.*`) and only
references `BBMcuhub.*` for library seams. The library carries the machinery (wire,
floor, freshness, segmentation, the DSL, the generator, the host runtime, the C
chassis); the consumer supplies only device-specific logic. The boundary is the
product: if the example can't be built cleanly _as a consumer_, the library has
failed its purpose.

Two design choices give the boundary teeth, and are the reason this is recorded:

**A value-type is the extensibility spine (`use BBMcuhub.ValueType`).** A kind of
wire value (`imu`, `effort`, …) is a standalone, cross-bot-reusable module owning
its `layout` (the ordered `{field, wire_type}` list), its host `lift`/`unlift`
(raw field-map ↔ `BB.Message`), _and_ the firmware-hook signature for ports of its
shape. A port names its value-type by module; the IR carries the resolved layout,
so the C struct, the Elixir codec, and the parity bytes all derive from one
declaration. The library ships a lean stock set — `imu`, `effort`, `status` — and a
consumer adds their own value-type in their own project with **no library edit**.
The example proves this by defining its own `Range` and `Led` value-types rather
than relying on stock ones; the library's test fixture defines its own custom type
too. The extension seam is thus exercised — and CI-validated — by construction on
both sides, never merely documented.

**The firmware per-hub glue is generated from the IR; the user writes only device
hooks (Shape 1).** The generator emits all mechanical wiring — router table,
`hub_on_body`, command dispatch, the floor init/`on_command`/`control_tick`/status
plumbing, the schedule + `hub_tasks` — into `<app>/firmware/gen/<slug>/`. The user
implements only `<hub>_device_setup()` plus per-port `<hub>_<port>_read`/`_drive`
hooks (signatures owned by the value-type) under `<app>/firmware/mcu/`, giving a
clean on-disk split: everything under `gen/` is generated and drift-tested,
everything under `mcu/` is hand-authored. Because the glue is generated _from the
IR_, a user-defined hub is wired identically to a stock one — a device hook is
never hand-glued, and the safety-critical seq/floor plumbing cannot be miswired
per hub.

## Considered Options

- **One app, example inside the library namespace** (the pre-split state:
  `hubs/*`, `robots/follower`, `BBMcuhub.Robots.SegbyV1`, `BBMcuhub.Segby.Balance`
  all compiled into `:bb_mcuhub`) — rejected: the example tangled into the library
  namespace models the wrong thing and can't prove the import boundary.
- **Value-types as a library-internal map** (today's `Contract.Layouts`) — rejected:
  a closed map means a consumer can't add a wire type without forking the library.
  Authoring the layout inline in a hub's DSL (a `value_types` block) was also
  rejected — it buries a reusable, cross-bot unit inside one non-reusable hub and
  nests the DSL; a value-type is independent of any hub, so it is its own unit.
- **Firmware glue via header-only macros** (a `BB_ACTUATOR(...) { ... }` DSL in C)
  — rejected: macros would put a second source of the wiring in C, re-creating the
  two-models-that-must-agree problem ADR-0002 was written to eliminate. The
  generator (driven by the one authored model) is the single authority.
- **Firmware glue via a registered `HubDevice` vtable** (Shape 2 — a struct of
  function pointers the device file fills) — deferred, not rejected: it buys
  runtime device-swap and host-mocked hubs at the cost of per-file boilerplate
  (a `switch (port)` and a registration call) that fixed per-hub firmware doesn't
  need. Shape 1 (well-known link-time hook names) does not preclude adding it later.
- **Example consumes the C chassis via relative `build_src_filter` globs**
  (`+<../../firmware/src/...>`) — rejected in favour of packaging the library's
  `firmware/` as a self-contained PlatformIO library (`library.json`) the example
  pulls via `lib_deps`. Only the packaged form mirrors the real downstream story
  (a hex consumer has no known relative path to the chassis); the path-dep now
  becomes a registry dep later with no change to the example's build shape.

## Consequences

- **The library is self-testing in isolation.** Follower is retired entirely
  (robot + the imu/motor hubs + their generated artifacts); a fresh,
  coverage-maximizing **fixture robot** under `test/support/` backs the drift +
  C-parity witnesses, spanning both transports, stamped/unstamped headers, the
  actuator floor, and a custom value-type. `cd` into the library and `mix test`
  proves the wire and the extension seam without the example present.
- **Generation is always explicit-robot.** The `@default_robot` defaults in
  `WireGen` and `PortIndex` (which pointed at the now-external Follower) are
  removed; `WireGen` takes an explicit output-base so each app generates into its
  own tree (the library's fixture into the library's test area, the example into
  `examples/segby_v1/firmware/gen/`). The library ships `mix wire.gen --robot
<Mod>` so a consumer runs generation without authoring generator plumbing.
- **The host view becomes value-type-agnostic.** The hard-coded per-atom lift
  dispatch (`lift(:imu, …)` → `BBHub.Lift`) is replaced by delegation to the
  port's value-type module (`type_module.lift/unlift`); `BBHub.Lift`'s functions
  move into the stock value-type modules. A consumer's own value-type surfaces
  through the same `BBHub.Sensor`/`Actuator` views unchanged.
- **A generic host launcher moves into the library.** `BBMcuhub.Host` takes
  `robot:` and derives the command slots from that robot's IR, wiring the standard
  `BB.Supervisor` + `LinkOwner` tree — so a consumer no longer hand-writes the
  slot-resolution supervisor. The example's `Host` shrinks to a thin wrapper.
- **Generation stays manual + drift-tested.** Artifacts live in git (firmware is
  reviewable) and the drift test fails CI if a contract moved without a regen — no
  compile-time auto-generation. The one-step rule after any contract change:
  `mix wire.gen` + commit.
