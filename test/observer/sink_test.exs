defmodule BBMcuhub.Observer.SinkTest do
  @moduledoc """
  The sink behaviour + stock sinks (ADR-0004): the function-sink primitive and the
  PubSub-republish sink (the dashboard's slow topic).
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.NodeRegistry
  alias BBMcuhub.Observer
  alias BBMcuhub.Observer.Sample
  alias BBMcuhub.Observer.Sink

  @robot BBMcuhub.Test.Fixtures.Robot
  @never 3_600_000

  setup do
    NodeRegistry.reset()
    PortIndex.build(@robot)
    :ok
  end

  defp tick(observer) do
    send(observer, :sample)
    _ = :sys.get_state(observer)
    :ok
  end

  defp put(slot, value, seq, t_dev \\ 0) do
    {:ok, {node, port_id}} = PortIndex.resolve(elem(slot, 0), elem(slot, 1))
    NodeRegistry.put(node, port_id, value, seq, t_dev)
  end

  describe "Sink.normalize/1 collapses both shapes to {module, state}" do
    test "a bare fun/3 becomes a Fun sink" do
      fun = fn _s, _v, _m -> :ok end
      assert {Sink.Fun, ^fun} = Sink.normalize(fun)
    end

    test "a {module, state} passes through unchanged" do
      assert {SomeMod, %{a: 1}} = Sink.normalize({SomeMod, %{a: 1}})
    end
  end

  describe "the function sink (the primitive)" do
    test "receives (slot, value, meta) for each fresh sample" do
      test = self()
      sink = fn slot, value, meta -> send(test, {:got, slot, value, meta}) end

      {:ok, observer} =
        Observer.start_link(
          robot: @robot,
          slots: [{:sensor_hub, :pose}],
          sink: sink,
          sample_ms: @never
        )

      on_exit(fn -> if Process.alive?(observer), do: GenServer.stop(observer) end)

      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)

      assert_received {:got, {:sensor_hub, :pose}, %{az: 2.0}, %{seq: 2, freshness: :fresh}}
    end

    test "Sink.Fun.handle_sample/4 threads the same fun as state" do
      test = self()
      fun = fn s, v, m -> send(test, {s, v, m}) end
      assert ^fun = Sink.Fun.handle_sample({:h, :p}, %{x: 1}, %{}, fun)
      assert_received {{:h, :p}, %{x: 1}, %{}}
    end
  end

  describe "a stateful behaviour sink accumulates across samples" do
    defmodule CountingSink do
      @behaviour BBMcuhub.Observer.Sink
      @impl true
      def handle_sample(_slot, _value, _meta, %{count: c, test: t}) do
        st = %{count: c + 1, test: t}
        send(t, {:count, st.count})
        st
      end
    end

    test "the {module, state} is threaded through each sample" do
      test = self()

      {:ok, observer} =
        Observer.start_link(
          robot: @robot,
          slots: [{:sensor_hub, :pose}],
          sink: {CountingSink, %{count: 0, test: test}},
          sample_ms: @never
        )

      on_exit(fn -> if Process.alive?(observer), do: GenServer.stop(observer) end)

      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)
      assert_received {:count, 1}
      put({:sensor_hub, :pose}, %{az: 3.0}, 3)
      tick(observer)
      assert_received {:count, 2}
    end
  end

  describe "the PubSub-republish sink (the dashboard's slow topic)" do
    setup do
      # a real BB tree for the fixture robot gives us a PubSub to publish/subscribe
      start_supervised!(%{id: BB.Supervisor, start: {BB.Supervisor, :start_link, [@robot]}})
      :ok
    end

    test "publishes a Sample on the observer's OWN topic, not the control firehose" do
      sink = Sink.PubSub.new(robot: @robot, topic: [:observe, :ui])

      {:ok, observer} =
        Observer.start_link(
          robot: @robot,
          name: :ui_obs,
          slots: [{:sensor_hub, :pose}],
          sink: sink,
          sample_ms: @never
        )

      on_exit(fn -> if Process.alive?(observer), do: GenServer.stop(observer) end)

      # subscribe to the per-slot observer topic — NOT the broad [:sensor] prefix
      BB.subscribe(@robot, [:observe, :ui, :sensor_hub, :pose])

      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 9.5}, 2, 42)
      tick(observer)

      assert_receive {:bb, [:observe, :ui, :sensor_hub, :pose], %BB.Message{payload: payload}},
                     200

      assert %Sample{} = payload
      assert payload.slot == {:sensor_hub, :pose}
      assert payload.value == %{az: 9.5}
      assert payload.seq == 2
      assert payload.t_dev == 42
      assert payload.freshness == :fresh
      assert payload.value_type == BBMcuhub.ValueType.Imu
      assert payload.observer == :ui_obs
    end

    test "a subscriber to the base observer topic sees the whole feed" do
      sink = Sink.PubSub.new(robot: @robot, topic: [:observe])

      {:ok, observer} =
        Observer.start_link(
          robot: @robot,
          slots: [{:sensor_hub, :pose}],
          sink: sink,
          sample_ms: @never
        )

      on_exit(fn -> if Process.alive?(observer), do: GenServer.stop(observer) end)

      # the ancestor topic [:observe] receives every per-slot publish under it
      BB.subscribe(@robot, [:observe])

      put({:sensor_hub, :pose}, %{az: 1.0}, 1)
      tick(observer)
      put({:sensor_hub, :pose}, %{az: 2.0}, 2)
      tick(observer)

      assert_receive {:bb, [:observe, :sensor_hub, :pose], %BB.Message{payload: %Sample{}}}, 200
    end
  end
end
