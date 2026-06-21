defmodule BBMcuhub.ObserverTest do
  @moduledoc """
  The observability plane's sample-state core (ADR-0004).

  Drives the observer's `:sample` tick deterministically (send it, then flush via a
  `:sys.get_state` call) — exactly the idiom the views' tests use for `:beat` — so
  no test depends on a wall-clock timer. `sample_ms` is set huge so the auto-timer
  never fires during a test.
  """
  # Not async: resolve_slots reads the global PortIndex (:persistent_term), and the
  # observer reads/writes the shared NodeRegistry ETS table.
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.NodeRegistry
  alias BBMcuhub.Host.Registry.Reader
  alias BBMcuhub.Observer

  @robot BBMcuhub.Test.Fixtures.Robot
  # never fire the auto-timer; we drive :sample by hand for determinism
  @never 3_600_000

  setup do
    :ets.delete_all_objects(NodeRegistry.table())
    PortIndex.build(@robot)
    :ok
  end

  # send one sample tick and block until processed, so reads see the effect
  defp tick(observer) do
    send(observer, :sample)
    _ = :sys.get_state(observer)
    :ok
  end

  # a fun-sink that forwards every sample to the test process
  defp forwarding_sink do
    test = self()
    fn slot, value, meta -> send(test, {:sample, slot, value, meta}) end
  end

  defp put(slot, value, seq, t_dev \\ 0) do
    {:ok, {node, port_id}} = PortIndex.resolve(elem(slot, 0), elem(slot, 1))
    NodeRegistry.put(node, port_id, value, seq, t_dev)
  end

  defp start_observer(opts) do
    defaults = [robot: @robot, sample_ms: @never, sink: forwarding_sink()]
    {:ok, observer} = Observer.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(observer), do: GenServer.stop(observer) end)
    observer
  end

  describe "fail-loud select (ADR-0004 · resolves select at start)" do
    test "an unknown {hub, port} stops the observer at init" do
      Process.flag(:trap_exit, true)

      assert {:error, {:unknown_slot, {:no_such_hub, :nope}}} =
               Observer.start_link(
                 robot: @robot,
                 slots: [{:no_such_hub, :nope}],
                 sink: forwarding_sink(),
                 sample_ms: @never
               )
    end

    test "a known slot mixed with an unknown one still fails loud (no partial observe)" do
      Process.flag(:trap_exit, true)

      assert {:error, {:unknown_slot, {:sensor_hub, :typo}}} =
               Observer.start_link(
                 robot: @robot,
                 slots: [{:sensor_hub, :pose}, {:sensor_hub, :typo}],
                 sink: forwarding_sink(),
                 sample_ms: @never
               )
    end
  end

  describe "born-stale (ADR-0004 · never hand a leftover/never-witnessed value)" do
    test "a never-advancing slot is NOT handed to the sink" do
      observer = start_observer(slots: [{:sensor_hub, :pose}])

      # nothing in the slot yet
      tick(observer)
      refute_received {:sample, _, _, _}

      # a value appears, but the first tick only records the seq baseline
      # (born-stale: a value from before the observer booted is not trusted)
      put({:sensor_hub, :pose}, %{az: 9.81}, 7)
      tick(observer)
      refute_received {:sample, _, _, _}
    end

    test "after a witnessed seq advance the value IS handed to the sink" do
      observer = start_observer(slots: [{:sensor_hub, :pose}])

      put({:sensor_hub, :pose}, %{az: 9.81}, 7)
      tick(observer)
      refute_received {:sample, _, _, _}, "baseline only — not yet witnessed"

      # a distinct seq earns trust → the sink gets the latest value
      put({:sensor_hub, :pose}, %{az: 9.50}, 8)
      tick(observer)
      assert_received {:sample, {:sensor_hub, :pose}, %{az: 9.50}, _meta}
    end

    test "a gone-silent slot stops being handed to the sink after fresh_for beats" do
      observer = start_observer(slots: [{:sensor_hub, :pose}], fresh_for: 2)

      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)
      assert_received {:sample, _, %{az: 2.0}, _}, "fresh after a witnessed advance"

      # seq frozen at 2: idle climbs; within fresh_for it is still handed over...
      tick(observer)
      assert_received {:sample, _, %{az: 2.0}, _}
      tick(observer)
      assert_received {:sample, _, %{az: 2.0}, _}
      # ...then goes stale and is dropped (no leftover value to the sink)
      tick(observer)
      refute_received {:sample, _, _, _}
    end
  end

  describe "sample/drop semantics (ADR-0004 · sample-state, dropping is correct)" do
    test "several seq advances between ticks yield ONE sample of the latest" do
      observer = start_observer(slots: [{:sensor_hub, :pose}])

      # establish trust (baseline then one advance)
      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)
      assert_received {:sample, _, %{az: 2.0}, _}

      # the producer overwrites the slot several times between observer ticks;
      # the overwrite-only slot keeps only the latest (5.0 @ seq 5)
      put({:sensor_hub, :pose}, %{az: 3.0}, 3)
      put({:sensor_hub, :pose}, %{az: 4.0}, 4)
      put({:sensor_hub, :pose}, %{az: 5.0}, 5)

      tick(observer)
      # exactly ONE sample, of the latest value — the in-between values are dropped
      assert_received {:sample, _, %{az: 5.0}, %{seq: 5}}
      refute_received {:sample, _, %{az: 3.0}, _}
      refute_received {:sample, _, %{az: 4.0}, _}
    end
  end

  describe "the sample meta handed to the sink" do
    test "carries the slot, wire ids, seq, t_dev, freshness, and value-type" do
      {:ok, {node, port_id}} = PortIndex.resolve(:sensor_hub, :pose)
      observer = start_observer(slots: [{:sensor_hub, :pose}], name: :pose_obs)

      put({:sensor_hub, :pose}, %{az: 1.0}, 1, 111)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2, 222)
      tick(observer)

      assert_received {:sample, {:sensor_hub, :pose}, %{az: 2.0}, meta}
      assert meta.slot == {:sensor_hub, :pose}
      assert meta.node == node
      assert meta.port_id == port_id
      assert meta.seq == 2
      assert meta.t_dev == 222
      assert meta.freshness == :fresh
      assert meta.value_type == BBMcuhub.ValueType.Imu
      assert meta.observer == :pose_obs
    end
  end

  describe "independent cadence (ADR-0004 · N independent readers)" do
    test "two observers on the same slot at different rates both work, neither affects the other" do
      test = self()

      fast =
        start_observer(
          slots: [{:sensor_hub, :pose}],
          name: :fast,
          sink: fn slot, value, _meta -> send(test, {:fast, slot, value}) end
        )

      slow =
        start_observer(
          slots: [{:sensor_hub, :pose}],
          name: :slow,
          sink: fn slot, value, _meta -> send(test, {:slow, slot, value}) end
        )

      # establish trust for both (each holds its OWN monitor)
      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(fast)
      tick(slow)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(fast)
      tick(slow)
      assert_received {:fast, _, %{az: 2.0}}
      assert_received {:slow, _, %{az: 2.0}}

      # the fast observer ticks several times (sampling the latest each time);
      # the slow observer has not ticked — its monitor is untouched by the fast one
      put({:sensor_hub, :pose}, %{az: 3.0}, 3)
      tick(fast)
      assert_received {:fast, _, %{az: 3.0}}
      refute_received {:slow, _, _}

      put({:sensor_hub, :pose}, %{az: 4.0}, 4)
      tick(fast)
      assert_received {:fast, _, %{az: 4.0}}

      # now the slow observer ticks once: it samples the latest (4.0), independent
      # of how many times the fast one sampled in between
      tick(slow)
      assert_received {:slow, _, %{az: 4.0}}
    end
  end

  describe "multi-slot select" do
    test "one observer selects several slots and samples each independently" do
      observer = start_observer(slots: [{:sensor_hub, :pose}, {:sensor_hub, :scalar}])

      # only :pose has witnessed an advance → only :pose is handed over
      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)
      assert_received {:sample, {:sensor_hub, :pose}, _, _}
      refute_received {:sample, {:sensor_hub, :scalar}, _, _}

      # now :scalar earns trust too — both are sampled on a tick
      put({:sensor_hub, :scalar}, %{n: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :scalar}, %{n: 2.0}, 2)
      put({:sensor_hub, :pose}, %{az: 3.0}, 3)
      tick(observer)
      assert_received {:sample, {:sensor_hub, :pose}, %{az: 3.0}, _}
      assert_received {:sample, {:sensor_hub, :scalar}, %{n: 2.0}, _}
    end
  end

  describe "pure reader (ADR-0004 · structurally read-only)" do
    test "the observer reads through an injected Reader and never writes a slot" do
      # a fake reader that counts reads and would CRASH if a write were attempted —
      # it has no put, structurally. We assert the observer only ever reads.
      test = self()

      fake =
        %Reader{
          get: fn _node, _port_id ->
            send(test, :read)
            {%{az: 9.0}, 2, 0}
          end,
          dump: fn -> %{} end
        }

      # seed a baseline read so the monitor witnesses an advance on the 2nd tick:
      # the fake always returns seq 2, so we first make it return seq 1 once.
      {:ok, agent} = Agent.start_link(fn -> 1 end)

      fake =
        %Reader{
          fake
          | get: fn _node, _port_id ->
              seq = Agent.get_and_update(agent, fn s -> {s, s + 1} end)
              send(test, {:read, seq})
              {%{az: 9.0}, seq, 0}
            end
        }

      observer = start_observer(slots: [{:sensor_hub, :pose}], reader: fake)

      tick(observer)
      assert_received {:read, 1}
      tick(observer)
      assert_received {:read, 2}
      # advance witnessed (1 → 2) → handed to the sink, all via the Reader
      assert_received {:sample, {:sensor_hub, :pose}, %{az: 9.0}, _}
    end
  end
end
