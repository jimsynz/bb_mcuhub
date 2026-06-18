#include "cobs.h"
#include <stdbool.h>

size_t cobs_encode(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  if (out_cap < 1) return 0;

  size_t read = 0;       /* next input byte to consume */
  size_t code_idx = 0;   /* where the current block's code byte lives in `out` */
  size_t write = 1;      /* next free output slot (slot 0 holds the first code) */
  uint8_t code = 1;      /* 1 + number of non-zero bytes in the current block */

  while (read < in_len) {
    uint8_t b = in[read++];
    if (b == 0) {
      /* close the current block at a zero: write the code, open a new block */
      out[code_idx] = code;
      code_idx = write++;
      if (write > out_cap) return 0;
      code = 1;
    } else {
      if (write >= out_cap) return 0;
      out[write++] = b;
      code++;
      if (code == 0xFF) {
        /* full 254-byte block: emit 0xFF, open a fresh block, no implied zero */
        out[code_idx] = code;
        code_idx = write++;
        if (write > out_cap) return 0;
        code = 1;
      }
    }
  }

  out[code_idx] = code; /* close the final block */
  return write;
}

size_t cobs_decode(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  size_t read = 0;
  size_t write = 0;
  bool first = true;

  while (read < in_len) {
    uint8_t code = in[read++];
    uint8_t n = (uint8_t)(code - 1);

    if (read + n > in_len) return 0; /* code points past the data → corrupt */

    if (!first) {
      if (write >= out_cap) return 0;
      out[write++] = 0; /* the zero this code stood in for */
    }
    for (uint8_t i = 0; i < n; i++) {
      if (write >= out_cap) return 0;
      out[write++] = in[read++];
    }
    first = (code == 0xFF); /* a full block implies no trailing zero */
  }

  return write;
}
