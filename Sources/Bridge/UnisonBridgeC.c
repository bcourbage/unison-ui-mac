#include "UnisonBridgeC.h"

#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/threads.h>
#if UNISON_DEBUG_HOOKS
#include <stdatomic.h>       /* atomic fault-injection flags — Debug tests only */
#include <caml/minor_gc.h>   /* caml_minor_collection — Finding #1 GC-rooting test */
#include <caml/alloc.h>      /* caml_alloc_string — young-value GC probe */
#endif

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/sysctl.h>      /* KERN_PROC_PID + struct kinfo_proc — issue #35 */
#include <sys/proc.h>        /* SZOMB — zombie-state detection for #35 */
#include <time.h>

/* Forward declarations for the exception-safe callback wrappers (Finding #6).
 * Defined lower down, but referenced earlier by emit_state_items; the full
 * contract is documented at their definitions. */
static value bridge_call1_exn(const value *fn, value arg, bool *raised);
static value bridge_call2_exn(const value *fn, value a, value b, bool *raised);
static char *bridge_strdup(const char *s);
static void free_sync_rows(unison_sync_row_t *rows, size_t count);

/* =====================================================================
 * Threading model
 * =====================================================================
 *
 * OCaml lives on its own thread (spawned by unison_bridge_startup). The
 * caller thread (typically the AppKit main thread) hands work to OCaml
 * via a single-slot request/response handoff protected by mutex+condvar.
 *
 * `bridgeThreadWait` is the C function that parks an OCaml-aware thread
 * waiting for work. `callbackThreadCreate` (OCaml side, uimacbridge.ml)
 * spawns 3 such threads — extras exist so a re-entrant chain
 * (C → OCaml → C-callback → Swift → unison_bridge_xxx) has a free worker
 * instead of deadlocking on the single in-flight slot.
 *
 * Only one worker actually runs OCaml at any time — the OCaml runtime
 * lock serializes them. The extra workers are parked in a blocking
 * section, costing only their pthread stacks.
 *
 * Callers are genuinely concurrent: public entry points are invoked both
 * from the main thread (e.g. applicationWillTerminate) and from the
 * `net.courbage.unison-ui.connect` dispatch queue (the prompt loop). They
 * contend for the single request slot and serialize on `call_mutex`. Each
 * caller waits on its OWN per-request condvar for completion, so a worker
 * signalling one request can never wake — and be consumed by — a different
 * caller. (An earlier design shared one condvar across two mutexes, which
 * lost wakeups and deadlocked termination when a prompt loop was in flight.)
 */

typedef void (*ocaml_thread_fn_t)(void *user);

typedef struct call_request {
    ocaml_thread_fn_t fn;
    void *user;
    bool done;
    /* Per-request completion condvar. Only this request's caller waits on
     * it, so the worker's signal can never be stolen by an unrelated
     * waiter (the lost-wakeup bug that hung app termination). */
    pthread_cond_t done_cond;
} call_request_t;

/* One mutex governs ALL shared handoff state (g_pending and every
 * request's `done` flag). The previous design waited on a single condvar
 * with two different mutexes, which is undefined behavior under POSIX and
 * produced lost wakeups whenever two threads called in concurrently (e.g.
 * the connect queue driving the prompt loop while the main thread ran
 * applicationWillTerminate). */
static pthread_mutex_t call_mutex = PTHREAD_MUTEX_INITIALIZER;
/* Signaled when a worker frees the single request slot — woken by queued
 * callers waiting to install their request. */
static pthread_cond_t  slot_cond  = PTHREAD_COND_INITIALIZER;
/* Signaled when a request is installed — woken by parked workers. */
static pthread_cond_t  work_cond  = PTHREAD_COND_INITIALIZER;

static call_request_t *g_pending = NULL;

static void run_on_ocaml_thread(ocaml_thread_fn_t fn, void *user) {
    call_request_t req = { .fn = fn, .user = user, .done = false };
    pthread_cond_init(&req.done_cond, NULL);

    pthread_mutex_lock(&call_mutex);
    while (g_pending != NULL) {
        /* A previous request holds the single slot; wait for it to free. */
        pthread_cond_wait(&slot_cond, &call_mutex);
    }
    g_pending = &req;
    pthread_cond_signal(&work_cond);

    /* Wait on our OWN condvar so a completion signal can't be consumed by
     * another caller that is only waiting for a free slot. */
    while (!req.done) {
        pthread_cond_wait(&req.done_cond, &call_mutex);
    }
    pthread_mutex_unlock(&call_mutex);

    pthread_cond_destroy(&req.done_cond);
}

/* =====================================================================
 * Worker entry — called from OCaml side (`bridgeThreadWait`).
 * Owns the OCaml runtime lock when running OCaml; releases it while
 * waiting for work so other workers can serve nested calls.
 * ===================================================================== */

CAMLprim value bridgeThreadWait(value ignore) {
    CAMLparam1(ignore);
    for (;;) {
        caml_release_runtime_system();

        pthread_mutex_lock(&call_mutex);
        while (g_pending == NULL) {
            pthread_cond_wait(&work_cond, &call_mutex);
        }
        call_request_t *req = g_pending;
        g_pending = NULL;
        /* Free the slot before running the OCaml work so the next caller
         * can queue while we hold the runtime lock. */
        pthread_cond_signal(&slot_cond);
        pthread_mutex_unlock(&call_mutex);

        caml_acquire_runtime_system();

        req->fn(req->user);

        /* Signal completion on the request's own condvar. Taking call_mutex
         * here is safe while holding the runtime lock: it's a leaf lock with
         * no OCaml allocation in the critical section. */
        pthread_mutex_lock(&call_mutex);
        req->done = true;
        pthread_cond_signal(&req->done_cond);
        pthread_mutex_unlock(&call_mutex);
    }
    CAMLreturn(Val_unit); /* unreachable */
}

/* =====================================================================
 * OCaml -> C -> Swift callbacks
 * ===================================================================== */

static unison_status_handler_t           g_status_handler          = NULL;
static unison_progress_handler_t         g_progress_handler        = NULL;
static unison_init1_complete_handler_t   g_init1_complete_handler  = NULL;
static unison_init2_complete_handler_t   g_init2_complete_handler  = NULL;
static unison_init2_complete_handler_t   g_ignore_complete_handler = NULL;
static unison_scan_failed_handler_t      g_scan_failed_handler     = NULL;
static unison_reload_row_handler_t       g_reload_row_handler      = NULL;
static unison_sync_complete_handler_t    g_sync_complete_handler   = NULL;
static unison_diff_handler_t             g_diff_handler            = NULL;
static unison_diff_err_handler_t         g_diff_err_handler        = NULL;

void unison_bridge_set_status_handler(unison_status_handler_t handler) {
    g_status_handler = handler;
}

void unison_bridge_set_progress_handler(unison_progress_handler_t handler) {
    g_progress_handler = handler;
}

void unison_bridge_set_init1_complete_handler(unison_init1_complete_handler_t handler) {
    g_init1_complete_handler = handler;
}

void unison_bridge_set_init2_complete_handler(unison_init2_complete_handler_t handler) {
    g_init2_complete_handler = handler;
}

void unison_bridge_set_scan_failed_handler(unison_scan_failed_handler_t handler) {
    g_scan_failed_handler = handler;
}

void unison_bridge_set_ignore_complete_handler(unison_init2_complete_handler_t handler) {
    g_ignore_complete_handler = handler;
}

void unison_bridge_set_reload_row_handler(unison_reload_row_handler_t handler) {
    g_reload_row_handler = handler;
}

void unison_bridge_set_sync_complete_handler(unison_sync_complete_handler_t handler) {
    g_sync_complete_handler = handler;
}

void unison_bridge_set_diff_handler(unison_diff_handler_t handler) {
    g_diff_handler = handler;
}

void unison_bridge_set_diff_err_handler(unison_diff_err_handler_t handler) {
    g_diff_err_handler = handler;
}

void unison_bridge_test_status(const char *msg) {
    if (g_status_handler) {
        g_status_handler(msg);
    }
}

CAMLprim value displayStatus(value s) {
    CAMLparam1(s);
    if (g_status_handler) {
        g_status_handler(String_val(s));
    }
    CAMLreturn(Val_unit);
}

CAMLprim value displayGlobalProgress(value v) {
    CAMLparam1(v);
    if (g_progress_handler) {
        g_progress_handler(Double_val(v));
    }
    CAMLreturn(Val_unit);
}

#define UNISON_CB_STUB(name) \
    CAMLprim value name(value v) { \
        (void)v; \
        fprintf(stderr, "unison-mac: stub callback '" #name "' invoked\n"); \
        abort(); \
    }

/* === Modal warning/error handoff ===
 *
 * Pattern (same for warn and fatal):
 *   1. Build a request_t on this thread's stack (mutex + cond + result slots)
 *   2. Release the OCaml runtime so other workers can run
 *   3. Hand off to Swift with a pointer to the request
 *   4. Wait on the condvar
 *   5. Reacquire the OCaml runtime
 *   6. Return the result to OCaml
 *
 * Swift signals completion via unison_bridge_{warn,fatal}_response, which
 * acquires the request's mutex and sets `done`. */

typedef struct warn_request {
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
    bool            done;
    bool            user_wants_exit;
} warn_request_t;

static unison_warn_handler_t  g_warn_handler  = NULL;
static unison_fatal_handler_t g_fatal_handler = NULL;

void unison_bridge_set_warn_handler(unison_warn_handler_t handler) {
    g_warn_handler = handler;
}

void unison_bridge_set_fatal_handler(unison_fatal_handler_t handler) {
    g_fatal_handler = handler;
}

void unison_bridge_warn_response(void *opaque, bool user_wants_exit) {
    warn_request_t *req = (warn_request_t *)opaque;
    pthread_mutex_lock(&req->mutex);
    req->user_wants_exit = user_wants_exit;
    req->done = true;
    pthread_cond_signal(&req->cond);
    pthread_mutex_unlock(&req->mutex);
}

void unison_bridge_fatal_response(void *opaque) {
    /* Reuse the same request shape; just signal done. */
    warn_request_t *req = (warn_request_t *)opaque;
    pthread_mutex_lock(&req->mutex);
    req->done = true;
    pthread_cond_signal(&req->cond);
    pthread_mutex_unlock(&req->mutex);
}

CAMLprim value warnPanel(value s) {
    CAMLparam1(s);

    /* No handler installed (early startup, autotest): fall back to log+proceed
     * so OCaml doesn't kill the app on every warning. */
    if (g_warn_handler == NULL) {
        fprintf(stderr, "unison-mac WARN: %s\n", String_val(s));
        CAMLreturn(Val_int(0));
    }

    /* strdup before releasing the runtime — String_val(s) becomes invalid
     * the moment GC can run, which is what releasing the lock allows. */
    char *msg_copy = strdup(String_val(s));

    warn_request_t req;
    pthread_mutex_init(&req.mutex, NULL);
    pthread_cond_init(&req.cond, NULL);
    req.done = false;
    req.user_wants_exit = false;

    caml_release_runtime_system();

    g_warn_handler(msg_copy, &req);

    pthread_mutex_lock(&req.mutex);
    while (!req.done) {
        pthread_cond_wait(&req.cond, &req.mutex);
    }
    bool user_wants_exit = req.user_wants_exit;
    pthread_mutex_unlock(&req.mutex);

    pthread_mutex_destroy(&req.mutex);
    pthread_cond_destroy(&req.cond);
    free(msg_copy);

    caml_acquire_runtime_system();

    CAMLreturn(Val_int(user_wants_exit ? 1 : 0));
}

CAMLprim value fatalError(value s) {
    CAMLparam1(s);

    if (g_fatal_handler == NULL) {
        fprintf(stderr, "unison-mac FATAL: %s\n", String_val(s));
        CAMLreturn(Val_unit);
    }

    char *msg_copy = strdup(String_val(s));

    warn_request_t req;
    pthread_mutex_init(&req.mutex, NULL);
    pthread_cond_init(&req.cond, NULL);
    req.done = false;
    req.user_wants_exit = false;

    caml_release_runtime_system();

    g_fatal_handler(msg_copy, &req);

    pthread_mutex_lock(&req.mutex);
    while (!req.done) {
        pthread_cond_wait(&req.cond, &req.mutex);
    }
    pthread_mutex_unlock(&req.mutex);

    pthread_mutex_destroy(&req.mutex);
    pthread_cond_destroy(&req.cond);
    free(msg_copy);

    caml_acquire_runtime_system();

    CAMLreturn(Val_unit);
}

/* Called from OCaml when a diff attempt fails (e.g. one side is binary,
 * the row isn't a file, the external `diff` pref command errored). The
 * Swift handler receives the raw error message; it's typically routed
 * to whichever DiffWindow is open so the user sees the error in
 * context. Also mirrored to the status log for posterity. */
CAMLprim value displayDiffErr(value s) {
    CAMLparam1(s);
    const char *msg = String_val(s);
    fprintf(stderr, "unison-mac DIFF ERR: %s\n", msg);
    if (g_diff_err_handler) {
        g_diff_err_handler(msg);
    }
    if (g_status_handler) {
        char buf[2048];
        snprintf(buf, sizeof(buf), "diff error: %s", msg);
        g_status_handler(buf);
    }
    CAMLreturn(Val_unit);
}

/* Generational global roots for the most recent state-item array. Indexed
 * the same way Swift's [StateItem] is — a Swift row index translates to an
 * OCaml stateItem via g_ri_roots[row]. Re-registered on each init2;
 * cleared on init2 entry to release the previous batch. */
static value *g_ri_roots = NULL;
static size_t g_ri_count = 0;

/* Fired during sync each time a row's progress changes. We re-read the
 * row's progress text and bytes-transferred here on the OCaml thread (we
 * have the runtime lock) and call the Swift handler synchronously. The
 * Swift trampoline must copy strings before async-dispatching. */
CAMLprim value reloadTable(value row) {
    CAMLparam1(row);
    int i = Int_val(row);
    if (i < 0 || (size_t)i >= g_ri_count || g_reload_row_handler == NULL) {
        CAMLreturn(Val_unit);
    }
    const value *fn_p = caml_named_value("unisonRiToProgress");
    const value *fn_b = caml_named_value("unisonRiToBytesTransferred");
    if (fn_p == NULL || fn_b == NULL) CAMLreturn(Val_unit);

    /* Finding #1: `vp` must be a registered local root across the SECOND
     * allocating callback, or a moving collection triggered by fn_b can
     * invalidate the C `value` before we read String_val(vp). CAMLlocal2 roots
     * both. `vp`/`vb` are consumed synchronously below (String_val copied by
     * the Swift trampoline before it async-dispatches; Double_val reads a
     * float immediately) while we still hold the runtime lock. This is an
     * OCaml->C->OCaml callback, so an exception in fn_p/fn_b re-raises into
     * the OCaml progress loop (no run_on_ocaml_thread strand); plain
     * caml_callback is therefore acceptable here. */
    CAMLlocal2(vp, vb);
    vp = caml_callback(*fn_p, g_ri_roots[i]);
    vb = caml_callback(*fn_b, g_ri_roots[i]);

    unison_row_state_t state = {
        .progress          = String_val(vp),  /* valid while we hold the lock; copied by the handler */
        .bytes_transferred = (int64_t)Double_val(vb),
    };
    g_reload_row_handler(i, &state);
    CAMLreturn(Val_unit);
}

/* Finding #10: sync completion now carries the final post-sync state array
 * (`!theState`, patch 0005). Marshal ONE bulk snapshot — every row's final
 * progress + details + bytes — TRANSACTIONALLY: resolve accessors first, build
 * the complete C array (any accessor raise / OOM aborts before publishing), and
 * deliver exactly once. On failure deliver an explicit `ok=false` result with
 * NO partial rows — never interpreted as "no failures". This snapshot is a
 * read-only completion result, kept entirely separate from `g_ri_roots` (the
 * scan-state publication). Swift copies all strings before this returns. */
#if UNISON_DEBUG_HOOKS
/* Finding #10 fault injection: force a specific (row, field) accessor in the
 * snapshot marshaller to behave as if it raised. field: 0=progress 1=details
 * 2=bytes. row < 0 disables. One-shot cleared after it fires. */
static atomic_int g_test_snapshot_fail_row   = -1;
static atomic_int g_test_snapshot_fail_field = -1;
void unison_bridge_test_fail_snapshot_accessor_at(int row, int field) {
    atomic_store(&g_test_snapshot_fail_field, field);
    atomic_store(&g_test_snapshot_fail_row, row);
}
static bool test_snapshot_should_fail(size_t row, int field) {
    if (atomic_load(&g_test_snapshot_fail_row) != (int)row) return false;
    if (atomic_load(&g_test_snapshot_fail_field) != field) return false;
    atomic_store(&g_test_snapshot_fail_row, -1);   /* one-shot */
    return true;
}
#endif

/* Shared snapshot marshaller (Finding #10). `row_at(i)` returns the i-th
 * stateItem as a GC-rooted `value` (the caller keeps the backing array rooted).
 * Builds the COMPLETE C snapshot before publishing; any accessor raise, OOM, or
 * injected fault frees the partial candidate and delivers exactly one
 * `ok=false` result (no partial rows). On success delivers `ok=true` exactly
 * once. `item` is CAMLlocal-rooted across the allocating accessor calls. */
static void deliver_sync_snapshot(size_t n, value (^row_at)(size_t)) {
    CAMLparam0();
    CAMLlocal1(item);

    if (g_sync_complete_handler == NULL) { CAMLreturn0; }

    const value *fn_progress = caml_named_value("unisonRiToProgress");
    const value *fn_details  = caml_named_value("unisonRiToDetails");
    const value *fn_bytes    = caml_named_value("unisonRiToBytesTransferred");
    if (fn_progress == NULL || fn_details == NULL || fn_bytes == NULL) {
        fprintf(stderr, "unison-mac: sync snapshot: a result accessor is not "
                        "registered (stale blob?) — results unavailable\n");
        g_sync_complete_handler(false, 0, NULL);
        CAMLreturn0;
    }

    unison_sync_row_t *out = NULL;
    if (n > 0) {
        out = calloc(n, sizeof(*out));
        if (out == NULL) {
            fprintf(stderr, "unison-mac: sync snapshot: OOM allocating %zu rows — "
                            "results unavailable\n", n);
            g_sync_complete_handler(false, 0, NULL);
            CAMLreturn0;
        }
    }

    bool raised = false, oom = false;
    size_t built = 0;
    for (size_t i = 0; i < n; i++) {
        item = row_at(i);   /* rooted across the allocating calls below */
        built = i + 1;
        value v;
#if UNISON_DEBUG_HOOKS
        if (test_snapshot_should_fail(i, 0)) { raised = true; break; }
#endif
        v = bridge_call1_exn(fn_progress, item, &raised); if (raised) break;
        out[i].progress = bridge_strdup(String_val(v));   if (!out[i].progress) { oom = true; break; }
#if UNISON_DEBUG_HOOKS
        if (test_snapshot_should_fail(i, 1)) { raised = true; break; }
#endif
        v = bridge_call1_exn(fn_details, item, &raised);  if (raised) break;
        out[i].details = bridge_strdup(String_val(v));    if (!out[i].details) { oom = true; break; }
#if UNISON_DEBUG_HOOKS
        if (test_snapshot_should_fail(i, 2)) { raised = true; break; }
#endif
        v = bridge_call1_exn(fn_bytes, item, &raised);    if (raised) break;
        out[i].bytes_transferred = (int64_t)Double_val(v);
    }

    if (raised || oom) {
        fprintf(stderr, "unison-mac: sync snapshot: marshalling failed (%s) — "
                        "results unavailable, no partial rows\n",
                        raised ? "accessor raised" : "allocation");
        free_sync_rows(out, built);
        g_sync_complete_handler(false, 0, NULL);
        CAMLreturn0;
    }

    g_sync_complete_handler(true, (int)n, out);
    free_sync_rows(out, n);
    CAMLreturn0;
}

CAMLprim value syncComplete(value state) {
    CAMLparam1(state);
    /* Defensive ABI guards. The typed OCaml `stateItem array` boundary already
     * guarantees a boxed (tag-0) block array, so these are unreachable in
     * practice — but keep them so a malformed value can never reach
     * Wosize_val/Field, and the size_t→int width is bounded before delivery. */
    if (!Is_block(state) || Tag_val(state) != 0) {
        fprintf(stderr, "unison-mac: syncComplete: value is not an array — unavailable\n");
        if (g_sync_complete_handler) g_sync_complete_handler(false, 0, NULL);
        CAMLreturn(Val_unit);
    }
    const size_t n = (size_t)Wosize_val(state);
    if (n > (size_t)INT32_MAX) {
        fprintf(stderr, "unison-mac: syncComplete: implausible row count %zu — unavailable\n", n);
        if (g_sync_complete_handler) g_sync_complete_handler(false, 0, NULL);
        CAMLreturn(Val_unit);
    }
    deliver_sync_snapshot(n, ^(size_t i){ return Field(state, i); });
    CAMLreturn(Val_unit);
}

#if UNISON_DEBUG_HOOKS
/* Exercise the REAL snapshot marshaller over the currently-rooted scan rows
 * (g_ri_roots) — the same accessor→strdup→deliver path syncComplete uses — so
 * a test proves the bridge boundary without a synthetic OCaml array or a live
 * sync, and without another vendored-blob change. The marshaller calls
 * `caml_callback`, so it MUST run on the OCaml runtime thread (with the lock),
 * exactly as OCaml invokes the real `syncComplete`. */
static void _ocaml_run_sync_snapshot(void *user) {
    (void)user;
    deliver_sync_snapshot((size_t)g_ri_count, ^(size_t i){ return g_ri_roots[i]; });
}
void unison_bridge_test_run_sync_snapshot(void) {
    run_on_ocaml_thread(_ocaml_run_sync_snapshot, NULL);
}
#endif

/* Preconnection from unisonInit1Complete, kept alive across credential calls.
 * `g_has_preconn` guards both presence-of-value and root-registration so we
 * can release cleanly on connection_end/cancel or another init1. */
static value g_preconn = Val_unit;
static bool  g_has_preconn = false;

static void release_preconn(void) {
    if (g_has_preconn) {
        caml_remove_generational_global_root(&g_preconn);
        g_has_preconn = false;
        g_preconn = Val_unit;
    }
}

/* OCaml passes `preconnection option`. None == Val_unit; Some v is a block
 * whose Field(_,0) is the preconnection value. */
CAMLprim value unisonInit1Complete(value v) {
    CAMLparam1(v);
    release_preconn();
    bool needs_prompt = (v != Val_unit);
    if (needs_prompt) {
        g_preconn = Field(v, 0);
        caml_register_generational_global_root(&g_preconn);
        g_has_preconn = true;
    }
    if (g_init1_complete_handler) {
        g_init1_complete_handler(needs_prompt);
    }
    CAMLreturn(Val_unit);
}

/* Unregister + free a root set (either the published globals or a temporary,
 * not-yet-published candidate). Caller holds the runtime lock. */
static void free_ri_root_set(value *roots, size_t count) {
    for (size_t i = 0; i < count; i++) {
        caml_remove_generational_global_root(&roots[i]);
    }
    free(roots);
}

static void clear_ri_roots(void) {
    free_ri_root_set(g_ri_roots, g_ri_count);
    g_ri_roots = NULL;
    g_ri_count = 0;
}

/* Build a fresh, fully-registered root set from `arr` WITHOUT touching the
 * published globals. Returns true on success (out_roots/out_count set; n==0 is a
 * valid empty set → NULL/0); false only on OOM. This is the "candidate" set that
 * emit_state_items publishes atomically only after a complete, successful
 * marshal — so a mid-marshal failure never leaves g_ri_roots pointing at a new
 * array while Swift still shows the old rows. Caller holds the runtime lock. */
static bool build_ri_root_set(value arr, value **out_roots, size_t *out_count) {
    *out_roots = NULL;
    *out_count = 0;
    const size_t n = (size_t)Wosize_val(arr);
    if (n == 0) return true;
    value *roots = calloc(n, sizeof(value));
    if (roots == NULL) {
        fprintf(stderr, "unison-mac: OOM registering %zu ri roots\n", n);
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        roots[i] = Field(arr, i);
        caml_register_generational_global_root(&roots[i]);
    }
    *out_roots = roots;
    *out_count = n;
    return true;
}

/* Publish a candidate root set as the live globals, freeing the old set. Caller
 * holds the runtime lock. emit_state_items calls this and then hands the matching
 * rows to the consumer; the roots swap here on the OCaml thread while the rows
 * reach Swift via the consumer's trampoline (which hops to the main thread). The
 * two are NOT simultaneous on the Swift side — the caller (coordinator phase gate
 * for scan; window mutation gate for Ignore) is responsible for ensuring no row
 * action runs against the new roots until the delivered rows land. */
static void install_ri_root_set(value *roots, size_t count) {
    value *old = g_ri_roots;
    size_t old_count = g_ri_count;
    g_ri_roots = roots;
    g_ri_count = count;
    free_ri_root_set(old, old_count);
}

static void free_state_items(unison_state_item_t *out, size_t count) {
    for (size_t i = 0; i < count; i++) {
        free((void *)out[i].path);
        free((void *)out[i].left);
        free((void *)out[i].right);
        free((void *)out[i].direction);
        free((void *)out[i].file_type);
        free((void *)out[i].progress);
    }
    free(out);
}

/* Free a partially- or fully-built sync-completion snapshot (Finding #10).
 * `count` is the number of rows whose strings were strdup'd (so a mid-build
 * failure frees exactly what was allocated, no more). */
static void free_sync_rows(unison_sync_row_t *rows, size_t count) {
    for (size_t i = 0; i < count; i++) {
        free((void *)rows[i].progress);
        free((void *)rows[i].details);
    }
    free(rows);
}

#if UNISON_DEBUG_HOOKS
/* Finding #10: count per-row `unison_bridge_ri_get_details` calls so a test can
 * prove the completion path makes ZERO of them. Debug-only. */
static atomic_int g_test_ri_get_details_calls = 0;
void unison_bridge_test_reset_ri_get_details_count(void) {
    atomic_store(&g_test_ri_get_details_calls, 0);
}
int unison_bridge_test_ri_get_details_count(void) {
    return atomic_load(&g_test_ri_get_details_calls);
}
#endif

#if UNISON_DEBUG_HOOKS
/* Fault injection for emit_state_items (Debug only). */
static atomic_int g_test_fail_strdup_ordinal = 0;  /* Nth bridge_strdup → NULL (0=off) */
static atomic_int g_test_strdup_count        = 0;
static atomic_int g_test_suppress_consumer   = 0;  /* treat the consumer as absent */
void unison_bridge_test_fail_strdup_at(int k) {
    atomic_store(&g_test_strdup_count, 0);
    atomic_store(&g_test_fail_strdup_ordinal, k < 0 ? 0 : k);
}
void unison_bridge_test_suppress_consumer(int on) {
    atomic_store(&g_test_suppress_consumer, on ? 1 : 0);
}
static bool test_should_fail_strdup(void) {
    int tgt = atomic_load(&g_test_fail_strdup_ordinal);
    if (tgt <= 0) return false;
    int c = atomic_fetch_add(&g_test_strdup_count, 1) + 1;
    if (c == tgt) { atomic_store(&g_test_fail_strdup_ordinal, 0); return true; }
    return false;
}
#endif

/* strdup with Debug-only failure injection, so the emit rollback path is
 * testable without perturbing production (in Release this is a plain strdup). */
static char *bridge_strdup(const char *s) {
#if UNISON_DEBUG_HOOKS
    if (test_should_fail_strdup()) return NULL;
#endif
    return strdup(s);
}

/* Publish a fresh state-item set to `consumer` and swap in the matching per-row
 * roots — TRANSACTIONALLY. Reachable from unisonInit2Complete (consumer =
 * g_init2_complete_handler) and _ocaml_ignore (consumer =
 * g_ignore_complete_handler). Caller holds the OCaml runtime lock.
 *
 * The published g_ri_roots and the rows delivered to `consumer` must change
 * together or not at all. So this: (1) requires a valid consumer up front — with
 * no consumer to deliver rows to, installing new roots would strand the old
 * Swift rows against new OCaml roots, so it fails without touching the globals;
 * (2) resolves every accessor before dereferencing any; (3) builds a *candidate*
 * root set and marshals the COMPLETE output, checking every allocation; (4) only
 * on full success swaps the globals to the candidate and delivers the rows. On
 * ANY failure — missing consumer, missing accessor, OOM, a failed strdup, or an
 * accessor raising — the candidate roots and partial output are freed and the
 * previously-published g_ri_roots (and the old Swift rows) are left intact.
 *
 * NOTE: the roots are installed on the OCaml thread and the rows are then handed
 * to `consumer`, whose Swift trampoline copies them and hops to the main thread.
 * The swap-then-deliver is atomic on the OCaml side; the caller is responsible
 * for ensuring no row action runs against the new roots until the delivered rows
 * land (init2 gates via the coordinator's .scanning→.ready transition; Ignore
 * gates the window until its dedicated completion is applied). */
static bool emit_state_items(value arr_in, unison_init2_complete_handler_t consumer) {
    CAMLparam1(arr_in);
    CAMLlocal1(item);

    /* 1. A valid completion consumer is required BEFORE anything is installed. */
    bool have_consumer = (consumer != NULL);
#if UNISON_DEBUG_HOOKS
    if (atomic_load(&g_test_suppress_consumer)) have_consumer = false;
#endif
    if (!have_consumer) {
        fprintf(stderr, "unison-mac: emit_state_items: no completion consumer — "
                        "not publishing (old rows/roots preserved)\n");
        CAMLreturnT(bool, false);
    }

    /* 2. Resolve EVERY accessor before dereferencing any. A missing one is a
     *    controlled failure (stale blob) — never a NULL-function call, and the
     *    published globals stay untouched. */
    const value *fn_path      = caml_named_value("unisonRiToPath");
    const value *fn_left      = caml_named_value("unisonRiToLeft");
    const value *fn_right     = caml_named_value("unisonRiToRight");
    const value *fn_direction = caml_named_value("unisonRiToDirection");
    const value *fn_size      = caml_named_value("unisonRiToFileSize");
    const value *fn_type      = caml_named_value("unisonRiToFileType");
    const value *fn_progress  = caml_named_value("unisonRiToProgress");
    const value *fn_bytes     = caml_named_value("unisonRiToBytesTransferred");
    const value *fn_changed   = caml_named_value("changedFromDefault");
    if (fn_path == NULL || fn_left == NULL || fn_right == NULL ||
        fn_direction == NULL || fn_size == NULL || fn_type == NULL ||
        fn_progress == NULL || fn_bytes == NULL || fn_changed == NULL) {
        fprintf(stderr, "unison-mac: emit_state_items: a state accessor is not "
                        "registered (stale blob?) — not publishing\n");
        CAMLreturnT(bool, false);
    }

    const size_t n = (size_t)Wosize_val(arr_in);

    /* 3. Build the candidate root set (NOT yet published). */
    value *cand_roots = NULL;
    size_t cand_count = 0;
    if (!build_ri_root_set(arr_in, &cand_roots, &cand_count)) {
        CAMLreturnT(bool, false);   /* OOM — globals untouched */
    }

    /* 4. Marshal the COMPLETE C output. Any accessor raise or failed strdup
     *    aborts before publication; `item` is CAMLlocal-rooted so it survives
     *    the allocating accessor calls. */
    unison_state_item_t *out = NULL;
    if (n > 0) {
        out = calloc(n, sizeof(*out));
        if (out == NULL) {
            fprintf(stderr, "unison-mac: OOM allocating %zu state items\n", n);
            free_ri_root_set(cand_roots, cand_count);
            CAMLreturnT(bool, false);
        }
    }

    bool raised = false, oom = false;
    size_t built = 0;
    for (size_t i = 0; i < n; i++) {
        item = Field(arr_in, i);
        built = i + 1;
        value v;
        v = bridge_call1_exn(fn_path, item, &raised);      if (raised) break;
        out[i].path = bridge_strdup(String_val(v));        if (!out[i].path) { oom = true; break; }
        v = bridge_call1_exn(fn_left, item, &raised);      if (raised) break;
        out[i].left = bridge_strdup(String_val(v));        if (!out[i].left) { oom = true; break; }
        v = bridge_call1_exn(fn_right, item, &raised);     if (raised) break;
        out[i].right = bridge_strdup(String_val(v));       if (!out[i].right) { oom = true; break; }
        v = bridge_call1_exn(fn_direction, item, &raised); if (raised) break;
        out[i].direction = bridge_strdup(String_val(v));   if (!out[i].direction) { oom = true; break; }
        v = bridge_call1_exn(fn_size, item, &raised);      if (raised) break;
        out[i].size_bytes = (int64_t)Double_val(v);
        v = bridge_call1_exn(fn_type, item, &raised);      if (raised) break;
        out[i].file_type = bridge_strdup(String_val(v));   if (!out[i].file_type) { oom = true; break; }
        v = bridge_call1_exn(fn_progress, item, &raised);  if (raised) break;
        out[i].progress = bridge_strdup(String_val(v));    if (!out[i].progress) { oom = true; break; }
        v = bridge_call1_exn(fn_bytes, item, &raised);     if (raised) break;
        out[i].bytes_transferred = (int64_t)Double_val(v);
        v = bridge_call1_exn(fn_changed, item, &raised);   if (raised) break;
        out[i].changed_from_default = (Bool_val(v) == 1);
    }

    if (raised || oom) {
        /* Roll back: drop the candidate roots and the partial output; the old
         * published g_ri_roots and Swift's old rows both stay untouched. */
        if (oom) fprintf(stderr, "unison-mac: emit_state_items: allocation failed — "
                                 "preserving previous publication\n");
        free_state_items(out, built);
        free_ri_root_set(cand_roots, cand_count);
        CAMLreturnT(bool, false);
    }

    /* 5. Success — publish: swap the globals to the candidate set, then deliver
     *    the matching rows to the consumer. */
    install_ri_root_set(cand_roots, cand_count);
    /* Synchronous: the Swift trampoline must copy strings before returning. */
    consumer(out, n);
    free_state_items(out, n);
    CAMLreturnT(bool, true);
}

CAMLprim value unisonInit2Complete(value arr) {
    CAMLparam1(arr);
    /* This is the asynchronous scan-completion path (OCaml's doInOtherThread
     * scan worker calls it). If emit_state_items fails — a missing accessor, an
     * accessor raising, or OOM — the state was NOT published (Blocker 1) and the
     * normal completion handler did NOT fire, so the coordinator would otherwise
     * be stranded in .scanning forever. Deliver a terminal scan-failure instead
     * (Blocker 2): the token-bound handler routes it to
     * operationFailed(engineIsQuiescent:false) → restart-required. Never merely
     * log and return — every asynchronous scan must produce either completion or
     * a terminal failure. */
    if (!emit_state_items(arr, g_init2_complete_handler)) {
        fprintf(stderr, "unison-mac: unisonInit2Complete: state emission failed "
                        "— delivering terminal scan failure\n");
        if (g_scan_failed_handler != NULL) {
            g_scan_failed_handler();
        } else {
            /* No handler installed (should not happen in the running app): the
             * scan cannot be reported terminal. Abort loudly rather than leave a
             * silently-wedged coordinator — this is a wiring bug, not a runtime
             * condition. */
            fprintf(stderr, "unison-mac: FATAL: no scan-failed handler installed; "
                            "cannot report terminal scan failure\n");
            abort();
        }
    }
    CAMLreturn(Val_unit);
}

/* Called from OCaml when a diff completes successfully. `title` is the
 * file's relative path (used for window titling); `text` is the diff
 * output produced by Unison's configured `diff` pref (default
 * `diff -u`). Both arrive as OCaml-owned strings; we hand pointers to
 * the Swift trampoline, which copies before async-dispatching to the
 * main queue. */
CAMLprim value displayDiff(value title, value text) {
    CAMLparam2(title, text);
    if (g_diff_handler) {
        g_diff_handler(String_val(title), String_val(text));
    } else {
        // Unhandled diff — log so we can spot wiring regressions in dev.
        fprintf(stderr, "unison-mac: displayDiff fired with no handler installed\n");
    }
    CAMLreturn(Val_unit);
}

/* =====================================================================
 * Startup
 *
 * The OCaml thread runs caml_startup, signals init complete, then calls
 * callbackThreadCreate (OCaml side) which spawns N worker threads, each
 * looping in bridgeThreadWait. The OCaml startup thread itself joins on
 * one of the workers, parking indefinitely — that's how we keep the
 * OCaml runtime alive while AppKit owns the C/Swift main thread.
 * ===================================================================== */

static pthread_mutex_t init_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  init_cond  = PTHREAD_COND_INITIALIZER;
static bool g_ocaml_ready = false;
static char **g_saved_argv = NULL;

static void *ocaml_thread_main(void *arg) {
    (void)arg;
    caml_startup(g_saved_argv);

    /* Signal that the OCaml runtime + Callback.register table are ready. */
    pthread_mutex_lock(&init_mutex);
    g_ocaml_ready = true;
    pthread_cond_signal(&init_cond);
    pthread_mutex_unlock(&init_mutex);

    /* Park: callbackThreadCreate spawns workers + joins; never returns. */
    const value *f = caml_named_value("callbackThreadCreate");
    if (f == NULL) {
        fprintf(stderr, "unison-mac: callbackThreadCreate not registered\n");
        abort();
    }
    (void)caml_callback_exn(*f, Val_unit);
    return NULL; /* unreachable */
}

static bool g_started = false;

void unison_bridge_startup(int argc, char *argv[]) {
    if (g_started) return;
    g_started = true;
    (void)argc;

    g_saved_argv = argv;

    pthread_t tid;
    int rc = pthread_create(&tid, NULL, ocaml_thread_main, NULL);
    if (rc != 0) {
        fprintf(stderr, "unison-mac: pthread_create failed (%d)\n", rc);
        abort();
    }
    pthread_detach(tid);

    pthread_mutex_lock(&init_mutex);
    while (!g_ocaml_ready) {
        pthread_cond_wait(&init_cond, &init_mutex);
    }
    pthread_mutex_unlock(&init_mutex);

    /* Workers may not be parked yet — callbackThreadCreate runs after the
     * ready signal. That's fine: run_on_ocaml_thread queues into g_pending
     * unconditionally, and workers check the predicate before waiting, so
     * a request issued early just sits in the slot until the first worker
     * picks it up. */
}

/* =====================================================================
 * Clean shutdown
 *
 * Called from AppDelegate's applicationWillTerminate. The OCaml runtime
 * is still alive at this point — we use the existing dispatch
 * infrastructure to release our generational global roots on the OCaml
 * thread so any leak-checker (`leaks(1)`, ASan) doesn't flag them.
 *
 * Mostly cosmetic since the process is about to die and macOS will tear
 * the runtime down anyway. The hygiene matters mainly for
 * release-gate `make leaks` runs, where unreleased roots would
 * otherwise show up as "leaked OCaml values".
 *
 * Safe to call multiple times; the per-collection clear helpers
 * (`release_preconn`, `clear_ri_roots`) are idempotent. NOT safe to call
 * before startup — would deadlock waiting for the OCaml worker.
 *
 * Because this runs on the main thread from applicationWillTerminate, it
 * is TIME-BOXED: the root release is dispatched to a helper thread and we
 * wait at most SHUTDOWN_TIMEOUT_SEC for it. If the bridge is wedged (an
 * OCaml worker stuck mid-call), quit proceeds anyway instead of hanging
 * the app. Losing the cosmetic root release in that case is harmless: the
 * process is exiting and macOS reclaims everything.
 * ===================================================================== */

/* === Transport-child (ssh) registry + pure-C shutdown reaper ===
 *
 * The embedded engine spawns one ssh child per remote connection
 * (remote.ml). On NORMAL OCaml termination its at_exit `end_ssh` reaps it, but
 * the AppKit host can terminate this process WITHOUT running OCaml at_exit
 * (unison_bridge_shutdown is a bounded C helper that does not drive at_exit),
 * and a sync wedged on a frozen remote is blocked on the transport socket, so
 * closing fds does not make the child exit. It then survives as an orphan.
 *
 * Contract (needs NO OCaml/Lwt progress at shutdown):
 *   - track(pid): OCaml records the exact pid right after spawn (deduplicated).
 *   - retire(pid): OCaml's teardown, BEFORE it waitpid/close_sessions the
 *     child, calls this. It SIGKILLs the exact pid AND removes it from the
 *     registry ATOMICALLY under the mutex, and only while the pid is still
 *     registered (hence still un-reaped and reserved by the OS). SIGKILL is
 *     ISSUED before the pid is removed: the child is thereafter irrevocably
 *     terminating (SIGKILL cannot be caught/blocked), though it may not have
 *     exited the instant kill() returns; its pid stays reserved by the OS until
 *     the following waitpid, so a reused pid is never signalled. A removed pid
 *     is thus always one that has ALREADY been signalled and is dying -- never a
 *     live child that a racing shutdown could miss (a pid is signalled before
 *     it is removed).
 *   - reap(): the pure-C shutdown pass SIGKILLs every still-registered pid.
 *
 * Every kill(2) is issued WHILE HOLDING the mutex, before the pid is removed.
 * Because OCaml can only reap a child after retire() removed it (under the same
 * mutex), no concurrent waitpid can reap+free a pid between our decision to
 * signal it and the signal itself -> no PID-reuse race. No process
 * enumeration; exact registered pids only. See docs/ssh-reaper-design.md. */
#define MAX_TRANSPORT_CHILDREN 64
static pthread_mutex_t g_child_mutex = PTHREAD_MUTEX_INITIALIZER;
static pid_t g_children[MAX_TRANSPORT_CHILDREN];
static int   g_child_count = 0;
static bool  g_children_closing = false;

/* Caller must hold g_child_mutex. */
static bool child_present_locked(pid_t pid) {
    for (int i = 0; i < g_child_count; i++)
        if (g_children[i] == pid) return true;
    return false;
}

/* Register a just-spawned transport child by exact pid. Deduplicated: a second
 * track of the same pid is a no-op, so one retire fully removes it. If shutdown
 * has already begun, or the registry is full, the pid cannot be tracked, so it
 * is SIGKILLed at once (under the mutex) -- a spawn racing shutdown must not
 * escape, and an untrackable child must not be left running. */
void unison_bridge_track_child(pid_t pid) {
    if (pid <= 0) return;
    pthread_mutex_lock(&g_child_mutex);
    if (g_children_closing) {
        kill(pid, SIGKILL);
    } else if (child_present_locked(pid)) {
        /* dedup: already tracked */
    } else if (g_child_count < MAX_TRANSPORT_CHILDREN) {
        g_children[g_child_count++] = pid;
    } else {
        kill(pid, SIGKILL);
    }
    pthread_mutex_unlock(&g_child_mutex);
}

/* Retire a transport child: SIGKILL the exact pid and remove ALL its registry
 * entries, atomically under the mutex, ONLY if it is still registered (hence
 * still reserved). Idempotent: a second retire of an already-retired pid finds
 * nothing and never signals (so it can't hit a reused pid). The caller then
 * waitpid/close_sessions the killed child. */
void unison_bridge_retire_child(pid_t pid) {
    pthread_mutex_lock(&g_child_mutex);
    if (child_present_locked(pid)) {
        kill(pid, SIGKILL);
        int w = 0;
        for (int r = 0; r < g_child_count; r++)
            if (g_children[r] != pid) g_children[w++] = g_children[r];
        g_child_count = w;
    }
    pthread_mutex_unlock(&g_child_mutex);
}

/* True if `pid` no longer names a live, non-zombie process: it is gone (sysctl
 * reports ESRCH / no record) or a zombie awaiting reap (p_stat == SZOMB). Uses
 * sysctl rather than kill(pid, 0) precisely because a just-exited-but-unreaped
 * child is a zombie that kill(pid, 0) still reports as alive — the exact state
 * a login-grace-timed-out ssh child is in while OCaml's prompt reader has not
 * yet waitpid'd it. Never reaps. On any unexpected sysctl error other than
 * "no such process", errs conservative and reports NOT terminated, so we never
 * fabricate terminal evidence. Caller must hold g_child_mutex. */
static bool pid_terminated_locked(pid_t pid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) {
        return errno == ESRCH || errno == ENOENT;   /* gone */
    }
    if (len == 0) return true;                       /* no record → gone */
    return kp.kp_proc.p_stat == SZOMB;               /* zombie → terminated */
}

/* Terminal evidence for the connect prompt loop (issue #35): the transport
 * (ssh) child has gone away. Returns 1 iff at least one child is tracked AND
 * every tracked child has terminated (gone or zombie); 0 if any tracked child
 * is still live, or if none is tracked (no evidence either way). "All" rather
 * than "any" so a transient multi-child state is never misjudged as fatal;
 * during a connect there is exactly one transport child, so all == any there.
 * Never reaps. */
int unison_bridge_transport_child_terminated(void) {
    pthread_mutex_lock(&g_child_mutex);
    int count = g_child_count;
    bool all_terminated = (count > 0);
    for (int i = 0; i < count; i++) {
        if (!pid_terminated_locked(g_children[i])) { all_terminated = false; break; }
    }
    pthread_mutex_unlock(&g_child_mutex);
    return all_terminated ? 1 : 0;
}

#if UNISON_DEBUG_HOOKS
/* === Phase 0 scan-interruption spike (issue #24 follow-up) ===
 * Debug-only harness primitives. See docs/scan-interruption-design.md §6/§8.
 * The production app never calls these; Release omits the definitions. */

/* Read pid's start identity via sysctl. Returns 1 present (fills stat +
 * starttime), 0 gone (ESRCH/ENOENT/no record), -1 other error (inconclusive).
 * No mutex needed: a read-only sysctl on a pid we hold reserved. */
static int proc_identity_debug(pid_t pid, int *out_stat,
                               int64_t *out_sec, int32_t *out_usec) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0)
        return (errno == ESRCH || errno == ENOENT) ? 0 : -1;
    if (len == 0) return 0;
    if (out_stat) *out_stat = kp.kp_proc.p_stat;
    if (out_sec)  *out_sec  = (int64_t)kp.kp_proc.p_starttime.tv_sec;
    if (out_usec) *out_usec = (int32_t)kp.kp_proc.p_starttime.tv_usec;
    return 1;
}

/* SIGKILL the single tracked transport child, capturing its identity first.
 * Refuses unless exactly one child is tracked and still live. Leaves the pid
 * REGISTERED and does NOT waitpid — OCaml stays the owner of retirement/reap
 * (design §6); the killed-but-unremoved pid cannot be reused before OCaml
 * reaps it, so the registry's pid-reuse guarantee is preserved. */
unison_scan_signal_result_t unison_bridge_signal_scan_transport(void) {
    unison_scan_signal_result_t r = { UNISON_SIGNAL_NO_CHILD, 0, 0, 0 };
    pthread_mutex_lock(&g_child_mutex);
    if (g_child_count == 0) {
        r.outcome = UNISON_SIGNAL_NO_CHILD;
    } else if (g_child_count > 1) {
        r.outcome = UNISON_SIGNAL_MULTIPLE_CHILDREN;   /* never guess which */
    } else {
        pid_t pid = g_children[0];
        int stat = 0; int64_t sec = 0; int32_t usec = 0;
        int present = proc_identity_debug(pid, &stat, &sec, &usec);
        r.pid = (int32_t)pid; r.start_sec = sec; r.start_usec = usec;
        if (present <= 0 || stat == SZOMB) {
            r.outcome = UNISON_SIGNAL_ALREADY_DEAD;    /* nothing live to kill */
        } else if (kill(pid, SIGKILL) == 0) {
            r.outcome = UNISON_SIGNAL_SIGNALLED;
        } else {
            r.outcome = UNISON_SIGNAL_FAILED;
        }
    }
    pthread_mutex_unlock(&g_child_mutex);
    return r;
}

/* Classify whether the captured identity was reaped. Poll this over a bounded
 * grace period (design §8) rather than trusting one snapshot. */
unison_reap_state_t unison_bridge_classify_reap(int32_t pid, int64_t start_sec,
                                                int32_t start_usec) {
    int stat = 0; int64_t sec = 0; int32_t usec = 0;
    int present = proc_identity_debug((pid_t)pid, &stat, &sec, &usec);
    if (present < 0) return UNISON_REAP_UNKNOWN;
    if (present == 0) return UNISON_REAP_ABSENT;                 /* reaped */
    if (sec != start_sec || usec != start_usec)
        return UNISON_REAP_REUSED;                              /* pid recycled */
    if (stat == SZOMB) return UNISON_REAP_ZOMBIE;               /* original, unreaped */
    return UNISON_REAP_LIVE;                                    /* original, running */
}

bool unison_bridge_capture_identity(int32_t pid, int64_t *out_sec, int32_t *out_usec) {
    int stat = 0;
    return proc_identity_debug((pid_t)pid, &stat, out_sec, out_usec) == 1;
}
#endif /* UNISON_DEBUG_HOOKS */

/* Pure-C shutdown reaper. Enters the `closing` state and SIGKILLs every
 * still-registered pid WHILE HOLDING the mutex (so no concurrent retire+waitpid
 * can free a pid out from under a signal), then clears the set and unlocks.
 * Idempotent (a second call finds an empty set). SIGKILL, not SIGTERM: a
 * stopped/wedged child may defer or ignore SIGTERM. Does NOT waitpid -- the
 * process is exiting, so init reaps the transient zombies; this keeps shutdown
 * non-blocking and avoids a double-reap race. Returns the number of pids
 * signaled. */
int unison_bridge_reap_transport_children(void) {
    int n;
    pthread_mutex_lock(&g_child_mutex);
    g_children_closing = true;
    n = g_child_count;
    for (int i = 0; i < n; i++) kill(g_children[i], SIGKILL);
    g_child_count = 0;
    pthread_mutex_unlock(&g_child_mutex);
    return n;
}

/* OCaml externals (value ABI) delegating to the plain-C registry above. These
 * are the symbols uimacbridge.ml's `external` declarations resolve to when the
 * blob is linked into this app. */
CAMLprim value unison_bridge_register_child(value pid_v) {
    CAMLparam1(pid_v);
    unison_bridge_track_child((pid_t)Long_val(pid_v));
    CAMLreturn(Val_unit);
}
CAMLprim value unison_bridge_retire_child_ml(value pid_v) {
    CAMLparam1(pid_v);
    unison_bridge_retire_child((pid_t)Long_val(pid_v));
    CAMLreturn(Val_unit);
}

#if UNISON_DEBUG_HOOKS
/* Test-only: clear the registry + closing state so a test can run multiple
 * reap cycles from a known baseline. Defined only in Debug (UNISON_DEBUG_HOOKS,
 * set by project.yml's Debug config — we can't use DEBUG, which would pull in
 * OCaml's debug-assert runtime). Absent from Release. */
void unison_bridge_reset_child_registry_for_test(void) {
    pthread_mutex_lock(&g_child_mutex);
    g_child_count = 0;
    g_children_closing = false;
    pthread_mutex_unlock(&g_child_mutex);
}

/* Test-only (Blocker 3): install/clear a dummy preconnection so the credential
 * prompt/reply entry points pass their g_has_preconn guard and reach the exn
 * wrapper. Intended for pairing with forced-raise ONLY — the wrapper
 * short-circuits before the real OCaml call, so the Val_unit stand-in is never
 * dereferenced. Registered/released like a real preconn (via release_preconn) so
 * shutdown stays consistent. Runs on the OCaml thread for lock safety. */
static void _ocaml_set_fake_preconn(void *user) {
    bool on = *(bool *)user;
    if (on) {
        if (!g_has_preconn) {
            g_preconn = Val_unit;
            caml_register_generational_global_root(&g_preconn);
            g_has_preconn = true;
        }
    } else {
        release_preconn();
    }
}
void unison_bridge_test_set_fake_preconn(bool on) {
    run_on_ocaml_thread(_ocaml_set_fake_preconn, &on);
}

/* Test-only (Blocker 1): the currently-published per-row root count. Lets a test
 * prove that a failed state publication left the OLD roots intact (rollback). */
int unison_bridge_test_ri_count(void) {
    return (int)g_ri_count;
}

/* Finding #1 GC-rooting probe. Faithfully reproduces reloadTable's rooting
 * pattern against the REAL registered progress/bytes callbacks on a live
 * g_ri_roots[row], but injects the exact adversarial condition reloadTable
 * must survive: a moving collection between obtaining the progress `value`
 * and reading its String_val. `vp` is rooted via CAMLlocal2 (as in the
 * production code), so caml_minor_collection relocates it and String_val(vp)
 * stays valid. If the rooting were removed, the minor GC would move the
 * freshly-allocated progress string and this would read freed memory
 * (garbage or a crash) — which is exactly what the test asserts against.
 * Debug-only; never linked into Release. Caller supplies the output buffer. */
struct reload_gc_io { int row; char buf[1024]; bool ok; };

static void _ocaml_test_reload_under_gc(void *user) {
    CAMLparam0();
    CAMLlocal2(vp, vb);
    struct reload_gc_io *io = user;
    io->ok = false;
    io->buf[0] = '\0';
    if (io->row < 0 || (size_t)io->row >= g_ri_count) CAMLreturn0;
    const value *fn_p = caml_named_value("unisonRiToProgress");
    const value *fn_b = caml_named_value("unisonRiToBytesTransferred");
    if (fn_p == NULL || fn_b == NULL) CAMLreturn0;

    vp = caml_callback(*fn_p, g_ri_roots[io->row]);  /* progress: freshly allocated */
    vb = caml_callback(*fn_b, g_ri_roots[io->row]);  /* bytes: allocates a boxed float */
    (void)vb;
    /* Churn the minor heap, then force a minor collection so any minor-heap
     * survivor (including vp) is relocated to the major heap right now. */
    for (int k = 0; k < 64; k++) { (void)caml_alloc_string(256); }
    caml_minor_collection();

    strncpy(io->buf, String_val(vp), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
    io->ok = true;
    CAMLreturn0;
}

bool unison_bridge_test_reload_under_gc(int row, char *out, size_t outlen) {
    struct reload_gc_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_test_reload_under_gc, &io);
    if (out != NULL && outlen > 0) {
        strncpy(out, io.buf, outlen - 1);
        out[outlen - 1] = '\0';
    }
    return io.ok;
}

/* Stronger, self-contained rooting proof. Unlike the reload probe (which reads
 * whatever the real progress accessor returns — often "" or an interned/old
 * string, so it can't prove the value was young or actually moved), this builds
 * a KNOWN, freshly-allocated string (guaranteed young), roots it with CAMLlocal1
 * exactly as reloadTable roots its accessor result, records the block address,
 * churns + forces a minor collection to evacuate the young heap, and then checks
 * both that the block's address CHANGED (proving it was young and relocated) and
 * that String_val still yields the original bytes (proving the root tracked the
 * move). *out_moved reports the relocation; the returned string must equal the
 * input. Debug-only. */
struct root_gc_io {
    char in[256];
    char out[1024];
    bool moved;
    bool ok;
};

static void _ocaml_test_root_survives_gc(void *user) {
    CAMLparam0();
    CAMLlocal1(v);
    struct root_gc_io *io = user;
    io->ok = false;
    io->out[0] = '\0';
    io->moved = false;

    v = caml_copy_string(io->in);           /* fresh YOUNG block, known content */
    uintptr_t before = (uintptr_t)v;
    /* Fill the minor heap so the forced collection actually evacuates `v` to the
     * major heap (relocating it); a CAMLlocal1 root is updated to the new
     * address, an unrooted C value would be left dangling. */
    for (int k = 0; k < 256; k++) { (void)caml_alloc_string(512); }
    caml_minor_collection();
    uintptr_t after = (uintptr_t)v;
    io->moved = (before != after);

    strncpy(io->out, String_val(v), sizeof(io->out) - 1);
    io->out[sizeof(io->out) - 1] = '\0';
    io->ok = true;
    CAMLreturn0;
}

bool unison_bridge_test_root_survives_gc(const char *in, char *out, size_t outlen,
                                         bool *out_moved) {
    struct root_gc_io io;
    memset(&io, 0, sizeof(io));
    strncpy(io.in, in ? in : "", sizeof(io.in) - 1);
    run_on_ocaml_thread(_ocaml_test_root_survives_gc, &io);
    if (out != NULL && outlen > 0) {
        strncpy(out, io.out, outlen - 1);
        out[outlen - 1] = '\0';
    }
    if (out_moved != NULL) *out_moved = io.moved;
    return io.ok;
}
#endif

static void _ocaml_shutdown(void *user) {
    (void)user;
    release_preconn();
    clear_ri_roots();
}

#define SHUTDOWN_TIMEOUT_SEC 2

struct shutdown_ctl {
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
    bool            done;
};

static void *_shutdown_thread(void *arg) {
    struct shutdown_ctl *ctl = arg;
    run_on_ocaml_thread(_ocaml_shutdown, NULL);
    pthread_mutex_lock(&ctl->mutex);
    ctl->done = true;
    pthread_cond_signal(&ctl->cond);
    pthread_mutex_unlock(&ctl->mutex);
    return NULL;
}

void unison_bridge_shutdown(void) {
    /* FIRST, pure C, independent of the OCaml runtime: SIGKILL any transport
     * ssh children still registered (e.g. a wedged sync's child that no OCaml
     * reap will ever run for). This must precede the bounded root-release
     * helper below, which depends on OCaml making progress and can time out. */
    unison_bridge_reap_transport_children();
    if (!g_started) return;

    /* Heap-allocated so its lifetime can outlive this frame if we time out
     * (the helper thread may still touch it). Freed only on the clean path,
     * where the helper is provably done with it; deliberately leaked on the
     * timeout path — a ~100-byte one-time leak at process exit, not a real
     * leak the `make leaks` gate would ever hit on a healthy bridge. */
    struct shutdown_ctl *ctl = calloc(1, sizeof(*ctl));
    if (ctl == NULL) return;
    pthread_mutex_init(&ctl->mutex, NULL);
    pthread_cond_init(&ctl->cond, NULL);

    pthread_t tid;
    if (pthread_create(&tid, NULL, _shutdown_thread, ctl) != 0) {
        /* Best-effort: skip the cosmetic root release rather than block. */
        return;
    }
    pthread_detach(tid);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += SHUTDOWN_TIMEOUT_SEC;

    pthread_mutex_lock(&ctl->mutex);
    int rc = 0;
    while (!ctl->done && rc != ETIMEDOUT) {
        rc = pthread_cond_timedwait(&ctl->cond, &ctl->mutex, &deadline);
    }
    bool done = ctl->done;
    pthread_mutex_unlock(&ctl->mutex);

    if (done) {
        /* Helper has passed its unlock and touches ctl no more; safe to reap. */
        pthread_cond_destroy(&ctl->cond);
        pthread_mutex_destroy(&ctl->mutex);
        free(ctl);
    } else {
        fprintf(stderr,
                "unison-mac: bridge shutdown timed out after %ds; "
                "exiting without cosmetic root release\n",
                SHUTDOWN_TIMEOUT_SEC);
        /* Intentionally leak ctl: the wedged helper may still reference it. */
    }
}

/* =====================================================================
 * Public C -> OCaml entry points
 *
 * Each follows the same shape:
 *   - args/result struct
 *   - private fn that runs ON the OCaml thread (has runtime lock)
 *   - public wrapper that builds the struct and calls run_on_ocaml_thread
 * ===================================================================== */

/* === Exception-safe callback wrappers (Finding #6) ===
 *
 * Every Swift->OCaml entry point dispatches its OCaml work onto the single
 * worker via run_on_ocaml_thread, which sets req->done ONLY after req->fn
 * returns. A plain caml_callback on an uncaught OCaml exception does not
 * return — it aborts the process (or, if unwound, strands the parked caller
 * and loses the worker). These wrappers use the caml_callback*_exn family:
 * on a raise they RETURN an exception-encoded result (so req->fn returns
 * normally, req->done is set, and the worker stays usable) and set *raised so
 * the caller converts the failure into an explicit bridge status instead of
 * dereferencing a non-result. Caller holds the runtime lock.
 *
 * connection_end / connection_cancel are deliberately NOT routed through here
 * — their existing, separately-verified _exn + release_preconn cleanup is left
 * untouched. */
#if UNISON_DEBUG_HOOKS
/* Two independent, atomic fault-injection modes (Debug-only). Atomics because
 * the concurrent liveness test arms `force_raise` from one thread while callers
 * consume it on the worker thread.
 *   1. force_raise (count): the next N wrapper calls are forged as raised.
 *      Used by concurrency/stress tests where the exact consuming call doesn't
 *      matter.
 *   2. ordinal: the Kth wrapper call after arming is forged as raised (1-based),
 *      counting only wrapper (caml_callback) invocations, not caml_named_value
 *      lookups. Lets a test fail a SPECIFIC callback stage — e.g. the direction
 *      readback but not the setter, or the 3rd accessor of the 5th emitted row —
 *      so post-first-mutation failures are exercisable. Single-armed (auto-
 *      disarms on fire). Intended for single-threaded deterministic tests. */
static atomic_int g_test_force_raise    = 0;
static atomic_int g_test_ordinal_target = 0;   /* 0 = disabled */
static atomic_int g_test_ordinal_count  = 0;   /* wrapper calls since arm */

void unison_bridge_test_force_next_callbacks_raise(int n) {
    atomic_store(&g_test_force_raise, n < 0 ? 0 : n);
}
int unison_bridge_test_pending_forced_raises(void) {
    return atomic_load(&g_test_force_raise);
}
void unison_bridge_test_force_raise_at_ordinal(int k) {
    atomic_store(&g_test_ordinal_count, 0);
    atomic_store(&g_test_ordinal_target, k < 0 ? 0 : k);
}

/* Returns true (once) if the current wrapper call should be forged as raised. */
static bool test_should_force_raise(void) {
    int tgt = atomic_load(&g_test_ordinal_target);
    if (tgt > 0) {
        int c = atomic_fetch_add(&g_test_ordinal_count, 1) + 1;
        if (c == tgt) { atomic_store(&g_test_ordinal_target, 0); return true; }
    }
    int n = atomic_load(&g_test_force_raise);
    while (n > 0) {
        if (atomic_compare_exchange_weak(&g_test_force_raise, &n, n - 1)) return true;
    }
    return false;
}
#endif

static value bridge_call1_exn(const value *fn, value arg, bool *raised) {
#if UNISON_DEBUG_HOOKS
    if (test_should_force_raise()) { *raised = true; return Val_unit; }
#endif
    value r = caml_callback_exn(*fn, arg);
    *raised = Is_exception_result(r);
    return r;
}

static value bridge_call2_exn(const value *fn, value a, value b, bool *raised) {
#if UNISON_DEBUG_HOOKS
    if (test_should_force_raise()) { *raised = true; return Val_unit; }
#endif
    value r = caml_callback2_exn(*fn, a, b);
    *raised = Is_exception_result(r);
    return r;
}

struct get_version_io {
    char buf[256];
};

static void _ocaml_get_version(void *user) {
    struct get_version_io *io = user;
    io->buf[0] = '\0';
    const value *closure = caml_named_value("unisonGetVersion");
    if (closure == NULL) return;
    bool raised = false;
    value result = bridge_call1_exn(closure, Val_unit, &raised);
    if (raised) return;   /* empty buf → NULL to the caller (not misread as data) */
    strncpy(io->buf, String_val(result), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
}

const char *unison_bridge_get_version(void) {
    /* _Thread_local so concurrent callers each get their own return buffer
     * (the worker writes through &io on the OCaml thread, but run_on_ocaml_thread
     * blocks THIS thread until it completes, so the storage this caller reads
     * is its own). Matches the ri_* helpers below. */
    static _Thread_local struct get_version_io io;
    run_on_ocaml_thread(_ocaml_get_version, &io);
    return io.buf[0] ? io.buf : NULL;
}

struct unison_directory_io {
    char buf[4096];
};

static void _ocaml_unison_directory(void *user) {
    struct unison_directory_io *io = user;
    io->buf[0] = '\0';
    const value *closure = caml_named_value("unisonDirectory");
    if (closure == NULL) return;
    bool raised = false;
    value result = bridge_call1_exn(closure, Val_unit, &raised);
    if (raised) return;
    strncpy(io->buf, String_val(result), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
}

const char *unison_bridge_unison_directory(void) {
    /* _Thread_local: per-caller return storage (see unison_bridge_get_version). */
    static _Thread_local struct unison_directory_io io;
    run_on_ocaml_thread(_ocaml_unison_directory, &io);
    return io.buf[0] ? io.buf : NULL;
}

/* Shared {int status} shape for the status-returning phase entry points. */
struct status_io { int status; };

static void _ocaml_init0(void *user) {
    struct status_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;
    const value *closure = caml_named_value("unisonInit0");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit0 not registered\n");
        return;   /* ERR_MISSING — caller must abort launch */
    }
    bool raised = false;
    (void)bridge_call1_exn(closure, Val_unit, &raised);
    if (raised) {
        fprintf(stderr, "unison-mac: unisonInit0 raised — runtime not fully initialized\n");
        io->status = UNISON_BRIDGE_ERR_EXN;
        return;
    }
    io->status = UNISON_BRIDGE_OK;
}

int unison_bridge_init0(void) {
    struct status_io io = { .status = UNISON_BRIDGE_ERR_MISSING };
    run_on_ocaml_thread(_ocaml_init0, &io);
    return io.status;
}

struct init1_io {
    const char *profile_name;
    int status;
};

static void _ocaml_init1(void *user) {
    struct init1_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;
    const value *closure = caml_named_value("unisonInit1");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit1 not registered\n");
        return;
    }
    value name = caml_copy_string(io->profile_name ? io->profile_name : "");
    /* unisonInit1 spawns its own OCaml thread (doInOtherThread) and returns
     * immediately; this status covers only the SYNCHRONOUS dispatch. A raise
     * here means the connect phase never started — the driver treats it as a
     * failed op with uncertain quiescence (→ restart-required). */
    bool raised = false;
    (void)bridge_call1_exn(closure, name, &raised);
    io->status = raised ? UNISON_BRIDGE_ERR_EXN : UNISON_BRIDGE_OK;
}

int unison_bridge_init1(const char *profile_name) {
    struct init1_io io = { .profile_name = profile_name, .status = UNISON_BRIDGE_ERR_MISSING };
    run_on_ocaml_thread(_ocaml_init1, &io);
    return io.status;
}

/* === Credential loop ===
 *
 * All four operate on g_preconn. Same dispatch-to-OCaml-worker pattern as
 * the other entry points; each acquires the runtime lock and reads/mutates
 * the stashed preconnection. */

struct prompt_io {
    char prompt[4096];
    int  result;   /* unison_prompt_result_t */
};

static void _ocaml_connection_prompt(void *user) {
    struct prompt_io *io = user;
    io->prompt[0] = '\0';
    io->result = UNISON_PROMPT_NONE;
    if (!g_has_preconn) return;                 /* NONE: nothing pending */
    const value *fn = caml_named_value("openConnectionPrompt");
    if (fn == NULL) {                           /* NONE: stale blob */
        fprintf(stderr, "unison-mac: openConnectionPrompt not registered\n");
        return;
    }
    bool raised = false;
    value result = bridge_call1_exn(fn, g_preconn, &raised);
    if (raised) { io->result = UNISON_PROMPT_EXN; return; }   /* EXN, never DONE */
    /* OCaml `string option`: None == Val_int(0) → DONE; Some s → AVAILABLE. */
    if (result == Val_int(0)) { io->result = UNISON_PROMPT_DONE; return; }
    value s = Field(result, 0);
    strncpy(io->prompt, String_val(s), sizeof(io->prompt) - 1);
    io->prompt[sizeof(io->prompt) - 1] = '\0';
    io->result = UNISON_PROMPT_AVAILABLE;
}

unison_prompt_result_t unison_bridge_connection_prompt(const char **out_prompt) {
    /* _Thread_local: per-caller return storage (see unison_bridge_get_version). */
    static _Thread_local struct prompt_io io;
    run_on_ocaml_thread(_ocaml_connection_prompt, &io);
    if (out_prompt != NULL) {
        *out_prompt = (io.result == UNISON_PROMPT_AVAILABLE) ? io.prompt : NULL;
    }
    return (unison_prompt_result_t)io.result;
}

struct reply_io {
    const char *text;
    int         status;   /* UNISON_REPLY_* */
};

static void _ocaml_connection_reply(void *user) {
    struct reply_io *io = user;
    io->status = UNISON_REPLY_NONE;
    if (!g_has_preconn) return;                 /* NONE: nothing to reply to */
    const value *fn = caml_named_value("openConnectionReply");
    if (fn == NULL) {                           /* NONE: stale blob */
        fprintf(stderr, "unison-mac: openConnectionReply not registered\n");
        return;
    }
    value v = caml_copy_string(io->text ? io->text : "");
    bool raised = false;
    (void)bridge_call2_exn(fn, g_preconn, v, &raised);
    /* A raise leaves the preconnection's auth state uncertain; the caller must
     * stop looping and clean up rather than send another prompt/reply. */
    io->status = raised ? UNISON_REPLY_EXN : UNISON_REPLY_OK;
}

int unison_bridge_connection_reply(const char *response) {
    struct reply_io io = { .text = response, .status = UNISON_REPLY_NONE };
    run_on_ocaml_thread(_ocaml_connection_reply, &io);
    return io.status;
}

/* connection_end / connection_cancel are now status-returning and
 * exception-safe (findings 1 & 2). Both use caml_callback_exn and treat an
 * OCaml exception as a failure the Swift driver routes to a restart-required
 * transition, and both release g_preconn on EVERY terminal path (success,
 * exception, or missing callback) so a half-open preconnection is never leaked.
 * Status: 0 = success; UNISON_CONN_ERR_NONE (-1) = nothing to finalize/cancel
 * or callback missing; UNISON_CONN_ERR_EXN (2) = OCaml raised. */
struct conn_fin_io { int status; };

static void _ocaml_connection_end(void *user) {
    struct conn_fin_io *io = user;
    if (!g_has_preconn) { io->status = -1; return; }
    const value *fn = caml_named_value("openConnectionEnd");
    if (fn == NULL) { release_preconn(); io->status = -1; return; }
    value r = caml_callback_exn(*fn, g_preconn);
    release_preconn();                       /* release on every terminal path */
    io->status = Is_exception_result(r) ? 2 : 0;
}

int unison_bridge_connection_end(void) {
    struct conn_fin_io io = { .status = -1 };
    run_on_ocaml_thread(_ocaml_connection_end, &io);
    return io.status;
}

static void _ocaml_connection_cancel(void *user) {
    struct conn_fin_io *io = user;
    /* Nothing to cancel is a benign, idempotent success (the preconnection is
     * already gone) — status 0, so an abandoned connect with no live
     * preconnection still resolves cleanly. */
    if (!g_has_preconn) {
        io->status = 0;
    } else {
        const value *fn = caml_named_value("openConnectionCancel");
        if (fn == NULL) {
            release_preconn();
            io->status = -1;
        } else {
            value r = caml_callback_exn(*fn, g_preconn);
            release_preconn();               /* release on every terminal path */
            io->status = Is_exception_result(r) ? 2 : 0;
        }
    }
#ifdef UNISON_DEBUG_HOOKS
    /* Issue #35 scenario-6 hook (Debug ONLY): drive the non-quiescent path by
     * forcing the REPORTED cancel status to "failed" while the real cancel above
     * still runs (so nothing leaks). Compiled out entirely in Release
     * (UNISON_DEBUG_HOOKS is set only by project.yml's Debug config), so neither
     * this behavior nor the env-var string exists in a Release binary and the
     * hook is impossible to activate there. */
    const char *force = getenv("UNISON_TEST_FORCE_CANCEL_FAIL");
    if (force != NULL && force[0] == '1') { io->status = 2; }
#endif
}

int unison_bridge_connection_cancel(void) {
    struct conn_fin_io io = { .status = 0 };
    run_on_ocaml_thread(_ocaml_connection_cancel, &io);
    return io.status;
}

/* Close an established connection via the OCaml `closeConnection`
 * callback (Remote.clientCloseRootConnection). See the header for the
 * quiescent-only contract and return codes. */
struct close_conn_io { int status; };

static void _ocaml_close_connection(void *user) {
    struct close_conn_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;   /* callback not registered (old blob) */
    const value *fn = caml_named_value("closeConnection");
    if (fn == NULL) return;
    bool raised = false;
    value r = bridge_call1_exn(fn, Val_unit, &raised);
    /* A raise is a failed close with uncertain quiescence — status 2, which the
     * driver routes to restart-required (never misread as a successful close). */
    io->status = raised ? UNISON_BRIDGE_ERR_EXN : Int_val(r);
}

int unison_bridge_close_connection(void) {
    struct close_conn_io io = { .status = -1 };
    run_on_ocaml_thread(_ocaml_close_connection, &io);
    return io.status;
}

struct init2_io { int status; };

static void _ocaml_init2(void *user) {
    struct init2_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;
    const value *closure = caml_named_value("unisonInit2");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit2 not registered\n");
        return;
    }
    /* Scan runs async; this covers the synchronous dispatch. A raise means the
     * scan never started → failed op with uncertain quiescence (→ restart). */
    bool raised = false;
    (void)bridge_call1_exn(closure, Val_unit, &raised);
    io->status = raised ? UNISON_BRIDGE_ERR_EXN : UNISON_BRIDGE_OK;
}

int unison_bridge_init2(void) {
    struct init2_io io = { .status = UNISON_BRIDGE_ERR_MISSING };
    run_on_ocaml_thread(_ocaml_init2, &io);
    return io.status;
}

struct ri_set_io {
    const char *setter_name;     /* OCaml callback name, e.g. "unisonRiSetRight" | "unisonRiRevert" */
    int         row;
    char        direction[16];   /* Out: new direction in OCaml raw form */
    bool        changed;         /* Out: changedFromDefault after the mutation */
    int         result;          /* unison_op_result_t */
};

/* Shared per-row direction mutation: apply `setter_name` to the row, then read
 * back the resulting direction AND changedFromDefault. Used by all six direction
 * setters and by Revert (setter_name = "unisonRiRevert"). Both readbacks are
 * part of the operation — a raise in either is DIRTY (the row was mutated),
 * never a silent "no change" / false `changed`. */
static void _ocaml_ri_mutate(void *user) {
    struct ri_set_io *io = user;
    io->direction[0] = '\0';
    io->changed = false;
    io->result = UNISON_OP_INVALID;

    if (io->row < 0 || (size_t)io->row >= g_ri_count) {
        fprintf(stderr, "unison-mac: ri mutate row %d out of range (count=%zu)\n",
                io->row, g_ri_count);
        return;   /* INVALID — no mutation */
    }

    /* Resolve ALL three callbacks before mutating: a missing one is INVALID
     * (nothing changed), never a null-deref after the setter already ran. */
    const value *setter = caml_named_value(io->setter_name);
    const value *dir_fn = caml_named_value("unisonRiToDirection");
    const value *chg_fn = caml_named_value("changedFromDefault");
    if (setter == NULL || dir_fn == NULL || chg_fn == NULL) {
        fprintf(stderr, "unison-mac: ri mutate callback missing (%s / unisonRiToDirection / changedFromDefault)\n",
                io->setter_name);
        return;   /* INVALID — no mutation */
    }

    /* The setter IS the mutation. Any raise from here on is DIRTY: the row may
     * have been partially mutated, so the engine's state is uncertain and the
     * caller must not keep the old row live/actionable. */
    bool raised = false;
    (void)bridge_call1_exn(setter, g_ri_roots[io->row], &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; return; }

    value dir_v = bridge_call1_exn(dir_fn, g_ri_roots[io->row], &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; return; }  /* mutated, readback failed */
    strncpy(io->direction, String_val(dir_v), sizeof(io->direction) - 1);
    io->direction[sizeof(io->direction) - 1] = '\0';

    value chg_v = bridge_call1_exn(chg_fn, g_ri_roots[io->row], &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; return; }  /* mutated; never report false-on-failure */
    io->changed = (Bool_val(chg_v) == 1);
    io->result = UNISON_OP_OK;
}

static unison_op_result_t _ri_mutate_via(const char *setter_name, int row,
                                         char *out_dir, size_t out_dir_len,
                                         bool *out_changed) {
    struct ri_set_io io = { .setter_name = setter_name, .row = row };
    run_on_ocaml_thread(_ocaml_ri_mutate, &io);
    if (out_dir != NULL && out_dir_len > 0) {
        strncpy(out_dir, io.result == UNISON_OP_OK ? io.direction : "", out_dir_len - 1);
        out_dir[out_dir_len - 1] = '\0';
    }
    /* Only report changed on success — a non-OK result never conflates a
     * callback failure with `false`. */
    if (out_changed != NULL && io.result == UNISON_OP_OK) *out_changed = io.changed;
    return (unison_op_result_t)io.result;
}

unison_op_result_t unison_bridge_ri_set_to_remote(int row, char *d, size_t n, bool *c) { return _ri_mutate_via("unisonRiSetRight",    row, d, n, c); }
unison_op_result_t unison_bridge_ri_set_to_local(int row, char *d, size_t n, bool *c)  { return _ri_mutate_via("unisonRiSetLeft",     row, d, n, c); }
unison_op_result_t unison_bridge_ri_set_skip(int row, char *d, size_t n, bool *c)      { return _ri_mutate_via("unisonRiSetConflict", row, d, n, c); }
unison_op_result_t unison_bridge_ri_set_merge(int row, char *d, size_t n, bool *c)     { return _ri_mutate_via("unisonRiSetMerge",    row, d, n, c); }
unison_op_result_t unison_bridge_ri_force_older(int row, char *d, size_t n, bool *c)   { return _ri_mutate_via("unisonRiForceOlder",  row, d, n, c); }
unison_op_result_t unison_bridge_ri_force_newer(int row, char *d, size_t n, bool *c)   { return _ri_mutate_via("unisonRiForceNewer",  row, d, n, c); }

/* Finding #2: the genuine engine inverse — reset the row to Unison's post-scan
 * recommendation via upstream `unisonRiRevert`. Same mutate-then-readback
 * contract; on success `*out_changed` is false (back to default by definition). */
unison_op_result_t unison_bridge_ri_revert(int row, char *d, size_t n, bool *c)        { return _ri_mutate_via("unisonRiRevert",      row, d, n, c); }

/* Per-row Diff support. canDiff is a pure read (no mutation); runShowDiffs
 * kicks off the diff and returns immediately — the result comes back via
 * the diff/diff-err callbacks. */
struct can_diff_io {
    int  row;
    bool result;
};

static void _ocaml_can_diff(void *user) {
    struct can_diff_io *io = user;
    io->result = false;
    if (io->row < 0 || (size_t)io->row >= g_ri_count) return;
    const value *fn = caml_named_value("canDiff");
    if (fn == NULL) {
        fprintf(stderr, "unison-mac: canDiff not registered\n");
        return;
    }
    bool raised = false;
    value r = bridge_call1_exn(fn, g_ri_roots[io->row], &raised);
    if (raised) return;   /* result stays false; engine remains valid */
    io->result = (Bool_val(r) == 1);
}

bool unison_bridge_can_diff(int row) {
    struct can_diff_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_can_diff, &io);
    return io.result;
}

struct run_show_diffs_io {
    int  row;
    bool ok;
};

static void _ocaml_run_show_diffs(void *user) {
    struct run_show_diffs_io *io = user;
    io->ok = false;
    if (io->row < 0 || (size_t)io->row >= g_ri_count) {
        fprintf(stderr, "unison-mac: run_show_diffs row %d out of range\n", io->row);
        return;
    }
    const value *fn = caml_named_value("runShowDiffs");
    if (fn == NULL) {
        fprintf(stderr, "unison-mac: runShowDiffs not registered\n");
        return;
    }
    // runShowDiffs signature: `ri -> int -> unit`. The int is used to tag
    // diff output back to a specific row (Uutil.File.ofLine i); we pass
    // the same row index so the tagging is consistent.
    bool raised = false;
    (void)bridge_call2_exn(fn, g_ri_roots[io->row], Val_int(io->row), &raised);
    io->ok = !raised;   /* false lets the caller surface a diff error, not a silent no-op */
}

bool unison_bridge_run_show_diffs(int row) {
    struct run_show_diffs_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_run_show_diffs, &io);
    return io.ok;
}

/* Per-row getter. Same dispatch pattern as the ri_set_* functions but
 * doesn't mutate state — just reads `unisonRiToDetails` for the row.
 *
 * Read-only (Blocker 4): a raise here mutates nothing, so it retains narrow
 * failure handling — NULL to the caller. NULL already covers "out of range" and
 * "no details", and the Details caller needs no finer distinction (it simply
 * shows nothing); the exception is logged for diagnosis. The engine stays
 * valid, so no restart routing. */
struct ri_details_io {
    int  row;
    char buf[4096];
};

static void _ocaml_ri_get_details(void *user) {
    struct ri_details_io *io = user;
    io->buf[0] = '\0';
    if (io->row < 0 || (size_t)io->row >= g_ri_count) return;
    const value *fn = caml_named_value("unisonRiToDetails");
    if (fn == NULL) return;
    bool raised = false;
    value result = bridge_call1_exn(fn, g_ri_roots[io->row], &raised);
    if (raised) {   /* buf stays empty → caller returns NULL; engine valid */
        fprintf(stderr, "unison-mac: unisonRiToDetails raised for row %d\n", io->row);
        return;
    }
    strncpy(io->buf, String_val(result), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
}

const char *unison_bridge_ri_get_details(int row) {
    static _Thread_local char buf[4096];
#if UNISON_DEBUG_HOOKS
    atomic_fetch_add(&g_test_ri_get_details_calls, 1);
#endif
    struct ri_details_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_ri_get_details, &io);
    if (io.buf[0] == '\0') return NULL;
    strncpy(buf, io.buf, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return buf;
}

/* === Per-row Ignore actions ===
 *
 * For a row, ask OCaml for its path, hand that path to one of the three
 * Uicommon.ignore{Path,Ext,Name} flavors, then re-run unisonUpdateForIgnore
 * to filter the global theState. The new state-item array is emitted via
 * the same handler as init2 — Swift treats it as a "fresh items, replace
 * in place" update, exactly like a rescan.
 *
 * Row indices in the new array bear no relationship to the old indices:
 * unisonUpdateForIgnore drops every now-ignored row, so even the click
 * target itself is usually gone after this returns. That's the point. */
struct ignore_io {
    int         row;
    const char *ignore_fn_name;  /* "unisonIgnorePath" | "unisonIgnoreExt" | "unisonIgnoreName" */
    int         result;          /* unison_op_result_t */
};

static void _ocaml_ignore(void *user) {
    CAMLparam0();
    CAMLlocal2(path_v, arr);
    struct ignore_io *io = user;
    io->result = UNISON_OP_INVALID;

    if (io->row < 0 || (size_t)io->row >= g_ri_count) {
        fprintf(stderr, "unison-mac: ignore row %d out of range (count=%zu)\n",
                io->row, g_ri_count);
        CAMLreturn0;   /* INVALID — no mutation */
    }

    /* Resolve EVERY callback before running any mutating step, so a missing one
     * is INVALID (nothing changed) rather than a partial mutation. */
    const value *path_fn   = caml_named_value("unisonRiToPath");
    const value *ignore_fn = caml_named_value(io->ignore_fn_name);
    const value *upd_fn    = caml_named_value("unisonUpdateForIgnore");
    const value *state_fn  = caml_named_value("unisonState");
    if (path_fn == NULL || ignore_fn == NULL || upd_fn == NULL || state_fn == NULL) {
        fprintf(stderr, "unison-mac: ignore callback missing (path/%s/update/state)\n",
                io->ignore_fn_name);
        CAMLreturn0;   /* INVALID — no mutation */
    }

    bool raised = false;

    /* Reading the path is read-only: a raise here changed nothing → CLEAN. */
    path_v = bridge_call1_exn(path_fn, g_ri_roots[io->row], &raised);
    if (raised) { io->result = UNISON_OP_FAILED_CLEAN; CAMLreturn0; }

    /* From here the operation mutates engine state — persisting the ignore
     * pattern, then rewriting theState. Any raise, or a failure to publish the
     * post-filter state, is DIRTY: theState no longer matches the displayed
     * rows, so the caller must route to restart-required. path_v is held across
     * these allocating callbacks; CAMLlocal2 keeps it rooted. */
    (void)bridge_call1_exn(ignore_fn, path_v, &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; CAMLreturn0; }

    (void)bridge_call1_exn(upd_fn, Val_int(0), &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; CAMLreturn0; }

    arr = bridge_call1_exn(state_fn, Val_unit, &raised);
    if (raised) { io->result = UNISON_OP_FAILED_DIRTY; CAMLreturn0; }

    /* theState is already mutated; publish it through the DEDICATED ignore
     * consumer (never the init2/scan handler — an ignore completion must never
     * satisfy pendingScan). On success the originating session's rows are
     * updated; on failure the engine moved but the old rows stay published →
     * DIRTY (route to restart). */
    io->result = emit_state_items(arr, g_ignore_complete_handler)
                     ? UNISON_OP_OK : UNISON_OP_FAILED_DIRTY;
    CAMLreturn0;
}

static unison_op_result_t _ignore_via(const char *fn_name, int row) {
    struct ignore_io io = { .row = row, .ignore_fn_name = fn_name };
    run_on_ocaml_thread(_ocaml_ignore, &io);
    return (unison_op_result_t)io.result;
}

unison_op_result_t unison_bridge_ignore_path(int row) { return _ignore_via("unisonIgnorePath", row); }
unison_op_result_t unison_bridge_ignore_ext(int row)  { return _ignore_via("unisonIgnoreExt",  row); }
unison_op_result_t unison_bridge_ignore_name(int row) { return _ignore_via("unisonIgnoreName", row); }

struct sync_io { int status; };

static void _ocaml_synchronize(void *user) {
    struct sync_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;
    const value *closure = caml_named_value("unisonSynchronize");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonSynchronize not registered\n");
        return;
    }
    /* unisonSynchronize spawns its own OCaml thread (doInOtherThread) and
     * returns immediately. Completion arrives later via syncComplete. A raise
     * here means the sync never launched → failed start with uncertain
     * quiescence, which the driver routes to restart-required (the pending
     * syncComplete will never arrive, so the caller must not wait for it). */
    bool raised = false;
    (void)bridge_call1_exn(closure, Val_unit, &raised);
    io->status = raised ? UNISON_BRIDGE_ERR_EXN : UNISON_BRIDGE_OK;
}

int unison_bridge_synchronize(void) {
    struct sync_io io = { .status = UNISON_BRIDGE_ERR_MISSING };
    run_on_ocaml_thread(_ocaml_synchronize, &io);
    return io.status;
}

/* Abort the in-flight sync. The actual sync is running on an OCaml
 * worker that's spinning through Lwt-managed file transfers; we just
 * need to flip `Abort.abortAll` to true and let the worker observe
 * the flag at its next checkpoint.
 *
 * The Lwt-managed transfer releases the OCaml runtime lock during
 * blocking IO, so our dispatched _ocaml_abort_all runs on whichever
 * of the 3 worker threads picks it up. The actual `Abort.all` call
 * is just `abortAll := true` — fast, no chance of deadlock against
 * the sync worker. */
static void _ocaml_abort_all(void *user) {
    struct status_io *io = user;
    io->status = UNISON_BRIDGE_ERR_MISSING;
    const value *fn = caml_named_value("abortAll");
    if (fn == NULL) {
        fprintf(stderr, "unison-mac: abortAll not registered (vendored blob out of date / built without upstream mid-sync abort?)\n");
        return;   /* ERR_MISSING: the abort flag was NOT set — caller must not
                   * claim the cancellation was requested. */
    }
    /* abortAll is `abortAll := true` — fast, no deadlock against the sync worker;
     * it cannot itself raise in practice, but route it through the exn wrapper
     * for uniformity. On a raise the flag was NOT reliably set, so report EXN and
     * let the caller surface that cancellation could not be requested rather than
     * falsely claim success. The worker thread is never stranded either way. */
    bool raised = false;
    (void)bridge_call1_exn(fn, Val_unit, &raised);
    io->status = raised ? UNISON_BRIDGE_ERR_EXN : UNISON_BRIDGE_OK;
}

int unison_bridge_abort_sync(void) {
    struct status_io io = { .status = UNISON_BRIDGE_ERR_MISSING };
    run_on_ocaml_thread(_ocaml_abort_all, &io);
    return io.status;
}
