defmodule BBMcuhub.Dsl.ChecksTest do
  @moduledoc """
  Unit-tests the pure verifier checks (`BBMcuhub.Dsl.Checks`, candidate 3) over
  PLAIN DATA — hand-built `%IrRow{}` structs, plain hub maps, plain view maps — with
  NO `use BB` robot compiled. This is the payoff of decomplecting the checks from
  the Spark verifier: each rule is reachable directly and asserts on the
  representation-agnostic `%{path:, message:}` violation.

  The end-to-end "the verifier actually FIRES at compile time and the message
  reaches the user as a DslError" coverage stays in `verifier_test.exs`; this file
  covers the LOGIC, fast and in isolation.
  """
  use ExUnit.Case, async: true

  alias BBMcuhub.Contract.IrRow
  alias BBMcuhub.Dsl.Checks

  # --- builders for the three plain inputs -----------------------------------

  # A placed hub, the shape Checks reads (.name/.node/.parent/.uplink).
  defp hub(name, node, parent, uplink \\ nil) do
    %{name: name, node: node, parent: parent, uplink: uplink}
  end

  # A well-formed floored scalar-effort command row; override any field.
  defp cmd_row(overrides) do
    base = %{
      hub: :act_hub,
      node: 2,
      parent: :host,
      uplink: nil,
      port: :effort_cmd,
      port_id: 0x7B,
      dir: :in,
      type: :effort,
      layout: [nm: :f32],
      stamped: false,
      rate: 50,
      fresh_for: 5,
      has_safe_action: true,
      safe_action: %{nm: 0.0}
    }

    IrRow.new(Map.merge(base, overrides))
  end

  # A single valid root hub matching cmd_row's :act_hub / sense_row's :sensor_hub,
  # so the topology/node checks (which run BEFORE the IR-based checks in all/3)
  # pass through to the check a test is actually targeting.
  defp root_hubs(name \\ :act_hub, node \\ 2), do: [hub(name, node, :host)]

  # A produced sensor row (no floor, no safe_action).
  defp sense_row(overrides) do
    base = %{
      hub: :sensor_hub,
      node: 1,
      parent: :host,
      uplink: nil,
      port: :pose,
      port_id: 0x40,
      dir: :out,
      type: :imu,
      layout: [qw: :f32, qx: :f32],
      stamped: true,
      rate: 100,
      fresh_for: nil,
      has_safe_action: nil,
      safe_action: nil
    }

    IrRow.new(Map.merge(base, overrides))
  end

  # --- happy path ------------------------------------------------------------

  describe "all/3 on a well-formed model" do
    test "passes a single-root robot with reconciled views" do
      hubs = [hub(:root, 2, :host)]
      ir = [cmd_row(%{hub: :root}), sense_row(%{hub: :root, node: 2, port_id: 0x40})]
      views = [%{hub: :root, port: :effort_cmd, fresh_for: 5}]

      assert :ok = Checks.all(hubs, ir, views)
    end

    test "passes a two-hub tree (root + can child)" do
      hubs = [hub(:root, 2, :host), hub(:leaf, 3, :root, :can)]
      assert :ok = Checks.all(hubs, [], [])
    end
  end

  # --- nodes -----------------------------------------------------------------

  describe "verify_nodes" do
    test "rejects two hubs sharing a node" do
      hubs = [hub(:a, 5, :host), hub(:b, 5, :a, :can)]
      assert {:error, %{path: [:hubs], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "share node 0x05"
      assert msg =~ "whole-tree unique"
    end

    test "rejects the reserved broadcast node (0x00)" do
      hubs = [hub(:a, 0, :host)]
      assert {:error, %{path: [:hubs, :a], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "reserved node 0x00"
    end
  end

  # --- topology --------------------------------------------------------------

  describe "verify_topology" do
    test "rejects no root" do
      hubs = [hub(:a, 1, :b, :can), hub(:b, 2, :a, :can)]
      assert {:error, %{path: [:hubs], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "no root"
    end

    test "rejects two roots" do
      hubs = [hub(:a, 1, :host), hub(:b, 2, :host)]
      assert {:error, %{path: [:hubs], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "two+ roots"
      assert msg =~ "[:a, :b]"
    end

    test "rejects a root that declares an uplink" do
      hubs = [hub(:root, 2, :host, :can)]
      assert {:error, %{path: [:hubs, :root], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "declares uplink: :can"
      assert msg =~ "host UART"
    end

    test "rejects a parent that is not a declared hub" do
      hubs = [hub(:root, 2, :host), hub(:leaf, 3, :ghost, :can)]
      assert {:error, %{path: [:hubs, :leaf], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "names parent :ghost"
      assert msg =~ "not a declared hub"
    end

    test "rejects a non-root hub missing its uplink" do
      hubs = [hub(:root, 2, :host), hub(:leaf, 3, :root, nil)]
      assert {:error, %{path: [:hubs, :leaf], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "declares no uplink"
    end

    test "rejects a parent cycle" do
      # a → b → a, with no path to :host
      hubs = [hub(:a, 1, :b, :can), hub(:b, 2, :a, :can), hub(:r, 3, :host)]
      assert {:error, %{path: [:hubs, _], message: msg}} = Checks.all(hubs, [], [])
      assert msg =~ "parent cycle"
    end
  end

  # --- fresh_for -------------------------------------------------------------

  describe "verify_fresh_for" do
    test "rejects a view fresh_for below 1" do
      hubs = [hub(:root, 2, :host)]
      views = [%{hub: :root, port: :cmd, fresh_for: 0}]
      assert {:error, %{path: [:topology], message: msg}} = Checks.all(hubs, [], views)
      assert msg =~ "fresh_for 0"
      assert msg =~ ">= 1"
    end

    test "allows a nil fresh_for (a sensor view carries none here)" do
      hubs = [hub(:root, 2, :host)]
      views = [%{hub: :root, port: :pose, fresh_for: nil}]
      # reconciliation will complain (no producer), but fresh_for itself is fine;
      # with a matching producer it passes.
      ir = [sense_row(%{hub: :root, node: 2, port: :pose, port_id: 0x40})]
      assert :ok = Checks.all(hubs, ir, views)
    end
  end

  # --- safe_action (floored-role contract, ADR-0005) -------------------------

  describe "verify_safe_actions" do
    test "rejects a :in port missing has_safe_action" do
      ir = [cmd_row(%{has_safe_action: nil, safe_action: nil})]
      assert {:error, %{path: [:hubs, :act_hub], message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "must declare has_safe_action"
    end

    test "rejects a floored port with no safe_action value" do
      ir = [cmd_row(%{has_safe_action: true, safe_action: nil})]
      assert {:error, %{message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "is has_safe_action: true (floored) but declares no safe_action"
    end

    test "rejects a floored safe_action missing a layout field" do
      ir = [cmd_row(%{layout: [nm: :f32, brake: :bool], safe_action: %{nm: 0.0}})]
      assert {:error, %{message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "is missing field(s) [:brake]"
    end

    test "rejects a floored safe_action with an unknown field" do
      ir = [cmd_row(%{safe_action: %{nm: 0.0, torque: 0.0}})]
      assert {:error, %{message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "has unknown field(s) [:torque]"
    end

    test "rejects a non-numeric safe_action value (trial-pack fails)" do
      ir = [cmd_row(%{safe_action: %{nm: :zero}})]
      assert {:error, %{message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "is not a valid"
    end

    test "rejects a stray has_safe_action on a :out port" do
      ir = [sense_row(%{has_safe_action: true})]
      hubs = root_hubs(:sensor_hub, 1)

      assert {:error, %{path: [:hubs, :sensor_hub], message: msg}} = Checks.all(hubs, ir, [])
      assert msg =~ "declares has_safe_action"
      assert msg =~ "meaningless on a :out port"
    end

    test "rejects a stray safe_action on a :out port" do
      ir = [sense_row(%{safe_action: %{qw: 1.0}})]
      assert {:error, %{message: msg}} = Checks.all(root_hubs(:sensor_hub, 1), ir, [])
      assert msg =~ "declares a safe_action"
      assert msg =~ "only a floored :in port"
    end

    test "allows a non-floored :in port (has_safe_action: false, no value)" do
      # :effort command_message is non-nil, so command_messages also passes.
      ir = [cmd_row(%{has_safe_action: false, safe_action: nil})]
      assert :ok = Checks.all(root_hubs(), ir, [])
    end
  end

  # --- command_message (agnostic Component, finding #1) ----------------------

  describe "verify_command_messages" do
    test "rejects a :in port whose value-type declares no command_message" do
      # :imu is a sense value-type → command_message/0 is nil.
      ir = [
        cmd_row(%{type: :imu, layout: [qw: :f32], safe_action: %{qw: 0.0}})
      ]

      assert {:error, %{path: [:hubs, :act_hub], message: msg}} = Checks.all(root_hubs(), ir, [])
      assert msg =~ "declares no command_message"
    end
  end

  # --- id collision ----------------------------------------------------------

  describe "verify_no_id_collision" do
    test "rejects two rows sharing a wire identity {node, port_id}" do
      # both rows live on node 9 (one hub) — a single root suffices for topology.
      hubs = [hub(:a, 9, :host)]

      ir = [
        cmd_row(%{hub: :a, port: :x, node: 9, port_id: 0x20}),
        cmd_row(%{hub: :a, port: :y, node: 9, port_id: 0x20})
      ]

      assert {:error, %{path: [:hubs], message: msg}} = Checks.all(hubs, ir, [])
      assert msg =~ "wire id {0x09, 0x20} collides"
    end
  end

  # --- frame size ------------------------------------------------------------

  describe "verify_frame_sizes" do
    test "rejects a CAN port whose frame exceeds the 512-byte ceiling" do
      # 64 × f64 = 512 payload bytes; + header + CRC blows past 512. uplink: :can
      # is what makes the port CAN-budgeted (a :uart/root port is exempt).
      big_layout = for i <- 1..64, do: {:"f#{i}", :f64}
      big_value = Map.new(big_layout, fn {f, _wt} -> {f, 0.0} end)
      hubs = [hub(:root, 1, :host), hub(:leaf, 2, :root, :can)]

      ir = [
        cmd_row(%{
          hub: :leaf,
          uplink: :can,
          layout: big_layout,
          has_safe_action: true,
          safe_action: big_value
        })
      ]

      assert {:error, %{path: [:hubs, :leaf], message: msg}} = Checks.all(hubs, ir, [])
      assert msg =~ "over the 512-byte ceiling"
    end

    test "exempts a wide :uart port (no segmentation ceiling)" do
      big_layout = for i <- 1..64, do: {:"f#{i}", :f64}
      big_value = Map.new(big_layout, fn {f, _wt} -> {f, 0.0} end)
      hubs = [hub(:root, 1, :host), hub(:leaf, 2, :root, :uart)]

      ir = [
        cmd_row(%{
          hub: :leaf,
          uplink: :uart,
          layout: big_layout,
          has_safe_action: true,
          safe_action: big_value
        })
      ]

      assert :ok = Checks.all(hubs, ir, [])
    end
  end

  # --- reconciliation --------------------------------------------------------

  describe "verify_reconciliation" do
    test "rejects a view naming a (hub, port) with no IR producer" do
      hubs = [hub(:root, 2, :host)]
      ir = [cmd_row(%{hub: :root})]
      views = [%{hub: :root, port: :nonexistent, fresh_for: 3}]

      assert {:error, %{path: [:topology], message: msg}} = Checks.all(hubs, ir, views)
      assert msg =~ "but no hub declares that port"
    end
  end
end
