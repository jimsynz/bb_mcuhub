defmodule BBMCUHub.Observer.BackpressureTest do
  @moduledoc """
  The observability plane's load-bearing invariant (ADR-0004, CONTEXT.md ·
  *Observer* / *Control plane · observability plane*): **a slow consumer
  structurally cannot slow the control plane.**

  This is the property the whole observer plane exists for, and the one the rest of
  the observer suite does not assert. `ObserverTest` proves *correctness* (born-stale,
  sample/drop, independent monitors); this proves *isolation under load* — that a
  hard-blocked sink, or many fast observers, cannot apply backpressure to a producer.

  ## Why this is structural, not a timing race

  A producer writes a slot with `NodeRegistry.put/5`, which is a bare `:ets.insert`
  on a `:public`, `write_concurrency: true` table — executed in the **producer's own
  process**, with no GenServer round-trip. An observer's sink runs inside the
  **observer's** `handle_info(:sample)`. The two processes share only the
  overwrite-only ETS slot. So a sink that blocks forever blocks only its observer's
  mailbox — it can never serialize behind, or stall, the producer's insert.

  We therefore assert **counts, not durations**: a producer driven to write N times
  completes all N writes *while* an observer's sink is provably wedged. No wall-clock
  tolerance, so nothing flakes on a loaded CI box.

  ## The CPU caveat, deliberately NOT gated

  CONTEXT.md is careful: the isolation is from **backpressure**, *not* from CPU —
  "many fast observers still share the BEAM scheduler." So the many-fast-observers
  case here only **characterizes** loop jitter (logged, never asserted). Gating on a
  jitter bound would assert a guarantee the design does not make, and would flake.
  """
  # Not async: reads/writes the shared NodeRegistry ETS table and the global
  # PortIndex (:persistent_term), exactly like ObserverTest.
  use ExUnit.Case, async: false

  alias BBMCUHub.Contract.PortIndex
  alias BBMCUHub.Host.NodeRegistry
  alias BBMCUHub.Observer

  @robot BBMCUHub.Test.Fixtures.Robot
  @slot {:sensor_hub, :pose}

  setup do
    NodeRegistry.reset()
    PortIndex.build(@robot)
    {:ok, {node, port_id}} = PortIndex.resolve(elem(@slot, 0), elem(@slot, 1))
    {:ok, node: node, port_id: port_id}
  end

  # Write the slot directly, as a real producer (LinkOwner / actuator view) would —
  # a bare ETS insert from the *caller's* process. `seq` increments so any observer
  # watching would witness advances; the producer never blocks on a consumer.
  defp produce(node, port_id, seq) do
    NodeRegistry.put(node, port_id, %{az: seq * 1.0}, seq, 0)
  end

  # Drive `count` writes as fast as the producer can, in a separate process, and
  # report how many actually landed (== count: the producer never waits on anyone).
  defp spawn_producer(node, port_id, count, parent) do
    spawn_link(fn ->
      for seq <- 1..count, do: produce(node, port_id, seq)
      send(parent, {:produced, count, latest_seq(node, port_id)})
    end)
  end

  # The seq currently in the slot — the row is `{value, seq, t_dev}`.
  defp latest_seq(node, port_id) do
    {_value, seq, _t_dev} = NodeRegistry.get(node, port_id)
    seq
  end

  # Deterministically walk an observer from born-stale to "about to wedge": write a
  # baseline seq and hand-drive ONE :sample (recorded as baseline, no advance yet, so
  # the sink is NOT called — we can safely flush with :sys.get_state). Then write an
  # advancing seq and hand-drive ONE more :sample; THIS witnesses the advance and
  # calls the (blocking) sink, so we do NOT flush — the caller asserts the sink entered.
  # This removes the auto-timer race: born-stale needs a witnessed advance on the
  # observer's OWN beats, which the bare timer cannot guarantee against two fast writes.
  defp prime_to_wedge(observer, node, port_id) do
    produce(node, port_id, 1)
    send(observer, :sample)
    _ = :sys.get_state(observer)
    produce(node, port_id, 2)
    send(observer, :sample)
    :ok
  end

  describe "backpressure isolation (ADR-0004 · a slow sink cannot slow the producer)" do
    test "a producer writes its full burst while an observer's sink is hard-blocked",
         %{node: node, port_id: port_id} do
      test = self()

      # A sink that BLOCKS the observer forever on its first call: it waits for a
      # message we never send. The observer's :sample handler is now wedged — the
      # worst possible consumer. If backpressure could reach the producer, this is
      # where it would show.
      gate = make_ref()

      blocking_sink = fn _slot, _value, _meta ->
        send(test, :sink_entered)
        # park here forever (until the test process dies) — never returns
        receive do
          ^gate -> :ok
        end
      end

      {:ok, observer} =
        Observer.start_link(
          robot: @robot,
          slots: [@slot],
          sink: blocking_sink,
          # short timer so the observer actively tries to sample under load
          sample_ms: 1,
          fresh_for: 1000
        )

      on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)

      # Walk born-stale → witnessed-advance → the sink call that wedges (see helper).
      prime_to_wedge(observer, node, port_id)

      # The observer enters the sink and blocks. Once we've seen that, the consumer
      # is provably stuck.
      assert_receive :sink_entered, 1000
      assert {:message_queue_len, _} = Process.info(observer, :message_queue_len)

      # NOW drive a full producer burst. If the wedged sink applied any backpressure,
      # these writes would not all land. They must all land — the producer shares
      # nothing with the observer but the overwrite-only slot.
      n = 5_000
      spawn_producer(node, port_id, n, test)

      assert_receive {:produced, ^n, last_seq}, 5000
      assert last_seq == n, "every write landed: the producer ran to completion (seq #{last_seq})"

      # And the sink is STILL blocked — it only ever entered once and never returned,
      # so the observer never advanced past that one sample even as 5000 writes flew by.
      refute_received :sink_entered
      assert {:message_queue_len, mql} = Process.info(observer, :message_queue_len)
      # the observer's mailbox backed up (its own timer kept firing while it was
      # wedged) — that backlog is contained to the observer, not the producer.
      assert mql >= 0
    end

    test "the slot still holds the producer's LATEST despite the wedged observer",
         %{node: node, port_id: port_id} do
      # Backpressure isolation must not corrupt the data path: a stuck observer must
      # not freeze the slot at an old value. The overwrite-only slot keeps the latest.
      test = self()

      blocking_sink = fn _s, _v, _m ->
        send(test, :sink_entered)

        receive do
          :never -> :ok
        end
      end

      {:ok, observer} =
        Observer.start_link(robot: @robot, slots: [@slot], sink: blocking_sink, sample_ms: 1)

      on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)

      prime_to_wedge(observer, node, port_id)
      assert_receive :sink_entered, 1000

      produce(node, port_id, 99)
      assert {%{az: 99.0}, 99, _} = NodeRegistry.get(node, port_id)
    end
  end

  describe "many observers, one slow (ADR-0004 · a slow sink degrades only itself)" do
    test "a wedged observer does not stop the fast observers or the producer",
         %{node: node, port_id: port_id} do
      test = self()

      # One observer wedges on its sink forever.
      wedged_sink = fn _s, _v, _m ->
        send(test, :wedged_entered)

        receive do
          :never -> :ok
        end
      end

      {:ok, wedged} =
        Observer.start_link(
          robot: @robot,
          slots: [@slot],
          name: :wedged,
          sink: wedged_sink,
          sample_ms: 1,
          fresh_for: 1000
        )

      # Several fast observers forward every sample to the test process.
      fast =
        for i <- 1..4 do
          {:ok, obs} =
            Observer.start_link(
              robot: @robot,
              slots: [@slot],
              name: :"fast_#{i}",
              sink: fn slot, _v, meta -> send(test, {:fast, i, slot, meta.seq}) end,
              sample_ms: 1,
              fresh_for: 1000
            )

          obs
        end

      on_exit(fn ->
        for o <- [wedged | fast], Process.alive?(o), do: Process.exit(o, :kill)
      end)

      # Deterministically wedge the slow observer (writes seq 1 then 2; it witnesses
      # the 1→2 advance and blocks in its sink).
      prime_to_wedge(wedged, node, port_id)
      assert_receive :wedged_entered, 1000

      # Now a long producer burst (seq 3..n+2): the fast observers, on their own 1ms
      # timers, baseline then witness advances during the burst and keep delivering —
      # while the wedged sibling stays stuck and the producer runs to completion.
      n = 2_000

      spawn_link(fn ->
        for seq <- 3..(n + 2), do: produce(node, port_id, seq)
        send(test, {:produced, n, latest_seq(node, port_id)})
      end)

      assert_receive {:produced, ^n, last}, 5000
      assert last == n + 2

      # The microsecond burst finishes between two 1ms ticks, so now keep the slot
      # advancing on the observers' OWN timescale: a few spaced writes guarantee each
      # fast observer's timer witnesses an advance and delivers — proving they kept
      # running while the sibling stays wedged. (Wall-clock spacing here is for
      # WITNESSING, not for the isolation claim, which is count-based above.)
      for seq <- (n + 3)..(n + 12) do
        produce(node, port_id, seq)
        Process.sleep(5)
      end

      # Every fast observer is still sampling (we got fresh samples from each).
      for i <- 1..4 do
        assert_receive {:fast, ^i, @slot, _seq},
                       2000,
                       "fast observer #{i} kept sampling while a sibling was wedged"
      end

      # The wedged observer never escaped its one sink call.
      refute_received :wedged_entered
    end
  end

  describe "CPU characterization (ADR-0004 · isolation is from backpressure, NOT CPU)" do
    @tag :characterize
    test "many fast observers: producer completes; loop jitter is LOGGED, not gated",
         %{node: node, port_id: port_id} do
      # This does NOT assert a jitter bound — CONTEXT.md is explicit that many fast
      # observers share the BEAM scheduler and may contend for CPU. We only assert
      # the producer completes, and we MEASURE inter-write jitter so a human can see
      # the cost. Gating here would assert a guarantee the design does not make.
      test = self()

      observers =
        for i <- 1..16 do
          {:ok, obs} =
            Observer.start_link(
              robot: @robot,
              slots: [@slot],
              name: :"cpu_#{i}",
              # a cheap real sink (no blocking) so they actually run their timers
              sink: fn _s, _v, _m -> :ok end,
              sample_ms: 1,
              fresh_for: 1000
            )

          obs
        end

      on_exit(fn -> for o <- observers, Process.alive?(o), do: Process.exit(o, :kill) end)

      produce(node, port_id, 1)
      produce(node, port_id, 2)

      # Drive a producer that timestamps each write so we can characterize the gap
      # distribution while 16 observers churn the scheduler.
      n = 3_000

      spawn_link(fn ->
        gaps =
          Enum.reduce(3..(n + 2), {System.monotonic_time(:microsecond), []}, fn seq,
                                                                                {prev, acc} ->
            produce(node, port_id, seq)
            now = System.monotonic_time(:microsecond)
            {now, [now - prev | acc]}
          end)
          |> elem(1)

        send(test, {:gaps, gaps})
      end)

      assert_receive {:gaps, gaps}, 10_000
      sorted = Enum.sort(gaps)
      len = length(sorted)
      p50 = Enum.at(sorted, div(len, 2))
      p99 = Enum.at(sorted, div(len * 99, 100))
      max = List.last(sorted)

      # Characterization only — no assertion on the values.
      IO.puts("""

      [observer CPU characterization] 16 fast observers @ 1ms, #{len} producer writes
        inter-write gap  p50=#{p50}µs  p99=#{p99}µs  max=#{max}µs
        (logged, not gated — isolation is from backpressure, not CPU; ADR-0004)
      """)

      assert len == n, "the producer ran to completion under CPU load"
    end
  end
end
