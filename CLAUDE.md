# bb_mcuhub (thunderdome)

`bb_mcuhub` reaches microcontroller hardware from the BeamBots (`bb`) Elixir
ecosystem through one recursive abstraction — **the hub**. The repo has two
strata that build and test independently:

- **Elixir host** — a Mix app (`:bb_mcuhub`, `elixir ~> 1.18`) that runs on the
  board above the hub tree, owns the UART to the root hub, and exposes the
  BeamBots seam (host control, codec, scheduler, TUI dashboard).
- **C / ESP32 firmware** — under `firmware/`, built with PlatformIO (the
  `pioarduino` fork of `platform-espressif32` for arduino-esp32 3.x / ESP-IDF
  5.x). Four envs: `imu_root`, `motor_leaf`, `blaster_root`, `wheels_leaf`.

See `CONTEXT.md` for the domain glossary and `docs/hub-design.html` for the full
architecture. `design_changelog.md` tracks design decisions.

## Repository layout

- `lib/` — the platform host code (codec, host link, scheduler, application).
- `hubs/<imu|motor|blaster|wheels>/` — per-hub-type code; `lib/` holds the
  Elixir hub view, `mcu/` holds the firmware sources for that hub type.
- `robots/<follower|segby_v1>/` — robot-scoped Elixir (topology, controllers).
- `firmware/` — PlatformIO project. `src/` shared firmware, `include/` headers,
  `gen/<robot>/` robot-scoped generated artifacts (`wire_contract.h`,
  `parity_vectors.h`), `platformio.ini` the 4 envs, `test/` host-compiled C
  harnesses (built with a Makefile, no device needed).
- `test/` — Elixir tests (`mix test`).

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

| Stratum        | Command                                       |
| -------------- | --------------------------------------------- |
| Elixir host    | `mix deps.get && mix test` (or `mix compile`) |
| C test harness | `cd firmware/test && make`                    |
| ESP32 firmware | `cd firmware && pio run -e imu_root` (etc.)   |

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
