defmodule BBMcuhub.Wire.COBS do
  @moduledoc """
  Consistent Overhead Byte Stuffing (§03).

  COBS replaces every `0x00` in the body with a pointer to the next `0x00`, so
  the encoding is guaranteed **null-free** and a lone `0x00` is an unambiguous
  frame delimiter. Overhead is `ceil(n / 254)` bytes — bounded.

  Pure, no I/O. The round-trip is verified over the edge cases (an embedded
  `0x00`, a zero-run, the 254-byte block boundary, a real frame) in
  `BBMcuhub.Wire.COBSTest`, and `transport.c` on the hub mirrors this exactly
  (the parity vectors are the cross-language witness, §06).
  """

  @doc """
  Encode a binary into a null-free COBS run. The result never contains `0x00`,
  so the caller appends a single `0x00` as the frame delimiter.

  ## Examples

      iex> BBMcuhub.Wire.COBS.encode(<<0x11, 0x22, 0x00, 0x33>>)
      <<0x03, 0x11, 0x22, 0x02, 0x33>>

      iex> BBMcuhub.Wire.COBS.encode(<<0x00>>)
      <<0x01, 0x01>>
  """
  @spec encode(binary()) :: binary()
  def encode(data) when is_binary(data), do: enc(data, [], <<>>)

  # Each block is at most 254 payload bytes, emitted as <<len+1, block>>.
  # A maximal 254-byte block uses code 0xFF and implies NO trailing zero.
  defp enc(<<>>, blocks, cur), do: emit([cur | blocks])
  defp enc(<<0, rest::binary>>, blocks, cur), do: enc(rest, [cur | blocks], <<>>)

  defp enc(<<b, rest::binary>>, blocks, cur) when byte_size(cur) == 253,
    do: enc(rest, [<<cur::binary, b>> | blocks], <<>>)

  defp enc(<<b, rest::binary>>, blocks, cur),
    do: enc(rest, blocks, <<cur::binary, b>>)

  defp emit(blocks) do
    blocks
    |> Enum.reverse()
    |> Enum.map_join(fn blk -> <<byte_size(blk) + 1, blk::binary>> end)
  end

  @doc """
  Decode a COBS run (the bytes *between* delimiters) back to the original body.

  Returns `{:error, :truncated}` when a code byte points past the available data
  — i.e. a corrupt or short frame. The framing layer treats that as a dropped
  frame (§03).

  ## Examples

      iex> BBMcuhub.Wire.COBS.decode(<<0x03, 0x11, 0x22, 0x02, 0x33>>)
      {:ok, <<0x11, 0x22, 0x00, 0x33>>}

      iex> BBMcuhub.Wire.COBS.decode(<<0x05, 0x11>>)
      {:error, :truncated}
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, :truncated}
  def decode(data) when is_binary(data), do: dec(data, <<>>, true)

  defp dec(<<>>, acc, _first), do: {:ok, acc}

  defp dec(<<code, rest::binary>>, acc, first) do
    n = code - 1

    case rest do
      <<blk::binary-size(n), tail::binary>> ->
        # Re-insert the 0x00 this code stood in for — except before the very
        # first block, and except after a full (0xFF) block which implied none.
        acc = if first, do: acc, else: acc <> <<0>>
        dec(tail, acc <> blk, code == 0xFF)

      _ ->
        {:error, :truncated}
    end
  end
end
