# Frequently asked questions

## What is Unison UI for macOS?

It is a native macOS app that gives the
[Unison File Synchronizer](https://github.com/bcpierce00/unison) a modern graphical
interface. Unison does reliable **two-way** file synchronization — keeping two
replicas in sync and detecting conflicts — and this app wraps that engine in a
Swift/AppKit UI with a visual conflict-review step.

## How is it different from the `unison` command-line tool?

Same engine, different front end. The app embeds Unison's compiled core, so you do
not need the `unison` CLI installed for the app to run, and you drive everything —
choosing profiles, reviewing changes, resolving conflicts — through the macOS
interface instead of a terminal.

## What are the system requirements?

macOS 15 (Sequoia) or later, on Apple Silicon. It is free and open source under the
GPLv3.

## Can it sync to another machine over SSH?

Yes. A profile's two roots can each be a local folder or a remote root of the form
`ssh://user@host//path`. The app runs Unison over SSH just as the command-line tool
does, including key-based authentication and host-key prompts.

## What happens when there is a conflict?

Nothing is written until you decide. After scanning, the reconcile window lists
every proposed change with its direction. You can flip the direction of any item,
skip it, or diff two versions before applying anything to either root.

## Is it two-way (bidirectional) synchronization or one-way backup?

Two-way. Changes made on either side are detected and can be propagated to the
other, with conflicts surfaced for review — this is Unison's model, not a one-way
mirror.

## How does it update itself?

Through [Sparkle](https://sparkle-project.org/), over a cryptographically signed
appcast feed. Release builds are Developer ID-signed and notarized by Apple. You can
also check manually from **App menu ▸ Check for Updates**.

## Which version of Unison does it use?

It currently embeds upstream Unison **2.54.0**. The wire-protocol compatibility
boundary is Unison 2.52.0, so it interoperates with SSH peers running 2.52.0 or
newer.

## Is this an official Unison project?

No. It is an independent, personal project and is not affiliated with upstream
Unison. Please report issues with **this UI** to
[its own issue tracker](https://github.com/bcourbage/unison-ui-mac/issues), not to
the upstream Unison project.

## Where is the full manual?

See the [manual](../manual/), which is the same feature-by-feature guide bundled in
the app's Help menu.
