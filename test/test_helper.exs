# `:characterize` tests MEASURE-and-log (e.g. CPU jitter under load) rather than
# assert a pass/fail bound — they run on demand with `--include characterize`, not
# on every suite run. See test/observer/backpressure_test.exs.
#
# capture_log: true silences runtime Logger output on PASSING tests (the suite
# deliberately crashes robots to exercise disarm, which is otherwise very noisy);
# the captured log is still printed for any test that FAILS, so failures keep
# their context. Override per-test with `@tag capture_log: false` when debugging.
ExUnit.start(exclude: [:characterize], capture_log: true)
