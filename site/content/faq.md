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

## What are the system requirements?

macOS 15 (Sequoia) or later, on Apple Silicon. It is free and open source under the
GPLv3.

## Can it sync to another machine over SSH?

Yes. A profile's two roots can each be a local folder or a remote root of the form
`ssh://user@host//path`. The app runs Unison over SSH just as the command-line tool
does, including key-based authentication and host-key prompts.

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

## Which version of Unison does it use?

It currently embeds upstream Unison
[2.54.0](https://github.com/bcpierce00/unison/releases). The wire-protocol
compatibility boundary is Unison 2.52.0, so it interoperates with SSH peers running
2.52.0 or newer.

## Is this an official Unison project?

No. It is an independent, personal project, not affiliated with upstream Unison.
Report issues with this UI to its
[own issue tracker]({{REPO}}/issues), not to the upstream Unison project.

## Where is the full manual?

See the [manual](../manual/), which is the same feature-by-feature guide bundled in
the app's Help menu.
