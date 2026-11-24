#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){struct sigaction action;if(sigaction(SIGPIPE,NULL,&action))return 70;const char *keys[]={"LIFELINE_PARENT","LIFELINE_STATUS_FD","LIFELINE_LIFECYCLE_FD","LIFELINE_TEST_STAGE","LIFELINE_TEST_ENUM_FILE","LIFELINE_TEST_SMALL_BUFFER","LIFELINE_TEST_GRACE_MS"};int leaks=0;for(size_t i=0;i<sizeof keys/sizeof keys[0];i++)if(getenv(keys[i]))leaks++;printf("SIGPIPE=%s HELPER_ENV=%d\n",action.sa_handler==SIG_IGN?"ignored":action.sa_handler==SIG_DFL?"default":"handler",leaks);return leaks?1:0;}
