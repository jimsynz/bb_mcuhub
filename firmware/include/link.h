/* The link + board interface shared across the firmware (§03/§08).
 *
 * Declared once here with C linkage so the pure-C hub logic (hubs/<hub>/mcu/*.c)
 * and the C++ ESP32 glue (firmware/src/esp32/*.cpp) agree on the symbols — a
 * mismatched extern is the linker error this header exists to prevent. */
#ifndef BB_MCUHUB_LINK_H
#define BB_MCUHUB_LINK_H

#include <stddef.h>
#include <stdint.h>
#include "frame.h"
#include "scheduler.h" /* for Task, used by hub_tasks() */

#ifdef __cplusplus
extern "C" {
#endif

/* --- the link layer (firmware/src/esp32/link_esp32.cpp) --- */
void link_begin(void);
void link_pump(void);
void link_set_on_body(void (*cb)(const uint8_t *body, size_t len));
void link_send_up(const Frame *f); /* toward parent/host; bridge re-frames UART/CAN */

/* --- supplied by each board sketch (hubs/<hub>/mcu/main_*.cpp) --- */
void hub_setup(void);
void hub_on_body(const uint8_t *body, size_t len);
Task *hub_tasks(size_t *n_tasks);

#ifdef __cplusplus
}
#endif

#endif /* BB_MCUHUB_LINK_H */
