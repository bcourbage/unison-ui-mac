/* Audit-token signal test: spawn a child, read its audit token while it is still our
 * unreaped child, then signal it by token. Also try a token with a wrong pid version. */
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
    pid_t c = fork();
    if (c == 0) { execlp("sleep", "sleep", "60", NULL); _exit(127); }
    usleep(100000);
    mach_port_t name = MACH_PORT_NULL;
    kern_return_t kr = task_name_for_pid(mach_task_self(), c, &name);
    printf("task_name_for_pid: kr=%d (%s)\n", kr, mach_error_string(kr));
    audit_token_t tok; mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
    kr = task_info(name, TASK_AUDIT_TOKEN, (task_info_t)&tok, &cnt);
    printf("task_info(TASK_AUDIT_TOKEN): kr=%d (%s) pid=%d pidversion=%d\n", kr, mach_error_string(kr),
           audit_token_to_pid(tok), audit_token_to_pidversion(tok));
    if (kr != KERN_SUCCESS) { kill(c, SIGKILL); waitpid(c, NULL, 0); return 1; }

    audit_token_t wrong = tok; wrong.val[7] += 1;   /* pid version lives in val[7] */
    printf("wrong-version token pidversion=%d\n", audit_token_to_pidversion(wrong));
    int r = proc_signal_with_audittoken(&wrong, SIGTERM);
    printf("signal with WRONG version: r=%d errno=%d (%s)\n", r, errno, strerror(errno));
    int st; pid_t w = waitpid(c, &st, WNOHANG);
    printf("child still alive after wrong-version signal: %s\n", w == 0 ? "yes" : "no");

    r = proc_signal_with_audittoken(&tok, SIGTERM);
    printf("signal with RIGHT version: r=%d errno=%d (%s)\n", r, r ? errno : 0, r ? strerror(errno) : "ok");
    waitpid(c, &st, 0);
    printf("child ended by signal %d\n", WIFSIGNALED(st) ? WTERMSIG(st) : -1);

    /* After reaping, the old token must not hit anything. */
    r = proc_signal_with_audittoken(&tok, 0);
    printf("signal 0 with stale token after reap: r=%d errno=%d (%s)\n", r, errno, strerror(errno));
    return 0;
}
