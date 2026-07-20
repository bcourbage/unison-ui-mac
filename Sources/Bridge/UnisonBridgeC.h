#ifndef UNISON_BRIDGE_C_H
#define UNISON_BRIDGE_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

void unison_bridge_startup(int argc, char *argv[]);

/* Release the bridge's OCaml generational global roots (preconnection
 * + per-row stateItem array). Idempotent. Intended for app-termination
 * cleanup so leak checkers don't flag retained OCaml values; doesn't
 * tear down the OCaml runtime itself (process exit handles that).
 * Must be called AFTER unison_bridge_startup — would deadlock
 * otherwise (no OCaml worker to dispatch onto). */
void unison_bridge_shutdown(void);

/* Transport-child (ssh) registry + pure-C shutdown reaper. OCaml populates the
 * registry via track/retire (exact pid: track right after spawn; retire
 * strictly before the reap, where it SIGKILLs + removes the child under the
 * mutex); `unison_bridge_shutdown` calls the reaper first thing. Exposed here
 * for the C shutdown path and for tests. See UnisonBridgeC.c and
 * docs/ssh-reaper-design.md. */
void unison_bridge_track_child(pid_t pid);
void unison_bridge_retire_child(pid_t pid);
int  unison_bridge_reap_transport_children(void);
/* Declared unconditionally so every target/config sees the prototype; only
 * DEFINED in Debug (UNISON_DEBUG_HOOKS) — the production app never calls them,
 * so a Release build links fine with no definition and the symbols are absent. */
void unison_bridge_reset_child_registry_for_test(void);
/* Test-only fault injection (Finding #6): force the next `n` OCaml bridge
 * callbacks dispatched through the worker to be treated as if they raised, so
 * the exception-handling / completion / status contract can be exercised
 * deterministically without a raising OCaml stub in the vendored blob. */
void unison_bridge_test_force_next_callbacks_raise(int n);
int  unison_bridge_test_pending_forced_raises(void);
/* Force the Kth wrapper callback after arming (1-based, counting only
 * caml_callback invocations) to raise — lets a test fail a specific callback
 * stage so post-first-mutation failures are exercisable. Single-shot. */
void unison_bridge_test_force_raise_at_ordinal(int k);
/* Test-only (Finding #1): run reloadTable's rooting pattern against row's real
 * progress/bytes callbacks with a forced moving collection interposed. Returns
 * true and fills `out` with the (still-valid) progress string on success. */
bool unison_bridge_test_reload_under_gc(int row, char *out, size_t outlen);
/* Test-only (Finding #1): build a KNOWN fresh young string, root it, force a
 * relocating minor collection, then verify it survived. Fills `out` with the
 * post-collection contents (must equal `in`) and sets *out_moved to whether the
 * block's address actually changed (proving it was young and relocated). */
bool unison_bridge_test_root_survives_gc(const char *in, char *out, size_t outlen,
                                         bool *out_moved);
/* Test-only (Blocker 3): install/clear a dummy preconnection so credential
 * prompt/reply reach the exn wrapper. Pair with forced-raise ONLY. */
void unison_bridge_test_set_fake_preconn(bool on);
/* Test-only (Blocker 1): the currently-published per-row root count. */
int unison_bridge_test_ri_count(void);

/* Bridge phase/close return codes (shared by init1/init2/synchronize/close). */
#define UNISON_BRIDGE_OK          0    /* dispatched / completed without raising */
#define UNISON_BRIDGE_ERR_EXN     2    /* the OCaml callback raised (logged) */
#define UNISON_BRIDGE_ERR_MISSING (-1) /* callback not registered (old blob) */

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
 * Util.msg / Trace.message reaches the registered Swift status handler.
 *
 * Returns UNISON_BRIDGE_OK on success; a non-OK status (ERR_EXN / ERR_MISSING)
 * means the runtime is only partly initialized. The caller MUST NOT continue a
 * normal launch on failure — it must present an unrecoverable startup error. */
int unison_bridge_init0(void);

/* === Init1 — load profile, parse roots, open remote connection ===
 *
 * Asynchronous: OCaml spawns a worker that eventually invokes the installed
 * init1-complete handler from the OCaml thread. The return value covers only
 * the SYNCHRONOUS dispatch: UNISON_BRIDGE_OK once the worker was launched, or
 * UNISON_BRIDGE_ERR_EXN if the OCaml call raised before launching (in which
 * case the completion handler will never fire and the caller must fail the op).
 *
 * If `needs_prompt` is true, the bridge has stashed a preconnection value
 * internally; the caller must drive the credential loop via
 * unison_bridge_connection_prompt / _reply / _end / _cancel before
 * proceeding to unison_bridge_init2(). */
typedef void (*unison_init1_complete_handler_t)(bool needs_prompt);
void unison_bridge_set_init1_complete_handler(unison_init1_complete_handler_t h);
int unison_bridge_init1(const char *profile_name);

/* === Credential prompts ===
 *
 * Used between init1 (needs_prompt=true) and init2 to walk OCaml's
 * Remote.openConnection state machine — typically: SSH password,
 * passphrase, or host-key-authenticity confirmation.
 *
 * Blocker 3: the result is EXPLICIT, so an OCaml exception is never confused
 * with "no more prompts". The four outcomes are distinct:
 *   AVAILABLE — `*out_prompt` holds the next prompt (bridge-owned, valid until
 *               the next bridge call; copy to retain). Show UI, then reply.
 *   DONE      — the prompt sequence finished normally. ONLY here may the caller
 *               proceed to connection_end + init2.
 *   NONE      — no preconnection is pending, or the callback is missing (stale
 *               blob). Not a normal finish: the caller must NOT call
 *               connection_end; treat as terminal.
 *   EXN       — the OCaml prompt callback raised. The caller must NOT call
 *               connection_end; retain the connect token, attempt preconnection
 *               cleanup (connection_cancel) without declaring success, and route
 *               an uncertain cleanup to restart-required.
 *
 * Usage loop:
 *   const char *p = NULL;
 *   switch (unison_bridge_connection_prompt(&p)) {
 *     case UNISON_PROMPT_AVAILABLE: show UI with p; reply; loop; break;
 *     case UNISON_PROMPT_DONE:      connection_end(); go to init2; break;
 *     default:                      terminal failure handling; break;
 *   } */
typedef enum {
    UNISON_PROMPT_AVAILABLE = 0,
    UNISON_PROMPT_DONE      = 1,
    UNISON_PROMPT_NONE      = 2,
    UNISON_PROMPT_EXN       = 3,
} unison_prompt_result_t;
unison_prompt_result_t unison_bridge_connection_prompt(const char **out_prompt);

/* Send a credential reply. Explicit status (Blocker 3):
 *   UNISON_REPLY_OK   (0)  — delivered; caller may loop back to prompt.
 *   UNISON_REPLY_NONE (-1) — no preconnection / callback missing.
 *   UNISON_REPLY_EXN  (2)  — OCaml raised. Caller must NOT continue the loop;
 *                            attempt cleanup without declaring success. */
#define UNISON_REPLY_OK    0
#define UNISON_REPLY_NONE (-1)
#define UNISON_REPLY_EXN   2
int unison_bridge_connection_reply(const char *response);

/* Finalize (end) or abort (cancel) the pending preconnection. Both are
 * exception-safe and status-returning, and release the stashed preconnection
 * on every terminal path so it is never leaked.
 *   connection_end:    0 = connection established; -1 = nothing to finalize /
 *                      callback missing; 2 = OCaml raised.
 *   connection_cancel: 0 = cancelled (or nothing to cancel — idempotent);
 *                      -1 = callback missing; 2 = OCaml raised.
 * A nonzero result must be treated by the caller as a terminal failure (the
 * connect op did not complete cleanly). */
int unison_bridge_connection_end(void);
int unison_bridge_connection_cancel(void);

/* Cleanly close the ESTABLISHED remote connection for the current
 * profile (closes the transport channels and reaps the ssh child), via
 * the same ClientConn-registry teardown upstream uses after a transport
 * failure. Safe on an established connection; a harmless no-op for a
 * local-only profile or when nothing is connected. Idempotent.
 *
 * MUST only be called when the engine is quiescent (no scan/sync in
 * flight) — closing under an active transport would tear it out. The
 * caller waits on the OCaml worker (this can block on waitpid), so run
 * it OFF the main thread.
 *
 * Returns: 0 = ok, 2 = OCaml raised (logged to stderr), -1 = the
 * closeConnection callback isn't registered (blob predates the patch). */
int unison_bridge_close_connection(void);

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

/* Terminal ASYNCHRONOUS scan failure (Blocker 2). Fired from the OCaml scan
 * worker (unisonInit2Complete) when the completed scan's state could not be
 * published — a missing accessor, an accessor raising, or OOM. The scan is over
 * but produced no items, so the init2-complete handler will never fire; this is
 * the terminal alternative. The handler must be token-bound (match the pending
 * scan op) and route to operationFailed(engineIsQuiescent:false) so the
 * coordinator leaves .scanning for restart-required rather than hanging. */
typedef void (*unison_scan_failed_handler_t)(void);
void unison_bridge_set_scan_failed_handler(unison_scan_failed_handler_t h);

/* Return covers only the synchronous dispatch: UNISON_BRIDGE_OK once the scan
 * was launched, or UNISON_BRIDGE_ERR_EXN if the OCaml call raised before
 * launching (the init2-complete handler will then never fire). A scan that
 * launches OK but then fails while publishing state reports terminally through
 * the scan-failed handler above, not through this return value. */
int unison_bridge_init2(void);

/* Structured result for mutating per-row operations (Blocker 4). Distinguishes
 * a benign validation/pre-mutation failure (safe to ignore) from a failure that
 * struck AT or AFTER the OCaml state actually began changing (the ready UI must
 * not stay live against uncertain state). A direction setter mutates its row
 * before the direction readback; Ignore is a multi-step mutation (persist a
 * pattern, then rewrite theState). So a raise partway through can leave the
 * engine in a state the displayed rows no longer describe. */
typedef enum {
    UNISON_OP_OK           = 0,  /* success */
    UNISON_OP_INVALID      = 1,  /* bad row / missing callback; NO mutation attempted */
    UNISON_OP_FAILED_CLEAN = 2,  /* raised BEFORE any mutation began; engine unchanged */
    UNISON_OP_FAILED_DIRTY = 3,  /* raised AT/AFTER mutation; engine state uncertain */
} unison_op_result_t;

/* === Per-row direction overrides ===
 *
 * `row` is a 0-based index into the most-recent unisonInit2Complete array.
 * The bridge keeps OCaml references to each row alive between calls until
 * the next init2 (then they're released and re-registered).
 *
 * On UNISON_OP_OK, `out_dir` (a caller-provided buffer of `out_dir_len` bytes)
 * receives the row's new direction string in OCaml's raw representation
 * ("---->", "<----", "<-?->", "<-M->"). On any non-OK result `out_dir` is set to
 * the empty string. A setter mutates the row before the direction is read back,
 * so any raise here is UNISON_OP_FAILED_DIRTY (never a silent "no change"): the
 * caller must route it to restart-required rather than leave a stale-but-
 * actionable row. UNISON_OP_INVALID (bad row / missing callback) mutated
 * nothing and is safe to surface narrowly. */
unison_op_result_t unison_bridge_ri_set_to_remote(int row, char *out_dir, size_t out_dir_len);  /* unisonRiSetRight */
unison_op_result_t unison_bridge_ri_set_to_local(int row, char *out_dir, size_t out_dir_len);   /* unisonRiSetLeft */
unison_op_result_t unison_bridge_ri_set_skip(int row, char *out_dir, size_t out_dir_len);       /* unisonRiSetConflict */
unison_op_result_t unison_bridge_ri_set_merge(int row, char *out_dir, size_t out_dir_len);      /* unisonRiSetMerge */
/* Force-older / force-newer pick a direction based on mtime — the side
 * with the older (resp. newer) mtime wins. Same mutation-then-readback contract
 * and result semantics as the ri_set_* functions above. */
unison_op_result_t unison_bridge_ri_force_older(int row, char *out_dir, size_t out_dir_len);
unison_op_result_t unison_bridge_ri_force_newer(int row, char *out_dir, size_t out_dir_len);

/* Calls OCaml's unisonRiToDetails for the given row and returns the
 * multi-line details string (path, both sides' size/mtime, conflict
 * reason). Returned pointer is owned by the bridge and stable until the
 * next call from the same thread — copy if you need to retain it. */
const char *unison_bridge_ri_get_details(int row);

/* === Per-row Diff ===
 *
 * `unison_bridge_can_diff` returns true if the row's two sides are both
 * files with differing CONTENT (not just metadata). Drives Diff
 * menu/button enabled state — Unison's own `canDiff` predicate.
 *
 * `unison_bridge_run_show_diffs` kicks off a diff. The result arrives
 * asynchronously via the registered diff handler (success) or diff-err
 * handler (failure, e.g. "Can't diff: path doesn't refer to a file in
 * both replicas"). Both handlers fire on the OCaml worker thread; the
 * Swift trampolines copy strings and async-dispatch to the main queue
 * before invoking user handlers.
 *
 * Returns immediately; the diff itself runs through Unison's configured
 * `diff` pref (default `diff -u`) on the OCaml side. */
bool unison_bridge_can_diff(int row);
bool unison_bridge_run_show_diffs(int row);

typedef void (*unison_diff_handler_t)(const char *title, const char *text);
typedef void (*unison_diff_err_handler_t)(const char *msg);
void unison_bridge_set_diff_handler(unison_diff_handler_t h);
void unison_bridge_set_diff_err_handler(unison_diff_err_handler_t h);

/* === Per-row Ignore actions ===
 *
 * Add a permanent ignore pattern derived from the given row's path:
 *   - _ignore_path: ignore exactly this path
 *   - _ignore_ext:  ignore anything with the same extension
 *   - _ignore_name: ignore anything with the same basename
 *
 * Each call synchronously (a) registers the pattern via Uicommon.addIgnorePattern,
 * (b) re-runs `unisonUpdateForIgnore` to filter the global reconcile state,
 * (c) re-invokes the init2-complete handler with the post-filter state-item
 * array. Swift handles the callback the same way as a rescan: replace the
 * table contents in place.
 *
 * Structured result (Blocker 4): this is a MULTI-STEP mutation. The path read is
 * read-only (a raise there is UNISON_OP_FAILED_CLEAN — nothing changed); once
 * the ignore pattern is persisted or theState is rewritten, a later failure —
 * including a failure to publish the new state — is UNISON_OP_FAILED_DIRTY and
 * the caller must route it to restart-required rather than leave stale rows
 * live. UNISON_OP_INVALID (bad row / missing callback) mutated nothing. */
unison_op_result_t unison_bridge_ignore_path(int row);
unison_op_result_t unison_bridge_ignore_ext(int row);
unison_op_result_t unison_bridge_ignore_name(int row);

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
/* Return covers only the synchronous dispatch: UNISON_BRIDGE_OK once the sync
 * worker was launched (completion arrives later via the sync-complete handler),
 * or UNISON_BRIDGE_ERR_EXN if the OCaml call raised before launching (the
 * sync-complete handler will then never fire). */
int unison_bridge_synchronize(void);

/* Real mid-sync abort. Sets OCaml's `Abort.abortAll` flag; the
 * in-flight sync worker raises `Util.Transient "Aborted by user
 * request"` the next time it hits an `Abort.check` checkpoint —
 * typically between files, sometimes mid-file at network boundaries.
 * Already-in-progress operations may complete naturally before the
 * abort propagates.
 *
 * In-progress rows surface as FAILED via the existing per-row reload
 * callback; eventually `sync_complete_handler` fires once the worker
 * has unwound. Safe to call multiple times — idempotent on the
 * OCaml side (just re-assigns the flag).
 *
 * Depends on the `abortAll` callback being registered in
 * `uimacbridge.ml` (local fork only — not in upstream Unison's
 * vanilla bridge).
 *
 * Returns UNISON_BRIDGE_OK when the abort flag was set; a non-OK status
 * (ERR_EXN / ERR_MISSING) means the flag was NOT reliably set, so the caller
 * must NOT report that cancellation was successfully requested. */
int unison_bridge_abort_sync(void);

#ifdef __cplusplus
}
#endif

#endif
