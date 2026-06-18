/* CRC-16/CCITT-FALSE — the one pinned variant (§03).
 *   poly 0x1021 · init 0xFFFF · no reflection · xorout 0x0000
 *   check value 0x29B1 over the ASCII bytes "123456789".
 * Identical math to BBMcuhub.Wire.CRC16; the parity vectors (§06) prove both
 * sides hash the same bytes. */
#ifndef BB_MCUHUB_CRC16_H
#define BB_MCUHUB_CRC16_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint16_t crc16_ccitt_false(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_CRC16_H */
