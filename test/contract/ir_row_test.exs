defmodule BBMcuhub.Contract.IrRowTest do
  @moduledoc """
  The IR row is a typed value (candidate 1): a malformed projection must fail loud
  at construction, naming the offending (hub, port) — never reach the generator as
  a late KeyError. These tests pin the structural-completeness guarantee; the
  logical cross-field rules (the floored-role contract, topology) stay covered by
  the verifier tests.
  """
  use ExUnit.Case, async: true

  alias BBMcuhub.Contract.IrRow

  # A minimal well-formed row (a floored scalar-effort command port).
  defp valid_fields do
    %{
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
  end

  describe "new/1 accepts a well-formed row" do
    test "builds a typed struct from complete fields" do
      row = IrRow.new(valid_fields())
      assert %IrRow{} = row
      assert row.node == 2
      assert row.layout == [nm: :f32]
      assert row.safe_action == %{nm: 0.0}
    end

    test "a produced sensor port (nil fresh_for / safe_action) is well-formed" do
      fields =
        valid_fields()
        |> Map.merge(%{
          port: :pose,
          dir: :out,
          type: :imu,
          layout: [qw: :f32, qx: :f32],
          stamped: true,
          fresh_for: nil,
          has_safe_action: nil,
          safe_action: nil
        })

      assert %IrRow{dir: :out, fresh_for: nil} = IrRow.new(fields)
    end

    test "a non-root hub carries an uplink transport" do
      fields = Map.merge(valid_fields(), %{parent: :blaster, uplink: :can})
      assert %IrRow{uplink: :can} = IrRow.new(fields)
    end
  end

  describe "new/1 fails loud on a malformed projection" do
    test "a missing field is rejected, naming the field and the (hub, port)" do
      fields = Map.delete(valid_fields(), :layout)

      assert_raise ArgumentError, ~r/\{:act_hub, :effort_cmd\}.*missing field.*:layout/s, fn ->
        IrRow.new(fields)
      end
    end

    test "an out-of-range node is rejected" do
      assert_raise ArgumentError, ~r/:node.*0\.\.255/s, fn ->
        IrRow.new(%{valid_fields() | node: 300})
      end
    end

    test "an unknown uplink transport is rejected" do
      assert_raise ArgumentError, ~r/:uplink/, fn ->
        IrRow.new(%{valid_fields() | uplink: :spi})
      end
    end

    test "a bad dir is rejected" do
      assert_raise ArgumentError, ~r/:dir.*:in \| :out/s, fn ->
        IrRow.new(%{valid_fields() | dir: :inout})
      end
    end

    test "a malformed layout (unknown wire type) is rejected" do
      assert_raise ArgumentError, ~r/:layout/, fn ->
        IrRow.new(%{valid_fields() | layout: [nm: :f128]})
      end
    end

    test "a non-list layout is rejected" do
      assert_raise ArgumentError, ~r/:layout/, fn ->
        IrRow.new(%{valid_fields() | layout: :effort})
      end
    end

    test "a non-positive rate is rejected" do
      assert_raise ArgumentError, ~r/:rate/, fn ->
        IrRow.new(%{valid_fields() | rate: 0})
      end
    end

    test "a fresh_for below 1 is rejected" do
      assert_raise ArgumentError, ~r/:fresh_for/, fn ->
        IrRow.new(%{valid_fields() | fresh_for: 0})
      end
    end

    test "a non-map safe_action is rejected" do
      assert_raise ArgumentError, ~r/:safe_action/, fn ->
        IrRow.new(%{valid_fields() | safe_action: :zero})
      end
    end
  end
end
