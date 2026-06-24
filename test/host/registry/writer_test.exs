defmodule BBMcuhub.Host.Registry.WriterTest do
  @moduledoc """
  The sole-writer capability (candidate 5): one writer per slot, scoped writes,
  and a uniqueness guard that frees a slot when its writer dies.
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.Host.NodeRegistry
  alias BBMcuhub.Host.Registry.Writer

  setup do
    NodeRegistry.reset()
    :ok
  end

  test "a Writer can only write its own slot" do
    w = NodeRegistry.writer!(7, 0x20)
    assert Writer.slot(w) == {7, 0x20}

    :ok = Writer.put(w, %{nm: 0.5}, 1, 0)
    assert {%{nm: 0.5}, 1, 0} = NodeRegistry.get(7, 0x20)

    # there is no node/port argument on Writer.put — a holder structurally cannot
    # name another slot (the ids are closed over at mint).
    assert function_exported?(Writer, :put, 4)
    refute function_exported?(Writer, :put, 6)
  end

  test "a second live writer (a different process) of the same slot is refused (uniqueness, §07)" do
    test = self()

    # a separate, still-alive process holds the slot
    holder =
      spawn(fn ->
        _ = NodeRegistry.writer!(7, 0x21)
        send(test, :claimed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :claimed

    # a DIFFERENT process (this one) cannot claim the same live slot
    assert_raise Writer.Taken, ~r/slot \{7, 33\} already has a live writer/, fn ->
      NodeRegistry.writer!(7, 0x21)
    end

    send(holder, :stop)
  end

  test "re-minting from the SAME process is idempotent" do
    w1 = NodeRegistry.writer!(7, 0x22)
    w2 = NodeRegistry.writer!(7, 0x22)
    assert Writer.slot(w1) == Writer.slot(w2)
  end

  test "a different slot is independently claimable" do
    _a = NodeRegistry.writer!(7, 0x23)
    _b = NodeRegistry.writer!(7, 0x24)
    # no raise — distinct slots
  end

  test "a writer's death frees its slot for a successor" do
    test = self()

    # a short-lived process claims the slot, then exits
    pid =
      spawn(fn ->
        _ = NodeRegistry.writer!(7, 0x25)
        send(test, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # the successor can now claim it (claim-time liveness check + :DOWN cleanup)
    w = NodeRegistry.writer!(7, 0x25)
    assert Writer.slot(w) == {7, 0x25}
  end

  test "reset/0 clears both slot rows and writer claims" do
    w = NodeRegistry.writer!(7, 0x26)
    :ok = Writer.put(w, %{nm: 1.0}, 1, 0)
    assert NodeRegistry.get(7, 0x26) != nil

    NodeRegistry.reset()

    assert NodeRegistry.get(7, 0x26) == nil
    # the claim was released, so a fresh mint succeeds
    _w2 = NodeRegistry.writer!(7, 0x26)
  end
end
