# capture_log: true silences runtime Logger output on PASSING tests (the suite
# tears down robot supervision trees, which is otherwise noisy); the captured log
# is still printed for any test that FAILS. config/test.exs additionally filters
# the framework's supervisor-teardown logs (outside this capture scope) to :error.
ExUnit.start(capture_log: true)
