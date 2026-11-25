#!/usr/bin/env python3
"""Owned-process transport experiments. Does not call the product app or alter TCC."""
import argparse,errno,json,os,pty,re,select,shlex,signal,subprocess,sys,tempfile,threading,time
from pathlib import Path
from ssh_fixture import SSHFixture
ACTIVE=[]

class Case:
    def __init__(self,helper,argv,*,terminal=False,extra=None,close_status=False,close_life_exit=False,full_status=False,proxy=False,ignore_chld=False):
        self.started=time.monotonic();self.records=[];self.partial={};self.output=b'';self.chunks=[];self.defer_delivery=False;self.rc=None;self.lock=threading.Lock();self.terminal=terminal;self.proxy=proxy
        self.sr,sw=os.pipe();self.lr,lw=os.pipe();os.set_blocking(sw,False);os.set_blocking(lw,False)
        self.deferred_status=full_status
        if full_status:
            try:
                while True:os.write(sw,b'x'*4096)
            except BlockingIOError:pass
        env=dict(os.environ,LIFELINE_PARENT=str(os.getpid()),LIFELINE_STATUS_FD=str(sw),LIFELINE_LIFECYCLE_FD=str(lw),LIFELINE_TEST_GRACE_MS='300')
        env.update(extra or {})
        args=[str(helper),*argv]
        old_chld=signal.signal(signal.SIGCHLD,signal.SIG_IGN) if ignore_chld else None
        try:
            if terminal:
                os.set_inheritable(sw,True);os.set_inheritable(lw,True)
                self.pid,self.io=pty.fork()
                if self.pid==0:os.execve(str(helper),args,env)
                self.proc=None
            elif proxy:
                rd,wr=os.pipe();self.pid=os.fork()
                if self.pid==0:
                    os.close(rd);env['LIFELINE_PARENT']=str(os.getpid())
                    child=subprocess.Popen(args,env=env,pass_fds=(sw,lw),stdout=wr,stderr=wr)
                    os.close(sw);os.close(lw);os.close(wr);child.wait();os._exit(0)
                os.close(wr);self.io=rd;self.proc=None
            else:
                self.proc=subprocess.Popen(args,env=env,pass_fds=(sw,lw),stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
                self.pid=self.proc.pid;self.io=self.proc.stdout.fileno()
        finally:
            if ignore_chld:signal.signal(signal.SIGCHLD,old_chld)
        os.close(sw);os.close(lw);os.set_blocking(self.io,False)
        ACTIVE.append(self)
        self.threads=[]
        if not full_status:self.reader(self.sr,'status',close_status=close_status)
        self.reader(self.lr,'lifecycle',close_life_exit=close_life_exit)
    def reader(self,fd,channel,**controls):
        def collect():
            buf=b''
            try:
                while True:
                    data=os.read(fd,4096)
                    if not data:break
                    buf+=data
                    while b'\n' in buf:
                        raw,buf=buf.split(b'\n',1);line=raw.decode(errors='replace')
                        with self.lock:self.records.append({'channel':channel,'time':round(time.monotonic()-self.started,6),'line':line})
                        if controls.get('close_status') and line.startswith('S '):return
                        if controls.get('close_life_exit') and line.startswith('TransportExited '):return
            finally:
                self.partial[channel]=len(buf);os.close(fd)
        t=threading.Thread(target=collect,daemon=True);t.start();self.threads.append(t)
    def drain(self):
        try:
            while True:
                data=os.read(self.io,4096)
                if not data:break
                stamp=round(time.monotonic()-self.started,6)
                self.chunks.append({'time':stamp,'delivery_time':None if self.defer_delivery else stamp,'bytes':len(data)})
                self.output+=data
                if len(self.output)>65536:raise AssertionError('probe output cap')
        except OSError as e:
            if e.errno not in (errno.EAGAIN,errno.EIO):raise
    def poll(self):
        self.drain()
        if self.rc is not None:return self.rc
        if self.proc is not None:self.rc=self.proc.poll()
        else:
            got,st=os.waitpid(self.pid,os.WNOHANG)
            if got:self.rc=os.waitstatus_to_exitcode(st)
        return self.rc
    def send(self,sig):
        if self.poll() is None:os.kill(self.pid,sig) # Still the direct, unreaped owned process.
    def event(self,kind):
        with self.lock:return [e for e in self.records if e['line'].split()[0]==kind]
    def until(self,predicate,seconds=8):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            self.drain()
            if predicate():return
            time.sleep(.005)
        raise AssertionError('timed out waiting for probe event')
    def finish(self,seconds=10):
        end=time.monotonic()+seconds
        while self.poll() is None and time.monotonic()<end:time.sleep(.01)
        if self.rc is None:self.send(signal.SIGTERM);raise AssertionError('helper did not finish')
        if self.deferred_status:self.reader(self.sr,'status');self.deferred_status=False
        for t in self.threads:t.join(timeout=5);assert not t.is_alive(),'writer did not close'
        self.drain()
        if self.proc is not None:self.proc.stdout.close()
        else:os.close(self.io)
        if self in ACTIVE:ACTIVE.remove(self)
        return self
    def verified(self):
        s=self.event('S');d=self.event('D')
        return len(s)==len(d)==1 and s[0]['line'].split()[1]==d[0]['line'].split()[1] and not self.partial.get('status')
    def record(self,name,clean=lambda s:s):
        return {'case':name,'returncode':self.rc,'elapsed':round(time.monotonic()-self.started,4),'cleanup_verified':self.verified(),'records':self.records,'partial_bytes':self.partial,'terminal_chunks':self.chunks,'output':clean(self.output.decode(errors='replace'))}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--helper',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--skip-ssh',action='store_true');ap.add_argument('--only-ssh',action='store_true');ap.add_argument('--login-grace-only',action='store_true');ap.add_argument('--defer-terminal',action='store_true');a=ap.parse_args();a.output.mkdir(parents=True,exist_ok=True);h=a.helper.resolve();results=[]
    if a.login_grace_only:a.only_ssh=True
    def save(name,c,clean=lambda s:s):
        data=c.record(name,clean);results.append(data);(a.output/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n');print('PASS',name,f'{data["elapsed"]:.3f}s',flush=True)
    if not a.only_ssh:
        c=Case(h,['/bin/sh','-c','exit 7']).finish();assert c.rc==7 and c.verified();save('ordinary-exit',c)
        c=Case(h,['/nonexistent/unison-transport']).finish();assert c.rc==127 and c.verified();save('exec-failure',c)
        for stage in ('before-watch','before-start','before-fork','child-setup','release-eof','after-release'):
            with tempfile.TemporaryDirectory(prefix='unison-no-exec-',dir='/private/tmp') as tmp:
                marker=Path(tmp)/'executed'
                c=Case(h,['/bin/sh','-c','touch "$1"','probe',str(marker)],extra={'LIFELINE_TEST_STAGE':stage,'LIFELINE_TEST_GRACE_MS':'1000'}).finish()
                assert not marker.exists(),stage
                if stage in ('before-watch','before-start'):assert c.rc==143 and not c.event('S')
                elif stage=='before-fork':assert c.rc==143 and c.verified() and not c.event('TransportStarted')
                elif stage=='after-release':assert c.rc==-15 and c.verified()
                else:assert c.rc==70 and c.verified()
                save('startup-'+stage,c)
        stubborn='(trap "" TERM; exec /bin/sleep 8) & /bin/sleep 0.1; exit 7'
        c=Case(h,['/bin/sh','-c',stubborn]).finish();assert c.rc==7 and c.verified()
        assert c.event('CleanupComplete')[0]['time']-c.event('TransportExited')[0]['time']>.2;save('exit-before-cleanup',c)
        c=Case(h,['/bin/sh','-c','/bin/sleep 0.1; exit 7'],close_status=True).finish();assert c.rc==7 and not c.verified();save('closed-status-reader',c)
        c=Case(h,['/bin/sh','-c',stubborn],close_life_exit=True).finish();assert c.rc==7 and c.verified() and not c.event('CleanupComplete');save('closed-lifecycle-reader',c)
        c=Case(h,['/bin/sh','-c','exit 0'],full_status=True).finish();assert c.rc==71 and not c.event('S') and not c.event('TransportStarted');save('full-start-pipe',c)
        with tempfile.TemporaryDirectory(prefix='unison-enum-fault-',dir='/private/tmp') as tmp:
            f=Path(tmp)/'unknown';f.touch()
            c=Case(h,['/bin/sh','-c','exit 7'],extra={'LIFELINE_TEST_ENUM_FILE':str(f)})
            c.until(lambda:bool(c.event('U')));assert not c.event('D') and not c.event('CleanupComplete');f.unlink();c.finish();assert c.rc==7 and c.verified();save('unknown-membership-blocks',c)
        c=Case(h,['/bin/sh','-c','for i in 1 2 3 4 5 6 7 8; do (trap "" TERM; exec /bin/sleep 8) & done; /bin/sleep 0.2; exit 7'],extra={'LIFELINE_TEST_SMALL_BUFFER':'1'}).finish();assert c.rc==7 and c.verified();save('growing-membership-buffer',c)
        c=Case(h,['/bin/sh','-c','/bin/sleep 0.2; exit 7'],ignore_chld=True).finish();assert c.rc==7 and c.verified();save('inherited-sigchld-ignore',c)
        c=Case(h,['/bin/sleep','8'],proxy=True);c.until(lambda:bool(c.event('TransportStarted')));c.send(signal.SIGKILL);c.finish();assert c.rc==-9 and c.verified();save('simulated-engine-death',c)
        c=Case(h,['/bin/sh','-c','printf "PTY "; ps -o pgid=,tpgid= -p $$'],terminal=True).finish();assert c.rc==0 and c.verified()
        nums=re.search(rb'PTY\s+(\d+)\s+(\d+)',c.output);assert nums and nums[1]==nums[2];save('pty-foreground',c)
    if not a.skip_ssh:
        if not a.login_grace_only:
            with SSHFixture() as server:
                c=Case(h,server.argv()).finish();assert c.rc==0 and b'authenticated-spike' in c.output and c.verified();save('ssh-key-auth-nonpty',c,server.clean)
                for scenario in ('correct-passphrase','wrong-then-correct','cancel-prompt'):
                    c=Case(h,server.argv(encrypted=True),terminal=True)
                    prompt=rb'(?:Enter|Bad) passphrase[^\r\n]*:'
                    c.until(lambda:len(re.findall(prompt,c.output))>=1)
                    if scenario=='cancel-prompt':c.send(signal.SIGTERM)
                    else:
                        if scenario=='wrong-then-correct':
                            os.write(c.io,b'incorrect-fixture-passphrase\n');c.until(lambda:len(re.findall(prompt,c.output))>=2)
                        os.write(c.io,(server.passphrase+'\n').encode())
                    c.finish()
                    assert c.verified()
                    if scenario=='cancel-prompt':assert c.rc==-15
                    else:assert c.rc==0 and b'authenticated-spike' in c.output
                    clean=lambda s:server.clean(s).replace(server.passphrase,'<fixture-secret>').replace('incorrect-fixture-passphrase','<incorrect-fixture-secret>')
                    save('ssh-pty-'+scenario,c,clean)
        with SSHFixture(grace=1) as server:
            wrapper='(trap "" TERM; exec /bin/sleep 20) & exec '+shlex.join(server.argv(encrypted=True))
            c=Case(h,['/bin/sh','-c',wrapper],terminal=True);c.until(lambda:b'Enter passphrase' in c.output);time.sleep(6);os.write(c.io,(server.passphrase+'\n').encode())
            if a.defer_terminal:
                c.defer_delivery=True;c.until(lambda:bool(c.event('TransportExited')));c.defer_delivery=False
                delivered=round(time.monotonic()-c.started,6)
                for chunk in c.chunks:
                    if chunk['delivery_time'] is None:chunk['delivery_time']=delivered
            c.finish()
            attempt=c.record('ssh-login-grace-lingering-descendant',lambda text:server.clean(text).replace(server.passphrase,'<fixture-secret>'))
            (a.output/'login-grace-observed.json').write_text(json.dumps(attempt,indent=2)+'\n')
            print('Login-grace observed:',c.rc,'cleanup:',c.verified(),'output:',attempt['output'],flush=True)
            assert c.rc==255 and c.verified();assert c.event('CleanupComplete')[0]['time']-c.event('TransportExited')[0]['time']>.2
            save('ssh-login-grace-lingering-descendant',c,lambda s:server.clean(s).replace(server.passphrase,'<fixture-secret>'))
    (a.output/'summary.json').write_text(json.dumps({'passed':len(results),'helper':h.name,'grace_ms':300,'scope':'Signed helper under an owned harness; not the AppKit/OCaml prompt reader.'},indent=2)+'\n')
    print('Completed',len(results),'cases.',flush=True)
if __name__=='__main__':
    try:main()
    finally:
        for case in list(ACTIVE):
            try:case.defer_delivery=False;case.send(signal.SIGTERM);case.finish(seconds=7)
            except Exception as error:print('Owned-case cleanup incomplete:',type(error).__name__,flush=True)
