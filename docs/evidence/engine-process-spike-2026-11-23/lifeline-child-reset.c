/* Lifeline v2 (review prototype, not production).
 *
 * The transport runs as the leader of its OWN process group G (= its pid). The lifeline stays
 * outside G, so signalling G can never kill the cleanup owner. The lifeline does not reap the
 * transport until G has no live members, so G's id stays reserved for every killpg it issues.
 *
 * Records on the status fd (each one write(2) <= PIPE_BUF, so atomic):
 *   S <nonce> <lifeline-pid>            before the transport exists
 *   U <nonce> <live-count>              escalation finished but members still live (repeats)
 *   D <nonce> <wait-status>             written only after G was OBSERVED empty, then reap
 * A reader that sees S without D for a nonce must treat cleanup as unknown.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int status_fd = -1;
static char nonce[17];
static volatile sig_atomic_t stop_requested = 0;
static void noop(int s) { (void)s; stop_requested = 1; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int record(const char *fmt, long a) {
    if (status_fd < 0) return -1;
    char b[96]; int n = snprintf(b, sizeof b, fmt, nonce, a);
    ssize_t w;
    do { w = write(status_fd, b, (size_t)n); } while (w < 0 && errno == EINTR);
    if (w != n) { status_fd = -1; return -1; }            /* endpoint lost: keep cleaning, report nothing */
    return 0;
}

/* Live members of G other than our (possibly exited, unreaped) child. A member whose info
 * cannot be read for a reason other than "gone" counts as live: unknown is not empty. */
static int live_members(pid_t g, pid_t child, int child_exited) {
    pid_t buf[512]; memset(buf, 0, sizeof buf);
    int n = proc_listpgrppids(g, buf, sizeof buf);
    if (n < 0) return 1;
    int live = 0;
    for (int i = 0; i < n && i < 512; i++) {
        if (buf[i] == 0) continue;
        if (buf[i] == child && child_exited) continue;
        struct proc_bsdinfo bi;
        errno = 0;
        if (proc_pidinfo(buf[i], PROC_PIDTBSDINFO, 0, &bi, sizeof bi) > 0) {
            if (bi.pbi_status != 5 /* SZOMB */) live++;
        } else if (errno != ESRCH) {
            live++;
        }
    }
    return live;
}

static void exit_like(int st) {
    if (WIFSIGNALED(st)) { signal(WTERMSIG(st), SIG_DFL); raise(WTERMSIG(st)); }
    _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 70);
}

int main(int argc, char **argv) {
    if (argc < 2) return 64;
    const char *ep = getenv("LIFELINE_PARENT");
    if (!ep) return 64;
    pid_t parent = (pid_t)atoi(ep);
    if (getenv("LIFELINE_STATUS_FD")) status_fd = atoi(getenv("LIFELINE_STATUS_FD"));
    snprintf(nonce, sizeof nonce, "%08x%08x", arc4random(), arc4random());
    struct sigaction inherited_pipe; sigaction(SIGPIPE, NULL, &inherited_pipe);
    signal(SIGPIPE, SIG_IGN);
    if (status_fd >= 0) fcntl(status_fd, F_SETFL, fcntl(status_fd, F_GETFL) | O_NONBLOCK);

    sigset_t stop_set, old_mask;
    sigemptyset(&stop_set);
    sigaddset(&stop_set, SIGTERM); sigaddset(&stop_set, SIGHUP); sigaddset(&stop_set, SIGINT);
    if (sigprocmask(SIG_BLOCK, &stop_set, &old_mask) < 0) return 70;
    int kq = kqueue();
    if (kq < 0) return 70;
    struct kevent ev[4]; int n = 0;
    EV_SET(&ev[n++], parent, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
    int sigs[] = { SIGTERM, SIGHUP, SIGINT };
    for (int i = 0; i < 3; i++) { signal(sigs[i], noop); EV_SET(&ev[n++], sigs[i], EVFILT_SIGNAL, EV_ADD, 0, 0, NULL); }
    /* Spike-only deterministic stop at the handler/filter boundary. */
    if (getenv("SPIKE_STOP_BEFORE_FILTER")) kill(getpid(), SIGTERM);
    if (kevent(kq, ev, n, NULL, 0, NULL) < 0) return 70;     /* includes ESRCH: spawner gone */
    if (getppid() != parent) return 70;                        /* spawner died before the watch */
    if (sigprocmask(SIG_SETMASK, &old_mask, NULL) < 0) return 70;
    if (stop_requested) return 128 + SIGTERM; /* no S and no fork */
    signal(SIGTTOU, SIG_IGN);                                   /* for tcsetpgrp below */

    if (record("S %s %ld\n", (long)getpid()) != 0) return 71;   /* no S, no transport */

    int sync[2];
    if (pipe(sync) < 0) { record("D %s %ld\n", 70L << 8); return 70; }
    pid_t child = fork();
    if (child < 0) { record("D %s %ld\n", 70L << 8); return 70; }
    if (child == 0) {
        /* Do not inherit the helper stop handler across setup or exec. */
        for (int i = 0; i < 3; i++) signal(sigs[i], SIG_DFL);
        setpgid(0, 0);
        close(sync[1]);
        char b; (void)!read(sync[0], &b, 1);                    /* wait until the parent set us up */
        close(sync[0]);
        if (status_fd >= 0) close(status_fd);
        signal(SIGTTOU, SIG_DFL);
        sigaction(SIGPIPE, &inherited_pipe, NULL);
        execvp(argv[1], argv + 1);
        _exit(127);
    }
    close(sync[0]);
    setpgid(child, child);                                      /* both sides, as job-control shells do */
    int tty = open("/dev/tty", O_RDWR | O_CLOEXEC);
    if (tty >= 0) {                                             /* PTY path: hand the terminal to G */
        if (tcgetpgrp(tty) == getpgrp()) tcsetpgrp(tty, child);
        close(tty);
    }
    (void)!write(sync[1], "x", 1); close(sync[1]);

    int child_exited = 0, st = 0;
    struct kevent cev; EV_SET(&cev, child, EVFILT_PROC, EV_ADD, NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
    if (kevent(kq, &cev, 1, NULL, 0, NULL) < 0) {               /* ESRCH: already exited, unreaped */
        siginfo_t si; memset(&si, 0, sizeof si);
        if (waitid(P_PID, child, &si, WEXITED | WNOWAIT) == 0) child_exited = 1;
    }

    /* Wait for a trigger: transport exit, spawner exit, or a stop request. */
    while (!child_exited && !stop_requested) {
        struct kevent got;
        if (kevent(kq, NULL, 0, &got, 1, NULL) <= 0) continue;
        if (got.filter == EVFILT_PROC && (pid_t)got.ident == child) { child_exited = 1; break; }
        break;                                                  /* spawner exit or signal */
    }

    /* Cleanup: TERM, grace, KILL, then observe. Never exit while G has live members. */
    killpg(child, SIGTERM);
    double grace = getenv("LIFELINE_GRACE") ? atof(getenv("LIFELINE_GRACE")) : 2.0;
    double deadline = now() + grace; int phase = 0; double last_u = 0;
    for (;;) {
        if (!child_exited) {
            siginfo_t si; memset(&si, 0, sizeof si);
            if (waitid(P_PID, child, &si, WEXITED | WNOWAIT | WNOHANG) == 0 && si.si_pid == child) child_exited = 1;
        }
        int live = live_members(child, child, child_exited);
        if (child_exited && live == 0) break;
        double t = now();
        if (phase == 0 && t >= deadline) { killpg(child, SIGKILL); phase = 1; deadline = t + 2.0; }
        else if (phase == 1) killpg(child, SIGKILL);
        if (phase == 1 && t >= deadline && t - last_u >= 5.0) { record("U %s %ld\n", (long)(live + !child_exited)); last_u = t; }
        struct timespec tick = { 0, 20 * 1000 * 1000 };
        struct kevent got; kevent(kq, NULL, 0, &got, 1, &tick);  /* drain/ignore further triggers */
    }
    waitpid(child, &st, 0);                                     /* G observed empty: now reap */
    record("D %s %ld\n", (long)st);
    exit_like(st);
}
