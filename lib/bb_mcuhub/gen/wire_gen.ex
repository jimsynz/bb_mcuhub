defmodule BBMcuhub.Gen.WireGen do
  @moduledoc """
  The one generator (§06): contracts + topology → one IR → committed artifacts,
  drift-tested so the C and Elixir sides physically cannot diverge.

  The design names four renderings of one model. In this implementation the
  **Elixir codec is data-driven** — `BBMcuhub.Wire.Codec` reads each port's
  value-type layout (`BBMcuhub.ValueType`) and the `BBMcuhub.Contract` header at
  runtime, so it *cannot* drift from the model within Elixir (there is no generated
  Elixir file to fall stale). That leaves the emitters whose output crosses a
  boundary the in-language guarantee can't reach, so they are emitted to disk and
  drift-tested:

    * `emit_c_header/1`     → `firmware/gen/<slug>/wire_contract.h` — port ids,
      packed structs, the floor window constants, and a contract hash.
    * `emit_glue/2`         → `firmware/gen/<slug>/<hub>.glue.h` — the GENERATED
      mechanical per-hub firmware glue (§08, ADR-0003): the router table,
      `hub_on_body`, command dispatch, the floor init/`on_command`/`control_tick`/
      status plumbing, the sense ticks, and the `hub_tasks` schedule. This replaces
      the hand-written `main_<hub>.cpp` + the old `schedule.gen.h`.
    * `emit_device_header/2`→ `firmware/gen/<slug>/<hub>.device.h` — the prototypes
      for the hand-written device hooks the glue calls (the contract the
      `mcu/<hub>.{c,cpp}` file owes), signatures owned by each port's value-type.
    * `emit_parity/1`       → `test/fixtures/<slug>/parity_vectors.exs` — `{port,
      value, body, crc}` rows computed by running the *real* encoder, the
      cross-language witness (§03). Numbers are correct by construction.

  Artifacts are **robot-scoped** (§09): each robot owns a `firmware/gen/<slug>/`
  dir (now holding wire_contract.h + the per-hub glue/device headers) and a
  `test/fixtures/<slug>/` dir, so robots can coexist without one clobbering the
  other's artifacts. `<slug>` is the robot module's last segment, underscored
  (`Robot` → `robot`, `SegbyV1` → `segby_v1`). Each hub appears in exactly one
  robot, so `<hub>.glue.h` never collides across robots.

  `write_all!/0` regenerates everything for every committed LIBRARY robot — now
  just the library's own test fixture (the `mix wire.gen` alias). A consumer app
  (e.g. `examples/segby_v1`) generates ITS robot itself via `write_all!/2` with
  its own output base (ADR-0003 / Phase 5). The drift test asserts each file on
  disk equals what these emitters produce *now*, per robot.
  """

  alias BBMcuhub.Contract
  alias BBMcuhub.Robot.Info
  alias BBMcuhub.ValueType
  alias BBMcuhub.Wire.{Codec, CRC16}

  # Representative scalar per wire type — used to build deterministic parity
  # vectors. Chosen so each field is distinguishable in the bytes.
  @sample_seq 42
  @sample_t_dev 1234

  # The default output base — cwd-relative `firmware/gen` for the C headers and
  # `test/fixtures` for the parity-vector fixture (ADR-0003: WireGen takes an
  # explicit output-base so each app generates into its own tree; the library
  # uses this default, Phase 5's example passes its own base). A consumer can
  # override either via `write_all!/2`.
  @default_base %{gen: ["firmware", "gen"], fixtures: ["test", "fixtures"]}

  # --- top-level ---

  # The robots whose artifacts the LIBRARY commits and drift-tests (ADR-0003):
  # its own test fixture (the drift/C-parity witness). segby_v1 moved to the
  # example app (Phase 5), which generates its own artifacts. There is NO
  # default-robot — the library always generates for an explicit set. `mix
  # wire.gen` (no arg) regenerates ALL of them.
  @robots [BBMcuhub.Test.Fixtures.Robot]

  @doc "The library's committed robots (just the test fixture)."
  @spec robots() :: [module()]
  def robots, do: @robots

  @doc "Regenerate every artifact for every committed library robot. Returns the paths written."
  @spec write_all!() :: [Path.t()]
  def write_all!, do: Enum.flat_map(@robots, &write_all!(&1, @default_base))

  @doc """
  Regenerate every artifact for one explicit robot into the default output base.
  The robot is ALWAYS explicit (no library default, ADR-0003).
  """
  @spec write_all!(module()) :: [Path.t()]
  def write_all!(robot), do: write_all!(robot, @default_base)

  @doc """
  Regenerate every artifact for one robot into an explicit output `base`.

  `base` is `%{gen: [path, segments], fixtures: [path, segments]}` — the C headers
  go under `base.gen/<slug>/` and the parity fixture under
  `base.fixtures/<slug>/parity_vectors.exs`. Defaults to the library's own tree;
  a consumer app passes its own base so each app generates into its own tree.

  The `<slug>` defaults to `slug(robot)` (the robot module's last segment,
  underscored). A consumer whose robot module's last segment is generic (e.g.
  `SegbyV1.Robot` → `robot`) can PIN a meaningful slug by putting `:slug` in the
  `base` map (e.g. `%{... , slug: "segby_v1"}`) — the example does this so its
  artifacts land in `firmware/gen/segby_v1/`. Returns the paths written.
  """
  @spec write_all!(module(), map()) :: [Path.t()]
  def write_all!(robot, base) do
    ir = ir(robot)
    slug = Map.get(base, :slug) || slug(robot)

    header = {gen_dir(base, slug, "wire_contract.h"), emit_c_header(ir)}
    parity = {fixtures_path(base, slug), emit_parity(ir)}
    parity_c = {gen_dir(base, slug, "parity_vectors.h"), emit_parity_c(ir)}

    # The per-hub glue + device-prototype headers go in the SAME robot-scoped gen
    # dir as wire_contract.h (§08, ADR-0003). The glue is fully generated and
    # drift-tested; the device header is the contract the hand-written mcu/<hub>.c
    # owes. Each hub lives in exactly one robot, so the per-robot dir never
    # collides across robots.
    glue =
      for hub <- hubs(ir) do
        [
          {gen_dir(base, slug, "#{hub}.glue.h"), emit_glue(ir, hub)},
          {gen_dir(base, slug, "#{hub}.device.h"), emit_device_header(ir, hub)}
        ]
      end
      |> List.flatten()

    for {path, contents} <- [header, parity, parity_c | glue] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      path
    end
  end

  @doc """
  The robot's short slug — its module's last segment, underscored. Drives the
  per-robot artifact dirs (`Follower` → `follower`, `SegbyV1` → `segby_v1`).
  """
  @spec slug(module()) :: String.t()
  def slug(robot) do
    robot
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc "The default output base (the library's own tree)."
  @spec default_base() :: map()
  def default_base, do: @default_base

  @doc "The robot-scoped generated-C dir under the DEFAULT base, joined with `file` (§09)."
  @spec gen_dir(String.t(), String.t()) :: Path.t()
  def gen_dir(slug, file), do: gen_dir(@default_base, slug, file)

  @doc "The robot-scoped generated-C dir under `base`, joined with `file` (§09)."
  @spec gen_dir(map(), String.t(), String.t()) :: Path.t()
  def gen_dir(base, slug, file), do: Path.join(base.gen ++ [slug, file])

  @doc "The robot-scoped parity-vector fixture path under the DEFAULT base (§09)."
  @spec fixtures_path(String.t()) :: Path.t()
  def fixtures_path(slug), do: fixtures_path(@default_base, slug)

  @doc "The robot-scoped parity-vector fixture path under `base` (§09)."
  @spec fixtures_path(map(), String.t()) :: Path.t()
  def fixtures_path(base, slug), do: Path.join(base.fixtures ++ [slug, "parity_vectors.exs"])

  @doc "The IR for an explicit robot — the single model the emitters render (no default, ADR-0003)."
  @spec ir(module()) :: [Contract.ir_row()]
  def ir(robot) do
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
        "/* The root hub's children-facing backplane transport (a contract fact, not",
        "   a build flag — see docs/adr/0002). 1 = a plain UART carrying the same",
        "   COBS+CRC frames (no CAN segmentation: a wide body rides one frame); 0 =",
        "   the default CAN/TWAI backplane. For v1 the backplane is uniform per robot:",
        "   UART iff any non-root hub is reached over :uart. */",
        "#define BACKPLANE_TRANSPORT_UART #{backplane_transport_uart(ir)}",
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
      ValueType.resolve(type).layout()
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

  # --- emit: per-hub generated glue (§08, ADR-0003) ---
  #
  # The hand-written `main_<hub>.cpp` was mechanical: a router table, hub_on_body,
  # command dispatch, the floor init/on_command/control_tick/status plumbing, the
  # sense ticks, and the hub_tasks schedule assembly. ALL of it is derivable from
  # the IR, so it is generated here into `<hub>.glue.h`. The user is left only the
  # device hooks (`<hub>_device_setup`, per-port read/drive) declared in
  # `<hub>.device.h` and implemented in a hand-authored `mcu/<hub>.{c,cpp}`.
  #
  # Derivations, all from the IR (documented for the safety review):
  #
  #   * ROOT hub  — the lowest-NODE hub in the robot (`Enum.min` on node), matching
  #     `backplane_transport_uart/1`'s root rule. A root's route table defaults to
  #     LINK_UP (toward host), MY_NODE → LINK_LOCAL, and every OTHER hub's node →
  #     LINK_DOWN. Its hub_on_body forwards up via `link_send_up` (host) and down
  #     via `link_send_down` (backplane → child). A LEAF defaults route_table[*] =
  #     LINK_LOCAL and passes nullptr,nullptr (local-only) — matching motor/wheels.
  #
  #   * FLOORED command port — `dir: :in` AND `safe_action != nil`. Gets a Floor,
  #     an `on_command_<port>` that decodes the effort and feeds the floor's seq,
  #     and a per-loop `<hub>_<port>_drive(floor_tick(...))` in control_tick. The
  #     floor window = FLOOR_MISSES_* * CMD_PERIOD_MS_* (from wire_contract.h); the
  #     safe_action atom maps to a numeric via `safe_action_value/1` (default 0.0f).
  #
  #   * NON-FLOORED command port — `dir: :in` AND `safe_action == nil` (segby's
  #     `status_led`). No floor: `on_command_<port>` decodes the value and calls the
  #     device drive hook directly, reproducing the hand-written LED path exactly.
  #
  #   * STATUS port — `dir: :out`, `type: :status`. Reports {applied_seq, floored?}
  #     of its PAIRED floored command port (see `status_pair/2`).
  #
  #   * SENSE port — `dir: :out`, not :status. A scheduled read → pack → send-up.
  #
  #   * DRIVE/READ hook signatures are owned by the value-type (§ Firmware hook): a
  #     single numeric field → scalar `(float)` (effort) or `bool read(<Struct>*)`;
  #     a multi-field value → struct-pointer (`const <Struct>*` to drive, `<Struct>*`
  #     to read). See `drive_sig/2` / `read_call/2`.
  #
  #   * OPTIONAL post-control hook — the glue ALWAYS calls `<hub>_post_control()` at
  #     the end of control_tick AND emits a `__attribute__((weak))` empty default,
  #     so a device that needs it (wheels' current sense) overrides it and one that
  #     doesn't links fine with the no-op. Portable C, no #ifdef per hub.

  @doc """
  Render a hub's `<hub>.glue.h` — all mechanical per-hub firmware wiring (§08).

  This replaces the hand-written `main_<hub>.cpp`. It defines the C-linkage
  `hub_setup`/`hub_on_body`/`hub_tasks` the generic `hub_main.cpp` expects, plus
  the router table, command dispatch, floor plumbing, status + sense ticks, and
  the schedule. ARDUINO-guarded so the host C harnesses (which never compile it)
  still build.
  """
  @spec emit_glue([Contract.ir_row()], atom()) :: String.t()
  def emit_glue(ir, hub) do
    rows = ir |> Enum.filter(&(&1.hub == hub)) |> Enum.sort_by(& &1.port_id)
    root? = root_hub?(ir, hub)
    my_node = rows |> hd() |> Map.fetch!(:node)

    floored = Enum.filter(rows, &floored_command?/1)
    nonfloored = Enum.filter(rows, &nonfloored_command?/1)
    statuses = Enum.filter(rows, &status_port?/1)
    senses = Enum.filter(rows, &sense_port?/1)
    actuator? = floored != []

    finalize([
      header_banner("#{hub}.glue.h", "generated per-hub glue (router, floor, ticks) — §08"),
      glue_intro(hub, root?),
      "#if defined(ARDUINO)",
      "",
      ~s(#include <Arduino.h>),
      "extern \"C\" {",
      "#include \"frame.h\"",
      "#include \"scheduler.h\"",
      "#include \"router.h\"",
      "#include \"link.h\"",
      if(actuator?, do: "#include \"floor.h\"", else: nil),
      "#include \"wire_contract.h\"",
      ~s(#include "#{hub}.device.h" /* the hand-written device hooks */),
      "}",
      "",
      "#ifndef MY_NODE",
      "#define MY_NODE 0x#{hex2(my_node)}",
      "#endif",
      "",
      glue_post_control_default(hub),
      glue_floor_state(floored),
      glue_sense_state(senses),
      glue_status_state(statuses),
      glue_on_commands(hub, floored, nonfloored),
      glue_control_tick(hub, floored, actuator?),
      glue_cmd_ticks(rows),
      glue_status_ticks(hub, statuses, floored),
      glue_sense_ticks(hub, senses),
      glue_router(hub, rows, root?),
      glue_setup(hub, floored, root?, ir),
      glue_tasks(hub, rows, actuator?),
      "#endif /* ARDUINO */"
    ])
  end

  @doc """
  Render a hub's `<hub>.device.h` — the prototypes for the hand-written device
  hooks (the contract the `mcu/<hub>.{c,cpp}` file owes). Legible, link-time
  resolved (Shape 1, ADR-0003). Signatures are owned by each port's value-type.
  """
  @spec emit_device_header([Contract.ir_row()], atom()) :: String.t()
  def emit_device_header(ir, hub) do
    rows = ir |> Enum.filter(&(&1.hub == hub)) |> Enum.sort_by(& &1.port_id)
    cmds = Enum.filter(rows, &(&1.dir == :in))
    senses = Enum.filter(rows, &sense_port?/1)
    guard = "BB_MCUHUB_#{up(hub)}_DEVICE_H"

    setup_proto =
      "void #{hub}_device_setup(void); /* one-time bring-up (pins, peripherals,\n" <>
        "                                    FOC/encoder init). May take as long as it\n" <>
        "                                    needs: the task watchdog is armed AFTER this\n" <>
        "                                    returns, so a slow initFOC/i2c settle is safe. */"

    read_protos =
      Enum.map(senses, fn row ->
        "bool #{hub}_#{row.port}_read(#{c_struct_name(row.type)} *out); /* bounded read; false on timeout */"
      end)

    drive_protos =
      Enum.map(cmds, fn row ->
        "void #{hub}_#{row.port}_drive(#{drive_param(row)}); /* apply to the plant */"
      end)

    post_control =
      "void #{hub}_post_control(void); /* OPTIONAL: per-loop telemetry. To provide one, `#define #{up(hub)}_POST_CONTROL_OVERRIDE` before #include'ing #{hub}.glue.h; else a no-op default is used. */"

    finalize([
      header_banner(
        "#{hub}.device.h",
        "device-hook prototypes — the hand-written contract (§ Firmware hook)"
      ),
      "#ifndef #{guard}",
      "#define #{guard}",
      "#include <stdint.h>",
      "#include <stdbool.h>",
      "#include \"wire_contract.h\" /* the packed value structs the hooks fill/take */",
      "",
      "#ifdef __cplusplus",
      "extern \"C\" {",
      "#endif",
      "",
      "/* Implemented by the hand-authored mcu/#{hub}.{c,cpp}; the generated glue calls these. */",
      [setup_proto] |> Enum.join("\n"),
      if(read_protos == [], do: nil, else: Enum.join(read_protos, "\n")),
      if(drive_protos == [], do: nil, else: Enum.join(drive_protos, "\n")),
      post_control,
      "",
      "#ifdef __cplusplus",
      "}",
      "#endif",
      "",
      "#endif /* #{guard} */"
    ])
  end

  # --- glue: section renderers ---

  defp glue_intro(hub, root?) do
    role =
      if root?,
        do: "ROOT hub (host UART ↔ backplane + local ports)",
        else: "LEAF hub (local ports only)"

    [
      "/* GENERATED firmware glue for the #{hub} hub — #{role}.",
      "   Mechanical wiring derived from the IR (§08): router table, hub_on_body,",
      "   command dispatch, the floor init/on_command/control_tick/status plumbing,",
      "   the sense ticks, and the hub_tasks schedule. The user writes ONLY the",
      "   device hooks in mcu/#{hub}.{c,cpp} (prototypes in #{hub}.device.h).",
      "   This header is #include'd by the device file, which the build compiles. */"
    ]
    |> Enum.join("\n")
  end

  # The optional per-loop hook. The glue ALWAYS calls `<hub>_post_control()` at the
  # end of control_tick; here it emits a no-op DEFAULT body UNLESS the device file
  # signalled it provides its own by `#define <HUB>_POST_CONTROL_OVERRIDE` before
  # including the glue. A weak attribute can't be used because the glue is included
  # INTO the device TU (a weak default + a strong override in one TU is a
  # redefinition error), so this compile-time switch is the portable form: a hub
  # that needs it (wheels' current sense) defines the macro and supplies the real
  # body; one that doesn't gets the no-op for free.
  defp glue_post_control_default(hub) do
    """
    /* Optional per-loop telemetry hook (§08). The glue calls #{hub}_post_control() at
       the end of every control_tick. The device file can provide its own by doing
       `#define #{up(hub)}_POST_CONTROL_OVERRIDE` BEFORE including this header (then
       implementing #{hub}_post_control() itself); otherwise this no-op default is used. */
    #ifndef #{up(hub)}_POST_CONTROL_OVERRIDE
    extern "C" void #{hub}_post_control(void) {}
    #endif
    """
  end

  defp glue_floor_state([]), do: nil

  defp glue_floor_state(floored) do
    decls =
      Enum.flat_map(floored, fn row ->
        win =
          "(FLOOR_MISSES_#{up(row.hub)}_#{up(row.port)} * CMD_PERIOD_MS_#{up(row.hub)}_#{up(row.port)})"

        [
          "static Floor g_floor_#{row.port};",
          "static uint16_t g_applied_seq_#{row.port} = 0;  /* last command seq we handed the floor */",
          "#define FLOOR_WINDOW_MS_#{up(row.port)} #{win}"
        ]
      end)

    "/* One floor per floored command port (§05) — born-disarmed, safe at boot. */\n" <>
      Enum.join(decls, "\n")
  end

  defp glue_sense_state([]), do: nil

  defp glue_sense_state(senses) do
    "/* Per-sensor seq — advanced only on a real new value (§04). */\n" <>
      Enum.map_join(senses, "\n", &"static uint16_t g_seq_#{&1.port} = 0;")
  end

  defp glue_status_state([]), do: nil

  defp glue_status_state(statuses) do
    "/* Per-status-port seq. */\n" <>
      Enum.map_join(statuses, "\n", &"static uint16_t g_status_seq_#{&1.port} = 0;")
  end

  defp glue_on_commands(_hub, [], []), do: nil

  defp glue_on_commands(hub, floored, nonfloored) do
    floored_fns =
      Enum.map(floored, fn row ->
        """
        /* A command for #{row.port}: decode the value, hand its seq to the floor
           (the floor watches the seq, not the value), record applied_seq (§05). */
        static void on_command_#{row.port}(const Frame *f) {
          if (f->port != PORT_#{up(hub)}_#{up(row.port)}) return;
          if (f->payload_len < 4) return;
          float v = be_get_f32(&f->payload[0]);
          floor_on_command(&g_floor_#{row.port}, f->seq, v);
          g_applied_seq_#{row.port} = f->seq;
        }\
        """
      end)

    nonfloored_fns =
      Enum.map(nonfloored, fn row ->
        glue_nonfloored_on_command(hub, row)
      end)

    Enum.join(floored_fns ++ nonfloored_fns, "\n\n")
  end

  # A non-floored command port (e.g. segby's decorative LED): no safe-state, just
  # decode the value and drive directly. Reproduces the hand-written LED path.
  defp glue_nonfloored_on_command(hub, row) do
    layout = ValueType.resolve(row.type).layout()
    min_len = payload_min_len(layout)

    {decode, drive_arg} =
      case layout do
        [{_field, _wt}] ->
          # single field → pass the scalar (only effort uses this path today;
          # a single-:u8 would also land here but no such command port exists)
          {"  #{c_type(elem(hd(layout), 1))} v = #{scalar_get(elem(hd(layout), 1), 0)};", "v"}

        _ ->
          # multi-field → build the packed struct, pass a pointer (LED's r,g,b)
          fields =
            layout
            |> Enum.with_index()
            |> Enum.map_join("\n", fn {{field, wt}, idx} ->
              "  v.#{field} = #{scalar_get(wt, field_offset(layout, idx))};"
            end)

          {"  #{c_struct_name(row.type)} v;\n" <> fields, "&v"}
      end

    """
    /* A command for #{row.port}: NOT floored (safe_action == nil), so decode the
       value and drive the device directly — a stale command is harmless (§09). */
    static void on_command_#{row.port}(const Frame *f) {
      if (f->port != PORT_#{up(hub)}_#{up(row.port)}) return;
      if (f->payload_len < #{min_len}) return;
    #{decode}
      #{hub}_#{row.port}_drive(#{drive_arg});
    }\
    """
  end

  defp glue_control_tick(_hub, [], false), do: nil

  defp glue_control_tick(hub, floored, true) do
    drives =
      Enum.map_join(floored, "\n", fn row ->
        "  #{hub}_#{row.port}_drive(floor_tick(&g_floor_#{row.port}, now_ms));"
      end)

    """
    /* The drive loop — period 0 so it runs every loop pass, never starved (§08).
       Each floor gates its own port: target while armed, safe action otherwise
       (default safe). Then the optional per-loop device hook (telemetry). */
    static void control_tick(uint32_t now_us) {
      uint32_t now_ms = now_us / 1000u;
    #{drives}
      #{hub}_post_control();
    }\
    """
  end

  defp glue_control_tick(_hub, _floored, _actuator?), do: nil

  # Command ports are event-driven via on_command; their scheduled cmd tick (the
  # schedule lists every port) is a no-op, matching the hand-written hubs.
  defp glue_cmd_ticks(rows) do
    cmds = Enum.filter(rows, &(&1.dir == :in))
    if cmds == [], do: nil, else: cmd_ticks_body(cmds)
  end

  defp cmd_ticks_body(cmds) do
    "/* IN ports are event-driven via on_command; the scheduled cmd tick is a no-op. */\n" <>
      Enum.map_join(
        cmds,
        "\n",
        &"static void #{&1.port}_cmd_tick(uint32_t now_us) { (void)now_us; }"
      )
  end

  defp glue_status_ticks(_hub, [], _floored), do: nil

  defp glue_status_ticks(hub, statuses, floored) do
    Enum.map_join(statuses, "\n\n", fn st ->
      pair = status_pair(st, floored)

      """
      /* Report #{st.port}'s reported truth (§05): the paired floor's applied_seq +
         floored? flag, so the host reads truth instead of inferring it. */
      static void #{st.port}_sample_tick(uint32_t now_us) {
        (void)now_us; /* status omits t_dev, so the tick needs no clock */
        Frame f;
        f.node = MY_NODE;
        f.port = PORT_#{up(hub)}_#{up(st.port)};
        f.seq = ++g_status_seq_#{st.port};
        f.stamped = PORT_#{up(hub)}_#{up(st.port)}_STAMPED;
        f.t_dev = 0;

        be_put_u16(&f.payload[0], g_applied_seq_#{pair.port});
        f.payload[2] = g_floor_#{pair.port}.armed ? 0 : 1; /* floored? = not armed */
        f.payload_len = 3;

        link_send_up(&f);
      }\
      """
    end)
  end

  defp glue_sense_ticks(_hub, []), do: nil

  defp glue_sense_ticks(hub, senses) do
    Enum.map_join(senses, "\n\n", fn row ->
      layout = ValueType.resolve(row.type).layout()
      struct = c_struct_name(row.type)

      pack =
        layout
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {{field, wt}, idx} ->
          "  #{scalar_put(wt, field_offset(layout, idx), "raw.#{field}")}"
        end)

      payload_len = payload_min_len(layout)

      tdev =
        if row.stamped do
          "  f.t_dev = now_us;                 /* this hub's own µs, same-device use only */"
        else
          "  f.t_dev = 0;\n  (void)now_us;"
        end

      """
      /* Sense #{row.port} (§08): one bounded read, pack big-endian, send up. A read
         that fails returns → no write → the seq stalls → the reader goes stale. */
      static void #{row.port}_sample_tick(uint32_t now_us) {
        #{struct} raw;
        if (!#{hub}_#{row.port}_read(&raw)) return;

        Frame f;
        f.node = MY_NODE;
        f.port = PORT_#{up(hub)}_#{up(row.port)};
        f.seq = ++g_seq_#{row.port};        /* advance only on a real new value */
        f.stamped = PORT_#{up(hub)}_#{up(row.port)}_STAMPED;
      #{tdev}

      #{pack}
        f.payload_len = #{payload_len};

        link_send_up(&f);
      }\
      """
    end)
  end

  defp glue_router(hub, rows, root?) do
    cmds = Enum.filter(rows, &(&1.dir == :in))

    deliver =
      if cmds == [] do
        """
        static void deliver_local(const Frame *f, void *) {
          (void)f; /* sense-only hub: no local command ports */
        }\
        """
      else
        dispatch =
          cmds
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {row, idx} ->
            kw = if idx == 0, do: "if", else: "else if"
            "  #{kw} (f->port == PORT_#{up(hub)}_#{up(row.port)}) on_command_#{row.port}(f);"
          end)

        """
        static void deliver_local(const Frame *f, void *) {
        #{dispatch}
        }\
        """
      end

    {fwd_decls, sinks} =
      if root? do
        {
          """
          static void fwd_up(const Frame *f, void *) { link_send_up(f); }
          static void fwd_down(const Frame *f, void *) { link_send_down(f); /* re-frames onto the backplane to a child */ }
          """,
          "RouterSinks sinks = {deliver_local, fwd_up, fwd_down, nullptr};"
        }
      else
        {nil,
         "RouterSinks sinks = {deliver_local, nullptr, nullptr, nullptr}; /* leaf: local only */"}
      end

    [
      "static Router g_router;",
      "",
      deliver,
      fwd_decls,
      """

      /* Meaning-blind inbound (§04): decode the body (CRC-clean at the seam), learn
         t_dev-ness per port just-in-time, route by NODE. seq/t_dev never touched. */
      extern "C" void hub_on_body(const uint8_t *body, size_t len) {
        if (len < FRAME_HEADER_BASE_SIZE) return;
        Frame f;
        bool stamped = wire_port_stamped(body[0], body[1]); /* per-port t_dev (§04) */
        if (!frame_decode_body(body, len, stamped, &f)) return;
        #{sinks}
        router_route(&g_router, &f, &sinks);
      }\
      """
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp glue_setup(hub, floored, root?, ir) do
    floor_inits =
      Enum.map_join(floored, "\n", fn row ->
        "  floor_init(&g_floor_#{row.port}, FLOOR_WINDOW_MS_#{up(row.port)}, #{safe_action_value(row.safe_action)}f); /* #{inspect(row.safe_action)} */"
      end)

    route_fill =
      if root? do
        my_node = ir |> Enum.find(&(&1.hub == hub)) |> Map.fetch!(:node)

        child_nodes =
          ir |> Enum.map(& &1.node) |> Enum.uniq() |> Enum.reject(&(&1 == my_node)) |> Enum.sort()

        downs =
          Enum.map_join(child_nodes, "\n", fn n ->
            "  g_router.route_table[0x#{hex2(n)}] = LINK_DOWN; /* a child hub, reached over the backplane */"
          end)

        """
          g_router.my_node = MY_NODE;
          for (int i = 0; i < 256; i++) g_router.route_table[i] = LINK_UP; /* default: toward host */
          g_router.route_table[MY_NODE] = LINK_LOCAL;
        #{downs}\
        """
      else
        """
          g_router.my_node = MY_NODE;
          for (int i = 0; i < 256; i++) g_router.route_table[i] = LINK_LOCAL; /* leaf: every port is local */\
        """
      end

    floor_block =
      if floored == [] do
        nil
      else
        "  /* born-disarmed floors first (§05), so the safe output is selected before any drive */\n" <>
          floor_inits <> "\n"
      end

    [
      """
      extern "C" void hub_setup(void) {
      """
      |> String.trim_trailing(),
      floor_block,
      route_fill,
      "",
      "  #{hub}_device_setup(); /* the hand-written hardware bring-up */",
      "}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp glue_tasks(hub, rows, actuator?) do
    sorted = Enum.sort_by(rows, & &1.port_id)

    table =
      sorted
      |> Enum.map_join(",\n", fn row ->
        period_us = div(1_000_000, row.rate)
        "  { #{period_us}, 0, #{tick_name(row)} }  /* #{row.port} @ #{row.rate} Hz */"
      end)

    if actuator? do
      """
      /* The schedule (§08): one {period_us, tick} row per port from its rate. The
         drive loop runs EVERY loop (period 0) and is prepended here, never starved. */
      static Task #{hub}_tasks[] = {
        { 0, 0, control_tick },  /* period 0 → every loop pass */
      #{table}
      };
      #define #{up(hub)}_N_TASKS (sizeof(#{hub}_tasks) / sizeof(#{hub}_tasks[0]))

      extern "C" Task *hub_tasks(size_t *n_tasks) {
        *n_tasks = #{up(hub)}_N_TASKS;
        return #{hub}_tasks;
      }\
      """
    else
      """
      /* The schedule (§08): one {period_us, tick} row per port from its rate. A
         sense-only hub has no control_tick. */
      static Task #{hub}_tasks[] = {
      #{table}
      };
      #define #{up(hub)}_N_TASKS (sizeof(#{hub}_tasks) / sizeof(#{hub}_tasks[0]))

      extern "C" Task *hub_tasks(size_t *n_tasks) {
        *n_tasks = #{up(hub)}_N_TASKS;
        return #{hub}_tasks;
      }\
      """
    end
  end

  # --- glue: classification + derivation helpers (all from the IR) ---

  # The ROOT hub is the lowest-NODE hub (matches backplane_transport_uart/1).
  defp root_hub?(ir, hub) do
    root_node = ir |> Enum.map(& &1.node) |> Enum.min()
    hub_node = ir |> Enum.find(&(&1.hub == hub)) |> Map.fetch!(:node)
    hub_node == root_node
  end

  defp floored_command?(row), do: row.dir == :in and row.safe_action != nil
  defp nonfloored_command?(row), do: row.dir == :in and row.safe_action == nil
  defp status_port?(row), do: row.dir == :out and row.type == :status
  defp sense_port?(row), do: row.dir == :out and row.type != :status

  # Map a status OUT-port to the floored command port whose truth it reports.
  #
  #   * one floored command port → every status reports that one floor (motor).
  #   * many → pair by a shared name suffix (status_LEFT ↔ motor_LEFT,
  #     status_RIGHT ↔ motor_RIGHT on wheels). The in-tree hubs (motor, wheels)
  #     are the only actuators this phase; the rule reproduces their exact pairing.
  defp status_pair(_status, [only]), do: only

  defp status_pair(status, floored) do
    suffix = name_suffix(status.port)

    Enum.find(floored, fn cmd -> name_suffix(cmd.port) == suffix end) ||
      raise "no floored command pairs status port #{status.port} (suffix #{suffix})"
  end

  defp name_suffix(port), do: port |> Atom.to_string() |> String.split("_") |> List.last()

  # The safe_action atom → its numeric drive value. Default 0.0f (safe = off).
  # Today only :zero_torque exists; documented mapping so a new safe action is
  # one line here.
  defp safe_action_value(:zero_torque), do: "0.0"
  defp safe_action_value(nil), do: "0.0"
  defp safe_action_value(_other), do: "0.0"

  # The drive-hook *parameter* declaration, from the value-type layout (§ Firmware
  # hook): a single numeric field → the scalar by value; a multi-field value → a
  # const pointer to the packed struct.
  defp drive_param(row) do
    case ValueType.resolve(row.type).layout() do
      [{_f, wt}] -> c_type(wt)
      _ -> "const #{c_struct_name(row.type)} *v"
    end
  end

  # Big-endian field GET at `off` for wire type `wt` (decode in on_command).
  defp scalar_get(:f32, off), do: "be_get_f32(&f->payload[#{off}])"
  defp scalar_get(:f64, off), do: "be_get_f64(&f->payload[#{off}])"
  defp scalar_get(:u8, off), do: "f->payload[#{off}]"
  defp scalar_get(:u16, off), do: "be_get_u16(&f->payload[#{off}])"
  defp scalar_get(:u32, off), do: "be_get_u32(&f->payload[#{off}])"
  defp scalar_get(:u64, off), do: "be_get_u64(&f->payload[#{off}])"
  defp scalar_get(:bool, off), do: "(f->payload[#{off}] != 0)"

  # Big-endian field PUT at `off` for wire type `wt` (pack in a sense/status tick).
  defp scalar_put(:f32, off, src), do: "be_put_f32(&f.payload[#{off}], #{src});"
  defp scalar_put(:f64, off, src), do: "be_put_f64(&f.payload[#{off}], #{src});"
  defp scalar_put(:u8, off, src), do: "f.payload[#{off}] = #{src};"
  defp scalar_put(:u16, off, src), do: "be_put_u16(&f.payload[#{off}], #{src});"
  defp scalar_put(:u32, off, src), do: "be_put_u32(&f.payload[#{off}], #{src});"
  defp scalar_put(:u64, off, src), do: "be_put_u64(&f.payload[#{off}], #{src});"
  defp scalar_put(:bool, off, src), do: "f.payload[#{off}] = (#{src}) ? 1 : 0;"

  # Byte offset of the field at `idx` in a layout (sum of preceding widths).
  defp field_offset(layout, idx) do
    layout
    |> Enum.take(idx)
    |> Enum.reduce(0, fn {_f, wt}, acc -> acc + Contract.Layouts.width(wt) end)
  end

  # Total packed payload length for a layout (the body's payload byte count).
  defp payload_min_len(layout) do
    Enum.reduce(layout, 0, fn {_f, wt}, acc -> acc + Contract.Layouts.width(wt) end)
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
    ValueType.resolve(type).layout()
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

  # The backplane transport, as the `0`/`1` value of BACKPLANE_TRANSPORT_UART.
  #
  # The host talks UART to the ROOT hub (its own host-UART seam is unchanged); the
  # backplane is the link the root hub uses to reach its children. The IR has no
  # explicit root marker, so v1 takes the lowest-node hub as the root (the host's
  # entry point) and asks: is any hub BELOW it reached over :uart? For v1 the
  # backplane is uniform per robot, so any one such hub flips it to a UART
  # backplane. An all-:can robot (the Follower) emits 0 and is unchanged.
  defp backplane_transport_uart(ir) do
    root_node = ir |> Enum.map(& &1.node) |> Enum.min(fn -> nil end)

    uart? =
      Enum.any?(ir, fn row -> row.node != root_node and row.transport == :uart end)

    if uart?, do: 1, else: 0
  end

  defp tick_name(%{dir: :out, hub: _hub, port: port}), do: "#{port}_sample_tick"
  defp tick_name(%{dir: :in, port: port}), do: "#{port}_cmd_tick"

  defp c_type(:f32), do: "float"
  defp c_type(:f64), do: "double"
  defp c_type(:u8), do: "uint8_t"
  defp c_type(:u16), do: "uint16_t"
  defp c_type(:u32), do: "uint32_t"
  defp c_type(:u64), do: "uint64_t"
  defp c_type(:bool), do: "bool"

  # The C struct name for a value-type ref. A stock atom (`:imu`) camelizes
  # directly (`Imu`). A consumer's own value-type is named by MODULE
  # (`MyApp.ValueType.Scalar`); its dotted string is not a valid C identifier, so
  # take the module's LAST segment (`Scalar`) — the value-type is a standalone
  # unit, so its short name uniquely names its struct.
  defp c_struct_name(type) do
    str = Atom.to_string(type)

    if String.starts_with?(str, "Elixir.") do
      type |> Module.split() |> List.last()
    else
      Macro.camelize(str)
    end
  end

  defp header_banner(file, what) do
    "/* GENERATED by BBMcuhub.Gen.WireGen — do not edit. #{file}\n   #{what} */"
  end

  defp finalize(lines), do: (lines |> List.flatten() |> Enum.join("\n")) <> "\n"

  defp up(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp hex2(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
  defp hex4(n), do: n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
end
