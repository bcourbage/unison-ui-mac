"""Loopback-only disposable sshd. No system sshd/config or account password changes."""
from pathlib import Path
import getpass,os,socket,subprocess,tempfile,time,shutil
class SSHFixture:
    def __init__(self,grace=20):self.grace=grace;self.passphrase='spike-fixture-passphrase'
    def __enter__(self):
        self.root=Path(tempfile.mkdtemp(prefix='unison-ssh-owned-',dir='/private/tmp'));self.root.chmod(0o700)
        try:
            for name,phrase in [('host',''),('plain',''),('encrypted',self.passphrase)]:
                subprocess.run(['ssh-keygen','-q','-t','ed25519','-N',phrase,'-f',str(self.root/name)],check=True)
            self.user=getpass.getuser()
            (self.root/'authorized_keys').write_bytes((self.root/'plain.pub').read_bytes()+(self.root/'encrypted.pub').read_bytes())
            (self.root/'authorized_keys').chmod(0o600)
            with socket.socket() as s:s.bind(('127.0.0.1',0));self.port=s.getsockname()[1]
            host=(self.root/'host.pub').read_text().split()
            (self.root/'known_hosts').write_text(f'[127.0.0.1]:{self.port} {host[0]} {host[1]}\n')
            # StrictModes is relaxed only for this isolated high-port server's /tmp key path.
            config=f'''Port {self.port}
ListenAddress 127.0.0.1
HostKey {self.root}/host
PidFile {self.root}/sshd.pid
AuthorizedKeysFile {self.root}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
UsePAM no
PermitRootLogin no
AllowUsers {self.user}
LoginGraceTime {self.grace}
ForceCommand /usr/bin/printf authenticated-spike
LogLevel ERROR
'''
            (self.root/'sshd_config').write_text(config)
            subprocess.run(['/usr/sbin/sshd','-t','-f',str(self.root/'sshd_config')],check=True,capture_output=True)
            self.log=(self.root/'server.log').open('w+')
            self.server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(self.root/'sshd_config')],stdout=self.log,stderr=self.log)
            for _ in range(100):
                if self.server.poll() is not None:
                    self.log.seek(0);raise RuntimeError(self.clean(self.log.read()))
                try:
                    with socket.create_connection(('127.0.0.1',self.port),timeout=.1):pass
                    return self
                except OSError:time.sleep(.03)
            raise TimeoutError('Loopback sshd did not become ready')
        except BaseException:self.__exit__(None,None,None);raise
    def argv(self,encrypted=False):
        return ['/usr/bin/ssh','-F','/dev/null','-p',str(self.port),'-l',self.user,'-o','IdentityAgent=none','-o','IdentitiesOnly=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','ConnectionAttempts=1','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=yes','-o','GlobalKnownHostsFile=/dev/null','-o','UserKnownHostsFile='+str(self.root/'known_hosts'),'-i',str(self.root/('encrypted' if encrypted else 'plain')),'127.0.0.1','fixture-command']
    def clean(self,text):return text.replace(str(self.root),'<ssh-fixture>').replace(self.user,'<fixture-user>')
    def __exit__(self,*_):
        if hasattr(self,'server') and self.server.poll() is None:
            self.server.terminate()
            try:self.server.wait(timeout=3)
            except subprocess.TimeoutExpired:self.server.kill();self.server.wait()
        if hasattr(self,'log'):self.log.close()
        if hasattr(self,'root'):shutil.rmtree(self.root)
if __name__=='__main__':
    with SSHFixture() as f:
        r=subprocess.run(f.argv(),capture_output=True,text=True,timeout=8)
        print('Fixture authentication exit:',r.returncode,'marker:',r.stdout=='authenticated-spike')
        if r.returncode:print(f.clean(r.stderr))
        assert r.returncode==0 and r.stdout=='authenticated-spike'
