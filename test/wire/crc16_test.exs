defmodule BBMcuhub.Wire.CRC16Test do
  use ExUnit.Case, async: true
  alias BBMcuhub.Wire.CRC16
  doctest BBMcuhub.Wire.CRC16

  test "the pinned check value — the single test that catches a wrong variant" do
    # CRC-16/CCITT-FALSE check value is 0x29B1 over "123456789". If this fails,
    # the variant drifted (poly/init/reflection/xorout) — the §03 bug.
    assert CRC16.crc("123456789") == 0x29B1
  end

  test "empty input is the init value" do
    assert CRC16.crc(<<>>) == 0xFFFF
  end

  test "result is always a 16-bit value" do
    for n <- 0..64 do
      bytes = :crypto.strong_rand_bytes(n)
      crc = CRC16.crc(bytes)
      assert crc in 0..0xFFFF
    end
  end

  test "a single flipped bit changes the CRC" do
    base = <<0x02, 0x10, 0x00, 0x2A, 0x3F, 0x80, 0x00, 0x00>>
    flipped = <<0x02, 0x10, 0x00, 0x2B, 0x3F, 0x80, 0x00, 0x00>>
    assert CRC16.crc(base) != CRC16.crc(flipped)
  end
end
