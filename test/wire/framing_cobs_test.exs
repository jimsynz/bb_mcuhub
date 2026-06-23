defmodule BBMcuhub.Wire.FramingCOBSTest do
  use ExUnit.Case, async: false
  alias BBMcuhub.Wire.{FramingCOBS, Stats}

  setup do
    Stats.setup()
    {:ok, st} = FramingCOBS.init([])
    %{st: st}
  end

  describe "add_framing then remove_framing round-trips a whole frame (§03)" do
    test "one body in, one body out", %{st: st} do
      body = <<0x02, 0x10, 0x00, 0x2A, 0x3F, 0x80, 0x00, 0x00>>
      {:ok, frame, st} = FramingCOBS.add_framing(body, st)

      # frame is null-free except the single trailing delimiter
      assert :binary.last(frame) == 0x00
      assert <<head::binary-size(byte_size(frame) - 1), 0x00>> = frame
      refute 0 in :binary.bin_to_list(head)

      assert {:ok, [^body], _st} = FramingCOBS.remove_framing(frame, st)
    end
  end

  describe "the seam drops garbage and reports :in_frame for partials" do
    test "a frame split across two reads is held then delivered", %{st: st} do
      body = <<0x05, 0x20, 0x00, 0x01, 0xAB, 0xCD>>
      {:ok, frame, _} = FramingCOBS.add_framing(body, st)
      cut = div(byte_size(frame), 2)
      <<first::binary-size(cut), second::binary>> = frame

      assert {:in_frame, [], st} = FramingCOBS.remove_framing(first, st)
      assert {:ok, [^body], _st} = FramingCOBS.remove_framing(second, st)
    end

    test "a structurally-broken frame is dropped and counted (rx_drop), never delivered",
         %{st: st} do
      body = <<0x02, 0x10, 0x00, 0x2A>>
      {:ok, frame, st} = FramingCOBS.add_framing(body, st)

      # Flip the leading COBS *code* byte: this corrupts the run structure (the
      # block length no longer matches the bytes), so the frame never decodes into
      # a well-formed body+CRC pair — a generic drop, not a CRC mismatch.
      <<h, rest::binary>> = frame
      corrupt = <<bxor_one(h), rest::binary>>

      before = Stats.get(:rx_drop)
      assert {:ok, [], _st} = FramingCOBS.remove_framing(corrupt, st)
      assert Stats.get(:rx_drop) == before + 1
    end

    test "a COBS-valid frame with a corrupted body is counted as crc_fail, never delivered",
         %{st: st} do
      # A body with NO 0x00 bytes encodes to a single COBS block, so flipping a
      # *data* byte keeps the run well-formed: COBS decodes cleanly and the only
      # failure is the integrity check. That is a CRC mismatch — counted distinctly
      # as crc_fail, NOT rx_drop (the wire stays legible about the *kind* of fault).
      body = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      {:ok, frame, st} = FramingCOBS.add_framing(body, st)

      # flip a middle data byte (^0x01 can't turn 0x33 into a 0x00 delimiter)
      <<a, b, c, rest::binary>> = frame
      corrupt = <<a, b, bxor_one(c), rest::binary>>

      crc_before = Stats.get(:crc_fail)
      drop_before = Stats.get(:rx_drop)
      assert {:ok, [], _st} = FramingCOBS.remove_framing(corrupt, st)
      assert Stats.get(:crc_fail) == crc_before + 1, "a clean-COBS CRC mismatch is crc_fail"

      assert Stats.get(:rx_drop) == drop_before,
             "a CRC mismatch must NOT be miscounted as rx_drop"
    end

    test "two frames glued together both come out", %{st: st} do
      b1 = <<0x01, 0x10, 0x00, 0x01>>
      b2 = <<0x02, 0x20, 0x00, 0x02, 0xFF>>
      {:ok, f1, st} = FramingCOBS.add_framing(b1, st)
      {:ok, f2, st} = FramingCOBS.add_framing(b2, st)

      assert {:ok, bodies, _st} = FramingCOBS.remove_framing(f1 <> f2, st)
      assert bodies == [b1, b2]
    end

    test "an empty run between two delimiters is ignored", %{st: st} do
      assert {:ok, [], _st} = FramingCOBS.remove_framing(<<0x00, 0x00>>, st)
    end
  end

  test "frame_timeout discards a stalled partial", %{st: st} do
    assert {:in_frame, [], st} = FramingCOBS.remove_framing(<<0x03, 0x11>>, st)
    assert {:ok, [], st} = FramingCOBS.frame_timeout(st)
    assert st.rx == <<>>
  end

  defp bxor_one(b), do: Bitwise.bxor(b, 0x01)
end
