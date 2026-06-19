# Host-target shim — runs when `MIX_TARGET=host` (the default).
#
# On host there is no real Pi UART, so SegbyV1.Host is NOT started (the
# Application gates it off at compile time via @target). This file only makes
# Nerves.Runtime start cleanly under `mix compile` / `iex -S mix` / CI.
import Config

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is read from UBoot-env on-device; the
       # InMemory backend lets host-mode (and CI) start cleanly.
       # https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
