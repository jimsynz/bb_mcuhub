# CAN segmentation rides the reserved id bits, with an end-to-end CRC trailer

<a id="adr-0001"></a>

A logical body (`NODE·PORT·SEQ·[T_DEV]·PAYLOAD·CRC16`) is often wider than a CAN
data field (8 B on the ESP32's classic-CAN TWAI; the IMU body is 54 B). We
segment it across CAN frames, and we put the fragment metadata
(`[FIRST:1][LAST:1][SEQLO:5][FRAG_IDX:6]`) in the **13 reserved bits of the 29-bit
id**, not in the data field — so the CAN data bytes stay 100% body and are
byte-identical to the UART body for the same value, keeping the parity vectors
(the cross-language drift witness, §06) valid across both transports. The
end-to-end **CRC-16 rides the body as a 2-byte trailer and is checked on every CAN
receive** (single- and multi-frame), because CAN's own per-frame CRC cannot
survive a branch hub's decode-rebuild-retransmit. Reassembly is **fail-closed**: a
buffer is seeded only by a FIRST fragment, and any gap/reorder/alias/CRC-fail
drops the **whole** body (counted, never delivered partial) — a lost body is a
stale-making non-event the freshness machinery (§04) already tolerates, whereas a
partial body reaching a slot would be silent corruption. No reassembly timeout in
v1; a stalled partial is reclaimed by the next FIRST for that `(node,port)`.

## Considered Options

- **Fragment metadata in a data-field sub-header** — rejected: it would fork the
  CAN body bytes from the UART body bytes for the same value, breaking the single
  parity-vector set that guarantees the two codecs can't drift.
- **Trust CAN's hardware CRC for single frames, add ours only when segmenting** —
  rejected: leaves the re-framing gap open on the common (small) path and
  contradicts §03's "CRC guards the body across the UART↔CAN boundary."
- **ARQ / partial recovery / out-of-order tolerance** — deferred (SAFeD): a lost
  body costs one sample, which born-stale/`fresh_for` already handle; not worth
  the state machine in v1.

## Consequences

- 6-bit index caps a body at **64 fragments → 512 bytes**, asserted by the §06
  boot size-check. The fragment bits sit below NODE/PORT, so the `(NODE,PORT)`
  hardware filter and arbitration priority are undisturbed — `NODE 0x00` (e-stop)
  still wins the bus.
- The on-wire id-bit layout is now a wire-format commitment baked into the C side,
  the host side, and the parity vectors; changing it is a coordinated, hard
  reversal — hence this record.
