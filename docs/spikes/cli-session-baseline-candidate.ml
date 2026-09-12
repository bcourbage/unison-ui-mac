(* Independent baseline CANDIDATE: the fork path. Built from the PATCHED worktree
   (0002-0009). Extracts this launch's session options with Prefs.commandLineSessionArgs
   (patch 0009) and applies them with Prefs.parseCmdLineArgs (patch 0007), then
   prints Globals.paths (each bracketed). The runner compares this, ACROSS
   BINARIES, against the pristine upstream reference on the same argv + profile. *)
let bracket xs = String.concat "" (List.map (fun x -> "[" ^ x ^ "]") xs)
let () =
  let prof = try Sys.getenv "UPROFILE" with Not_found -> "" in
  let extracted = Prefs.commandLineSessionArgs (Sys.argv) in
  Prefs.resetToDefaults ();
  Prefs.profileName := Some prof;
  Prefs.loadTheFile ();
  Prefs.parseCmdLineArgs "usage" extracted;
  Printf.printf "%s\n" (bracket (Safelist.map Path.toString (Prefs.read Globals.paths)))
