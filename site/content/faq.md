# Frequently asked questions

## What is Unison UI for macOS?

It is a native macOS app that gives the
[Unison File Synchronizer](https://github.com/bcpierce00/unison) a modern graphical
interface. Unison does reliable **two-way** file synchronization, keeping two
replicas in sync and detecting conflicts. This app wraps that engine in a
Swift and AppKit interface with a visual conflict-review step.

## How is it different from the `unison` command-line tool?

It is the same engine with a different front end. The app embeds Unison's compiled
core, so the `unison` CLI does not need to be installed for the app to run, and
everything happens through the macOS interface instead of a terminal: choosing
profiles, reviewing changes, and resolving conflicts.

## How does it compare to the macOS app included with Unison?

Upstream Unison ships its own front ends, including a native macOS Cocoa app (built
from the `uimac` sources in the Unison repository) alongside the text and GTK
interfaces. Unison UI for macOS is a separate, independently maintained app. It runs
the same Unison engine, but its interface is an independent Swift and AppKit
implementation, not derived from the upstream Cocoa app's code. It targets macOS 15
and later on Apple Silicon and adds built-in Sparkle updates from a signed feed. For
the upstream app and its history, see the
[Unison project](https://github.com/bcpierce00/unison).

## Why does this exist when Unison already ships a macOS app?

Part of the motivation is practical: the upstream maintainers have noted that they
are not able to test the macOS build themselves, so a separately maintained native
app can respond to Mac-specific issues more directly. A concrete example is staying
responsive under trouble: in the bundled Cocoa app, cancelling a sync or a scan can
leave it stuck and needing a force quit. This app takes a different approach.
Stopping a running sync aborts it cleanly at the next checkpoint, and during a scan
you can return to the profile list instead of watching a frozen window. Recovering
from a remote connection that has gone silent can still mean quitting and relaunching,
but the interface stays usable rather than locking up. Beyond that, the goal was a
modern, native experience on current macOS: a Swift and AppKit interface targeting
macOS 15 and Apple Silicon, with a focused conflict-review workflow, native
notifications, and built-in updates from a signed feed. Starting from a fresh Swift
and AppKit codebase, rather than building on the bundled Cocoa app, made those goals
easier to pursue and maintain. Both run the same Unison engine, so synchronization
behaves the way Unison is known for.

## What are the system requirements?

macOS 15 (Sequoia) or later, on Apple Silicon. It is free and open source under the
GPLv3.

## Can it sync to another machine over SSH?

Yes. A profile's two roots can each be a local folder or a remote root of the form
`ssh://user@host//path`. The app runs Unison over SSH just as the command-line tool
does, including key-based authentication and host-key prompts.

## Does this app have a GUI to help configure sync profiles?

Yes. A graphical profile editor sets a profile's two roots, the paths to include,
ignore patterns, file-handling options, and more, so there is no configuration file
to hand-edit. The profiles it reads and writes are ordinary Unison profiles
(standard `.prf` files in your Unison directory), so they work with the `unison`
command-line tool in exactly the same way. Nothing about a profile is specific to
this app's interface.

## What happens when there is a conflict?

Nothing is written until you decide. After scanning, the reconcile window lists
every proposed change with its direction. Flip the direction of any item, skip it, or
diff two versions before anything is applied to either root.

## Is it two-way (bidirectional) synchronization or one-way backup?

Two-way. Changes made on either side are detected and can be propagated to the other,
with conflicts surfaced for review. This is Unison's model, not a one-way mirror.

## How does it update itself?

Through [Sparkle](https://sparkle-project.org/), over a cryptographically signed
appcast feed. Check manually any time from **App menu ▸ Check for Updates**.

## What data does the app send?

The app has no per-user tracking. When it checks for updates, the request goes to
the project's update endpoint. A record is created only when a check includes the
optional anonymous system profile. Sparkle attaches that profile at most once every
seven days, and only if the checkbox is on. Checks without the profile, including
every check after you opt out and the routine checks in between, are not recorded.

Each record holds only the check time, a coarse country that Cloudflare derives from
the connection, and the profile fields: macOS version, Mac model, CPU, memory, app
version, and preferred language. It carries no name, account, IP address, cookie, or
stable per-user identifier, and no file names, contents, or record of what you sync.
The records are per-check rows, kept for at most six months and used only to produce
aggregate statistics. Cloudflare processes the request as the hosting provider.

An "Include an anonymous system profile with update checks" checkbox controls the
profile, on the first-launch update prompt and in Settings. The checkbox is selected
by default on that prompt, so accepting the defaults includes the profile; clear it
there or in Settings to turn it off. With it off, update checks still reach the
endpoint, the same as any app that updates itself, but nothing is recorded.

Your synced files never route through this project: they move directly between the
two roots over SSH.

## Which version of Unison does it use?

It currently embeds upstream Unison
[{{UNISON_VERSION}}]({{UNISON_TAG_URL}}). The wire-protocol compatibility boundary is
Unison 2.52.0, so it interoperates with SSH peers running 2.52.0 or newer.

## Is this an official Unison project?

No. It is an independent, personal project, not affiliated with upstream Unison.
Report issues with this UI to its
[own issue tracker]({{REPO}}/issues), not to the upstream Unison project.

## How do I get help or report a bug?

Support happens on GitHub. Open a bug report or feature request on the
[issue tracker]({{REPO}}/issues), searching first in case it is already filed. This
is an independently maintained personal project, so help is best-effort. Clear
reproduction steps and the app version (from **App menu ▸ About Unison UI for
macOS**) make a report much easier to act on.

## Where is the full manual?

See the [manual](../manual/), which is the same feature-by-feature guide bundled in
the app's Help menu.
