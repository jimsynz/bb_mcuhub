defmodule BBMcuhub.Contract.Source do
  @moduledoc """
  Loads the generator's two inputs (§06): every hub's `contract.exs` and the
  robot's topology (which hub sits on which `NODE` id).

  Contracts live beside their hub at `hubs/<hub>/contract.exs`. The topology is
  declared per robot at `robots/<robot>/topology.exs` as `%{hub => node_id}`. For
  v1's walking skeleton the active robot is `:follower` (the doc's example, with
  imu on node 0x02 and the wheel on node 0x05).

  These are read at generation time and by the drift test, so the same model that
  ships the artifacts is the one the build checks against.
  """

  @hubs_root "hubs"
  @robots_root "robots"
  @default_robot :follower

  @doc "Names of the hubs that have a contract on disk."
  @spec hubs() :: [atom()]
  def hubs do
    @hubs_root
    |> Path.join("*/contract.exs")
    |> app_glob()
    |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() |> String.to_atom() end)
    |> Enum.sort()
  end

  @doc "Every hub contract, loaded and sorted by hub name for determinism."
  @spec contracts() :: [BBMcuhub.Contract.hub_contract()]
  def contracts do
    @hubs_root
    |> Path.join("*/contract.exs")
    |> app_glob()
    |> Enum.sort()
    |> Enum.map(&load_exs!/1)
    |> Enum.sort_by(& &1.hub)
  end

  @doc "The active robot's topology: `%{hub_name => node_id}`."
  @spec topology(atom()) :: %{atom() => 0..255}
  def topology(robot \\ @default_robot) do
    [@robots_root, "#{robot}", "topology.exs"]
    |> Path.join()
    |> app_path()
    |> load_exs!()
  end

  @doc "The default robot name for v1's slice."
  @spec default_robot() :: atom()
  def default_robot, do: @default_robot

  # Evaluate an .exs file to its term. The contracts are plain data literals.
  defp load_exs!(path) do
    {term, _binding} = Code.eval_file(path)
    term
  end

  # Resolve a path relative to the app root (works under mix and in a release).
  defp app_path(rel), do: Path.join(app_root(), rel)

  defp app_glob(rel), do: rel |> app_path() |> Path.wildcard()

  defp app_root do
    # File.cwd! is the project root under `mix`; fall back to the app dir.
    File.cwd!()
  end
end
