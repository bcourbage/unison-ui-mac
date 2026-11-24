#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
int main(void) {
    pid_t c = fork();
    if (c == 0) { setpgid(0, 0); if (fork() == 0) { execlp("sleep","sleep","42",NULL); } execlp("sleep","sleep","43",NULL); _exit(127); }
    setpgid(c, c); usleep(200000);
    pid_t buf[64]; memset(buf, 0, sizeof buf);
    int r = proc_listpgrppids(c, buf, sizeof buf);
    printf("proc_listpgrppids returned %d; entries:", r); for (int i = 0; i < 64 && buf[i]; i++) printf(" %d", buf[i]); printf("\n");
    kill(c, SIGKILL); usleep(100000);                       /* c is now an unreaped zombie */
    struct proc_bsdinfo bi; int ok = proc_pidinfo(c, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    printf("zombie child pidinfo ok=%d status=%u (SZOMB=5)\n", ok, ok > 0 ? bi.pbi_status : 0);
    memset(buf, 0, sizeof buf); r = proc_listpgrppids(c, buf, sizeof buf);
    printf("group listing with zombie leader: r=%d entries:", r); for (int i = 0; i < 64 && buf[i]; i++) printf(" %d", buf[i]); printf("\n");
    int kq = kqueue(); struct kevent ev; EV_SET(&ev, c, EVFILT_PROC, EV_ADD, NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
    int kr = kevent(kq, &ev, 1, NULL, 0, NULL);
    printf("kevent register on zombie child: %d errno=%d (%s)\n", kr, kr < 0 ? errno : 0, kr < 0 ? strerror(errno) : "ok");
    siginfo_t si; memset(&si, 0, sizeof si); int w = waitid(P_PID, c, &si, WEXITED | WNOWAIT);
    printf("waitid WNOWAIT: %d code=%d status=%d; still a zombie: %s\n", w, si.si_code, si.si_status, proc_pidinfo(c, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) > 0 ? "yes" : "no");
    killpg(c, SIGKILL); waitpid(c, NULL, 0); usleep(100000);
    memset(buf, 0, sizeof buf); r = proc_listpgrppids(c, buf, sizeof buf); printf("after killpg+reap: r=%d\n", r);
    return 0;
}
