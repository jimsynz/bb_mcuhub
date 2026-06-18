/* Consistent Overhead Byte Stuffing (§03). Standard COBS: 254-byte blocks, code
 * 0xFF marks a full block with no implied trailing zero. Encoding is null-free,
 * so a lone 0x00 is an unambiguous frame delimiter. Mirrors BBMcuhub.Wire.COBS;
 * the round-trip is verified on the host and the parity vectors cross-check. */
#ifndef BB_MCUHUB_COBS_H
#define BB_MCUHUB_COBS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Encode `in_len` bytes into `out` (capacity `out_cap`). Returns the encoded
 * length, or 0 if it would not fit. Worst case is in_len + in_len/254 + 1. */
size_t cobs_encode(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap);

/* Decode `in_len` COBS bytes (the bytes BETWEEN delimiters) into `out`. Returns
 * the decoded length, or 0 on a truncated/corrupt run or insufficient capacity. */
size_t cobs_decode(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_COBS_H */
