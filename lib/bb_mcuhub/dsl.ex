defmodule BBMcuhub.Dsl.Hub do
  @moduledoc """
  One hub placed in the robot (§06, ADR-0006): its symbolic `name`, the hub
  `module` that declares its ports, its whole-tree-unique `node` id (§03), the
  `parent` it hangs off (another hub's name, or `:host` for the root), and the
  `uplink` transport of the link UP to that parent (`:can` | `:uart`).

  Topology is DECLARED, not inferred (ADR-0006): the tree falls out of the parent
  pointers, and a link is the edge between a hub and its parent. Transport is a
  property of the LINK, not the hub — `uplink` is the transport of THIS hub's
  link to its parent. The root declares `parent: :host`; its uplink is the host
  UART (fixed, not declared). A non-root hub declares both `parent` and `uplink`.
  """

  defstruct [:name, :module, :node, :parent, :uplink, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          node: 0..255,
          parent: atom(),
          uplink: :can | :uart | nil,
          __spark_metadata__: term()
        }
end

defmodule BBMcuhub.Dsl.IrTransformer do
  @moduledoc """
  Projects the authored model into the frozen IR (§06) at compile time.

  Reads the placed `hub` entities (`[:hubs]`), each hub module's intrinsic port
  facts (`BBMcuhub.Hub.Info.ports/1`), and the reader views nested in the BeamBots
  `topology` (sensors/actuators under links/joints). It joins them — producer
  facts from the hub module, the consumer `fresh_for` from the view that targets a
  port — into one row per port, sorted by `{node, port_id}`, and persists it under
  `:bb_mcuhub_ir`.

  Runs after BeamBots' own topology transformers so the views are fully built.
  """
  use Spark.Dsl.Transformer

  alias BBMcuhub.Contract
  alias BBMcuhub.ValueType
  alias Spark.Dsl.Transformer

  # Run after BeamBots' topology is assembled so the view child_specs are present.
  @impl true
  def after?(BB.Dsl.RobotTransformer), do: true
  def after?(BB.Dsl.TopologyTransformer), do: true
  def after?(BB.Dsl.WildcardExpansionTransformer), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    hubs = Transformer.get_entities(dsl_state, [:hubs])
    views = collect_views(Transformer.get_entities(dsl_state, [:topology]))

    rows =
      for hub <- hubs, port <- BBMcuhub.Hub.Info.ports(hub.module) do
        ir_row(hub, port, views)
      end
      |> Enum.sort_by(&{&1.node, &1.port_id})

    {:ok, Transformer.persist(dsl_state, :bb_mcuhub_ir, rows)}
  end

  # One IR row: producer facts from the hub port, the consumer window (fresh_for)
  # from the view targeting this (hub, port). Built through the IrRow constructor
  # so a malformed projection fails loud HERE (naming the (hub, port)), never as a
  # late KeyError in the generator (candidate 1).
  defp ir_row(hub, port, views) do
    BBMcuhub.Contract.IrRow.new(%{
      hub: hub.name,
      node: hub.node,
      parent: hub.parent,
      uplink: hub.uplink,
      port: port.name,
      port_id: Contract.port_id(hub.name, port.name),
      dir: port.dir,
      type: port.type,
      layout: ValueType.resolve(port.type).layout(),
      stamped: port.t_dev,
      rate: port.rate,
      fresh_for: fresh_for_for(views, hub.name, port),
      has_safe_action: port.has_safe_action,
      safe_action: port.safe_action
    })
  end

  # The consumer window the IR carries is the on-chip FLOOR window for a command
  # (:in) port — the actuator view's `fresh_for` (§04/§05). It is sourced from the
  # reader view (the producer/reader split), but only commands carry a floor; a
  # produced (:out) sensor/status port has none, so its IR `fresh_for` is nil. The
  # sensor view's own publish-freshness window stays a host-side view option and
  # never enters the wire contract.
  defp fresh_for_for(_views, _hub, %{dir: :out}), do: nil

  defp fresh_for_for(views, hub, %{name: port, dir: :in}) do
    Enum.find_value(views, fn v ->
      if v.hub == hub and v.port == port, do: v.fresh_for
    end)
  end

  # Walk the topology (links/joints, recursively) and pull every sensor/actuator
  # view's (hub, port, fresh_for). A sensor view's `:port` is the produced port;
  # an actuator view's `:port` is the command port. Status ports are read for
  # reconciliation but carry no consumer window here.
  defp collect_views(entities) do
    entities
    |> Enum.flat_map(&views_in/1)
  end

  defp views_in(%BB.Dsl.Link{sensors: sensors, joints: joints}) do
    Enum.flat_map(sensors, &view_from/1) ++ collect_views(joints)
  end

  defp views_in(%BB.Dsl.Joint{sensors: sensors, actuators: actuators, link: link}) do
    Enum.flat_map(sensors, &view_from/1) ++
      Enum.flat_map(actuators, &view_from/1) ++
      collect_views(List.wrap(link))
  end

  defp views_in(_other), do: []

  # A sensor/actuator child_spec `{module, opts}` → its (hub, port, fresh_for).
  # A bare module spec (no opts) names no hub and is skipped.
  defp view_from(%{child_spec: {_module, opts}}) when is_list(opts) do
    case Keyword.fetch(opts, :hub) do
      {:ok, hub} ->
        [%{hub: hub, port: Keyword.fetch!(opts, :port), fresh_for: Keyword.get(opts, :fresh_for)}]

      :error ->
        []
    end
  end

  defp view_from(_other), do: []
end

defmodule BBMcuhub.Dsl.Verifier do
  @moduledoc """
  Verifies the authored hub-gateway contract after IR projection (§06).

  A thin Spark adapter: it pulls the placed hubs, the projected IR, and the reader
  view refs out of the DSL state, runs the pure `BBMcuhub.Dsl.Checks.all/3`, and
  maps any returned violation into a `Spark.Error.DslError` for the offending
  module. All the check LOGIC lives in `BBMcuhub.Dsl.Checks`, which knows nothing
  about Spark and is unit-testable over plain data (candidate 3).

  Raises a `Spark.Error.DslError` on any of:

    * a sensor/actuator/status_port that names a `(hub, port)` with no IR
      producer (reader↔producer reconciliation);
    * two hubs sharing a `node`, or a reserved `node` (0x00);
    * an ill-formed topology (ADR-0006): no root / two roots / an unknown
      `parent:` / a parent cycle / a disconnected hub / a non-root missing its
      `uplink:` / a root that declares an `uplink:`;
    * a view `fresh_for` < 1;
    * a `:in` port missing `has_safe_action`, a floored port without a valid
      `safe_action` value, or a stray `safe_action`/flag where it does not belong
      (the floored-role contract, ADR-0005);
    * a `{node, port_id}` collision across IR rows;
    * a port whose frame would exceed the segmentation ceiling.
  """
  use Spark.Dsl.Verifier

  alias BBMcuhub.Dsl.Checks
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    hubs = Verifier.get_entities(dsl_state, [:hubs])
    ir = Verifier.get_persisted(dsl_state, :bb_mcuhub_ir, [])
    views = collect_view_refs(Verifier.get_entities(dsl_state, [:topology]))

    case Checks.all(hubs, ir, views) do
      :ok ->
        :ok

      {:error, %{path: path, message: message}} ->
        {:error, DslError.exception(module: module, path: path, message: message)}
    end
  end

  # Every sensor/actuator view ref naming a hub port, plus actuator status_port
  # refs — both must reconcile to a producer. These walk Spark's BB.Dsl entities,
  # so they stay HERE (Spark-coupled); the pure checks consume the plain maps.
  defp collect_view_refs(entities), do: Enum.flat_map(entities, &refs_in/1)

  defp refs_in(%BB.Dsl.Link{sensors: sensors, joints: joints}) do
    Enum.flat_map(sensors, &refs_from/1) ++ collect_view_refs(joints)
  end

  defp refs_in(%BB.Dsl.Joint{sensors: sensors, actuators: actuators, link: link}) do
    Enum.flat_map(sensors, &refs_from/1) ++
      Enum.flat_map(actuators, &refs_from/1) ++
      collect_view_refs(List.wrap(link))
  end

  defp refs_in(_other), do: []

  defp refs_from(%{child_spec: {_module, opts}}) when is_list(opts) do
    case Keyword.fetch(opts, :hub) do
      {:ok, hub} ->
        fresh_for = Keyword.get(opts, :fresh_for)

        base = [%{hub: hub, port: Keyword.fetch!(opts, :port), fresh_for: fresh_for}]

        case Keyword.fetch(opts, :status_port) do
          {:ok, status} -> [%{hub: hub, port: status, fresh_for: fresh_for} | base]
          :error -> base
        end

      :error ->
        []
    end
  end

  defp refs_from(_other), do: []
end

defmodule BBMcuhub.Dsl do
  @moduledoc """
  The hub-gateway DSL extension (§06) — composed alongside `BB.Dsl` via
  `use BB, extensions: [BBMcuhub.Dsl]`.

  It owns a sibling top-level `hubs do … end` section (the BeamBots `topology`
  section is not patchable, so hub placement lives here rather than as a patch
  into `[:topology]`). A transformer projects the placed hubs + their declared
  ports + the topology's reader views into one frozen IR; a verifier reconciles
  readers against producers and pins the wire invariants.
  """

  @hub %Spark.Dsl.Entity{
    name: :hub,
    describe: "Place a hub on a whole-tree-unique NODE id.",
    target: BBMcuhub.Dsl.Hub,
    args: [:name, :module],
    schema: [
      name: [type: :atom, required: true, doc: "the symbolic hub name"],
      module: [type: :module, required: true, doc: "the hub module (use BBMcuhub.Hub)"],
      node: [
        type: {:in, 0..255},
        required: true,
        doc: "the flat, whole-tree-unique NODE id (§03)"
      ],
      parent: [
        type: :atom,
        required: true,
        doc: "the parent hub's name, or the atom :host for the root (ADR-0006)"
      ],
      uplink: [
        type: {:in, [:can, :uart]},
        required: false,
        doc:
          "the transport of THIS hub's link to its parent (:can | :uart). Required for a non-root hub; the root's uplink is the host UART (fixed, not declared) (ADR-0006)"
      ]
    ]
  }

  @hubs %Spark.Dsl.Section{
    name: :hubs,
    describe: "The hubs this robot reaches, each placed on a NODE id.",
    entities: [@hub],
    top_level?: false
  }

  use Spark.Dsl.Extension,
    sections: [@hubs],
    transformers: [BBMcuhub.Dsl.IrTransformer],
    verifiers: [BBMcuhub.Dsl.Verifier]
end

defmodule BBMcuhub.Robot.Info do
  @moduledoc """
  Read a robot's projected hub-gateway IR (§06): `ir(robot_module) :: [ir_row]`.

  The IR is the single model the generator (`BBMcuhub.Gen.WireGen`) and the
  runtime `PortIndex` consume. It is persisted at compile time by
  `BBMcuhub.Dsl.IrTransformer`.
  """

  alias BBMcuhub.Contract

  @doc "The frozen IR rows for a robot, sorted by `{node, port_id}`."
  @spec ir(module()) :: [Contract.ir_row()]
  def ir(robot_module) do
    Spark.Dsl.Extension.get_persisted(robot_module, :bb_mcuhub_ir, [])
  end
end
