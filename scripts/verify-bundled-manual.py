#!/usr/bin/env python3
"""Check bundled == committed HTML and its marker == the current source hash.

This does not re-render Markdown. Rendering fidelity is checked separately by
CI's site job (build-bundled-manual.py --check); release from a commit that passed
that check. A matching source-hash marker alone does not prove faithful rendering.
"""
import hashlib
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
try:
    app = pathlib.Path(sys.argv[1])
    expected = (root / 'Resources/UIManual.html').read_bytes()
    actual = (app / 'Contents/Resources/UIManual.html').read_bytes()
    marker = ('<!-- MANUAL.md sha256: ' + hashlib.sha256((root / 'MANUAL.md').read_bytes()).hexdigest() + ' -->').encode()
    if marker not in expected or actual != expected:
        raise ValueError('bundled manual differs from the current reviewed manual')
    print('PASS: exact bundled UI manual and source hash match')
except (IndexError, OSError, ValueError) as e:
    sys.exit(f'error: {e}')
