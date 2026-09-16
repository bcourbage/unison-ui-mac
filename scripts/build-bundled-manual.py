#!/usr/bin/env python3
"""Render the offline UI manual. Uses requirements-site.txt's pinned Markdown.

The generated resource is committed so ordinary app builds need no Python packages.
CI --check rejects a resource that differs from current MANUAL.md rendering.
"""
import hashlib
import pathlib
import re
import sys
import markdown

ROOT = pathlib.Path(__file__).resolve().parent.parent
source = (ROOT / 'MANUAL.md').read_text()
body = markdown.markdown(source, extensions=['tables', 'fenced_code', 'toc', 'sane_lists', 'attr_list'])
# Repository-relative links should still work from a file:// page. Fragments stay
# local to this version of the manual; external references require a connection.
body = re.sub(r'href="(?!#|https?://|mailto:)([^" :]+)"',
              r'href="https://github.com/bcourbage/unison-ui-mac/blob/main/\1"', body)
output = '''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Unison UI for macOS — User Manual</title>
<style>html{color-scheme:light dark}body{font:16px/1.55 system-ui,sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem}pre{overflow:auto;padding:1rem;background:#8882}table{border-collapse:collapse}td,th{border:1px solid #8886;padding:.5rem}img{max-width:100%}a{color:light-dark(#065aba,#78baff)}</style>
</head><body>
''' + '<!-- MANUAL.md sha256: ' + hashlib.sha256(source.encode()).hexdigest() + ' -->\n' + body + '\n</body></html>\n'
path = ROOT / 'Resources/UIManual.html'
if sys.argv[1:] == ['--check']:
    if not path.exists() or path.read_text() != output:
        sys.exit('Bundled manual is stale: run scripts/build-bundled-manual.py with requirements-site.txt installed')
    print('PASS: bundled manual matches MANUAL.md')
elif not sys.argv[1:]:
    path.write_text(output)
else:
    sys.exit('usage: build-bundled-manual.py [--check]')
