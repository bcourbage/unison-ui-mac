# unison-ui-mac — User Manual

A feature-by-feature guide to the macOS app. For build instructions and
architecture overview, see [README.md](README.md). For the underlying
file-synchronization concepts (profiles, roots, paths, ignore patterns,
conflict resolution, the `merge` preference, archive files), the
authoritative reference is the **upstream Unison documentation**:

- [Unison File Synchronizer wiki](https://github.com/bcpierce00/unison/wiki)
- [Unison user manual (full)](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex)
- [Preferences reference (`.prf` keys + syntax)](https://github.com/bcpierce00/unison/wiki/Manual)

This document covers **how the macOS GUI exposes those concepts** — not the
concepts themselves. When a feature touches a `.prf` preference, it's
linked to the section of the upstream docs that defines it.

---

## Table of contents

1. [Concepts in one paragraph](#concepts-in-one-paragraph)
2. [Getting started](#getting-started)
3. [The Profile Picker](#the-profile-picker)
4. [The Profile Editor (manager window)](#the-profile-editor-manager-window)
5. [The Profile Form (single-profile content editor)](#the-profile-form-single-profile-content-editor)
6. [The Reconcile window](#the-reconcile-window)
7. [The Diff viewer](#the-diff-viewer)
8. [The menu bar reference](#the-menu-bar-reference)
9. [Keyboard shortcuts](#keyboard-shortcuts)
10. [Troubleshooting](#troubleshooting)
11. [What this app does NOT do](#what-this-app-does-not-do)

---

## Concepts in one paragraph

Unison synchronizes a pair of file trees ("**replicas**") rooted at two
paths ("**roots**") — both can be local directories, or one or both can be
remote over SSH. A **profile** is a `.prf` file under
`~/Library/Application Support/Unison/` that declares the two roots plus
any preferences (paths to sync, paths to ignore, merge command, etc.).
Running a sync involves two phases: **reconcile** (Unison scans both sides
and lists the differences it found) and **propagate** (Unison applies the
decisions the user made about each difference). Between reconciles, Unison
keeps a per-replica **archive file** describing the last-known state so
the next scan can tell what's changed.

---

## Getting started

### 1. Install Unison on remote machines (SSH profiles only)

The app embeds Unison's OCaml runtime, so the local machine doesn't need a
separate `unison` install. But profiles whose second root is `ssh://…`
spawn `unison -server` on the remote host — that remote needs Unison
installed and reachable in `$PATH` (or via `servercmd = …` in the profile).

The simplest install on the remote: `brew install unison` on macOS,
`apt install unison` on Debian/Ubuntu, etc. Version match between local
and remote helps; Unison checks compatibility at handshake.

### 2. Launch the app

The app opens with the **Profile Picker** (see next section). On first
launch, if you have no profiles yet, the list will be empty — use
`Edit → Profile Editor…` (⌘⇧E) to create one.

### 3. Pick a profile, hit Run

Double-click a profile (or select it and click Run) to start reconcile.
The reconcile window opens immediately in "scanning" mode and populates
when init1+init2 complete.

---

## The Profile Picker

The launch view. A simple list of every `.prf` file in
`~/Library/Application Support/Unison/`, sorted by your custom order if
you've set one (see [Profile Editor](#the-profile-editor-manager-window)),
otherwise alphabetical. Hidden profiles (also a Profile Editor feature)
don't appear here.

**Run** (⏎ / Enter) — selects the highlighted profile and opens the
reconcile window in scanning mode.

Double-click also runs.

> The button is labeled "Run" rather than "Open" because picking a profile
> kicks off the sync workflow — same verb as the CLI `unison <profile>`.
> "Open" was the old label but was misleading: nothing here opens a
> document for editing.

### Profile creation, editing, deletion, etc.

Not on the picker — those live in the Profile Editor manager. The picker
is intentionally minimal: list + Run.

---

## The Profile Editor (manager window)

Opens via `Edit → Profile Editor…` (⌘⇧E).

A table of every profile, with three columns:

- **☰ Drag handle** — grab and drag to reorder the list. The order
  persists across app launches (stored in `UserDefaults` under
  `profiles.order`). The custom order applies to the picker too. Reorder
  is **UI-only**: the `.prf` files themselves aren't touched, and the
  CLI `unison <profile>` sees every profile in whatever order Unison's
  own profile scanner returns.
- **👁 / 👁‍🗨 Visibility toggle** — click to hide/unhide. Hidden profiles
  disappear from the picker (so you don't see profiles you only run
  rarely or have permanently retired from regular use), but remain on
  disk and remain visible in the Profile Editor. Stored in
  `UserDefaults` under `profiles.hidden`. Like reorder, it's UI-only —
  the CLI doesn't know about hidden state.
- **Profile name** — the basename of the `.prf` file. Dimmed when the
  profile is hidden.

Bottom-bar buttons (left to right by profile lifecycle):

- **New…** — opens the Profile Form with empty fields. Save creates a
  new `<name>.prf` in the Unison directory.
- **Duplicate…** — copies the selected profile's `.prf` verbatim to a
  new name. The new profile inherits everything: roots, paths, ignores,
  advanced prefs. Defaults the new name to `<original> copy`, prompts for
  the actual name. After save, the duplicate is inserted right after its
  source in the custom order.
- **Edit…** — opens the Profile Form for the selected profile. Same form
  as New, but pre-populated and with the name field pre-filled. Editing
  the name field and saving performs a rename (see Profile Form below).
- **Delete…** — confirmation alert, then moves the `.prf` (and its
  `.prf.bak` sidecar from a prior save, if any) to the Trash via
  `NSFileManager.trashItem`. A misclick is recoverable from Finder's
  Trash. Unison's archive files (`ar*`, `fp*`, `lk*`) for the profile
  are *not* touched here — use **Reset Archives…** for that.
- **Reset Archives…** — for the selected profile, compute its archive
  hash (see [archive files](https://github.com/bcpierce00/unison/wiki/FAQ#what-are-archive-files-in-unison)
  in the upstream wiki), find matching `ar<hash>`, `fp<hash>`, `lk<hash>`,
  `tm<hash>`, `sc<hash>` files in the Unison directory, and move them to
  Trash. The confirmation dialog lists exactly which files will be moved
  plus the computed hash (you can cross-check against
  `unison -showArchiveName <profile>` on the CLI if you want). The next
  sync of this profile will then rebuild reconciliation state from
  scratch — a full re-scan of both replicas.
- **Done** — closes the manager window. ⏎ activates.

Hidden profiles are still listed (dimmed) so you can unhide them.

Footer text: "Hide and reorder only affect this app's picker. The CLI
`unison <profile>` still sees every .prf in the directory."

---

## The Profile Form (single-profile content editor)

Opens from the manager's **New…** or **Edit…** buttons. Top to bottom:

### Profile name

The `.prf` filename without the `.prf` extension. **Editable in both New
and Edit modes** — changing the name on an existing profile and clicking
Save performs a rename of the `.prf` file on disk (and carries the
`.prf.bak` sidecar along). The user's view preferences (hide / custom
order) also follow the renamed profile.

**Renaming is benign for Unison's archive state** — archive files are
keyed off the roots + hostname + archive format, *not* the `.prf`
filename, so the rename doesn't orphan any archives. (Earlier versions of
this app warned about archive orphans on rename; that warning was based
on a misreading of upstream and has been removed.)

Forbidden characters: `/`, `\`, `:` (would break the filename).

### First root / Second root

Two text fields, each with a **Browse…** button for picking a local
directory. The terminology matches the upstream Unison manual — see
[Roots](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex)
§ "Specifying Roots". Either root can be:

- A local absolute path: `/Users/you/Documents`
- An SSH URL: `ssh://user@host//absolute/path` (note the double slash
  for absolute remote paths; single slash for relative-to-home)
- A socket URL: `socket://host:port/path`
- A `file://` URL (rarely needed)

**Both roots can be local** — there is no client/server distinction in
the `.prf` data model. The "First" and "Second" labels just match the
order of the `root = …` lines in the profile file.

Below the root fields, a paragraph reminds you that either side can be
local or remote.

### Paths to sync

Multi-line field, one path per line. Each line becomes a `path = …` entry
in the `.prf`. Empty list = "sync everything under the roots."

See [path specification](https://github.com/bcpierce00/unison/wiki/Manual#path-specification)
in the upstream wiki for the syntax (relative to the root, forward-slash
separated regardless of OS).

### Ignore patterns

Multi-line field, one pattern per line. Each line becomes an `ignore = …`
entry. Pattern syntax (also in the wiki):

- `Path foo/bar` — ignore a specific path
- `Name *.tmp` — ignore by basename (glob)
- `Regex \..*` — ignore by regex

These patterns can also be added on the fly from the reconcile window's
right-click menu (Ignore Path / Extension / Name) — those entries get
appended to this same list.

### Include (override ignore)

Multi-line field. Each line becomes an `ignorenot = …` entry. Exceptions
to the ignore patterns: a match here keeps a path even if `ignore` would
have dropped it. Useful for "ignore everything in `temp/` *except*
`temp/important.txt`".

### Advanced (other prefs)

A raw text field for every `.prf` preference the form doesn't have a
dedicated field for. One `key = value` per line. The form preserves these
verbatim on save — unknown keys, comments, blank lines all survive a
load-edit-save round trip without alteration.

Common entries you might put here:

- `auto = true` — auto-accept Unison's default direction for non-conflicting
  rows (the GUI doesn't honor this exactly; you'll still see the
  reconcile window, but it pre-selects defaults).
- `batch = true` — non-interactive mode (not very meaningful in the GUI).
- `merge = Name * -> /usr/bin/opendiff CURRENT1 CURRENT2 -merge NEW` —
  configure a merge tool. Without this, the Merge action is hidden from
  the toolbar and greyed in the menu — see [Hide Merge below](#the-merge-action).
- `sshcmd = /usr/bin/ssh` / `sshargs = -i /path/to/key` — SSH connection
  details.
- `servercmd = /opt/homebrew/bin/unison` — where to find Unison on the
  remote (if it's not in the default `$PATH` of the SSH login shell).

Full reference: the [Preferences section of the upstream
wiki](https://github.com/bcpierce00/unison/wiki/Manual#preferences).

### Save / Cancel

`Save` writes the `.prf` atomically (`NSString.write(to:atomically:)`)
after backing up the previous version to `.prf.bak`. `Cancel` discards
everything.

---

## The Reconcile window

Opens when you click Run on the picker. Initially in "scanning" mode
showing the indeterminate progress bar; populates with the list of
differences once Unison's `init1` + `init2` complete (init1 sets up the
roots and any SSH connection — that's where credential prompts appear —
and init2 walks both replicas to compute differences).

### Anatomy

```
┌─────────────────────────────────────────────────────────────────────┐
│ [Profiles] [Rescan] | [← First | → Second | Skip | Merge] | [Go] │ ← toolbar
├─────────────────────────────────────────────────────────────────────┤
│ profile-name · 142 items · 3 conflicts · 12 → second · 4 ← first   │ ← summary
│ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░  35%                              │ ← global progress
├─────────────────────────────────────────────────────────────────────┤
│ Path                | First | Action | Second | Size | Progress     │ ← columns
├─────────────────────────────────────────────────────────────────────┤
│ ▾ 📁 Documents      |   ●   |    →   |        |      |              │
│   📄 notes.txt      |   ●   |    →   |        | 24 KB|              │ ← row
│   📄 photo.jpg      |       |    ←   |   ●    | 1 MB │              │
│ ▸ 📁 Pictures       |   ●   |    →   |   ●    |      │              │
├─────────────────────────────────────────────────────────────────────┤
│ /Users/you/Documents/notes.txt                                       │ ← details
│ ...mtime/size details from Unison...                                │
└─────────────────────────────────────────────────────────────────────┘
```

### Columns

- **Path** — the file's relative path within the replica. Folder rows
  show a tinted folder icon (system blue); leaf rows show a neutral
  document icon. Names truncate with `byTruncatingMiddle`; the full
  path is available as a hover tooltip when truncation happens.
- **First / Second** — SF Symbol status icons summarizing what changed
  on each side since the last sync:
  - ➕ Created (green)
  - 🔵 Modified (hollow blue circle)
  - 🔘 PropsChanged (dashed blue) — only metadata changed
  - ➖ Deleted (red)
  - · Unchanged (tiny gray dot) or absent
- **Action** — what the sync will do for this row. The badge shows
  either the **direction** (→ Second / ← First, green / blue) for
  auto-resolved rows, OR the **user's decision** when an override is
  pinned:
  - ⚠ (orange) — auto-detected conflict, needs your attention
  - ⊖ (gray) — user-skipped (Skip applied)
  - ↺ (brown) — Force Older applied (mtime-based decision; arrow hidden
    on purpose so you can tell forced vs. deliberate left/right)
  - ↻ (teal) — Force Newer applied
  - M (purple) — Merge will run (requires `merge = …` in the `.prf`)
  - → (green) — propagate first → second
  - ← (blue) — propagate second → first

  Folder rows show an aggregate badge: same glyph/tint as a leaf when
  every descendant agrees, empty when descendants disagree.
- **Size** — file size, formatted by `ByteCountFormatter`.
- **Progress** — populated during sync. Shows a custom-drawn bar with
  overlaid percent text for in-flight rows (`5%`, `35%`, `100%`), `done`
  when finished, bold red `FAILED` on errors. Empty when idle.
- **Type** — `FILE`, `DIR`, `SYMLINK`, etc., as Unison reports.

### Summary line

Above the row list. Live-updates with status messages from OCaml during
scanning ("Looking for changes...", "Reconciling...") and shows a count
summary once the reconcile completes ("142 items · 3 conflicts · 12 →
second · 4 ← first").

If a status message has multiple lines (typically SSH connect failures
dumping stderr), a **"Details…"** button appears next to the summary
line. Clicking it pops up a scrollable, selectable view with the full
text. The summary label's hover tooltip also carries the full text as a
one-hover alternative.

### Global progress bar

Visible during init2 (indeterminate) and during sync (determinate). Hidden
when idle.

### Toolbar

- **Profiles** — return to the picker (closes this reconcile window).
- **Rescan** — re-run init2 without re-initializing the SSH connection.
  Useful when files have changed on either side and you want a fresh
  view.
- **← First / → Second / Skip / Merge** — direction overrides for the
  selected leaf rows. Multi-select supported; selecting a folder applies
  to every leaf under it.
- **Go** (green) — synchronize. Propagates every row's Action.
- **Stop** (red) — visible during sync. Closes the window (the running
  sync continues in the background until it finishes naturally — there
  is no true mid-sync abort available; see TODO P3 "Real mid-sync
  abort").

### Details footer

A non-editable `NSTextView` at the bottom. Selecting a leaf row shows the
OCaml-computed details (size, mtime, conflict reason). Selecting a folder
shows the folder's full path plus the count of items under it.

### Row context menu (right-click)

- **Diff** (top — most common right-click intent) → opens the diff viewer.
- (separator)
- **Ignore Path / Ignore Extension / Ignore Name** — adds a new `ignore`
  pattern to the profile's `.prf` *immediately* (no confirmation), then
  re-filters the row list. **The pattern is permanent** — it persists in
  the `.prf` file and applies to the CLI `unison <profile>` too.

---

## The Diff viewer

Opens via:

- `Action → Diff` menu item (with a row selected, or by right-clicking
  a row)
- Row context menu → Diff (top item)

**When the Diff item is greyed**: Unison's `canDiff` predicate rejects
the row. That happens for directories, symlinks, rows with
update-detection problems, and rows where the only change on both sides
is metadata (PropsChanged). It does **not** reject binary files —
those just produce uninformative output from the configured `diff`
command (typically `Binary files X and Y differ`).

The diff itself runs through whatever you've configured as Unison's
`diff` pref (default `diff -u CURRENT1 CURRENT2`). With the default, the
output is unified-diff format, which the diff window colorizes:

- Lines starting with `+` → green (added)
- Lines starting with `-` → red (removed)
- Lines starting with `@@` → blue (hunk header)
- `+++` / `---` file headers → bold (no tint)
- Everything else → default labelColor

The diff window:

- Is read-only and selectable (⌘F opens the find bar for searching
  within the diff).
- Reuses across multiple Diff invocations — clicking Diff on another row
  updates the same window in place.
- Survives the reconcile window closing (you can keep reading the diff
  after going back to the picker).

When `displayDiffErr` fires (Unison can't produce a diff for some
reason), the window switches to an error view: red header + raw error
text. Pick another row's Diff to recover.

---

## The menu bar reference

### `<appname>` menu

Standard macOS app menu: About, Services, Hide, Quit. The About panel
shows the embedded Unison version (queried via
`unison_bridge_get_version`).

### Edit menu

| Item | Shortcut | Action |
|---|---|---|
| Undo | ⌘Z | Standard responder action |
| Redo | ⌘⇧Z | Standard responder action |
| Cut / Copy / Paste / Select All | ⌘X / ⌘C / ⌘V / ⌘A | Standard text ops |
| Ignore Path | — | Add `ignore = Path "<row's path>"` to the profile |
| Ignore Extension | — | Add `ignore = Name {,.}*"<.ext>"` |
| Ignore Name | — | Add `ignore = Name "<basename>"` |
| Profile Editor… | ⌘⇧E | Open the manager window |

The three Ignore items dispatch to the reconcile window when it's key;
otherwise they're greyed.

### Action menu (reconcile-window operations)

| Item | Action |
|---|---|
| → Second | Propagate first → second for selected leaves |
| ← First | Propagate second → first |
| Skip | Mark selected leaves as user-skipped |
| Merge | Run the configured `merge` command on selected leaves (greyed if `merge` pref isn't set) |
| Force Older | Pick the older-mtime side for each selected leaf |
| Force Newer | Pick the newer-mtime side |
| Diff | Open the diff viewer for the selected (or right-clicked) leaf |
| Select Conflicts | Select every leaf row that's still unresolved (`<-?->` with no user override) |
| Revert to Unison's Recommendation | Clear user overrides on selected leaves |

All items dispatch via the responder chain to `ReconcileWindowController`
when the reconcile window is key. Disabled when no reconcile window is
key. Direction items are disabled during sync.

### Window menu

Standard: Minimize, Zoom, Bring All to Front.

### Help menu

- `<appname> Help` (⌘?) — opens this repo's README in the browser.
- `Unison File Synchronizer Help` — opens the upstream Unison wiki.

No File menu — this isn't a document-based app. ⌘W still closes the
focused window via the standard responder action.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⏎ (in picker) | Run selected profile |
| ⌘⇧E | Profile Editor… |
| ⌘? | App help |
| ⌘W | Close focused window |
| ⌘M | Minimize focused window |
| ⌘Q | Quit |
| ⌘F (in diff window) | Find bar |

No keyboard shortcuts on Action-menu items by design — they're frequently
applied to multi-row selections where a mouse is usually already in
play. Add custom shortcuts via System Settings → Keyboard → Keyboard
Shortcuts → App Shortcuts if you want them.

---

## Troubleshooting

### "Archive inconsistency" fatal mid-reconcile

Unison detected that its archive files are out of sync (typically from a
crashed sync). A modal alert appears with the offending archive list. If
the archive files exist locally, the alert offers a one-click **"Delete
N Orphan Archive(s) and Retry"** button. Click it to remove the
orphaned files and retry the reconcile.

For pre-emptive cleanup (no error yet, but suspect): use **Reset
Archives…** in the Profile Editor.

### SSH "permission denied" / "host key changed"

Unison runs SSH with whatever your `sshcmd` / `sshargs` prefs specify,
and the macOS system SSH config. If you need a specific key or non-
default host, set them in the Advanced field of the Profile Form. The
multi-line error appears in the reconcile window's summary line — click
**Details…** for the full text (especially useful when the SSH client
returns a multi-line key fingerprint check or similar).

### A profile won't open from the GUI but works from the CLI

Likely cause: the `.prf` references `~` or relative paths that resolve
differently in the GUI's process environment. Use absolute paths in the
Profile Form's root fields.

Also: any preference that requires interactive CLI flags (e.g.,
`-ignorearchives`) won't work here — those are command-line-only and
this app builds its own argv. Put their equivalent in the `.prf` if
possible.

### The Merge button is missing

The Merge toolbar item and `Action → Merge` menu item are hidden /
greyed when the active profile's `.prf` doesn't declare a `merge`
preference. Add a `merge = …` line to the profile's Advanced field
(see [Profile Form > Advanced](#advanced-other-prefs)) and re-open the
profile.

### "Cancel" / Stop doesn't actually stop the sync

Correct — Unison's OCaml core doesn't expose a mid-sync abort callback
that we can wire to. The Stop button closes the reconcile window;
Unison's worker continues until the current batch of file transfers
finishes naturally. See TODO P3 "Real mid-sync abort" for the upstream
patch we'd need to enable a true cancel.

### The app starts slowly / OCaml takes time to spin up

First launch involves `caml_startup` and a few hundred milliseconds of
OCaml runtime setup. Subsequent launches reuse the same `.app` bundle.
There's a one-time Gatekeeper prompt on macOS Tahoe 26 for ad-hoc-signed
apps — accept it once and it stops.

### Profile won't sync but CLI `unison <profile>` works

Check the `clientHostName` pref in your `.prf`. If you've set it
explicitly to a value that differs from the hostname Unison's OCaml
runtime detects via `gethostname()` (which is what
`ProcessInfo.hostName` returns), the archive hashes diverge. Either
remove the `clientHostName` override or set
`UNISONLOCALHOSTNAME=<your-hostname>` in the launch environment.

---

## What this app does NOT do

- **Edit conflicts inline.** You set the direction for a conflicted row;
  Unison handles the actual byte propagation. To merge byte-by-byte, use
  the `merge` pref + an external merge tool (FileMerge, kdiff3, etc.).
- **Show file content beyond Diff.** No preview pane, no quick-look-style
  inspector. Use the Diff viewer for textual differences or open the file
  in its native application.
- **Edit `.prf` syntax it doesn't understand.** Unknown keys round-trip
  through the Advanced field unchanged, but the form doesn't validate
  them. Garbage-in, garbage-Unison-error-out.
- **Truly abort a running sync.** See troubleshooting above.
- **Replace the upstream Unison CLI for scripting.** The CLI is still the
  right tool for `crontab` / `launchd` automation. This GUI is for
  interactive use.
- **Run as a menu-bar status item or background daemon.** Foreground app
  only, one reconcile window per profile open at a time.

---

For everything else, the [upstream
wiki](https://github.com/bcpierce00/unison/wiki) is the authoritative
reference. This GUI is just a way of driving Unison; the synchronization
semantics, the `.prf` format, the conflict-resolution rules — all of
that is Unison.
