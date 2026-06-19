defmodule SegbyV1.DriftTest do
  @moduledoc """
  The example's OWN drift test (ADR-0003): the build is red if segby's committed
  firmware artifacts (`firmware/gen/segby_v1/*`) or its parity fixture
  (`test/fixtures/segby_v1/parity_vectors.exs`) could disagree with what the
  library's generator (`BBMcuhub.Gen.WireGen`) emits for `SegbyV1.Robot` NOW.

  This is the CONSUMER side of the generation seam: the example invokes the
  library's WireGen with its OWN output base (the example's `firmware/gen` +
  `test/fixtures`), regenerates in-memory, and compares against the files on disk.
  The committed artifacts are the example's, not the library's. Regenerate with
  `mix wire.gen` (the example's alias) + commit; a non-empty diff means a contract
  moved and the bytes moved with it.

  It also re-runs the Elixir codec over the committed parity rows (encode + decode
  round-trip), proving the data-driven codec agrees with the bytes byte-for-byte.
  """
  # Not async: the decode round-trip builds the global PortIndex (:persistent_term).
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Gen.WireGen
  alias BBMcuhub.Wire.{Codec, CRC16}

  @robot SegbyV1.Robot

  # The example's OWN output base — cwd-relative (the example app's root), so the
  # generator emits into THIS tree, not the library's (ADR-0003). The slug is
  # PINNED to "segby_v1" (the robot module's last segment is the generic "Robot",
  # so `WireGen.slug/1` would give "robot"); the example's `mix wire.gen` alias
  # passes the same `--slug segby_v1`, so the committed dir is `gen/segby_v1/`.
  @slug "segby_v1"
  @base %{gen: ["firmware", "gen"], fixtures: ["test", "fixtures"]}

  defp gen_path(file), do: WireGen.gen_dir(@base, @slug, file)
  defp fixtures_path, do: WireGen.fixtures_path(@base, @slug)

  describe "the example's committed artifacts are not stale (a hand-edit or stale checkout fails here)" do
    test "wire_contract.h matches the emitter now" do
      ir = WireGen.ir(@robot)
      assert File.read!(gen_path("wire_contract.h")) == WireGen.emit_c_header(ir)
    end

    test "the parity-vector fixture matches the emitter now" do
      ir = WireGen.ir(@robot)
      assert File.read!(fixtures_path()) == WireGen.emit_parity(ir)
    end

    test "the C parity-vector header matches the emitter now" do
      ir = WireGen.ir(@robot)
      assert File.read!(gen_path("parity_vectors.h")) == WireGen.emit_parity_c(ir)
    end

    test "each hub's generated glue + device header match the emitters now" do
      ir = WireGen.ir(@robot)

      for hub <- ir |> Enum.map(& &1.hub) |> Enum.uniq() do
        assert File.read!(gen_path("#{hub}.glue.h")) == WireGen.emit_glue(ir, hub),
               "glue drift for #{hub}"

        assert File.read!(gen_path("#{hub}.device.h")) == WireGen.emit_device_header(ir, hub),
               "device-header drift for #{hub}"
      end
    end

    test "the wire contract SHA is the locked segby_v1 value" do
      # The wire didn't change in the library/example move (only the namespace +
      # location + the value-type REFERENCE did). The SHA hashes the IR; the
      # range/led ports now name CONSUMER modules instead of stock atoms, so the
      # IR's `type` field carries the module — this is the locked post-move SHA.
      ir = WireGen.ir(@robot)
      sha = WireGen.contract_sha(ir)
      assert File.read!(gen_path("wire_contract.h")) =~ ~s(#define WIRE_CONTRACT_SHA "#{sha}")
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
      # The codec decodes via the global PortIndex, built for THIS robot so its
      # (node, port_id) pairs resolve to the right type.
      PortIndex.build(@robot)

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

  defp parity_rows do
    {rows, _} = Code.eval_file(fixtures_path())
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
