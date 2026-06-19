defmodule BBMcuhub.MixProject do
  use Mix.Project

  def project do
    [
      app: :bb_mcuhub,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      name: "bb_mcuhub",
      source_url: "https://github.com/lostbean/thunderdome"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BBMcuhub.Application, []}
    ]
  end

  # The platform lives in lib/; hubs/ and robots/ keep their Elixir beside their
  # contracts and firmware (the design's strata, §10).
  defp elixirc_paths(:test), do: base_paths() ++ ["test/support"]
  defp elixirc_paths(_), do: base_paths()

  defp base_paths do
    # Follower + the imu/motor hubs are retired (ADR-0003); the library's tests
    # are backed by the fixture robot under test/support (added by
    # elixirc_paths(:test)). segby_v1 (blaster/wheels) stays in-tree this phase
    # and moves to the example app in Phase 5.
    [
      "lib",
      "hubs/blaster/lib",
      "hubs/wheels/lib",
      "robots/segby_v1/lib"
    ]
  end

  defp deps do
    [
      # The BeamBots framework — the seam the hub views sit on (§09).
      {:bb, "~> 0.20"},
      # The host owns a UART to the root hub (§07); Circuits.UART provides the
      # framing behaviour our COBS+CRC framer implements (§03).
      {:circuits_uart, "~> 1.5"},
      # The terminal dashboard over the BeamBots seam (§09): subscribes to the
      # standard BB PubSub paths and renders safety/joints/events/commands. Wired
      # to segby via the host launcher; launched foreground (it owns stdin/stdout).
      {:bb_tui, "~> 0.1.0"},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      # Regenerate every artifact (C header, per-hub glue, parity vectors) from
      # the contracts + topology — see §06 / ADR-0003. The drift test fails the
      # build if any committed artifact differs from this output.
      #
      # The committed robots include the TEST FIXTURE (the drift/C-parity
      # witness), which lives under test/support and is compiled only in :test.
      # So generation must run in the test env to see it — `mix wire.gen` chains
      # the compile+task under MIX_ENV=test for you. Implemented by
      # `Mix.Tasks.Wire.Gen` (supports `--robot <Mod>`).
      "wire.gen": ["cmd MIX_ENV=test mix do compile + wire.gen.run"]
    ]
  end

  defp description do
    "bb_mcuhub — reach microcontroller hardware from the BeamBots ecosystem " <>
      "through one recursive abstraction: the hub. A correct framed wire, a " <>
      "fail-passive floor, clock-free freshness, and a generated contract."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"Design" => "docs/hub-design.html"}
    ]
  end
end
