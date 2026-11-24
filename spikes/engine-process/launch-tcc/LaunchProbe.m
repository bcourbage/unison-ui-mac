// Standalone platform probe. No Unison runtime, profiles, archive operations or updater.
#import <Cocoa/Cocoa.h>
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

static double seconds(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL allIO(int fd, void *p, size_t n, BOOL writing) {
    char *b=p;
    while (n) {
        ssize_t k=writing ? write(fd,b,n) : read(fd,b,n);
        if (k<0 && errno==EINTR) continue;
        if (k<=0) return NO;
        b+=k;n-=(size_t)k;
    }
    return YES;
}
static BOOL sendJSON(int fd, NSDictionary *d) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    if (!data || data.length>1024*1024) return NO;
    uint32_t n=htonl((uint32_t)data.length);
    return allIO(fd,&n,sizeof n,YES) && allIO(fd,(void *)data.bytes,data.length,YES);
}
static NSDictionary *receiveJSON(int fd) {
    uint32_t n;
    if (!allIO(fd,&n,sizeof n,NO)) return nil;
    n=ntohl(n);if (!n || n>1024*1024) return nil;
    NSMutableData *d=[NSMutableData dataWithLength:n];
    if (!allIO(fd,d.mutableBytes,n,NO)) return nil;
    id value=[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSDictionary *readTarget(NSDictionary *t) {
    NSString *path=t[@"path"], *label=t[@"label"];
    if (![path isKindOfClass:NSString.class] || ![label isKindOfClass:NSString.class])
        return @{@"configuration_error":@YES};
    struct stat st;errno=0;
    int rc=lstat(path.fileSystemRepresentation,&st), statErr=rc ? errno : 0;
    BOOL isDir=rc==0 && S_ISDIR(st.st_mode);
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|(isDir?O_DIRECTORY:0));
    int openErr=fd<0 ? errno : 0, readErr=0;BOOL readable=NO;
    if (fd>=0 && isDir) {
        DIR *dir=fdopendir(fd);
        if (dir) { errno=0;(void)readdir(dir);readErr=errno;readable=readErr==0;closedir(dir); }
        else { readErr=errno;close(fd); }
    } else if (fd>=0) {
        // Only a caller-approved file or disposable fixture. Never retain content.
        char byte;ssize_t count=read(fd,&byte,1);readErr=count<0?errno:0;readable=count>=0;close(fd);
    }
    return @{@"label":label,@"stat_ok":@(rc==0),@"stat_errno":@(statErr),
        @"open_ok":@(fd>=0),@"open_errno":@(openErr),@"read_ok":@(readable),
        @"read_errno":@(readErr),@"directory":@(isDir)};
}
// Sources are moved above reserved descriptor numbers before any spawn actions.
static int spawnOwned(NSString *exe, NSArray<NSString *> *args, int channel, int status, int output, pid_t *pid) {
    posix_spawn_file_actions_t fa;posix_spawnattr_t at;
    int error=posix_spawn_file_actions_init(&fa);if (error) return error;
    error=posix_spawnattr_init(&at);
    if (error) {posix_spawn_file_actions_destroy(&fa);return error;}
    if (channel>=0) error=posix_spawn_file_actions_adddup2(&fa,channel,3);
    if (!error && status>=0) error=posix_spawn_file_actions_adddup2(&fa,status,4);
    if (!error && output>=0) error=posix_spawn_file_actions_adddup2(&fa,output,STDOUT_FILENO);
    sigset_t mask, defaults;sigemptyset(&mask);sigemptyset(&defaults);
    sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGHUP);sigaddset(&defaults,SIGINT);
    if (!error) error=posix_spawnattr_setsigmask(&at,&mask);
    if (!error) error=posix_spawnattr_setsigdefault(&at,&defaults);
    if (!error) error=posix_spawnattr_setflags(&at,POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    char **argv=calloc(args.count+2,sizeof(char *));
    if (!argv && !error) error=ENOMEM;
    if (argv) {
        argv[0]=(char *)exe.fileSystemRepresentation;
        for (NSUInteger i=0;i<args.count;i++) argv[i+1]=(char *)args[i].UTF8String;
        if (!error) error=posix_spawn(pid,exe.fileSystemRepresentation,&fa,&at,argv,environ);
    }
    free(argv);posix_spawnattr_destroy(&at);posix_spawn_file_actions_destroy(&fa);return error;
}
static _Atomic bool engineFinished=false;
static void *watchGUI(void *unused) {
    (void)unused;
    while (!atomic_load(&engineFinished)) {
        struct pollfd p={.fd=3,.events=0};int rc=poll(&p,1,100);
        if (rc>0 && (p.revents&(POLLHUP|POLLERR|POLLNVAL))) _exit(72);
        if (rc<0 && errno!=EINTR) _exit(73);
    }
    return NULL;
}
static int engineMain(void) {
    struct sockaddr_storage addr;socklen_t len=sizeof addr;
    if (getpeername(3,(struct sockaddr *)&addr,&len)!=0 || addr.ss_family!=AF_UNIX) return 64;
    struct timeval limit={180,0};setsockopt(3,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof limit);
    NSDictionary *request=receiveJSON(3);
    if (![request[@"nonce"] isKindOfClass:NSString.class] || ![request[@"targets"] isKindOfClass:NSArray.class]) return 65;
    pthread_t monitor;int threadError=pthread_create(&monitor,NULL,watchGUI,NULL);
    if (threadError) return 66;
    // Writer is nonblocking already; do not change a shared writer's flags here.
    setenv("LIFELINE_PARENT",[[NSString stringWithFormat:@"%d",getpid()] UTF8String],1);
    setenv("LIFELINE_STATUS_FD","4",1);
    NSString *helper=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/lifeline"];
    int ready[2]={-1,-1};int readyError=pipe(ready)==0?0:errno;
    pid_t helperPID=0;int statusCopy=fcntl(4,F_DUPFD_CLOEXEC,20);
    int readyCopy=readyError?-1:fcntl(ready[1],F_DUPFD_CLOEXEC,20);
    int spawnError=readyError?readyError:((statusCopy<0 || readyCopy<0)?errno:
        spawnOwned(helper,@[@"/bin/sh",@"-c",@"printf r; exec /bin/sleep 30"],-1,statusCopy,readyCopy,&helperPID));
    if (statusCopy>=0) close(statusCopy);if (readyCopy>=0) close(readyCopy);
    if (ready[1]>=0)close(ready[1]);
    BOOL transportReady=NO;
    if (!spawnError) {
        struct pollfd p={.fd=ready[0],.events=POLLIN};char byte=0;
        int rc;do {rc=poll(&p,1,10000);} while(rc<0 && errno==EINTR);
        transportReady=rc>0 && read(ready[0],&byte,1)==1 && byte=='r';
    }
    if (ready[0]>=0)close(ready[0]);
    NSMutableArray *results=[NSMutableArray array];
    for (NSDictionary *target in request[@"targets"]) [results addObject:readTarget(target)];
    int helperStatus=-1;BOOL helperReaped=NO;
    if (!spawnError) {
        kill(helperPID,SIGTERM); // Still our unreaped child; never SIGKILL the cleanup owner.
        double deadline=seconds()+6;
        while (seconds()<deadline) {
            pid_t k=waitpid(helperPID,&helperStatus,WNOHANG);
            if (k==helperPID) {helperReaped=YES;break;}
            if (k<0 && errno!=EINTR) break;
            usleep(10000);
        }
    }
    close(4);
    NSDictionary *reply=@{@"nonce":request[@"nonce"],@"engine_pid":@(getpid()),
        @"parent_pid":@(getppid()),@"bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"",
        @"executable":NSBundle.mainBundle.executablePath?:@"",@"targets":results,
        @"helper_spawn_errno":@(spawnError),@"helper_transport_ready":@(transportReady),@"helper_reaped":@(helperReaped),@"helper_wait_status":@(helperStatus)};
    BOOL sent=sendJSON(3,reply);atomic_store(&engineFinished,true);pthread_join(monitor,NULL);close(3);
    return sent && !spawnError && transportReady && helperReaped ? 0 : 67;
}
@interface StatusReader : NSObject
@property(atomic) BOOL engineReaped;
@property(nonatomic) int fd;
@property(nonatomic,strong) NSData *data;
@property(nonatomic) BOOL eof;
@property(nonatomic) BOOL failed;
- (void)drain;
@end
@implementation StatusReader
- (void)drain {
    NSMutableData *data=[NSMutableData data];double deadline=0;
    for (;;) {
        if (self.engineReaped && !deadline) deadline=seconds()+15;
        if (deadline && seconds()>deadline) {self.failed=YES;break;}
        struct pollfd p={.fd=self.fd,.events=POLLIN};int rc=poll(&p,1,100);
        if (rc<0) {if (errno==EINTR) continue;self.failed=YES;break;}
        if (!rc) continue;
        char bytes[1024];ssize_t n=read(self.fd,bytes,sizeof bytes);
        if (!n) {self.eof=YES;break;}
        if (n<0) {if (errno==EINTR||errno==EAGAIN) continue;self.failed=YES;break;}
        if (data.length+(NSUInteger)n>65536) {self.failed=YES;break;}
        [data appendBytes:bytes length:(NSUInteger)n];
    }
    close(self.fd);self.data=data;
}
@end
static NSDictionary *statusVerdict(StatusReader *reader) {
    NSString *text=[[NSString alloc] initWithData:reader.data?:NSData.data encoding:NSUTF8StringEncoding];
    NSMutableDictionary *starts=[NSMutableDictionary dictionary],*done=[NSMutableDictionary dictionary];BOOL valid=text!=nil;
    NSArray *lines=[text componentsSeparatedByString:@"\n"]?:@[];
    for (NSUInteger i=0;i<lines.count;i++) {
        NSString *line=lines[i];if (!line.length && i==lines.count-1) continue;
        NSArray *fields=[line componentsSeparatedByString:@" "];
        if (fields.count!=3) {valid=NO;continue;}
        NSString *kind=fields[0],*nonce=fields[1];
        if ([kind isEqual:@"S"] && !starts[nonce]) starts[nonce]=fields[2];
        else if ([kind isEqual:@"D"] && starts[nonce] && !done[nonce]) done[nonce]=fields[2];
        else if (![kind isEqual:@"U"] || !starts[nonce] || done[nonce]) valid=NO;
    }
    BOOL complete=reader.eof && !reader.failed && valid && starts.count==1 && done.count==starts.count && [text hasSuffix:@"\n"];
    return @{@"eof":@(reader.eof),@"reader_failed":@(reader.failed),@"valid":@(valid),
        @"starts":@(starts.count),@"completions":@(done.count),@"verified":@(complete),@"records":text?:@"invalid UTF-8"};
}
static NSDictionary *runProbe(NSDictionary *config) {
    double began=seconds();int pair[2],pipefd[2];
    if (socketpair(AF_UNIX,SOCK_STREAM,0,pair)!=0) return @{@"setup_errno":@(errno)};
    if (pipe(pipefd)!=0) {int e=errno;close(pair[0]);close(pair[1]);return @{@"setup_errno":@(e)};}
    int flags=fcntl(pipefd[1],F_GETFL);
    int setup=flags<0?-1:fcntl(pipefd[1],F_SETFL,flags|O_NONBLOCK);
    int channelCopy=fcntl(pair[1],F_DUPFD_CLOEXEC,20), statusCopy=fcntl(pipefd[1],F_DUPFD_CLOEXEC,20);
    if (setup<0 || channelCopy<0 || statusCopy<0) {
        int e=errno;for(int i=0;i<2;i++){close(pair[i]);close(pipefd[i]);}
        if(channelCopy>=0)close(channelCopy);if(statusCopy>=0)close(statusCopy);
        return @{@"setup_errno":@(e)};
    }
    StatusReader *reader=[StatusReader new];reader.fd=pipefd[0];
    dispatch_group_t group=dispatch_group_create();
    dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{[reader drain];}});
    pid_t pid=0;NSString *exe=NSBundle.mainBundle.executablePath;
    int error=spawnOwned(exe,@[@"--engine-spike"],channelCopy,statusCopy,-1,&pid);
    close(channelCopy);close(statusCopy);close(pair[1]);close(pipefd[1]);
    struct timeval timeout={180,0};setsockopt(pair[0],SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
    NSDictionary *reply=nil;NSString *nonce=NSUUID.UUID.UUIDString;
    if (!error && sendJSON(pair[0],@{@"nonce":nonce,@"targets":config[@"targets"]?:@[]})) reply=receiveJSON(pair[0]);
    if (!reply && !error) kill(pid,SIGTERM); // Exact unreaped direct child, not a forwarded PID.
    int st=-1;BOOL reaped=NO;
    if (!error) {
        pid_t got;do {got=waitpid(pid,&st,0);} while(got<0 && errno==EINTR);
        reaped=got==pid;
    }
    close(pair[0]);reader.engineReaped=YES;dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
    NSMutableArray *parent=[NSMutableArray array];
    for (NSDictionary *t in config[@"targets"]?:@[]) [parent addObject:readTarget(t)];
    BOOL bound=reply && [reply[@"nonce"] isEqual:nonce] && [reply[@"engine_pid"] intValue]==pid && [reply[@"parent_pid"] intValue]==getpid();
    NSDictionary *status=statusVerdict(reader);
    return @{@"scenario":config[@"scenario"]?:@"unspecified",@"parent_pid":@(getpid()),
        @"parent_bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"",@"engine_spawn_errno":@(error),
        @"engine_reaped":@(reaped),@"engine_wait_status":@(st),@"identity_bound":@(bound),
        @"engine":reply?:@{},@"parent_targets":parent,@"cleanup":status,
        @"elapsed_seconds":@(seconds()-began),@"platform":NSProcessInfo.processInfo.operatingSystemVersionString};
}
@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSDictionary *config;
@property(strong) NSWindow *window;
@property(strong) NSTextField *label;
@end
@implementation ProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,620,180) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Unison Engine Launch Spike";
    self.label=[NSTextField wrappingLabelWithString:@"Running isolated signed parent/engine/lifeline checks…"];
    self.label.frame=NSMakeRect(24,24,572,120);[self.window.contentView addSubview:self.label];
    [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSDictionary *result=runProbe(self.config);
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        NSString *output=self.config[@"output"];BOOL saved=[data writeToFile:output atomically:YES];
        dispatch_async(dispatch_get_main_queue(),^{
            self.label.stringValue=saved?@"Probe finished. Results saved; no file contents retained.":@"Could not save probe results.";
            if (![self.config[@"keep_open"] boolValue]) [NSApp terminate:nil];
        });
    }});
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {(void)sender;return YES;}
@end
int main(int argc,char **argv) {
    @autoreleasepool {
        signal(SIGPIPE,SIG_IGN);
        if (argc==2 && strcmp(argv[1],"--engine-spike")==0) return engineMain();
        if (argc!=3 || strcmp(argv[1],"--config")!=0) return 64;
        NSData *data=[NSData dataWithContentsOfFile:@(argv[2])];
        id config=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"output"] isKindOfClass:NSString.class]) return 65;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ProbeDelegate *delegate=[ProbeDelegate new];delegate.config=config;NSApp.delegate=delegate;[NSApp run];
    }
    return 0;
}
