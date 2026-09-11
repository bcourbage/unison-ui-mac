(* prototype2: rigorous evidence for docs/cli-session-requests-design.md.
   Over prototype v1: explicit assertions with a nonzero exit; a real
   CLI-args -> preference translation compared against the engine's OWN parser
   (Prefs.parseCmdLine on the process argv); scalar readback; and the lifecycle
   point where overrides must land. Modes are selected by the EXPECT env var, so
   one binary is run several times with different argv (parseCmdLine reads the
   fixed Sys.argv, so each argv needs its own process).

   Not a production integration: it does not connect. It establishes the boundary
   and, honestly, its limits. *)

let failures = ref 0
let check name cond detail =
  if cond then Printf.printf "  PASS  %-40s %s\n" name detail
  else (incr failures; Printf.printf "  FAIL  %-40s %s\n" name detail)

let paths () = Safelist.map Path.toString (Prefs.read Globals.paths)
let pathstr () = "[" ^ String.concat "; " (paths ()) ^ "]"

(* Scalar readback via Prefs.dumpPrefsToStderr (for prefs with no exposed
   accessor, e.g. maxerrors). Trims, so only used for values without whitespace. *)
let read_dump name =
  let tmp = Filename.temp_file "proto" ".txt" in
  let fd = Unix.openfile tmp [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr; Unix.close fd;
  Prefs.dumpPrefsToStderr (); flush stderr;
  Unix.dup2 saved Unix.stderr; Unix.close saved;
  let ic = open_in tmp in
  let result = ref "<none>" in
  (try while true do
     let line = input_line ic in
     match String.index_opt line '=' with
     | Some i -> if String.trim (String.sub line 0 i) = name
                 then result := String.trim (String.sub line (i+1) (String.length line - i - 1))
     | None -> ()
   done with End_of_file -> ());
  close_in ic; Sys.remove tmp; !result

(* Bounded CLI-args -> profile-line translator, using ONLY the engine's public
   arity query (Prefs.typ) and alias table (Prefs.canonicalName). Raises rather
   than guessing when it cannot determine arity. *)
let translate (args : string list) : string list =
  let rec go acc = function
    | [] -> Safelist.rev acc
    | a :: rest when String.length a > 1 && a.[0] = '-' ->
      let body = String.sub a 1 (String.length a - 1) in
      (match String.index_opt body '=' with
       | Some i -> go ((String.sub body 0 i ^ " = " ^ String.sub body (i+1) (String.length body-i-1)) :: acc) rest
       | None ->
         (match Prefs.typ (Prefs.canonicalName body) with
          | `BOOL | `BOOLDEF -> go ((body ^ " = true") :: acc) rest
          | `INT | `STRING | `STRING_LIST ->
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

  (* Baseline: the engine's real command-line parser on the process argv. *)
  Prefs.resetToDefaults (); Prefs.parseCmdLine "usage";
  let b_paths = paths () and b_batch = Prefs.read Globals.batch
  and b_cbd = Prefs.read Globals.confirmBigDeletes and b_maxerr = read_dump "maxerrors" in
  Printf.printf "  baseline(parseCmdLine): path=%s batch=%b confirmBigDeletes=%b maxerrors=%s\n"
    (pathstr ()) b_batch b_cbd b_maxerr;

  (match expect with
   | "match" ->
     (* Translatable options only: bool, alias(bool), int. Adapter must equal baseline. *)
     let lines = translate args in
     Printf.printf "  adapter lines: [%s]\n" (String.concat " | " lines);
     Prefs.resetToDefaults (); Prefs.loadStrings lines;
     check "boolean matches CLI baseline" (Prefs.read Globals.batch = b_batch) (string_of_bool b_batch);
     check "alias matches CLI baseline" (Prefs.read Globals.confirmBigDeletes = b_cbd) (string_of_bool b_cbd);
     check "scalar (maxerrors) matches CLI baseline" (read_dump "maxerrors" = b_maxerr) b_maxerr
   | "path-custom" ->
     (* -path is a CUSTOM pref: the generic translator cannot handle it. *)
     let raised = (try ignore (translate args); false with Failure _ -> true) in
     check "-path is CUSTOM: generic translate refuses" raised
       "(engine's own parser handled it in the baseline above)";
     check "CLI baseline still applied -path" (b_paths = ["Documents"]) (String.concat "," b_paths)
   | "whitespace" ->
     (* CLI keeps whitespace; the profile parser (loadStrings) trims. Apply the
        SAME value both ways (hand-built loadStrings line, since -path can't be
        generically translated) and show they differ. *)
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
    check "process alive" true "";

    Printf.printf "\nD. cli_only rejected:\n";
    check "dumparchives (cli_only) rejected" (try load "A" ["dumparchives = true"]; false with Util.Fatal _ -> true) "";

    Printf.printf "\nE. Failure isolation (reset-before-next, NOT connect/scan prevention):\n";
    (try load "A" ["path = Documents"; "batch = notabool"] with Util.Fatal _ -> ());
    load "B" []; check "next session clean after partial-apply failure" (paths () = ["Preset"]) (String.concat "," (paths ()));
    Printf.printf "    LIMIT: proves subsequent reset only; preventing a scan/connection on the\n";
    Printf.printf "           failed session is an app control-flow guarantee, not shown here.\n";

    Printf.printf "\nF. Lifecycle point (override in effect before connect):\n";
    Prefs.resetToDefaults (); Prefs.profileName := Some "A"; Prefs.loadTheFile ();
    Prefs.loadStrings ["servercmd = /session/unison"];
    check "servercmd applied after loadTheFile" (read_dump "servercmd" = "/session/unison") (read_dump "servercmd");
    Printf.printf "    LIMIT: production do_unisonInit1 does reset->loadTheFile->connect with NO hook\n";
    Printf.printf "           between; reaching this point needs a SOURCE edit to that engine function\n";
    Printf.printf "           (uimacbridge.ml), though not a parser patch.\n"
  end;

  Printf.printf "\n=== %s (%d failure(s)) ===\n" (if !failures = 0 then "PASS" else "FAIL") !failures;
  exit (if !failures = 0 then 0 else 1)
