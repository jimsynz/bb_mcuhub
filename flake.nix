{
  # bb_mcuhub dev environment.
  #
  # Two strata live in this repo (see CONTEXT.md / docs/hub-design.html):
  #   - Elixir host code  (Mix app :bb_mcuhub, elixir ~> 1.18) — `mix test`
  #   - C / ESP32 firmware (firmware/, PlatformIO) — `pio run`, plus host-compiled
  #     C test harnesses under firmware/test/ built with a Makefile (cc/clang).
  #
  # This devShell pins both toolchains so any git worktree of this repo gets the
  # same env reproducibly — crucial because the legacy firmware/.pio-venv is
  # gitignored and its launcher hardcodes an absolute main-tree path, so it does
  # NOT exist in a fresh worktree. With this flake, `nix develop` (or direnv)
  # gives a worktree subagent `mix`, `pio`, `cc`, and `make` out of the box.
  description = "bb_mcuhub — Elixir host + ESP32 firmware dev environment";

  inputs = {
    # nixos-unstable: it ships the exact toolchain versions this project targets
    # — elixir 1.18.4 (~> 1.18), platformio 6.1.19 (matches the .pio-venv core),
    # clang 21.x, lefthook. (Switch to "nixos-25.05" for the stable channel.)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # treefmt config — one formatter per language in the repo.
        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";

          programs.mix-format.enable = true; # Elixir — uses .formatter.exs
          programs.nixfmt.enable = true; # Nix — RFC-style (official)
          programs.prettier.enable = true; # Markdown / YAML / JSON
          programs.shfmt.enable = true; # Shell
          programs.clang-format.enable = true; # C / C++ firmware

          settings.global.excludes = [
            "_build/**"
            "deps/**"
            ".pio/**"
            ".pio-core/**"
            ".pio-venv/**"
            "firmware/.pio/**"
            "docs/**/*.html" # generated design docs — leave untouched
            "*.lock"
            "mix.lock"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # --- Elixir host stratum ---
            elixir # 1.18.x — satisfies elixir ~> 1.18
            erlang # OTP — the BEAM the host runs on

            # --- C / ESP32 firmware stratum ---
            platformio # `pio run` for the 4 ESP32 envs (6.1.x)
            clang # cc/clang for firmware/test host harnesses
            gnumake # `cd firmware/test && make`

            # --- shared dev tooling ---
            lefthook # pre-commit format gate (run `lefthook install`)
            git
          ];

          # PlatformIO downloads its platform/toolchains into PLATFORMIO_CORE_DIR
          # at first `pio run`. Default it to a worktree-local, gitignored path so
          # each worktree keeps its own core dir and never touches the main tree's
          # .pio-core. The existing manual workflow that sets PLATFORMIO_CORE_DIR
          # explicitly still wins (we only set it if unset).
          shellHook = ''
            export PLATFORMIO_CORE_DIR="''${PLATFORMIO_CORE_DIR:-$PWD/.pio-core}"
            echo "bb_mcuhub devShell: elixir $(elixir --version | tail -1 | cut -d' ' -f2), $(pio --version)"
            echo "  PLATFORMIO_CORE_DIR=$PLATFORMIO_CORE_DIR"
          '';
        };

        # `nix fmt` runs treefmt across the repo.
        formatter = treefmtEval.config.build.wrapper;

        # `nix flake check` verifies everything is formatted.
        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
