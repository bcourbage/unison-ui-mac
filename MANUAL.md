# Unison-UI-Mac, User Manual

A feature-by-feature guide to the macOS app. For install steps see
[INSTALL.md](INSTALL.md); for architecture overview and a build
cheatsheet see [README.md](README.md). For the underlying
file-synchronization concepts (profiles, roots, paths, ignore patterns,
conflict resolution, the `merge` preference, archive files), the
authoritative reference is the **upstream Unison documentation**:

- [Unison File Synchronizer wiki](https://github.com/bcpierce00/unison/wiki)
- [Unison user manual (full)](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex)
- [Preferences reference (`.prf` keys + syntax)](https://github.com/bcpierce00/unison/wiki/Manual)

The sections below cover **how the macOS GUI exposes those concepts**, not the
concepts themselves. When a feature touches a `.prf` preference, it's
linked to the section of the upstream docs that defines it.

---

## Table of contents

1. [Concepts in one paragraph](#concepts-in-one-paragraph)
2. [Getting started](#getting-started)
3. [The `unison` command](#the-unison-command)
4. [The Profile Picker](#the-profile-picker)
5. [The Profile Editor (manager window)](#the-profile-editor-manager-window)
6. [The Profile Form (single-profile content editor)](#the-profile-form-single-profile-content-editor)
7. [The Reconcile window](#the-reconcile-window)
8. [The Diff viewer](#the-diff-viewer)
9. [Settings](#settings)
10. [The menu bar reference](#the-menu-bar-reference)
11. [Keyboard shortcuts](#keyboard-shortcuts)
12. [Troubleshooting](#troubleshooting)
13. [What this app does NOT do](#what-this-app-does-not-do)

---

## Concepts in one paragraph

Unison synchronizes a pair of file trees ("**replicas**") rooted at two
paths ("**roots**"), both can be local directories, or one or both can be
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
`unison -server` on the remote host, so that remote needs a `unison`
command its non-interactive shell can find (or a `servercmd = …` line in
the profile).

Ways to provide it on the remote side:

- **macOS with this app installed**: the bundled command serves this role
  with the embedded engine; see [The `unison` command](#the-unison-command).
- **macOS without this app**: `brew install unison`
- **Debian/Ubuntu**: `sudo apt install unison`
- **Other**: see upstream's [Downloading Unison](https://github.com/bcpierce00/unison/wiki/Downloading-Unison)
  page or build from source at <https://github.com/bcpierce00/unison>.

This project's embedded Unison is **v2.54.0** (see README's "Unison
version" section for the exact upstream commit). The compatibility
boundary is Unison's **2.52.0** wire protocol, not an exact version
match: any remote at `>= 2.52.0` interoperates (so `2.53.x` and `2.54.x`
work together), while `2.51.x` and earlier are on the other side of the
boundary and cannot connect. The app runs a one-shot
`ssh ... unison -version` probe on profile open and surfaces a
suppressible alert only when the two sides straddle that boundary (see
[Version-mismatch warning](#version-mismatch-warning-on-profile-open)
below).

### 2. Launch the app

The app opens with the **Profile Picker** (see next section). On first
launch, if you have no profiles yet, the list will be empty, use
`Edit → Profile Editor…` (⌘⇧E) to create one.

### 3. Pick a profile, hit Run

Double-click a profile (or select it and click Run) to start reconcile.
The reconcile window opens immediately in "scanning" mode and populates
when init1+init2 complete.

---

## The `unison` command

The app bundle carries a command-line launcher at
`unison-ui-mac.app/Contents/MacOS/cltool`. Linked onto PATH under the name
`unison`, it makes one command serve both of Unison's roles through this
app:

| Command | What runs |
|---|---|
| `unison -ui graphic` | This app. A profile name after the flags is preselected in the picker when the picker lists it and its row opens the same file Unison would (`p.prf` given while a file named plainly `p` also exists is refused, since the picker's `p` would open that other file); a hidden profile is refused with a message. Two roots are refused. |
| `unison -ui text <profile>` | Unison's text interface in the terminal, on the embedded engine. |
| `unison -version`, `unison -doc …`, `unison -help` | Printed by the embedded engine. |
| `unison -server`, `unison -socket …` | The embedded engine in server mode. This is what a remote peer's ssh invocation runs, so a Mac with this app installed needs no other Unison to be the far side of an SSH profile. |
| `unison <profile>`, `unison -batch <profile>`, `unison root1 root2`, with no `-ui` | The text interface, exactly as the `unison` command behaves everywhere. The graphical interface runs only when `-ui graphic` is given. |
| `unison -ui graphic …` where no graphical session exists (over ssh) | Refused with a message. Use `-ui text`. |
| `unison` with no arguments, over ssh | The text interface, which like upstream's `unison` uses the `default` profile if one exists and prints usage otherwise. |

The command hands Unison's engine `-ui text` followed by the arguments
exactly as typed, and Unison interprets them: a later `-ui graphic` wins
over that default, `-server` and `-version` take effect before any interface
choice, `-ui=text` means the same as `-ui text`, and options take exactly one
leading dash (`--ui` is an unknown option to Unison). Unknown options are
reported by Unison with its usage text.

`unison -ui graphic` keeps the terminal busy until the app quits, like any
foreground command. Append `&` to get the prompt back.

### Putting it on PATH

Settings → Command Line shows what `unison` resolves to and offers Install
when nothing owns the name (see [Settings](#command-line)). The manual
equivalent: create a symlink named `unison`. Whether a given shell finds it
depends on that shell's PATH; `/usr/local/bin` is on the PATH `/etc/paths`
gives login shells on a stock macOS. Writing there needs an administrator
password:

```sh
sudo ln -s /Applications/unison-ui-mac.app/Contents/MacOS/cltool /usr/local/bin/unison
```

Only one command can own the name. Check what `unison` resolves to before
and after:

```sh
which -a unison
```

A Homebrew `unison` formula or upstream Unison.app's own launcher may
already hold it. Leave it and skip this section if you prefer: the app works
from the profile picker either way. For Homebrew installs of the app: with
the formula linked, Homebrew installs the app but skips the `unison` link with
a warning and the formula keeps the command; to give the command to the app,
run `brew unlink unison` and then `brew reinstall --cask unison-ui-mac`.

If the app is moved, the link dangles and `unison` reports "command not
found"; recreate it. To uninstall the command, remove the link:

```sh
sudo rm /usr/local/bin/unison
```

### Remote peers

Peers whose profiles target this Mac run `unison -server` here through
ssh. The PATH that command receives is not the one your Terminal has: it is
decided by the SSH server's configuration and by the login shell's
non-interactive startup files, and it does not include the directories that
`/etc/paths` adds to login shells. On one measured machine (macOS 26.6.2,
zsh, no `.zshenv`), `ssh host 'echo $PATH'` printed `/usr/bin:/bin:/usr/sbin:/sbin`,
which contains neither `/usr/local/bin` nor the Homebrew prefix; other
machines may differ. Do not rely on it either way: set `servercmd` in the
peer's profile to the link's full path, for example
`servercmd = /usr/local/bin/unison` or `servercmd = /opt/homebrew/bin/unison`.

A freshly installed app, whether from the zip or through Homebrew, carries
the quarantine attribute until it is opened once from Finder, and
Gatekeeper's first-launch check needs a graphical session. Launch the app
once before relying on it as an ssh peer.

---

## The Profile Picker

The launch view. A simple list of every `.prf` file in
`~/Library/Application Support/Unison/`, sorted by your custom order if
you've set one (see [Profile Editor](#the-profile-editor-manager-window)),
otherwise alphabetical. Hidden profiles (also a Profile Editor feature)
don't appear here.

**Run** (⏎ / Enter): selects the highlighted profile and opens the
reconcile window in scanning mode.

Double-click also runs.

**Quit**: at the far left of the bottom bar, quits the app (same as
⌘Q). Placed away from Run so it isn't clicked by reflex.

> The button is labeled "Run" rather than "Open" because picking a profile
> kicks off the sync workflow, same verb as the CLI `unison <profile>`.
> Nothing here opens a document for editing.

**Initial selection**:

- First launch (or any time the picker opens with no prior context):
  the profile named `default` if you have one, otherwise the top row.
- Returning from the reconcile window: the profile you just had open
  stays highlighted, so re-running it (or moving on to a different
  one) is a single click away.
- After a manual click + a `windowDidBecomeKey` reload (e.g. you
  switched apps and came back): your last manual selection is
  preserved if the profile is still on disk.

### Profile creation, editing, deletion, etc.

Not on the picker, those live in the Profile Editor manager. The picker
is intentionally minimal: list + Run.

### Refresh

The picker re-reads the Unison directory automatically every time its
window becomes key, so creating a `.prf` via the CLI, copying one in
from a backup, or editing a name in Finder is picked up the moment you
switch back to the app. No manual refresh action on the picker; the
Profile Editor has an explicit Refresh button (and ⌘R) for the edge case
where you want a re-read without losing focus.

---

## The Profile Editor (manager window)

Opens via `Edit → Profile Editor…` (⌘⇧E).

A table of every profile, with three columns:

- **☰ Drag handle**: grab and drag to reorder the list. The order
  persists across app launches (stored in `UserDefaults` under
  `profiles.order`). The custom order applies to the picker too. Reorder
  is **UI-only**: the `.prf` files themselves aren't touched, and the
  CLI `unison <profile>` sees every profile in whatever order Unison's
  own profile scanner returns.
- **👁 / 👁‍🗨 Visibility toggle**: click to hide/unhide. Hidden profiles
  disappear from the picker (so you don't see profiles you only run
  rarely or have permanently retired from regular use), but remain on
  disk and remain visible in the Profile Editor. Stored in
  `UserDefaults` under `profiles.hidden`. Like reorder, it's UI-only,
  the CLI doesn't know about hidden state.
- **Profile name**: the basename of the `.prf` file. Dimmed when the
  profile is hidden.

Above the list, a path line shows the Unison directory. The folder
glyph at its right opens that directory in Finder, handy for
inspecting `.prf` files or archive files directly.

Bottom-bar buttons (left to right by profile lifecycle):

- **New…**: opens the Profile Form with empty fields. Save creates a
  new `<name>.prf` in the Unison directory.
- **Duplicate…**: copies the selected profile's `.prf` verbatim to a
  new name. The new profile inherits everything: roots, paths, ignores,
  advanced prefs. Defaults the new name to `<original> copy`, prompts for
  the actual name. After save, the duplicate is inserted right after its
  source in the custom order.
- **Edit…**: opens the Profile Form for the selected profile. Same form
  as New, but pre-populated and with the name field pre-filled. Editing
  the name field and saving performs a rename (see Profile Form below).
- **Delete…**: confirmation alert, then moves the `.prf` (and its
  `.prf.bak` sidecar from a prior save, if any) to the Trash via
  `NSFileManager.trashItem`. A misclick is recoverable from Finder's
  Trash.

  If the profile has matching archive files in the Unison directory
  (`ar<hash>`, `fp<hash>`, `tm<hash>`, `sc<hash>` — never the lock
  `lk<hash>`), the confirmation grows a checkbox: **"Also move N archive
  file(s) to Trash"**, *checked by default*. The removal runs through the
  crash-safe archive-mutation transaction (it acquires each archive's
  lock, stages the files, and Trashes them as one unit; the lock is held,
  never trashed). The hash is computed from the profile's roots before the
  `.prf` is deleted, so we still know which archives belong to it. If
  you uncheck the box, the `.prf` goes but the archives stay; useful
  when you plan to restore the profile from Trash and resume syncing.
  When there are no matching archives (e.g. both roots are remote,
  archives already cleaned up), the checkbox is hidden.
- **Reset Archives…**: for the selected profile, compute its archive
  hash (see [archive files](https://github.com/bcpierce00/unison/wiki/FAQ#what-are-archive-files-in-unison)
  in the upstream wiki), find the matching payload files `ar<hash>`,
  `fp<hash>`, `tm<hash>`, `sc<hash>` (never the lock `lk<hash>`) in the
  Unison directory, and remove them through the crash-safe transaction
  (acquire lock → stage → Trash as one unit; the lock stays in place).
  The confirmation dialog lists exactly which files will be moved
  plus the computed hash (you can cross-check against
  `unison -showArchiveName <profile>` on the CLI if you want). The next
  sync of this profile will then rebuild reconciliation state from
  scratch, a full re-scan of both replicas. Use this when you want to
  clean archives but keep the profile itself; Delete's archive-cleanup
  checkbox is the right tool for "I'm done with this profile entirely."
- **Refresh** (⌘R): re-reads the `.prf` directory. The editor also
  auto-refreshes whenever its window becomes key, so this button is for
  the edge case where you modify files in another tool without losing
  focus on the editor (e.g. running a command in Terminal that's already
  visible in a split with the editor window key).
- **Done**: closes the manager window. ⏎ activates.

Hidden profiles are still listed (dimmed) so you can unhide them.

Footer text: "Hide and reorder only affect this app's picker. The CLI
`unison <profile>` still sees every .prf in the directory."

---

## The Profile Form (single-profile content editor)

Opens from the manager's **New…** or **Edit…** buttons. A sidebar on the
left lists the editor's sections, with a search box above it that filters
the list as you type. A small pop-out button in the window's top-right
corner opens the raw `.prf` in your default editor for that file type
(enabled once the profile has been saved at least once). Each section is
described below.

### General

- **Profile name**: the `.prf` filename without the extension, editable in
  both New and Edit modes. Changing it on an existing profile and clicking
  Save renames the `.prf` on disk, carrying the `.prf.bak` sidecar and your
  hide / custom-order view preferences along. Renaming is benign for
  Unison's archive state, which is keyed off the roots and host, not the
  filename. Forbidden characters: `/`, `\`, `:`.
- **Show in the profile picker**: mirrors the eye toggle in the Profile
  Editor. Unchecked hides the profile from the picker. The `.prf` is
  untouched.

### Roots

Two text fields (First root / Second root), each with a **Browse…** button
for picking a local directory. Either root can be:

- A local absolute path: `/Users/you/Documents`
- An SSH URL: `ssh://user@host//absolute/path` (double slash for an
  absolute remote path, single slash for relative-to-home)
- A socket URL: `socket://host:port/path`

Both roots can be local. There is no client/server distinction in the
`.prf`. "First" and "Second" just match the order of the `root = …` lines.

**Remote Connection.** When either root is `ssh://` or `socket://`, an
extra group appears with the remote-connection prefs: `servercmd` (path to
Unison on the remote), `sshcmd`, `sshargs`, and `clientHostName`. It hides
again when both roots are local.

### Paths

One path per line; each becomes a `path = …` entry. An empty list means
"sync everything under the roots." See
[path specification](https://github.com/bcpierce00/unison/wiki/Manual#path-specification)
in the upstream wiki for the syntax.

Lines beginning with `#` are comments and are kept in place across edits.
When a long line wraps, the continuation is shown with a hanging indent so
you can tell a wrap apart from a new entry. (The same applies to the Ignore
and Exceptions fields.)

### Ignore

- **Ignore patterns**: one pattern per line (`Name *.tmp`, `Path build`,
  `Regex \..*`, `BelowPath foo`). The **Add Common…** menu appends typical
  sets. The reconcile window's right-click Ignore actions append here too.
- **Exceptions (override ignore)**: one pattern per line, written as
  `ignorenot`. A match keeps a path even when an ignore rule would drop it.

### File Attributes

Which file metadata Unison keeps in sync. Each control has a **Default**
state that leaves the setting out of the profile (Unison's standard
behavior):

- **Modification times**, **Resource forks**, **Owner**, **Group**,
  **Suppress chmod**: Default / On / Off.
- **Permissions**: Default, "Ignore permission differences", or **Custom
  mask…**, which reveals a field for an octal (`0o755`), hex (`0x1FF`), or
  decimal mask.

### Options

How a sync runs, as opposed to what is synced:

- **Conflict handling**: Default (ask on conflict), or Prefer / Force a
  root (first, second, newer, or older). "Force" makes one root
  authoritative and overwrites the other; "Prefer" only breaks ties on
  conflicting changes.
- **Confirm big deletions** (`confirmbigdel`), **Auto-accept changes**
  (`auto`), **Fast update check** (`fastcheck`), Default / On / Off.
- **Write a log file**: toggles `log`. Which fields appear depends on the
  global logging mode set in [Settings → Logging](#logging): shared-file
  mode shows just the checkbox, shared-folder mode adds a file name, and
  per-profile mode adds a folder and a file name.

### Includes

Pull in another prefs file with an `include` directive. Each row is a file
name (the dropdown lists the other `.prf` files in your Unison directory,
or you can type a name), an optional **comment** line, and a **Top / Bottom**
position:

- **Top**: applied before this profile's own settings, so this profile
  wins single-value conflicts.
- **Bottom**: applied after, so the included file wins.

For list-valued prefs (ignore, ignorenot, path) the position has no effect;
they accumulate either way. Use this to share a list across profiles, for
example a "common" file of ignore patterns. Note that an `include` pulls in
the *entire* target file, so a shared list file should contain only the
relevant lines. A banner at the top of the editor notes when a profile
includes others.

Profile names with spaces are fine, they're written back-slash-escaped
(`include File\ System\ Ignores.prf`), which is how Unison reads a name as a
single word. The `.prf` extension is added on the saved line for clarity;
the editor still shows you the bare profile name.

### Advanced (other prefs)

A raw `key = value` box for any preference the form doesn't surface. One
entry per line. Unknown keys, comments, and blank lines all survive a
load-edit-save round trip unchanged. Settings that have their own section
(and `include` directives) can't be saved from here: the editor stops you
and points you to the right section, so nothing is silently dropped.

Full reference: the [Preferences section of the upstream
wiki](https://github.com/bcpierce00/unison/wiki/Manual#preferences).

### Save / Cancel

`Save` writes the `.prf` atomically after backing up the previous version
to `.prf.bak`. `Cancel` discards everything.

---

## The Reconcile window

Opens when you click Run on the picker. Initially in "scanning" mode
showing the indeterminate progress bar; populates with the list of
differences once Unison's `init1` + `init2` complete (init1 sets up the
roots and any SSH connection, that's where credential prompts appear,
and init2 walks both replicas to compute differences).

### Anatomy

```
┌─────────────────────────────────────────────────────────────────────┐
│ [Profiles] [Rescan] | [← First | → Second | Skip | Merge] | [Go] │ ← toolbar
├─────────────────────────────────────────────────────────────────────┤
│ 142 items · 1.2 GB · 3 conflicts · 12 First → Second              │ ← summary
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

- **Path**: the file's relative path within the replica. Folder rows
  show a tinted folder icon (system blue); leaf rows show a neutral
  document icon. Names truncate with `byTruncatingMiddle`; the full
  path is available as a hover tooltip when truncation happens.
- **First / Second**: SF Symbol status icons summarizing what changed
  on each side since the last sync:
  - ➕ Created (green)
  - 🔵 Modified (hollow blue circle)
  - 🔘 PropsChanged (dashed blue), only metadata changed
  - ➖ Deleted (red)
  - · Unchanged (tiny gray dot) or absent
- **Action**: what the sync will do for this row. The badge shows
  either the **direction** (→ Second / ← First, green / blue) for
  auto-resolved rows, OR the **user's decision** when an override is
  pinned:
  - ⚠ (orange), auto-detected conflict, needs your attention
  - ⊖ (gray), user-skipped (Skip applied)
  - ↺ (brown), Force Older applied (mtime-based decision; arrow hidden
    on purpose so you can tell forced vs. deliberate left/right)
  - ↻ (teal), Force Newer applied
  - M (purple), Merge will run (requires `merge = …` in the `.prf`)
  - → (green), propagate first → second
  - ← (blue), propagate second → first

  Folder rows show an aggregate badge: same glyph/tint as a leaf when
  every descendant agrees, empty when descendants disagree.
- **Size**: file size, formatted by `ByteCountFormatter`.
- **Progress**: populated during sync. Shows a standard macOS
  `NSProgressIndicator` bar (follows your **System Settings →
  Appearance → Accent color**) for in-flight rows, full bar when
  finished, and a bold red **`⚠`** marker on rows whose transfer
  didn't complete. Hover the ⚠ to see the full failure reason in a
  tooltip; the same text is also shown in the details panel at the
  bottom of the window when the failed row is selected. Empty when
  idle.
- **Type**: `FILE`, `DIR`, `SYMLINK`, etc., as Unison reports.

### Summary line

Above the row list. Live-updates with status messages from OCaml during
scanning ("Looking for changes...", "Reconciling...") and shows a count
summary once the reconcile completes ("142 items · 1.2 GB · 3 conflicts ·
12 First → Second · 4 Second → First").

The status word, when there is one, always leads. Six forms:

| State | Example |
| --- | --- |
| Ready, items to sync | `121 items · 1.2 GB · 121 First → Second` |
| Ready, nothing to do | `Everything is up to date` |
| **Sync in progress** | `Synchronizing · 121 items · 1.2 GB · 121 First → Second` |
| Sync complete, all clean | `Synchronization complete · 121 items · 1.2 GB · 121 First → Second` |
| Sync complete, partial failure | `Synchronization completed with 5 errors · 121 items · 1.2 GB · 121 First → Second` |
| Sync complete, zero items synced | `Synchronization complete · nothing to transfer` |

During an active sync, the summary line stays pinned to the
`Synchronizing · …` form so the at-a-glance totals (item count,
total bytes, direction split) remain visible throughout the
transfer. The dynamic state, *which* file is currently moving and
how far along, is conveyed by the global progress bar above the
file list and by the per-row Progress column inside it. Mid-sync
errors that attach to a row surface as the per-row `⚠` marker
(hover for reason); the post-sync summary's
`Synchronization completed with N error(s)` covers the aggregate
count. The full raw diagnostic stream (every `displayStatus`
message Unison emits) is also logged to Console.app under subsystem
`net.courbage.unison-ui-mac` for deeper debugging if needed.

The profile name is **not** included in the summary; the window
title carries it (`Unison — <profile>`). Each direction breakdown reads
`<count> <source> → <destination>` so the arrow always points
left-to-right in reading order, regardless of which side data
flows toward. "First" and "Second" refer to the two replicas (the
two `root = …` lines in the `.prf`), matching the column headers
and the toolbar's `← First` / `→ Second` buttons.

When one or more rows failed during sync, the summary prefix
switches to `Synchronization completed with N error(s)` and each
failed row gets a red `⚠` marker in its Progress column. Hover the
marker to read the per-row failure reason; the same text is also
shown in the details panel at the bottom of the window when the
failed row is selected.

The size figure between the item count and the breakdown is the **total
bytes that will move if you hit Go now**. Sum of file sizes for rows
with a clear direction arrow (`←` First or `→` Second); conflicts and
`<-M->` merge rows are excluded, conflicts won't transfer until
resolved, and merge runs an external command whose byte output isn't
predictable in advance. User overrides on conflict rows aren't reflected
in this total (same convention as the count breakdown), rescan refreshes
the snapshot after manual changes if you want an updated total.

If a status message has multiple lines (typically SSH connect failures
dumping stderr), a **"Details…"** button appears next to the summary
line. Clicking it pops up a scrollable, selectable view with the full
text. The summary label's hover tooltip also carries the full text as a
one-hover alternative.

### Progress column

During a sync, each **file** row shows its own transfer progress in the
Progress column (a bar that fills as bytes move; `done` when complete; a
red `⚠` on failure, hover for the reason).

A **collapsed folder** row shows an *aggregate* bar summarizing the
transfer of everything hidden beneath it, so you can watch a whole branch
advance without expanding it. The fraction is byte-weighted, a large file
contributes more than a small one, and falls back to a simple
done-count when the folder's items carry no size (e.g. a folder of
deletions). Expanding the folder clears its aggregate bar (its children
then show their own); collapsing it again brings the summary back.

### Global progress bar

Visible during init2 (indeterminate) and during sync (determinate). Hidden
when idle.

### Toolbar

- **Profiles**: return to the picker (closes this reconcile window). Its
  label and position never change. Leaving during a connect or scan does
  **not** cancel it; the connection or scan keeps running in the background
  until it finishes on its own (for a remote session the app then closes the
  connection; a local-only session has no connection and simply goes idle).
  There is no in-place "stop the scan" control; if a remote scan hangs, quit
  and relaunch. Leaving during a sync raises a confirmation first (see Stop).
- **Rescan**: re-run init2 without re-initializing the SSH connection.
  Useful when files have changed on either side and you want a fresh
  view. Disabled while a scan or sync is already running.
- **← First / → Second / Skip / Merge**: direction overrides for the
  selected leaf rows. Multi-select supported; selecting a folder applies
  to every leaf under it.
- **Go** (green): synchronize. Propagates every row's Action.
- **Stop**: the sync-abort control, always in the same position. It is
  enabled and red only while a sync is running, and disabled and neutral
  otherwise. Aborting signals Unison to stop at its next checkpoint (between
  files), so a transfer already in flight may finish before the abort takes
  hold. The window stays open afterward so you can inspect any rows left
  `⚠ FAILED` in the Progress column; close it or Rescan when you're ready.
  To leave during a connect or scan, use Profiles, not Stop.
- **Quit**: quit the app, identical to `⌘Q` (runs the clean OCaml
  bridge shutdown on the way out).

### Details footer

A non-editable `NSTextView` at the bottom. Selecting a leaf row shows the
OCaml-computed details (size, mtime, conflict reason). Selecting a folder
shows the folder's full path plus the count of items under it.

### Row context menu (right-click)

- **Diff** (top: most common right-click intent) → opens the diff viewer.
- (separator)
- **Ignore Path / Ignore Extension / Ignore Name**: adds a new `ignore`
  pattern to the profile's `.prf` *immediately* (no confirmation), then
  re-filters the row list. **The pattern is permanent**, it persists in
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
is metadata (PropsChanged). It does **not** reject binary files,
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
- Reuses across multiple Diff invocations, clicking Diff on another row
  updates the same window in place.
- Survives the reconcile window closing (you can keep reading the diff
  after going back to the picker).

When `displayDiffErr` fires (Unison can't produce a diff for some
reason), the window switches to an error view: red header + raw error
text. Pick another row's Diff to recover.

---

## Settings

Opens via `Unison-UI-Mac → Settings…` (⌘,). A toolbar-tab window
(System Settings style) with six tabs that resize the window to fit:

- **Saved State**: *implicit* state the app remembers and lets you
  reset: profile picker layout, SSH version-mismatch suppressions, and
  window & toolbar layout.
- **Reconcile**: how the reconcile window renders differences.
- **Sync**: the end-of-sync notification and sound (actual on/off
  preferences you set directly).
- **Logging**: how log file locations are chosen across profiles.
- **Maintenance**: Archive Maintenance, a **Clean Stale Archives** scan.
  It lists archives that no current profile uses, but only offers to
  remove the ones it can prove are a superseded generation (an older copy
  a current profile has already replaced with a live archive). Orphans,
  "probably old" copies, anything involving a remote replica, and anything
  it can't attribute unambiguously are shown for review but are not
  selectable. Removal is recoverable (Trash) and runs through the
  crash-safe transaction; live archives are never listed.
- **Updates**: Software Updates, direct toggles for whether the app
  checks for updates automatically and whether it sends an anonymous
  system profile with the check. Shown only when the Sparkle updater is
  present in the build.

Settings and the profile editor can't be open at the same time. Because a
logging change here can rewrite `.prf` files, the **Settings** menu item is
greyed out while a profile is open for editing; and opening a profile editor
while Settings is open is blocked with a "Close Settings first" prompt
(Settings is brought forward instead). This prevents a Settings change from
conflicting with unsaved edits.

Most of the Saved State items are reset/clear actions on remembered
state (you hide a profile by clicking its eye icon, dismiss a
version-mismatch alert via its checkbox, etc.); the **Sync** and
**Updates** tabs are where you toggle preferences directly.

### Profile picker layout

Shows counts ("3 hidden profiles · 7 in custom order") for the keys
`profiles.hidden` and `profiles.order`. The **Reset** button clears
both, after a reset, every `.prf` is visible in alphabetical order in
the picker. The `.prf` files themselves are untouched; this is purely
UI presentation state.

### SSH version-mismatch suppressions

A table of `(host, this-Mac-version, remote-version)` triples that
you've dismissed via the "Don't remind me again" checkbox on the
[Version-mismatch warning](#version-mismatch-warning-on-profile-open).
Each row can be selected and removed individually via **Remove
Selected**, or wiped en masse via **Clear All** (which has a confirm
sheet because it's a bulk destructive action; per-row removal doesn't
prompt, one accidental removal is cheap to re-suppress next time the
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

Currently-open windows are not moved by the reset, autosaves are
written on close and read on open, so the effect only takes hold the
next time each window is opened. The reset alert spells this out.

### Reconcile display

Two pickers that control how the reconcile window renders the list of
differences. Mirrors upstream Unison's "Switch table nesting"
segmented control plus a smart-expand option that upstream calls
`expandConflictedParent`.

**Layout**:

- **Nested (collapsed)** *(default)*: folder tree by path components,
  with any folder whose only child is another folder merged into a
  combined-name row (`a/b/c/leaf.txt` instead of four separate folder
  rows). Compact for deep paths through otherwise-uninteresting
  directories.
- **Nested (full)**: every folder level is its own row. Most
  hierarchical, busiest visually.
- **Flat list**: every leaf is a top-level row. Sorted list of full
  paths, no folder nodes, no chevrons. Useful when the user wants
  to scan "did file X get touched?" without navigating a tree.

**Expand on open** (applies on every fresh populate: initial scan
or rescan; user-driven expand/collapse during a session is untouched):

- **Smart (only branches with conflicts)** *(default)*: only folders
  whose subtree contains a row needing the user's attention
  (unresolved conflict) are pre-expanded. Other folders stay
  collapsed. The user lands on what needs doing.
- **All branches**: every folder is pre-expanded. The Finder-style "outline fully open" behavior.
- **Top level only**: nothing pre-expanded; only top-level entries
  visible. Useful for very large diffs where the user wants to
  navigate by clicking in.

Both settings take effect on the **next reconcile populate** (rescan
or profile open). Already-open reconcile windows aren't re-laid out
live, the section description in Settings spells this out.

**Post-sync failure reveal.** When a sync finishes with one or more
failures, the app expands the ancestor chain of every ⚠ FAILED row,
even when the user's configured policy is `Smart` or `Top level
only` and those rows would otherwise stay collapsed out of view. The
user's setting isn't mutated; this is a one-shot widening for the
current sync result, reverted on the next rescan. The configured
policy still governs the pre-sync (just-rescanned) view.

### Sync completion

Two checkboxes controlling the optional cues fired when a sync
finishes (both **on by default**):

- **Show a notification when a sync finishes**: posts a Notification
  Center banner ("Sync complete", or "Sync finished with N errors").
- **Play a sound when a sync finishes**: a chime on a clean sync, the
  system error tone when there were failures.

Unlike the other sections (which inspect/reset implicit state), these
are real, explicitly-set preferences, stored under
`sync.complete.notify` and `sync.complete.sound`.

Independent of these toggles, the reconcile summary **always** shows
an inline result badge when a sync ends, a green ✓ (clean) or red ⚠
(errors), with the summary text tinted to match.

> **Banner not appearing?** macOS suppresses notification banners
> while you're **screen sharing**, and routes them silently to
> Notification Center when **Scheduled Summary** ("Summarize
> notifications") or a **Focus** filter is active. The notification
> still lands in Notification Center, and the inline ✓/⚠ badge and the
> sound are unaffected. See [Troubleshooting](#sync-complete-notification-doesnt-pop-up).

### Logging

Controls how each profile's `logfile` is chosen. A **Mode** popup with
three choices, and a path field whose label follows the mode:

- **All profiles share one log file**: every profile that has logging on
  writes to the same file. The field is that file's path.
- **All profiles share one folder (one file each)**: a shared folder; each
  profile gets its own file in it (`Unison-<profile>.log` by default). The
  field is the folder.
- **Each profile has its own location** *(default)*: every profile sets
  its own path in its editor. The field is a **default folder** used only
  to pre-fill a new profile's path; it is never forced and never changes a
  profile you've already configured.

The default location is Unison's own directory
(`~/Library/Application Support/Unison`), alongside your profiles and
archives.

When you switch into a shared mode (or change its file/folder), the app
asks whether to **apply it to every profile that already has logging on**.
This is all-or-nothing: choose **Update All** to rewrite those `.prf`
files, or **Don't Update** to leave them as they are (new saves still use
the current shared location). The prompt supports Return (Update All) and
Escape (Don't Update).

The `logfile` line is written into each profile's `.prf` (which is what
Unison reads). The matching per-profile controls live in the editor's
**Options** section: see [Write a log file](#options).

### Command Line

Shows what the `unison` command resolves to right now, for two PATHs, read
from the filesystem each time the tab is shown (nothing here is a stored
preference):

- **Terminal**: the PATH obtained by running your login shell
  non-interactively. An interactive Terminal also reads `.zshrc`, which can
  change what `unison` resolves to there.
- **Remote SSH command**: not determined locally. The PATH an incoming ssh
  command receives depends on the SSH server configuration and on the login
  shell's startup files on this Mac, which the app does not evaluate. Set
  `servercmd` in the peer's profile to the link's full path so the peer does
  not rely on remote PATH at all.

Each line names the first `unison` entry on that PATH, broken links
included, and says what it is: this app's command, another copy of this app,
Homebrew-managed, the Homebrew `unison` formula, upstream Unison.app's
command, a broken link, or something else. When a broken link comes before a
command that works, both are named, because repairing the link changes which
command the name reaches.

One button is offered at a time, and only when the evidence supports it:

- **Install…** when neither PATH holds a `unison`. Creates
  `/usr/local/bin/unison` as a link to this app's launcher after an
  administrator password.
- **Repair…** when the first entry is a broken link to a former copy of this
  app's launcher. The confirmation shows the old target and, if a working
  command sits later on the PATH, names it as the one that will no longer be
  reached.
- **Remove…** when the entry is this installation's link. Deletes it; the app
  keeps working from the profile picker.

Anything else (the formula, upstream's command, Homebrew's link, another copy
of this app) is shown and left alone.

**First-launch offer.** When neither PATH holds a `unison`, or the first
entry is a broken link to a former copy of this app, the app offers Install
or Repair once per launch after the picker appears. "Not Now" asks again next
launch; "Do not ask again" stops the offer, and the Command Line tab remains
the way to install later.

### What's stored, and where

Everything lives in `~/Library/Preferences/net.courbage.unison-ui-mac.plist`,
accessed via the standard `UserDefaults` API. That domain also holds the
Sparkle-owned update preferences (the **Updates** tab writes them through
Sparkle, not as app keys of its own). The keys this app writes:

| Key | Purpose |
|---|---|
| `profiles.hidden` | Basenames of profiles hidden from the picker |
| `profiles.order` | Custom picker order |
| `versionMismatch.suppressed` | List of suppressed `host\|local\|remote` triples |
| `reconcile.layoutMode` | `flat` / `nestedCollapsed` / `nestedFull` |
| `reconcile.expandPolicy` | `smart` / `all` / `rootOnly` |
| `sync.complete.notify` | Show a Notification Center banner on sync completion (default on) |
| `sync.complete.sound` | Play a sound on sync completion (default on) |
| `commandLineTool.doNotAsk` | "Do not ask again" on the first-launch offer to install the `unison` command |
| `NSWindow Frame <name>` | AppKit auto: window position/size per window |
| `NSToolbar Configuration ReconcileToolbar.v6` | Reconcile toolbar customization |

Sparkle also manages update keys in this same domain, set from the **Updates**
tab and the first-launch prompt: `SUEnableAutomaticChecks` (automatic update
checks) and `SUSendProfileInfo` (send the anonymous system profile), plus its
own bookkeeping (e.g. `SULastCheckTime`). These are owned by Sparkle; change
them through the Updates tab rather than by hand.

You can inspect them directly with `defaults read net.courbage.unison-ui-mac`,
or wipe everything in one shot with `defaults delete net.courbage.unison-ui-mac`,
but the Settings window gives you fine-grained control by category.

---

## The menu bar reference

### `Unison-UI-Mac` menu

Standard macOS app menu: About, Check for Updates… (the Sparkle updater),
Settings… (⌘,), Services, Hide, Quit.
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
| Ignore Path | (none) | Add `ignore = Path "<row's path>"` to the profile |
| Ignore Extension | (none) | Add `ignore = Name {,.}*"<.ext>"` |
| Ignore Name | (none) | Add `ignore = Name "<basename>"` |
| Profile Editor… | ⌘⇧E | Open the manager window |

The three Ignore items dispatch to the reconcile window when it's key;
otherwise they're greyed.

### Action menu (reconcile-window operations)

| Item | Shortcut | Action |
|---|---|---|
| Go | ⌘⏎ | Start synchronizing the current row decisions. Disabled mid-sync and before init2 has populated rows. |
| Stop | ⌘. | Abort a running sync. Disabled when no sync is running. (See [Stop button](#stop-button-how-abort-works) for the abort semantics.) |
| Rescan | ⌘⇧R | Re-run init2 against the current profile. Disabled while a scan or sync is already running. |
| Rescan Ignoring Archives… | (none) | Re-open the profile with a one-shot `ignorearchives` to recover from an "archive inconsistency" (confirms first). Enabled only with a reconcile window open. See [Troubleshooting](#archive-inconsistency-fatal-mid-reconcile). |
| Show Profile Picker | ⌘⇧P | Close the reconcile window and return to the launch picker (the just-run profile stays highlighted). Disabled mid-sync, use Stop or ⌘W (which triggers the mid-sync confirm sheet) instead. |
| → Second | `>` | Propagate first → second for selected leaves |
| ← First | `<` | Propagate second → first |
| Skip | `/` | Mark selected leaves as user-skipped |
| Merge | (none) | Run the configured `merge` command on selected leaves (greyed if `merge` pref isn't set) |
| Force Older | (none) | Pick the older-mtime side for each selected leaf |
| Force Newer | (none) | Pick the newer-mtime side |
| Diff | (none) | Open the diff viewer for the selected (or right-clicked) leaf |
| Select Conflicts | (none) | Select every leaf row that's still unresolved (`<-?->` with no user override) |
| Revert to Unison's Recommendation | (none) | Clear user overrides on selected leaves |

All items dispatch via the responder chain to `ReconcileWindowController`
when the reconcile window is key. Disabled when no reconcile window is
key. Direction items are disabled during sync.

The three workflow shortcuts follow macOS conventions:
**⌘⏎ "submit / run"** (matches Mail's Send and similar primary actions),
**⌘.** for "cancel currently running operation" (system-wide since
System 6), and **⌘⇧R** for Rescan, parallel to Safari/Mail's "Reload"
and distinct from Profile Editor's ⌘R refresh so the two never collide.

### Window menu

Standard: Minimize, Zoom, Bring All to Front.

### Help menu

- `Unison-UI-Mac Help` (⌘?), opens this app's MANUAL (this document) on
  GitHub in the browser.
- `Unison File Synchronizer Manual`, opens the full upstream Unison
  reference manual, rendered to HTML and bundled with the app (works
  offline). The HTML is the hevea-rendered output of upstream's
  `doc/unison-manual.tex` at the Unison version this app embeds; see
  the About panel for the exact version. Falls back to the upstream
  wiki if the bundled resource is missing.
- `Report an Issue`, opens GitHub's new-issue form for this repo
  with an Environment block pre-filled (app version, embedded Unison
  version, macOS version, architecture). The repo's bug-report
  template provides the rest of the structure. You'll need a GitHub
  account to file the issue itself.
- `Donate`, opens the project's GitHub Sponsors page in the browser.

No File menu, this isn't a document-based app. ⌘W still closes the
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
| `>` / `<` (in reconcile window) | Set selected rows to → Second / ← First |
| `/` (in reconcile window) | Skip selected rows |
| ⌘⇧P (in reconcile window) | Show Profile Picker |
| ⌘? | App help |
| ⌘W | Close focused window |
| ⌘M | Minimize focused window |
| ⌘Q | Quit |
| ⌘F (in diff window) | Find bar |

No keyboard shortcuts on Action-menu items by design, they're frequently
applied to multi-row selections where a mouse is usually already in
play. Add custom shortcuts via System Settings → Keyboard → Keyboard
Shortcuts → App Shortcuts if you want them.

---

## Troubleshooting

### "Archive inconsistency" fatal mid-reconcile

Unison detected that its archive files are out of sync (typically from a
crashed sync). A modal alert appears with the offending archive list,
offering two recoveries:

- **Retry Ignoring Archives**: always available. Unison rebuilds its
  state by comparing the two replicas directly, ignoring the saved
  archive for one scan. Use this when the missing or extra archive is
  on the remote host (nothing local to delete), or whenever you just
  want to get going again. The scan may show more rows than usual, so
  review them before you sync. Your profile file is not changed.
- **Delete N Orphan Archive(s) and Retry**: shown only when orphaned
  archive files exist on this Mac. Removes them and retries.

You can also trigger the first option yourself any time from **Action →
Rescan Ignoring Archives…**. For pre-emptive cleanup (no error yet, but
suspect): use **Reset Archives…** in the Profile Editor.

### SSH "permission denied" / "host key changed"

Unison runs SSH with whatever your `sshcmd` / `sshargs` prefs specify,
and the macOS system SSH config. If you need a specific key or non-
default host, set them in the Advanced field of the Profile Form. The
multi-line error appears in the reconcile window's summary line, click
**Details…** for the full text (especially useful when the SSH client
returns a multi-line key fingerprint check or similar).

If you are re-entering your password on every reconnect, switch that profile to
SSH key authentication instead of passwords: see [Avoiding repeated password
prompts](#avoiding-repeated-password-prompts-recommended-ssh-setup) below.

### Avoiding repeated password prompts (recommended SSH setup)

unison-ui-mac never stores or replays your credentials. Every SSH prompt is
passed straight through from the system `ssh`, and the app cannot tell whether a
given prompt is a password, a key passphrase, or a one-time code. So the place to
stop re-entering a password on every reconnect is your SSH configuration, not the
app: switch the profile to **public-key authentication** with Apple's system
client at `/usr/bin/ssh`, and let macOS hold the key's passphrase.

The steps below call the tools by their explicit `/usr/bin/` paths on purpose.
`UseKeychain` and `--apple-use-keychain` are features of Apple's OpenSSH; a
non-Apple OpenSSH earlier in your `PATH` does not honor them. Such a client
rejects `UseKeychain` in a config it reads (hence the `IgnoreUnknown` guard
below), and `ssh-add --apple-use-keychain` fails on the unknown option rather
than caching the passphrase. A bare `ssh` / `ssh-add` could be that wrong client.

**1. Create a key** (skip if you already have one):

```
/usr/bin/ssh-keygen -t ed25519
```

**2. Verify the server's host key before sending any secret.** Connect once by
hand and check the fingerprint against one you obtained through a trusted channel
(the server's administrator, or `ssh-keygen -lf <host-key-file>` run on the
server itself):

```
/usr/bin/ssh my-user@server.example.com
```

ssh prints the host-key fingerprint and waits; answer `yes` only once it matches.
It then asks for your account password, which now goes to a host you have
verified. This order matters: never accept an unseen host key and type a password
in the same breath, or a machine-in-the-middle could capture it.

**3. Install your public key** so future logins use the key, not the password.
The host is already trusted from step 2, so this does not re-prompt for it.
`ssh-copy-id` resolves its own child `ssh` through `PATH` (its script sets
`SSH="ssh -a -x"`), so pin `PATH` to the system directories for this one command:

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/ssh-copy-id -i ~/.ssh/id_ed25519.pub my-user@server.example.com
```

**4. Add a host block to `~/.ssh/config`:**

```
Host my-server
    HostName server.example.com
    User my-user
    IdentityFile ~/.ssh/id_ed25519
    AddKeysToAgent yes
    UseKeychain yes
```

**5. Store the key's passphrase in the macOS Keychain, once:**

```
/usr/bin/ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

**6. Confirm key-based login works, using the alias:**

```
/usr/bin/ssh my-server
```

It should log in with no password prompt. If it still asks for a password, the
key most likely was not installed or accepted (this command already pins the
client, so it is not a `PATH` issue): run `/usr/bin/ssh -v my-server` and check
that the server's `~/.ssh/authorized_keys` contains your public key, that
`~/.ssh` and `authorized_keys` have safe permissions (`700` and `600`), and that
the identity being offered is the one you installed.

**7. Point the profile at the alias, not the raw host.** In the app, set the
remote root to use the `my-server` alias, for example
`ssh://my-server//Users/me/data`. Using `server.example.com` directly does **not**
match the `Host my-server` block, so the `IdentityFile` and `UseKeychain` settings
would not apply and you would be back to password prompts. If the app is using a
non-Apple `ssh` from your `PATH`, set the profile's `sshcmd` to `/usr/bin/ssh`, or
rely on the agent from step 5 (any client can use a key already loaded there).

**What is and isn't stored.** The macOS Keychain holds your *private key's
passphrase*, never the remote account's password. unison-ui-mac itself stores
nothing and replays nothing; all key handling belongs to OpenSSH and macOS.

If you share `~/.ssh/config` with a non-Apple OpenSSH (for example on Linux),
guard the macOS-only option so those clients don't reject the file:

```
Host my-server
    IgnoreUnknown UseKeychain
    UseKeychain yes
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
```

Avoid these "shortcuts"; each trades real protection for convenience:

- Disabling host-key verification (`StrictHostKeyChecking no`): removes the
  guarantee that you are connecting to the intended server.
- Leaving the private key unencrypted (no passphrase): an encrypted key held by
  the agent is just as convenient and far safer.
- `UserKnownHostsFile=/dev/null`: discards host-key memory entirely, so a
  machine-in-the-middle cannot be detected.

### A profile won't open from the GUI but works from the CLI

Likely cause: the `.prf` references `~` or relative paths that resolve
differently in the GUI's process environment. Use absolute paths in the
Profile Form's root fields.

Also: any preference that requires interactive CLI flags (e.g.,
`-ignorearchives`) won't work here, those are command-line-only and
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
context menu) calls Unison's `Abort.all` on the OCaml side (the
mid-sync abort was upstreamed in bcpierce00/unison#1198, so this is no
longer a fork patch). The in-flight sync worker observes the abort at
its next `Abort.check` checkpoint, typically between file transfers,
and unwinds by raising the internal `Aborted by user request` transient.

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
completion, useful when you want to reclaim screen space but not
interrupt the transfer.

### Sync-complete notification doesn't pop up

You finished a sync but never saw the banner. This is almost always
macOS holding it, not the app failing to send it, the notification
still lands in **Notification Center** (click the clock to check). The
common causes:

- **Screen sharing.** macOS suppresses *all* notification banners
  while you're sharing your screen (a privacy feature). They appear
  silently in Notification Center instead.
- **Scheduled Summary** ("Summarize notifications", in System Settings
  → Notifications). When the app is included in a summary, individual
  banners are held and batched. Exclude Unison-UI-Mac from the summary
  (or turn the summary off) for immediate banners.
- **Focus.** An active Focus filter can route the banner straight to
  Notification Center.

The inline green ✓ / red ⚠ badge in the reconcile window and the
completion sound don't depend on any of this, they always fire (when
the sound toggle is on). See [Settings → Sync completion](#sync-completion).

### The app starts slowly / OCaml takes time to spin up

First launch involves `caml_startup` and a few hundred milliseconds of
OCaml runtime setup. Subsequent launches reuse the same `.app` bundle.

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

Unified Logging gives you filterable categories, structured search, and
persistence across reboots without the disk-hygiene problem of a stray
/tmp file.

### Version-mismatch warning on profile open

When you open a profile that has an `ssh://…` root, the app spawns a
one-shot `ssh -o BatchMode=yes host servercmd -version` in the
background and compares the result with the locally-embedded Unison
version. **You only see a warning when the two sides straddle Unison's
2.52.0 wire-protocol boundary**, i.e., the local side is >= 2.52.0
and the remote is < 2.52.0, or vice versa. Same-side-of-boundary
differences (e.g., `2.54.0` ↔ `2.53.8`) negotiate features through
the new wire protocol and don't warn.

The alert looks like:

> **Unison wire-protocol incompatibility**  
> This Mac has Unison 2.54.0. The remote (server.example.com) is
> running 2.51.5. Unison changed its wire protocol at version 2.52.0,
> and the two sides here are on opposite sides of that change, they
> cannot connect to each other. Update the older side to a release
> >= 2.52.0.
>
> ☐ Don't remind me again for this host (until either version changes)

The checkbox persists per `(host, localVersion, remoteVersion)` triple.
Once you suppress it, you won't see it again for that exact combination,
but as soon as you upgrade either side, the triple changes and you'll
see the alert again so you can re-confirm.

**Rationale for the 2.52 boundary**: Unison 2.52.0 introduced the
"new wire protocol" with feature negotiation, so any pair of versions
>= 2.52.0 interoperates regardless of which exact minor release each
side runs. The app alerts only when the wire protocol itself is
incompatible.

**The probe is silent in normal operation**:
- Uses `BatchMode=yes`, won't prompt for a password. If the remote
  requires password auth, the probe fails silently and no alert
  appears (Unison's own connection will prompt as usual for the
  actual sync).
- Uses `ConnectTimeout=5` for the TCP/SSH connection; the overall probe
  has a 20-second wall-clock deadline for the remote work, after which it
  is terminated and reported as a timeout.
- `StrictHostKeyChecking=yes`: the probe never adds or changes a host key,
  so it cannot alter your trust state. A first-time or changed host key
  makes the probe fail (no alert); Unison's own connection then handles
  host-key acceptance for the actual sync.

**Limitations**:
- Honors an **absolute** `sshcmd` and the profile's `sshargs` (so it
  authenticates like the real sync, including an `-i <key>` in `sshargs`);
  a bare, non-absolute `sshcmd` falls back to `/usr/bin/ssh`. If your
  Unison SSH config differs significantly from your shell SSH config, the
  probe still mirrors the profile's own settings.
- Doesn't check `socket://` profiles. There's no `-version` probe
  for socket-mode Unison servers without going through the actual
  Unison protocol.
- Only checks the FIRST `ssh://` root in the profile. The pathological
  case of two `ssh://` roots pointing at different hosts is not
  fully covered.

### What happens when a new version of Unison is released?

Two halves of the answer, for the **local** side (the embedded Unison)
and for the **remote** side (any `ssh://…` peer).

**Local side (the embedded copy).** This app links in the committed
vendored blob (`vendor/unison-blob-<version>-<arch>.o`); the version is
frozen at build time. An ordinary `make build` uses that committed blob,
so it does **not** recompile from a local upstream checkout and does
**not** change the embedded version.

- **Ordinary users** receive embedded-engine upgrades through app
  releases (the in-app Sparkle update, or a fresh download). There is
  nothing to do locally.
- **Maintainers** bump the embedded engine deliberately: check out a
  reviewed upstream commit under `UNISON_SRC`, run `make vendor-blob`
  (and `make vendor-manual` to refresh the bundled Help manual), update
  the provenance and SHA-256 in `vendor/README.md`, then rebuild and
  commit the refreshed blob. See `docs/vendored-patches-upstream.md` and
  the vendor-bump checklist.

The About panel shows the embedded version so you can verify after an
upgrade.

**Remote side (`ssh://…` profiles).** Unrelated to local rebuilds. You
update the remote Unison the way you'd update any CLI on that machine
(`brew upgrade unison`, `apt upgrade unison`, etc.). The two Unisons
negotiate compatibility at connection, see the upstream wiki's
[Cross-Platform Issues / Compatibility](https://github.com/bcpierce00/unison/blob/master/doc/unison-manual.tex)
section. As a rule of thumb:

- Versions on the same side of the 2.52.0 wire-protocol boundary
  (e.g., `2.52.0` ↔ `2.54.0`, or `2.54.0` ↔ `2.54.3`) interoperate
  via feature negotiation in the new wire protocol.
- Versions straddling 2.52.0 (e.g., `2.51` ↔ `2.54`) do NOT
  interoperate: Unison 2.54.0 removed the old wire protocol
  entirely. The UI surfaces a warning for this case, only for the
  actual incompatibility.

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

For day-to-day usage: a remote at `>= 2.52.0` interoperates with this
app's embedded 2.54.0, so upgrading the remote (`brew upgrade unison`,
etc.) does **not** require rebuilding the app. You would only need a
newer embedded engine (a maintainer vendor-blob bump, delivered in an
app release) if a remote is stuck below 2.52.0 and cannot be upgraded.

### Profile won't sync but CLI `unison <profile>` works

Three things to check, in order of likelihood:

**1. `clientHostName` divergence.** If you've set this pref in your
`.prf` to a value that differs from what `gethostname()` reports
(which is what `ProcessInfo.hostName` returns), the archive hashes
diverge between CLI and GUI. Either remove the `clientHostName`
override, or set `UNISONLOCALHOSTNAME=<your-hostname>` in the launch
environment so both pick up the same value.

**2. Command-line argument overrides.** This app launches OCaml with
`argv = [program_name]`, no CLI args propagate from your shell to
Unison. So if you typically run `unison -opt=val <profile>` to
override a preference at the command line, the GUI won't apply that
override (it only sees the `.prf` content). Put the override in the
`.prf` itself via the Advanced field of the Profile Form to bring
the GUI into parity.

**3. Multi-profile session quirk.** If you switch profiles within
one GUI session (via the picker), the GUI doesn't re-parse the
command line for the new profile, only on first launch. The CLI
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
- **Change how Unison's text interface behaves.** `unison -ui text` through
  the bundled command (see [The `unison` command](#the-unison-command)) runs
  upstream's own text interface on the embedded engine, unchanged, which is
  still the right tool for `crontab` / `launchd` automation. This GUI is for
  interactive use.
- **Run as a menu-bar status item or background daemon.** Foreground app
  only, one reconcile window per profile open at a time.

---

For everything else, the [upstream
wiki](https://github.com/bcpierce00/unison/wiki) is the authoritative
reference. This GUI is just a way of driving Unison; the synchronization
semantics, the `.prf` format, the conflict-resolution rules, all of
that is Unison.
