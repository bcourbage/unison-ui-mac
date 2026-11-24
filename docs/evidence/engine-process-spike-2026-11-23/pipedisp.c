#include <signal.h>
#include <stdio.h>
int main(void) { struct sigaction sa; sigaction(SIGPIPE, NULL, &sa); puts(sa.sa_handler == SIG_IGN ? "ignored" : sa.sa_handler == SIG_DFL ? "default" : "handler"); return 0; }
