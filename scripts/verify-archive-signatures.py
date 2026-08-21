#!/usr/bin/env python3
"""Cryptographically verify a Sparkle appcast's Ed25519 signatures.

This is the release gate that the structural verify-appcast-signatures.sh cannot
be: it actually checks each signature against the archive bytes and the *shipped*
public key (SUPublicEDKey), so a well-formed-but-invalid signature is rejected.

Two independent Ed25519 signatures are verified (both under the same public key):

  1. Per-enclosure  — sparkle:edSignature on every enclosure Sparkle would parse
     (a direct <enclosure> child of an <item>, or of a <sparkle:deltas>), over the
     raw bytes of the referenced archive file in <archives-dir>.
  2. Feed-level     — the trailing "<!-- sparkle-signatures: ... -->" block that
     SURequireSignedFeed makes the client require, over the appcast body that
     precedes the block (exactly what Sparkle's SPUExtractAppcastContent returns).

Fail-closed: any missing archive, missing/invalid signature, or (with
--require-feed-signature) a missing feed signature exits non-zero.

Usage:
  verify-archive-signatures.py <appcast.xml> <archives-dir> \
      [--public-key <base64>] [--require-feed-signature]
"""
import argparse
import base64
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# The project's shipped Ed25519 public key (SUPublicEDKey in project.yml). The
# default so CI verifies against exactly what the app trusts; overridable for
# tests with a throwaway key.
DEFAULT_PUBLIC_KEY = "/jLGv/pL0qFJOHFm/kpxONcqkeo8KOBH+oxDLTuCwt8="
FEED_SIG_PREFIX = b"<!-- sparkle-signatures:\n"


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _ns(tag: str) -> str:
    return tag[1:tag.index("}")] if tag.startswith("{") else ""


def enclosures(root: ET.Element):
    """Yield the enclosure elements Sparkle would parse (mirrors the structural
    verifier's node set): a direct <enclosure> child of an <item>, or of a
    <sparkle:deltas> under an item. Excludes a sparkle-namespaced <enclosure>."""
    for item in root.findall("./channel/item"):
        for child in list(item):
            if _local(child.tag) == "enclosure" and _ns(child.tag) != SPARKLE_NS:
                yield child
            elif _local(child.tag) == "deltas" and _ns(child.tag) == SPARKLE_NS:
                for d in list(child):
                    if _local(d.tag) == "enclosure":
                        yield d


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appcast")
    ap.add_argument("archives_dir")
    ap.add_argument("--public-key", default=DEFAULT_PUBLIC_KEY)
    ap.add_argument("--require-feed-signature", action="store_true")
    ap.add_argument(
        "--skip-absent", action="store_true",
        help="skip (with a logged notice) enclosures whose archive is not present "
             "locally — used at release time, where older items are carried "
             "forward from the published feed and only the new archive is on "
             "disk. Their integrity is covered by the feed-level signature; at "
             "least one enclosure must still be cryptographically verified.")
    args = ap.parse_args()

    try:
        from nacl.signing import VerifyKey
        from nacl.exceptions import BadSignatureError
    except ImportError:
        sys.stderr.write("error: PyNaCl is required (pip install pynacl)\n")
        return 1

    pub = base64.b64decode(args.public_key)
    if len(pub) != 32:
        sys.stderr.write(f"error: public key is {len(pub)} bytes, expected 32\n")
        return 1
    verifier = VerifyKey(pub)

    with open(args.appcast, "rb") as f:
        raw = f.read()

    checked = 0
    enclosures_verified = 0
    # --- Per-enclosure signatures ---
    root = ET.fromstring(raw)
    encs = list(enclosures(root))
    if not encs:
        sys.stderr.write("error: no Sparkle-parsable <enclosure> entries found\n")
        return 1
    for enc in encs:
        url = enc.get("url", "")
        sig_b64 = enc.get(f"{{{SPARKLE_NS}}}edSignature")
        name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
        if not sig_b64:
            sys.stderr.write(f"error: enclosure {name} has no sparkle:edSignature\n")
            return 1
        path = f"{args.archives_dir}/{name}"
        try:
            with open(path, "rb") as af:
                data = af.read()
        except OSError:
            if args.skip_absent:
                # Loud, not silent: an older item carried forward from the
                # published feed. The feed-level signature still covers it.
                print(f"  skip (archive not local)  {name}")
                continue
            sys.stderr.write(f"error: archive not found for enclosure: {path}\n")
            return 1
        try:
            sig = base64.b64decode(sig_b64)
            if len(sig) != 64:
                raise ValueError(f"signature is {len(sig)} bytes, expected 64")
            verifier.verify(data, sig)
        except (BadSignatureError, ValueError) as e:
            sys.stderr.write(f"error: enclosure {name} signature INVALID: {e}\n")
            return 1
        print(f"  ok (enclosure)  {name}")
        checked += 1
        enclosures_verified += 1

    if args.skip_absent and enclosures_verified == 0:
        sys.stderr.write("error: no local archive was cryptographically verified\n")
        return 1

    # --- Feed-level signature ---
    idx = raw.rfind(FEED_SIG_PREFIX)
    if idx == -1:
        if args.require_feed_signature:
            sys.stderr.write("error: feed-level signature block is required but absent\n")
            return 1
        print("  no feed-level signature block (not required)")
    else:
        body = raw[:idx]
        block = raw[idx + len(FEED_SIG_PREFIX):]
        feed_sig = None
        for line in block.split(b"\n"):
            if line.startswith(b"edSignature:"):
                feed_sig = line.split(b":", 1)[1].strip()
                break
        if not feed_sig:
            sys.stderr.write("error: feed signature block has no edSignature line\n")
            return 1
        try:
            sig = base64.b64decode(feed_sig)
            if len(sig) != 64:
                raise ValueError(f"signature is {len(sig)} bytes, expected 64")
            verifier.verify(body, sig)
        except (BadSignatureError, ValueError) as e:
            sys.stderr.write(f"error: feed-level signature INVALID: {e}\n")
            return 1
        print("  ok (feed-level signature)")
        checked += 1

    print(f"cryptographic verification passed: {checked} signature(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
