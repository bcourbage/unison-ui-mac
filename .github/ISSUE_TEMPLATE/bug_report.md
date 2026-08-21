---
name: Bug report
about: Something the macOS GUI is doing wrong
title: ''
labels: bug
assignees: ''
---

> [!IMPORTANT]
> **This template is for bug reports against the macOS GUI**:
> reproducible incorrect behavior in this app. Before filing:
>
> - **Usage questions ("how do I…")** are not tracked as issues. See
>   [MANUAL.md](https://github.com/bcourbage/unison-ui-mac/blob/main/MANUAL.md)
>   for GUI usage, and **Help → Unison File Synchronizer Manual** in
>   the app for sync-behavior questions.
> - **Upstream Unison bugs** (OCaml core, sync semantics, RPC
>   protocol) go to
>   [`bcpierce00/unison`](https://github.com/bcpierce00/unison/issues),
>   not here. When in doubt, file here and we'll figure out which
>   side it belongs on.
> - **Scope details** in
>   [CONTRIBUTING.md](https://github.com/bcourbage/unison-ui-mac/blob/main/CONTRIBUTING.md).

<!--
If you reached this page via Help → "Report an Issue" inside the app,
the Environment block below will already be filled in for you.
Otherwise please fill it in by hand from the About panel (Unison-UI-Mac →
About Unison-UI-Mac) and `sw_vers`.
-->

## Environment

- **App version:**
- **Embedded Unison:**
- **macOS:**
- **Architecture:**

## What happened?

<!-- What did you expect? What did the app actually do? Screenshots
welcome if a UI element is the focus. -->

## Steps to reproduce

1.
2.
3.

## Profile / context (if a sync-time bug)

<!-- If the bug involves a specific Unison profile, paste the .prf
contents below WITH CREDENTIALS REDACTED (replace passwords with
"REDACTED"). Local-paths-only profiles are usually safe to share
verbatim. -->

<details>
<summary>.prf contents</summary>

```
# paste here, redact credentials first
```

</details>

## Logs (optional but helpful)

<details>
<summary>Unified log slice</summary>

```
# Capture and paste:
# log show --predicate 'subsystem == "net.courbage.unison-ui-mac"' --last 10m
```

</details>
