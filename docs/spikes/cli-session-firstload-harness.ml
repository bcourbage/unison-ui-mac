(* Fresh-process tests of the launch command-line handling (patches 0008/0009).
   The hosted XCTest cannot exercise these: it cannot control Sys.argv and its
   `firstTime` was already consumed by an earlier test. Each invocation of this
   harness is a FRESH process (firstTime = true) with a controlled argv.

   Modes (env SESS):
   - extract: print the SESSION-scoped options extracted from this process's own
     command line (Prefs.commandLineSessionArgs over Sys.argv, patch 0009), each
     token bracketed so order/whitespace/option-like values are unambiguous.
   - applyeq: extract the session options, then apply them to profile $UPROFILE
     through the engine's own parser (parseCmdLineArgs, patch 0007), and print the
     resulting paths bracketed. Proves extraction -> application, including
     profile precedence and list accumulation.
   - none / empty / <vector>: drive the REAL do_unisonInit1 first-load contract
     (patch 0008): sessionArgs None / Some [] / Some vector; print Globals.paths.

   $UPROFILE names a local profile in $UNISON. *)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)
let bracket xs = String.concat "" (List.map (fun x -> "[" ^ x ^ "]") xs)

let () =
  let prof = try Sys.getenv "UPROFILE" with Not_found -> "" in
  match (try Sys.getenv "SESS" with Not_found -> "none") with
  | "extract" ->
    (try
       let a = Array.to_list (Prefs.commandLineSessionArgs (Sys.argv)) in
       Printf.printf "%s\n" (bracket a)
     with e -> Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3)
  | "applyeq" ->
    (try
       let a = Prefs.commandLineSessionArgs (Sys.argv) in
       Prefs.resetToDefaults (); Prefs.profileName := Some prof; Prefs.loadTheFile ();
       Prefs.parseCmdLineArgs "usage" a;
       Printf.printf "%s\n" (bracket (paths ()))
     with e -> Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3)
  (* The independent baseline (extract+apply vs the UNMODIFIED upstream
     parseCmdLine) is a CROSS-BINARY comparison — see
     docs/spikes/run-cli-session-baseline.sh — because an in-binary check would
     run both sides through the patched parser. *)
  | sess ->
    (match sess with
     | "none" -> ()
     | "empty" -> Uimacbridge.unisonSetSessionArgs [||]
     | s -> Uimacbridge.unisonSetSessionArgs (Array.of_list (String.split_on_char ' ' s)));
    (try ignore (Uimacbridge.do_unisonInit1 prof)
     with e -> Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3);
    Printf.printf "%s\n" (String.concat ";" (paths ()))
