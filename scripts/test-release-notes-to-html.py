#!/usr/bin/env python3
"""Deterministic tests for release-notes-to-html.py (no network / no Sparkle).

Runs the converter as a subprocess on small inputs and asserts the emitted
fragment. Locks the house-style subset and the fragment invariant Sparkle
depends on.
"""
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CONVERTER = HERE / "release-notes-to-html.py"

failures = 0


def run(md: str) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(md)
        path = f.name
    out = subprocess.run(
        [sys.executable, str(CONVERTER), path],
        capture_output=True, text=True, check=True,
    )
    return out.stdout


def check(desc: str, cond: bool) -> None:
    global failures
    status = "PASS" if cond else "FAIL"
    if not cond:
        failures += 1
    print(f"  {desc:38s} {status}")


print("release-notes-to-html.py:")

h = run("# Title\n\n## Section\n")
check("h1", "<h1>Title</h1>" in h)
check("h2", "<h2>Section</h2>" in h)

b = run("Some **bold** and `code` here.\n")
check("bold", "<strong>bold</strong>" in b)
check("inline code", "<code>code</code>" in b)
check("paragraph wrap", b.strip().startswith("<p>") and b.strip().endswith("</p>"))

lk = run("See [the page](https://example.com/x).\n")
check("link", '<a href="https://example.com/x">the page</a>' in lk)

esc = run("A < B & C > D, not <body> or <!DOCTYPE html>.\n")
check("escapes angle brackets", "&lt;" in esc and "&gt;" in esc)
check("escapes ampersand", "&amp;" in esc)
check("literal <body> in text is escaped, still a fragment",
      "<body>" not in esc.lower() and "<!doctype" not in esc.lower())

lst = run("- first item\n  continued line\n- second item\n")
check("list items", lst.count("<li>") == 2 and "<ul>" in lst and "</ul>" in lst)
check("continuation joined", "first item continued line" in lst)

# A bullet immediately followed by a heading must close the list cleanly.
mix = run("- only bullet\n## After\n")
check("list closes before heading",
      "<ul>" in mix and "</ul>" in mix and "<h2>After</h2>" in mix)

if failures:
    print(f"RELEASE-NOTES-TO-HTML TESTS FAILED ({failures})", file=sys.stderr)
    sys.exit(1)
print("all release-notes-to-html tests passed")
