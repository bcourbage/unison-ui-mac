# Lifeline review evidence

November 23, 2026. Source copies preserved from the reviewer's session scratch directory.
These are experimental sources and have not been qualified for production use.

An independent probe ran nanny around a shell that started a descendant with SIGTERM ignored,
then exited with status 7. The descendant executed sleep 20. The helper exited with status 7,
the completion pipe returned EOF, and ps reported the descendant still running with state S.
The test-owned process group was then terminated during cleanup.

The source's normal transport-exit branch calls killpg(SIGTERM), then die_like without waiting
or escalating for remaining group members. EOF establishes that the pipe writers have closed,
not that descendants have ended. The forced cleanup branch also needs a proof distinct from
signal issuance, and engine retirement must not kill the lifeline before group cleanup finishes.

The reviewer's other reported test results have not been independently rerun here. No crash
signals, authenticated SSH session, signed build, or macOS 15 qualification was performed.
