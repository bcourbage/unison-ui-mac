#!/usr/bin/env python3
"""Reject LLVM/gcov coverage in every Mach-O of a finished app (all slices).

Inspect load commands as well as symbols: stripping symbols must not defeat the
check. Missing executables, malformed Mach-O, and tool failures fail closed.
"""
import pathlib
import plistlib
import re
import subprocess
import sys

MAGICS = {bytes.fromhex(x) for x in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def inspect(app):
    app = pathlib.Path(app)
    with (app / 'Contents/Info.plist').open('rb') as f:
        name = plistlib.load(f)['CFBundleExecutable']
    if not isinstance(name, str) or pathlib.Path(name).name != name:
        raise ValueError('invalid CFBundleExecutable')
    required = {app / 'Contents/MacOS' / name, app / 'Contents/MacOS/cltool'}
    for path in required:
        if not path.is_file():
            raise ValueError(f'missing executable: {path}')
    seen = set()
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as f:
            magic = f.read(4)
        if magic not in MAGICS:
            continue
        seen.add(path)
        loads = subprocess.run(['/usr/bin/otool', '-l', str(path)],
                               check=True, capture_output=True, text=True).stdout
        if not re.search(r'^\s*cmd LC_', loads, re.M):
            raise ValueError(f'no load commands: {path}')
        symbols = subprocess.run(['/usr/bin/nm', '-a', str(path)],
                                 check=True, capture_output=True, text=True).stdout
        if re.search(r'__LLVM_(?:COV|PRF)|__llvm_(?:prf|cov)|__llvm_profile|__profc_|__profd_|__gcov', loads + symbols):
            raise ValueError(f'coverage instrumentation: {path}')
    if not required <= seen:
        raise ValueError('main executable or cltool is not a regular Mach-O')
    print(f'PASS: no coverage instrumentation in {len(seen)} Mach-O files: {app}')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: verify-no-coverage.py app')
        inspect(sys.argv[1])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, plistlib.InvalidFileException) as e:
        sys.exit(f'error: {e}')
