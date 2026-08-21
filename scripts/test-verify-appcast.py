#!/usr/bin/env python3
"""Tests for verify-appcast.py against the REAL pinned sign_update.

Requires SPARKLE_BIN (the checksum-pinned Sparkle tools bin/). Uses a THROWAWAY
Ed25519 key — never the project key — to build a signed feed + archive, then
asserts verify-appcast.py passes on valid input and fails closed on: a tampered
archive, a poisoned (re-content) feed, the wrong key, an absent archive, a
non-exact (dot-segment) URL, and a duplicated enclosure URL. Locks the exact
attack classes the review found (foreign-prefixed / duplicate enclosures and
URL-canonicalization tricks).
"""
import base64
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
VERIFIER = HERE / "verify-appcast.py"
PREFIX = "https://github.com/bcourbage/unison-ui-mac/releases/download/v9.9.9/"
NAME = "unison-ui-mac-9.9.9.app.zip"
URL = PREFIX + NAME

SPARKLE_BIN = os.environ.get("SPARKLE_BIN")
if not SPARKLE_BIN or not os.access(f"{SPARKLE_BIN}/sign_update", os.X_OK):
    sys.stderr.write("error: set SPARKLE_BIN to the Sparkle tools bin/ to run this test\n")
    sys.exit(1)
SIGN_UPDATE = f"{SPARKLE_BIN}/sign_update"

failures = 0


def check(desc, cond):
    global failures
    if not cond:
        failures += 1
    print(f"  {desc:46s} {'PASS' if cond else 'FAIL'}")


def run(appcast, key_b64, *flags):
    return subprocess.run(
        [sys.executable, str(VERIFIER), str(appcast), *flags],
        input=key_b64, capture_output=True, text=True,
        env={**os.environ, "SPARKLE_BIN": SPARKLE_BIN},
    )


def build(d, *, tamper_archive=False, poison_feed=False, duplicate=False,
          foreign_new=False):
    d = pathlib.Path(d)
    key_b64 = base64.b64encode(os.urandom(32)).decode()
    keyfile = d / "key.txt"
    keyfile.write_text(key_b64)
    archive = d / NAME
    archive.write_bytes(b"payload-" + os.urandom(64))
    sig = subprocess.run(
        [SIGN_UPDATE, "-p", "--ed-key-file", str(keyfile), str(archive)],
        capture_output=True, text=True,
    ).stdout.strip()
    size = archive.stat().st_size
    if foreign_new:
        # The new archive appears ONLY as a foreign-prefixed <evil:enclosure> at
        # the expected URL (Sparkle ignores it), alongside an unrelated real
        # <enclosure> so a structural gate would still pass. The crypto gate must
        # NOT accept the foreign node.
        new_enc = (f'<evil:enclosure xmlns:evil="http://evil.example/ns" url="{URL}" '
                   f'length="{size}" type="application/octet-stream" sparkle:edSignature="{sig}"/>')
        old_enc = (f'<enclosure url="{PREFIX}old.zip" length="1" '
                   f'type="application/octet-stream" sparkle:edSignature="{sig}"/>')
    else:
        new_enc = (f'<enclosure url="{URL}" length="{size}" '
                   f'type="application/octet-stream" sparkle:edSignature="{sig}"/>')
        old_enc = ""
    dup = (f'<enclosure url="{URL}" length="1" type="application/octet-stream" '
           f'sparkle:edSignature="{sig}"/>') if duplicate else ""
    feed = d / "appcast.xml"
    feed.write_text(
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        '<channel>\n<item>\n<sparkle:version>19</sparkle:version>\n'
        f'{old_enc}{new_enc}\n{dup}'
        '</item>\n</channel>\n</rss>\n'
    )
    subprocess.run([SIGN_UPDATE, "--ed-key-file", str(keyfile), str(feed)],
                   capture_output=True, text=True, check=True)
    if poison_feed:
        feed.write_text(feed.read_text().replace(
            "</channel>",
            f'<item><enclosure url="{PREFIX}evil.zip" length="1" '
            f'type="application/octet-stream" sparkle:edSignature="{sig}"/></item></channel>'))
    if tamper_archive:
        with open(archive, "ab") as fh:
            fh.write(b"tampered")
    return feed, str(archive), key_b64


print("verify-appcast.py (via real sign_update):")

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d)
    check("valid feed + new archive", run(feed, key, "--archive", arc, "--expected-url", URL).returncode == 0)
    check("valid --feed-only", run(feed, key, "--feed-only").returncode == 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d, tamper_archive=True)
    check("tampered archive rejected", run(feed, key, "--archive", arc, "--expected-url", URL).returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d, poison_feed=True)
    check("poisoned feed rejected", run(feed, key, "--archive", arc, "--expected-url", URL).returncode != 0)
    check("poisoned feed rejected (--feed-only)", run(feed, key, "--feed-only").returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d)
    wrong = base64.b64encode(os.urandom(32)).decode()
    check("wrong key rejected", run(feed, wrong, "--archive", arc, "--expected-url", URL).returncode != 0 and
          run(feed, wrong, "--feed-only").returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d)
    os.remove(arc)
    check("absent archive rejected", run(feed, key, "--archive", arc, "--expected-url", URL).returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d)
    dotseg = PREFIX + "../../evil/" + NAME
    check("non-exact (dot-segment) URL rejected",
          run(feed, key, "--archive", arc, "--expected-url", dotseg).returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d, duplicate=True)
    check("duplicate enclosure URL rejected (ambiguous)",
          run(feed, key, "--archive", arc, "--expected-url", URL).returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, arc, key = build(d, foreign_new=True)
    check("foreign-prefixed <evil:enclosure> at URL rejected",
          run(feed, key, "--archive", arc, "--expected-url", URL).returncode != 0)

if failures:
    print(f"VERIFY-APPCAST TESTS FAILED ({failures})", file=sys.stderr)
    sys.exit(1)
print("all verify-appcast tests passed")
