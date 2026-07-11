# Context — segby_v1

The `segby_v1` glossary. This context is the worked example — a downstream consumer
of the [`bb_mcuhub`](../CONTEXT.md) library
([ADR-0003](../../adr/0003-library-example-split.md#adr-0003)) — so it inherits
almost all of its vocabulary from the root context: [Hub](../CONTEXT.md#term-hub),
[Component](../CONTEXT.md#term-component), [Status slot](../CONTEXT.md#term-status-slot),
[seq](../CONTEXT.md#term-seq-t-dev), [born-stale](../CONTEXT.md#term-fresh-for-born-stale),
[the floor](../CONTEXT.md#term-the-floor), and the rest apply here unchanged — this file
never redefines them, only links them. Exactly one term is owned here: it names
something that lives entirely in this example and has no library-side meaning.

## Terms

### Wheel-speed sensor · host velocity loop {#term-wheel-speed-sensor}

A wheel's **measured angular velocity** (rad/s) reported _up_ as a first-class
**sensor port** (`vel_left`/`vel_right`, value-type `WheelSpeed`, `dir: :out`) — surfaced
through the same [Component](../CONTEXT.md#term-component) view + `[:sensor | …]` topic the
IMU pose uses, so the host controller subscribes to it exactly like pose
([ADR-0009](../../adr/0009-wheel-velocity-sensor-and-host-velocity-loop.md#adr-0009)). The
firmware sources it from the FOC's closed-loop `shaft_velocity`; the sim from MuJoCo's
`qvel`. It exists so the host **balance** loop, which is otherwise open-loop on wheel
state (it targets pitch only), can run an **inner velocity loop**: operator teleop sets a
per-wheel _target speed_ and the controller adds `kv · (target − measured)` to the
per-wheel balance torque. The wheel command stays **torque** (faithful to the real
torque-voltage FOC); the velocity loop is a host control law on top — so "forward" means
a _bounded speed_, not an unbounded torque (acceleration) bias that runs the wheels away.
**Turn** is likewise closed-loop: it commands a _target yaw rate_, and a yaw-rate
controller (`kyaw · (target − gyro_z)`, the IMU's yaw rate already on the wire) drives the
differential torque so the measured yaw tracks it — self-limiting, so a sustained hard
turn can't run away (the open-loop differential-speed turn it replaced eventually toppled
the pitch-only balancer). Distinct from the [Status slot](../CONTEXT.md#term-status-slot):
that is liveness; this is measurement. This lives entirely in `segby_v1`: a consumer
value-type + ports on the stock seams
([ADR-0003](../../adr/0003-library-example-split.md#adr-0003)) — the library is
untouched.
