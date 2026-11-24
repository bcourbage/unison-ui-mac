"""Read only: retain fixed error text/timestamps/counters, not personal paths or raw logs."""
from collections import deque
from pathlib import Path
import hashlib,json,re,subprocess
out=Path(__file__).resolve().parent
log=Path.home()/'Library/Application Support/Unison/Unison-Sync.log'
results=[];current=None;digest=hashlib.sha256()
with log.open('rb') as f:
    for n,raw in enumerate(f,1):
        digest.update(raw);line=raw.decode(errors='replace')
        if line.startswith('Unison ') and 'started propagating changes' in line:
            if current: results.append(current);current=None
            if ('09:41:' in line and '19 Nov 2026' in line) or ('14:24:' in line and '22 Nov 2026' in line):
                current={'header_line':n,'header':line.strip(),'events':[],'copy_starts':0,'copy_ends':0}
        if current:
            if line.startswith('[BGN]'):current['copy_starts']+=1
            if line.startswith('[END]'):current['copy_ends']+=1
            if 'Lost connection' in line:
                current['events'].append({'line':n,'kind':'failed_item' if line.startswith('Failed [') else 'connection_error','message':'Lost connection with the server'})
            elif line.startswith('Unison ') and 'finished propagating changes' in line:
                current['events'].append({'line':n,'kind':'finish','message':line.strip()})
if current:results.append(current)
(out/'incident-windows.json').write_text(json.dumps({'source':'~/Library/Application Support/Unison/Unison-Sync.log','source_bytes':log.stat().st_size,'source_sha256':digest.hexdigest(),'privacy':'Only selected headers, counters and fixed error text. Paths excluded; log not copied.','windows':results},indent=2)+'\n')
expr=re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ([+-]\d{4}) (Sleep|Wake|DarkWake)\s{2,}(.*)')
proc=subprocess.Popen(['pmset','-g','log'],stdout=subprocess.PIPE,text=True,errors='replace')
events=[]
for line in proc.stdout:
    m=expr.match(line)
    if m:events.append({'timestamp':m[1],'offset':m[2],'event':m[3],'detail':m[4].strip()[:200]})
rc=proc.wait()
if rc:raise RuntimeError('pmset failed with status '+str(rc))
events.sort(key=lambda e:e['timestamp'])
windows=[]
for target in ('2026-11-19 09:41:51','2026-11-22 14:24:28'):
    before=[e for e in events if e['timestamp']<=target]
    after=[e for e in events if e['timestamp']>target]
    windows.append({'sync_start':target,'last_six_prior_events':before[-6:],'first_two_following_events':after[:2]})
(out/'sleep-wake-windows.json').write_text(json.dumps({'command':'pmset -g log','selection':'Exact Sleep/Wake/DarkWake event type; nearest six preceding and two following records, including previous days. Process lists and assertions excluded.','windows':windows},indent=2)+'\n')
print('Saved path-free evidence for',len(results),'sync windows and',len(windows),'power windows.')
