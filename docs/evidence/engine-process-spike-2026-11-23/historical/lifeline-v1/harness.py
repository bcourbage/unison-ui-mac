"""Failure-injection harness for the lifeline prototype. Only signals PIDs it recorded."""
import os, pty, signal, subprocess, sys, time

signal.alarm(80)   # never hang the session
HERE = os.path.dirname(os.path.abspath(__file__))
NANNY = os.path.join(HERE, "nanny")
recorded = set()


def group_members(pgid):
    out = subprocess.run(["ps", "-ax", "-o", "pid=,pgid=,ppid=,stat=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5 and int(parts[1]) == pgid and not parts[3].startswith("Z"):   # zombies await their parent's wait
            rows.append((int(parts[0]), int(parts[2]), parts[4]))
    return rows


def wait_gone(pgid, limit=3.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < limit:
        if not group_members(pgid):
            return time.monotonic() - t0
        time.sleep(0.01)
    return None


def engine(cmd, die_after_spawn=False, env=None, pass_fds=()):
    """Fork an 'engine' that spawns the lifeline, reports its pid, then waits (or dies at once)."""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        env = dict(env or os.environ, LIFELINE_PARENT=str(os.getpid()))
        n = subprocess.Popen([NANNY] + cmd, env=env, pass_fds=pass_fds)
        if die_after_spawn:
            os.kill(os.getpid(), signal.SIGKILL)
        os.write(w, str(n.pid).encode()); os.close(w)
        time.sleep(600)
        os._exit(0)
    os.close(w)
    data = os.read(r, 32); os.close(r)
    recorded.add(pid)
    return pid, (int(data) if data else None)


def report(name, ok, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")


# A. engine SIGKILLed after spawn: child + background grandchild must go
eng, nan = engine(["sh", "-c", "sleep 301 & exec sleep 302"]); recorded.add(nan)
time.sleep(0.3)
before = group_members(nan)
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)
t = wait_gone(nan)
report("A engine killed", t is not None and len(before) == 3,
       f"group before={[(p, c.split()[0:2]) for p, _, c in before]}, emptied in {t and round(t*1000)} ms")

# B. engine dies immediately after spawning (before any registration could happen)
os.environ["MARK"] = "B"
eng, _ = engine(["sh", "-c", "exec sleep 303"], die_after_spawn=True)
os.waitpid(eng, 0)
time.sleep(0.5)
left = [l for l in subprocess.run(["ps", "-ax", "-o", "pid=,command="], capture_output=True, text=True).stdout.splitlines() if "sleep 303" in l]
report("B engine dies before registration", not left, f"leftover={left}")

# C. stop request (SIGTERM) to the lifeline
eng, nan = engine(["sh", "-c", "sleep 304 & exec sleep 305"]); recorded.add(nan)
time.sleep(0.3)
os.kill(nan, signal.SIGTERM)
t = wait_gone(nan)
report("C SIGTERM to lifeline", t is not None, f"group emptied in {t and round(t*1000)} ms")
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)

# D. child exits normally: status is propagated
p = subprocess.run([NANNY, "sh", "-c", "exit 7"])
report("D exit status propagated", p.returncode == 7, f"returncode={p.returncode}")
p = subprocess.run([NANNY, "sh", "-c", "kill -TERM $$"])
report("D signal status propagated", p.returncode == -15, f"returncode={p.returncode}")

# E. completion barrier: EOF only after the lifeline (and so its child) is gone
br, bw = os.pipe()
env = dict(os.environ, LIFELINE_BARRIER_FD=str(bw))
eng, nan = engine(["sh", "-c", "exec sleep 306"], env=env, pass_fds=(bw,)); recorded.add(nan)
os.close(bw)
time.sleep(0.3)
os.set_blocking(br, False)
try:
    early = os.read(br, 1); early_state = "EOF" if early == b"" else "data"
except BlockingIOError:
    early_state = "open"
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)
os.set_blocking(br, True)
t0 = time.monotonic(); eof = os.read(br, 1) == b""; dt = time.monotonic() - t0
gone = not group_members(nan)
report("E completion barrier", early_state == "open" and eof and gone,
       f"while running: {early_state}; EOF after engine death in {round(dt*1000)} ms; group empty at EOF: {gone}")

# F. PTY path: lifeline as session leader on a PTY; its child keeps the controlling terminal
pid, fd = pty.fork()
if pid == 0:
    os.execv(NANNY, [NANNY, "sh", "-c", "tty; ps -o pid=,pgid=,sess=,tpgid=,tt= -p $$"])
out = b""
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
text = out.decode(errors="replace").strip().replace("\r", "")
report("F PTY child keeps controlling tty", "/dev/ttys" in text, text.replace("\n", " | "))

# G. real ssh with a ProxyCommand under the lifeline; barrier fd must not leak into ssh
br, bw = os.pipe()
env = dict(os.environ, LIFELINE_BARRIER_FD=str(bw))
eng, nan = engine(["/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ProxyCommand=sleep 307",
                   "-o", "ConnectTimeout=30", "lifeline-test-host", "true"], env=env, pass_fds=(bw,)); recorded.add(nan)
os.close(bw)
time.sleep(0.8)
members = group_members(nan)
ssh_pid = next((p for p, _, c in members if c.startswith("/usr/bin/ssh")), None)
fds = subprocess.run(["lsof", "-a", "-p", str(ssh_pid), "-d", str(bw)], capture_output=True, text=True).stdout if ssh_pid else ""
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)
t = wait_gone(nan)
report("G ssh + ProxyCommand", ssh_pid is not None and t is not None and len(members) == 3,
       f"group={[(p, c.split()[0]) for p, _, c in members]}; barrier fd {bw} open in ssh: {'yes' if fds.strip() else 'no'}; emptied in {t and round(t*1000)} ms")

# Final sweep: anything still alive in a recorded group is reported and ended by exact pid.
stray = [(p, c) for g in recorded for p, _, c in group_members(g)]
for p, _ in stray:
    os.kill(p, signal.SIGKILL)
print("stray processes:", stray or "none")
