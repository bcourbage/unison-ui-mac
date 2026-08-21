#!/usr/bin/env python3
"""Deterministic tests for verify-archive-signatures.py.

Uses a THROWAWAY Ed25519 key (never the project key) to sign a fake archive and
a feed body, then asserts the verifier passes on valid input and fails closed on
a tampered archive, a corrupted signature, and a missing required feed signature.
"""
import base64
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
VERIFIER = HERE / "verify-archive-signatures.py"

try:
    from nacl.signing import SigningKey
except ImportError:
    sys.stderr.write("error: PyNaCl is required to run this test (pip install pynacl)\n")
    sys.exit(1)

failures = 0


def check(desc: str, cond: bool) -> None:
    global failures
    if not cond:
        failures += 1
    print(f"  {desc:34s} {'PASS' if cond else 'FAIL'}")


def run(appcast: pathlib.Path, archives: pathlib.Path, pub_b64: str, require_feed: bool,
        skip_absent: bool = False):
    cmd = [sys.executable, str(VERIFIER), str(appcast), str(archives),
           "--public-key", pub_b64]
    if require_feed:
        cmd.append("--require-feed-signature")
    if skip_absent:
        cmd.append("--skip-absent")
    return subprocess.run(cmd, capture_output=True, text=True)


def build(tmp: pathlib.Path, *, tamper_archive=False, corrupt_enc_sig=False,
          drop_feed_sig=False, extra_absent_enclosure=False):
    sk = SigningKey.generate()
    pub_b64 = base64.b64encode(bytes(sk.verify_key)).decode()

    archives = tmp
    name = "unison-ui-mac-9.9.9.app.zip"
    archive_bytes = b"pretend-zip-payload-" + b"\x00\x01\x02\x03" * 32
    (archives / name).write_bytes(archive_bytes)

    signed_bytes = b"different" if tamper_archive else archive_bytes
    enc_sig = base64.b64encode(sk.sign(signed_bytes).signature).decode()
    if corrupt_enc_sig:
        enc_sig = base64.b64encode(b"\x00" * 64).decode()

    url = f"https://github.com/o/r/releases/download/v9.9.9/{name}"
    # An older item carried forward from the published feed: valid signature over
    # an archive that is NOT present locally.
    absent_item = ""
    if extra_absent_enclosure:
        old_name = "unison-ui-mac-8.8.8.app.zip"
        old_bytes = b"older-release-payload"
        old_sig = base64.b64encode(sk.sign(old_bytes).signature).decode()
        old_url = f"https://github.com/o/r/releases/download/v8.8.8/{old_name}"
        absent_item = (
            '    <item>\n'
            f'      <enclosure url="{old_url}" length="{len(old_bytes)}" '
            f'type="application/octet-stream" sparkle:edSignature="{old_sig}"/>\n'
            '    </item>\n'
        )
    body = (
        '<?xml version="1.0"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        '  <channel>\n    <item>\n'
        f'      <enclosure url="{url}" length="{len(archive_bytes)}" '
        f'type="application/octet-stream" sparkle:edSignature="{enc_sig}"/>\n'
        '    </item>\n'
        f'{absent_item}'
        '  </channel>\n</rss>\n'
    ).encode()

    appcast = archives / "appcast.xml"
    if drop_feed_sig:
        appcast.write_bytes(body)
    else:
        feed_sig = base64.b64encode(sk.sign(body).signature).decode()
        trailer = (b"<!-- sparkle-signatures:\nedSignature: "
                   + feed_sig.encode()
                   + f"\nlength: {len(body)}\n-->\n".encode())
        appcast.write_bytes(body + trailer)
    return appcast, archives, pub_b64


print("verify-archive-signatures.py:")

with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d))
    r = run(ac, ar, pub, require_feed=True)
    check("valid enclosure + feed sig", r.returncode == 0)

with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d), tamper_archive=True)
    r = run(ac, ar, pub, require_feed=True)
    check("tampered archive rejected", r.returncode != 0)

with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d), corrupt_enc_sig=True)
    r = run(ac, ar, pub, require_feed=True)
    check("corrupt enclosure sig rejected", r.returncode != 0)

with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d), drop_feed_sig=True)
    r = run(ac, ar, pub, require_feed=True)
    check("missing required feed sig rejected", r.returncode != 0)
    r2 = run(ac, ar, pub, require_feed=False)
    check("missing feed sig ok when not required", r2.returncode == 0)

with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d))
    wrong = base64.b64encode(bytes(SigningKey.generate().verify_key)).decode()
    r = run(ac, ar, wrong, require_feed=True)
    check("wrong public key rejected", r.returncode != 0)

# Carried-forward older item whose archive is absent locally.
with tempfile.TemporaryDirectory() as d:
    ac, ar, pub = build(pathlib.Path(d), extra_absent_enclosure=True)
    r = run(ac, ar, pub, require_feed=True)
    check("absent archive fails without --skip-absent", r.returncode != 0)
    r2 = run(ac, ar, pub, require_feed=True, skip_absent=True)
    check("absent archive skipped with --skip-absent", r2.returncode == 0)
    check("skip logged, not silent", "skip (archive not local)" in r2.stdout)

if failures:
    print(f"VERIFY-ARCHIVE-SIGNATURES TESTS FAILED ({failures})", file=sys.stderr)
    sys.exit(1)
print("all verify-archive-signatures tests passed")
