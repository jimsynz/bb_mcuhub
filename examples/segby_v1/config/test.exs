import Config

# Same as the library: the suite tears down robot supervision trees, so the `bb`
# framework logs :info/:warning teardown chatter from supervisor processes that
# lies OUTSIDE the test's capture_log scope (test_helper.exs sets capture_log:
# true). Raise the floor to :error so that expected noise is filtered while
# :error and the :critical force-disarm lines are still shown. Drop this (or set
# :debug) when debugging a specific failure.
config :logger, level: :error
