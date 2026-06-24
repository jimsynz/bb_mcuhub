defmodule BBMCUHub.Gen.WireDriftTest do
  @moduledoc """
  The build is red if the committed artifacts could disagree with the contract,
  or if the Elixir codec disagrees with the committed parity bytes (§06).

  Artifacts are robot-scoped (§09): each robot owns `firmware/gen/<slug>/` and
  `test/fixtures/<slug>/`, so the drift check runs PER ROBOT. The library's
  committed robot is its test FIXTURE (segby_v1 moved to the example app, which
  has its own drift test).
  """
  # Not async: the decode round-trip builds the global PortIndex per robot
  # (:persistent_term), so two robots' decode tests must not race on it.
  use ExUnit.Case, async: false

  alias BBMCUHub.Contract.PortIndex
  alias BBMCUHub.Gen.WireGen
  alias BBMCUHub.Wire.{Codec, CRC16}

  # Every robot whose artifacts the LIBRARY commits (§09). Adding a robot here
  # makes the drift test guard its generated dir too. The library's drift/C-parity
  # witness is the test FIXTURE robot (ADR-0003); segby_v1 moved to the example
  # app (Phase 5), which has its own drift test.
  @robots [BBMCUHub.Test.Fixtures.Robot]

  describe "generated artifacts are not stale (a hand-edit or stale checkout fails here)" do
    for robot <- @robots do
      @robot robot

      test "#{inspect(robot)}: wire_contract.h matches the emitter now" do
        ir = WireGen.ir(@robot)
        slug = WireGen.slug(@robot)
        assert File.read!(WireGen.gen_dir(slug, "wire_contract.h")) == WireGen.emit_c_header(ir)
      end

      test "#{inspect(robot)}: the parity-vector fixture matches the emitter now" do
        ir = WireGen.ir(@robot)
        slug = WireGen.slug(@robot)
        assert File.read!(WireGen.fixtures_path(slug)) == WireGen.emit_parity(ir)
      end

      test "#{inspect(robot)}: the C parity-vector header matches the emitter now" do
        ir = WireGen.ir(@robot)
        slug = WireGen.slug(@robot)
        assert File.read!(WireGen.gen_dir(slug, "parity_vectors.h")) == WireGen.emit_parity_c(ir)
      end

      test "#{inspect(robot)}: each hub's generated glue + device header match the emitters now" do
        ir = WireGen.ir(@robot)
        slug = WireGen.slug(@robot)

        for hub <- ir |> Enum.map(& &1.hub) |> Enum.uniq() do
          assert File.read!(WireGen.gen_dir(slug, "#{hub}.glue.h")) == WireGen.emit_glue(ir, hub),
                 "glue drift for #{hub}"

          assert File.read!(WireGen.gen_dir(slug, "#{hub}.device.h")) ==
                   WireGen.emit_device_header(ir, hub),
                 "device-header drift for #{hub}"
        end
      end
    end
  end

  describe "the Elixir codec reproduces every parity row byte-for-byte" do
    for robot <- @robots do
      @robot robot

      test "#{inspect(robot)}: encode matches the committed body and CRC" do
        for row <- parity_rows(@robot) do
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

      test "#{inspect(robot)}: decode round-trips every parity body back to its value" do
        # The codec decodes via the global PortIndex, which is per-robot; build it
        # for THIS robot so its (node, port_id) pairs resolve to the right type.
        PortIndex.build(@robot)
        on_exit(fn -> PortIndex.build(BBMCUHub.Test.Fixtures.Robot) end)

        for row <- parity_rows(@robot) do
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
  end

  test "the CRC variant is pinned (the §03 bug guard)" do
    assert CRC16.crc("123456789") == 0x29B1
  end

  defp parity_rows(robot) do
    {rows, _} = Code.eval_file(WireGen.fixtures_path(WireGen.slug(robot)))
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
