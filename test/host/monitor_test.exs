defmodule BBMCUHub.Host.MonitorTest do
  use ExUnit.Case, async: true
  alias BBMCUHub.Host.Monitor

  defp row(seq), do: {%{nm: 0.0}, seq, 0}

  describe "born stale (§04)" do
    test "a fresh monitor is stale and has witnessed nothing" do
      mon = Monitor.new(2, 0x10, 3)
      assert mon.status == :stale
      refute mon.witnessed?
    end

    test "an empty slot keeps it stale and unwitnessed" do
      mon = Monitor.new(2, 0x10, 3) |> Monitor.check_row(nil)
      assert mon.status == :stale
      refute mon.witnessed?
    end

    test "a value already sitting in the slot is NOT trusted on the first beat" do
      # The slot holds seq 99 from before this consumer booted. The first beat
      # only records 99 as a baseline; born-stale means it must not be trusted as
      # fresh until seq advances *since* this consumer started watching.
      mon = Monitor.new(2, 0x10, 3) |> Monitor.check_row(row(99))
      refute mon.witnessed?
      assert mon.status == :stale
    end

    test "trust begins once seq advances since boot" do
      mon =
        Monitor.new(2, 0x10, 3)
        |> Monitor.check_row(row(99))
        |> Monitor.check_row(row(100))

      assert mon.status == :fresh
    end
  end

  describe "the fresh_for window" do
    test "stays fresh while seq advances every beat" do
      mon =
        Enum.reduce(1..10, Monitor.new(2, 0x10, 2), fn seq, m ->
          Monitor.check_row(m, row(seq))
        end)

      assert mon.status == :fresh
    end

    test "goes stale after fresh_for beats with no advance" do
      mon =
        Monitor.new(2, 0x10, 3)
        |> Monitor.check_row(row(1))
        |> Monitor.check_row(row(2))

      assert mon.status == :fresh

      # seq frozen at 2 — idle climbs 1,2,3 (still fresh) then 4 (stale)
      mon = Enum.reduce(1..3, mon, fn _i, m -> Monitor.check_row(m, row(2)) end)
      assert mon.status == :fresh
      mon = Monitor.check_row(mon, row(2))
      assert mon.status == :stale
    end

    test "recovers to fresh when seq advances again" do
      mon =
        Monitor.new(2, 0x10, 1)
        |> Monitor.check_row(row(1))
        |> Monitor.check_row(row(2))
        |> Monitor.check_row(row(2))
        |> Monitor.check_row(row(2))

      assert mon.status == :stale
      mon = Monitor.check_row(mon, row(3))
      assert mon.status == :fresh
    end
  end

  describe "advance is a plain inequality, sound under in-order links" do
    test "any change in seq counts as a new value, including a wrap-around jump" do
      mon =
        Monitor.new(2, 0x10, 2)
        |> Monitor.check_row(row(0xFFFE))
        |> Monitor.check_row(row(0xFFFF))
        # wrapped: 0xFFFF -> 0 is still an advance (it differs)
        |> Monitor.check_row(row(0x0000))

      assert mon.status == :fresh
    end

    test "a re-arrival of the same seq is not an advance" do
      mon =
        Monitor.new(2, 0x10, 1)
        |> Monitor.check_row(row(5))
        |> Monitor.check_row(row(6))
        # same seq re-sent (a relay re-arrival) — must not count as new
        |> Monitor.check_row(row(6))
        |> Monitor.check_row(row(6))

      assert mon.status == :stale
    end
  end
end
