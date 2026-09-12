/* No-op C stubs for uimacbridge.ml's `external` declarations, so the fresh-load
 * harness (cli-session-firstload-harness.ml) can link uimacbridge.cmx and call
 * the real do_unisonInit1. The LOCAL-profile first-load path invokes none of
 * these at runtime; they exist only to satisfy the linker. */
#include <caml/mlvalues.h>

CAMLprim value unison_bridge_register_child(value v) { (void)v; return Val_unit; }
CAMLprim value unison_bridge_retire_child_ml(value v) { (void)v; return Val_unit; }
CAMLprim value displayGlobalProgress(value v) { (void)v; return Val_unit; }
CAMLprim value bridgeThreadWait(value v) { (void)v; return Val_unit; }
CAMLprim value displayStatus(value v) { (void)v; return Val_unit; }
CAMLprim value fatalError(value v) { (void)v; return Val_unit; }
CAMLprim value warnPanel(value v) { (void)v; return Val_false; }
CAMLprim value reloadTable(value v) { (void)v; return Val_unit; }
CAMLprim value unisonInit1Complete(value v) { (void)v; return Val_unit; }
CAMLprim value unisonInit2Complete(value v) { (void)v; return Val_unit; }
CAMLprim value displayDiff(value a, value b) { (void)a; (void)b; return Val_unit; }
CAMLprim value displayDiffErr(value v) { (void)v; return Val_unit; }
CAMLprim value syncComplete(value v) { (void)v; return Val_unit; }
