import os, subprocess, sys, time
for name in ("late", "late-fixed"):
    for _ in range(3):
        sr, sw = os.pipe()
        env = dict(os.environ, LIFELINE_PARENT=str(os.getpid()), LIFELINE_STATUS_FD=str(sw), SPIKE_CHILD_PAUSE="1", SPIKE_STOP_AFTER_SYNC="1")
        t = time.monotonic()
        p = subprocess.Popen([os.path.join(os.path.dirname(os.path.abspath(__file__)), name), "/bin/sleep", "5"], env=env, pass_fds=(sw,))
        os.close(sw); rc = p.wait(timeout=15); dt = time.monotonic() - t
        recs = os.read(sr, 4096).decode().split("\n"); os.close(sr)
        d = [r for r in recs if r.startswith("D")]
        st = int(d[0].split()[2]) if d else None
        desc = f"signal {os.WTERMSIG(st)}" if st is not None and os.WIFSIGNALED(st) else f"exit {os.WEXITSTATUS(st)}" if st is not None else "no D"
        print(f"{name:10s} transport {desc}, helper rc={rc}, {dt:.2f}s")
