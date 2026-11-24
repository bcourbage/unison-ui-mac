# Review prompt for the engine-process design

Historical review prompt for the first lifeline proposal. Its questions and evidence summary
describe that review point, not the current qualification status. Retained for context; use
the updated design and separate spike reports for current requirements and results.

Review docs/engine-process-design.md and docs/engine-process-brief.md as a report-only adversarial
review. Leave priorities and release versions open. The maintainer requires lifeline-based
transport supervision as the first topology to qualify and has rejected forwarded numeric-PID
signals and routine acceptance of orphaned transports.

The updated design incorporates the six revision-2 document findings. It adds crash-report
classification and fault-injection isolation, makes transport telemetry asynchronous, removes
unused phase 2 protocol fields, states the profile/log acceptance inputs directly, adds a
conditional interim implementation row, and reconciles the brief's effort estimate. It adopts
the lifeline while leaving its completion guarantee and retirement protocol unqualified.

## Questions where the author partially disagrees with the cleanup addendum

1. **EOF as completion proof.** The author independently ran the supplied nanny prototype with
   a shell transport that started a descendant ignoring SIGTERM, then exited 7. The helper
   exited 7 and its pipe returned EOF while ps showed the descendant running. The normal-exit
   branch sends group SIGTERM and immediately calls die_like. Reproduce or refute this case.
   Distinguish writer closure, signal issuance and observed process termination. Does EOF
   establish the addendum's claimed guarantee under any explicitly stated assumptions?
2. **All helper exit paths.** Challenge ordinary transport exit, engine death, failed exec,
   early watch/setup failure, signal races and external helper SIGKILL. The forced branch
   kills its own group, including itself. Identify what completion evidence can safely
   authorize resource release, and where the outcome must remain unknown.
3. **Retirement escalation.** The addendum proposes SIGTERM, grace, then SIGKILL of the helper.
   Show whether that escalation can kill the only cleanup owner while a transport or
   descendant is live. Specify the ownership/barrier protocol needed to avoid that result.
   Preserve transport exit and signal status even when descendant cleanup needs escalation.
   Review both patch 0004's retire path and its engine-shutdown reaper, including waitpid and
   mutex ordering. Do not assume the helper's direct child is the only remaining group member.
4. **Registration-gap claim.** The lifeline should remove dependence on GUI registration by
   arming its engine watch and checking parent identity before forking the transport. Verify
   that ordering on both spawn paths. Treat elimination of the old gap as conditional on
   complete helper coverage and checked error paths, rather than requiring a GUI ack.
5. **Audit-token fallback.** The supplied experiments support further qualification. Verify
   API availability and kernel identity semantics, token capture after exec, same-user
   permissions, hardened runtime/notarization and macOS 15. State what happens if token
   acquisition or signaling is unavailable. No unchecked-PID fallback is acceptable.

## Evidence and experimental scope

The preserved experimental sources are at
/Users/bcourbage/Documents/Codex/2026-11-06/do-you-recall-the-finding-in/engine-process-evidence/lifeline/.
Read review-result.md, nanny.c, harness.py and the token probes. The original sources also
exist in the reviewer's session scratch directory. Preserve these as experimental evidence.
The author independently ran only the normal-exit/stubborn-descendant regression. The other
prototype measurements remain attributed to their original run.

Use disposable local fixtures and exact test-owned process/group identities. Avoid real
profiles, external account changes and the user's crash-report marker. Prefer SIGKILL for
abrupt-death tests. If actual crash generation is needed, isolate and identify those reports.
No authenticated SSH, signed-build or macOS 15 pass has yet been established by the author.

## Required response

For each question provide the verdict, source/mechanism, any observed test result, remaining
assumptions, and the smallest design correction. Distinguish reproduced behavior from source
inference and platform behavior still requiring qualification. Challenge the author's findings
where evidence contradicts them. Check the brief and design for contradictory requirements,
particularly cleanup promises versus completion evidence and the estimated spike scope.

Do not broaden the architecture automatically. Recommend a different topology only if the
lifeline cannot meet the required supported-transport behavior at a proportionate cost.
