defmodule BBMCUHub.ValueTypeTest do
  @moduledoc """
  The value-type resolution seam (§06). `resolved?/1` is the parse-don't-scan
  predicate the transformer uses to reject a typo'd `type:` at compile time
  (finding #6) — a stock atom or a real value-type module is true; anything that
  does not resolve to a module exporting `layout/0` is false.
  """
  use ExUnit.Case, async: true

  alias BBMCUHub.ValueType

  describe "resolve/1" do
    test "maps stock atoms to their modules" do
      assert ValueType.resolve(:imu) == BBMCUHub.ValueType.Imu
      assert ValueType.resolve(:effort) == BBMCUHub.ValueType.Effort
      assert ValueType.resolve(:status) == BBMCUHub.ValueType.Status
    end

    test "passes a module through unchanged" do
      assert ValueType.resolve(BBMCUHub.ValueType.Imu) == BBMCUHub.ValueType.Imu
    end
  end

  describe "resolved?/1" do
    test "true for every stock atom" do
      assert ValueType.resolved?(:imu)
      assert ValueType.resolved?(:effort)
      assert ValueType.resolved?(:status)
    end

    test "true for a real value-type module" do
      assert ValueType.resolved?(BBMCUHub.ValueType.Effort)
    end

    test "false for a typo'd stock atom" do
      refute ValueType.resolved?(:effor)
      refute ValueType.resolved?(:imuu)
    end

    test "false for an atom that is not a value-type module" do
      refute ValueType.resolved?(Enum)
      refute ValueType.resolved?(:not_a_module)
    end
  end
end
