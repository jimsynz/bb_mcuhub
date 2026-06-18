defmodule BBMcuhub.Wire.CRC16 do
  @moduledoc """
  CRC-16/CCITT-FALSE — the **one** pinned variant, so the C and Elixir sides
  cannot differ (§03, §06).

      poly 0x1021 · init 0xFFFF · NO input/output reflection · xorout 0x0000

  The check value MUST be `0x29B1` over the ASCII bytes `"123456789"`. That is
  asserted by a test, not by faith (`BBMcuhub.Wire.CRC16Test`).

  ## Why this module exists

  The old prototype computed `:erlang.crc32(body) |> rem(65536)` — the low 16
  bits of CRC-32, which is a *different function* from CRC-16-CCITT, not a
  truncation of one. A corrupted `seq` that slips a weak check poisons the whole
  freshness story (§04), so v1 uses a real, pinned CRC-16 and a parity-vector
  fixture that proves both languages hash the same bytes.
  """
  import Bitwise

  @doc """
  CRC-16/CCITT-FALSE over a binary, starting from the pinned init value.

  ## Examples

      iex> BBMcuhub.Wire.CRC16.crc("123456789")
      0x29B1

      iex> BBMcuhub.Wire.CRC16.crc(<<>>)
      0xFFFF
  """
  @spec crc(binary()) :: 0..0xFFFF
  def crc(bin) when is_binary(bin), do: crc(bin, 0xFFFF)

  @spec crc(binary(), 0..0xFFFF) :: 0..0xFFFF
  def crc(<<>>, acc), do: acc

  def crc(<<b, rest::binary>>, acc) do
    # top byte XOR next input byte; the table-free "x = x ^ (x >> 4)" form of
    # the CCITT polynomial, identical math to the byte-at-a-time table version.
    x = bxor(acc >>> 8, b) &&& 0xFF
    x = bxor(x, x >>> 4)
    acc = bxor(bxor(bxor(acc <<< 8, x <<< 12), x <<< 5), x) &&& 0xFFFF
    crc(rest, acc)
  end
end
