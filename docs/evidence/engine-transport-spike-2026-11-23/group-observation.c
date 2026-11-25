#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
int main(void){pid_t c=fork();if(c<0)return 1;if(!c){if(setpgid(0,0))_exit(1);_exit(0);}siginfo_t si={0};if(waitid(P_PID,c,&si,WEXITED|WNOWAIT))return 2;pid_t p[16]={0};errno=0;int estimate=proc_listpgrppids(c,NULL,0),e1=errno;errno=0;int n=proc_listpgrppids(c,p,sizeof p),e2=errno;struct proc_bsdinfo bi={0};int b=proc_pidinfo(c,PROC_PIDTBSDINFO,0,&bi,sizeof bi);printf("estimate=%d errno=%d listed=%d errno=%d first_is_child=%d info_bytes=%d expected_bytes=%zu status=%u\n",estimate,e1,n,e2,n>0&&p[0]==c,b,sizeof bi,bi.pbi_status);int st;waitpid(c,&st,0);return 0;}
