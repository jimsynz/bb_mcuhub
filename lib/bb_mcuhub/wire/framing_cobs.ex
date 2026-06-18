defmodule BBMcuhub.Wire.FramingCOBS do
  @moduledoc """
  COBS + CRC-16 framing for the host↔root-hub UART — the `Circuits.UART.Framing`
  behaviour (§03).

  This is the one place a byte stream becomes *whole, CRC-clean* frames. It
  accumulates bytes, splits on the `0x00` delimiter, COBS-decodes each piece,
  checks the trailing CRC-16, and passes up **only** the bodies that survive. A
  bad CRC, a truncated COBS run, or noise is dropped and counted here
  (`BBMcuhub.Wire.Stats`), so nothing above the seam ever sees a corrupt frame —
  the codec (§06/§07) never has to defend against garbage, and a corrupted `seq`
  can never fake an advance (§04).

  Wire shape per frame: `COBS(body <> CRC16(body)) <> 0x00`.
  """
  @behaviour Circuits.UART.Framing

  alias BBMcuhub.Wire.{COBS, CRC16, Stats}

  @delim 0x00

  @impl true
  # rx = bytes seen so far but not yet a complete frame
  def init(_args), do: {:ok, %{rx: <<>>}}

  @impl true
  # OUTBOUND: a full body in, a COBS-encoded delimited frame out.
  def add_framing(body, st) when is_binary(body) do
    frame = COBS.encode(body <> <<CRC16.crc(body)::16>>) <> <<@delim>>
    {:ok, frame, st}
  end

  @impl true
  # INBOUND: append new bytes, peel off every complete (delimited) frame, decode
  # + CRC-check each. Good bodies go up; bad ones are counted and dropped.
  def remove_framing(data, st) do
    {frames, rest} = split(st.rx <> data, [])
    bodies = for f <- frames, {:ok, body} <- [verify(f)], do: body
    in_frame = if rest == <<>>, do: :ok, else: :in_frame
    {in_frame, bodies, %{st | rx: rest}}
  end

  @impl true
  # a stalled partial frame is discarded, not delivered
  def frame_timeout(st), do: {:ok, [], %{st | rx: <<>>}}

  @impl true
  def flush(_direction, st), do: %{st | rx: <<>>}

  # Peel complete frames at each 0x00 delimiter; keep the trailing partial in rx.
  defp split(buf, acc) do
    case :binary.split(buf, <<@delim>>) do
      [frame, rest] -> split(rest, [frame | acc])
      [partial] -> {Enum.reverse(acc), partial}
    end
  end

  # One frame: COBS-decode, split body from its 2-byte CRC, and check it.
  defp verify(<<>>) do
    # empty run between two delimiters → ignore, not an error worth counting
    :error
  end

  defp verify(frame) do
    with {:ok, decoded} <- cobs_decode(frame),
         true <- byte_size(decoded) >= 2,
         <<body::binary-size(byte_size(decoded) - 2), crc::16>> <- decoded,
         true <- crc == CRC16.crc(body) do
      {:ok, body}
    else
      _ ->
        Stats.bump(:rx_drop)
        :error
    end
  end

  defp cobs_decode(frame) do
    case COBS.decode(frame) do
      {:ok, _} = ok ->
        ok

      {:error, :truncated} = err ->
        Stats.bump(:cobs_truncated)
        err
    end
  end
end
