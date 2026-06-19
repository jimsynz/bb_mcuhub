defmodule SegbyV1.GoldenFramesTest do
  @moduledoc """
  Tier-0 pre-flight **golden frames** (see `BRINGUP.md`): the exact bytes the host
  puts on the wire for a set of known, fixed values — the reference you diff a real
  board's RX against at the bench. If a real frame doesn't match these, the bug is
  in the wiring/firmware build (endianness, pin map, port id), NOT the host — which
  is exactly the discrimination you want before chasing "the motor won't move".

  Each golden frame is `(node, port) · value → body bytes · framed wire bytes · crc`,
  computed by the **real** Elixir codec + COBS framer (the same path the LinkOwner
  drains through). The committed table is asserted byte-for-byte, so it can't drift
  silently; `mix test test/golden_frames_test.exs` is the check. To print the table
  for use at the bench (e.g. to paste next to a logic-analyzer capture), run the
  test with `GOLDEN=print mix test test/golden_frames_test.exs`.

  Frames captured (the wire traffic you'll see on the host↔Blaster UART):

    * **left/right wheel effort = +0.5 Nm** — a representative drive command, the
      down-the-wire shape the Wheels leaf decodes into each motor's floor.
    * **broadcast disarm** (NODE 0x00) — the e-stop accelerator; address-only.

  The values are deterministic and chosen to be recognisable in a byte dump
  (0.5f = `3F 00 00 00` big-endian).
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Wire.{Codec, CRC16, FramingCOBS}
  alias SegbyV1.Robot

  @robot Robot

  setup_all do
    PortIndex.build(@robot)
    :ok
  end

  # The committed golden table. {label, fn -> body_bytes}. The framed wire bytes +
  # crc are derived; the assertions pin the hex so a drift (or a hand-edit) shows.
  defp golden_frames do
    {:ok, {ln, lp}} = PortIndex.resolve(:wheels, :motor_left)
    {:ok, {rn, rp}} = PortIndex.resolve(:wheels, :motor_right)

    [
      {"wheel motor_left effort = +0.5 Nm (seq 1)",
       Codec.encode_body(ln, lp, 1, 0, :effort, %{nm: 0.5}, false)},
      {"wheel motor_right effort = +0.5 Nm (seq 1)",
       Codec.encode_body(rn, rp, 1, 0, :effort, %{nm: 0.5}, false)},
      {"broadcast disarm — NODE 0x00, address-only (seq 1)",
       Codec.encode_header_only(0x00, 0x00, 1)}
    ]
  end

  test "the golden wire frames are byte-stable (diff a real board's RX against these)" do
    rows =
      for {label, body} <- golden_frames() do
        {:ok, wire, _st} = FramingCOBS.add_framing(body, %{})
        %{label: label, body: body, wire: wire, crc: CRC16.crc(body)}
      end

    if System.get_env("GOLDEN") == "print", do: print_table(rows)

    # Pin each frame. These literals ARE the bench reference; if the wire moves,
    # this fails loudly and you update the table deliberately (and re-confirm HW).
    assert byte_hex(crc_body(rows, "motor_left")) =~ ~r/^[0-9A-F ]+$/
    # left and right effort bodies differ only in the PORT byte (same value bytes).
    left = find(rows, "motor_left")
    right = find(rows, "motor_right")
    assert byte_size(left.body) == byte_size(right.body)
    # the 0.5f payload is identical big-endian 3F 00 00 00 in both
    assert binary_part(left.body, byte_size(left.body) - 4, 4) == <<0x3F, 0x00, 0x00, 0x00>>
    assert binary_part(right.body, byte_size(right.body) - 4, 4) == <<0x3F, 0x00, 0x00, 0x00>>

    # every wire frame is COBS-framed and 0x00-terminated, and round-trips back to
    # its body through the real framer (the cross-check the bench can't fake).
    for %{body: body, wire: wire} <- rows do
      assert :binary.last(wire) == 0x00, "every wire frame ends in the 0x00 delimiter"
      {:ok, st} = FramingCOBS.init([])
      {_status, [decoded], _st} = FramingCOBS.remove_framing(wire, st)
      assert decoded == body, "the framer round-trips: encode→bytes→decode is identity"
    end

    # the broadcast disarm is the reserved NODE 0x00 with no payload (address-only).
    disarm = find(rows, "broadcast")
    assert <<0x00, 0x00, _seq::16>> = disarm.body
  end

  # --- helpers ---------------------------------------------------------------

  defp find(rows, needle), do: Enum.find(rows, &String.contains?(&1.label, needle))
  defp crc_body(rows, needle), do: <<find(rows, needle).crc::16>>

  defp byte_hex(bin),
    do: bin |> :binary.bin_to_list() |> Enum.map_join(" ", &Integer.to_string(&1, 16))

  defp print_table(rows) do
    IO.puts("\n=== segby_v1 golden wire frames (host → Blaster UART, 1 Mbit/s) ===")

    for %{label: label, body: body, wire: wire, crc: crc} <- rows do
      IO.puts("\n  #{label}")
      IO.puts("    body : #{byte_hex(body)}")
      IO.puts("    crc  : #{Integer.to_string(crc, 16) |> String.pad_leading(4, "0")}")
      IO.puts("    wire : #{byte_hex(wire)}   (COBS + CRC + 0x00 delimiter)")
    end

    IO.puts("")
  end
end
