(* prototype3: the parser-variant half of docs/cli-session-requests-design.md.

   Where prototype2 tested an app-owned Prefs.loadStrings adapter (and found it
   cannot translate -path/CUSTOM or preserve whitespace), this drives a small,
   backward-compatible extension of the engine's OWN command-line parser:
     Uarg.parseArgv  (parse an explicit vector, raise instead of exit)
     Prefs.parseCmdLineArgs  (the session-request counterpart of parseCmdLine)
   and compares it, on the same option words, against the upstream baseline
   Prefs.parseCmdLine (which reads a fixed Sys.argv). The claim under test: the
   variant is behaviorally identical to upstream for the options, differing only
   in plumbing (explicit vector + raise vs. Sys.argv + exit). Asserts and exits
   non-zero on any surprise. Not a production integration: it does not connect. *)

let failures = ref 0
let check name cond detail =
  if cond then Printf.printf "  PASS  %-46s %s\n" name detail
  else (incr failures; Printf.printf "  FAIL  %-46s %s\n" name detail)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)
let pathstr () = "[" ^ String.concat "; " (paths ()) ^ "]"

let read_dump name =                       (* scalar readback for prefs w/o accessor *)
  let tmp = Filename.temp_file "proto" ".txt" in
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

(* baseline: upstream's own parser on the process's fixed Sys.argv *)
let baseline () = Prefs.resetToDefaults (); Prefs.parseCmdLine "usage"
(* variant: the SAME parser fed an explicit per-session vector, raising on error *)
let variant args = Prefs.resetToDefaults (); Prefs.parseCmdLineArgs "usage" (Array.of_list args)

(* full-session load at the do_unisonInit1 insertion point:
   reset -> loadTheFile -> apply session overrides (pre-connect) *)
let load profile args =
  Prefs.resetToDefaults (); Prefs.profileName := Some profile;
  Prefs.loadTheFile (); Prefs.parseCmdLineArgs "usage" (Array.of_list args)

let () =
  let expect = try Sys.getenv "EXPECT" with Not_found -> "match" in
  let args = match Array.to_list Sys.argv with _ :: t -> t | [] -> [] in
  Printf.printf "=== prototype3 EXPECT=%s argv=[%s] ===\n" expect (String.concat " " args);

  (match expect with
   | "match" ->
     (* scalar/bool/alias/BOOLDEF: variant must equal upstream baseline *)
     baseline ();
     let b_batch = Prefs.read Globals.batch and b_cbd = Prefs.read Globals.confirmBigDeletes
     and b_maxerr = read_dump "maxerrors" and b_fast = read_dump "fastcheck" in
     Printf.printf "  baseline(parseCmdLine): batch=%b confirmBigDeletes=%b maxerrors=%s fastcheck=%s\n"
       b_batch b_cbd b_maxerr b_fast;
     variant args;
     Printf.printf "  variant(parseCmdLineArgs): batch=%b confirmBigDeletes=%b maxerrors=%s fastcheck=%s\n"
       (Prefs.read Globals.batch) (Prefs.read Globals.confirmBigDeletes) (read_dump "maxerrors") (read_dump "fastcheck");
     check "boolean matches upstream baseline" (Prefs.read Globals.batch = b_batch) (string_of_bool b_batch);
     check "alias set OPPOSITE its default (proves effect)" (Prefs.read Globals.confirmBigDeletes = false && b_cbd = false) (string_of_bool b_cbd);
     check "scalar (maxerrors) matches upstream baseline" (read_dump "maxerrors" = b_maxerr && b_maxerr = "5") b_maxerr;
     check "BOOLDEF (fastcheck=default) matches upstream baseline" (read_dump "fastcheck" = b_fast && b_fast = "default") b_fast

   | "path-custom" ->
     (* the headline: -path is Prefs.typ=CUSTOM, which the loadStrings translator
        could not carry. The engine's own parser knows its arity, so the variant
        applies it exactly as the baseline does. *)
     baseline (); let b = paths () in
     Printf.printf "  baseline(parseCmdLine -path): %s\n" (pathstr ());
     variant args; let v = paths () in
     Printf.printf "  variant(parseCmdLineArgs -path): %s\n" (pathstr ());
     check "variant applies -path (CUSTOM), unlike the loadStrings translator" (v = ["Documents"]) (String.concat "," v);
     check "variant matches upstream baseline for -path" (v = b) (String.concat "," v)

   | "repeated-list" ->
     (* list accumulation and precedence must match upstream, not replace *)
     baseline (); let b = paths () in
     Printf.printf "  baseline(parseCmdLine -path A -path B): %s\n" (pathstr ());
     variant args; let v = paths () in
     Printf.printf "  variant(parseCmdLineArgs -path A -path B): %s\n" (pathstr ());
     check "repeated list accumulates [A; B]" (v = ["A"; "B"]) (String.concat "," v);
     check "variant matches upstream baseline for repeated -path" (v = b) (String.concat "," v)

   | "whitespace" ->
     (* loadStrings trimmed leading/trailing whitespace the CLI preserves; the
        parser variant, being the CLI parser, preserves it and matches. *)
     baseline (); let b = paths () in
     Printf.printf "  baseline(parseCmdLine '-path   ws  '): %s\n" (pathstr ());
     variant args; let v = paths () in
     Printf.printf "  variant(parseCmdLineArgs '-path   ws  '): %s\n" (pathstr ());
     check "variant preserves whitespace, matches upstream baseline" (v = b && v = ["  ws  "]) (Printf.sprintf "[%s]" (String.concat "," v))

   | "invalid" ->
     (* bad input RAISES Util.Fatal, never exits (upstream parseCmdLine would exit) *)
     let raised = (try variant args; false with Util.Fatal _ -> true) in
     check "invalid argument raises Util.Fatal, no exit" raised "(-maxerrors notanint)";
     (* recovered state is demonstrably clean: a following valid session is unaffected *)
     variant ["-batch"];
     check "next session clean after a raised failure" (paths () = []) (pathstr ())

   | _ -> ());

  if expect = "match" then begin
    Printf.printf "\nB. Reset isolation (A -> reload A -> B), each session independent:\n";
    load "A" ["-path"; "Documents"]; let a = paths () in
    load "A" []; let a2 = paths () in
    load "B" []; let b = paths () in
    check "A scoped to Documents" (a = ["Documents"]) (String.concat "," a);
    check "reload A with no overrides drops the scope" (a2 = []) (String.concat "," a2);
    check "B clean, no leak from A" (b = ["Preset"]) (String.concat "," b);

    Printf.printf "\nC. Later request with different overrides uses only its own:\n";
    load "A" ["-path"; "Documents"]; let _ = paths () in
    load "A" ["-path"; "Projects"]; let p2 = paths () in
    check "second request carries only its own -path" (p2 = ["Projects"]) (String.concat "," p2);

    Printf.printf "\nD. Failure isolation (partial apply then reset):\n";
    (try load "A" ["-path"; "Documents"; "-maxerrors"; "notanint"] with Util.Fatal _ -> ());
    load "B" []; check "next session clean after partial-apply failure" (paths () = ["Preset"]) (String.concat "," (paths ()));
    Printf.printf "    LIMIT: proves the NEXT load resets clean; it does NOT by itself prove a\n";
    Printf.printf "           scan/connection is prevented on the failed session (an app control-flow\n";
    Printf.printf "           guarantee the design requires around this parser call).\n";

    Printf.printf "\nE. Lifecycle insertion point (parser applies after loadTheFile, before connect):\n";
    Prefs.resetToDefaults (); Prefs.profileName := Some "A"; Prefs.loadTheFile ();
    Prefs.parseCmdLineArgs "usage" [| "-servercmd"; "/session/unison" |];
    check "servercmd applied at the pre-connection point" (read_dump "servercmd" = "/session/unison") (read_dump "servercmd");
    Printf.printf "    This is where do_unisonInit1 must call it: after loadTheFile, before\n";
    Printf.printf "    openConnectionStart. That call site is an upstream source edit (uimacbridge.ml),\n";
    Printf.printf "    the same lifecycle edit either engine approach needs; it is NOT a parser patch.\n";

    Printf.printf "\nF. Full-CLI surface note (a real difference from the loadStrings adapter):\n";
    let accepted = (try Prefs.resetToDefaults (); Prefs.parseCmdLineArgs "usage" [| "-dumparchives" |]; true with Util.Fatal _ -> false) in
    check "parser variant ACCEPTS cli_only options (loadStrings rejected them)" accepted "(-dumparchives)";
    Printf.printf "    The parser accepts the whole command-line surface, including process-role\n";
    Printf.printf "    options (-server, -ui, -doc, cli_only). The design routes those at the app\n";
    Printf.printf "    layer before a session apply; the engine parser does not gate them.\n"
  end;

  Printf.printf "\n=== %s (%d failure(s)) ===\n" (if !failures = 0 then "PASS" else "FAIL") !failures;
  exit (if !failures = 0 then 0 else 1)
