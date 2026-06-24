defmodule BBMcuhub.Host.LinkOwnerTest do
  use ExUnit.Case, async: false

  alias BBMcuhub.Host.{LinkOwner, NodeRegistry}
  alias BBMcuhub.Host.Transport.Loopback, as: LoopbackTransport
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Wire.{Codec, Stats}

  setup do
    # NodeRegistry is started by the application supervisor; just clear it.
    NodeRegistry.reset()
    PortIndex.build(BBMcuhub.Test.Fixtures.Robot)
    Stats.setup()
    :ok
  end

  defp start_link_owner(opts \\ []) do
    base = [
      transport: LoopbackTransport,
      transport_opts: [],
      name: nil
    ]

    {:ok, owner} = LinkOwner.start_link(Keyword.merge(base, opts))
    # the loopback transport's pid is the link owner's `:transport` field
    transport = :sys.get_state(owner).transport
    %{owner: owner, transport: transport}
  end

  test "inbound: a received body lands in the registry by (node, port)" do
    %{transport: transport} = start_link_owner()
    {:ok, {node, port_id}} = PortIndex.resolve(:sensor_hub, :pose)

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

  test "outbound: a command slot is drained to the wire when notified after a write" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :effort_cmd)
    %{owner: owner, transport: transport} = start_link_owner(command_slots: [{node, port_id}])

    # the actuator view (here, the test) is the sole writer of the command slot:
    # write, then notify the link owner (event-driven, no poll).
    NodeRegistry.put(node, port_id, %{nm: 0.5}, 1, 100)
    LinkOwner.notify_command_slot(owner, node, port_id)

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

  test "outbound: a redundant notification with no seq change is NOT re-sent (seq inequality)" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :effort_cmd)
    %{owner: owner, transport: transport} = start_link_owner(command_slots: [{node, port_id}])

    NodeRegistry.put(node, port_id, %{nm: 0.5}, 1, 100)
    LinkOwner.notify_command_slot(owner, node, port_id)
    assert_eventually(fn -> length(LoopbackTransport.sent(transport)) == 1 end)

    # further notifications with no seq change must not re-send (read-only,
    # seq-inequality dedup is preserved without the poll)
    LinkOwner.notify_command_slot(owner, node, port_id)
    LinkOwner.notify_command_slot(owner, node, port_id)
    # let the casts process
    _ = :sys.get_state(owner)
    assert length(LoopbackTransport.sent(transport)) == 1

    # a new value (advanced seq) is sent on the next notification
    NodeRegistry.put(node, port_id, %{nm: 0.6}, 2, 200)
    LinkOwner.notify_command_slot(owner, node, port_id)
    assert_eventually(fn -> length(LoopbackTransport.sent(transport)) == 2 end)
  end

  test "outbound: a malformed command value is counted as encode_fail and skipped, the drain survives" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :effort_cmd)
    %{owner: owner, transport: transport} = start_link_owner(command_slots: [{node, port_id}])
    before = Stats.get(:encode_fail)

    # the :effort layout is %{nm: f32}; a value MISSING that field cannot be packed
    # (encode_fields' Map.fetch! would raise). The link owner must count it and
    # carry on, NOT crash the drain (which would take down telemetry + every slot).
    NodeRegistry.put(node, port_id, %{wrong: 0.5}, 1, 100)
    LinkOwner.notify_command_slot(owner, node, port_id)

    assert_eventually(fn -> Stats.get(:encode_fail) >= before + 1 end)
    # nothing reached the wire, and the owner is still alive
    assert LoopbackTransport.sent(transport) == []
    assert Process.alive?(owner)

    # a SUBSEQUENT well-formed command on the same slot still drains — the bad one
    # did not poison the drain (the floor backstopped the gap meanwhile).
    NodeRegistry.put(node, port_id, %{nm: 0.5}, 2, 200)
    LinkOwner.notify_command_slot(owner, node, port_id)

    assert_eventually(fn ->
      case LoopbackTransport.sent(transport) do
        [body | _] ->
          match?({:ok, %{node: ^node, port_id: ^port_id, seq: 2}}, Codec.decode_body(body))

        [] ->
          false
      end
    end)
  end

  test "outbound: a notification for an unwatched slot is ignored (never written by the owner)" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :effort_cmd)
    # start with NO command slots registered
    %{owner: owner, transport: transport} = start_link_owner()

    NodeRegistry.put(node, port_id, %{nm: 0.5}, 1, 100)
    LinkOwner.notify_command_slot(owner, node, port_id)
    _ = :sys.get_state(owner)

    # an unregistered slot is not drained — the owner only drains slots it watches
    assert LoopbackTransport.sent(transport) == []
  end

  defp assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(fun, tries - 1)
    end
  end
end
