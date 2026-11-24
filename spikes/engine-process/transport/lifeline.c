/* Experimental checked lifeline. Not wired into the application or OCaml.
 * The direct child remains unreaped until its group has no live members.
 * Status: S nonce helper-pid; U nonce live-or-minus-one; D nonce wait-status.
 * Lifecycle: TransportStarted/TransportExited/CleanupComplete nonce child status.
 * Started identifies checked setup before exec release, not successful exec.
 * A child of 0 in CleanupComplete means no transport was forked (setup status).
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int status_fd=-1,life_fd=-1;
static char nonce[17];
static volatile sig_atomic_t stop_signal=0;
static void stop_handler(int s){if(!stop_signal)stop_signal=s;}
static double clock_now(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))_exit(70);return t.tv_sec+t.tv_nsec/1e9;}
static void nap(void){struct timespec t={0,20000000};while(nanosleep(&t,&t)<0&&errno==EINTR){} }
static int number(const char *s,int minimum){if(!s||!*s)return -1;char *end;errno=0;long n=strtol(s,&end,10);return errno||*end||n<minimum||n>INT_MAX?-1:(int)n;}
static bool cloexec(int fd){int v=fcntl(fd,F_GETFD);return v>=0&&fcntl(fd,F_SETFD,v|FD_CLOEXEC)==0;}
static bool channel(int fd){struct stat s;int flags=fcntl(fd,F_GETFL);return flags>=0&&(flags&O_NONBLOCK)&&fstat(fd,&s)==0&&S_ISFIFO(s.st_mode)&&cloexec(fd);}
static bool emit(int *fd,const char *kind,pid_t child,int status,bool lifecycle){
    if(*fd<0)return false;
    char b[192];int n=lifecycle?snprintf(b,sizeof b,"%s %s %d %d\n",kind,nonce,child,status):snprintf(b,sizeof b,"%s %s %d\n",kind,nonce,status);
    if(n<=0||(size_t)n>=sizeof b)return false;
    ssize_t k;do{k=write(*fd,b,(size_t)n);}while(k<0&&errno==EINTR);
    if(k!=n){close(*fd);*fd=-1;return false;}
    return true;
}
static bool pipe_cloexec(int p[2]){if(pipe(p))return false;if(cloexec(p[0])&&cloexec(p[1]))return true;close(p[0]);close(p[1]);return false;}
static bool byte_write(int fd,char b){ssize_t n;do{n=write(fd,&b,1);}while(n<0&&errno==EINTR);return n==1;}
static bool pending_stop(const sigset_t *set){
    sigset_t pending;if(sigpending(&pending))return true;
    const int list[]={SIGTERM,SIGHUP,SIGINT};
    for(size_t i=0;i<3;i++)if(sigismember(set,list[i])&&sigismember(&pending,list[i])){if(!stop_signal)stop_signal=list[i];return true;}
    return stop_signal!=0;
}
#ifdef LIFELINE_SPIKE_FAULTS
static const char *fault(void){const char *v=getenv("LIFELINE_TEST_STAGE");return v?v:"";}
static void inject(const char *stage){if(strcmp(fault(),stage)==0)kill(getpid(),SIGTERM);}
static bool fail_stage(const char *stage){return strcmp(fault(),stage)==0;}
static bool enumeration_fault(void){const char *p=getenv("LIFELINE_TEST_ENUM_FILE");return p&&access(p,F_OK)==0;}
#else
static void inject(const char *stage){(void)stage;}
static bool fail_stage(const char *stage){(void)stage;return false;}
static bool enumeration_fault(void){return false;}
#endif
/* Return -1 for uncertainty; never use a full/truncated list as an empty proof.
 * libproc wrappers can return 0 on error. The unreaped group leader must be listed.
 * Source/API semantics are recorded in the spike report; platform churn needs testing.
 */
static int live_members(pid_t group,pid_t leader,bool exited){
    size_t capacity=16;
#ifdef LIFELINE_SPIKE_FAULTS
    if(getenv("LIFELINE_TEST_SMALL_BUFFER"))capacity=2;
#endif
    while(capacity<=32768){
        pid_t *p=calloc(capacity,sizeof *p);if(!p)return -1;
        errno=0;int n;
        if(enumeration_fault()){errno=EIO;n=0;}
        else n=proc_listpgrppids(group,p,(int)(capacity*sizeof *p));
        if(n<=0){free(p);return -1;}
        if((size_t)n>=capacity){free(p);capacity*=2;continue;}
        bool saw_leader=false;int live=0;
        for(int i=0;i<n;i++){
            if(p[i]==leader){saw_leader=true;if(exited)continue;}
            struct proc_bsdinfo info;memset(&info,0,sizeof info);errno=0;
            int bytes=proc_pidinfo(p[i],PROC_PIDTBSDINFO,0,&info,sizeof info);
            if(bytes!=(int)sizeof info){if(bytes==0&&errno==ESRCH)continue;free(p);return -1;}
            if(info.pbi_pgid==(uint32_t)group&&info.pbi_status!=5)live++;
        }
        free(p);return saw_leader?live:-1;
    }
    return -1;
}
static int peek_child(pid_t child,int *status){
    siginfo_t si;memset(&si,0,sizeof si);int rc;
    do{rc=waitid(P_PID,child,&si,WEXITED|WNOWAIT|WNOHANG);}while(rc<0&&errno==EINTR);
    if(rc<0)return -1;if(!si.si_pid)return 0;
    if(si.si_code==CLD_EXITED)*status=(si.si_status&255)<<8;
    else if(si.si_code==CLD_KILLED)*status=si.si_status&127;
    else if(si.si_code==CLD_DUMPED)*status=(si.si_status&127)|128;
    else return -1;
    return 1;
}
static void exit_status(int st){
    if(WIFSIGNALED(st)){int s=WTERMSIG(st);struct sigaction d={0};d.sa_handler=SIG_DFL;sigemptyset(&d.sa_mask);sigaction(s,&d,NULL);sigset_t set;sigemptyset(&set);sigaddset(&set,s);sigprocmask(SIG_UNBLOCK,&set,NULL);raise(s);_exit(128+s);}
    _exit(WIFEXITED(st)?WEXITSTATUS(st):70);
}
static int no_child(int code){int st=code<<8;emit(&life_fd,"CleanupComplete",0,st,true);emit(&status_fd,"D",0,st,false);return code;}

int main(int argc,char **argv){
    if(argc<2)return 64;
    sigset_t stops,old_mask;sigemptyset(&stops);sigaddset(&stops,SIGTERM);sigaddset(&stops,SIGHUP);sigaddset(&stops,SIGINT);
    if(sigprocmask(SIG_BLOCK,&stops,&old_mask))return 70;
    struct sigaction inherited_pipe,inherited_chld,inherited_ttou,action={0};
    if(sigaction(SIGPIPE,NULL,&inherited_pipe)||sigaction(SIGCHLD,NULL,&inherited_chld)||sigaction(SIGTTOU,NULL,&inherited_ttou))return 70;
    action.sa_handler=SIG_IGN;sigemptyset(&action.sa_mask);if(sigaction(SIGPIPE,&action,NULL)||sigaction(SIGTTOU,&action,NULL))return 70;
    // Own the unreaped child even if the spawner ignored SIGCHLD/used NOCLDWAIT.
    action.sa_handler=SIG_DFL;action.sa_flags=0;if(sigaction(SIGCHLD,&action,NULL))return 70;
    action.sa_handler=stop_handler;action.sa_mask=stops;
    const int signals[]={SIGTERM,SIGHUP,SIGINT};for(int i=0;i<3;i++)if(sigaction(signals[i],&action,NULL))return 70;
    pid_t parent=number(getenv("LIFELINE_PARENT"),2);
    status_fd=number(getenv("LIFELINE_STATUS_FD"),3);life_fd=number(getenv("LIFELINE_LIFECYCLE_FD"),3);
    if(parent<2||status_fd<0||life_fd<0||status_fd==life_fd||!channel(status_fd)||!channel(life_fd))return 64;
    snprintf(nonce,sizeof nonce,"%08x%08x",arc4random(),arc4random());
    int kq=kqueue();if(kq<0||!cloexec(kq))return 70;
    struct kevent events[4];EV_SET(&events[0],parent,EVFILT_PROC,EV_ADD,NOTE_EXIT,0,NULL);
    for(int i=0;i<3;i++)EV_SET(&events[i+1],signals[i],EVFILT_SIGNAL,EV_ADD,0,0,NULL);
    inject("before-watch");if(kevent(kq,events,4,NULL,0,NULL)<0||getppid()!=parent)return 70;
    if(sigprocmask(SIG_SETMASK,&old_mask,NULL))return 70;
    inject("before-start");if(stop_signal)return 128+stop_signal;
    if(!emit(&status_fd,"S",0,getpid(),false))return 71;
    int ready[2],release[2];if(!pipe_cloexec(ready))return no_child(70);
    if(!pipe_cloexec(release)){close(ready[0]);close(ready[1]);return no_child(70);}
    // The child inherits blocked stops, resets dispositions first, then acknowledges setup.
    if(sigprocmask(SIG_BLOCK,&stops,NULL))return no_child(70);
    inject("before-fork");if(pending_stop(&stops))return no_child(128+(stop_signal?stop_signal:SIGTERM));
    pid_t child=fail_stage("fork-failure")?-1:fork();if(child<0)return no_child(70);
    if(child==0){
        struct sigaction d={0};d.sa_handler=SIG_DFL;sigemptyset(&d.sa_mask);
        for(int i=0;i<3;i++)if(sigaction(signals[i],&d,NULL))_exit(70);
        close(ready[0]);close(release[1]);close(status_fd);close(life_fd);close(kq);
        if(fail_stage("child-setup")||setpgid(0,0))_exit(70);
        if(!byte_write(ready[1],'R'))_exit(70);close(ready[1]);
        char b=0;ssize_t n;do{n=read(release[0],&b,1);}while(n<0&&errno==EINTR);
        close(release[0]);if(n!=1||b!='X')_exit(70);
        if(fail_stage("after-release")){struct timespec delay={0,300000000};nanosleep(&delay,NULL);}
        if(sigaction(SIGPIPE,&inherited_pipe,NULL)||sigaction(SIGCHLD,&inherited_chld,NULL)||sigaction(SIGTTOU,&inherited_ttou,NULL)||sigprocmask(SIG_SETMASK,&old_mask,NULL))_exit(70);
        unsetenv("LIFELINE_PARENT");unsetenv("LIFELINE_STATUS_FD");unsetenv("LIFELINE_LIFECYCLE_FD");
        unsetenv("LIFELINE_TEST_STAGE");unsetenv("LIFELINE_TEST_ENUM_FILE");unsetenv("LIFELINE_TEST_SMALL_BUFFER");unsetenv("LIFELINE_TEST_GRACE_MS");
        execvp(argv[1],argv+1);_exit(127);
    }
    close(ready[1]);close(release[0]);
    bool group_owned=setpgid(child,child)==0,setup_ok=false;
    if(sigprocmask(SIG_SETMASK,&old_mask,NULL))stop_signal=SIGTERM;
    double setup_deadline=clock_now()+5;
    while(!stop_signal&&clock_now()<setup_deadline){
        struct pollfd p={.fd=ready[0],.events=POLLIN};int n=poll(&p,1,20);
        if(n<0&&errno==EINTR)continue;if(n<0)break;
        if(n>0){char b;setup_ok=read(ready[0],&b,1)==1&&b=='R';break;}
    }
    close(ready[0]);if(setup_ok)group_owned=true;
    int tty=open("/dev/tty",O_RDWR|O_CLOEXEC);
    if(tty>=0){if(!setup_ok||tcgetpgrp(tty)!=getpgrp()||fail_stage("tty-setup")||tcsetpgrp(tty,child))setup_ok=false;close(tty);}
    else if(errno!=ENXIO&&errno!=ENOTTY&&errno!=ENOENT)setup_ok=false;
    if(setup_ok&&!stop_signal)setup_ok=emit(&life_fd,"TransportStarted",child,0,true);
    if(fail_stage("release-eof"))setup_ok=false;
    if(setup_ok&&!stop_signal)setup_ok=byte_write(release[1],'X');
    close(release[1]);inject("after-release");
    bool exited=false,e_sent=false,identity_lost=false;int peek_status=0;
    while(setup_ok&&!stop_signal&&!exited){
        int observed=peek_child(child,&peek_status);
        if(observed<0){identity_lost=true;break;}if(observed>0){exited=true;break;}
        struct timespec tick={0,20000000};struct kevent event;
        int n=kevent(kq,NULL,0,&event,1,&tick);
        if(n<0&&errno!=EINTR){stop_signal=SIGTERM;break;}
        if(n>0&&event.filter==EVFILT_PROC&&(pid_t)event.ident==parent){stop_signal=SIGTERM;break;}
    }
    if(exited){emit(&life_fd,"TransportExited",child,peek_status,true);e_sent=true;}
    if(!identity_lost){if(group_owned)killpg(child,SIGTERM);else kill(child,SIGTERM);}
    double grace=2.0;
#ifdef LIFELINE_SPIKE_FAULTS
    int ms=number(getenv("LIFELINE_TEST_GRACE_MS"),50);if(ms>=50&&ms<=5000)grace=ms/1000.0;
#endif
    double deadline=clock_now()+grace,last_unknown=0;int empty_rounds=0;
    for(;;){
        if(!exited&&!identity_lost){int observed=peek_child(child,&peek_status);if(observed<0)identity_lost=true;else if(observed>0)exited=true;}
        if(exited&&!e_sent){emit(&life_fd,"TransportExited",child,peek_status,true);e_sent=true;}
        int live=identity_lost?-1:(group_owned?live_members(child,child,exited):(exited?0:1));
        if(exited&&live==0){if(++empty_rounds>=2)break;}else empty_rounds=0;
        double t=clock_now();
        if(!identity_lost&&t>=deadline){if(group_owned)killpg(child,SIGKILL);else kill(child,SIGKILL);}
        if((live<0||t>=deadline)&&t-last_unknown>=0.25){emit(&status_fd,"U",0,live,false);last_unknown=t;}
        nap();
    }
    // No group signal is issued after this point; reaping frees the reserved identity.
    int status=0;pid_t got;do{got=waitpid(child,&status,0);}while(got<0&&errno==EINTR);
    if(got!=child)_exit(70); // Missing D keeps cleanup unknown.
    emit(&life_fd,"CleanupComplete",child,status,true);emit(&status_fd,"D",0,status,false);
    exit_status(status);return 70;
}
