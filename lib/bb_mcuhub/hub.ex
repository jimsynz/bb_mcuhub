defmodule BBMcuhub.Hub.Port do
  @moduledoc """
  One port's intrinsic wire facts (§06), as authored in a hub module's
  `ports do … end`. These are the PRODUCER facts — what the hub physically does:
  its `dir`, value `type`, sample/command `rate`, whether it carries `t_dev`, its
  `safe_action`, and the declared `sample`/`step` MFA refs.

  The MFA refs (`sample`, `step`) are **declared data only** — the host never
  invokes them; they travel into the generated per-hub schedule for the firmware.
  """

  defstruct [
    :name,
    :dir,
    :type,
    :rate,
    :safe_action,
    :sample,
    :step,
    t_dev: false,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          dir: :in | :out,
          type: atom(),
          rate: pos_integer(),
          t_dev: boolean(),
          safe_action: atom() | nil,
          sample: {module(), atom()} | nil,
          step: {module(), atom()} | nil,
          __spark_metadata__: term()
        }
end

defmodule BBMcuhub.Hub.Dsl do
  @moduledoc """
  The small Spark DSL behind `use BBMcuhub.Hub`: one `ports do … end` section
  declaring a hub's ports and their intrinsic wire facts (§06).
  """

  @port %Spark.Dsl.Entity{
    name: :port,
    describe: "One port on this hub, with its intrinsic wire facts.",
    target: BBMcuhub.Hub.Port,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "the port name on this hub"],
      dir: [type: {:in, [:in, :out]}, required: true, doc: ":in (command) or :out (produced)"],
      type: [type: :atom, required: true, doc: "the value type (a Contract.Layouts key)"],
      rate: [type: :pos_integer, required: true, doc: "nominal sample/command rate in Hz"],
      t_dev: [type: :boolean, default: false, doc: "carry the producer µs stamp (§04)"],
      safe_action: [type: :atom, doc: "the on-chip floor's safe action for a command port (§05)"],
      sample: [type: {:tuple, [:atom, :atom]}, doc: "declared {module, fun} sampler (data only)"],
      step: [type: {:tuple, [:atom, :atom]}, doc: "declared {module, fun} floor step (data only)"]
    ]
  }

  @ports %Spark.Dsl.Section{
    name: :ports,
    describe: "The ports this hub exposes on the wire.",
    entities: [@port]
  }

  use Spark.Dsl.Extension, sections: [@ports]
end

defmodule BBMcuhub.Hub.Info do
  @moduledoc """
  Read a hub module's declared ports (§06): `ports(module) :: [Hub.Port.t()]`.
  """
  use Spark.InfoGenerator, extension: BBMcuhub.Hub.Dsl, sections: [:ports]
end

defmodule BBMcuhub.Hub do
  @moduledoc """
  `use BBMcuhub.Hub` — declare one hub's ports and their intrinsic wire facts.

  A hub module is small authored data: each `port` names its `dir`, value `type`,
  `rate`, optional `t_dev`/`safe_action`, and declared `sample`/`step` MFA refs.
  The robot's BeamBots topology places the hub on a `NODE` id and names which
  ports the views read; the extension projects both into one IR (§06).

      defmodule MyHub do
        use BBMcuhub.Hub

        ports do
          port :pose, dir: :out, type: :imu, rate: 50, t_dev: true,
            sample: {MyHub.SamplePose, :sample}
        end
      end
  """
  use Spark.Dsl, default_extensions: [extensions: [BBMcuhub.Hub.Dsl]]
end
