# Top-level config — picks host.exs or target.exs based on Mix.target().
import Config

# Enable the Nerves integration with Mix.
Application.start(:nerves_bootstrap)

config :segby_v1_nerves, target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH for reproducible builds.
# https://reproducible-builds.org/docs/source-date-epoch/
config :nerves, source_date_epoch: "1779214339"

# Use Ringlogger as the logger backend and remove :console.
# https://hexdocs.pm/ring_logger/readme.html
# (kept lightweight: on target we stick with :console so iex over SSH shows
# logs; RingLogger is still a dep nerves_pack uses for the ssh log subsystem.)

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
