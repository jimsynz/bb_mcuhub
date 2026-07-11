# Context map — bb_mcuhub

Two bounded contexts. `bb_mcuhub` is the reusable library — the hub gateway
itself. `segby_v1` is a worked example consuming it exactly as a downstream
project would ([ADR-0003](adr/0003-library-example-split.md#adr-0003)).

## Contexts

| Context     | Design                                          | Glossary                                          | Owns                                                                                                                                                                                            |
| ----------- | ----------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bb_mcuhub` | [design.md](design/design.md)                   | [CONTEXT.md](design/CONTEXT.md)                   | The hub abstraction, the wire, the generated contract, freshness/the floor, the host runtime, the BeamBots seam, the observability plane, the virtual-robot sim seam, and the firmware chassis. |
| `segby_v1`  | [segby_v1/design.md](design/segby-v1/design.md) | [segby_v1/CONTEXT.md](design/segby-v1/CONTEXT.md) | One real robot instantiated on the library: its hubs, its balance/teleop control loops, the wheel-speed velocity loop, its MuJoCo plant, and its Nerves deployment.                             |

## Relationships

**`segby_v1` is a customer/conformist of `bb_mcuhub`** (DDD vocabulary,
one-directional): `segby_v1` conforms entirely to the contract and DSL
surface `bb_mcuhub` publishes — `BBMCUHub.Hub`, `BBMCUHub.ValueType`,
`BBMCUHub.Dsl`, `BBMCUHub.Host`, `BBMCUHub.BBHub.{Sensor,Actuator}`,
`BBMCUHub.Sim.{Plant,Transport,Driver}` — and adapts itself to that surface
rather than the library bending to fit `segby_v1`. There is no
anti-corruption layer between them: `segby_v1` references `BBMCUHub.*`
directly at every seam, because the library's public API _is_ the seam, not
something to be translated. The dependency arrow points only one way —
library ← example — enforced structurally (a Mix `path` dependency on the
host side, a PlatformIO `lib_deps` dependency on the firmware side); nothing
in `bb_mcuhub` references `SegbyV1.*`.

A **shared term** (e.g. [Component](design/CONTEXT.md#term-component),
[Status slot](design/CONTEXT.md#term-status-slot),
[born-stale](design/CONTEXT.md#term-fresh-for-born-stale)) is owned by
`bb_mcuhub` and linked from `segby_v1`, never redefined there. Exactly one
term is owned by `segby_v1` itself: [Wheel-speed sensor · host velocity
loop](design/segby-v1/CONTEXT.md#term-wheel-speed-sensor) — it names
something with no library-side meaning.

## Reading order

Start at [`design/design.md`](design/design.md) for the library's own
foundation and structure. [`design/segby-v1/design.md`](design/segby-v1/design.md)
assumes that context and cross-links back to it throughout — it does not
restate the library's vocabulary. [`COVERAGE.md`](COVERAGE.md) maps every
part of the repository to its design status.
