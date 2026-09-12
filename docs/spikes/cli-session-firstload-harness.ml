(* Fresh-process test of do_unisonInit1's FIRST-LOAD override contract (patch
   0008). The hosted XCTest cannot exercise this: it cannot control Sys.argv and
   its `firstTime` was already consumed by an earlier test. Each invocation of
   this harness is a FRESH process (firstTime = true) with a controlled argv.

   It calls the REAL Uimacbridge.do_unisonInit1 on a LOCAL profile (so no
   connection is opened) and prints the resulting Globals.paths. The process's
   own argv carries `-path <ArgvPath>` that the legacy first-load parse would
   pick up; the SESS env selects the sessionArgs mode:

     SESS=none                 -> leave sessionArgs = None  (legacy parse runs)
     SESS=empty                -> unisonSetSessionArgs [||] (Some []; suppresses)
     SESS="-path <SessionPath>"-> unisonSetSessionArgs vector (Some v; applied)

   The runner asserts:
     none  -> paths contains the ArgvPath          (legacy honored)
     empty -> paths is the profile's only (no Argv) (process argv suppressed)
     Some v-> paths is the SessionPath (no Argv)     (session applied, legacy off)

   $UPROFILE names the local profile in $UNISON. *)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)

let () =
  let prof = try Sys.getenv "UPROFILE" with Not_found -> "" in
  (match Sys.getenv_opt "SESS" with
   | None | Some "none" -> ()                                   (* sessionArgs stays None *)
   | Some "empty" -> Uimacbridge.unisonSetSessionArgs [||]
   | Some s -> Uimacbridge.unisonSetSessionArgs (Array.of_list (String.split_on_char ' ' s)))
  ;
  (try ignore (Uimacbridge.do_unisonInit1 prof)
   with e ->
     Printf.printf "RAISED %s\n" (Printexc.to_string e); exit 3);
  Printf.printf "%s\n" (String.concat ";" (paths ()))
