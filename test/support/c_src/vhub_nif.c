/* vhub_nif.c — a TEST-ONLY NIF exposing the REAL firmware C floor + wire path
 * to the host-side e2e suite (Option B). It compiles the same chassis sources
 * the firmware/test harnesses host-compile (floor.c, transport.c, frame.c,
 * crc16.c, cobs.c), so the soft-fault e2e runs the ACTUAL safety code — not an
 * Elixir re-implementation that could drift.
 *
 * Design: purely FUNCTIONAL NIF. All C state (the Floor struct, the
 * TransportDecoder) is round-tripped as an Erlang binary — the NIF holds no
 * resources, no globals, no threads. This is the safest possible NIF (a
 * leaf-pure value transformer) and composes with Elixir immutability: the
 * VirtualHub keeps the floor/decoder state as binaries and threads them through
 * each call.
 *
 * Exposed (ADR-0005: the floor is byte-generic — values are packed binaries):
 *   floor_init(window_ms, safe_bytes)             -> floor_state (binary)
 *   floor_on_command(floor_state, seq, value_bytes) -> floor_state
 *   floor_tick(floor_state, now_ms)               -> {floor_state, drive_bytes,
 * armed} transport_encode(body)                        -> wire_bytes (binary)
 *   decoder_new()                                 -> decoder_state (binary)
 *   decoder_feed(decoder_state, bytes)            -> {decoder_state, [body],
 * rx_drop} frame_decode_body(body, stamped)              -> {:ok, node, port,
 * seq} | :error
 */
#include "erl_nif.h"
#include "floor.h"
#include "frame.h"
#include "transport.h"
#include <string.h>

/* ---- Floor: state passed as a binary holding the Floor struct verbatim ----
 */

static ERL_NIF_TERM mk_floor_bin(ErlNifEnv *env, const Floor *f) {
  ERL_NIF_TERM bin;
  unsigned char *p = enif_make_new_binary(env, sizeof(Floor), &bin);
  memcpy(p, f, sizeof(Floor));
  return bin;
}

static int get_floor(ErlNifEnv *env, ERL_NIF_TERM term, Floor *f) {
  ErlNifBinary b;
  if (!enif_inspect_binary(env, term, &b) || b.size != sizeof(Floor))
    return 0;
  memcpy(f, b.data, sizeof(Floor));
  return 1;
}

static ERL_NIF_TERM nif_floor_init(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  unsigned int window_ms;
  ErlNifBinary safe;
  if (!enif_get_uint(env, argv[0], &window_ms) ||
      !enif_inspect_binary(env, argv[1], &safe) || safe.size > FLOOR_MAX_VALUE)
    return enif_make_badarg(env);
  Floor f;
  floor_init(&f, (uint32_t)window_ms, safe.data, (uint8_t)safe.size);
  return mk_floor_bin(env, &f);
}

static ERL_NIF_TERM nif_floor_on_command(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  (void)argc;
  Floor f;
  unsigned int seq;
  ErlNifBinary value;
  if (!get_floor(env, argv[0], &f) || !enif_get_uint(env, argv[1], &seq) ||
      !enif_inspect_binary(env, argv[2], &value) ||
      value.size > FLOOR_MAX_VALUE)
    return enif_make_badarg(env);
  floor_on_command(&f, (uint16_t)seq, value.data, (uint8_t)value.size);
  return mk_floor_bin(env, &f);
}

static ERL_NIF_TERM nif_floor_tick(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  Floor f;
  unsigned int now_ms;
  if (!get_floor(env, argv[0], &f) || !enif_get_uint(env, argv[1], &now_ms))
    return enif_make_badarg(env);
  uint8_t buf[FLOOR_MAX_VALUE];
  uint8_t n = floor_tick(&f, (uint32_t)now_ms, buf);
  ERL_NIF_TERM drive;
  unsigned char *p = enif_make_new_binary(env, n, &drive);
  memcpy(p, buf, n);
  return enif_make_tuple3(env, mk_floor_bin(env, &f), drive,
                          enif_make_atom(env, f.armed ? "true" : "false"));
}

/* ---- transport_encode: body bytes -> framed wire bytes ---- */

static ERL_NIF_TERM nif_transport_encode(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary body;
  if (!enif_inspect_binary(env, argv[0], &body))
    return enif_make_badarg(env);
  uint8_t out[FRAME_MAX_WIRE];
  size_t n = transport_encode(body.data, body.size, out, sizeof(out));
  if (n == 0)
    return enif_make_atom(env, "error");
  ERL_NIF_TERM bin;
  unsigned char *p = enif_make_new_binary(env, n, &bin);
  memcpy(p, out, n);
  return bin;
}

/* ---- transport decoder: state passed as a binary holding TransportDecoder
 * ---- decoder_feed collects every verified body the C decoder peels off, into
 * a list.
 */

typedef struct {
  ErlNifEnv *env;
  ERL_NIF_TERM list; /* accumulated bodies, reversed at the end */
} CollectCtx;

static void collect_body(const uint8_t *body, size_t body_len, void *ctx_) {
  CollectCtx *ctx = (CollectCtx *)ctx_;
  ERL_NIF_TERM bin;
  unsigned char *p = enif_make_new_binary(ctx->env, body_len, &bin);
  memcpy(p, body, body_len);
  ctx->list = enif_make_list_cell(ctx->env, bin, ctx->list);
}

static ERL_NIF_TERM nif_decoder_new(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  TransportDecoder d;
  transport_decoder_init(&d);
  ERL_NIF_TERM bin;
  unsigned char *p = enif_make_new_binary(env, sizeof(TransportDecoder), &bin);
  memcpy(p, &d, sizeof(TransportDecoder));
  return bin;
}

static ERL_NIF_TERM nif_decoder_feed(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary dbin, bytes;
  if (!enif_inspect_binary(env, argv[0], &dbin) ||
      dbin.size != sizeof(TransportDecoder) ||
      !enif_inspect_binary(env, argv[1], &bytes))
    return enif_make_badarg(env);

  TransportDecoder d;
  memcpy(&d, dbin.data, sizeof(TransportDecoder));

  CollectCtx ctx = {.env = env, .list = enif_make_list(env, 0)};
  transport_decoder_feed(&d, bytes.data, bytes.size, collect_body, &ctx);

  ERL_NIF_TERM out_d;
  unsigned char *p =
      enif_make_new_binary(env, sizeof(TransportDecoder), &out_d);
  memcpy(p, &d, sizeof(TransportDecoder));

  ERL_NIF_TERM ordered;
  enif_make_reverse_list(env, ctx.list, &ordered);
  return enif_make_tuple3(env, out_d, ordered, enif_make_uint(env, d.rx_drop));
}

/* ---- frame_decode_body: read NODE/PORT/SEQ from a verified body (C path) ----
 */

static ERL_NIF_TERM nif_frame_decode_body(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary body;
  char stamped_atom[8];
  if (!enif_inspect_binary(env, argv[0], &body) ||
      !enif_get_atom(env, argv[1], stamped_atom, sizeof(stamped_atom),
                     ERL_NIF_LATIN1))
    return enif_make_badarg(env);
  bool stamped = strcmp(stamped_atom, "true") == 0;
  Frame f;
  if (!frame_decode_body(body.data, body.size, stamped, &f))
    return enif_make_atom(env, "error");
  return enif_make_tuple4(
      env, enif_make_atom(env, "ok"), enif_make_uint(env, f.node),
      enif_make_uint(env, f.port), enif_make_uint(env, f.seq));
}

static ErlNifFunc nif_funcs[] = {
    {"floor_init", 2, nif_floor_init, 0},
    {"floor_on_command", 3, nif_floor_on_command, 0},
    {"floor_tick", 2, nif_floor_tick, 0},
    {"transport_encode", 1, nif_transport_encode, 0},
    {"decoder_new", 0, nif_decoder_new, 0},
    {"decoder_feed", 2, nif_decoder_feed, 0},
    {"frame_decode_body", 2, nif_frame_decode_body, 0},
};

ERL_NIF_INIT(Elixir.BBMCUHub.Test.VHubNif, nif_funcs, NULL, NULL, NULL, NULL)
