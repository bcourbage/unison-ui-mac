# Checked transport-helper spike

Experimental C helper and owned-process harness for step B. The product app and
vendored OCaml build do not use this directory. The helper is signed/hardened in
these experiments; its parent is a Python test actor, not the real AppKit engine.

The helper keeps the direct transport child unreaped while its group is cleaned.
A two-way pipe handshake checks child signal/group setup and parent PTY foreground
handoff before release to exec. SIGPIPE is ignored for helper reporting and restored
to its inherited disposition in the transport. The helper resets its own SIGCHLD
policy so an inherited ignore/NOCLDWAIT cannot silently remove its owned child.

The status writer and lifecycle writer must be distinct nonblocking pipe FDs made
by the spawner. Writes are bounded below POSIX PIPE_BUF; failure never authorizes
abandoning a group. A failed S prevents fork. Each endpoint fails independently.

| Channel | Probe records |
|---|---|
| Status | `S nonce helperPID`, `U nonce live-or--1`, `D nonce waitStatus` |
| Lifecycle | `TransportStarted nonce childPID 0`, `TransportExited nonce childPID waitStatus`, `CleanupComplete nonce childPID waitStatus` |

Started means checked child setup, not successful exec, authentication or present
liveness. Exited is obtained with waitid/WNOWAIT before cleanup/reaping. Complete
requires observed group termination and reaping. If a start is cancelled or fork
fails before there is a child, Complete has childPID 0 and a synthetic setup status;
that is not evidence that an SSH process exited. These are experimental line
records, not the final engine codec or a production prompt-classification API.

Terminal reads paused during a credential sheet are a separate qualification case.
`trace-unread-pty.py` retains process state and independent kernel/helper exit events,
then compares resumed reads with owned-helper stop while the PTY remains unread.
Use `--sample` to retain sanitized SSH call stacks. Its loopback fixture covers a
client-key passphrase only, not server-password authentication or the AppKit bridge.

Membership queries grow their buffer on saturation, require complete proc info,
and treat zero/error results or a missing unreaped leader as unknown. Two empty
observations are required, with no signaling after reaping. Capacity is bounded;
exhaustion keeps U rather than declaring completion. This still needs long-running
churn, platform and full failure qualification. Deliberately detached tools and
remote work after local exit remain outside the group guarantee.

## Build and run

Use a fresh artifact directory. Never overwrite qualified signed bytes.

```sh
transport_artifact=$(mktemp -d /private/tmp/unison-transport-build.XXXXXX)
xcrun clang -Wall -Wextra -Werror -std=gnu11 -O2 \
  -DLIFELINE_SPIKE_FAULTS -mmacosx-version-min=15.0 \
  lifeline.c -o "$transport_artifact/lifeline"
codesign --force --options runtime --timestamp \
  --identifier net.courbage.unison-ui-mac.engine-transport-spike.lifeline \
  --sign '<Developer ID Application identity>' "$transport_artifact/lifeline"
python3 run.py --helper "$transport_artifact/lifeline" --output '<new normal-results directory>'
python3 run.py --helper "$transport_artifact/lifeline" \
  --login-grace-only --defer-terminal --output '<new ordering-results directory>'
python3 trace-unread-pty.py --helper "$transport_artifact/lifeline" \
  --repeats 2 --output '<new unread-PTY results directory>'
python3 trace-unread-pty.py --helper "$transport_artifact/lifeline" \
  --sample --output '<new sampled unread-PTY results directory>'
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
  env-probe.c -o "$transport_artifact/env-probe"
python3 extra-controls.py --helper "$transport_artifact/lifeline" \
  --env-probe "$transport_artifact/env-probe" --output '<new extra-results directory>'
```

The compiled fault hooks are exclusively for this spike. Source default cleanup
grace is 2 seconds. The harness sets 300 ms for most cases and 1000 ms for the
300 ms pre-exec pause injection; neither is an approved shipping timeout. Setup
and test-driver deadlines are likewise experimental. `--defer-terminal` continues
reading the PTY and delays only consumer delivery; stopping reads is not a valid
way to test message ordering.

The SSH fixture starts an unprivileged server listening only on loopback at a
fresh high port. It uses disposable host/client keys, isolated known_hosts and
AuthorizedKeysFile, a forced printf command, no PAM, no account-password or
keyboard-interactive auth, and no SSH agent. The passphrase belongs to the temporary
fixture key. Nothing edits system sshd configuration, real authorized_keys,
known_hosts, profiles or TCC. StrictModes is relaxed only for this private `/tmp`
server fixture; its directory is mode 0700 and keys are mode 0600.

The login-grace case uses a 1-second server setting and pauses 6 seconds while a
fixture descendant remains alive. Earlier 1.5-second attempts could authenticate;
upstream adds timer jitter, so that was not a reliable expiry observation. Record
actual exit/output rather than treating any delay as proof of timeout.

The entry point cleans up its direct owned cases and fixture server. On an
unrecoverable helper failure, do not add a process-name kill to make the test green.
Keep the failed result and investigate ownership. The historical failed ordering
attempt is retained separately; it is not a passed case.
