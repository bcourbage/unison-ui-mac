#include "UnisonBridgeC.h"

#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/threads.h>

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>

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

    value vp = caml_callback(*fn_p, g_ri_roots[i]);
    value vb = caml_callback(*fn_b, g_ri_roots[i]);

    unison_row_state_t state = {
        .progress          = String_val(vp),  /* lifetime: valid only while we hold the lock */
        .bytes_transferred = (int64_t)Double_val(vb),
    };
    g_reload_row_handler(i, &state);
    CAMLreturn(Val_unit);
}

CAMLprim value syncComplete(value unit) {
    CAMLparam1(unit);
    if (g_sync_complete_handler) {
        g_sync_complete_handler();
    }
    CAMLreturn(Val_unit);
}

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

static void clear_ri_roots(void) {
    for (size_t i = 0; i < g_ri_count; i++) {
        caml_remove_generational_global_root(&g_ri_roots[i]);
    }
    free(g_ri_roots);
    g_ri_roots = NULL;
    g_ri_count = 0;
}

static void register_ri_roots(value arr) {
    /* Caller holds the runtime lock (we're invoked from unisonInit2Complete). */
    clear_ri_roots();
    const size_t n = (size_t)Wosize_val(arr);
    if (n == 0) return;
    g_ri_roots = calloc(n, sizeof(value));
    if (g_ri_roots == NULL) {
        fprintf(stderr, "unison-mac: OOM registering %zu ri roots\n", n);
        return;
    }
    g_ri_count = n;
    for (size_t i = 0; i < n; i++) {
        g_ri_roots[i] = Field(arr, i);
        caml_register_generational_global_root(&g_ri_roots[i]);
    }
}

/* Shared between unisonInit2Complete (fired from OCaml when init2 finishes)
 * and unison_bridge_update_for_ignore (fired from Swift after the user picks
 * an Ignore action on a row). Both produce the same observable effect on
 * the Swift side: "here is a fresh state-item array, replace the table in
 * place" — so they go through the same handler. Caller must hold the OCaml
 * runtime lock. */
static void emit_state_items(value arr_in) {
    CAMLparam1(arr_in);
    CAMLlocal1(item);

    register_ri_roots(arr_in);

    if (g_init2_complete_handler == NULL) {
        CAMLreturn0;
    }

    const size_t n = (size_t)Wosize_val(arr_in);
    unison_state_item_t *out = NULL;
    if (n > 0) {
        out = calloc(n, sizeof(*out));
        if (out == NULL) {
            fprintf(stderr, "unison-mac: OOM allocating %zu state items\n", n);
            CAMLreturn0;
        }
    }

    const value *fn_path      = caml_named_value("unisonRiToPath");
    const value *fn_left      = caml_named_value("unisonRiToLeft");
    const value *fn_right     = caml_named_value("unisonRiToRight");
    const value *fn_direction = caml_named_value("unisonRiToDirection");
    const value *fn_size      = caml_named_value("unisonRiToFileSize");
    const value *fn_type      = caml_named_value("unisonRiToFileType");
    const value *fn_progress  = caml_named_value("unisonRiToProgress");
    const value *fn_bytes     = caml_named_value("unisonRiToBytesTransferred");

    for (size_t i = 0; i < n; i++) {
        item = Field(arr_in, i);
        out[i].path              = strdup(String_val(caml_callback(*fn_path, item)));
        out[i].left              = strdup(String_val(caml_callback(*fn_left, item)));
        out[i].right             = strdup(String_val(caml_callback(*fn_right, item)));
        out[i].direction         = strdup(String_val(caml_callback(*fn_direction, item)));
        out[i].size_bytes        = (int64_t)Double_val(caml_callback(*fn_size, item));
        out[i].file_type         = strdup(String_val(caml_callback(*fn_type, item)));
        out[i].progress          = strdup(String_val(caml_callback(*fn_progress, item)));
        out[i].bytes_transferred = (int64_t)Double_val(caml_callback(*fn_bytes, item));
    }

    /* Synchronous: the Swift trampoline must copy strings before returning. */
    g_init2_complete_handler(out, n);

    for (size_t i = 0; i < n; i++) {
        free((void *)out[i].path);
        free((void *)out[i].left);
        free((void *)out[i].right);
        free((void *)out[i].direction);
        free((void *)out[i].file_type);
        free((void *)out[i].progress);
    }
    free(out);

    CAMLreturn0;
}

CAMLprim value unisonInit2Complete(value arr) {
    CAMLparam1(arr);
    emit_state_items(arr);
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
 * (remote.ml:buildShellConnection). On NORMAL OCaml termination its at_exit
 * `end_ssh` reaps it, but the AppKit host can terminate this process WITHOUT
 * running OCaml at_exit (unison_bridge_shutdown is a bounded C helper that
 * does not drive at_exit), and a sync wedged on a frozen remote is blocked on
 * the transport socket, not stdio, so pipe closure won't wake the child. It
 * then survives as an orphan.
 *
 * Guarantee (needs NO OCaml/Lwt progress at shutdown): OCaml populates this
 * C-owned registry with each transport child's EXACT pid right after spawn
 * (Remote.registerTransportChild) and removes it strictly before the OCaml
 * reap (Remote.unregisterTransportChild); a pure-C pass SIGKILLs whatever
 * remains during shutdown. No process enumeration, no name/command/pgroup
 * matching -- only exact registered pids, and only while still un-reaped (so a
 * pid can never denote a reused process). See docs/ssh-reaper-design.md for
 * the adversarial race proof. */
#define MAX_TRANSPORT_CHILDREN 64
static pthread_mutex_t g_child_mutex = PTHREAD_MUTEX_INITIALIZER;
static pid_t g_children[MAX_TRANSPORT_CHILDREN];
static int   g_child_count = 0;
static bool  g_children_closing = false;

/* Register a just-spawned transport child by exact pid. If shutdown has
 * already begun (closing), the pid cannot be covered by the C pass that may
 * already have run, so kill it at once -- a spawn racing shutdown must not
 * escape. A full registry likewise cannot track the pid, so it is killed
 * rather than left untracked. */
void unison_bridge_track_child(pid_t pid) {
    if (pid <= 0) return;
    bool kill_now = false;
    pthread_mutex_lock(&g_child_mutex);
    if (g_children_closing) {
        kill_now = true;
    } else if (g_child_count < MAX_TRANSPORT_CHILDREN) {
        g_children[g_child_count++] = pid;
    } else {
        kill_now = true;
    }
    pthread_mutex_unlock(&g_child_mutex);
    if (kill_now) kill(pid, SIGKILL);
}

/* Unregister a transport child. MUST be called strictly BEFORE the OCaml reap
 * (waitpid), while the pid is still reserved by the OS, so the registry never
 * retains a pid that has become reusable. */
void unison_bridge_untrack_child(pid_t pid) {
    pthread_mutex_lock(&g_child_mutex);
    for (int i = 0; i < g_child_count; i++) {
        if (g_children[i] == pid) {
            g_children[i] = g_children[--g_child_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_child_mutex);
}

/* Pure-C shutdown reaper. Atomically flips `closing` + detaches the set under
 * the mutex, then SIGKILLs the snapshot OUTSIDE the mutex (kill(2) is never
 * held under the leaf mutex). Idempotent (a second call finds an empty set).
 * SIGKILL, not SIGTERM: a stopped/wedged child may defer or ignore SIGTERM;
 * SIGKILL cannot be caught, blocked, or deferred. Does NOT waitpid -- the
 * process is exiting so init reaps the transient zombies; this keeps shutdown
 * non-blocking and avoids a double-reap race with a concurrent OCaml waitpid.
 * Returns the number of pids signaled. */
int unison_bridge_reap_transport_children(void) {
    pid_t snapshot[MAX_TRANSPORT_CHILDREN];
    int n;
    pthread_mutex_lock(&g_child_mutex);
    g_children_closing = true;
    n = g_child_count;
    for (int i = 0; i < n; i++) snapshot[i] = g_children[i];
    g_child_count = 0;
    pthread_mutex_unlock(&g_child_mutex);
    for (int i = 0; i < n; i++) kill(snapshot[i], SIGKILL);
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
CAMLprim value unison_bridge_unregister_child(value pid_v) {
    CAMLparam1(pid_v);
    unison_bridge_untrack_child((pid_t)Long_val(pid_v));
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

struct get_version_io {
    char buf[256];
};

static void _ocaml_get_version(void *user) {
    struct get_version_io *io = user;
    const value *closure = caml_named_value("unisonGetVersion");
    if (closure == NULL) {
        io->buf[0] = '\0';
        return;
    }
    value result = caml_callback(*closure, Val_unit);
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
    const value *closure = caml_named_value("unisonDirectory");
    if (closure == NULL) {
        io->buf[0] = '\0';
        return;
    }
    value result = caml_callback(*closure, Val_unit);
    strncpy(io->buf, String_val(result), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
}

const char *unison_bridge_unison_directory(void) {
    /* _Thread_local: per-caller return storage (see unison_bridge_get_version). */
    static _Thread_local struct unison_directory_io io;
    run_on_ocaml_thread(_ocaml_unison_directory, &io);
    return io.buf[0] ? io.buf : NULL;
}

static void _ocaml_init0(void *user) {
    (void)user;
    const value *closure = caml_named_value("unisonInit0");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit0 not registered\n");
        return;
    }
    (void)caml_callback(*closure, Val_unit);
}

void unison_bridge_init0(void) {
    run_on_ocaml_thread(_ocaml_init0, NULL);
}

struct init1_io {
    const char *profile_name;
};

static void _ocaml_init1(void *user) {
    struct init1_io *io = user;
    const value *closure = caml_named_value("unisonInit1");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit1 not registered\n");
        return;
    }
    value name = caml_copy_string(io->profile_name ? io->profile_name : "");
    /* unisonInit1 spawns its own OCaml thread (doInOtherThread) and
     * returns immediately. Completion arrives later via unisonInit1Complete. */
    (void)caml_callback(*closure, name);
}

void unison_bridge_init1(const char *profile_name) {
    struct init1_io io = { .profile_name = profile_name };
    run_on_ocaml_thread(_ocaml_init1, &io);
}

/* === Credential loop ===
 *
 * All four operate on g_preconn. Same dispatch-to-OCaml-worker pattern as
 * the other entry points; each acquires the runtime lock and reads/mutates
 * the stashed preconnection. */

struct prompt_io {
    char prompt[4096];
    bool has_prompt;
};

static void _ocaml_connection_prompt(void *user) {
    struct prompt_io *io = user;
    io->has_prompt = false;
    io->prompt[0] = '\0';
    if (!g_has_preconn) return;
    const value *fn = caml_named_value("openConnectionPrompt");
    if (fn == NULL) return;
    value result = caml_callback(*fn, g_preconn);
    /* OCaml `string option`: None == Val_int(0); Some s is a block. */
    if (result == Val_int(0)) return;
    value s = Field(result, 0);
    strncpy(io->prompt, String_val(s), sizeof(io->prompt) - 1);
    io->prompt[sizeof(io->prompt) - 1] = '\0';
    io->has_prompt = true;
}

const char *unison_bridge_connection_prompt(void) {
    /* _Thread_local: per-caller return storage (see unison_bridge_get_version). */
    static _Thread_local struct prompt_io io;
    run_on_ocaml_thread(_ocaml_connection_prompt, &io);
    return io.has_prompt ? io.prompt : NULL;
}

struct reply_io { const char *text; };

static void _ocaml_connection_reply(void *user) {
    struct reply_io *io = user;
    if (!g_has_preconn) return;
    const value *fn = caml_named_value("openConnectionReply");
    if (fn == NULL) return;
    value v = caml_copy_string(io->text ? io->text : "");
    (void)caml_callback2(*fn, g_preconn, v);
}

void unison_bridge_connection_reply(const char *response) {
    struct reply_io io = { .text = response };
    run_on_ocaml_thread(_ocaml_connection_reply, &io);
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
    if (!g_has_preconn) { io->status = 0; return; }
    const value *fn = caml_named_value("openConnectionCancel");
    if (fn == NULL) { release_preconn(); io->status = -1; return; }
    value r = caml_callback_exn(*fn, g_preconn);
    release_preconn();                       /* release on every terminal path */
    io->status = Is_exception_result(r) ? 2 : 0;
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
    io->status = -1;                 /* callback not registered (old blob) */
    const value *fn = caml_named_value("closeConnection");
    if (fn == NULL) return;
    io->status = Int_val(caml_callback(*fn, Val_unit));
}

int unison_bridge_close_connection(void) {
    struct close_conn_io io = { .status = -1 };
    run_on_ocaml_thread(_ocaml_close_connection, &io);
    return io.status;
}

static void _ocaml_init2(void *user) {
    (void)user;
    const value *closure = caml_named_value("unisonInit2");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonInit2 not registered\n");
        return;
    }
    (void)caml_callback(*closure, Val_unit);
}

void unison_bridge_init2(void) {
    run_on_ocaml_thread(_ocaml_init2, NULL);
}

struct ri_set_io {
    const char *setter_name;     /* OCaml callback name, e.g. "unisonRiSetRight" */
    int         row;
    char        direction[16];   /* Out: new direction in OCaml raw form */
    bool        ok;
};

static void _ocaml_ri_set(void *user) {
    struct ri_set_io *io = user;
    io->direction[0] = '\0';
    io->ok = false;

    if (io->row < 0 || (size_t)io->row >= g_ri_count) {
        fprintf(stderr, "unison-mac: ri_set row %d out of range (count=%zu)\n",
                io->row, g_ri_count);
        return;
    }

    const value *setter = caml_named_value(io->setter_name);
    if (setter == NULL) {
        fprintf(stderr, "unison-mac: %s not registered\n", io->setter_name);
        return;
    }
    (void)caml_callback(*setter, g_ri_roots[io->row]);

    const value *dir_fn = caml_named_value("unisonRiToDirection");
    if (dir_fn == NULL) return;
    value dir_v = caml_callback(*dir_fn, g_ri_roots[io->row]);
    strncpy(io->direction, String_val(dir_v), sizeof(io->direction) - 1);
    io->direction[sizeof(io->direction) - 1] = '\0';
    io->ok = true;
}

static const char *_ri_set_via(const char *setter_name, int row) {
    static _Thread_local char buf[16];
    struct ri_set_io io = { .setter_name = setter_name, .row = row };
    run_on_ocaml_thread(_ocaml_ri_set, &io);
    if (!io.ok) return NULL;
    strncpy(buf, io.direction, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return buf;
}

const char *unison_bridge_ri_set_to_remote(int row) { return _ri_set_via("unisonRiSetRight",    row); }
const char *unison_bridge_ri_set_to_local(int row)  { return _ri_set_via("unisonRiSetLeft",     row); }
const char *unison_bridge_ri_set_skip(int row)      { return _ri_set_via("unisonRiSetConflict", row); }
const char *unison_bridge_ri_set_merge(int row)     { return _ri_set_via("unisonRiSetMerge",    row); }
const char *unison_bridge_ri_force_older(int row)   { return _ri_set_via("unisonRiForceOlder",  row); }
const char *unison_bridge_ri_force_newer(int row)   { return _ri_set_via("unisonRiForceNewer",  row); }

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
    value r = caml_callback(*fn, g_ri_roots[io->row]);
    io->result = (Bool_val(r) == 1);
}

bool unison_bridge_can_diff(int row) {
    struct can_diff_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_can_diff, &io);
    return io.result;
}

struct run_show_diffs_io {
    int row;
};

static void _ocaml_run_show_diffs(void *user) {
    struct run_show_diffs_io *io = user;
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
    (void)caml_callback2(*fn, g_ri_roots[io->row], Val_int(io->row));
}

void unison_bridge_run_show_diffs(int row) {
    struct run_show_diffs_io io = { .row = row };
    run_on_ocaml_thread(_ocaml_run_show_diffs, &io);
}

/* Per-row getter. Same dispatch pattern as the ri_set_* functions but
 * doesn't mutate state — just reads `unisonRiToDetails` for the row. */
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
    value result = caml_callback(*fn, g_ri_roots[io->row]);
    strncpy(io->buf, String_val(result), sizeof(io->buf) - 1);
    io->buf[sizeof(io->buf) - 1] = '\0';
}

const char *unison_bridge_ri_get_details(int row) {
    static _Thread_local char buf[4096];
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
    bool        ok;
};

static void _ocaml_ignore(void *user) {
    CAMLparam0();
    CAMLlocal2(path_v, arr);
    struct ignore_io *io = user;
    io->ok = false;

    if (io->row < 0 || (size_t)io->row >= g_ri_count) {
        fprintf(stderr, "unison-mac: ignore row %d out of range (count=%zu)\n",
                io->row, g_ri_count);
        CAMLreturn0;
    }

    const value *path_fn = caml_named_value("unisonRiToPath");
    if (path_fn == NULL) {
        fprintf(stderr, "unison-mac: unisonRiToPath not registered\n");
        CAMLreturn0;
    }
    path_v = caml_callback(*path_fn, g_ri_roots[io->row]);

    const value *ignore_fn = caml_named_value(io->ignore_fn_name);
    if (ignore_fn == NULL) {
        fprintf(stderr, "unison-mac: %s not registered\n", io->ignore_fn_name);
        CAMLreturn0;
    }
    (void)caml_callback(*ignore_fn, path_v);

    const value *upd_fn = caml_named_value("unisonUpdateForIgnore");
    if (upd_fn == NULL) {
        fprintf(stderr, "unison-mac: unisonUpdateForIgnore not registered\n");
        CAMLreturn0;
    }
    (void)caml_callback(*upd_fn, Val_int(0));

    const value *state_fn = caml_named_value("unisonState");
    if (state_fn == NULL) {
        fprintf(stderr, "unison-mac: unisonState not registered\n");
        CAMLreturn0;
    }
    arr = caml_callback(*state_fn, Val_unit);

    emit_state_items(arr);
    io->ok = true;
    CAMLreturn0;
}

static bool _ignore_via(const char *fn_name, int row) {
    struct ignore_io io = { .row = row, .ignore_fn_name = fn_name };
    run_on_ocaml_thread(_ocaml_ignore, &io);
    return io.ok;
}

bool unison_bridge_ignore_path(int row) { return _ignore_via("unisonIgnorePath", row); }
bool unison_bridge_ignore_ext(int row)  { return _ignore_via("unisonIgnoreExt",  row); }
bool unison_bridge_ignore_name(int row) { return _ignore_via("unisonIgnoreName", row); }

static void _ocaml_synchronize(void *user) {
    (void)user;
    const value *closure = caml_named_value("unisonSynchronize");
    if (closure == NULL) {
        fprintf(stderr, "unison-mac: unisonSynchronize not registered\n");
        return;
    }
    /* unisonSynchronize spawns its own OCaml thread (doInOtherThread) and
     * returns immediately. Completion arrives later via syncComplete. */
    (void)caml_callback(*closure, Val_unit);
}

void unison_bridge_synchronize(void) {
    run_on_ocaml_thread(_ocaml_synchronize, NULL);
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
    (void)user;
    const value *fn = caml_named_value("abortAll");
    if (fn == NULL) {
        fprintf(stderr, "unison-mac: abortAll not registered (uimacbridge.ml patch missing?)\n");
        return;
    }
    (void)caml_callback(*fn, Val_unit);
}

void unison_bridge_abort_sync(void) {
    run_on_ocaml_thread(_ocaml_abort_all, NULL);
}
