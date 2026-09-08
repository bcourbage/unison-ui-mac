# Command-line setup

**Status:** Proposed design, under review
**Scope:** How a user's `unison` command comes to run this app. Replaces the takeover-with-restoration design in this PR's earlier revisions. Separate from the guided remote-profile check.

## Purpose

A user who prefers this app should be able to type `unison` in Terminal and get it, and to name this app's command from another machine. The app achieves both without writing outside the user's own files: the command lives inside the bundle, and the user's login shell is told where to find it.

The app's role: "Put this app's command on your PATH, and keep it there while you want it." It never writes to a system directory, never requests administrator authorization, and never replaces another program's command. It edits a startup file automatically only inside a narrow, stated set of conditions; everything outside them is Manual setup, where the pane shows what to add and where. Homebrew's link is Homebrew's operation.

## The command inside the bundle

`Contents/SharedSupport/bin/unison` is a symlink to `../../MacOS/cltool`; the launcher resolves its own path with `realpath` and requires the `/Contents/MacOS/cltool` suffix, so it needs no change. The directory holds only that entry. The symlink is part of the signed bundle; `scripts/sign-app.sh`, `scripts/test-cltool.sh` and `scripts/smoke-cli.sh` gain a case resolving the command through it.

**Bundle precondition for adding.** Before Add Terminal Setup, Use This Copy, or a startup rewrite, the app checks that `Bundle.main` contains `Contents/SharedSupport/bin/unison`, a symlink whose resolved path is this bundle's `Contents/MacOS/cltool`, and that the target is a regular executable file. Failure blocks those three operations with the note "This app's command is missing from the bundle. Reinstall the app." It does not block Remove Terminal Setup.

## Three facts, kept separate

- **Resolution**: what `unison` resolves to in this account's login shell (the probe).
- **Block state**: whether this app's entry exists in the selected file, what location it records, and whether this account owns it.
- **File safety**: whether the file can be identified, is inside the editable bound, and can be replaced with its metadata preserved.

Each row leads with a verdict line qualified by what established it: **This app selected by the check**, **Another unison selected by the check**, **No unison selected by the check**, **Could not be checked**, **Needs manual setup**. The badge is the short form (This app, Not this app, Not installed, Unknown, Manual setup). The check is the non-interactive login-shell probe, and the limits sentence carries the consequence. Beneath the verdict, in muted monospace, the resolved path is the evidence; a path inside this app's bundle is abbreviated as `unison-ui-mac.app › SharedSupport/bin/unison`, and Copy This App's Command Path carries the full path. Actions and startup writes depend on block state, file safety and, for adding, the bundle precondition. Throughout, a read failure or failed query is "could not be established" and is never treated as absence.

## The PATH entry

### Content

zsh and bash, one block:

```
# >>> unison-ui-mac command >>>
# Managed by Unison UI for macOS (Settings > Command Line). Text inside this block is rewritten by the app.
export PATH='/Applications/unison-ui-mac.app/Contents/SharedSupport/bin':"$PATH"
# <<< unison-ui-mac command <<<
```

fish, one dedicated file `<fish config dir>/conf.d/unison-ui-mac.fish`, whole content:

```
# Managed by Unison UI for macOS (Settings > Command Line). This file is rewritten by the app.
if status is-login
    set -gx PATH '/Applications/unison-ui-mac.app/Contents/SharedSupport/bin' $PATH
end
```

The directory is `Bundle.main.bundleURL` plus `/Contents/SharedSupport/bin`, computed at every write. POSIX serialization is a single-quoted literal with `'` as `'\''` (measured against `$USER`, `$(…)`, backticks, an apostrophe, spaces and a semicolon in zsh and bash: no expansion, no substitution). fish serialization is a single-quoted string with `'` as `\'` and `\` as `\\` (from documentation; to be measured). A path containing a colon, a newline, or bytes that are not valid UTF-8 cannot be represented: Manual setup with the limitation shown, and no setup text offered.

The fish file sets a global variable for that shell only. `status is-login` limits it to login shells, which include Terminal and interactive ssh logins and exclude non-login `ssh host command`. It never touches `fish_user_paths` or any universal variable.

### Selecting the file

Login shell and home directory come from the account record (`getpwuid`), never from `$SHELL` or the launching environment.

| Shell | File | Automatic editing only when | Otherwise |
|---|---|---|---|
| zsh | `$HOME/.zprofile` | the stock layout is established positively: `/etc/zshenv` does not exist (`ENOENT`); `$HOME/.zshenv` does not exist (`ENOENT`); `/etc/zprofile` is readable and byte-identical to a known stock text; `ZDOTDIR` is absent from the launchd user environment as listed by `launchctl print gui/<uid>` (present with any value, empty included, disqualifies; a failed or unparsable query is uncertainty) and absent from the app's own environment | Manual setup, naming `$HOME/.zprofile` as the usual file; the app does not choose. Any `.zshenv`, a non-stock or unreadable `/etc/zprofile`, a set `ZDOTDIR`, or an uncertain query is outside the bound |
| bash | first existing, readable of `~/.bash_profile`, `~/.bash_login`, `~/.profile`; `~/.bash_profile` created if none exists | bash reads only the first (measured) | one of the three exists but cannot be read: Manual setup |
| fish | `$__fish_config_dir/conf.d/unison-ui-mac.fish` | a non-login `fish -c` probe prints an absolute existing directory for `$__fish_config_dir` | Manual setup |
| other | none | never | Manual setup: the directory to add is shown |

Known stock texts are embedded fixtures: the text measured on macOS 26.6.2 (a `LANG=C.UTF-8` default and the `path_helper` eval, nothing else), and the macOS 15 text captured by the release pipeline's macOS 15 job before this feature ships. That gate verifies the recognized stock file on the tested macOS 15 image, not every macOS 15 installation; the evidence preserves the OS version and build and the exact fixture bytes. A future macOS revision that changes the file moves accounts to Manual setup until its text is measured and added; that is the intended refusal, not a defect.

Why the bound is sufficient for what it claims: before zsh selects `$ZDOTDIR/.zprofile` it has read only `/etc/zshenv` and `$ZDOTDIR/.zshenv`, with `ZDOTDIR` initially taken from the environment; `/etc/zprofile` runs before the user's `.zprofile` and could change `ZDOTDIR` for later files. With both `.zshenv` files absent, the variable absent from the environments a Terminal shell inherits, and `/etc/zprofile` known verbatim, the profile read is `$HOME/.zprofile`. The bound is re-established at every launch and before every write; if it stops holding, the account moves to Manual setup and an existing block is reported as present but no longer maintained.

`launchctl getenv` cannot serve the three-way distinction: it exits 0 with no output for both an unset and an empty variable (measured). `launchctl print gui/<uid>` lists a set variable in its environment section, including an empty one, and omits an unset one.

### Editable-file bound (zsh and bash)

A startup file is inside the bound only if all of the following hold. Each failure is Manual setup, with the reason in the note.

1. **No heredoc syntax.** No line of the file contains `<<`, except lines byte-equal to the two marker lines, whose end marker contains that sequence by design. Parse checks accept an open heredoc at end of file (measured), and delimiter matching can be defeated (`cat <<ONE <<TWO` with both delimiters present but the second heredoc still open), so the design does not detect heredoc regions; it refuses files that could contain one. Here-strings and comments containing `<<` are refused by the same rule; false refusals are accepted.
2. **Parses cleanly, whole file and prefix.** `zsh -n` or `bash -n` exits 0 on the whole file and, for a rewrite or removal, on the text before the begin marker. The prefix check refuses a block that a completed multiline quote, function body or compound command has enclosed since it was written, which whole-file parsing alone accepts. Neither check understands shell semantics; together they refuse the constructs this design knows about. What they accept is edited at the user's risk, which is why ownership, effect verification and the manual's limits remain.
3. **Marker grammar.** Zero marker lines (append), or exactly one begin marker followed later by exactly one end marker (rewrite or removal), both at the start of a line. Any other arrangement is refused.
4. **Ownership.** For a rewrite or removal, this account's record must name this file's resolved path and hold a hash equal to the existing block's text. No record, or a different hash, means foreign: the pane says a block exists that this app did not write or that was edited, and shows both texts.
5. **Template match.** The existing block must equal the app's template with some bundle path.
6. **Metadata.** The file is a regular file after following symlinks once, owned by this account, without an immutable flag, and `copyfile(3)` with `COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT` succeeds in cloning its metadata onto the temporary file.
7. **Newline.** A file without a final newline gets one before an appended block. Removal deletes the block lines and the newline after the end marker; in the no-final-newline case a round trip leaves a trailing newline, otherwise text outside the block is byte-identical.

### Ownership record

Per account, in defaults, two slots for the selected file: `confirmed` and `pending`. Each holds the resolved file path, the block hash, the bundle path written, and a date.

- Add or rewrite: write `pending` with the new hash, leaving `confirmed` untouched. If writing `pending` fails, refuse before touching the file: "The entry could not be recorded. Nothing was written."
- Outcome classification: **not mutated** when the failure happens before the rename is issued, or the rename fails with an error that guarantees no change (`ENOENT`, `EACCES`, `EPERM`, `EEXIST`, `ENOTDIR`, `EXDEV`; this list is a reading of `rename(2)` and is verified for both `renameat` and `renameatx_np` with `RENAME_EXCL` during implementation review): delete `pending`; `confirmed` still matches the unchanged file. **Mutated** when the rename returned success: keep `pending`. **Uncertain** when the rename returned any error outside the list: keep `pending`.
- Promotion: after a successful read-back, `pending` becomes `confirmed`.
- Removal: after the file change succeeds, delete both slots.
- Ownership test: the existing block's hash equals `confirmed`, or equals `pending`. A block matching neither is foreign.
- The record is keyed by resolved path, not inode, so an editor's replace-save keeps ownership. A user edit inside the block, or loss of defaults, makes the block foreign; the pane explains and shows the file and block. No automatic recovery.

### Write procedure: replacement

Snapshot on read: resolved target, device, inode, size, modification time, content hash, and an open descriptor on the parent directory. Immediately before the rename, re-read identity and content through the directory descriptor and refuse on any difference: "The file changed while the entry was being prepared. Nothing was written." Then `renameat` of the temporary file over the target within that directory descriptor. Read back and compare before reporting written.

**Residual, stated without a duration:** between the final check and the rename, another writer's save can be lost; scheduling can widen that window. The app writes only its own block; the exposure is the other writer's change in that window. Accepted for editing a user's own startup file and stated in the manual.

### Write procedure: creation

For an absent startup file or fish file: snapshot the absence through the parent descriptor with `fstatat(…, AT_SYMLINK_NOFOLLOW)` returning `ENOENT` (any other result, including a dangling symlink or a permission error, is not absence: Manual setup); write the temporary file with mode `0666 & ~umask`; place it with `renameatx_np(…, RENAME_EXCL)`, which fails atomically if the name became occupied, in which case nothing is overwritten and the operation is refused with the message above. fish's `conf.d` is created with `mkdir` at `0777 & ~umask` when absent; an existing non-directory at that path is Manual setup.

### fish rules

The dedicated file is app-owned only if its entire content matches the template with some bundle path (whitespace exact, trailing newline optional) and the ownership record matches. Rewrite, creation and removal follow the procedures above; removal is `unlinkat` through the directory descriptor after the re-check. Any other content is foreign: left alone, with the intended content offered through Copy Setup Text when its conditions hold.

### Outcomes

After an Add, Use This Copy or startup rewrite, the status line reports one of:

- "Entry written and selected." (the login-shell probe, run again, resolves `unison` to this app's entry). The only success.
- "Entry written; your shell still selects another unison."
- "Entry written; your shell selects no unison."
- "Entry written; command selection could not be checked." (the probe did not complete, timed out, or produced output the app could not parse, with no claim about why).
- "Entry written; the result could not be read back." (the rename returned success and the read-back failed; `pending` kept).
- "The file operation's result could not be established." (the rename returned an error outside the no-change list; `pending` kept; the app does not claim the entry was written).

After a Remove, the status line reports "PATH entry removed." on success, and a second line reports the subsequent resolution separately: "Your shell now selects <path>.", "Your shell now selects no unison.", or "Command selection could not be checked." Removal is successful when the configuration is gone; it does not promise that every route to this app disappears, since a Homebrew link or a 0.7.0 link may still be selected.

## The probe

The existing marker-delimited probe, run as a non-interactive login shell (`zsh -l -c`, `bash -l -c`, `fish -l -c`), reports what `unison` resolves to and whether the bundle's `bin` directory is on PATH and at which position. A separate non-login `fish -c` probe reports `__fish_config_dir`. Limit, stated in the pane and manual: a non-interactive login shell runs the login files, not the interactive ones (zsh: not `.zshrc`), and aliases or functions can select a command without changing PATH. The probe reports what a login shell selects; a Terminal window may differ.

## Preference

One per account: **Keep unison in Terminal pointing at this app** (`commandLine.keepInTerminal`). Off: the app neither offers nor writes. On with no block: the startup offer is shown when `unison` does not resolve to this app (rows 11 and 12). On with a block: the block is maintained at each launch (row 6). **Don't ask again** in the offer turns it off; the Settings checkbox turns it back on. Add Terminal Setup and Use This Copy turn it on; Remove Terminal Setup turns it off. It is hidden in rows 1 to 3.

Initial value for an account that has never run a version with this preference: **on**, so the first launch offers setup in rows 11 and 12 and a correct state stays silent. Migration from 0.7.0: on, unless `commandLineTool.doNotAsk` is true, in which case off; the old key is then removed. No block exists at migration, so the first post-upgrade launch behaves as a first launch.

## State table

Evaluated in order; the first matching row decides. "Current" means the block records this bundle's present path. "Owned" means inside the editable bound with a matching record.

| # | Condition | Badge | Note | Action | Startup behavior (preference on) |
|---|---|---|---|---|---|
| 1 | Probe failed or timed out | Unknown | Your shell's PATH could not be read. | none | none |
| 2 | Unsupported shell; zsh outside the stock bound or bound uncertain; file outside the editable bound; unrepresentable path; foreign block or fish file | Manual setup | one line naming the reason | none; the directory to add shown; the intended file named and Copy Setup Text offered only when the shell syntax is supported and the intended destination is established, otherwise the limitation only | none |
| 3 | Bundle precondition failed | from resolution | This app's command is missing from the bundle. Reinstall the app. | Remove Terminal Setup… if an owned block exists, else none | none |
| 4 | Owned block, recorded path is an existing copy of this app other than the running one | from resolution | Another copy of this app owns the PATH entry. | Use This Copy… (shows block; rewrites on consent; records) | none |
| 5 | Owned block, recorded path cannot be inspected (any error other than `ENOENT`) | from resolution | The previous app location could not be checked. | Use This Copy… | none |
| 6 | Owned block, recorded path absent (`ENOENT`) or present but not a copy of this app | from resolution | none | Remove Terminal Setup… | rewrite with the current path; status "PATH entry updated to this app's location."; outcome reported |
| 7 | Owned block, current; resolution is this app's entry | This app | none | Remove Terminal Setup… | none |
| 8 | Owned block, current; resolution is another unison | Not this app | Your shell still selects another unison. | Remove Terminal Setup… | none |
| 9 | Owned block, current; resolution is nothing | Not installed | Your shell still selects no unison. | Remove Terminal Setup… | none |
| 10 | No block; resolution is this app (Homebrew or 0.7.0 link) | This app | none | Add Terminal Setup… | none |
| 11 | No block; resolution is another unison | Not this app | Another unison comes first on your PATH. | Add Terminal Setup… | show the offer; on Add, write and report the outcome |
| 12 | No block; resolution is nothing | Not installed | none | Add Terminal Setup… | show the offer; on Add, write and report the outcome |

Transitions: Add Terminal Setup… shows the block and file, writes on consent, records, turns the preference on. Use This Copy… does the same for rows 4–5. Remove Terminal Setup… shows the file, removes on consent, deletes the records, turns the preference off. Turning the preference on in rows 10–12 runs Add Terminal Setup…, in rows 4–5 runs Use This Copy…; cancelling leaves it off. Turning it off changes nothing on disk. The startup check writes at most once per launch, only in row 6 and, after the user chooses Add in the offer, in rows 11 and 12; never in headless, server or test-host launches, and only when the bundle precondition holds. A startup write in row 6 does not assert why the recorded path is gone.

## Startup offer

Shown once per launch, after the profile picker, when the preference is on, no block exists, and the state is row 11 or 12:

> **Use this app for unison in Terminal?**
> Adds this app's command to your Terminal by writing one marked block to ~/.zprofile. A shell set up differently may still choose another unison.
> [Add Terminal Setup…] [Not Now] [Don't ask again]

For fish the second sentence reads "… by writing a dedicated file in your fish configuration." The file named is the one selected for the account's login shell. Not Now is the default button.

## Settings > Command Line

Title: **unison in Terminal**. One row: the verdict line, the badge, the path line in muted monospace (or "No unison command"), at most one note; **Refresh** with **Checked N minutes ago** (**Not checked yet** before the first check); the status line from the last write, removal or startup check ("Set up in Terminal." on a later launch when the block is current and selected); the single action, **Add Terminal Setup…** or **Remove Terminal Setup…**, with a footnote naming the mechanism and the file: "Adds this app's command to your Terminal by writing one marked block to ~/.zprofile, the file your login shell reads." / "Removes this app's block from ~/.zprofile. Another link may still select this app." / for fish: "… by writing a dedicated file in your fish configuration." and "Removes this app's file from your fish configuration. Another link may still select this app."; in Manual setup, the directory to add in its own field and, only when the shell syntax is supported and the intended destination is established, the intended file in its own field and **Copy Setup Text**, otherwise the limitation in the note; **Copy This App's Command Path**, which copies `<bundle>/Contents/SharedSupport/bin/unison` regardless of the row, with the footnote "The full path, for servercmd in a profile on another machine." and, when the path has characters outside `A–Z a–z 0–9 . _ / + -`, the note "Contains characters that need care in a profile's servercmd; the remote check can assess it."; the checkbox **Keep unison in Terminal pointing at this app** with its explanation "Offers setup at launch when it is missing, and repairs it if the app moves."; and the limits sentence:

> Applies to new Terminal windows for this account. A shell set up differently can still choose another unison.

Copy Setup Text and Copy This App's Command Path are distinct controls with distinct labels. Use This Copy… keeps its label in rows 4 and 5. Homebrew is not named anywhere in the pane.

## Removed from the app

The 0.7.0 Install, Repair and Remove actions, their `do shell script … with administrator privileges` calls, the `/etc/paths` reconstruction, the "Remote command" row and the offer to install `/usr/local/bin/unison` are deleted in the same release with their specific tests. Release gate "known elevation APIs absent": none of `with administrator privileges`, `AuthorizationExecuteWithPrivileges`, `AuthorizationCreate`, `SMAppService`, `SMJobBless`, `requestAuthorization(to:` appears in the source. It proves those identifiers are absent, not that every elevation path is; code review covers the rest.

A 0.7.0 link at `/usr/local/bin/unison` keeps working and is left alone. Manual: run `readlink /usr/local/bin/unison`; only if it prints this app's launcher path is the link the obsolete one, and `sudo rm /usr/local/bin/unison` removes it. Peers whose `servercmd` names that path depend on it; update those profiles first or keep the link.

## ssh peers

Unchanged: a peer names this app's command by absolute path in `servercmd`. Copy This App's Command Path supplies the string; whether it is usable verbatim depends on its characters, and the guided remote-profile check can assess it and refuses some paths by its own rules. A moved app changes that path; the local entry follows, remote profiles do not.

## Limits, for the manual

Per account and per login shell. Adding or removing the entry changes future login shells only: shells already open, and processes they started, keep the PATH they have. The probe runs login files, not interactive ones; a Terminal window can select differently through `.zshrc`, aliases or functions. Automatic editing applies only to the stock zsh layout, a bash profile without heredoc syntax, and a fish config directory the probe can name; everything else is Manual setup. Scripts from cron and launchd keep their own PATH. ssh sessions use `servercmd`.

## Acceptance criteria

- Bundle: `Contents/SharedSupport/bin/unison` resolves to `cltool`; launcher and smoke scripts exercise it; signed bundle verifies; with the symlink removed or retargeted, Add and startup rewrites refuse while Remove of an owned block still works.
- Serialization: the measured hostile names round-trip in zsh and bash without substitution; colon, newline, invalid UTF-8 refused and Copy Setup Text withheld; fish escaping measured in a disposable fish install before merge.
- Bound: a file containing exactly the app's block passes rule 1; refusal for any other line containing `<<` (the `cat <<ONE <<TWO` fixture, a here-string, a comment), for whole-file parse failure, for prefix parse failure (the block enclosed in a completed multiline quote and in a function body), for each malformed marker state, for an unrecorded or edited block, for a template mismatch, for an immutable or foreign-owned file, and when copyfile fails.
- zsh bound: automatic only when both `.zshenv` files return `ENOENT`, `/etc/zprofile` matches an embedded stock text, and `ZDOTDIR` is absent from the launchd listing and the app environment; Manual setup for a `.zshenv` containing only `source ~/.shell-location`, for a modified or unreadable `/etc/zprofile`, for `ZDOTDIR` present with any value including empty, and for a `launchctl print` failure or unparsable output, which is uncertainty and not absence. The macOS 15 stock text is captured by the release pipeline's macOS 15 job with the OS version and build recorded, compared to the embedded fixture before the feature ships; a mismatch fails the pipeline. The gate is named for what it verifies: the recognized stock file on the tested macOS 15 image.
- Write: re-check refusal when the target changed at the seam; `renameat` through the parent descriptor unaffected by an ancestor rename during the operation; metadata identical before and after; symlinked file edited through to its target with the link preserved; text outside the block byte-identical, with the no-final-newline case leaving one trailing newline.
- Creation: `RENAME_EXCL` refusal when the absent name becomes occupied by a file or a dangling symlink; a permission error on the absence check is Manual setup, not absence; created file mode `0666 & ~umask`.
- Ownership: replace-save keeps ownership; edit inside the block makes it foreign; a refused rewrite (seam change) leaves `confirmed` intact and the block owned; a rename that fails with `EACCES` deletes `pending`; a rename that succeeds followed by an injected read-back failure keeps `pending` and reports "the result could not be read back", and the next launch treats the new block as owned; a rename returning an ambiguous error keeps `pending` and reports "could not be established", tested separately from the read-back case; failure to write `pending` refuses before any file change; removal deletes both slots; the no-change error list is verified against both rename calls at implementation review.
- Outcomes: the six write outcomes and the removal outcome with its separate resolution line, each from fixtures (a `.zlogin` that reorders PATH; an alias in `.zlogin`; an empty PATH; a startup file that exits; an injected read-back failure; an injected ambiguous rename error; removal with a Homebrew link still present). A `.zshrc` fixture that reorders PATH demonstrates the probe's blind spot and is documented as such.
- fish: owned file created, rewritten, removed; foreign content refused; `status is-login` guard verified; no universal variable changed.
- State table: every row; Remove clears Keep and the records; Keep-on transitions in rows 4–5 and 10–12; rows 4, 5, 8, 9 never write at startup; at most one write per launch; none in headless, server, test-host launches; row 3 permits Remove and nothing else; Copy Setup Text absent when the destination is uncertain or the path does not serialize.
- View-model tests per row, including the verdict wording and the abbreviated path with the full path in Copy This App's Command Path; controller tests with injected time for Refresh, aging, offer buttons, Copy Setup Text and Copy This App's Command Path; Debug screenshot smoke.
- Preference migration matrix: no prior key → on; `commandLineTool.doNotAsk` true → off; false → on; the old key removed. The fish footnote and offer variants render.
- Release gate as named.
- Copy: no first person, no dash as punctuation, only the file being written is named in the pane.

## What was set aside, and why

Earlier revisions of this document designed a privileged takeover of `/usr/local/bin/unison` or `/opt/homebrew/bin/unison` with journaled restoration: a compiled root helper, `renameatx_np` swap into protected staging, a conflict state machine, and signature-verified elevation through AppleScript. Two findings could not be closed within that model: no macOS primitive replaces a directory entry conditionally on its identity, so consent to "replace what you were shown" could only be checked after the fact; and the elevated command text comes from a user-owned app, so a replaced app could misuse the prompt, which only a launchd-managed daemon prevents. Apple's authorized file-operation service was tested and blocked on service admission, and would not have provided identity-conditional replacement either. A command inside the bundle plus a PATH entry in the user's own files needs none of that and resolves #122 for interactive use; the ssh case was always served by an absolute `servercmd`.
