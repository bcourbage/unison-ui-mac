---
name: Bug report
about: Something the macOS GUI is doing wrong
title: ''
labels: bug
assignees: ''
---

<!--
If you reached this page via Help → "Report an Issue" inside the app,
the Environment block below will already be filled in for you.
Otherwise please fill it in by hand from the About panel (Unison-UI-Mac →
About Unison-UI-Mac) and `sw_vers`.

Before filing: please skim https://github.com/bcourbage/unison-ui-mac/blob/main/CONTRIBUTING.md
— it explains what belongs here (macOS GUI bugs) vs. what belongs
upstream at https://github.com/bcpierce00/unison (OCaml core / sync
semantics / protocol changes). Save us both a triage step.
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
