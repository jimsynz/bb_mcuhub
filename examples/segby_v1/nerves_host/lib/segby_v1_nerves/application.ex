defmodule SegbyV1Nerves.Application do
  @moduledoc """
  Top-level supervision tree for the segby_v1 Nerves firmware.

  Boots straight into `SegbyV1.Host` on TARGET — the self-balancing bot's host
  stack (the BeamBots tree for `SegbyV1.Robot` + the `BBMcuhub.Host.LinkOwner`
  that owns the host<->root-hub UART). On HOST it skips that child so `iex -S
  mix` / `mix compile` don't try to open a real UART that doesn't exist.

  ## Host-vs-target gating (compile-time)

  `Mix` is NOT available at runtime on the device, so the target is captured at
  COMPILE time into `@target` (`Mix.target()` runs during compilation). The
  `SegbyV1.Host` child is added ONLY when `@target != :host`. On host the child
  is `nil` and `Enum.reject(&is_nil/1)` drops it, leaving a tree that boots
  cleanly with no hardware. This mirrors the `master_firmware` reference's
  nil-child pattern, but uses a compile-time gate instead of a config-driven
  Stub transport because `SegbyV1.Host` opens a real UART (`circuits_uart`)
  with no host stub.

  ## Target boot

  On `MIX_TARGET=rpi0_2` the child is:

      {SegbyV1.Host, [transport_opts: [port: "ttyAMA0", baud: 115_200]]}

  `SegbyV1.Host` (a thin wrapper over `BBMcuhub.Host`) stands up
  `BB.Supervisor` + the `LinkOwner` over `BBMcuhub.Host.Transport.UART`, which
  opens `/dev/ttyAMA0`. 115200 baud is the proven-good Pi<->Blaster baud — at
  1 Mbit/s the link lost ~95% of frames on this hardware (see the reference's
  config/target.exs note). It MUST match the Blaster's firmware UART baud.

  ## Firmware validation (OTA auto-rollback)

  After the supervisor returns `{:ok, _}` we call `Nerves.Runtime` to mark the
  running firmware validated, so the bootloader's tryboot auto-revert stops
  reverting to the previous slot. Guarded so it no-ops on host.
  """

  use Application

  require Logger

  # Captured at COMPILE time — Mix is not available at runtime on device.
  @target Mix.target()

  @impl true
  def start(_type, _args) do
    children =
      [
        host_child()
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: SegbyV1Nerves.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup} = ok ->
        # The firmware is healthy once the HOST stack is up — validate (stops the
        # OTA auto-revert) BEFORE touching the optional TUI, so a dashboard
        # problem can never roll back a working robot.
        validate_firmware()
        # The TUI dashboard is best-effort and NON-CRITICAL: start it as a child
        # of the running supervisor, and if it fails to start just log it — never
        # abort the boot (a dead dashboard must not take down SegbyV1.Host or
        # trigger a firmware rollback).
        start_tui(sup)
        ok

      other ->
        other
    end
  end

  # The segby_v1 host stack. Only on target — on host (no ttyAMA0) we return
  # nil so the supervisor boots without trying to open a real UART.
  defp host_child do
    if @target == :host do
      nil
    else
      {SegbyV1.Host, [transport_opts: [port: "ttyAMA0", baud: 115_200]]}
    end
  end

  # Start the bb_tui dashboard as its OWN SSH daemon on port 2222 — a SEPARATE
  # listener from the nerves_ssh IEx console (port 22), so connecting to the
  # dashboard never takes over or kills the IEx session. (`BB.TUI.run/1` from the
  # IEx console is NOT viable here — it grabs the nerves_ssh console's I/O and
  # drops the whole session.) Connect with:
  #
  #     ssh tui@segby-v1-<serial>.local -p 2222     (password: segby)
  #
  # Best-effort + non-critical: a start failure is logged, never propagated, so a
  # dashboard problem can't roll back a working robot. Started under the running
  # supervisor as a :temporary child (BB.TUI.child_spec is already :temporary).
  # Host-gated like host_child/0 (no SSH daemon under `iex -S mix`).
  defp start_tui(sup) do
    if @target != :host do
      # The SSH host key must live on a WRITABLE path. `auto_host_key: true` writes
      # under the app's priv dir, which on Nerves is the read-only squashfs rootfs
      # → the daemon fails to start. Use an explicit system_dir on /data (the
      # persistent writable app partition) and ensure a host key there ourselves.
      system_dir = ensure_tui_host_key()

      spec =
        {BB.TUI,
         [
           robot: SegbyV1.Robot,
           transport: :ssh,
           port: 2222,
           system_dir: system_dir,
           auth_methods: ~c"password",
           user_passwords: [{~c"tui", ~c"segby"}]
         ]}

      case Supervisor.start_child(sup, spec) do
        {:ok, _} -> Logger.info("bb_tui dashboard on ssh port 2222 (user tui)")
        {:error, reason} -> Logger.warning("bb_tui dashboard not started: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Generate/locate the dashboard SSH daemon's host key on a writable partition.
  # Prefers /data (Nerves persistent app data); falls back to /tmp (ephemeral —
  # a fresh host key each boot, which only means clients re-accept the key).
  defp ensure_tui_host_key do
    base = if File.dir?("/data"), do: "/data", else: System.tmp_dir!()
    dir = Path.join(base, "segby_tui_ssh")

    case ExRatatui.SSH.Daemon.ensure_host_key!(dir) do
      charlist when is_list(charlist) -> to_string(charlist)
      _ -> dir
    end
  end

  # Mark the currently-running firmware validated so the bootloader's tryboot
  # auto-revert stops reverting to the previous partition. Safe on host (no-op
  # if Nerves.Runtime isn't loaded). `apply/3` so the host compiler doesn't warn
  # about Nerves.Runtime being undefined — the guard already gates the call.
  defp validate_firmware do
    if Code.ensure_loaded?(Nerves.Runtime) and
         function_exported?(Nerves.Runtime, :validate_firmware, 0) do
      try do
        apply(Nerves.Runtime, :validate_firmware, [])
        :ok
      rescue
        e ->
          Logger.warning("validate_firmware/0 failed: #{inspect(e)}")
          :ok
      end
    else
      :ok
    end
  end
end
