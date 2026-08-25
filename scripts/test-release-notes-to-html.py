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

# Single-asterisk emphasis (the v0.5.1 `*checking*` regression).
em = run("If automatic update *checking* is enabled, you are notified.\n")
check("emphasis", "<em>checking</em>" in em)
check("emphasis leaves no literal asterisk", "*checking*" not in em)
# Bold must stay bold, not be mistaken for emphasis of an asterisk-wrapped span.
mix = run("Both **strong words** and *soft words* render.\n")
check("bold not turned into em", "<strong>strong words</strong>" in mix
      and "*" not in mix)
check("emphasis alongside bold", "<em>soft words</em>" in mix)

lk = run("See [the page](https://example.com/x).\n")
check("link", '<a href="https://example.com/x">the page</a>' in lk)

# A query string's `&` must be escaped EXACTLY once (not `&amp;amp;`): links are
# parsed from the raw text so the URL isn't escaped a second time.
q = run("[query](https://example.com/?a=1&b=2)\n")
check("link query single-escaped",
      'href="https://example.com/?a=1&amp;b=2"' in q and "&amp;amp;" not in q)

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
