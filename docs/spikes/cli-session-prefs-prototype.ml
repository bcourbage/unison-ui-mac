(* prototype2: rigorous evidence for docs/cli-session-requests-design.md.
   A real CLI-args -> preference translation compared, on the same argv, against
   the engine's OWN parser (Prefs.parseCmdLine). Asserts and exits non-zero on
   any surprise. Modes are selected by EXPECT (parseCmdLine reads a fixed argv, so
   each argv needs its own process). Not a production integration: it does not
   connect. It establishes the boundary and its limits. *)

let failures = ref 0
let check name cond detail =
  if cond then Printf.printf "  PASS  %-42s %s\n" name detail
  else (incr failures; Printf.printf "  FAIL  %-42s %s\n" name detail)

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

(* CLI-args -> profile-line translator, using only the engine's public arity
   (Prefs.typ) and alias table (Prefs.canonicalName). BOOL is a bare flag;
   BOOLDEF (createBoolWithDefault, e.g. -fastcheck default) takes a value, like
   INT/STRING/STRING_LIST. CUSTOM/UNKNOWN arity is unknown, so it refuses. *)
let translate (args : string list) : string list =
  let rec go acc = function
    | [] -> Safelist.rev acc
    | a :: rest when String.length a > 1 && a.[0] = '-' ->
      let body = String.sub a 1 (String.length a - 1) in
      (match String.index_opt body '=' with
       | Some i -> go ((String.sub body 0 i ^ " = " ^ String.sub body (i+1) (String.length body-i-1)) :: acc) rest
       | None ->
         (match Prefs.typ (Prefs.canonicalName body) with
          | `BOOL -> go ((body ^ " = true") :: acc) rest                 (* bare flag *)
          | `BOOLDEF | `INT | `STRING | `STRING_LIST ->                  (* takes a value *)
            (match rest with v :: r -> go ((body ^ " = " ^ v) :: acc) r
                           | [] -> failwith ("missing value for -" ^ body))
          | `CUSTOM | `UNKNOWN -> failwith ("cannot determine arity of -" ^ body ^ " (Prefs.typ = CUSTOM/UNKNOWN)")))
    | a :: _ -> failwith ("anonymous argument, not an override: " ^ a)
  in go [] args

let load profile overrides =
  Prefs.resetToDefaults (); Prefs.profileName := Some profile;
  Prefs.loadTheFile (); Prefs.loadStrings overrides

let () =
  let expect = try Sys.getenv "EXPECT" with Not_found -> "match" in
  let args = match Array.to_list Sys.argv with _ :: t -> t | [] -> [] in
  Printf.printf "=== prototype2 EXPECT=%s argv=[%s] ===\n" expect (String.concat " " args);

  Prefs.resetToDefaults (); Prefs.parseCmdLine "usage";     (* engine's own parser, baseline *)
  let b_paths = paths () and b_batch = Prefs.read Globals.batch
  and b_cbd = Prefs.read Globals.confirmBigDeletes and b_maxerr = read_dump "maxerrors"
  and b_fast = read_dump "fastcheck" in
  Printf.printf "  baseline(parseCmdLine): path=%s batch=%b confirmBigDeletes=%b maxerrors=%s fastcheck=%s\n"
    (pathstr ()) b_batch b_cbd b_maxerr b_fast;

  (match expect with
   | "match" ->
     let lines = translate args in
     Printf.printf "  adapter lines: [%s]\n" (String.concat " | " lines);
     Prefs.resetToDefaults (); Prefs.loadStrings lines;
     check "boolean matches CLI baseline" (Prefs.read Globals.batch = b_batch) (string_of_bool b_batch);
     check "alias set OPPOSITE its default (proves effect)" (Prefs.read Globals.confirmBigDeletes = false && b_cbd = false) (string_of_bool b_cbd);
     check "scalar (maxerrors) matches CLI baseline" (read_dump "maxerrors" = b_maxerr) b_maxerr;
     check "BOOLDEF (fastcheck=default) matches CLI baseline" (read_dump "fastcheck" = b_fast) b_fast
   | "repeated-list" ->
     (* -path is CUSTOM so the generic translator refuses it, but loadStrings CAN
        apply repeated path values; show accumulation parity with the CLI. *)
     Prefs.resetToDefaults (); Prefs.loadStrings ["path = A"; "path = B"];
     let a_paths = paths () in
     Printf.printf "  adapter(loadStrings path=A; path=B): path=%s\n" (pathstr ());
     check "repeated list accumulates, matches CLI baseline" (b_paths = a_paths && b_paths = ["A"; "B"]) (String.concat "," a_paths)
   | "path-custom" ->
     let raised = (try ignore (translate args); false with Failure _ -> true) in
     check "-path is CUSTOM: generic TRANSLATOR refuses" raised "(loadStrings itself CAN apply a path value; see repeated-list)";
     check "CLI baseline still applied -path" (b_paths = ["Documents"]) (String.concat "," b_paths)
   | "whitespace" ->
     Prefs.resetToDefaults (); Prefs.loadStrings ["path =   ws  "];
     let a_paths = paths () in
     Printf.printf "  adapter(loadStrings 'path =   ws  '): path=%s\n" (pathstr ());
     check "CLI keeps whitespace, loadStrings trims (DIFFER)" (b_paths <> a_paths)
       (Printf.sprintf "CLI=%s vs adapter=%s" (String.concat "," b_paths) (String.concat "," a_paths))
   | _ -> ());

  if expect = "match" then begin
    Printf.printf "\nB. Reset isolation:\n";
    load "A" ["path = Documents"]; let a = paths () in
    load "B" []; let b = paths () in
    check "A scoped to Documents" (a = ["Documents"]) (String.concat "," a);
    check "B clean, no leak" (b = ["Preset"]) (String.concat "," b);

    Printf.printf "\nC. Invalid override raises, no exit:\n";
    check "invalid raised Util.Fatal" (try load "A" ["batch = notabool"]; false with Util.Fatal _ -> true) "";

    Printf.printf "\nD. cli_only rejected:\n";
    check "dumparchives (cli_only) rejected" (try load "A" ["dumparchives = true"]; false with Util.Fatal _ -> true) "";

    Printf.printf "\nE. Failure isolation (reset-before-next only):\n";
    (try load "A" ["path = Documents"; "batch = notabool"] with Util.Fatal _ -> ());
    load "B" []; check "next session clean after partial-apply failure" (paths () = ["Preset"]) (String.concat "," (paths ()));
    Printf.printf "    LIMIT: proves the NEXT load resets clean; it does NOT prove a scan/connection\n";
    Printf.printf "           is prevented on the failed session (an app control-flow guarantee).\n";

    Printf.printf "\nF. Preference assignment at the pre-connection point (NOT a production integration):\n";
    Prefs.resetToDefaults (); Prefs.profileName := Some "A"; Prefs.loadTheFile ();
    Prefs.loadStrings ["servercmd = /session/unison"];
    check "servercmd set after loadTheFile" (read_dump "servercmd" = "/session/unison") (read_dump "servercmd");
    Printf.printf "    This is a preference assignment plus source inspection, not a demonstrated\n";
    Printf.printf "    production lifecycle. Source inspection: the CURRENT do_unisonInit1 has no hook\n";
    Printf.printf "    between loadTheFile and openConnectionStart. It does not prove every app-owned\n";
    Printf.printf "    replacement entry needs a source edit; a replacement would duplicate that\n";
    Printf.printf "    lifecycle, which may be less maintainable than a small patch.\n"
  end;

  Printf.printf "\n=== %s (%d failure(s)) ===\n" (if !failures = 0 then "PASS" else "FAIL") !failures;
  exit (if !failures = 0 then 0 else 1)
