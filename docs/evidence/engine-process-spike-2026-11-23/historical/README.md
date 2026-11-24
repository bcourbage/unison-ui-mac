# Historical lifeline prototypes

These are unchanged source copies from the earlier review, retained with the spike
results so the v1 counterexample and v2 limitations remain inspectable from the repo.
They are not part of the application build or its test suite.

- `lifeline-v1/`: original nanny, harness, audit-token probes, and the author's
  `review-result.md` recording the independently observed stubborn-descendant failure.
- `lifeline-v2/`: original second helper, harness and probe. The reviewer's v2 runs
  remain attributed to the reviewer; the author did not rerun that exact version.

These versions are superseded. In particular, v1's EOF rule did not establish group
termination, and v2 predates the SIGPIPE/nonblocking and startup fixes. Archiving the
sources does not qualify them or imply their old harnesses cover the current design.
No historical experiment was rerun as part of this archival change.

The exact copied-file hashes are recorded in `manifest.json` here and in the parent
spike manifest. No compiled binaries or raw personal logs are included.
