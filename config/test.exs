import Config

# The suite deliberately crashes robots and tears down supervision trees to
# exercise disarm-on-crash, which makes the `bb` framework log :info/:warning
# teardown chatter from supervisor processes OUTSIDE the test's capture_log scope
# (test_helper.exs sets capture_log: true, which only reaches test-owned logs).
# Raise the floor to :error so that expected teardown noise is filtered while
# anything genuinely alarming — :error and the :critical force-disarm lines — is
# still shown. Drop this (or set :debug) when debugging a specific failure.
config :logger, level: :error
