/* "GUI" forks an "engine"; the engine spawns a "transport", reads its audit token while
 * it is still the engine's unreaped child, sends the token to the GUI, then dies abruptly.
 * The transport is now an orphan owned by launchd. The GUI signals it by token. */
#include <bsm/libbsm.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int p[2]; pipe(p);
    pid_t engine = fork();
    if (engine == 0) {
        close(p[0]);
        pid_t t = fork();
        if (t == 0) { execlp("sleep", "sleep", "61", NULL); _exit(127); }
        mach_port_t name; audit_token_t tok; mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
        task_name_for_pid(mach_task_self(), t, &name);
        task_info(name, TASK_AUDIT_TOKEN, (task_info_t)&tok, &cnt);
        write(p[1], &tok, sizeof tok);
        kill(getpid(), SIGKILL);                     /* engine dies without cleanup */
    }
    close(p[1]);
    audit_token_t tok;
    read(p[0], &tok, sizeof tok);
    int st; waitpid(engine, &st, 0);
    pid_t t = audit_token_to_pid(tok);
    usleep(100000);
    struct proc_bsdinfo bi;
    proc_pidinfo(t, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    printf("engine killed by signal %d; transport %d now has ppid %d\n", WTERMSIG(st), t, bi.pbi_ppid);
    int r = proc_signal_with_audittoken(&tok, SIGTERM);
    printf("GUI signals orphan by token: r=%d\n", r);
    usleep(200000);
    printf("orphan alive afterwards: %s\n", kill(t, 0) == 0 ? "YES" : "no");
    return 0;
}
