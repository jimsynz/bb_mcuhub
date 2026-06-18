defmodule BBMcuhub.Host.LinkOwnerTest do
  use ExUnit.Case, async: false

  alias BBMcuhub.Host.{LinkOwner, NodeRegistry}
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Test.LoopbackTransport
  alias BBMcuhub.Wire.{Codec, Stats}

  setup do
    # NodeRegistry is started by the application supervisor; just clear it.
    :ets.delete_all_objects(NodeRegistry.table())
    PortIndex.build()
    Stats.setup()
    :ok
  end

  defp start_link_owner(opts \\ []) do
    test_pid = self()

    base = [
      transport: LoopbackTransport,
      transport_opts: [],
      drain_ms: 5,
      name: nil
    ]

    {:ok, owner} = LinkOwner.start_link(Keyword.merge(base, opts))
    # the loopback transport's pid is the link owner's `:transport` field
    transport = :sys.get_state(owner).transport
    _ = test_pid
    %{owner: owner, transport: transport}
  end

  test "inbound: a received body lands in the registry by (node, port)" do
    %{transport: transport} = start_link_owner()
    {:ok, {node, port_id}} = PortIndex.resolve(:imu, :pose)

    value = %{
      qw: 1.0,
      qx: 0.0,
      qy: 0.0,
      qz: 0.0,
      wx: 0.0,
      wy: 0.0,
      wz: 0.0,
      ax: 0.0,
      ay: 0.0,
      az: 9.81
    }

    body = Codec.encode_body(node, port_id, 7, 1234, :imu, value, true)

    LoopbackTransport.inject(transport, body)

    assert_eventually(fn ->
      case NodeRegistry.get(node, port_id) do
        {got, 7, 1234} -> abs(got.az - 9.81) < 1.0e-5
        _ -> false
      end
    end)
  end

  test "inbound: an undecodable body is counted as decode_fail and dropped" do
    %{transport: transport} = start_link_owner()
    before = Stats.get(:decode_fail)

    # a body for an unknown port id — decodes to :error
    bogus = Codec.encode_body(0x02, 0x01, 1, 1, :effort, %{nm: 0.0})
    LoopbackTransport.inject(transport, bogus)

    assert_eventually(fn -> Stats.get(:decode_fail) >= before + 1 end)
  end

  test "outbound: a command slot is drained to the wire when its seq advances" do
    {:ok, {node, port_id}} = PortIndex.resolve(:motor, :motor_target)
    %{transport: transport} = start_link_owner(command_slots: [{node, port_id}])

    # the actuator view (here, the test) is the sole writer of the command slot
    NodeRegistry.put(node, port_id, %{nm: 0.5}, 1, 100)

    assert_eventually(fn ->
      case LoopbackTransport.sent(transport) do
        [body | _] ->
          case Codec.decode_body(body) do
            {:ok, %{node: ^node, port_id: ^port_id, seq: 1, value: v}} -> abs(v.nm - 0.5) < 1.0e-5
            _ -> false
          end

        [] ->
          false
      end
    end)
  end

  test "outbound: an unchanged command slot is NOT re-sent (seq inequality)" do
    {:ok, {node, port_id}} = PortIndex.resolve(:motor, :motor_target)
    %{transport: transport} = start_link_owner(command_slots: [{node, port_id}])

    NodeRegistry.put(node, port_id, %{nm: 0.5}, 1, 100)
    assert_eventually(fn -> length(LoopbackTransport.sent(transport)) == 1 end)

    # let several drain ticks pass with no seq change
    Process.sleep(40)
    assert length(LoopbackTransport.sent(transport)) == 1

    # a new value (advanced seq) is sent
    NodeRegistry.put(node, port_id, %{nm: 0.6}, 2, 200)
    assert_eventually(fn -> length(LoopbackTransport.sent(transport)) == 2 end)
  end

  defp assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(fun, tries - 1)
    end
  end
end
