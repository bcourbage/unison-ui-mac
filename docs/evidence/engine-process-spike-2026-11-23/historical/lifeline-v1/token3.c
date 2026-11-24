/* Does the pid version change at exec? And does posix_spawn hand back a post-exec identity?
 * Then repeat the orphan test using a post-exec token. */
#include <bsm/libbsm.h>
#include <libproc.h>
#include <mach/mach.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

static int version_of(pid_t pid, audit_token_t *out) {
    mach_port_t name; audit_token_t tok; mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
    if (task_name_for_pid(mach_task_self(), pid, &name) != KERN_SUCCESS) return -1;
    if (task_info(name, TASK_AUDIT_TOKEN, (task_info_t)&tok, &cnt) != KERN_SUCCESS) return -1;
    mach_port_deallocate(mach_task_self(), name);
    if (out) *out = tok;
    return audit_token_to_pidversion(tok);
}

int main(void) {
    /* 1. fork, read version before and after exec */
    int go[2]; pipe(go);
    pid_t c = fork();
    if (c == 0) { char b; read(go[0], &b, 1); execlp("sleep", "sleep", "62", NULL); _exit(127); }
    int before = version_of(c, NULL);
    write(go[1], "x", 1); usleep(100000);
    int after = version_of(c, NULL);
    printf("fork+exec: version before exec %d, after exec %d\n", before, after);
    kill(c, SIGKILL); waitpid(c, NULL, 0);

    /* 2. posix_spawn: identity read right after it returns */
    char *args[] = { "sleep", "63", NULL };
    pid_t s; posix_spawnp(&s, "sleep", NULL, NULL, args, environ);
    int v1 = version_of(s, NULL); usleep(100000); int v2 = version_of(s, NULL);
    printf("posix_spawn: version at return %d, 100 ms later %d\n", v1, v2);
    kill(s, SIGKILL); waitpid(s, NULL, 0);

    /* 3. orphan test with a post-exec token (posix_spawn) */
    int p[2]; pipe(p);
    pid_t engine = fork();
    if (engine == 0) {
        pid_t t; char *a[] = { "sleep", "64", NULL };
        posix_spawnp(&t, "sleep", NULL, NULL, a, environ);
        audit_token_t tok; version_of(t, &tok);
        write(p[1], &tok, sizeof tok);
        kill(getpid(), SIGKILL);
    }
    audit_token_t tok; read(p[0], &tok, sizeof tok);
    waitpid(engine, NULL, 0); usleep(100000);
    pid_t t = audit_token_to_pid(tok);
    struct proc_bsdinfo bi; proc_pidinfo(t, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    int r = proc_signal_with_audittoken(&tok, SIGTERM);
    usleep(200000);
    int alive = kill(t, 0) == 0;
    printf("orphan %d (ppid %d) signalled by post-exec token: r=%d, alive afterwards: %s\n",
           t, bi.pbi_ppid, r, alive ? "YES" : "no");
    if (alive) { kill(t, SIGKILL); printf("cleaned up %d\n", t); }
    return 0;
}
