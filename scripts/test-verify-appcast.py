#!/usr/bin/env python3
"""Tests for verify-appcast.py against the REAL pinned sign_update.

Requires SPARKLE_BIN (the checksum-pinned Sparkle tools bin/). Uses a THROWAWAY
Ed25519 key — never the project key — to build a signed feed + archive, then
asserts verify-appcast.py passes on valid input and fails closed on: a tampered
archive, a poisoned (re-content) feed, an enclosure URL outside the expected
prefix, and an absent local archive. Locks the exact attack classes the review
found.
"""
import base64
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
VERIFIER = HERE / "verify-appcast.py"
PREFIX = "https://github.com/bcourbage/unison-ui-mac/releases/download/"

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
    print(f"  {desc:44s} {'PASS' if cond else 'FAIL'}")


def run(appcast, archives, key_b64, *flags):
    return subprocess.run(
        [sys.executable, str(VERIFIER), str(appcast), str(archives), *flags],
        input=key_b64, capture_output=True, text=True,
        env={**os.environ, "SPARKLE_BIN": SPARKLE_BIN},
    )


def build(d, *, tamper_archive=False, poison_feed=False, bad_url=False, absent=False):
    d = pathlib.Path(d)
    key_b64 = base64.b64encode(os.urandom(32)).decode()
    keyfile = d / "key.txt"
    keyfile.write_text(key_b64)
    name = "unison-ui-mac-9.9.9.app.zip"
    archive = d / name
    archive.write_bytes(b"payload-" + os.urandom(64))
    sig = subprocess.run(
        [SIGN_UPDATE, "-p", "--ed-key-file", str(keyfile), str(archive)],
        capture_output=True, text=True,
    ).stdout.strip()
    url = ("https://evil.example/" if bad_url else PREFIX + "v9.9.9/") + name
    feed = d / "appcast.xml"
    feed.write_text(
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        '<channel>\n<item>\n<sparkle:version>19</sparkle:version>\n'
        f'<enclosure url="{url}" length="{archive.stat().st_size}" '
        f'type="application/octet-stream" sparkle:edSignature="{sig}"/>\n'
        '</item>\n</channel>\n</rss>\n'
    )
    # Sign the feed in place (embeds the feed-level signature trailer).
    subprocess.run([SIGN_UPDATE, "--ed-key-file", str(keyfile), str(feed)],
                   capture_output=True, text=True, check=True)
    if poison_feed:
        # Inject a forged carried item AFTER signing → feed body no longer matches
        # the embedded feed signature (the review's carry-forward attack).
        text = feed.read_text().replace(
            "</channel>",
            '<item><sparkle:version>99</sparkle:version>'
            f'<enclosure url="{PREFIX}v99/x.zip" length="1" '
            f'type="application/octet-stream" sparkle:edSignature="{sig}"/></item></channel>',
        )
        feed.write_text(text)
    if tamper_archive:
        with open(archive, "ab") as fh:
            fh.write(b"tampered")
    if absent:
        archive.unlink()
    return feed, d, key_b64


print("verify-appcast.py (via real sign_update):")

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d)
    check("valid feed + archive", run(feed, ar, key, "--expected-prefix", PREFIX).returncode == 0)
    check("valid --feed-only", run(feed, ar, key, "--feed-only").returncode == 0)

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d, tamper_archive=True)
    check("tampered archive rejected", run(feed, ar, key).returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d, poison_feed=True)
    check("poisoned feed rejected", run(feed, ar, key).returncode != 0)
    check("poisoned feed rejected (--feed-only)", run(feed, ar, key, "--feed-only").returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d, bad_url=True)
    r = run(feed, ar, key, "--expected-prefix", PREFIX)
    check("URL outside prefix rejected", r.returncode != 0)

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d, absent=True)
    check("absent archive rejected (default)", run(feed, ar, key).returncode != 0)
    r = run(feed, ar, key, "--skip-absent")
    check("absent-only + --skip-absent fails (nothing verified)", r.returncode != 0)
    check("absent + --feed-only passes", run(feed, ar, key, "--feed-only").returncode == 0)

with tempfile.TemporaryDirectory() as d:
    feed, ar, key = build(d)
    wrong = base64.b64encode(os.urandom(32)).decode()
    check("wrong key rejected", run(feed, ar, wrong).returncode != 0)

if failures:
    print(f"VERIFY-APPCAST TESTS FAILED ({failures})", file=sys.stderr)
    sys.exit(1)
print("all verify-appcast tests passed")
