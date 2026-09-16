#!/usr/bin/env python3
"""Real compiler fixtures, including stripped and nested instrumented binaries."""
import pathlib
import plistlib
import subprocess
import tempfile

CHECK = pathlib.Path(__file__).with_name('verify-no-coverage.py')
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    app = root / 'Fixture.app'
    mac = app / 'Contents/MacOS'
    mac.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'main'}))
    src = root / 'main.c'
    src.write_text('int main(int argc, char **argv) { return argc > 10; }\n')
    def build(path, coverage=False):
        subprocess.run(['xcrun', 'clang', str(src), '-o', str(path)] +
                       (['-fprofile-instr-generate', '-fcoverage-mapping'] if coverage else []), check=True)
    def check(ok, label):
        r = subprocess.run(['python3', str(CHECK), str(app)], capture_output=True, text=True)
        assert (r.returncode == 0) == ok, (label, r.stdout, r.stderr)
        print('PASS:', label)
    build(mac / 'main'); build(mac / 'cltool')
    check(True, 'clean bundle')
    build(mac / 'main', True)
    check(False, 'instrumented main')
    subprocess.run(['/usr/bin/strip', str(mac / 'main')], check=True)
    check(False, 'stripped instrumented main')
    build(mac / 'main')
    build(mac / 'cltool', True)
    check(False, 'instrumented launcher')
    build(mac / 'cltool')
    helper = app / 'Contents/Frameworks/helper'
    helper.parent.mkdir(); build(helper, True)
    check(False, 'instrumented nested helper')
    helper.unlink(); (mac / 'cltool').unlink()
    check(False, 'missing launcher')
    (mac / 'cltool').write_bytes(bytes.fromhex('cffaedfe') + b'broken')
    check(False, 'malformed Mach-O')
