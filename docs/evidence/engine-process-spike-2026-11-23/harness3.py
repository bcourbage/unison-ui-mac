"""Fault cases for the reviewed corrections. Signals only ids this harness recorded."""
import errno, fcntl, functools, os, signal, subprocess, sys, time
print = functools.partial(print, flush=True)
signal.alarm(60)
LIFE = sys.argv[1]
owned = []

def ps(pid_or_pat):
    out = subprocess.run(["ps", "-ax", "-o", "pid=,pgid=,stat=,command="], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if pid_or_pat in l and "ps -ax" not in l and " Z" not in l]

def start(cmd, sw, sigpipe=signal.SIG_DFL):
    def pre():
        signal.signal(signal.SIGPIPE, sigpipe)
    return subprocess.Popen([LIFE] + cmd, env=dict(os.environ, LIFELINE_PARENT=str(os.getpid()), LIFELINE_STATUS_FD=str(sw)),
                            pass_fds=(sw,), preexec_fn=pre, stdout=subprocess.PIPE)

def status(rc):
    return f"killed by signal {-rc}" if rc < 0 else f"exit {rc}"

def drain(fd):
    os.set_blocking(fd, False); data = b""
    try:
        while True:
            c = os.read(fd, 65536)
            if not c: break
            data += c
    except BlockingIOError:
        pass
    return [l.split()[0] for l in data.decode(errors="replace").splitlines() if l]

# A. reader closed after S; transport exits 7 leaving a SIGTERM-ignoring descendant
sr, sw = os.pipe()
p = start(["sh", "-c", '(trap "" TERM; exec sleep 51) & sleep 0.4; exit 7'], sw); os.close(sw)
time.sleep(0.2); os.read(sr, 64); os.close(sr)
try: rc = p.wait(timeout=10)
except subprocess.TimeoutExpired: rc = None
print(f"A reader closed during cleanup: helper {status(rc) if rc is not None else 'STILL RUNNING'}, survivors={ps('sleep 51')}")

# B. status pipe already full before S: no transport may start
sr, sw = os.pipe()
fcntl.fcntl(sw, fcntl.F_SETFL, fcntl.fcntl(sw, fcntl.F_GETFL) | os.O_NONBLOCK)
n = 0
try:
    while True: n += os.write(sw, b"x")
except BlockingIOError:
    pass
p = start(["sh", "-c", "exec sleep 52"], sw); os.close(sw)
try: rc = p.wait(timeout=5)
except subprocess.TimeoutExpired: rc = None
print(f"B full pipe before S ({n} bytes queued): helper {status(rc) if rc is not None else 'BLOCKED'}, transport ran={bool(ps('sleep 52'))}")
os.close(sr)

# C. live reader stops draining after S; pipe filled; transport exits 7
sr, sw = os.pipe()
p = start(["sh", "-c", "sleep 0.5; exit 7"], sw)
time.sleep(0.2)
fcntl.fcntl(sw, fcntl.F_SETFL, fcntl.fcntl(sw, fcntl.F_GETFL) | os.O_NONBLOCK)
n = 0
try:
    while True: n += os.write(sw, b"y")       # helper already set O_NONBLOCK on the shared description
except BlockingIOError:
    pass
os.close(sw)
t0 = time.monotonic()
try: rc = p.wait(timeout=8)
except subprocess.TimeoutExpired: rc = None
recs = [r for r in drain(sr) if r in ("S", "U", "D")]
print(f"C non-draining reader ({n} filler bytes): helper {status(rc) if rc is not None else 'BLOCKED'} after {time.monotonic()-t0:.2f}s, records={recs} -> {'UNKNOWN' if 'S' in recs and 'D' not in recs else 'verified' if 'D' in recs else '?'}")
if rc is None: p.kill(); p.wait()
os.close(sr)

# D. transport SIGPIPE disposition follows what the helper inherited (bit 13 = 0x1000 in sigignore)
for disp, name in ((signal.SIG_DFL, "default"), (signal.SIG_IGN, "ignored")):
    sr, sw = os.pipe()
    p = start([os.path.join(os.path.dirname(os.path.abspath(__file__)), "pipedisp")], sw, disp); os.close(sw)
    out, _ = p.communicate(timeout=10); os.close(sr)
    print(f"D helper inherited SIGPIPE {name}: transport sees {out.decode().strip()}")
