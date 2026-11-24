"""Failure injection for lifeline v2. Signals only process/group ids this harness recorded."""
import os, pty, signal, subprocess, sys, time, tempfile
from pathlib import Path

signal.alarm(150)
HERE = os.path.dirname(os.path.abspath(__file__))
LIFE = os.path.join(HERE, "lifeline")
owned_groups = set()


def ps_rows():
    out = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,pgid=,stat=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        p = line.split(None, 4)
        if len(p) == 5:
            rows.append((int(p[0]), int(p[1]), int(p[2]), p[3], p[4]))
    return rows


def live_in(pg):
    return [(r[0], r[4]) for r in ps_rows() if r[2] == pg and not r[3].startswith("Z")]


def records(fd):
    os.set_blocking(fd, True)
    data = b""
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data += chunk
    recs = [l.split() for l in data.decode().splitlines()]
    starts = {r[1] for r in recs if r[0] == "S"}
    done = {r[1]: int(r[2]) for r in recs if r[0] == "D"}
    verdict = "verified" if starts and all(n in done for n in starts) else ("none-started" if not starts else "UNKNOWN")
    return recs, verdict, done


def spawn(cmd, die_at_once=False, extra_env=None):
    """Fork an 'engine' that starts the lifeline with a status fd; returns ids and the reader."""
    sr, sw = os.pipe()
    ir, iw = os.pipe()
    eng = os.fork()
    if eng == 0:
        os.close(sr); os.close(ir)
        env = dict(os.environ, LIFELINE_PARENT=str(os.getpid()), LIFELINE_STATUS_FD=str(sw), **(extra_env or {}))
        p = subprocess.Popen([LIFE] + cmd, env=env, pass_fds=(sw,))
        if die_at_once:
            os.kill(os.getpid(), signal.SIGKILL)
        os.close(sw)
        os.write(iw, str(p.pid).encode()); os.close(iw)
        rc = p.wait()                                   # the engine reaps its lifeline
        os._exit(0 if rc is None else 0)
    os.close(sw); os.close(iw)
    d = os.read(ir, 32); os.close(ir)
    return eng, (int(d) if d else None), sr


def transport_group(lifeline_pid, timeout=2.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for r in ps_rows():
            if r[1] == lifeline_pid and r[2] == r[0]:
                owned_groups.add(r[0])
                return r[0]
        time.sleep(0.01)
    return None


failures = []

def result(name, ok, detail):
    if not ok: failures.append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)


STUBBORN = '(trap "" TERM; exec sleep 41) & '

# 1. Ordinary exit 7 leaving a SIGTERM-ignoring descendant (the author's case)
eng, life, sr = spawn(["sh", "-c", STUBBORN + "sleep 0.3; exit 7"])
g = transport_group(life)
t0 = time.monotonic(); recs, verdict, done = records(sr); dt = time.monotonic() - t0
left = live_in(g)
os.waitpid(eng, 0)
result("1 ordinary exit, stubborn descendant", verdict == "verified" and not left and os.WEXITSTATUS(list(done.values())[0]) == 7,
       f"verdict={verdict}, transport status={[os.WEXITSTATUS(s) for s in done.values()]}, live at D/EOF={left}, records closed after {dt:.2f}s (grace 2 s)")

# 2. Engine SIGKILLed while the transport and a stubborn descendant run
eng, life, sr = spawn(["sh", "-c", STUBBORN + "exec sleep 42"])
g = transport_group(life); time.sleep(0.2)
before = live_in(g)
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)
recs, verdict, done = records(sr); left = live_in(g)
result("2 engine killed", verdict == "verified" and not left and len(before) == 2,
       f"group before={[(p, c.split()[0:2]) for p, c in before]}, verdict={verdict}, live at EOF={left}")

# 3. Engine dies immediately after starting the lifeline
eng, life, sr = spawn(["sh", "-c", "exec sleep 43"], die_at_once=True)
os.waitpid(eng, 0)
recs, verdict, done = records(sr); time.sleep(0.3)
stray = [r for r in ps_rows() if "sleep 43" in r[4]]
result("3 engine dies before watch", verdict == "none-started" and not stray, f"records={recs}, stray={stray}")

# 4. Engine retire: SIGTERM to the lifeline (never SIGKILL), transport status preserved
eng, life, sr = spawn(["sh", "-c", STUBBORN + "exec sleep 44"])
g = transport_group(life); time.sleep(0.2)
os.kill(life, signal.SIGTERM)
recs, verdict, done = records(sr); left = live_in(g)
st = list(done.values())[0] if done else None
os.waitpid(eng, 0)
result("4 retire by SIGTERM", verdict == "verified" and not left and st is not None and os.WIFSIGNALED(st) and os.WTERMSIG(st) == 15,
       f"verdict={verdict}, transport terminated by signal {os.WTERMSIG(st) if st is not None and os.WIFSIGNALED(st) else st}, live at EOF={left}")

# 5. Failed exec of the transport
eng, life, sr = spawn(["/nonexistent/transport"])
recs, verdict, done = records(sr); os.waitpid(eng, 0)
st = list(done.values())[0] if done else None
result("5 failed exec", verdict == "verified" and st is not None and os.WEXITSTATUS(st) == 127, f"verdict={verdict}, status={os.WEXITSTATUS(st) if st is not None else None}")

# 6. Lifeline itself SIGKILLed from outside: must read as UNKNOWN, never verified
eng, life, sr = spawn(["sh", "-c", "exec sleep 45"])
g = transport_group(life); time.sleep(0.2)
os.kill(life, signal.SIGKILL)
recs, verdict, done = records(sr); left = live_in(g)
os.waitpid(eng, 0)
result("6 lifeline SIGKILLed externally", verdict == "UNKNOWN", f"verdict={verdict}, transport still live={left} (expected: orphaned, reported unknown)")

# 7. PTY path: lifeline as session leader; the transport's group must own the terminal
psr, psw = os.pipe(); os.set_inheritable(psw, True)
pid, fd = pty.fork()
if pid == 0:
    os.environ["LIFELINE_PARENT"] = str(os.getppid())
    os.environ["LIFELINE_STATUS_FD"] = str(psw)
    os.execv(LIFE, [LIFE, "sh", "-c", "tty; ps -o pgid=,tpgid= -p $$"])
out = b""
while True:
    try:
        c = os.read(fd, 1024)
    except OSError:
        break
    if not c:
        break
    out += c
os.waitpid(pid, 0); os.close(psw); print('  case 7 records:', records(psr)[1])
txt = out.decode(errors="replace").replace("\r", "").split()
fg_ok = len(txt) >= 3 and txt[0].startswith("/dev/ttys") and txt[1] == txt[2]
result("7 PTY foreground", fg_ok, f"output={txt} (pgid == tpgid means the transport group owns the terminal)")

# 8. Real ssh with ProxyCommand, engine killed
eng, life, sr = spawn(["/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ProxyCommand=sleep 46",
                       "-o", "ConnectTimeout=30", "lifeline-test-host", "true"])
g = transport_group(life); time.sleep(0.8)
before = live_in(g)
os.kill(eng, signal.SIGKILL); os.waitpid(eng, 0)
recs, verdict, done = records(sr); left = live_in(g)
result("8 ssh + ProxyCommand", verdict == "verified" and not left and len(before) == 2,
       f"group before={[(p, c.split()[0]) for p, c in before]}, verdict={verdict}, live at EOF={left}")

# 9. Detached descendant: capture its exact PID from a private fixture file.
with tempfile.TemporaryDirectory(prefix="unison-lifeline-escape-") as fixture:
    pidfile = Path(fixture) / "child.pid"
    code = "import os,time; os.setsid(); open(%r,'w').write(str(os.getpid())); time.sleep(47)" % str(pidfile)
    import shlex
    eng, life, sr = spawn(["sh", "-c", shlex.quote(sys.executable) + " -I -c " + shlex.quote(code) + " & sleep 0.3; exit 0"])
    g = transport_group(life)
    recs, verdict, done = records(sr); os.waitpid(eng, 0)
    escaped_pid = int(pidfile.read_text()) if pidfile.exists() else None
    escaped = [r for r in ps_rows() if r[0] == escaped_pid and str(pidfile) in r[4] and not r[3].startswith("Z")]
    result("9 escaped descendant (limit)", verdict == "verified" and bool(escaped),
           f"verdict={verdict}, recorded escaped child={[(r[0], r[2]) for r in escaped]}")
    for row in escaped:
        os.kill(row[0], signal.SIGKILL)

# Sweep: anything left in a group this harness recorded is reported, then ended by group id.
leftover = [(g, live_in(g)) for g in owned_groups if live_in(g)]
for g, _ in leftover:
    os.killpg(g, signal.SIGKILL)
print("leftover in recorded groups (ended now):", leftover or "none", flush=True)

raise SystemExit(bool(failures))
