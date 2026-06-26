import Config

# No prod-specific config — a consumer configures its own app; the library ships
# no runtime config of its own. This file exists so config/config.exs's
# `import_config "#{config_env()}.exs"` resolves in :prod.
