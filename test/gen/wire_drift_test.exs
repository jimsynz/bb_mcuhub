defmodule BBMcuhub.Gen.WireDriftTest do
  @moduledoc """
  The build is red if the committed artifacts could disagree with the contract,
  or if the Elixir codec disagrees with the committed parity bytes (§06).
  """
  use ExUnit.Case, async: true

  alias BBMcuhub.Gen.WireGen
  alias BBMcuhub.Wire.{Codec, CRC16}

  @robot BBMcuhub.Contract.Source.default_robot()

  setup_all do
    %{ir: WireGen.ir(@robot)}
  end

  describe "generated artifacts are not stale (a hand-edit or stale checkout fails here)" do
    test "wire_contract.h matches the emitter now", %{ir: ir} do
      assert File.read!("firmware/include/wire_contract.h") == WireGen.emit_c_header(ir)
    end

    test "the parity-vector fixture matches the emitter now", %{ir: ir} do
      assert File.read!("test/fixtures/parity_vectors.exs") == WireGen.emit_parity(ir)
    end

    test "each hub's schedule matches its ports' rates", %{ir: ir} do
      for hub <- ir |> Enum.map(& &1.hub) |> Enum.uniq() do
        assert File.read!("hubs/#{hub}/mcu/schedule.gen.h") == WireGen.emit_schedule(ir, hub)
      end
    end
  end

  describe "the Elixir codec reproduces every parity row byte-for-byte" do
    test "encode matches the committed body and CRC" do
      for row <- parity_rows() do
        body =
          Codec.encode_body(
            row.node,
            row.port_id,
            row.seq,
            row.t_dev,
            row.type,
            row.value,
            row.stamped
          )

        assert body == row.body, "body drift for #{row.hub}/#{row.port}"
        assert CRC16.crc(body) == row.crc, "crc drift for #{row.hub}/#{row.port}"
      end
    end

    test "decode round-trips every parity body back to its value" do
      for row <- parity_rows() do
        assert {:ok, decoded} = Codec.decode_body(row.body)
        assert decoded.node == row.node
        assert decoded.port_id == row.port_id
        assert decoded.seq == row.seq
        # t_dev rides only on a stamped port (§04); unstamped decodes to nil
        assert decoded.t_dev == if(row.stamped, do: row.t_dev, else: nil)
        assert decoded.type == row.type
        assert_value_equal(decoded.value, row.value)
      end
    end
  end

  test "the CRC variant is pinned (the §03 bug guard)" do
    assert CRC16.crc("123456789") == 0x29B1
  end

  defp parity_rows do
    {rows, _} = Code.eval_file("test/fixtures/parity_vectors.exs")
    rows
  end

  # floats survive the f32 round-trip exactly for our representative values
  defp assert_value_equal(got, want) do
    assert Map.keys(got) |> Enum.sort() == Map.keys(want) |> Enum.sort()

    for {k, v} <- want do
      case v do
        f when is_float(f) -> assert_in_delta(got[k], f, 1.0e-6)
        other -> assert got[k] == other
      end
    end
  end
end
