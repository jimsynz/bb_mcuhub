defmodule BBMcuhub.Wire.COBSTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BBMcuhub.Wire.COBS
  doctest BBMcuhub.Wire.COBS

  describe "encode/decode round-trip on the edge cases (§03)" do
    test "empty body" do
      assert round_trip(<<>>) == <<>>
    end

    test "a single embedded zero" do
      assert round_trip(<<0x11, 0x22, 0x00, 0x33>>) == <<0x11, 0x22, 0x00, 0x33>>
    end

    test "a run of zeros" do
      assert round_trip(<<0, 0, 0, 0>>) == <<0, 0, 0, 0>>
    end

    test "leading and trailing zeros" do
      assert round_trip(<<0, 0x11, 0>>) == <<0, 0x11, 0>>
    end

    test "the 254-byte block boundary (code 0xFF, no implicit zero)" do
      body = :binary.copy(<<0x41>>, 254)
      assert round_trip(body) == body
    end

    test "just over the block boundary" do
      body = :binary.copy(<<0x41>>, 255)
      assert round_trip(body) == body
    end

    test "254 non-zero bytes followed by a zero" do
      body = :binary.copy(<<0x41>>, 254) <> <<0x00>>
      assert round_trip(body) == body
    end

    test "a realistic frame body (node·port·seq·t_dev·payload)" do
      body =
        <<0x02, 0x10, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xD2, 0x3F, 0x80,
          0x00, 0x00>>

      assert round_trip(body) == body
    end
  end

  describe "the null-free guarantee" do
    test "encode output never contains 0x00" do
      for body <- [<<>>, <<0>>, <<0, 0>>, <<1, 0, 2>>, :binary.copy(<<0>>, 300)] do
        refute 0 in :binary.bin_to_list(COBS.encode(body))
      end
    end
  end

  describe "decode rejects corruption" do
    test "a code byte pointing past the data is :truncated" do
      assert COBS.decode(<<0x05, 0x11>>) == {:error, :truncated}
    end
  end

  property "round-trips any binary, and the encoding is always null-free" do
    check all(body <- binary(max_length: 600)) do
      encoded = COBS.encode(body)
      refute 0 in :binary.bin_to_list(encoded)
      assert COBS.decode(encoded) == {:ok, body}
    end
  end

  defp round_trip(body) do
    {:ok, out} = COBS.decode(COBS.encode(body))
    out
  end
end
