defmodule BBMCUHub.Dsl.Checks do
  @moduledoc """
  The pure checks behind `BBMCUHub.Dsl.Verifier` (§06) — decomplected from Spark so
  each rule is a plain function over plain data, unit-testable without compiling a
  `use BB` robot (candidate 3 of the architecture review).

  Each check takes plain inputs and returns `:ok | {:error, violation}`, where a
  **violation is a representation-agnostic map** `%{path: [...], message: String.t()}`
  — no dependency on `Spark.Error.DslError`. The thin `BBMCUHub.Dsl.Verifier`
  adapter pulls the data out of the DSL state, calls `all/3`, and maps any violation
  into a `DslError` with the offending module.

  The inputs:

    * `hubs` — the placed hubs, each with `.name`, `.node`, `.parent`, `.uplink`
      (the `BBMCUHub.Dsl.Hub` struct shape);
    * `ir` — the projected `[%BBMCUHub.Contract.IrRow{}]` rows;
    * `views` — the reader view refs, each `%{hub: atom, port: atom, fresh_for: integer | nil}`.

  `all/3` raises a violation on any of:

    * a sensor/actuator/status_port that names a `(hub, port)` with no IR
      producer (reader↔producer reconciliation);
    * two hubs sharing a `node`, or a reserved `node` (0x00);
    * an ill-formed topology: no root / two roots / an unknown
      `parent:` / a parent cycle / a disconnected hub / a non-root missing its
      `uplink:` / a root that declares an `uplink:`;
    * a view `fresh_for` < 1;
    * a `:in` port missing `has_safe_action`, a floored port without a valid
      `safe_action` value, or a stray `safe_action`/flag where it does not belong
      (the floored-role contract);
    * a `{node, port_id}` collision across IR rows;
    * a port whose frame would exceed the segmentation ceiling.
  """

  alias BBMCUHub.Contract
  alias BBMCUHub.Contract.Layouts

  # Matches the C SEG_MAX_BODY in firmware/include/segment.h.
  @segmentation_ceiling 512

  @host :host

  @type violation :: %{path: [atom() | nil], message: String.t()}

  @doc """
  Run every check, short-circuiting on the first violation (same order as the
  Spark verifier always ran them in).
  """
  @spec all([map()], [Contract.ir_row()], [map()]) :: :ok | {:error, violation()}
  def all(hubs, ir, views) do
    with :ok <- verify_nodes(hubs),
         :ok <- verify_topology(hubs),
         :ok <- verify_fresh_for(views),
         :ok <- verify_safe_actions(ir),
         :ok <- verify_command_messages(ir),
         :ok <- verify_reconciliation(views, ir),
         :ok <- verify_no_id_collision(ir),
         :ok <- verify_frame_sizes(ir) do
      :ok
    end
  end

  # The agnostic-Component contract (finding #1), per command port: every `dir: :in`
  # (command) port's value-type MUST name the `BB.Message` command struct it accepts
  # via `command_message/0` (non-nil). The actuator view derives its PubSub subscribe
  # from that struct, so a sense value-type (which leaves command_message nil) on a
  # command port would silently subscribe to `nil` and never receive a command — a
  # misconfiguration the verifier catches at compile time, not at runtime.
  defp verify_command_messages(ir) do
    Enum.reduce_while(ir, :ok, fn row, :ok ->
      case verify_command_message(row) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_command_message(%{dir: :in} = row) do
    if is_nil(BBMCUHub.ValueType.resolve(row.type).command_message()) do
      violation(
        [:hubs, row.hub],
        "command port #{inspect({row.hub, row.port})} uses value-type #{inspect(row.type)} which declares no command_message — a command value-type must name the BB.Message struct it accepts (finding #1 / agnostic Component)"
      )
    else
      :ok
    end
  end

  defp verify_command_message(%{dir: :out}), do: :ok

  # The floored-role contract (ADR-0005), per port:
  #
  #   * a :in (command) port MUST declare `has_safe_action` (true or false);
  #   * has_safe_action: true ⇒ `safe_action` present AND a valid value of the
  #     port's value-type (every layout field present, numeric — the codec packs
  #     it; an unknown/missing/ill-typed field is a compile error, not a silent
  #     default);
  #   * has_safe_action: false ⇒ `safe_action` MUST be absent;
  #   * a :out (produced) port carries NEITHER (the flag is meaningless there).
  defp verify_safe_actions(ir) do
    Enum.reduce_while(ir, :ok, fn row, :ok ->
      case verify_safe_action(row) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_safe_action(%{dir: :out} = row) do
    cond do
      not is_nil(row.has_safe_action) ->
        violation(
          [:hubs, row.hub],
          "produced port #{inspect({row.hub, row.port})} declares has_safe_action — it is meaningless on a :out port; remove it (ADR-0005)"
        )

      not is_nil(row.safe_action) ->
        violation(
          [:hubs, row.hub],
          "produced port #{inspect({row.hub, row.port})} declares a safe_action — only a floored :in port has one (ADR-0005)"
        )

      true ->
        :ok
    end
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: nil} = row) do
    violation(
      [:hubs, row.hub],
      "command port #{inspect({row.hub, row.port})} must declare has_safe_action (true ⇒ floored with a safe_action; false ⇒ non-floored) — omitting it would silently drop the dead-man (ADR-0005)"
    )
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: false} = row) do
    if is_nil(row.safe_action) do
      :ok
    else
      violation(
        [:hubs, row.hub],
        "command port #{inspect({row.hub, row.port})} is has_safe_action: false (non-floored) but declares a safe_action — the role and the value must agree; drop the safe_action or set has_safe_action: true (ADR-0005)"
      )
    end
  end

  defp verify_safe_action(%{dir: :in, has_safe_action: true} = row) do
    cond do
      is_nil(row.safe_action) ->
        violation(
          [:hubs, row.hub],
          "command port #{inspect({row.hub, row.port})} is has_safe_action: true (floored) but declares no safe_action — a floored port MUST give a safe action value (ADR-0005)"
        )

      true ->
        validate_safe_value(row)
    end
  end

  # The safe_action must be a valid value of the port's value-type: every field
  # in the layout present with a numeric value (the same shape the codec packs to
  # the wire). We validate explicitly for a clear message, then trial-pack via the
  # real codec so an ill-typed value (e.g. a non-number) is caught by the same
  # encoder the bytes go through (ADR-0005: no separate translation layer).
  defp validate_safe_value(row) do
    layout_fields = Enum.map(row.layout, fn {field, _wt} -> field end)
    given_fields = Map.keys(row.safe_action)

    missing = layout_fields -- given_fields
    extra = given_fields -- layout_fields

    cond do
      missing != [] ->
        violation(
          [:hubs, row.hub],
          "safe_action for #{inspect({row.hub, row.port})} is missing field(s) #{inspect(missing)} of its #{inspect(row.type)} value-type (ADR-0005)"
        )

      extra != [] ->
        violation(
          [:hubs, row.hub],
          "safe_action for #{inspect({row.hub, row.port})} has unknown field(s) #{inspect(extra)} not in its #{inspect(row.type)} value-type layout (ADR-0005)"
        )

      true ->
        try do
          _ = BBMCUHub.Wire.Codec.encode_fields(row.layout, row.safe_action)
          :ok
        rescue
          e ->
            violation(
              [:hubs, row.hub],
              "safe_action for #{inspect({row.hub, row.port})} is not a valid #{inspect(row.type)} value — #{Exception.message(e)} (ADR-0005)"
            )
        end
    end
  end

  # No two hubs share a node; no hub uses the reserved broadcast id (0x00).
  defp verify_nodes(hubs) do
    reserved = Contract.broadcast_node()

    with :ok <- check_reserved(hubs, reserved) do
      hubs
      |> Enum.group_by(& &1.node)
      |> Enum.find(fn {_node, group} -> length(group) > 1 end)
      |> case do
        nil ->
          :ok

        {node, group} ->
          names = group |> Enum.map(& &1.name) |> Enum.sort()

          violation(
            [:hubs],
            "hubs #{inspect(names)} share node 0x#{hex2(node)} — node ids must be whole-tree unique (§03)"
          )
      end
    end
  end

  defp check_reserved(hubs, reserved) do
    case Enum.find(hubs, &(&1.node == reserved)) do
      nil ->
        :ok

      hub ->
        violation(
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
  defp verify_topology(hubs) do
    names = MapSet.new(hubs, & &1.name)
    roots = Enum.filter(hubs, &(&1.parent == @host))

    with :ok <- verify_one_root(roots, hubs),
         :ok <- verify_root_uplink(roots),
         :ok <- verify_parents_resolve(hubs, names),
         :ok <- verify_nonroot_uplinks(hubs),
         :ok <- verify_no_cycles(hubs) do
      :ok
    end
  end

  defp verify_one_root([_one], _hubs), do: :ok

  defp verify_one_root([], _hubs) do
    violation(
      [:hubs],
      "no root: a hub must declare parent: :host — the root owns the host link (ADR-0006)"
    )
  end

  defp verify_one_root(roots, _hubs) do
    names = roots |> Enum.map(& &1.name) |> Enum.sort()

    violation(
      [:hubs],
      "two+ roots: hubs #{inspect(names)} each declare parent: :host — exactly one hub may be the root (ADR-0006)"
    )
  end

  # The root's uplink is the host UART (fixed). Declaring one is a contradiction.
  defp verify_root_uplink(roots) do
    case Enum.find(roots, &(not is_nil(&1.uplink))) do
      nil ->
        :ok

      hub ->
        violation(
          [:hubs, hub.name],
          "root hub #{inspect(hub.name)} declares uplink: #{inspect(hub.uplink)} — the root's uplink is the host UART, not declared (ADR-0006)"
        )
    end
  end

  # Every non-:host parent names a DECLARED hub.
  defp verify_parents_resolve(hubs, names) do
    case Enum.find(hubs, &(&1.parent != @host and not MapSet.member?(names, &1.parent))) do
      nil ->
        :ok

      hub ->
        violation(
          [:hubs, hub.name],
          "hub #{inspect(hub.name)} names parent #{inspect(hub.parent)}, which is not a declared hub (ADR-0006)"
        )
    end
  end

  # Every NON-root hub declares an uplink (the transport of its parent link).
  defp verify_nonroot_uplinks(hubs) do
    case Enum.find(hubs, &(&1.parent != @host and is_nil(&1.uplink))) do
      nil ->
        :ok

      hub ->
        violation(
          [:hubs, hub.name],
          "non-root hub #{inspect(hub.name)} (parent #{inspect(hub.parent)}) declares no uplink — a non-root hub must declare its parent-link transport (:can | :uart) (ADR-0006)"
        )
    end
  end

  # No cycles: following parent pointers from each hub must reach :host without
  # revisiting a hub. A revisit (or a non-resolving parent we don't error on here
  # because verify_parents_resolve already did) means a cycle. This also asserts
  # CONNECTEDNESS — a hub that loops never reaches :host.
  defp verify_no_cycles(hubs) do
    by_name = Map.new(hubs, &{&1.name, &1})

    Enum.reduce_while(hubs, :ok, fn hub, :ok ->
      case walk_to_host(hub, by_name, MapSet.new()) do
        :ok ->
          {:cont, :ok}

        {:cycle, chain} ->
          {:halt,
           violation(
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
  defp verify_fresh_for(views) do
    case Enum.find(views, fn v -> not is_nil(v.fresh_for) and v.fresh_for < 1 end) do
      nil ->
        :ok

      v ->
        violation(
          [:topology],
          "view for #{inspect({v.hub, v.port})} has fresh_for #{v.fresh_for} — must be >= 1 (§04)"
        )
    end
  end

  # Every (hub, port) a view names resolves to exactly one IR producer.
  defp verify_reconciliation(views, ir) do
    producers = MapSet.new(ir, &{&1.hub, &1.port})

    case Enum.find(views, fn v -> not MapSet.member?(producers, {v.hub, v.port}) end) do
      nil ->
        :ok

      v ->
        violation(
          [:topology],
          "view names #{inspect({v.hub, v.port})} but no hub declares that port (§06)"
        )
    end
  end

  # No two IR rows share a wire identity (node, port_id).
  defp verify_no_id_collision(ir) do
    ir
    |> Enum.group_by(&{&1.node, &1.port_id})
    |> Enum.find(fn {_key, rows} -> length(rows) > 1 end)
    |> case do
      nil ->
        :ok

      {{node, port_id}, rows} ->
        pairs = rows |> Enum.map(&{&1.hub, &1.port}) |> Enum.sort()

        violation(
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
  defp verify_frame_sizes(ir) do
    can_rows = Enum.filter(ir, &(&1.uplink == :can))

    case Enum.find(can_rows, fn row -> frame_size(row) > @segmentation_ceiling end) do
      nil ->
        :ok

      row ->
        violation(
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

  defp violation(path, message) do
    {:error, %{path: path, message: message}}
  end

  defp hex2(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
end
