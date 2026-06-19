# segby_v1_nerves — Nerves firmware for the segby_v1 host on a Pi Zero 2 W

A **minimal** Nerves firmware wrapper that boots the `segby_v1` example's host
(`SegbyV1.Host`) on a Raspberry Pi Zero 2 W, talking to the Blaster (the root
hub, NODE 0x02) over `/dev/ttyAMA0` at **115200 baud**.

This is its OWN Mix project (app `:segby_v1_nerves`, namespace
`SegbyV1Nerves.*`), a sibling-in-a-subdir of `examples/segby_v1/`. It is **not**
a path dep of `:segby_v1` — it depends on `:segby_v1`, never the other way
around — so it does not interfere with `cd examples/segby_v1 && mix test`.

It reuses the proven Nerves rpi0_2 config from `climber`'s `master_firmware`
(VintageNet wifi, mdns_lite, nerves_ssh, shoehorn, the custom fwup.conf +
config.txt + cmdline-{a,b}.txt that route the PL011 to ttyAMA0) and **drops** the
cog runtime, Phoenix endpoint, manifest system, and `BOT`-env parameterization.

## Dep chain (nested path deps)

From this project (`examples/segby_v1/nerves_host/`):

- `{:segby_v1, path: ".."}` → `examples/segby_v1/`
- `:segby_v1` declares `{:bb_mcuhub, path: "../.."}`, resolved relative to
  `examples/segby_v1/` → the repo root.

`:segby_v1` transitively pulls `:bb`, `:bb_tui`, and `:circuits_uart`.

## Host vs target

`SegbyV1Nerves.Application` gates the `SegbyV1.Host` child with a **compile-time**
`@target = Mix.target()` (Mix isn't available at runtime on device). On
`MIX_TARGET=host` the child is `nil` (rejected), so `iex -S mix` / `mix test`
don't try to open a non-existent UART. On target it boots:

    {SegbyV1.Host, [transport_opts: [port: "ttyAMA0", baud: 115_200]]}

## Build

Inside the repo dev shell (`nix develop`):

```sh
cd examples/segby_v1/nerves_host

# host sanity
MIX_TARGET=host mix deps.get
MIX_TARGET=host mix compile

# target compile (fetches nerves_system_rpi0_2 on first run — big)
export MIX_TARGET=rpi0_2
mix deps.get
mix compile

# firmware image — needs wifi env vars + ~/.ssh/*.pub at build time
NERVES_WIFI_SSID=... NERVES_WIFI_PSK=... mix firmware
mix firmware.burn   # or: mix upload <device>
```

The wifi SSID/PSK are read from `NERVES_WIFI_SSID` / `NERVES_WIFI_PSK` at build
time and are NEVER hardcoded. SSH authorized keys are read from `~/.ssh/*.pub`.

The device advertises itself as `segby-v1-<serial>.local` (ssh/sftp/epmd).

## Running on the bot

After flashing + boot, the host tree is already up (`SegbyV1.Host`). Attach the
dashboard from a workstation, then enable balance:

```sh
mix bb.tui --robot SegbyV1.Robot   # over ssh/console; see BB.TUI
# in iex on the device:
SegbyV1.Balance.enable(SegbyV1.Robot)
```
