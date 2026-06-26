# Root compile-time config (Mix auto-loads config/config.exs). Env-specific
# config lives in config/<env>.exs and is pulled in at the end.
import Config

import_config "#{config_env()}.exs"
