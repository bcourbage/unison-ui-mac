/* Lifeline prototype: run argv[1..] as our own child in our own process group,
 * and end that group when (a) our parent exits, (b) we receive SIGTERM/SIGHUP/SIGINT,
 * or (c) the child exits on its own (then we exit with its status).
 * The parent-exit watch is armed BEFORE the child is created, so a parent that dies
 * at any point after spawning us is always noticed. */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

/* A caught (not ignored) signal: macOS drops ignored signals before kqueue sees them. */
static void noop(int sig) { (void)sig; }

static void die_like(int status) {
    if (WIFSIGNALED(status)) { signal(WTERMSIG(status), SIG_DFL); raise(WTERMSIG(status)); }
    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: nanny cmd [args]\n"); return 2; }
    /* The spawner names itself. Reading getppid() here would race: a spawner that already
     * died makes getppid() return 1, and we would watch launchd forever. */
    const char *ep = getenv("LIFELINE_PARENT");
    pid_t parent = ep ? (pid_t)atoi(ep) : getppid();
    int kq = kqueue();
    if (kq < 0) { perror("kqueue"); return 1; }
    struct kevent ev[4];
    int n = 0;
    EV_SET(&ev[n++], parent, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
    int sigs[] = { SIGTERM, SIGHUP, SIGINT };
    for (int i = 0; i < 3; i++) { signal(sigs[i], noop); EV_SET(&ev[n++], sigs[i], EVFILT_SIGNAL, EV_ADD, 0, 0, NULL); }
    if (kevent(kq, ev, n, NULL, 0, NULL) < 0) { _exit(errno == ESRCH ? 0 : 1); }   /* parent already gone */
    if (getppid() != parent) _exit(0);                                              /* belt and braces */
    if (getpgrp() != getpid() && setpgid(0, 0) < 0 && errno != EPERM) { perror("setpgid"); return 1; }

    int barrier = getenv("LIFELINE_BARRIER_FD") ? atoi(getenv("LIFELINE_BARRIER_FD")) : -1;
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child == 0) {
        if (barrier >= 0) close(barrier);           /* only the lifeline holds the barrier */
        for (int i = 0; i < 3; i++) signal(sigs[i], SIG_DFL);
        execvp(argv[1], argv + 1);
        _exit(127);
    }
    struct kevent cev;
    EV_SET(&cev, child, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
    kevent(kq, &cev, 1, NULL, 0, NULL);             /* child is ours and unreaped: no race */

    for (;;) {
        struct kevent got;
        if (kevent(kq, NULL, 0, &got, 1, NULL) <= 0) continue;
        if (got.filter == EVFILT_PROC && (pid_t)got.ident == child) {
            int st; waitpid(child, &st, 0);
            killpg(getpgrp(), SIGTERM);             /* stragglers the child left behind */
            die_like(st);
        }
        /* parent exited or we were asked to stop: end our group, child first */
        killpg(getpgrp(), SIGTERM);
        struct timespec grace = { 2, 0 };
        struct kevent w;
        int st;
        if (kevent(kq, NULL, 0, &w, 1, &grace) > 0 && w.filter == EVFILT_PROC && (pid_t)w.ident == child) {
            waitpid(child, &st, 0);
        } else {
            kill(child, SIGKILL);                   /* still our unreaped child: exact target */
            waitpid(child, &st, 0);
        }
        signal(SIGKILL, SIG_DFL);
        killpg(getpgrp(), SIGKILL);                 /* remaining group members, then ourselves */
        _exit(1);
    }
}
