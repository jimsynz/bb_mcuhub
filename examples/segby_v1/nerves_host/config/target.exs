# Target-side config (everything except MIX_TARGET=host).
#
# Adapted from the proven master_firmware rpi0_2 reference, MINUS the
# Phoenix endpoint, config system, runtime, and BOT-env-var parameterization
# (this firmware builds for exactly one bot: segby_v1).
#
# The UART invariants are carried over VERBATIM via:
#   - config/fwup.conf (registered below)
#   - config/cmdline-{a,b}.txt (kernel console on tty1, NOT serial0)
#   - config/config.txt (dtoverlay=miniuart-bt, NOT disable-bt)
# These route the PL011 to GPIO 14/15 as /dev/ttyAMA0 and keep the kernel
# console off that device so SegbyV1.Host's circuits_uart owns it alone.

import Config

# Default :console handler. RingLogger is a dep (nerves_pack uses it for the
# ssh log subsystem) but :console is reachable via iex over SSH and avoids the
# `backends:` key that raises on newer logger versions.
config :logger, level: :info

# Bring core infra online before our app's children.
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Override the system's fwup.conf so we can substitute our own `config.txt` +
# `cmdline-{a,b}.txt` (which route the PL011 UART to GPIO 14/15 via
# dtoverlay=miniuart-bt and drop the kernel's `console=serial0,115200` fight for
# the same device). Without this override, fwup writes the stock files from the
# system squashfs.
config :nerves, :firmware, fwup_conf: "config/fwup.conf"

# Roll back firmware automatically if not all OTP apps come up.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit. Without ctty: "tty1" the BEAM console attaches to /dev/ttyAMA0 (the
# GPIO UART) and HDMI is silent. With this, IEx + any crash report lands on the
# HDMI framebuffer (so a UART dongle isn't required to debug first-boot
# failures). `hostname_pattern` is the LIVE mDNS name the firmware advertises —
# the device is reachable as `segby-v1-<serial>.local`.
config :nerves,
  erlinit: [
    ctty: "tty1",
    hostname_pattern: "segby-v1-%s",
    update_clock: true
  ]

# Authorized SSH keys, picked up from every ~/.ssh/*.pub at build time.
keys =
  Path.wildcard(Path.join([System.user_home!(), ".ssh", "*.pub"]))
  |> Enum.map(&File.read!/1)

if keys == [] do
  Mix.raise("""
  No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
  log into the Nerves device and update firmware over ssh.
  """)
end

config :nerves_ssh, authorized_keys: keys

# Wi-Fi via env vars at build time. Without them the Pi boots offline and we'd
# have to rely on USB-gadget or HDMI alone. SSID/PSK are NEVER hardcoded — they
# are read from the environment at build time by the coordinator.
ssid = System.get_env("NERVES_WIFI_SSID")
psk = System.get_env("NERVES_WIFI_PSK")

wlan_config =
  if ssid && psk do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            key_mgmt: :wpa_psk,
            ssid: ssid,
            psk: psk
          }
        ]
      },
      ipv4: %{method: :dhcp}
    }
  else
    IO.warn(
      "NERVES_WIFI_SSID / NERVES_WIFI_PSK not set — Wi-Fi will be unconfigured.\n" <>
        "Build with:  NERVES_WIFI_SSID=foo NERVES_WIFI_PSK=bar mix firmware"
    )

    %{type: VintageNetWiFi}
  end

config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0", wlan_config}
  ]

# mDNS — advertise segby-v1-<serial>.local for SSH + sftp + epmd (so the
# operator can reach the device by name from a workstation).
config :mdns_lite,
  hosts: [:hostname],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

# NOTE: the Pi <-> Blaster UART (device + baud) is NOT configured here. It is
# passed to SegbyV1.Host directly in SegbyV1Nerves.Application
# (transport_opts: [port: "ttyAMA0", baud: 115_200]). 115200 is the proven-good
# baud — at 1 Mbit/s the link lost ~95% of frames on this hardware. It MUST
# match the Blaster's firmware -DPI_UART_BAUD.
