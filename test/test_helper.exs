# `:characterize` tests MEASURE-and-log (e.g. CPU jitter under load) rather than
# assert a pass/fail bound — they run on demand with `--include characterize`, not
# on every suite run. See test/observer/backpressure_test.exs.
ExUnit.start(exclude: [:characterize])
