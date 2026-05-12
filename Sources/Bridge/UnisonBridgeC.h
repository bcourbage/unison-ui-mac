#ifndef UNISON_BRIDGE_C_H
#define UNISON_BRIDGE_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void unison_bridge_startup(int argc, char *argv[]);

const char *unison_bridge_get_version(void);

/* Returns the path to the Unison preferences directory
 * (typically ~/Library/Application Support/Unison or ~/.unison). */
const char *unison_bridge_unison_directory(void);

/* === OCaml -> Swift callback registration ===
 *
 * OCaml's uimacbridge.ml declares ~11 `external` C functions; the C shim
 * provides implementations that forward into Swift via these handler hooks.
 * Swift registers a handler at startup; the C side calls it from the OCaml
 * thread when the corresponding OCaml event fires.
 */

typedef void (*unison_status_handler_t)(const char *status);
void unison_bridge_set_status_handler(unison_status_handler_t handler);

typedef void (*unison_progress_handler_t)(double fraction);
void unison_bridge_set_progress_handler(unison_progress_handler_t handler);

/* === Modal warning/error sheets ===
 *
 * warnPanel and fatalError are called from the OCaml worker thread and
 * (for warnPanel) must return a synchronous answer to OCaml. The bridge
 * builds a request, releases the OCaml runtime so other workers can run,
 * dispatches into Swift, and blocks on a condvar. Swift shows an NSAlert,
 * waits for the user, and calls the *_response function below to wake C.
 *
 * `opaque` is a bridge-internal pointer; pass it through unchanged. */
typedef void (*unison_warn_handler_t)(const char *msg, void *opaque);
typedef void (*unison_fatal_handler_t)(const char *msg, void *opaque);

void unison_bridge_set_warn_handler(unison_warn_handler_t h);
void unison_bridge_set_fatal_handler(unison_fatal_handler_t h);

/* Swift calls this after the warning sheet is dismissed.
 * `user_wants_exit` == true tells OCaml to terminate; false means proceed. */
void unison_bridge_warn_response(void *opaque, bool user_wants_exit);

/* Swift calls this after the fatal-error sheet is dismissed. */
void unison_bridge_fatal_response(void *opaque);

/* Synthetic trigger — invokes the registered status handler directly,
 * bypassing OCaml. For wiring tests only. */
void unison_bridge_test_status(const char *msg);

/* Calls OCaml's unisonInit0, which (among other setup) wires
 * Trace.messageDisplayer := displayStatus. After this returns, any OCaml-side
 * Util.msg / Trace.message reaches the registered Swift status handler. */
void unison_bridge_init0(void);

/* === Init1 — load profile, parse roots, open remote connection ===
 *
 * Asynchronous: returns immediately; OCaml spawns a worker that eventually
 * invokes the installed init1-complete handler from the OCaml thread.
 *
 * If `needs_prompt` is true, the bridge has stashed a preconnection value
 * internally; the caller must drive the credential loop via
 * unison_bridge_connection_prompt / _reply / _end / _cancel before
 * proceeding to unison_bridge_init2(). */
typedef void (*unison_init1_complete_handler_t)(bool needs_prompt);
void unison_bridge_set_init1_complete_handler(unison_init1_complete_handler_t h);
void unison_bridge_init1(const char *profile_name);

/* === Credential prompts ===
 *
 * Used between init1 (needs_prompt=true) and init2 to walk OCaml's
 * Remote.openConnection state machine — typically: SSH password,
 * passphrase, or host-key-authenticity confirmation.
 *
 * Usage loop:
 *   const char *p = unison_bridge_connection_prompt();
 *   if (p == NULL) { unison_bridge_connection_end(); }   // go to init2
 *   else {                                                // show UI with `p`
 *          unison_bridge_connection_reply(response);
 *          // loop back to prompt
 *   }
 *
 * Returned prompt string is owned by the bridge and valid until the next
 * bridge call. Copy if you need to retain it. */
const char *unison_bridge_connection_prompt(void);
void unison_bridge_connection_reply(const char *response);
void unison_bridge_connection_end(void);
void unison_bridge_connection_cancel(void);

/* === Init2 — reconcile updates between roots ===
 *
 * Asynchronous. When complete, the init2-complete handler is invoked once
 * with a freshly built flat array of state items. The C strings and the
 * array itself are owned by the bridge and freed *after* the handler
 * returns — so the handler MUST copy/convert before returning.
 *
 * One OCaml->C transition does all per-row extraction (6 callbacks per row
 * inside the loop) on the OCaml thread. The Swift trampoline copies into
 * a Swift [StateItem] (which copies each String), then returns. Total
 * cost for N rows: ~6N caml_callback dispatches + N * 6 strdup, all on
 * the OCaml thread, no inter-thread handoffs. */
typedef struct unison_state_item {
    const char *path;             /* relative path, e.g. "Documents/foo.txt" */
    const char *left;             /* "", "Created", "Modified", "Deleted", "PropsChanged" */
    const char *right;            /* same */
    const char *direction;        /* "----\076", "<----", "<-?->", "<-M->", or "" */
    int64_t     size_bytes;       /* file size in bytes */
    const char *file_type;        /* "FILE", "DIR", "SYMLINK", ... */
    const char *progress;         /* "", "start ", " 35%", "done", "FAILED" */
    int64_t     bytes_transferred;
} unison_state_item_t;

typedef void (*unison_init2_complete_handler_t)(const unison_state_item_t *items,
                                                 size_t count);
void unison_bridge_set_init2_complete_handler(unison_init2_complete_handler_t h);
void unison_bridge_init2(void);

/* === Per-row direction overrides ===
 *
 * `row` is a 0-based index into the most-recent unisonInit2Complete array.
 * The bridge keeps OCaml references to each row alive between calls until
 * the next init2 (then they're released and re-registered).
 *
 * Each function returns the row's new direction string in OCaml's raw
 * representation ("---->", "<----", "<-?->", "<-M->"). The returned
 * pointer is owned by the bridge and stable until the next call from the
 * same thread — copy it if you need to retain it.
 *
 * Returns NULL if the row is out of range or the OCaml call fails. */
const char *unison_bridge_ri_set_to_remote(int row);  /* unisonRiSetRight: local wins */
const char *unison_bridge_ri_set_to_local(int row);   /* unisonRiSetLeft:  remote wins */
const char *unison_bridge_ri_set_skip(int row);       /* unisonRiSetConflict */
const char *unison_bridge_ri_set_merge(int row);      /* unisonRiSetMerge */

/* === Synchronize — run the transfer over the current direction overrides ===
 *
 * Asynchronous. During sync, OCaml fires displayStatus + displayGlobalProgress
 * (already wired) and reloadTable(row) when a row's per-file progress changes.
 * When sync finishes, syncComplete fires.
 *
 * Like init1/init2 — returns immediately; OCaml runs sync on its own thread. */
typedef struct unison_row_state {
    const char *progress;          /* e.g. "  5%", "done", "FAILED", "" */
    int64_t     bytes_transferred;
} unison_row_state_t;

typedef void (*unison_reload_row_handler_t)(int row, const unison_row_state_t *state);
typedef void (*unison_sync_complete_handler_t)(void);

void unison_bridge_set_reload_row_handler(unison_reload_row_handler_t h);
void unison_bridge_set_sync_complete_handler(unison_sync_complete_handler_t h);
void unison_bridge_synchronize(void);

#ifdef __cplusplus
}
#endif

#endif
