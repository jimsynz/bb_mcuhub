# bb_mcuhub (thunderdome)

`bb_mcuhub` reaches microcontroller hardware from the BeamBots (`bb`) Elixir
ecosystem through one recursive abstraction — **the hub**. The repo has two
strata that build and test independently:

- **Elixir host** — a Mix app (`:bb_mcuhub`, `elixir ~> 1.18`) that runs on the
  board above the hub tree, owns the UART to the root hub, and exposes the
  BeamBots seam (host control, codec, scheduler, TUI dashboard).
- **C / ESP32 firmware** — `firmware/` is the C chassis, packaged as a PlatformIO
  library (`library.json`) a consumer pulls via `lib_deps`. Built with the
  `pioarduino` fork of `platform-espressif32` (arduino-esp32 3.x / ESP-IDF 5.x).
  The library itself ships no deployable env; the worked example
  (`examples/segby_v1/firmware/`) has the `blaster_root` + `wheels_leaf` envs.

This repo is a **library + a worked example** (ADR-0003): `bb_mcuhub` at the root
is the reusable library; `examples/segby_v1/` is a separate Mix app that depends
on it as a downstream consumer would. See `CONTEXT.md` for the domain glossary,
`docs/hub-design.html` for the architecture, `docs/adr/` for decisions, and
`design_changelog.md` for history.

## Repository layout

Library (`bb_mcuhub`, repo root — every consumer gets this, never edits it):

- `lib/bb_mcuhub/` — host platform: `wire/`, `contract/`, `value_type/` (+ the
  `BBMcuhub.ValueType` behaviour), `dsl.ex` (the `hubs do` extension), `gen/` (the
  generator), `hub.ex`, `host.ex` (the generic launcher) + `host/`, `bb_hub/` (the
  value-type-agnostic BeamBots seam).
- `firmware/` — the C chassis (`src/`, `include/`, `src/esp32/`) + `library.json`;
  `firmware/test/` host-compiled C harnesses (Makefile, no device); `firmware/gen/robot/`
  the fixture robot's generated artifacts. NO deployable `platformio.ini`.
- `test/` — Elixir tests; `test/support/fixtures/` the coverage-maximizing fixture
  robot that lets the library self-test in isolation.

Example (`examples/segby_v1/`, app `:segby_v1`, namespace `SegbyV1.*`):

- `lib/segby_v1/` — robot, hubs, own value-types, balance, teleop, host wrapper.
- `firmware/mcu/` hand-authored device hooks; `firmware/gen/segby_v1/` GENERATED
  glue + headers; `firmware/platformio.ini` (`blaster_root`, `wheels_leaf`,
  `lib_deps` the chassis); `test/` its own suite + drift test; `BRINGUP.md`.

Everything under any `gen/` is generated + drift-tested; everything under `mcu/`
is hand-authored.

## Tooling

This repo uses a Nix-native dev setup so every git **worktree** gets the same
toolchain reproducibly. (Note: the legacy `firmware/.pio-venv` / `.pio-core` are
gitignored and the venv launcher is pinned to an absolute main-tree path, so it
does **not** work in a fresh worktree — use the devShell instead.)

- **Dev shell** — run `nix develop` from the repo root to enter a shell with
  Elixir 1.18, Erlang/OTP, PlatformIO 6.1, clang, make, and lefthook. Or let
  direnv load it automatically (`direnv allow` once). Inputs are pinned in
  `flake.lock`.
- **Formatting** — `nix fmt` formats the whole repo via treefmt (mix-format for
  Elixir, nixfmt, prettier for MD/YAML/JSON, shfmt, clang-format for C).
- **Commit gate** — a lefthook `pre-commit` hook formats staged files and
  re-stages them, so commits are always formatted. Install hooks with
  `lefthook install` (available in the devShell). If a commit reformats files,
  it still succeeds — the formatted result is what gets committed.

### Build & test (inside the dev shell)

| Stratum                | Command                                                    |
| ---------------------- | ---------------------------------------------------------- |
| Library (Elixir)       | `mix deps.get && mix test` (or `mix compile`)              |
| Library C test harness | `cd firmware/test && make`                                 |
| Example (Elixir)       | `cd examples/segby_v1 && mix deps.get && mix test`         |
| Example ESP32 firmware | `cd examples/segby_v1/firmware && pio run -e blaster_root` |

`pio run` downloads the ESP32 platform + toolchains into `PLATFORMIO_CORE_DIR`
on first use. The devShell defaults that to a **worktree-local** `.pio-core`
(gitignored) so each worktree keeps its own and never touches another tree's
core. Set `PLATFORMIO_CORE_DIR` yourself to override.

## Conventions

### Do

- Enter the dev shell (`nix develop` / direnv) before building or testing, in
  any worktree, so the toolchain is reproducible.
- Regenerate firmware/Elixir artifacts via `mix wire.gen` when contracts or
  topology change (a drift test fails the build otherwise).
- Run both strata's checks before committing: `mix test`,
  `cd firmware/test && make`, and `pio run` for the affected env.

### Don't

- **Do not add trailers, attribution, `Co-Authored-By`, or `Generated with`
  footers to commit messages.**
- Do not rely on `firmware/.pio-venv` / `.pio-core` in a worktree — they are
  main-tree-only and gitignored. Use the devShell's `pio` instead.
