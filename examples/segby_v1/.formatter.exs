# Used by `mix format` / the `ci` alias's `format --check-formatted` step. The
# generated parity-vector fixtures are EXCLUDED (the generator's output is
# canonical — the drift test asserts the committed file equals what the emitter
# produces now), mirroring the library's .formatter.exs and the treefmt exclusion
# in flake.nix.
[
  inputs:
    ["{mix,.formatter}.exs", "{config,lib}/**/*.{ex,exs}"] ++
      (Path.wildcard("test/**/*.{ex,exs}") --
         Path.wildcard("test/fixtures/**/parity_vectors.exs"))
]
