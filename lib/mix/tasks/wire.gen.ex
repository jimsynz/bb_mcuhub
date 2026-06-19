defmodule Mix.Tasks.Wire.Gen.Run do
  @shortdoc "Regenerate the wire artifacts (C headers, parity vectors) from the contracts + topology"

  @moduledoc """
  Regenerate every wire artifact (the C `wire_contract.h`, the per-hub
  glue/device headers, and the parity vectors) from the contracts + topology
  (§06, ADR-0003). The drift test fails the build if any committed artifact
  differs from this output, so the rule after any contract change is one command:
  `mix wire.gen` + commit.

  This is the underlying TASK; the `mix wire.gen` ALIAS wraps it to run under
  `MIX_ENV=test` (the committed test FIXTURE robot lives under test/support and is
  only compiled in :test, so generation must see the test env). Run the alias, not
  this task directly, unless you already set the env.

  Generation is ALWAYS explicit-robot (ADR-0003: no library default):

      mix wire.gen                       # all committed library robots
                                         #   (the test fixture + segby_v1)
      mix wire.gen --robot BBMcuhub.Robots.SegbyV1   # just one robot

  A consumer of the library runs `mix wire.gen --robot MyApp.MyRobot` to generate
  its own robot's artifacts without authoring any generator plumbing.
  """
  use Mix.Task

  alias BBMcuhub.Gen.WireGen

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [robot: :string])

    paths =
      case opts[:robot] do
        nil ->
          WireGen.write_all!()

        robot_str ->
          robot = Module.concat([robot_str])
          Code.ensure_loaded!(robot)
          WireGen.write_all!(robot)
      end

    Mix.shell().info("wire.gen: wrote #{length(paths)} artifact(s)")
    Enum.each(paths, &Mix.shell().info("  #{&1}"))
  end
end
