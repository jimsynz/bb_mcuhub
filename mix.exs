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
    [
      "lib",
      "hubs/imu/lib",
      "hubs/motor/lib",
      "hubs/blaster/lib",
      "hubs/wheels/lib",
      "robots/follower/lib",
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
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      # Regenerate every artifact (Elixir codec, C header, schedules, parity
      # vectors) from the contracts + topology — see §06. The drift test fails
      # the build if any committed artifact differs from this output.
      "wire.gen": ["run -e \"BBMcuhub.Gen.WireGen.write_all!()\""]
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
