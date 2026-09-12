(* Independent baseline REFERENCE: the UNMODIFIED upstream parser. Built from a
   PRISTINE worktree (no fork patches), so Prefs.parseCmdLine is upstream's own.
   Loads profile $UPROFILE, parses this process's command line with parseCmdLine,
   and prints Globals.paths (each bracketed). The invoking argv carries only
   session options (no profile / -ui), so parseCmdLine sees no anonymous argument.
   The runner compares this, ACROSS BINARIES, against the patched candidate. *)
let bracket xs = String.concat "" (List.map (fun x -> "[" ^ x ^ "]") xs)
let () =
  let prof = try Sys.getenv "UPROFILE" with Not_found -> "" in
  Prefs.resetToDefaults ();
  Prefs.profileName := Some prof;
  Prefs.loadTheFile ();
  Prefs.parseCmdLine "usage";
  Printf.printf "%s\n" (bracket (Safelist.map Path.toString (Prefs.read Globals.paths)))
