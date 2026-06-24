# Used by "mix format".
#
# The generated parity-vector fixtures are EXCLUDED: the generator's output is
# canonical (the drift test asserts the committed file equals what the emitter
# produces NOW), so reformatting them silently breaks that test. This mirrors the
# treefmt exclusion in flake.nix (`test/fixtures/**/parity_vectors.exs`), so a
# bare `mix format` behaves the same as `nix fmt` / the commit gate.
[
  inputs:
    ["{mix,.formatter}.exs", "{config,lib}/**/*.{ex,exs}"] ++
      (Path.wildcard("test/**/*.{ex,exs}") --
         Path.wildcard("test/fixtures/**/parity_vectors.exs"))
]
