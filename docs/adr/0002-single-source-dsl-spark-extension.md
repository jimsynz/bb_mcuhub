# The contract is authored in BeamBots' DSL; the hub gateway is a Spark extension

The hub-gateway library is a **Spark DSL extension to BeamBots (`bb`)**, not a
parallel configuration system. A user imports the `bb` packages plus this library
and authors **one model**: hubs are reusable modules (`use BBMcuhub.Hub`) that
declare their ports' intrinsic wire facts (`type`, `rate`, `t_dev`, `safe_action`,
the pure `sample`/`step`); the robot declares a sibling `hubs do` block (a top-level section our extension
owns, composed via `use BB, extensions: [BBMcuhub.Dsl]` — no `bb` fork) that
*places* each hub on a `NODE`, and the existing `topology do` wires its ports to
components. A
Spark **transformer** projects that assembled model into the IR row shape and
persists it; a Spark **verifier** validates it at compile time (reader↔producer
reconciliation, node-id uniqueness/reserved ids, `fresh_for` ≥ one period,
`(node,port_id)` collisions, the 512-byte frame ceiling), raising
`Spark.Error.DslError` on a violation. The earlier `hubs/*/contract.exs` files,
the `Source` loader, and `Contract.build_ir/2` are dissolved.

## Considered Options

- **Two canonical files reconciled at runtime** (the walking-skeleton state:
  `contract.exs` for producers + the BB topology for readers, checked at view
  `init/1`) — rejected: authoring the same system in two places is a sync hazard,
  and it parallels the BeamBots ecosystem instead of extending it.
- **Fold all wire facts into the BB topology** (no hub modules) — rejected: wire
  facts are device-intrinsic and must generate the C side without BeamBots in the
  loop; hub modules keep them reusable and deployment-independent.
- **A runtime boot validator** (the design's original §06 framing) — superseded:
  a compile-time verifier catches the same bugs strictly earlier (cannot ship),
  and the single model makes reader↔producer reconciliation a real check rather
  than a duplicate of the existing `resolve`.

## Consequences

- **The IR row shape is kept as a stable internal seam.** `WireGen`, `PortIndex`,
  and the parity/drift tests consume it unchanged; only its *source* moves from
  `build_ir(contracts, topology)` to a DSL projection. The C/firmware/parity side
  is untouched.
- **The library now depends on Spark's extension surface** (a top-level section,
  transformers, verifiers, InfoGenerators) composed onto `use BB` via the
  `extensions:` option. Hub *placement* is a sibling `hubs do` block rather than
  interleaved into BeamBots' `topology do`, because `bb` 0.20.3's `topology`
  section is not `patchable?` — `Spark.Dsl.Patch.AddEntity` into it is silently
  dropped, and making it patchable would mean forking `bb`. This couples the
  authoring front-end to the BeamBots/Spark version (`bb` 0.20.3) — a deliberate
  trade for composing with the ecosystem without a fork.
- **§06 checks run at compile time, not boot.** A malformed topology fails
  `mix compile`, naming the offending pair. No runtime re-check in v1
  (belt-and-suspenders boot validation is a possible later addition).
