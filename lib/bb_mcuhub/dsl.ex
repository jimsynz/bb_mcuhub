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
  # from the view targeting this (hub, port).
  defp ir_row(hub, port, views) do
    %{
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
    }
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

  alias BBMcuhub.Contract
  alias BBMcuhub.Contract.Layouts
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  # Matches the C SEG_MAX_BODY in firmware/include/segment.h.
  @segmentation_ceiling 512

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    hubs = Verifier.get_entities(dsl_state, [:hubs])
    ir = Verifier.get_persisted(dsl_state, :bb_mcuhub_ir, [])
    views = collect_view_refs(Verifier.get_entities(dsl_state, [:topology]))

    with :ok <- verify_nodes(hubs, module),
         :ok <- verify_topology(hubs, module),
         :ok <- verify_fresh_for(views, module),
         :ok <- verify_safe_actions(ir, module),
         :ok <- verify_command_messages(ir, module),
         :ok <- verify_reconciliation(views, ir, module),
         :ok <- verify_no_id_collision(ir, module),
         :ok <- verify_frame_sizes(ir, module) do
      :ok
    end
  end

  # The agnostic-Component contract (finding #1), per command port: every `dir: :in`
  # (command) port's value-type MUST name the `BB.Message` command struct it accepts
  # via `command_message/0` (non-nil). The actuator view derives its PubSub subscribe
  # from that struct, so a sense value-type (which leaves command_message nil) on a
  # command port would silently subscribe to `nil` and never receive a command — a
  # misconfiguration the verifier catches at compile time, not at runtime.
  defp verify_command_messages(ir, module) do
    Enum.reduce_while(ir, :ok, fn row, :ok ->
      case verify_command_message(row, module) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_command_message(%{dir: :in} = row, module) do
    if is_nil(BBMcuhub.ValueType.resolve(row.type).command_message()) do
      error(
        module,
        [:hubs, row.hub],
        "command port #{inspect({row.hub, row.port})} uses value-type #{inspect(row.type)} which declares no command_message — a command value-type must name the BB.Message struct it accepts (finding #1 / agnostic Component)"
      )
    else
      :ok
    end
  end

  defp verify_command_message(%{dir: :out}, _module), do: :ok

  # The floored-role contract (ADR-0005), per port:
  #
  #   * a :in (command) port MUST declare `has_safe_action` (true or false);
  #   * has_safe_action: true ⇒ `safe_action` present AND a valid value of the
  #     port's value-type (every layout field present, numeric — the codec packs
  #     it; an unknown/missing/ill-typed field is a compile error, not a silent
  #     default);
  #   * has_safe_action: false ⇒ `safe_action` MUST be absent;
  #   * a :out (produced) port carries NEITHER (the flag is meaningless there).
  defp verify_safe_actions(ir, module) do
    Enum.reduce_while(ir, :ok, fn row, :ok ->
      case verify_safe_action(row, module) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_safe_action(%{dir: :out} = row, module) do
    cond do
      not is_nil(row.has_safe_action) ->
        error(
          module,
          [:hubs, row.hub],
          "produced port #{inspect({row.hub, row.port})} declares has_safe_action — it is meaningless on a :out port; remove it (ADR-0005)"
        )

      not is_nil(row.safe_action) ->
        error(
          module,
          [:hubs, row.hub],
          "produced port #{inspect({row.hub, row.port})} declares a safe_action — only a floored :in port has one (ADR-0005)"
        )

      true ->
        :ok
    end
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: nil} = row, module) do
    error(
      module,
      [:hubs, row.hub],
      "command port #{inspect({row.hub, row.port})} must declare has_safe_action (true ⇒ floored with a safe_action; false ⇒ non-floored) — omitting it would silently drop the dead-man (ADR-0005)"
    )
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: false} = row, module) do
    if is_nil(row.safe_action) do
      :ok
    else
      error(
        module,
        [:hubs, row.hub],
        "command port #{inspect({row.hub, row.port})} is has_safe_action: false (non-floored) but declares a safe_action — the role and the value must agree; drop the safe_action or set has_safe_action: true (ADR-0005)"
      )
    end
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: true} = row, module) do
    cond do
      is_nil(row.safe_action) ->
        error(
          module,
          [:hubs, row.hub],
          "command port #{inspect({row.hub, row.port})} is has_safe_action: true (floored) but declares no safe_action — a floored port MUST give a safe action value (ADR-0005)"
        )

      true ->
        validate_safe_value(row, module)
    end
  end

  # The safe_action must be a valid value of the port's value-type: every field
  # in the layout present with a numeric value (the same shape the codec packs to
  # the wire). We validate explicitly for a clear message, then trial-pack via the
  # real codec so an ill-typed value (e.g. a non-number) is caught by the same
  # encoder the bytes go through (ADR-0005: no separate translation layer).
  defp validate_safe_value(row, module) do
    layout_fields = Enum.map(row.layout, fn {field, _wt} -> field end)
    given_fields = Map.keys(row.safe_action)

    missing = layout_fields -- given_fields
    extra = given_fields -- layout_fields

    cond do
      missing != [] ->
        error(
          module,
          [:hubs, row.hub],
          "safe_action for #{inspect({row.hub, row.port})} is missing field(s) #{inspect(missing)} of its #{inspect(row.type)} value-type (ADR-0005)"
        )

      extra != [] ->
        error(
          module,
          [:hubs, row.hub],
          "safe_action for #{inspect({row.hub, row.port})} has unknown field(s) #{inspect(extra)} not in its #{inspect(row.type)} value-type layout (ADR-0005)"
        )

      true ->
        try do
          _ = BBMcuhub.Wire.Codec.encode_fields(row.layout, row.safe_action)
          :ok
        rescue
          e ->
            error(
              module,
              [:hubs, row.hub],
              "safe_action for #{inspect({row.hub, row.port})} is not a valid #{inspect(row.type)} value — #{Exception.message(e)} (ADR-0005)"
            )
        end
    end
  end

  # No two hubs share a node; no hub uses the reserved broadcast id (0x00).
  defp verify_nodes(hubs, module) do
    reserved = Contract.broadcast_node()

    with :ok <- check_reserved(hubs, reserved, module) do
      hubs
      |> Enum.group_by(& &1.node)
      |> Enum.find(fn {_node, group} -> length(group) > 1 end)
      |> case do
        nil ->
          :ok

        {node, group} ->
          names = group |> Enum.map(& &1.name) |> Enum.sort()

          error(
            module,
            [:hubs],
            "hubs #{inspect(names)} share node 0x#{hex2(node)} — node ids must be whole-tree unique (§03)"
          )
      end
    end
  end

  defp check_reserved(hubs, reserved, module) do
    case Enum.find(hubs, &(&1.node == reserved)) do
      nil ->
        :ok

      hub ->
        error(
          module,
          [:hubs, hub.name],
          "hub #{inspect(hub.name)} uses reserved node 0x#{hex2(reserved)} (broadcast/e-stop, §03)"
        )
    end
  end

  # The tree is well-formed (ADR-0006): topology is DECLARED by parent links, not
  # inferred from node ids. Each violation names the offending hub:
  #
  #   * EXACTLY ONE hub declares `parent: :host` (the root). Zero → no root;
  #     two+ → name them.
  #   * the root MUST NOT declare an `uplink:` (its uplink is the host UART).
  #   * every NON-root hub declares an `uplink:` (the transport of its parent
  #     link), and its `parent:` names a DECLARED hub.
  #   * NO cycles in the parent pointers; every hub is CONNECTED (reaches the
  #     root by following parents).
  @host :host
  defp verify_topology(hubs, module) do
    names = MapSet.new(hubs, & &1.name)
    roots = Enum.filter(hubs, &(&1.parent == @host))

    with :ok <- verify_one_root(roots, hubs, module),
         :ok <- verify_root_uplink(roots, module),
         :ok <- verify_parents_resolve(hubs, names, module),
         :ok <- verify_nonroot_uplinks(hubs, module),
         :ok <- verify_no_cycles(hubs, module) do
      :ok
    end
  end

  defp verify_one_root([_one], _hubs, _module), do: :ok

  defp verify_one_root([], _hubs, module) do
    error(
      module,
      [:hubs],
      "no root: a hub must declare parent: :host — the root owns the host link (ADR-0006)"
    )
  end

  defp verify_one_root(roots, _hubs, module) do
    names = roots |> Enum.map(& &1.name) |> Enum.sort()

    error(
      module,
      [:hubs],
      "two+ roots: hubs #{inspect(names)} each declare parent: :host — exactly one hub may be the root (ADR-0006)"
    )
  end

  # The root's uplink is the host UART (fixed). Declaring one is a contradiction.
  defp verify_root_uplink(roots, module) do
    case Enum.find(roots, &(not is_nil(&1.uplink))) do
      nil ->
        :ok

      hub ->
        error(
          module,
          [:hubs, hub.name],
          "root hub #{inspect(hub.name)} declares uplink: #{inspect(hub.uplink)} — the root's uplink is the host UART, not declared (ADR-0006)"
        )
    end
  end

  # Every non-:host parent names a DECLARED hub.
  defp verify_parents_resolve(hubs, names, module) do
    case Enum.find(hubs, &(&1.parent != @host and not MapSet.member?(names, &1.parent))) do
      nil ->
        :ok

      hub ->
        error(
          module,
          [:hubs, hub.name],
          "hub #{inspect(hub.name)} names parent #{inspect(hub.parent)}, which is not a declared hub (ADR-0006)"
        )
    end
  end

  # Every NON-root hub declares an uplink (the transport of its parent link).
  defp verify_nonroot_uplinks(hubs, module) do
    case Enum.find(hubs, &(&1.parent != @host and is_nil(&1.uplink))) do
      nil ->
        :ok

      hub ->
        error(
          module,
          [:hubs, hub.name],
          "non-root hub #{inspect(hub.name)} (parent #{inspect(hub.parent)}) declares no uplink — a non-root hub must declare its parent-link transport (:can | :uart) (ADR-0006)"
        )
    end
  end

  # No cycles: following parent pointers from each hub must reach :host without
  # revisiting a hub. A revisit (or a non-resolving parent we don't error on here
  # because verify_parents_resolve already did) means a cycle. This also asserts
  # CONNECTEDNESS — a hub that loops never reaches :host.
  defp verify_no_cycles(hubs, module) do
    by_name = Map.new(hubs, &{&1.name, &1})

    Enum.reduce_while(hubs, :ok, fn hub, :ok ->
      case walk_to_host(hub, by_name, MapSet.new()) do
        :ok ->
          {:cont, :ok}

        {:cycle, chain} ->
          {:halt,
           error(
             module,
             [:hubs, hub.name],
             "parent cycle through #{inspect(chain)} — following parents never reaches :host (ADR-0006)"
           )}
      end
    end)
  end

  # Follow parents to :host. A hub already on the path → a cycle (report it). A
  # parent not in the map can only be :host here (verify_parents_resolve ran), so
  # reaching :host or an unresolved parent both terminate the walk cleanly.
  defp walk_to_host(%{parent: @host}, _by_name, _seen), do: :ok

  defp walk_to_host(%{name: name, parent: parent}, by_name, seen) do
    cond do
      MapSet.member?(seen, name) ->
        {:cycle, seen |> MapSet.put(name) |> Enum.sort()}

      true ->
        case Map.fetch(by_name, parent) do
          {:ok, parent_hub} -> walk_to_host(parent_hub, by_name, MapSet.put(seen, name))
          # parent unresolved (already errored by verify_parents_resolve) — stop.
          :error -> :ok
        end
    end
  end

  # Every view declares a freshness window of at least one beat.
  defp verify_fresh_for(views, module) do
    case Enum.find(views, fn v -> not is_nil(v.fresh_for) and v.fresh_for < 1 end) do
      nil ->
        :ok

      v ->
        error(
          module,
          [:topology],
          "view for #{inspect({v.hub, v.port})} has fresh_for #{v.fresh_for} — must be >= 1 (§04)"
        )
    end
  end

  # Every (hub, port) a view names resolves to exactly one IR producer.
  defp verify_reconciliation(views, ir, module) do
    producers = MapSet.new(ir, &{&1.hub, &1.port})

    case Enum.find(views, fn v -> not MapSet.member?(producers, {v.hub, v.port}) end) do
      nil ->
        :ok

      v ->
        error(
          module,
          [:topology],
          "view names #{inspect({v.hub, v.port})} but no hub declares that port (§06)"
        )
    end
  end

  # No two IR rows share a wire identity (node, port_id).
  defp verify_no_id_collision(ir, module) do
    ir
    |> Enum.group_by(&{&1.node, &1.port_id})
    |> Enum.find(fn {_key, rows} -> length(rows) > 1 end)
    |> case do
      nil ->
        :ok

      {{node, port_id}, rows} ->
        pairs = rows |> Enum.map(&{&1.hub, &1.port}) |> Enum.sort()

        error(
          module,
          [:hubs],
          "wire id {0x#{hex2(node)}, 0x#{hex2(port_id)}} collides across #{inspect(pairs)} (§03)"
        )
    end
  end

  # Every port's framed value fits under the segmentation ceiling. This is a
  # CAN-only invariant: the 512-byte ceiling is the segmentation budget (§03). A
  # :uart link carries arbitrary-length bodies in one COBS frame (no
  # fragmentation), so its ports are exempt. A port's frames traverse its hub's
  # uplink (toward the parent); the root's uplink is the host UART (uplink == nil
  # ⇒ never segmented). So a port is CAN-budgeted iff its hub's uplink is :can
  # (ADR-0006: transport is a property of the link, not the hub).
  defp verify_frame_sizes(ir, module) do
    can_rows = Enum.filter(ir, &(&1.uplink == :can))

    case Enum.find(can_rows, fn row -> frame_size(row) > @segmentation_ceiling end) do
      nil ->
        :ok

      row ->
        error(
          module,
          [:hubs, row.hub],
          "port #{inspect({row.hub, row.port})} frame is #{frame_size(row)} bytes, over the #{@segmentation_ceiling}-byte ceiling (§03)"
        )
    end
  end

  # header + payload + the 2-byte CRC the frame codec appends. The IR row already
  # carries the resolved layout, so size it from there.
  defp frame_size(row) do
    Contract.header_size(row.stamped) + Layouts.payload_size(row.layout) + 2
  end

  # Every sensor/actuator view ref naming a hub port, plus actuator status_port
  # refs — both must reconcile to a producer.
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

  defp error(module, path, message) do
    {:error, DslError.exception(module: module, path: path, message: message)}
  end

  defp hex2(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
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
