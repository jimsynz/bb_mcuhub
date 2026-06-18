defmodule BBMcuhub.Gen.WireGen do
  @moduledoc """
  The one generator (§06): contracts + topology → one IR → committed artifacts,
  drift-tested so the C and Elixir sides physically cannot diverge.

  The design names four renderings of one model. In this implementation the
  **Elixir codec is data-driven** — `BBMcuhub.Wire.Codec` reads the same
  `BBMcuhub.Contract.Layouts` / `BBMcuhub.Contract` tables at runtime, so it
  *cannot* drift from the model within Elixir (there is no generated Elixir file
  to fall stale). That leaves three emitters whose output crosses a boundary the
  in-language guarantee can't reach, so they are emitted to disk and drift-tested:

    * `emit_c_header/1`   → `firmware/include/wire_contract.h` — port ids, packed
      structs, the floor window constants, and a contract hash.
    * `emit_schedule/2`   → `hubs/<hub>/mcu/schedule.gen.h` — per-port
      `{period_us, tick}` rows from each port's `rate` (§08).
    * `emit_parity/1`     → `test/fixtures/parity_vectors.exs` — `{port, value,
      body, crc}` rows computed by running the *real* encoder, the cross-language
      witness (§03). Numbers are correct by construction, never typed.

  `write_all!/0` regenerates everything (the `mix wire.gen` alias). The drift test
  asserts each file on disk equals what these emitters produce *now*.
  """

  alias BBMcuhub.Contract
  alias BBMcuhub.Contract.Layouts
  alias BBMcuhub.Robot.Info
  alias BBMcuhub.Wire.{Codec, CRC16}

  # The robot whose IR every artifact is generated from in v1's slice (§09).
  @default_robot BBMcuhub.Robots.Follower

  # Representative scalar per wire type — used to build deterministic parity
  # vectors. Chosen so each field is distinguishable in the bytes.
  @sample_seq 42
  @sample_t_dev 1234

  # --- top-level ---

  @doc "Regenerate every artifact for the active robot. Returns the paths written."
  @spec write_all!(module()) :: [Path.t()]
  def write_all!(robot \\ @default_robot) do
    ir = ir(robot)

    header = {"firmware/include/wire_contract.h", emit_c_header(ir)}
    parity = {"test/fixtures/parity_vectors.exs", emit_parity(ir)}
    parity_c = {"firmware/test/parity_vectors.h", emit_parity_c(ir)}

    schedules =
      for hub <- hubs(ir) do
        {"hubs/#{hub}/mcu/schedule.gen.h", emit_schedule(ir, hub)}
      end

    for {path, contents} <- [header, parity, parity_c | schedules] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      path
    end
  end

  @doc "The IR for a robot — the single model the emitters render."
  @spec ir(module()) :: [Contract.ir_row()]
  def ir(robot \\ @default_robot) do
    Info.ir(robot)
  end

  defp hubs(ir), do: ir |> Enum.map(& &1.hub) |> Enum.uniq() |> Enum.sort()

  # --- emit: C header ---

  @doc "Render `wire_contract.h` from the IR."
  @spec emit_c_header([Contract.ir_row()]) :: String.t()
  def emit_c_header(ir) do
    types = ir |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

    body =
      [
        header_banner("wire_contract.h", "ids · structs · floor window · hash"),
        ~s(#ifndef BB_MCUHUB_WIRE_CONTRACT_H\n#define BB_MCUHUB_WIRE_CONTRACT_H\n),
        "#include <stdint.h>\n#include <stdbool.h>\n",
        "/* The CRC-covered body header, before every payload (§03). t_dev is",
        "   per-port (§04): an unstamped port omits it. */",
        "#define WIRE_HEADER_BASE_SIZE #{Contract.header_size(false)}",
        "#define WIRE_HEADER_STAMPED_SIZE #{Contract.header_size(true)}",
        "#define WIRE_BROADCAST_NODE 0x#{hex2(Contract.broadcast_node())}",
        "",
        "/* Port ids — generated, stable, never hand-assigned (§06). */",
        Enum.map_join(ir, "\n", &port_define/1),
        "",
        "/* Which ports carry t_dev (1) vs omit it (0) — see §04. */",
        Enum.map_join(ir, "\n", &stamped_define/1),
        "",
        "/* Decode-time lookup: does the frame for (node, port) carry t_dev? The",
        "   inbound path peeks the base header for (node, port), then calls this to",
        "   learn the header shape — exactly as the host learns it from PortIndex. */",
        stamped_lookup_fn(ir),
        "",
        "/* Packed value structs — field order MATCHES Contract.Layouts (§06). */",
        Enum.map_join(types, "\n\n", &struct_def/1),
        "",
        "/* Per-actuator floor window, derived from one number (§05). */",
        Enum.map_join(actuators(ir), "\n", &floor_defines/1),
        "",
        "/* Contract hash — the drift test compares this. */",
        ~s(#define WIRE_CONTRACT_SHA "#{contract_sha(ir)}"),
        "",
        "#endif /* BB_MCUHUB_WIRE_CONTRACT_H */"
      ]

    finalize(body)
  end

  defp port_define(row) do
    "#define PORT_#{up(row.hub)}_#{up(row.port)} 0x#{hex2(row.port_id)}"
  end

  defp stamped_define(row) do
    "#define PORT_#{up(row.hub)}_#{up(row.port)}_STAMPED #{if row.stamped, do: 1, else: 0}"
  end

  defp stamped_lookup_fn(ir) do
    cases =
      ir
      |> Enum.filter(& &1.stamped)
      |> Enum.map_join("\n", fn row ->
        "    if (node == 0x#{hex2(row.node)} && port == 0x#{hex2(row.port_id)}) return true;"
      end)

    """
    static inline bool wire_port_stamped(uint8_t node, uint8_t port) {
    #{cases}
      return false;
    }\
    """
  end

  defp struct_def(type) do
    fields =
      Layouts.fetch!(type)
      |> Enum.map_join("\n", fn {field, wt} -> "  #{c_type(wt)} #{field};" end)

    "typedef struct __attribute__((packed)) {\n#{fields}\n} #{c_struct_name(type)};"
  end

  defp floor_defines(row) do
    period_ms = div(1000, row.rate)

    [
      "#define FLOOR_MISSES_#{up(row.hub)}_#{up(row.port)} #{row.fresh_for}",
      "#define CMD_PERIOD_MS_#{up(row.hub)}_#{up(row.port)} #{period_ms}"
    ]
    |> Enum.join("\n")
  end

  # --- emit: per-hub schedule ---

  @doc "Render a hub's `schedule.gen.h` — one `{period_us, tick}` row per port."
  @spec emit_schedule([Contract.ir_row()], atom()) :: String.t()
  def emit_schedule(ir, hub) do
    rows = ir |> Enum.filter(&(&1.hub == hub)) |> Enum.sort_by(& &1.port_id)

    table =
      rows
      |> Enum.map_join(",\n", fn row ->
        period_us = div(1_000_000, row.rate)
        "  { #{period_us}, 0, #{tick_name(row)} }  /* #{row.port} @ #{row.rate} Hz */"
      end)

    finalize([
      header_banner("schedule.gen.h", "per-port {period_us, last_us, tick} for #{hub} (§08)"),
      "/* Generated from #{hub}'s contract rates. The actuator floor runs every",
      "   loop (period 0) and is added by the firmware, not listed here. */",
      "",
      "static Task tasks[] = {",
      table,
      "};",
      "#define N_TASKS (sizeof(tasks) / sizeof(tasks[0]))"
    ])
  end

  # --- emit: parity vectors ---

  @doc """
  Render the parity-vector fixture by running the **real** encoder over a
  representative value per port. The bytes are correct by construction (§03/§06).
  """
  @spec emit_parity([Contract.ir_row()]) :: String.t()
  def emit_parity(ir) do
    rows =
      ir
      |> Enum.map_join(",\n", fn row ->
        value = sample_value(row.type)

        body =
          Codec.encode_body(
            row.node,
            row.port_id,
            @sample_seq,
            @sample_t_dev,
            row.type,
            value,
            row.stamped
          )

        crc = CRC16.crc(body)

        "  %{\n" <>
          "    hub: #{inspect(row.hub)}, port: #{inspect(row.port)}, type: #{inspect(row.type)},\n" <>
          "    node: 0x#{hex2(row.node)}, port_id: 0x#{hex2(row.port_id)},\n" <>
          "    seq: #{@sample_seq}, t_dev: #{@sample_t_dev}, stamped: #{row.stamped},\n" <>
          "    value: #{inspect(value, custom_options: [sort_maps: true])},\n" <>
          "    body: #{inspect(body, base: :hex, limit: :infinity)},\n" <>
          "    crc: 0x#{hex4(crc)}\n" <>
          "  }"
      end)

    finalize([
      "# GENERATED parity vectors (§03/§06) — the cross-language witness.",
      "# Each row: a value, its exact CRC-covered body bytes, and the CRC, computed",
      "# by running the real encoder. Asserted by the Elixir suite AND the",
      "# host-compiled C harness. Regenerate with `mix wire.gen`; a non-empty diff",
      "# means a contract moved and the bytes moved with it. Hand-editing a row is",
      "# the tell.",
      "[",
      rows,
      "]"
    ])
  end

  @doc """
  Render the parity vectors as a C header of byte arrays, so the host-compiled C
  harness can assert the **same** rows with no Elixir dependency (§03/§06). Each
  row is `{node, port, seq, t_dev, body bytes, crc}` — the C side rebuilds the
  body from the value via its own codec and must match these bytes exactly.
  """
  @spec emit_parity_c([Contract.ir_row()]) :: String.t()
  def emit_parity_c(ir) do
    rows =
      ir
      |> Enum.map(fn row ->
        value = sample_value(row.type)

        body =
          Codec.encode_body(
            row.node,
            row.port_id,
            @sample_seq,
            @sample_t_dev,
            row.type,
            value,
            row.stamped
          )

        crc = CRC16.crc(body)
        {row, value, body, crc}
      end)

    entries =
      rows
      |> Enum.with_index()
      |> Enum.map_join(",\n", fn {{row, value, body, crc}, idx} ->
        bytes = body |> :binary.bin_to_list() |> Enum.map_join(", ", &"0x#{hex2(&1)}")
        payload = build_payload_call(row, value)

        ~s(  { #{inspect(to_string(row.hub))}, #{inspect(to_string(row.port))},\n) <>
          ~s(    0x#{hex2(row.node)}, 0x#{hex2(row.port_id)}, #{@sample_seq}, #{@sample_t_dev}ULL, #{if row.stamped, do: "true", else: "false"},\n) <>
          ~s(    { #{bytes} }, #{byte_size(body)}, 0x#{hex4(crc)}, #{payload} } /* #{idx} */)
      end)

    finalize([
      header_banner("parity_vectors.h", "byte-exact rows for the C parity harness (§03)"),
      "#ifndef BB_MCUHUB_PARITY_VECTORS_H",
      "#define BB_MCUHUB_PARITY_VECTORS_H",
      "#include <stdint.h>",
      "#include <stdbool.h>",
      "#include \"frame.h\"",
      "",
      "/* The representative value per row, as a Frame payload built by the test's",
      "   per-type packers — see firmware/test/test_parity.c. */",
      "typedef void (*pack_fn)(Frame *f);",
      "",
      "typedef struct {",
      "  const char *hub;",
      "  const char *port;",
      "  uint8_t node;",
      "  uint8_t port_id;",
      "  uint16_t seq;",
      "  uint64_t t_dev;",
      "  bool stamped;     /* does this port carry t_dev? (§04) */",
      "  uint8_t body[#{max_body_len(rows)}];",
      "  size_t body_len;",
      "  uint16_t crc;",
      "  pack_fn pack;",
      "} ParityVector;",
      "",
      "static const ParityVector PARITY_VECTORS[] = {",
      entries,
      "};",
      "#define N_PARITY_VECTORS (sizeof(PARITY_VECTORS) / sizeof(PARITY_VECTORS[0]))",
      "",
      "#endif /* BB_MCUHUB_PARITY_VECTORS_H */"
    ])
  end

  # A reference to the test-side packer that builds this row's payload into a
  # Frame. The test defines one packer per (hub, port).
  defp build_payload_call(row, _value), do: "pack_#{row.hub}_#{row.port}"

  defp max_body_len(rows),
    do: rows |> Enum.map(fn {_r, _v, body, _c} -> byte_size(body) end) |> Enum.max()

  # --- shared helpers ---

  @doc "Deterministic SHA over the whole IR — the drift hash."
  @spec contract_sha([Contract.ir_row()]) :: String.t()
  def contract_sha(ir) do
    canonical = inspect(ir, custom_options: [sort_maps: true], limit: :infinity)
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc "A deterministic representative value map for a type's parity row."
  @spec sample_value(atom()) :: map()
  def sample_value(type) do
    Layouts.fetch!(type)
    |> Enum.with_index()
    |> Map.new(fn {{field, wt}, idx} -> {field, sample_scalar(wt, idx)} end)
  end

  # Distinguishable, exactly-representable values per field.
  defp sample_scalar(:f32, 0), do: 1.0
  defp sample_scalar(:f32, idx), do: idx * 0.5
  defp sample_scalar(:f64, idx), do: idx * 0.25
  defp sample_scalar(:u8, idx), do: rem(idx + 1, 256)
  defp sample_scalar(:u16, idx), do: rem((idx + 1) * 7, 0x10000)
  defp sample_scalar(:u32, idx), do: (idx + 1) * 13
  defp sample_scalar(:u64, idx), do: (idx + 1) * 17
  defp sample_scalar(:bool, idx), do: rem(idx, 2) == 0

  defp actuators(ir), do: Enum.filter(ir, &(&1.dir == :in and &1.safe_action != nil))

  defp tick_name(%{dir: :out, hub: _hub, port: port}), do: "#{port}_sample_tick"
  defp tick_name(%{dir: :in, port: port}), do: "#{port}_cmd_tick"

  defp c_type(:f32), do: "float"
  defp c_type(:f64), do: "double"
  defp c_type(:u8), do: "uint8_t"
  defp c_type(:u16), do: "uint16_t"
  defp c_type(:u32), do: "uint32_t"
  defp c_type(:u64), do: "uint64_t"
  defp c_type(:bool), do: "bool"

  defp c_struct_name(type), do: type |> Atom.to_string() |> Macro.camelize()

  defp header_banner(file, what) do
    "/* GENERATED by BBMcuhub.Gen.WireGen — do not edit. #{file}\n   #{what} */"
  end

  defp finalize(lines), do: (lines |> List.flatten() |> Enum.join("\n")) <> "\n"

  defp up(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp hex2(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
  defp hex4(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
end
