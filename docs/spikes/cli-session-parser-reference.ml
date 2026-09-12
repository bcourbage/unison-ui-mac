(* Independent reference for the parser-variant experiment.
   See docs/cli-session-parser-report.md.

   This program uses ONLY the historical upstream parser, Prefs.parseCmdLine.
   Built from a pristine worktree (no patch) it is the ground truth. Built from
   the patched worktree it exercises the refactored `parse`, so the runner can
   compare the two for behavior fidelity (exit status, stdout, stderr) on the
   error paths, not just successful parses.

   Behavior:
   - On valid input: reset, optionally load profile $UPROFILE, run parseCmdLine
     on the process arguments, then print one canonical pref-state line to
     stdout and exit 0.
   - On invalid input: parseCmdLine itself prints to stderr and exits (2 or 37).
     That exit/stdout/stderr IS the upstream behavior under comparison; this
     program does not intercept it.

   Both binaries are invoked under the SAME argv0 (./parserbin) so the
   program-name token in upstream's error messages is identical on both sides. *)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)

let read_dump name =                       (* scalar readback for prefs w/o accessor *)
  let tmp = Filename.temp_file "ref" ".txt" in
  let fd = Unix.openfile tmp [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr; Unix.close fd;
  Prefs.dumpPrefsToStderr (); flush stderr;
  Unix.dup2 saved Unix.stderr; Unix.close saved;
  let ic = open_in tmp in let r = ref "<none>" in
  (try while true do
     let l = input_line ic in
     match String.index_opt l '=' with
     | Some i -> if String.trim (String.sub l 0 i) = name
                 then r := String.trim (String.sub l (i+1) (String.length l-i-1))
     | None -> () done with End_of_file -> ());
  close_in ic; Sys.remove tmp; !r

let () =
  Prefs.resetToDefaults ();
  (match Sys.getenv_opt "UPROFILE" with
   | Some p when p <> "" -> Prefs.profileName := Some p; Prefs.loadTheFile ()
   | _ -> ());
  Prefs.parseCmdLine "usage";     (* historical parser; exits/prints on error *)
  Printf.printf "path=[%s] batch=%b confirmBigDeletes=%b maxerrors=%s fastcheck=%s\n"
    (String.concat ";" (paths ())) (Prefs.read Globals.batch)
    (Prefs.read Globals.confirmBigDeletes) (read_dump "maxerrors") (read_dump "fastcheck")
