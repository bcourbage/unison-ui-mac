# Command-line setup and restoration

**Status:** Proposed design, under review  
**Scope:** Local command installation, replacement, repair, and restoration. Separate from the guided remote-profile check.

## Purpose

A user who prefers Unison UI for macOS should be able to make an existing `unison` command use this app, with clear consent and a way to undo the change.

The app’s role is deliberately limited:

> “Use this app for this command.”

It does not manage a roster of alternative providers. Restoring a displaced command reverses the app’s own action; it is not a general provider-selection feature.

## User experience

Command-line setup is available through a startup offer and **Settings → Command Line**. There is no additional App-menu command.

The pane answers two questions: does this command use this app, and, if it does not, does the user want this app to take its place? It is not a provider roster or a guide to using Unison. Terminal examples, SSH instructions, profile settings, and `servercmd` guidance do not appear in it.

### Startup check

During normal GUI startup, the app checks asynchronously without delaying the window. When the startup preference is enabled, the offer gate includes an established absent command, an eligible broken link, or another supported occupant eligible for replacement. Correct links are silent. Unknown, unreadable, unsupported, or unresolved transaction states do not trigger takeover offers. Headless CLI/server invocations and test hosts never run the offer.

The offer has **Use This App…**, **Not Now** as the default button, and **Don’t ask again**. Use This App opens the applicable confirmation; it does not authorize mutation. Replacement confirmation follows that explicit choice and precedes elevation. The offer concerns only the selected command path, or the ordinary proposed installation path after the check establishes absence; it never silently operates on multiple rows.

### Settings layout and copy

Settings shows one row per distinct managed or checked path. Existing journaled paths remain visible even when absent or outside the checked PATH, as does the proposed installation path when no command is found. Package-manager declarations alone never create rows for nonexistent entries.

Each row is label-free in its primary layout:

- The exact command path is always visible in monospace as the primary datum. It is not hidden in a disclosure or embedded in a sentence.
- The verdict badge uses only **This app**, **Not this app**, **Broken link**, **Not installed**, **Unknown**, or **Needs attention**. Needs attention takes precedence for an unresolved transaction; Unknown denotes insufficient inspection; Broken link denotes an inspected dangling symlink. A badge does not itself establish removal authority.
- At most one plain note line supplements the badge. Generated paths, static explanation, badges, and actions occupy distinct columns or typographic roles, rather than one body-text block. A longer explanation belongs in the applicable confirmation or recovery view.
- **Copy Path** copies that row’s command path. An absent destination identifies it as **Proposed installation path**; copying does not install it.

**Refresh** and **Checked N minutes ago** share one line and read as one control. The relative age updates while the window is open without silently rerunning the check. Before the first check, it reads **Not checked yet**. Refresh is read-only; on completion the timestamp and row results update together. A failed refresh reports Unknown with a short note and the attempted-check age; it does not present an old successful verdict as newly checked.

Each eligible ordinary row offers exactly one action: **Install Command…**, **Repair Command…**, **Replace Command…**, **Remove Command…**, or **Remove and Restore Previous Command…**. A correct link offers removal only when eligible under the journal or compatibility rule. Unknown, unsupported, or correct Homebrew-managed entries can have no mutation action. A Needs attention row instead has **Review Recovery…**, the sole recovery action. These exceptions prevent the one-action layout from forcing an unsafe operation.

The footnote under an offered mutation action describes only what that action does to the one public command entry and says **Requires administrator authorization; macOS may ask for a password.** Any generated path appears in its own monospace field, never interpolated into the footnote sentence. Suggested action-specific text is:

| Offered action | Footnote description, preceding the authorization sentence |
|---|---|
| Install Command… | Creates this command link. |
| Repair Command… | Replaces this broken command link. |
| Replace Command… | Replaces this command entry and preserves the previous entry. |
| Remove Command… | Removes this command link. |
| Remove and Restore Previous Command… | Replaces this command link with the preserved previous entry. |

No footnote mentions a different action or describes an action that is unavailable. Preservation and journal details are explained in the confirmation, not expanded into general instructions under the button. For a correct Homebrew-managed row with no app mutation action, the status footnote is simply **Installed by Homebrew.** This is a management disclosure, not another provider row or removal instruction. If an action is offered, package-manager involvement is disclosed in its confirmation instead of adding an unrelated action footnote.

The checkbox is **Offer to set up the unison command at launch**. Its gate is the absent-name, eligible-broken-link, and other-eligible-occupant rule above, including replacement. Don’t ask again clears it; re-enabling restores unsolicited offers. Existing suppression preferences survive the upgrade. Suppression never disables Refresh, Copy Path, or manual actions.

One plain limits sentence appears at the bottom:

> Shows the command found by this check. Your Terminal window may run another unison.

This deliberately avoids promising what a new Terminal window will run: the existing non-interactive login-shell check does not establish every interactive Terminal configuration. The pane contains no shell startup filenames and none of the terms “probe”, “login shell”, or “reconstruction”. No badge or successful refresh is presented as evidence about SSH peers or other shells.

### Recovery presentation

A blocked row visibly reads **Needs attention** and offers **Review Recovery…**. Opening recovery is read-only. The view lists the current command path, recorded and observed retained-entry paths, and the reason for the block; paths are separate monospace fields. It exposes the available recovery decisions or manual-recovery evidence. Applying a decision invokes the authorized helper; cancelling authorization leaves state unchanged. Review Recovery’s footnote describes reviewing retained entries, not an unavailable Install or Remove action.

## What is being managed

Three distinct facts are kept separate:

1. **Destination:** the exact filesystem entry being managed.
2. **Current target:** what that entry currently points to or contains.
3. **Management history:** whether this app installed or replaced it, and whether a package manager also declares that path.

For the usual installation:

```text
/usr/local/bin/unison
    → /Applications/unison-ui-mac.app/Contents/MacOS/cltool
```

For the Apple Silicon Homebrew cask:

```text
/opt/homebrew/bin/unison
    → /Applications/unison-ui-mac.app/Contents/MacOS/cltool
```

The app owns an action at a specific path. It cannot establish universal ownership of the name `unison` across every shell, account, and SSH connection.

### Selecting the destination

The proposed destination is explicit:

- When the login-shell probe identifies an existing `unison` entry, that path is the candidate for replacement or repair.
- When no entry is found, the ordinary installation destination is `/usr/local/bin/unison`.
- Existing app installation records remain discoverable even when their paths are no longer on the probed PATH.
- Multiple managed paths are represented separately; one confirmation never silently changes both.

The final action always names its destination. An unavailable probe does not establish that no command exists.

## State and action behavior

| State at the selected path | Primary behavior | Preservation |
|---|---|---|
| Nothing exists | **Install** | Records that no predecessor existed |
| Symlink resolves to this installation’s launcher | **Installed**; no replacement needed | Preserves any existing restoration record |
| Broken link known to have been installed by this app | **Repair** | Preserves any earlier predecessor record |
| Symlink points to another app copy or another provider | **Replace** after confirmation | Records the stored link target |
| Other dangling symlink | **Replace** after confirmation | Records its stored target; does not claim the target is usable |
| Regular file | **Replace** after confirmation | Exchanges the file into protected staging on the same filesystem |
| Anything other than a symlink or regular file, including a directory, socket, or device | No replacement | Explains why the entry cannot be managed |
| Entry cannot be inspected reliably | No replacement | Reports unknown state |

A broken pathname resembling this app’s launcher is suggestive, not proof that this app created it. The existing `danglingLauncherPath` classification becomes a display hint, not authority to discard a target or offer Repair. Without a valid journal, an old 0.7.0 dangling link is **Replace**, with confirmation and preservation of its stored target. A journal-backed Repair retains the original predecessor; it never starts a new restoration chain.

Replacing a link that already points correctly to this installation accomplishes nothing and does not remove another installer’s claim to the pathname. There is no Force Replace action for a correct Homebrew link.

### Existing installations without a journal

A compatibility rule preserves Remove Command for existing direct installations, including 0.7.0. A path is eligible when all of the following hold:

- It is a symlink resolving to this installation’s launcher, using resolved filesystem identity rather than spelling, capitalization, or bundle identifier alone.
- There is no installation record or incomplete transaction for the destination. A corrupt or unreadable journal is not an absent journal.
- Package-manager inspection establishes that no installed cask declares this destination. Incomplete or unavailable inspection is unknown and does not satisfy this condition.

The app treats this as an **inferred existing installation with no recorded predecessor** and offers Remove Command. This does not prove who created the link or whether something was displaced in the past. It is the sole exception allowing removal authority to be inferred without an app transaction record. Provider labels and pathname hints never independently authorize an action.

The removal confirmation states that no previous command is recorded and none will be restored. The privileged operation journals the inference and the removal before acting, rechecking the same eligibility conditions. Inspection alone does not create a claim of ownership. A correct link declared by a cask remains Homebrew-managed and has no Remove action without an app takeover record.

### Cask-declaration inspection

Inspection reads installed metadata under each relevant Homebrew prefix’s Caskroom without invoking `brew` or evaluating Ruby caskfiles. It looks for installed `binary` artifacts and resolves their destination using the recorded target and applicable prefix. It records the metadata source and whether inspection was complete.

An established absence of Homebrew in the inspected scope is a negative finding, not unknown. An existing but unreadable Caskroom is unknown. Legacy records without an artifact list, unsupported metadata formats, unresolved target expressions, and incomplete enumeration are also unknown; none proves that a destination is unclaimed. A missing artifact list is especially relevant to the previously observed legacy `unison-app` record.

The implementation specifies the supported metadata formats and prefix discovery rules and tests both. Checking only a conventional prefix does not establish that no custom-prefix installation exists. The compatibility inference is withheld where a relevant prefix or declaration cannot be resolved. Metadata changes between presentation and execution invalidate the eligibility snapshot. The privileged helper reads metadata as data; it never executes Homebrew code with administrator privileges.

## Replacement confirmation

The confirmation identifies:

- The exact path being changed.
- The current provider, when established, or the observed target/type otherwise.
- That the new command will run this installation.
- What is preserved and what restoration can recover.
- Shared-account impact.
- Package-manager involvement, when known.

Example:

> **Replace `/usr/local/bin/unison`?**  
> This command currently launches upstream Unison.app. Unison UI for macOS will take its place. The previous link will be preserved for restoration.  
>  
> This affects other accounts that use this shared command.

For a regular file, the confirmation explains that the previous executable will be preserved in this app’s protected recovery directory and shows its backup path. It does not promise that the executable can run from that relocated path.

An administrator password authorizes the filesystem operation. It does not substitute for explaining the replacement.

## Preservation and recovery

### Symlink occupant

The app records the link’s stored target before replacing it.

Restoration returns the preserved symlink to its original destination, or stages a recreation from a valid stored-target record, then exchanges it with the current app link. The stored target bytes, including relative spelling, remain unchanged. A relative symlink may resolve differently or be dangling while in staging: validation reads the link itself and interprets its intended target relative to the original destination’s parent, never to the staging directory. Neither preservation nor restoration promises the target still exists or contains the same software later.

### Regular-file occupant

The app atomically exchanges the entry with a launcher symlink in protected staging on the same filesystem. The displaced file remains under the staging name as its unique backup, preserving the file rather than copying its contents.

The backup name is unique, for example:

```text
/Library/Application Support/unison-ui-mac/command-installations/entry.<unique-id>
```

An existing backup is never overwritten. Unsupported files or states are refused rather than coerced into this workflow. The backup is outside PATH and is preserved without deliberately changing its ownership or access permissions. Directory traversal permission alone does not make it executable by every account: its own permissions still apply, and relocation may break executable-relative resource or library lookup. The helper never executes a preserved binary to inspect it. Preservation is for restoration, not a promise of a working alternate launcher.

### Existing app link

Repair does not create a new predecessor or replace an older restoration record. Repeated Install or Repair must not lose the command originally displaced.

## Durable installation record

Current status is derived from the filesystem. A persistent record explains what the app previously did and what it can undo.

Each transaction records:

- Destination path and transaction identifier.
- Previous entry kind.
- Previous symlink target or backup filename.
- Identity information needed to recognize the preserved file.
- New launcher target.
- Date and the classification disclosed to the user.
- Transaction progress and completion state.

Defaults retain only the startup-offer preference. Journal and staging share `/Library/Application Support/unison-ui-mac/command-installations/`. The directory is `root:wheel`, mode `0755`; journal and lock files are root-owned, with journal files mode `0644`. Captured files retain their original ownership and permissions and are never mistaken for journal files. Distinct journal, lock, and entry naming conventions prevent namespace collisions.

The coder reports measurements on 7 September 2026: `/`, `/Library`, and `/Library/Application Support` are mode `0755` with no ACLs on both Macs; `/Library/Application Support` is `root:admin`. The app-specific directory did not yet exist. These are reported evidence, not measurements repeated for this revision. Root ownership with a non-writable admin group is acceptable for an ancestor; ancestors need not be `root:wheel`. On first authorized use the helper creates its own directory hierarchy exclusively with the specified ownership and mode, and validates an existing hierarchy rather than overwriting it.

Before every operation the helper validates the directory chain, effective permissions including ACLs, and opened directory identities. No ancestor may grant write access to anyone but root through effective mode or ACL permissions; filesystem flags are also checked for restrictions affecting creation and mutation. An immutable flag is not used to excuse unsafe ownership or write grants. In particular, checking only the world-write bit is insufficient because group permissions or ACLs may grant that access. Unexpected ownership, symlinks, or writable ancestors cause refusal. The helper neither silently repairs unrelated system-directory permissions nor follows a GUI-supplied path as journal authority.

Public destination and protected staging must support the required rename operation on the same filesystem. Cross-filesystem destinations are refused, including `EXDEV` failures. There is no same-directory, copy, or capture-then-install fallback. The refusal explains that the command is on a filesystem this app’s protected recovery storage cannot manage.

The same authorized privileged operation writes the journal and mutates the destination. GUI-provided classifications are disclosure history, not trusted instructions for restoration. Destination, backup, and transaction paths are validated against the recorded operation; a record never authorizes an unrelated privileged move or deletion.

Journal updates are written durably before the next filesystem mutation. A single authorization covers preservation, installation, and their journal transitions, rather than obtaining a separate password for the backup. The journal is a recovery protocol across several filesystem operations, not a claim that the entire sequence is one atomic filesystem transaction.

The journal survives normal app updates and replacement of the bundle. Lost or inconsistent history produces an explicit recovery limitation, not a guessed restore operation.

### Entry identity and execution-time checks

The confirmation snapshot defines what the user authorized:

- For a symlink, the stored target bytes are compared exactly, including relative spelling. The entry type and filesystem identity are also checked. Comparison does not normalize or follow the stored target, and does not lose trailing bytes through shell command substitution.
- For a regular file, the snapshot includes device, inode, size, modification and change timestamps at available precision, and a content digest. Metadata alone is not treated as evidence that contents are unchanged. Inspection does not follow a replacement symlink.
- For an absent destination, absence means neither an entry nor a dangling symlink exists there.
- The destination’s parent and any existing backup are checked as well; changing an ancestor must not redirect an authorized operation to another directory.

A mismatch before mutation stops the operation with “The command changed since it was shown. Check again.” The app does not silently refresh the snapshot and proceed under the old consent.

### Privileged transaction helper

A small compiled C helper, distinct from `cltool`, performs installation, repair, replacement, removal, and restoration and is the only journal writer. Each invocation handles one authorized operation, one destination, and one confirmation snapshot. Inputs are structured data, not shell fragments. The helper independently validates the destination, snapshot, launcher, journal chain, and recovery state; privilege does not make GUI inputs trustworthy.

The helper acquires an advisory lock on a root-owned lock file in the journal directory for the destination. The lock identity accounts for equivalent paths to the same parent directory and entry. It serializes this app’s operations across accounts, including recovery. Homebrew and unrelated processes do not participate in that lock.

The helper is bundled, signed, and tested as a separate executable with macOS 15 compatibility. Existing `cltool` packaging is precedent, not evidence that this new helper is correctly authorized or deployed. The implementation review includes the elevation boundary below, input boundaries, signing order, hardened-runtime configuration, and release-artifact inclusion. It is not a general-purpose privileged filesystem utility. A test harness may supply an explicit scratch destination through the same validated transaction interface; no bypass of authorization or path validation ships for testing.

### Elevation and retirement of the old actions

Elevation uses AppleScript **`do shell script … with administrator privileges`** to launch the compiled helper by its absolute path in the current validated bundle. No SMAppService daemon or XPC service is introduced in this design.

This AppleScript API accepts shell text, not a native argv array. The adapter therefore emits only a fixed helper invocation: the absolute helper path and each independently encoded argument are shell-quoted with AppleScript’s `quoted form` or a proven equivalent. Structured request fields are serialized with a versioned bounded format; pathname and symlink bytes that cannot be represented directly are encoded losslessly. No input is concatenated as shell syntax. AppleScript source is fixed and receives data as values rather than interpolated source. No `eval`, variable command selection, redirection, pipeline, or filesystem mutation command is generated.

Apple documents both the shell-text interface and quoting facility: [AppleScript command reference](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html) and [Calling Command-Line Tools](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/CallCommandLineUtilities.html). Authorization can be reused by macOS, so UI copy does not promise a password prompt on every invocation.

The helper remains the only authority for journal writes and filesystem mutations. It rejects malformed or out-of-scope requests, independently revalidates valid requests, and never treats a GUI-written snapshot file as privileged authority. Authorization to run the helper is not proof that arbitrary supplied paths were approved. The review covers the helper binary and bundle-path trust at elevation, request boundaries, shell/AppleScript injection, and inherited execution environment. “Hostile argv can only cause refusal” is a testable input-validation objective, not a guarantee established merely by using structured data.

The same release deletes the 0.7.0 shell-based Install, Repair, and Remove implementations and the tests specific to those obsolete algorithms. Their relevant behavioral regression coverage is migrated to the helper. Both startup and Settings invoke only the new adapter and compiled helper. There is no fallback to shell filesystem operations on helper failure. AppleScript’s shell-based launch transport remains; the old shell mutation path does not.

### Other writers and staging authority

The coder reports that `/opt/homebrew/bin` is login-account-owned with mode 775 on both Macs, while `/usr/local/bin` is root-owned with mode 755. These are recorded machine observations, not assumed properties of every installation. At the Homebrew destination, a competing writer can be an ordinary process of the owning account or a member of the writable group, not just an elevated administrator. Effective access also depends on ACLs, flags, and ancestor permissions; mode bits alone are not a complete permission audit.

Staging names in a readable directory can be enumerated. The journal is also intentionally readable across accounts. Unpredictable names prevent accidental collision; they are not a security boundary and cannot justify a “negligible” replacement-to-unlink race. Root ownership of a file does not by itself prevent a writer of its containing directory from replacing that directory entry.

The helper never unlinks the public destination. Automatic deletion from a staging directory writable by unrelated processes is also excluded: an inode check followed by pathname unlink has the same race. Moving an entry to yet another random name in that directory does not close it. [Apple’s unlink API](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/unlink.2) removes the entry named by a path, not an expected inode.

Protected staging prevents unprivileged directory writers at the public destination from replacing captured staging entries. This protection is supplied by the validated directory chain and effective permissions, not by unpredictable names. It does not make preserved file contents immutable: original ownership and permissions may allow writes, and another hard link or an already-open writable descriptor may still reach the inode. The helper validates content again before restoration and refuses a changed predecessor. An independently privileged writer remains outside this protection.

This release retains retired launcher links and temporary recovery entries under journaled names rather than automatically deleting them. Remove Command removes the public command entry, not all transaction artifacts. Protected staging makes a future cleanup procedure feasible under the stated writer model, but this design does not authorize it.

A journal records preservation history; recovery still reports missing or changed evidence honestly. It does not guarantee permanent findability against a privileged writer or immutable contents against other existing access to the file.

### Atomic namespace operations

The selected primitive is `renameatx_np`, using separate validated directory descriptors for the public parent and protected staging, with relative entry names:

- For an absent destination, a staged launcher symlink is installed using **`RENAME_EXCL`**. An existing destination is a conflict, including a dangling symlink.
- For replacement of an existing entry, **`RENAME_SWAP`** exchanges the destination with the staged launcher symlink. The displaced entry lands under the staging name. A missing destination causes a refusal rather than creating a new installation under the replacement consent.
- For restoration while the expected app link occupies the destination, **`RENAME_SWAP`** exchanges that link with the selected preserved file or staged symlink. The retired app link lands in protected staging and is retained.
- These are separate flag choices; they are never combined.

Apple documents atomic exchange and exclusive-destination behavior, with unsupported flags producing `ENOTSUP`. The API does not take an expected inode or snapshot. See [Apple’s rename manual source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2).

Unsupported operation or filesystem capability is refused without a move-then-rename fallback. The design relies on demonstrated capability at the destination, not a blanket APFS or HFS+ label. Successful replacement or swap-based restoration introduces no missing-name interval of its own, so the previous routine interruption disclosure is removed. This establishes namespace continuity for that operation, not uninterrupted service under competing writes, crashes, or later execution failure.

The staging symlink is created exclusively at a fresh name; `RENAME_SWAP` does not create a fresh backup name on its own. A regular-file reservation followed by unlink-and-symlink is not exclusive symlink creation. The journal records the staged entry’s identity before exchange. Exclusive creation prevents an initial name collision; it does not prevent another directory writer from replacing the entry later. Both sides remain subject to identity checks and conflict handling.

The coder reports APFS scratch measurements for symlink and regular-file swaps, exclusive-install refusal at a dangling link, exclusive install at an absent path, and swap refusal when the destination disappears. Additional reported measurements cover swaps and exclusive capture across directories on one filesystem, restoration by swap, and `EXDEV` across a temporary disk image. The three relevant directories on both Macs reportedly reside on the Data volume; the helper checks its actual operands rather than assuming that layout. These are reported measurements, not independently repeated in this design revision. They establish individual syscall behavior in that environment, not concurrent rollback correctness, HFS+ behavior, crash durability, or release compatibility on macOS 15.

### Interrupted operations and concurrency

Replacement and restoration are journaled, recoverable operations. The journal records intent, staging, exchange, displaced-entry validation, and verified completion. Recovery inspects actual entries as well as the recorded stage: interruption can happen after a syscall succeeds but before its completion record is written. Atomic namespace exchange does not make the filesystem change and journal update one atomic durable transaction. Incomplete transactions block ordinary actions until reconciled.

After an exchange, the helper validates both the displaced entry and the installed link. A post-operation comparison accounts for metadata changes legitimately caused by the operation; it does not blindly compare pre-rename timestamps or ignore unexpected content changes. Until validation succeeds, the displaced entry remains recovery evidence and is neither deleted nor treated as an approved predecessor. The helper must also handle an unexpected entry type displaced by a race, rather than treating it as a regular-file backup.

**A second swap is not an unconditional rollback.** Suppose the approved entry is A, another process replaces it with B before the first swap, and the helper swaps B into the staging name. If another process then installs C at the destination, swapping again puts B at the destination and displaces C. That does not restore the state immediately preceding rollback. Rechecking immediately before the second swap creates another check-to-mutation interval; the advisory lock does not close it for other writers.

On an observed conflict, the helper stops automatic mutation, retains available recovery entries and the journal, and reports that the command changed during installation and recovery needs attention. It does not report “nothing changed” after a successful exchange. It never deletes an unfamiliar entry or blindly swaps back. A fresh recovery action must disclose current state and preserve any newly displaced entry under the same transaction rules.

### Transaction states

Each mutation has a durable pre-operation record naming both entries and the expected identities. A syscall result is recorded separately from validation. A crash between those writes is resolved by observation, not by assuming that the last recorded step did or did not execute.

| Operation | States and behavior |
|---|---|
| Install into an absent destination | `intent` → `stage_intent` → `staged` → `install_intent` → exclusive rename → `installed_unvalidated` → validate the destination → `complete` |
| Replace or Repair | `intent` → `stage_intent` → `staged` → `exchange_intent` → swap → `exchanged_unvalidated` → validate both entries → `complete` |
| Remove without restoration | `intent` → `capture_intent` → exclusive rename of the public entry to a fresh journaled name → `captured_unvalidated` → validate captured link and observe destination → `complete`; captured link is retained |
| Remove and restore | `intent` → validate preserved file or prepare a symlink in protected staging → `restore_intent` → swap predecessor with the expected public app link → `restored_unvalidated` → validate restored predecessor and captured app link → `complete`; retired app link is retained |

Stages are operation-specific: Install has no displaced predecessor, and Remove has no newly installed public link. If exclusive rename refuses a newly occupied destination, that entry remains untouched and the transaction records the refusal and retained artifacts. A missing source, missing evidence, validation mismatch, unexpected type, or ambiguous syscall outcome cannot become success.

Restoration uses one exchange and has no capture-then-install interval. The corresponding interruption disclosure from v4 is removed. If the public entry disappears before the swap, the operation refuses; it does not silently become Install. If it changes to a different entry, post-swap validation enters conflict and preserves that entry in protected staging without automatic rollback. Missing-destination recovery requires a separately previewed exclusive-install transaction, not implicit permission under Remove and Restore.

Post-mutation validation checks the destination as well as the displaced or captured entry. Symlink comparison includes stored target bytes and filesystem identity; file comparison includes content and identity, allowing only documented metadata changes from the operation. A matching predecessor alone does not establish that the public entry is still this app’s link. Completion records what was verified at that time, not a promise that no later writer can change it.

The rule is **after a mismatch, no further automatic filesystem mutation**. “After any mutation, only observe and record” is too broad for operations that include staging and journaled namespace changes. Successful validation can advance a previously authorized operation to its next journaled step; any conflict stops that progression. Automatic cleanup is excluded even on the success path.

### Conflict and recovery actions

A validation conflict retains all available entries and an immutable record of the original approved snapshot. The display reports current observations separately from where entries were previously placed. In the A/B/C example, B may remain at the staging name while C is now at the destination; the app must not claim its own link remains there.

- **Keep This Command** is available only after a fresh inspection establishes that the destination is this app’s intended link and the displaced entry can be inspected. The confirmation shows the actual displaced entry and asks whether to retain it as the predecessor. Acceptance appends a new decision to history; it does not rewrite the original approval or discard earlier predecessor records. If state changed again, the decision is refused. Unknown or unsupported displaced entries require manual recovery: the view provides the journaled path, observed type and availability, Copy Path, and an exportable recovery record. It states that the app will not move, execute, or delete that unsupported entry. After external recovery, Refresh refreshes observations and Review Recovery can request helper reconciliation; no generic clear-history action bypasses an unresolved state.
- **Restore Displaced Command…** is a new, previewed transaction, not unconditional Undo. It names the current destination and the particular preserved entry to restore, and uses the same protected-stage, swap, validation, and conflict rules. A new writer can cause this transaction to conflict as well. The original and all subsequent recovery records and available displaced entries remain linked and retained.
- If the destination is no longer this app’s expected link, neither action silently adopts or removes it. The app presents the changed state and retains evidence for a fresh, explicit recovery decision.

On GUI launch, recovery inspection performs no filesystem mutation. It can classify a transaction as verified complete, not applied, conflict, or unresolved; it must not force an interrupted, ambiguous operation into complete. Any durable journal reconciliation is performed only by the authorized helper. A missing staged entry, partially created stage without recorded identity, inaccessible directory, or missing backup is unresolved evidence, not permission to guess. Ordinary actions remain blocked for the affected destination until that state is resolved.

**Remaining implementation review gate:** this state machine supplies the normal and conflict paths but still requires demonstration in the compiled helper. Tests must cover every pre-operation record/syscall/post-operation record boundary, changes to both names, and retention without destructive cleanup. Tests must establish protected-namespace enforcement against ordinary destination-directory writers, separately from content mutation through retained file access. The design does not claim permanent findability under arbitrary privileged mutations. No public-name unlink, automatic swap-back, or random-name-based unlink safety claim is permitted.

## Removal and restoration

Removal is offered when the app has a valid record of installing or taking over the path and the current entry is still the expected app link, or when the narrowly defined existing-installation compatibility rule applies.

| Recovery state | Offered action |
|---|---|
| No predecessor was displaced, or the compatibility rule establishes an inferred existing installation with no recorded predecessor | **Remove Command**, with the distinction disclosed |
| Previous symlink is recorded | **Remove and Restore Previous Command…** |
| Preserved regular file is present and matches the record | **Remove and Restore Previous Command…** |
| Restoration data is missing or changed, but valid installation evidence still establishes the expected app link | Explain that restoration is unavailable; offer **Remove Command** separately |
| Installation authority itself is unreadable, corrupt, or inconsistent | No ordinary removal or restoration; explain the recovery limitation |
| Current entry no longer matches the app’s expected link | Refuse removal/restoration until the changed state is understood |

An action promising restoration never silently degrades to removal alone.

After restoration, the app verifies the resulting entry. Restoring a pathname does not establish that the previous program still functions; any missing target is reported.

## Multiple users

The ordinary `/usr/local/bin` installation is shared. The prompt preference is personal to each account; the command replacement is not.

User A can open this GUI without changing User B’s command. If A requests replacement of a shared command, the confirmation explains the broader effect.

Independent CLI selection for A and B requires per-user shell configuration. This design does not introduce automatic per-user PATH management or silently edit shell startup files.

The installation journal and authorization checks cannot depend solely on the account that originally performed a shared installation.

## PATH and success reporting

Installing a link and making a particular shell select it are different outcomes.

When the link is installed but its directory is absent from the probed PATH, the result says:

> “The command link was installed. Your Terminal window may run another unison.”

When another directory takes precedence, Settings conveys the result through its path rows, badges, and at most one note per row. It does not claim bare `unison` selects this app merely because a link was installed.

The manual and technical validation records identify the mechanism as a non-interactive login-shell probe and explain its limits. That terminology stays out of the pane. The pane uses only the plain limits sentence specified above; detailed PATH and remote-command guidance belongs in documentation or the separate guided remote-profile check.

## Homebrew interaction

Homebrew involvement is an additional fact, not a mutually exclusive installation state. A Homebrew-managed path can be correct, broken, or point elsewhere.

- If the link already points to this installation, the app reports it as installed.
- If Homebrew also declares that path, Settings can disclose that fact.
- An explicit app-directed replacement records the app’s action but does not transfer or erase Homebrew’s package ownership.
- Without an app installation or takeover record, removal of a cask-created link remains Homebrew’s responsibility.
- With a valid takeover record, the app can offer to undo its own replacement, subject to current-state checks.

The confirmation contains a short disclosure when appropriate:

> “Homebrew also manages this command path and may change it during a later package operation.”

Detailed consequences belong in the manual. Documentation distinguishes measured scenarios from source-based expectations, including:

- Formula linking versus cask linking.
- Cask upgrades that skip a formula-owned command.
- Legacy-cask uninstall behavior that can remove a replacement link.
- Recovery when another installer deletes or changes the app’s command.

A later formula upgrade after app-directed takeover remains a distinct scenario to verify before promising that the replacement link survives.

### Validation of package-manager behavior

Existing observations are retained with their limits. Formula linking after a cask install, a cask upgrade while a formula is linked, and a legacy-cask collision are different checks. None establishes the result of a future formula upgrade after this app replaces its link.

Before the implementation’s Homebrew disclosure becomes more specific than “may change this command,” validation distinguishes:

| Check | What it establishes |
|---|---|
| Actual `brew link unison` against a foreign link | Whether that link attempt preserves or changes the occupant, with exit status and before/after identity |
| No-op `brew upgrade unison` | Only the no-op outcome; it does not test upgrade-time relinking |
| `brew reinstall unison` in a disposable prefix against a foreign link | Reinstall behavior and a proxy for upgrade-time linking; record versions, before/after entries, exit status, and the evidence for the shared linking path |
| An actual formula version upgrade against a foreign link, when available | Direct upgrade evidence for the recorded versions; not a prerequisite that depends on a new formula release becoming available |
| Legacy `unison-app` uninstall | Whether that uninstall removes the replacement path and upstream app; a source inspection or dry run is not execution evidence |

The reinstall proxy does not establish all upgrade behavior. Until an actual upgrade is observed, the manual retains that distinction and avoids a guarantee that a future upgrade preserves the app’s link.

These are validation cases, not authorization to alter either Mac. Disposable environments are preferred where they can exercise the relevant behavior, and their limits are recorded. Live changes on Heracles require their own authorization and verified recovery. Demeter’s updates, legacy cleanup, and removal of existing test artifacts remain deferred until after the planned release. The upstream fallback remains available until the separately authorized cleanup.

## Relationship to the guided remote-profile check

This feature manages a local filesystem entry. It does not choose or edit another machine’s `servercmd`.

The guided remote-profile check remains separate: it helps users inspect the intended remote command, verify observations over SSH, and preview profile edits.

Taking over a local path does not prove that any remote peer selects that path.

## Implementation sequence

1. **Helper PR, no UI changes.** The compiled helper, transaction protocol, elevation adapter, packaging/signing integration, and fault-injection suite are reviewed first. It is not wired to product actions in this PR. The review demonstrates each journal/syscall/journal boundary and the privilege boundary independently of pane work.
2. **Settings and startup PR, on top of the reviewed helper.** This implements the layout, fixed badge vocabulary, action-specific footnotes, Refresh age, checkbox gate, and recovery presentation. It switches both entry points together and deletes the old shell mutation implementation and its obsolete tests. There is no runtime selector or fallback between implementations.

The first PR may temporarily coexist with the old product code during development; no release is cut between these two PRs. The release includes the completed migration to one privileged mutation path. Live Demeter acceptance remains after the release under the existing authorization and recovery plan.

## Acceptance criteria

The implementation is reviewed against these behaviors:

- Startup offers are asynchronous, limited to normal GUI launches, and respect suppression; Not Now is the default, and replacement confirmation follows an explicit Use This App choice.
- Refresh is read-only and paired with an aging relative timestamp; suppression never disables manual actions. Copy Path copies the selected row’s exact command path. Multiple paths have separate statuses and actions.
- UI tests cover every fixed badge, eligible one-action row, no-action exception, action-specific footnote, Needs attention recovery action, and absence of declaration-only rows for missing entries.
- Paths remain visible in monospace fields and outside explanatory sentences. The pane excludes usage instructions and internal shell terminology.
- Elevation tests include paths and request fields containing spaces, quotes, newlines, backticks, and shell substitution text, plus malformed or oversized structured requests. They verify literal argument delivery and refusal without mutation.
- Release verification establishes that startup and Settings use only the helper, the old shell mutation code is absent, and the helper is signed and included.
- Correct links cause no unnecessary replacement or password prompt.
- Every replacement confirmation identifies one destination and its displaced entry.
- Symlink targets and regular-file backups remain recoverable.
- Initial staging-name collisions are refused. Tests also replace the staging entry after creation and establish that exclusive creation is not mistaken for lasting ownership of the name.
- Repair preserves the original restoration history.
- Changes detected before mutation abort the action. Deterministic concurrent-change tests exercise the interval between inspection and mutation and demonstrate the conflict and recovery behavior specified above.
- Interrupted replacement and restoration enter recorded recovery states. Tests inject C after the initial swap and verify the displayed destination is C, no unconditional swap-back occurs, and retained evidence is not deleted.
- Removal retains the captured link. Restoration uses a single swap, validates both sides, refuses a vanished destination, and records a raced replacement as conflict without swap-back. Cross-filesystem and unsupported-operation cases refuse without fallback.
- Tests show that an ordinary destination-directory writer can enumerate but cannot replace entries in protected staging. Fault injection separately exercises privileged tampering; names are never assumed secret. No automatic entry deletion occurs.
- Relative symlinks survive staging and restoration with identical stored bytes. Neither staged-link resolution nor successful execution from a relocated backup is an identity gate.
- Tests modify a retained file through allowed file access, an alternate hard link, or an existing writable descriptor; restoration detects the changed content.
- Needs attention and Review Recovery expose blocked states, retained paths, authorization cancellation, unsupported-entry guidance, and reconciliation after external recovery.
- Recovery distinguishes not-applied, complete, conflict, and unresolved outcomes and does not manufacture completion from missing evidence.
- Keep and Restore decisions preserve the original snapshot and every earlier predecessor record.
- Missing backups never turn a restoration promise into silent removal.
- Homebrew-created links and app-recorded takeovers are distinguished without relying solely on a cask receipt.
- Shared-account effects and PATH limitations are accurately disclosed.
- Direct 0.7.0 links without records retain Remove only through the compatibility rule; cask declarations and unknown package-manager state prevent that inference.
- Unjournaled stale links use Replace and retain their stored target, even when their pathname resembles this app.
- Journal ownership, permissions, ancestor validation, and cross-account access are tested; unprivileged input cannot forge restoration authority.
- Regular-file identity tests include changed content, and crash tests cover every journal/filesystem transition, including the operation succeeding before its completion record is written.
- Directory, socket, device, and unreadable-entry cases fail closed.
- Compatibility remains macOS 15 and later on the app’s supported architecture, including the separately signed helper. Unsupported swap/exclusive capability refuses without fallback.
- Tests distinguish atomic exchange, snapshot validation, and journal durability; none is reported as proving the other two.
- Cask inspection fixtures include absent Homebrew, unreadable metadata, legacy missing artifacts, supported binary targets, and unknown prefix or target resolution.
- A valid removal/restoration record does not bypass the helper’s concurrent-change handling.

### Live restoration acceptance

A separately authorized Demeter test exercises symlink replacement and restoration using `/opt/homebrew/bin/unison.upstream-link`, the preserved upstream fallback link, after the release under the existing schedule. Preconditions establish the exact test path, its stored target, its working fallback, and an uncontested recovery path. The test replaces that one link through the app’s transaction flow, invokes `-version` through that exact path, restores through Remove and Restore, and compares the restored target bytes with the original capture.

The observed version output is recorded alongside the resolved app path; a version string alone is not proof of bundle identity. This check demonstrates symlink restoration, not regular-file restoration or server-protocol readiness. An isolated regular-file case separately verifies that restoration returns the preserved file with its identity, contents, ownership, and permissions intact.

The harness invokes the helper directly for this explicitly authorized destination; no PATH probe or Settings proposal is expected to discover `unison.upstream-link`. It exercises the production transaction validation, journaling, and recovery rules. The live test does not authorize legacy-cask uninstall or changes to production profiles, and does not add arbitrary-path selection to Settings.
