defmodule BBMcuhub.Wire.Codec do
  @moduledoc """
  Encode/decode the on-wire body — `NODE · PORT · SEQ · T_DEV · PAYLOAD` — the
  part the CRC covers (§03). The frame codec (`FramingCOBS`) wraps a body with
  LEN, the CRC, and COBS framing; this module owns only the body bytes.

  ## One source of truth, no drift (§06)

  The byte layout is *read*, not hand-written: payload fields come from the port's
  value-type (`BBMcuhub.ValueType.resolve(type).layout()`) and the header from
  `BBMcuhub.Contract`. The same
  tables render the C header, the per-hub schedule, and the parity vectors via
  `BBMcuhub.Gen.WireGen`. Because this codec interprets those tables directly, it
  cannot drift from them within Elixir; the parity-vector fixture is the
  cross-language witness that the C side agrees byte-for-byte.

  All multi-byte integers and floats are **big-endian** (the order the C side
  serialises with too — see `transport.c`).

  A value is represented as a plain map of `field => number`, e.g.
  `%{nm: 0.5}` for an `:effort`, `%{qw: 1.0, qx: 0.0, ...}` for an `:imu`. Lifting
  to/from concrete `BB.Message` structs is the view's job (§09), not the codec's.
  """

  alias BBMcuhub.Contract
  alias BBMcuhub.Contract.{Layouts, PortIndex}
  alias BBMcuhub.ValueType

  # The base header read before the per-port index reveals whether t_dev follows.
  @base_header [node: :u8, port: :u8, seq: :u16]

  @type value :: %{atom() => number()}
  @type decoded :: %{
          node: 0..255,
          port_id: 0..255,
          seq: 0..0xFFFF,
          t_dev: non_neg_integer() | nil,
          type: atom(),
          value: value()
        }

  @doc """
  Encode a body from explicit header fields, a value type, and a value map.

  `stamped?` selects the header shape (§04): `true` carries `t_dev`, `false`
  omits it. The `t_dev` argument is ignored on an unstamped port. Returns the
  CRC-covered body bytes (NODE..PAYLOAD); pass it to `FramingCOBS.add_framing/2`
  to frame it for the wire.
  """
  @spec encode_body(0..255, 0..255, 0..0xFFFF, non_neg_integer(), atom(), value(), boolean()) ::
          binary()
  def encode_body(node, port_id, seq, t_dev, type, value, stamped? \\ false) do
    hdr = %{node: node, port: port_id, seq: seq, t_dev: t_dev}
    header = encode_fields(Contract.header(stamped?), hdr)
    payload = encode_fields(ValueType.resolve(type).layout(), value)
    header <> payload
  end

  @doc """
  Encode a bare unstamped header with no payload — used for the broadcast disarm
  (NODE 0x00), where the address carries the meaning (§05). Not decodable as a
  value frame (it has no port in the index); it is acted on by its NODE alone.
  """
  @spec encode_header_only(0..255, 0..255, 0..0xFFFF) :: binary()
  def encode_header_only(node, port_id, seq) do
    encode_fields(@base_header, %{node: node, port: port_id, seq: seq})
  end

  @doc """
  Decode a CRC-verified body into its header fields, value type, and value map.

  The body arriving here has already passed the CRC/COBS seam (`FramingCOBS`), so
  this only has to *parse* — it never has to defend against garbage. The base
  header (`node·port·seq`) is read first to find the `(node, port_id)`, then the
  per-port index says whether a `t_dev` follows (§04) and what the value type is,
  so an unstamped frame is never misread as a stamped one. `t_dev` is `nil` on an
  unstamped port. Returns `:error` for an unknown `(node, port_id)` or a payload
  of the wrong size (counted as `decode_fail` by the caller).
  """
  @spec decode_body(binary()) :: {:ok, decoded()} | :error
  def decode_body(body) when is_binary(body) do
    with {%{node: node, port: port_id, seq: seq}, rest} <-
           take_fields(@base_header, body),
         {:ok, %{type: type, stamped: stamped?}} <- PortIndex.lookup(node, port_id),
         {t_dev, after_hdr} <- take_t_dev(stamped?, rest),
         {value, <<>>} <- take_fields(ValueType.resolve(type).layout(), after_hdr) do
      {:ok, %{node: node, port_id: port_id, seq: seq, t_dev: t_dev, type: type, value: value}}
    else
      _ -> :error
    end
  end

  defp take_t_dev(false, rest), do: {nil, rest}

  defp take_t_dev(true, rest) do
    case take_fields([t_dev: :u64], rest) do
      {%{t_dev: t}, after_t} -> {t, after_t}
      :error -> :error
    end
  end

  # --- field-level codec, driven by the layout tables ---

  @doc false
  @spec encode_fields([{atom(), Layouts.wire_type()}], map()) :: binary()
  def encode_fields(layout, values) do
    for {field, wt} <- layout, into: <<>> do
      encode_one(wt, Map.fetch!(values, field))
    end
  end

  @doc false
  @spec take_fields([{atom(), Layouts.wire_type()}], binary()) :: {map(), binary()} | :error
  def take_fields(layout, bin) do
    Enum.reduce_while(layout, {%{}, bin}, fn {field, wt}, {acc, rest} ->
      case take_one(wt, rest) do
        {:ok, val, tail} -> {:cont, {Map.put(acc, field, val), tail}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp encode_one(:f32, v), do: <<v::float-32-big>>
  defp encode_one(:f64, v), do: <<v::float-64-big>>
  defp encode_one(:u8, v), do: <<v::unsigned-8-big>>
  defp encode_one(:u16, v), do: <<v::unsigned-16-big>>
  defp encode_one(:u32, v), do: <<v::unsigned-32-big>>
  defp encode_one(:u64, v), do: <<v::unsigned-64-big>>
  defp encode_one(:bool, v), do: <<bool_byte(v)::unsigned-8-big>>

  defp take_one(:f32, <<v::float-32-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:f64, <<v::float-64-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:u8, <<v::unsigned-8-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:u16, <<v::unsigned-16-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:u32, <<v::unsigned-32-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:u64, <<v::unsigned-64-big, rest::binary>>), do: {:ok, v, rest}
  defp take_one(:bool, <<v::unsigned-8-big, rest::binary>>), do: {:ok, v != 0, rest}
  defp take_one(_wt, _bin), do: :error

  defp bool_byte(true), do: 1
  defp bool_byte(false), do: 0
  defp bool_byte(0), do: 0
  defp bool_byte(n) when is_integer(n) and n != 0, do: 1
end
