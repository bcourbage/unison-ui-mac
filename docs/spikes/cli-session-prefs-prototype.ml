(* Bounded engine prototype for docs/cli-session-requests-design.md.
   Proves the session-scoped option boundary using an app-owned adapter over
   EXISTING OCaml APIs (Prefs.resetToDefaults / loadTheFile / loadStrings), with
   no change to the engine's own command-line parser. Not wired to UI or socket. *)

let p fmt = Printf.printf fmt

let paths () =
  String.concat "; " (Safelist.map Path.toString (Prefs.read Globals.paths))

let flags () =
  Printf.sprintf "batch=%b confirmBigDeletes=%b"
    (Prefs.read Globals.batch) (Prefs.read Globals.confirmBigDeletes)

(* One session load through the adapter: reset to a clean state, load the
   profile, then apply this session's explicit overrides. *)
let load profile overrides =
  Prefs.resetToDefaults ();
  Prefs.profileName := Some profile;
  Prefs.loadTheFile ();
  Prefs.loadStrings overrides

let attempt label profile overrides =
  (try
     load profile overrides;
     p "  OK             %-32s path=[%s]  %s\n" label (paths ()) (flags ())
   with
   | Util.Fatal m -> p "  RAISED(caught) %-32s %s\n" label (String.trim m))

let () =
  p "=== session-scoped option adapter (Prefs.loadStrings), no engine-source patch ===\n";

  p "\n1. Session A with -path Documents (A configures no path):\n";
  attempt "A + path=Documents" "A" ["path = Documents"];

  p "\n2. Reload A with the same overrides (in-place / reconnect):\n";
  attempt "A reload + path=Documents" "A" ["path = Documents"];

  p "\n3. Session B, no overrides -- A must not leak (B configures path=Preset):\n";
  attempt "B (no overrides)" "B" [];

  p "\n4. Session B + -path Other -- list ACCUMULATES onto the profile path:\n";
  attempt "B + path=Other" "B" ["path = Other"];

  p "\n5. Scalar + boolean + alias overrides (maxerrors, batch, confirmbigdeletes):\n";
  attempt "A +maxerrors +batch +alias=false" "A" ["maxerrors = 5"; "batch = true"; "confirmbigdeletes = false"];

  p "\n6. Invalid value must RAISE (catchable), never exit the process:\n";
  attempt "A + batch=notabool" "A" ["batch = notabool"];
  p "  ...process is still running after invalid input.\n";

  p "\n7. A command-line-only option is rejected by the adapter:\n";
  attempt "A +dumparchives (cli_only)" "A" ["dumparchives = true"];

  p "\n8. Failure isolation: partial apply then failure; the NEXT session is clean:\n";
  attempt "A + path=Documents + bad" "A" ["path = Documents"; "batch = notabool"];
  p "  next session B (no overrides) must NOT inherit path=Documents:\n";
  attempt "B after failure" "B" [];

  p "\n9. -path stays root-relative (never rewritten against cwd=%s):\n" (Sys.getcwd ());
  attempt "A + path=Documents (check literal)" "A" ["path = Documents"];

  p "\n=== done ===\n"
