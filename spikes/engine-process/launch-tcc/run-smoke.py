#!/usr/bin/env python3
"""LaunchServices smoke controls; uses only a fresh private temporary directory."""
import argparse,errno,json,os,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--runs',type=int,default=3);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
for run in range(1,a.runs+1):
    with tempfile.TemporaryDirectory(prefix='unison-signed-smoke-',dir='/private/tmp') as tmp:
        root=Path(tmp);root.chmod(0o700);(root/'directory').mkdir();(root/'directory/file').write_text('disposable fixture\n')
        targets=[{'label':'temporary-directory','path':str(root/'directory')},{'label':'temporary-file','path':str(root/'directory/file')},{'label':'missing-control','path':str(root/'absent')}]
        cfg={'scenario':'signed-unprotected-smoke','targets':targets,'output':str(root/'result.json'),'keep_open':False}
        (root/'config.json').write_text(json.dumps(cfg));os.chmod(root/'config.json',0o600)
        subprocess.run(['open','-n',str(a.app.resolve()),'--args','--config',str(root/'config.json')],check=True)
        for tick in range(150):
            if (root/'result.json').exists():break
            time.sleep(.1)
        else:raise RuntimeError('Probe did not produce a result; leave ownership cleanup to investigation, not name-based kills.')
        data=json.loads((root/'result.json').read_text())
        assert data['engine_spawn_errno']==0 and data['engine_reaped'] and data['engine_wait_status']==0
        assert data['identity_bound'] and data['engine']['helper_transport_ready'] and data['engine']['helper_reaped']
        assert data['cleanup']['verified'],data['cleanup']
        for results in (data['parent_targets'],data['engine']['targets']):
            by={x['label']:x for x in results}
            assert by['temporary-directory']['read_ok'] and by['temporary-file']['read_ok']
            assert not by['missing-control']['open_ok'] and by['missing-control']['open_errno']==errno.ENOENT
        # Keep the bundle-relative role path, not the author's workspace directory.
        data['engine']['executable']=str(Path(*Path(data['engine']['executable']).parts[-4:]))
        (a.output/f'smoke-{run}.json').write_text(json.dumps(data,indent=2)+'\n')
        print(f'PASS {run}: engine reaped, nonce matched, file controls matched, S/D+EOF verified, {data["elapsed_seconds"]:.3f} s',flush=True)
        time.sleep(.25)
