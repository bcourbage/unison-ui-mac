(* The parser variant under test, for docs/cli-session-requests-design.md.
   Built only from the patched worktree; it drives the new entry point
   Prefs.parseCmdLineArgs (an explicit per-session vector, raising Util.Fatal
   instead of exiting).

   Modes (env EXPECT):
   - dump (default): reset, optionally load profile $UPROFILE, apply the process
     arguments via parseCmdLineArgs, print the SAME canonical pref-state line as
     the reference program, exit 0. The runner compares this line, argument for
     argument, against the UNPATCHED reference's parseCmdLine output. Fed only
     valid input.
   - invalid: assert parseCmdLineArgs RAISES Util.Fatal on bad input (no exit),
     that the option preceding the failure took effect, and that recovery is
     clean.
   - matrix: the session-lifetime assertions (reload with the same overrides,
     later request, CLI-versus-profile precedence, partial-application). Asserts
     and exits non-zero on any failure. Not a production integration: no connect. *)

let failures = ref 0
let check name cond detail =
  if cond then Printf.printf "  PASS  %-52s %s\n" name detail
  else (incr failures; Printf.printf "  FAIL  %-52s %s\n" name detail)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)
let pstr () = String.concat ";" (paths ())

let read_dump name =
  let tmp = Filename.temp_file "var" ".txt" in
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

(* full-session load at the do_unisonInit1 insertion point: reset -> loadTheFile
   -> apply this session's overrides (pre-connect). *)
let load profile args =
  Prefs.resetToDefaults (); Prefs.profileName := Some profile;
  Prefs.loadTheFile (); Prefs.parseCmdLineArgs "usage" (Array.of_list args)

let () =
  let expect = try Sys.getenv "EXPECT" with Not_found -> "dump" in
  let args = match Array.to_list Sys.argv with _ :: t -> t | [] -> [] in

  match expect with
  | "dump" ->
    Prefs.resetToDefaults ();
    (match Sys.getenv_opt "UPROFILE" with
     | Some p when p <> "" -> Prefs.profileName := Some p; Prefs.loadTheFile ()
     | _ -> ());
    Prefs.parseCmdLineArgs "usage" (Array.of_list args);
    Printf.printf "path=[%s] batch=%b confirmBigDeletes=%b maxerrors=%s fastcheck=%s\n"
      (pstr ()) (Prefs.read Globals.batch) (Prefs.read Globals.confirmBigDeletes)
      (read_dump "maxerrors") (read_dump "fastcheck")

  | "invalid" ->
    Printf.printf "=== variant EXPECT=invalid ===\n";
    (* bad input RAISES Util.Fatal (no exit); the option BEFORE the failure took
       effect (partial application is real); recovery resets clean. *)
    Prefs.resetToDefaults ();
    let raised = ref false and partial = ref "<unset>" in
    (try Prefs.parseCmdLineArgs "usage" [| "-path"; "Documents"; "-maxerrors"; "notanint" |]
     with Util.Fatal _ -> raised := true; partial := pstr ());
    check "invalid argument raises Util.Fatal, no exit" !raised "(-maxerrors notanint)";
    check "the option preceding the failure took effect" (!partial = "Documents") (Printf.sprintf "path=[%s] at raise" !partial);
    load "B" []; check "recovery: next session clean after failure" (paths () = ["Preset"]) (pstr ());
    Printf.printf "  LIMIT: proves the NEXT load resets clean; preventing a scan/connection on the\n";
    Printf.printf "         failed session is an app control-flow guarantee for later integration.\n";
    Printf.printf "=== %s (%d failure(s)) ===\n" (if !failures = 0 then "PASS" else "FAIL") !failures;
    exit (if !failures = 0 then 0 else 1)

  | "matrix" ->
    Printf.printf "=== variant EXPECT=matrix ===\n";
    (* A.prf: no path.  B.prf: path=Preset.  Pprec.prf: path=ProfA / path=ProfB. *)

    Printf.printf "A. Reload with the SAME overrides preserves scope, no accumulation:\n";
    load "A" ["-path"; "Documents"]; let a1 = pstr () in
    load "A" ["-path"; "Documents"]; let a2 = pstr () in
    check "first load scopes A to Documents" (a1 = "Documents") a1;
    check "reload A with the same -path is still [Documents]" (a2 = "Documents") a2;

    Printf.printf "B. A later request uses only its own overrides:\n";
    load "A" ["-path"; "Documents"];
    load "A" ["-path"; "Projects"]; let p2 = pstr () in
    check "second request carries only its own -path" (p2 = "Projects") p2;

    Printf.printf "C. CLI-versus-profile precedence (profile has paths):\n";
    load "Pprec" []; let prof = pstr () in
    load "Pprec" ["-path"; "CliX"]; let combined = pstr () in
    check "profile-only load yields the profile's paths" (prof = "ProfA;ProfB") prof;
    check "CLI -path accumulates onto profile paths (not replace)" (combined = "ProfA;ProfB;CliX") combined;

    Printf.printf "D. Partial application then recovery:\n";
    Prefs.resetToDefaults ();
    let raised = ref false and partial = ref "<unset>" in
    (try Prefs.parseCmdLineArgs "usage" [| "-path"; "Documents"; "-maxerrors"; "notanint" |]
     with Util.Fatal _ -> raised := true; partial := pstr ());
    check "partial-apply raised Util.Fatal" !raised "";
    check "the preceding -path took effect before the failure" (!partial = "Documents") (Printf.sprintf "path=[%s]" !partial);
    load "B" []; check "next session clean after partial-apply failure" (paths () = ["Preset"]) (pstr ());

    Printf.printf "=== %s (%d failure(s)) ===\n" (if !failures = 0 then "PASS" else "FAIL") !failures;
    exit (if !failures = 0 then 0 else 1)

  | _ -> prerr_endline "unknown EXPECT"; exit 2
