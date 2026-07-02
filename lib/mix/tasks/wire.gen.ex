defmodule Mix.Tasks.Wire.Gen.Run do
  @shortdoc "Regenerate the wire artifacts (C headers, parity vectors) from the contracts + topology"

  @moduledoc """
  Regenerate every wire artifact (the C `wire_contract.h`, the per-hub
  glue/device headers, and the parity vectors) from the contracts + topology.
  The drift test fails the build if any committed artifact differs from this
  output, so the rule after any contract change is one command:
  `mix wire.gen` + commit.

  This is the underlying TASK; the `mix wire.gen` ALIAS wraps it to run under
  `MIX_ENV=test` (the committed test FIXTURE robot lives under test/support and is
  only compiled in :test, so generation must see the test env). Run the alias, not
  this task directly, unless you already set the env.

  Generation is ALWAYS explicit-robot (there is no library-default robot):

  ```sh
  mix wire.gen                       # all committed library robots
                                     #   (the test fixture)
  mix wire.gen --robot BBMCUHub.Test.Fixtures.Robot   # just one robot
  ```

  ## Output base — each app generates into its own tree

  By default the artifacts land cwd-relative under `firmware/gen/<slug>/` (the C
  headers + glue) and `test/fixtures/<slug>/parity_vectors.exs` (the parity
  fixture) — the library's own tree. A downstream consumer overrides the base so
  generation lands in ITS tree, not the library's:

  ```sh
  mix wire.gen.run --robot MyApp.MyRobot \\
    --gen-dir firmware/gen --fixtures-dir test/fixtures
  ```

  `--gen-dir` / `--fixtures-dir` are resolved relative to the cwd the task runs in
  (i.e. the consumer app's root), so a consumer's `mix.exs` can add a `wire.gen`
  alias wrapping this with its own robot + base (see `examples/segby_v1/mix.exs`).
  A consumer thus runs generation without authoring any generator plumbing.
  """
  # Design: ADR-0003 (library/example split) is why generation is explicit-robot
  # and why each app generates into its own tree; the model itself is §06 of
  # docs/hub-design.html.
  use Mix.Task

  alias BBMCUHub.Gen.WireGen

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [robot: :string, gen_dir: :string, fixtures_dir: :string, slug: :string]
      )

    base = base_from(opts)

    paths =
      case opts[:robot] do
        nil ->
          # No explicit robot: generate every committed LIBRARY robot into the
          # default (library) tree. The base flags are consumer-only, so they are
          # ignored on this path (the library has its own fixed tree).
          WireGen.write_all!()

        robot_str ->
          robot = Module.concat([robot_str])
          Code.ensure_loaded!(robot)
          WireGen.write_all!(robot, base)
      end

    Mix.shell().info("wire.gen: wrote #{length(paths)} artifact(s)")
    Enum.each(paths, &Mix.shell().info("  #{&1}"))
  end

  # Build the output-base from the flags, defaulting each leg to the library's own
  # tree (so `--robot` alone behaves exactly as before). A path like "firmware/gen"
  # splits into the segment list WireGen joins with the slug.
  defp base_from(opts) do
    default = WireGen.default_base()

    base = %{
      gen: split_or(opts[:gen_dir], default.gen),
      fixtures: split_or(opts[:fixtures_dir], default.fixtures)
    }

    # An optional pinned slug (the per-robot artifact dir name) for a consumer
    # whose robot module's last segment is generic (e.g. SegbyV1.Robot → "robot").
    case opts[:slug] do
      nil -> base
      slug -> Map.put(base, :slug, slug)
    end
  end

  defp split_or(nil, default), do: default
  defp split_or(path, _default), do: Path.split(path)
end
