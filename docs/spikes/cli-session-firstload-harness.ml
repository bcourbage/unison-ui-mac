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
  | "baseline" ->
    (* Independent baseline: (loadTheFile + parseCmdLineArgs extracted) must equal
       (loadTheFile + the ORIGINAL parseCmdLine over the same Sys.argv). Uses the
       unmodified upstream parser as the reference, not asserted constants. The
       argv here carries only session options (no profile/-ui), so parseCmdLine
       sees no anonymous argument. *)
    (try
       Prefs.resetToDefaults (); Prefs.profileName := Some prof; Prefs.loadTheFile ();
       Prefs.parseCmdLine "usage";
       let refp = paths () in
       let extracted = Prefs.commandLineSessionArgs (Sys.argv) in
       Prefs.resetToDefaults (); Prefs.profileName := Some prof; Prefs.loadTheFile ();
       Prefs.parseCmdLineArgs "usage" extracted;
       let newp = paths () in
       Printf.printf "REF=%s NEW=%s EQ=%b\n" (bracket refp) (bracket newp) (refp = newp)
     with e -> Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3)
  | sess ->
    (match sess with
     | "none" -> ()
     | "empty" -> Uimacbridge.unisonSetSessionArgs [||]
     | s -> Uimacbridge.unisonSetSessionArgs (Array.of_list (String.split_on_char ' ' s)));
    (try ignore (Uimacbridge.do_unisonInit1 prof)
     with e -> Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3);
    Printf.printf "%s\n" (String.concat ";" (paths ()))
