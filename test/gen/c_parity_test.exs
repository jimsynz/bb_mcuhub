defmodule BBMCUHub.Gen.CParityTest do
  @moduledoc """
  Runs the host-compiled C parity + floor harnesses as part of `mix test`, so the
  cross-language witness (§03/§06) is checked on every test run, not just in CI.

  Skips gracefully if no host C compiler is available. The harnesses assert the C
  codec produces the SAME bytes/CRC as the generated parity vectors, that the C
  floor is born-disarmed / fail-passive, that the router relays meaning-blind in
  order, that CAN segmentation round-trips a wide body and is fail-closed on
  loss/reorder/corruption, and that a UART backplane round-trips a wide body in
  one COBS frame with no fragmentation (§03).
  """
  use ExUnit.Case, async: false

  @firmware_test Path.expand("../../firmware/test", __DIR__)

  @moduletag :c_parity

  setup_all do
    cc =
      System.find_executable("cc") || System.find_executable("clang") ||
        System.find_executable("gcc")

    if cc, do: :ok, else: {:skip, "no host C compiler (cc/clang/gcc) found"}
  end

  test "the C harnesses build and pass (cross-language wire + floor witness)" do
    # Always rebuild against the current generated headers so a stale binary can't
    # mask drift.
    {_clean, _} = System.cmd("make", ["clean"], cd: @firmware_test, stderr_to_stdout: true)
    {output, status} = System.cmd("make", [], cd: @firmware_test, stderr_to_stdout: true)

    assert status == 0, """
    C parity/floor harness failed (exit #{status}):

    #{output}
    """

    assert output =~ "ALL C PARITY CHECKS PASSED"
    assert output =~ "ALL C FLOOR CHECKS PASSED"
    assert output =~ "ALL C ROUTER CHECKS PASSED"
    assert output =~ "ALL C SEGMENT CHECKS PASSED"
    assert output =~ "ALL C UART BACKPLANE CHECKS PASSED"
  end
end
