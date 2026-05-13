# Unison-UI-Mac — User Manual

A feature-by-feature guide to the macOS app. For install steps see
[INSTALL.md](INSTALL.md); for architecture overview and a build
cheatsheet see [README.md](README.md). For the underlying
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
8. [Settings](#settings)
9. [The menu bar reference](#the-menu-bar-reference)
10. [Keyboard shortcuts](#keyboard-shortcuts)
11. [Troubleshooting](#troubleshooting)
12. [What this app does NOT do](#what-this-app-does-not-do)

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
separate `unison` install. But profiles whose root is `ssh://…` spawn
`unison -server` on the remote host — that remote needs Unison installed
and reachable in `$PATH` (or via `servercmd = …` in the profile).

Install instructions for the remote side:

- **macOS**: `brew install unison`
- **Debian/Ubuntu**: `sudo apt install unison`
- **Other**: see upstream's [Downloading Unison](https://github.com/bcpierce00/unison/wiki/Downloading-Unison)
  page or build from source at <https://github.com/bcpierce00/unison>.

This project's embedded Unison is **v2.54.0** (see README's "Unison
version" section for the exact upstream commit). The remote Unison must
be the same major version — `2.54.x` works, `2.51.x` does not. The app
runs a one-shot `ssh ... unison -version` probe on profile open and
surfaces a suppressible alert on mismatch (see
[Version-mismatch warning](#version-mismatch-warning-on-profile-open)
below).

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

### Refresh

The picker re-reads the Unison directory automatically every time its
window becomes key — so creating a `.prf` via the CLI, copying one in
from a backup, or editing a name in Finder is picked up the moment you
switch back to the app. No manual refresh action on the picker; the
Profile Editor has an explicit Refresh button (and ⌘R) for the edge case
where you want a re-read without losing focus.

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
  Trash.

  If the profile has matching archive files in the Unison directory
  (`ar<hash>`, `fp<hash>`, `lk<hash>`, etc.), the confirmation grows a
  checkbox: **"Also move N archive file(s) to Trash"** — *checked by
  default*. The hash is computed from the profile's roots before the
  `.prf` is deleted, so we still know which archives belong to it. If
  you uncheck the box, the `.prf` goes but the archives stay; useful
  when you plan to restore the profile from Trash and resume syncing.
  When there are no matching archives (e.g. both roots are remote,
  archives already cleaned up), the checkbox is hidden.
- **Reset Archives…** — for the selected profile, compute its archive
  hash (see [archive files](https://github.com/bcpierce00/unison/wiki/FAQ#what-are-archive-files-in-unison)
  in the upstream wiki), find matching `ar<hash>`, `fp<hash>`, `lk<hash>`,
  `tm<hash>`, `sc<hash>` files in the Unison directory, and move them to
  Trash. The confirmation dialog lists exactly which files will be moved
  plus the computed hash (you can cross-check against
  `unison -showArchiveName <profile>` on the CLI if you want). The next
  sync of this profile will then rebuild reconciliation state from
  scratch — a full re-scan of both replicas. Use this when you want to
  clean archives but keep the profile itself; Delete's archive-cleanup
  checkbox is the right tool for "I'm done with this profile entirely."
- **Refresh** (⌘R) — re-reads the `.prf` directory. The editor also
  auto-refreshes whenever its window becomes key, so this button is for
  the edge case where you modify files in another tool without losing
  focus on the editor (e.g. running a command in Terminal that's already
  visible in a split with the editor window key).
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
- **Progress** — populated during sync. Shows a standard macOS
  `NSProgressIndicator` bar (follows your **System Settings →
  Appearance → Accent color**) with overlaid percent text for
  in-flight rows (`5%`, `35%`, `100%`), `done` when finished, bold red
  `FAILED` on errors. Empty when idle.
- **Type** — `FILE`, `DIR`, `SYMLINK`, etc., as Unison reports.

### Summary line

Above the row list. Live-updates with status messages from OCaml during
scanning ("Looking for changes...", "Reconciling...") and shows a count
summary once the reconcile completes ("142 items · 1.2 GB · 3 conflicts ·
12 → second · 4 ← first").

The size figure between the item count and the breakdown is the **total
bytes that will move if you hit Go now**. Sum of file sizes for rows
with a clear direction arrow (`←` First or `→` Second); conflicts and
`<-M->` merge rows are excluded — conflicts won't transfer until
resolved, and merge runs an external command whose byte output isn't
predictable in advance. User overrides on conflict rows aren't reflected
in this total (same convention as the count breakdown) — rescan refreshes
the snapshot after manual changes if you want an updated total.

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

## Settings

Opens via `Unison-UI-Mac → Settings…` (⌘,). Single window with three
sections, each describing a category of stored state and offering a
way to reset it. No preferences are *set* here today — everything is
implicit (you hide a profile by clicking its eye icon, dismiss a
version-mismatch alert via its checkbox, etc.). The Settings window is
the place to *inspect* and *reset* that implicit state.

### Profile picker layout

Shows counts ("3 hidden profiles · 7 in custom order") for the keys
`profiles.hidden` and `profiles.order`. The **Reset** button clears
both — after a reset, every `.prf` is visible in alphabetical order in
the picker. The `.prf` files themselves are untouched; this is purely
UI presentation state.

### SSH version-mismatch suppressions

A table of `(host, this-Mac-version, remote-version)` triples that
you've dismissed via the "Don't remind me again" checkbox on the
[Version-mismatch warning](#version-mismatch-warning-on-profile-open).
Each row can be selected and removed individually via **Remove
Selected**, or wiped en masse via **Clear All** (which has a confirm
sheet because it's a bulk destructive action; per-row removal doesn't
prompt — one accidental removal is cheap to re-suppress next time the
alert fires).

Removing a suppression doesn't immediately do anything; the next time
you open a profile whose SSH peer matches the triple, the version-check
probe runs and re-prompts you with the alert.

### Window & toolbar layout

Counts of how many window-frame autosaves and toolbar configurations
the app has on file. The **Reset Window Positions** button clears all
of them; the next time each window reopens, it uses its default
position and size. Useful when:

- A window has drifted off-screen after a monitor change.
- You want to start fresh after experimenting with the reconcile
  toolbar layout.

Currently-open windows are not moved by the reset — autosaves are
written on close and read on open, so the effect only takes hold the
next time each window is opened. The reset alert spells this out.

### What's stored, and where

Everything lives in `~/Library/Preferences/net.courbage.unison-ui-mac.plist`,
accessed via the standard `UserDefaults` API. The keys this app writes:

| Key | Purpose |
|---|---|
| `profiles.hidden` | Basenames of profiles hidden from the picker |
| `profiles.order` | Custom picker order |
| `versionMismatch.suppressed` | List of suppressed `host\|local\|remote` triples |
| `NSWindow Frame <name>` | AppKit auto: window position/size per window |
| `NSToolbar Configuration ReconcileToolbar.v4` | Reconcile toolbar customization |

You can inspect them directly with `defaults read net.courbage.unison-ui-mac`,
or wipe everything in one shot with `defaults delete net.courbage.unison-ui-mac`
— but the Settings window gives you fine-grained control by category.

---

## The menu bar reference

### `Unison-UI-Mac` menu

Standard macOS app menu: About, Settings… (⌘,), Services, Hide, Quit.
The menu uses the app's display name (`CFBundleDisplayName =
"Unison-UI-Mac"`). The About panel shows the embedded Unison version
(queried via `unison_bridge_get_version`). The Settings entry opens
the inspect-and-reset window described in [Settings](#settings) above.

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

| Item | Shortcut | Action |
|---|---|---|
| Go | ⌘⏎ | Start synchronizing the current row decisions. Disabled mid-sync and before init2 has populated rows. |
| Stop | ⌘. | Abort a running sync. Disabled when no sync is running. (See [Stop button](#stop-button-how-abort-works) for the abort semantics.) |
| Rescan | ⌘⇧R | Re-run init2 against the current profile. Disabled mid-sync. |
| → Second | — | Propagate first → second for selected leaves |
| ← First | — | Propagate second → first |
| Skip | — | Mark selected leaves as user-skipped |
| Merge | — | Run the configured `merge` command on selected leaves (greyed if `merge` pref isn't set) |
| Force Older | — | Pick the older-mtime side for each selected leaf |
| Force Newer | — | Pick the newer-mtime side |
| Diff | — | Open the diff viewer for the selected (or right-clicked) leaf |
| Select Conflicts | — | Select every leaf row that's still unresolved (`<-?->` with no user override) |
| Revert to Unison's Recommendation | — | Clear user overrides on selected leaves |

All items dispatch via the responder chain to `ReconcileWindowController`
when the reconcile window is key. Disabled when no reconcile window is
key. Direction items are disabled during sync.

The three workflow shortcuts follow macOS conventions:
**⌘⏎ "submit / run"** (matches Mail's Send and similar primary actions),
**⌘.** for "cancel currently running operation" (system-wide since
System 6), and **⌘⇧R** for Rescan — parallel to Safari/Mail's "Reload"
and distinct from Profile Editor's ⌘R refresh so the two never collide.

### Window menu

Standard: Minimize, Zoom, Bring All to Front.

### Help menu

- `Unison-UI-Mac Help` (⌘?) — opens this repo's README in the browser.
- `Unison File Synchronizer Help` — opens the upstream Unison wiki.

No File menu — this isn't a document-based app. ⌘W still closes the
focused window via the standard responder action.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⏎ (in picker) | Run selected profile |
| ⌘⇧E | Profile Editor… |
| ⌘R (in Profile Editor) | Refresh profile list |
| ⌘, | Settings… |
| ⌘⏎ (in reconcile window) | Go (start sync) |
| ⌘. (in reconcile window) | Stop (abort sync) |
| ⌘⇧R (in reconcile window) | Rescan |
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

### Stop button: how abort works

Clicking **Stop** in the toolbar (or invoking it through the menu/
context menu) calls into a local patch in our fork of Unison that
sets the `Abort.abortAll` flag on the OCaml side. The in-flight sync
worker observes the flag at its next `Abort.check` checkpoint —
typically between file transfers — and unwinds by raising the
internal `Aborted by user request` transient.

**What you'll see**:
- One or two more rows may complete naturally before the abort
  takes effect (any file already in mid-transfer at the moment Stop
  was clicked).
- Queued rows that haven't started yet show **FAILED** in the
  Progress column.
- The reconcile window **stays open** so you can inspect the FAILED
  rows. The progress bar disappears; the summary line shows that
  the sync was aborted.
- Clicking Stop again is a no-op (the abort flag is already set).
- You can then rescan to see the post-abort state of both replicas,
  or close the window manually.

**What it does NOT do**:
- Doesn't roll back partial transfers. If a file was mid-write when
  the abort propagated, it's in whatever state OCaml's transfer
  layer left it (typically the destination has a partial copy plus
  Unison's `.unison.tmp` sidecar). Unison's next reconcile will see
  the difference and let you decide how to fix it.
- Doesn't kill the OCaml worker. It just sets a flag; the worker
  exits its current task cooperatively, then idles in
  `bridgeThreadWait` ready for the next bridge call.

If you close the reconcile window mid-sync via ⌘W (or the red close
button), you get a three-option prompt: **Keep Syncing** /
**Abort & Close** / **Close (let it run)**. The third option closes
the window but lets the sync continue in the background until natural
completion — useful when you want to reclaim screen space but not
interrupt the transfer.

### The app starts slowly / OCaml takes time to spin up

First launch involves `caml_startup` and a few hundred milliseconds of
OCaml runtime setup. Subsequent launches reuse the same `.app` bundle.
There's a one-time Gatekeeper prompt on macOS Tahoe 26 for ad-hoc-signed
apps — accept it once and it stops.

### How do I read this app's diagnostic logs?

The app emits diagnostic info to macOS Unified Logging under subsystem
`net.courbage.unison-ui-mac`. View it via Console.app (filter the
"Subsystem" column) or the `log` CLI:

```sh
# Live tail of everything the app is logging:
log stream --predicate 'subsystem == "net.courbage.unison-ui-mac"'

# Filter to just bridge events (OCaml↔Swift):
log stream --predicate 'subsystem == "net.courbage.unison-ui-mac" AND category == "bridge"'

# Or just the OCaml status messages forwarded from displayStatus:
log stream --predicate 'subsystem == "net.courbage.unison-ui-mac" AND category == "ocaml-status"'

# Last hour of everything, in one shot:
log show --predicate 'subsystem == "net.courbage.unison-ui-mac"' --last 1h
```

Categories: `lifecycle` (app/window open-close), `bridge`
(OCaml↔Swift events), `reconcile` (reconcile-window state),
`ocaml-status` (status messages forwarded from Unison's
`displayStatus`), `version-check` (the SSH version probe; see below),
`general` (the legacy `TraceLog` catch-all).

Earlier versions of this app wrote to `/tmp/unison-ui-mac.log` — that
file is no longer produced. Migrating to Unified Logging gives you
filterable categories, structured search, and persistence across
reboots without the disk-hygiene problem of a stray /tmp file.

### Version-mismatch warning on profile open

When you open a profile that has an `ssh://…` root, the app spawns a
one-shot `ssh -o BatchMode=yes host servercmd -version` in the
background and compares the result with the locally-embedded Unison
version. If they differ, you get a warning alert:

> **Unison version mismatch**  
> This Mac has Unison 2.54.0. The remote (server.example.com) is
> running 2.54.3. Minor-version differences usually interoperate,
> but major-version differences can fail with cryptic RPC handshake
> errors. If sync fails or behaves strangely, see the upstream wiki's
> compatibility notes.
>
> ☐ Don't remind me again for this host (until either version changes)

The checkbox persists per `(host, localVersion, remoteVersion)` triple.
Once you suppress it, you won't see it again for that exact combination
— but as soon as you upgrade either side, the triple changes and you'll
see the alert again so you can re-confirm.

**The probe is silent in normal operation**:
- Uses `BatchMode=yes` — won't prompt for a password. If the remote
  requires password auth, the probe fails silently and no alert
  appears (Unison's own connection will prompt as usual for the
  actual sync).
- Times out after 5 seconds (`ConnectTimeout=5`).
- `StrictHostKeyChecking=accept-new` — first-time hosts get added
  to known_hosts; changed keys are rejected (mirrors typical SSH
  workflow).

**Limitations**:
- Doesn't honor your `sshcmd` / `sshargs` prefs — invokes
  `/usr/bin/ssh` directly. If your Unison SSH config differs
  significantly from your shell SSH config, the probe may use a
  different path/auth than the actual Unison connection.
- Doesn't check `socket://` profiles. There's no `-version` probe
  for socket-mode Unison servers without going through the actual
  Unison protocol.
- Only checks the FIRST `ssh://` root in the profile. The pathological
  case of two `ssh://` roots pointing at different hosts is not
  fully covered.

### What happens when a new version of Unison is released?

Two halves of the answer — for the **local** side (the embedded Unison)
and for the **remote** side (any `ssh://…` peer).

**Local side (the embedded copy).** This app links in `unison-blob.o`,
which is built from whichever upstream source you have checked out
under `~/Documents/Sources/unison/` (or wherever `UNISON_SRC` points).
The embedded version is frozen at build time — the app doesn't
"auto-update" Unison on its own. To pull a new version:

```sh
cd ~/Documents/Sources/unison && git pull
cd ~/Documents/Sources/unison-ui-mac && make build
```

Then relaunch the app. The About panel shows the embedded version so
you can verify.

**Remote side (`ssh://…` profiles).** Unrelated to local rebuilds. You
update the remote Unison the way you'd update any CLI on that machine
(`brew upgrade unison`, `apt upgrade unison`, etc.). The two Unisons
negotiate compatibility at connection — see the upstream wiki's
[Cross-Platform Issues / Compatibility](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex)
section. As a rule of thumb:

- Minor-version mismatches (e.g. `2.54.0` ↔ `2.54.3`) usually
  interoperate cleanly.
- Major-version mismatches (e.g. `2.51` ↔ `2.54`) often don't.
  Upstream guarantees forward compatibility within a major series,
  not across them.

If you have multiple Unison versions on the remote and need to pin a
specific one for a profile, set `servercmd = /path/to/unison-X.Y` in
the Advanced field of the Profile Form.

**Archive format compatibility.** Unison's archive files have an
internal format version (currently `23`). When upstream bumps this in
a future release, existing archives become unreadable and Unison
forces a full re-scan to rebuild them. Two consequences for this app:

1. Existing archives from before the version bump get orphaned. Use
   `Reset Archives…` in the Profile Editor to clean them up after the
   update.
2. This app's `ArchiveHash.swift` has `archiveFormat = 23` pinned. If
   upstream bumps it and we don't update, the `Reset Archives` button
   will compute the wrong hash and miss the orphaned files. The fix
   is a one-line change to `ArchiveHash.archiveFormat`; the unit
   tests (using `md5(1)`-verified reference values) will fail loudly
   on a stale constant.

For day-to-day usage: when you run `brew upgrade unison` on a remote
host and SSH-based syncs start failing with a version mismatch error,
the answer is to rebuild this app against a matching upstream
checkout.

### Profile won't sync but CLI `unison <profile>` works

Three things to check, in order of likelihood:

**1. `clientHostName` divergence.** If you've set this pref in your
`.prf` to a value that differs from what `gethostname()` reports
(which is what `ProcessInfo.hostName` returns), the archive hashes
diverge between CLI and GUI. Either remove the `clientHostName`
override, or set `UNISONLOCALHOSTNAME=<your-hostname>` in the launch
environment so both pick up the same value.

**2. Command-line argument overrides.** This app launches OCaml with
`argv = [program_name]` — no CLI args propagate from your shell to
Unison. So if you typically run `unison -opt=val <profile>` to
override a preference at the command line, the GUI won't apply that
override (it only sees the `.prf` content). Put the override in the
`.prf` itself via the Advanced field of the Profile Form to bring
the GUI into parity.

**3. Multi-profile session quirk.** If you switch profiles within
one GUI session (via the picker), the GUI doesn't re-parse the
command line for the new profile — only on first launch. The CLI
re-parses on every profile open. For our app this is moot (we
don't accept user CLI args anyway), but it's a documented
divergence from upstream's `Uicommon.initPrefs` that matters if
we ever start accepting CLI overrides at the app's launch
arguments. See the audit comment near
`Prefs.parseCmdLine` in `unison/src/uimacbridge.ml`:
`do_unisonInit1` runs `parseCmdLine` only on `firstTime`, while
upstream `Uicommon.initPrefs` runs it unconditionally (per the
"JV (6/09): always reparse the command line" note in that file).

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
- **Roll back partial transfers.** The Stop button aborts cooperatively
  (see [Stop button](#stop-button-how-abort-works) in troubleshooting):
  a file mid-write at abort time stays partial. Unison's next reconcile
  will surface the difference for you to resolve.
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
