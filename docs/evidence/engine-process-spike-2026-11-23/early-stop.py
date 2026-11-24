"""Deterministic signal-registration injection; only direct test children are signaled."""
import json, os, pathlib, signal, subprocess, time
base=pathlib.Path(__file__).resolve().parent
results=[]
for name in ('lifeline-early-stop','lifeline-blocked-stop'):
    sr,sw=os.pipe()
    os.set_blocking(sw,False)
    env=dict(os.environ,LIFELINE_PARENT=str(os.getpid()),LIFELINE_STATUS_FD=str(sw),SPIKE_STOP_BEFORE_FILTER='1')
    start=time.monotonic()
    p=subprocess.Popen([str(base/name),'/bin/sleep','2'],pass_fds=(sw,),env=env)
    os.close(sw)
    try:
        rc=p.wait(timeout=6)
    except subprocess.TimeoutExpired:
        p.send_signal(signal.SIGTERM)
        rc=p.wait(timeout=6)
        raise AssertionError('timed out: '+name)
    records=os.read(sr,4096).decode();os.close(sr)
    results.append(dict(variant=name,returncode=rc,seconds=round(time.monotonic()-start,3),records=records.splitlines()))
print(json.dumps(results,indent=2))
assert results[0]['returncode']==0, 'prototype must demonstrate the lost stop'
assert results[1]['returncode']==128+signal.SIGTERM, 'durable state must retain the early stop'
assert results[1]['records']==[], 'no transport may start on a retained startup stop'
