# Root compile-time config. Mix loads this automatically (the default
# config/config.exs path). Env-specific config lives in config/<env>.exs and is
# pulled in at the end. This library ships no runtime config of its own — a
# consumer configures its own app; the only thing we set is test-suite logging.
import Config

import_config "#{config_env()}.exs"
