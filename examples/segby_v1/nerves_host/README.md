# segby_v1_nerves — Nerves firmware for the segby_v1 host on a Pi Zero 2 W

A **minimal** Nerves firmware wrapper that boots the `segby_v1` example's host
(`SegbyV1.Host`) on a Raspberry Pi Zero 2 W, talking to the Blaster (the root
hub, NODE 0x02) over `/dev/ttyAMA0` at **115200 baud**.

This is its OWN Mix project (app `:segby_v1_nerves`, namespace
`SegbyV1Nerves.*`), a sibling-in-a-subdir of `examples/segby_v1/`. It is **not**
a path dep of `:segby_v1` — it depends on `:segby_v1`, never the other way
around — so it does not interfere with `cd examples/segby_v1 && mix test`.

It is a focused Nerves rpi0_2 config (VintageNet wifi, mdns_lite, nerves_ssh,
shoehorn, the custom fwup.conf + config.txt + cmdline-{a,b}.txt that route the
PL011 to ttyAMA0) — just the network + OTA + ssh stack, with no web endpoint,
config system, or multi-bot parameterization. Besides the host it auto-starts
the observer plane and serves the **bb_tui dashboard as its own SSH daemon on
port 2222** (see "Running on the bot").

**The #1 field trap, hardware-verified:** on Nerves the PL011 lands on
`ttyAMA0` via `dtoverlay=miniuart-bt` — **not** `disable-bt`, which silently
renames it to `ttyAMA1` (and keep `console=tty1` so the kernel console doesn't
claim the UART). The shipped `config.txt`/`cmdline-{a,b}.txt` already encode
this; copy them rather than a Raspberry-Pi-OS recipe.

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

Inside the repo dev shell (`nix develop` — it already ships `fwup`,
`squashfs-tools`, and `xz`; install the Nerves archive once with
`mix archive.install hex nerves_bootstrap`):

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

After flashing + boot, the host tree is already up (`SegbyV1.Host`), and the
firmware serves the bb_tui dashboard itself as an SSH daemon:

```sh
# the dashboard (its own SSH daemon on port 2222):
ssh tui@segby-v1-<serial>.local -p 2222     # password: segby

# IEx on the device (port 22, key auth), e.g. to enable balance:
ssh segby-v1-<serial>.local
iex> SegbyV1.Balance.enable(SegbyV1.Robot)
```

(A `mix bb.tui` run from a workstation is a separate BEAM node with no robot
tree in it — it cannot attach; the port-2222 daemon is the supported path.)

See [`../BRINGUP.md`](../BRINGUP.md) for the staged hardware bring-up and
[`../README.md`](../README.md) for the example overview.
