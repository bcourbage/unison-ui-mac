#!/usr/bin/env python3
"""Cryptographically verify a Sparkle appcast by delegating to the pinned
`sign_update` (Sparkle's own verifier). No third-party crypto library: the only
dependency is the checksum-pinned Sparkle tools tarball (`SPARKLE_BIN`), which
the release job already fetches.

Why delegate: Sparkle 2.9.6's feed-level signature lives in a trailing
`<!-- sparkle-signatures: ... -->` block whose exact boundaries only Sparkle's
own extractor gets right; reimplementing that parse is how a verifier ends up
disagreeing with the client. So this script parses only the RSS enclosure list
(to locate archives and constrain URLs) and hands every actual signature check
to `sign_update --verify`.

The Ed25519 private key (base64) is read on stdin and passed to each
`sign_update` invocation on its stdin — never argv, never disk.

Checks (all fail-closed):
  * feed-level signature: `sign_update --verify <appcast>` authenticates the
    whole feed body, so every enclosure URL and edSignature it carries is exactly
    what the maintainer signed. Always required.
  * each enclosure whose archive is present locally: `sign_update --verify
    <archive> <edSignature>` — the signature actually verifies over the bytes.
  * --expected-prefix P: every parsed enclosure URL must start with P.
  * --skip-absent: enclosures whose archive is not on disk are logged and
    skipped (their metadata is covered by the feed-level signature); at least one
    local archive must still verify (unless --feed-only).
  * --feed-only: verify just the feed-level signature — used to authenticate a
    seed feed before reuse, or a published feed, where no archives are local.

Usage:
  SPARKLE_BIN=<dir> verify-appcast.py <appcast.xml> <archives-dir> \
      [--expected-prefix URL] [--skip-absent] [--feed-only]
  # private key (base64) on stdin
"""
import argparse
import os
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def _ns(tag):
    return tag[1:tag.index("}")] if tag.startswith("{") else ""


def enclosures(root):
    """The enclosure elements Sparkle would parse: a direct <enclosure> child of
    an <item>, or of a <sparkle:deltas> under an item; excludes a
    sparkle-namespaced <enclosure>. Mirrors verify-appcast-signatures.sh."""
    for item in root.findall("./channel/item"):
        for child in list(item):
            if _local(child.tag) == "enclosure" and _ns(child.tag) != SPARKLE_NS:
                yield child
            elif _local(child.tag) == "deltas" and _ns(child.tag) == SPARKLE_NS:
                for d in list(child):
                    if _local(d.tag) == "enclosure":
                        yield d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("appcast")
    ap.add_argument("archives_dir")
    ap.add_argument("--expected-prefix", default=None)
    ap.add_argument("--skip-absent", action="store_true")
    ap.add_argument("--feed-only", action="store_true")
    args = ap.parse_args()

    sparkle_bin = os.environ.get("SPARKLE_BIN")
    if not sparkle_bin or not os.access(f"{sparkle_bin}/sign_update", os.X_OK):
        sys.stderr.write("error: SPARKLE_BIN must point at the Sparkle tools bin/ (with sign_update)\n")
        return 2
    sign_update = f"{sparkle_bin}/sign_update"

    key = sys.stdin.read().strip()
    if not key:
        sys.stderr.write("error: empty private key on stdin\n")
        return 2

    def su_verify(*extra):
        # Key on stdin, never argv/disk. Returns (ok, stderr).
        p = subprocess.run(
            [sign_update, "--verify", "--ed-key-file", "-", *extra],
            input=key, capture_output=True, text=True,
        )
        return p.returncode == 0, (p.stderr or "").strip()

    # --- Feed-level signature (always) ---
    ok, err = su_verify(args.appcast)
    if not ok:
        sys.stderr.write(f"error: feed-level signature did not verify: {err}\n")
        return 1
    print("  ok (feed-level signature)")

    if args.feed_only:
        print("cryptographic verification passed: feed-level signature")
        return 0

    # --- Per-enclosure: URL constraint + verify local archives over bytes ---
    with open(args.appcast, "rb") as f:
        root = ET.fromstring(f.read())
    encs = list(enclosures(root))
    if not encs:
        sys.stderr.write("error: no Sparkle-parsable <enclosure> entries found\n")
        return 1

    verified = 0
    for enc in encs:
        url = enc.get("url", "")
        name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
        if args.expected_prefix and not url.startswith(args.expected_prefix):
            sys.stderr.write(f"error: enclosure URL not under expected prefix: {url}\n")
            return 1
        sig = enc.get(f"{{{SPARKLE_NS}}}edSignature")
        if not sig:
            sys.stderr.write(f"error: enclosure {name} has no sparkle:edSignature\n")
            return 1
        path = os.path.join(args.archives_dir, name)
        if not os.path.exists(path):
            if args.skip_absent:
                print(f"  skip (archive not local)  {name}")
                continue
            sys.stderr.write(f"error: archive not found for enclosure: {path}\n")
            return 1
        ok, err = su_verify(path, sig)
        if not ok:
            sys.stderr.write(f"error: enclosure {name} signature did not verify over its bytes: {err}\n")
            return 1
        print(f"  ok (enclosure)  {name}")
        verified += 1

    if verified == 0:
        sys.stderr.write("error: no local archive was cryptographically verified\n")
        return 1
    print(f"cryptographic verification passed: feed + {verified} archive(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
