#!/usr/bin/env python3
"""Build a separate Developer ID/hardened probe; never invokes the product release pipeline."""
import argparse,hashlib,json,plistlib,subprocess
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,required=True)
p.add_argument('--identity',required=True)
p.add_argument('--bundle-id',default='net.courbage.unison-ui-mac.engine-launch-spike')
a=p.parse_args()
if a.identity=='-' or not a.bundle_id.startswith('net.courbage.unison-ui-mac.engine-launch-spike'):
    raise SystemExit('Use a Developer ID identity and a separate spike bundle identifier.')
root=Path(__file__).resolve().parent
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
app=out/'Unison Engine Launch Spike.app'
if app.exists():raise SystemExit('Output bundle already exists; choose a new artifact directory.')
mac=app/'Contents/MacOS';mac.mkdir(parents=True)
info={'CFBundleIdentifier':a.bundle_id,'CFBundleName':'Unison Engine Launch Spike','CFBundleDisplayName':'Unison Engine Launch Spike','CFBundleExecutable':'EngineLaunchProbe','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,'NSDocumentsFolderUsageDescription':'This isolated spike reads a disposable test directory to compare parent and child access.','NSPhotoLibraryUsageDescription':'This isolated spike checks read access to a selected Photos library directory without changing it.'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
commands=[]
def portable_output(text):
    # Persist bundle-relative tool output, including codesign --verify diagnostics.
    return text.replace(str(out) + '/', '')
def run(args):
    commands.append(args)
    x=subprocess.run(args,text=True,capture_output=True)
    if x.returncode:raise SystemExit(portable_output(x.stdout+x.stderr))
    return portable_output(x.stdout+x.stderr)
run(['xcrun','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-O2','-std=gnu11','-mmacosx-version-min=15.0',str(root/'LaunchProbe.m'),'-framework','Cocoa','-o',str(mac/'EngineLaunchProbe')])
run(['xcrun','clang','-Wall','-Wextra','-Werror','-O2','-mmacosx-version-min=15.0',str(root/'lifeline.c'),'-o',str(mac/'lifeline')])
for target in (mac/'lifeline',app):
    run(['codesign','--force','--options','runtime','--timestamp','--sign',a.identity,str(target)])
verify=run(['codesign','--verify','--deep','--strict','--verbose=2',str(app)])
details={}
for target in (mac/'EngineLaunchProbe',mac/'lifeline'):
    details[target.name]={'signature':run(['codesign','--display','--verbose=4',str(target)]),'build':run(['xcrun','vtool','-show-build',str(target)]),'entitlements':run(['codesign','--display','--entitlements',':-',str(target)]),'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
report={'bundle_id':a.bundle_id,'source_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in (root/'LaunchProbe.m',root/'lifeline.c',root/'build.py')},'codesign_verify':verify,'components':details,'qualification':'Developer ID + hardened runtime, local build. Not notarized, not installed product, no OCaml/SSH authentication/TCC qualification yet.'}
(out/'build-inspection.json').write_text(json.dumps(report,indent=2)+'\n')
print(app)
