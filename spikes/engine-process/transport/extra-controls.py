import argparse,json,tempfile
from pathlib import Path
from run import Case
p=argparse.ArgumentParser();p.add_argument('--helper',type=Path,required=True);p.add_argument('--env-probe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='unison-setup-controls-',dir='/private/tmp') as tmp:
    root=Path(tmp);marker=root/'executed'
    for name,extra,terminal,expected in [
        ('fork-failure',{'LIFELINE_TEST_STAGE':'fork-failure'},False,70),
        ('missing-lifecycle',{'LIFELINE_LIFECYCLE_FD':'-1'},False,64),
        ('pty-setup-failure',{'LIFELINE_TEST_STAGE':'tty-setup'},True,70)]:
        c=Case(a.helper.resolve(),['/bin/sh','-c','touch "$1"','fixture',str(marker)],extra=extra,terminal=terminal).finish()
        assert c.rc==expected and not marker.exists()
        if expected==64:assert not c.event('S')
        else:assert c.verified()
        (a.output/(name+'.json')).write_text(json.dumps(c.record(name),indent=2)+'\n');print('PASS',name,flush=True)
    for terminal,expected in ((False,'default'),(True,'ignored')):
        extra={'LIFELINE_TEST_STAGE':'unused','LIFELINE_TEST_SMALL_BUFFER':'1','LIFELINE_TEST_ENUM_FILE':str(root/'absent')}
        c=Case(a.helper.resolve(),[str(a.env_probe.resolve())],terminal=terminal,extra=extra).finish()
        assert c.rc==0 and c.verified() and ('SIGPIPE='+expected+' HELPER_ENV=0').encode() in c.output
        name='sigpipe-'+expected+'-environment';(a.output/(name+'.json')).write_text(json.dumps(c.record(name),indent=2)+'\n');print('PASS',name,flush=True)
