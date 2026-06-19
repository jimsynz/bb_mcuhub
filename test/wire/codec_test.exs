defmodule BBMcuhub.Wire.CodecTest do
  use ExUnit.Case, async: true
  alias BBMcuhub.Wire.Codec
  alias BBMcuhub.Contract.PortIndex

  setup_all do
    PortIndex.build(BBMcuhub.Test.Fixtures.Robot)
    :ok
  end

  test "encode/decode round-trips an effort value (unstamped: no t_dev)" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :effort_cmd)
    # effort_cmd is unstamped — the t_dev arg is ignored and decodes to nil (§04)
    body = Codec.encode_body(node, port_id, 7, 99, :effort, %{nm: 0.25})

    assert {:ok, d} = Codec.decode_body(body)
    assert d.node == node
    assert d.port_id == port_id
    assert d.seq == 7
    assert d.t_dev == nil
    assert d.type == :effort
    assert_in_delta d.value.nm, 0.25, 1.0e-6
  end

  test "encode/decode round-trips a stamped imu value (carries t_dev)" do
    {:ok, {node, port_id}} = PortIndex.resolve(:sensor_hub, :pose)

    v = %{
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

    body = Codec.encode_body(node, port_id, 7, 1234, :imu, v, true)

    assert {:ok, d} = Codec.decode_body(body)
    assert d.t_dev == 1234
    assert_in_delta d.value.az, 9.81, 1.0e-5
  end

  test "decode of an unknown (node, port_id) is :error (dropped, not guessed)" do
    # port_id 0x01 is never assigned (ids live in 0x10..0xEF)
    body = Codec.encode_body(0x02, 0x01, 1, 1, :effort, %{nm: 0.0})
    assert Codec.decode_body(body) == :error
  end

  test "decode of a too-short payload is :error" do
    {:ok, {node, port_id}} = PortIndex.resolve(:sensor_hub, :pose)
    # an imu needs 10 floats; give it only the header + 1 float
    short =
      Codec.encode_body(node, port_id, 1, 1, :imu, all_floats(:imu), true) |> binary_part(0, 16)

    assert Codec.decode_body(short) == :error
  end

  test "bool round-trips both ways through status" do
    {:ok, {node, port_id}} = PortIndex.resolve(:act_hub, :act_status)

    for floored <- [true, false] do
      body = Codec.encode_body(node, port_id, 1, 1, :status, %{applied_seq: 3, floored: floored})
      assert {:ok, d} = Codec.decode_body(body)
      assert d.value.floored == floored
      assert d.value.applied_seq == 3
    end
  end

  defp all_floats(:imu) do
    [:qw, :qx, :qy, :qz, :wx, :wy, :wz, :ax, :ay, :az]
    |> Map.new(&{&1, 0.0})
  end
end
