#!/usr/bin/env python3
"""Cryptographically verify a Sparkle appcast by delegating to the pinned
`sign_update` (Sparkle's own verifier). No third-party crypto library: the only
dependency is the checksum-pinned Sparkle tools tarball (`SPARKLE_BIN`).

Two checks, both fail-closed:

  * Feed-level signature (always): `sign_update --verify <appcast>` authenticates
    the entire feed body, so every enclosure URL and edSignature it carries is
    exactly what the maintainer signed.

  * The NEW release archive (with --archive PATH --expected-url URL): the appcast
    must contain exactly one <enclosure> whose `url` is EXACTLY `URL`, and that
    enclosure's `sparkle:edSignature` must verify over PATH's bytes. Matching the
    exact expected URL — not a prefix, and not by enumerating "enclosures Sparkle
    would parse" — sidesteps both the foreign-prefixed-enclosure ambiguity
    (ElementTree cannot faithfully reproduce Sparkle's qualified-name rule) and
    URL-canonicalization tricks (dot segments, encoded separators). Enclosure-set
    shape is the structural gate's job (verify-appcast-signatures.sh, xmllint
    name()); this gate proves the one archive we are shipping is validly signed.

  * --feed-only: verify just the feed-level signature — to authenticate a seed
    feed before reuse, or the published feed.

Ed25519 key material (base64) is read on stdin and passed to each `sign_update`
invocation on its stdin — never argv, never disk. It is EITHER the private signing
key (release-time signing/verification) OR a verifier-only public-key blob (feed
authentication with no private key; see make-verifier-key.py). Feed authentication
needs only the verifier-only key: do NOT add the private signing secret where the
public-key blob suffices (e.g. the Pages deploy).

Usage:
  SPARKLE_BIN=<dir> verify-appcast.py <appcast.xml> \
      [--archive PATH --expected-url URL] [--feed-only]
  # base64 key material on stdin: the private signing key, or a verifier-only
  # public-key blob for --feed-only authentication
"""
import argparse
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("appcast")
    ap.add_argument("--archive")
    ap.add_argument("--expected-url")
    ap.add_argument("--feed-only", action="store_true")
    args = ap.parse_args()

    if not args.feed_only and not (args.archive and args.expected_url):
        sys.stderr.write("error: --archive and --expected-url are required unless --feed-only\n")
        return 2

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
        # Key on stdin, never argv/disk.
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

    # --- The one NEW archive, matched by EXACT url ---
    with open(args.appcast, "rb") as f:
        root = ET.fromstring(f.read())
    # Match the canonical, unprefixed <enclosure> in no namespace — exactly what
    # generate_appcast emits and what Sparkle parses. `e.tag == "enclosure"`
    # rejects a foreign-prefixed <evil:enclosure> ({ns}enclosure) that Sparkle
    # would ignore but that a local-name match would wrongly accept.
    matches = [e for e in root.iter()
               if e.tag == "enclosure" and e.get("url") == args.expected_url]
    if len(matches) != 1:
        sys.stderr.write(
            f"error: expected exactly one enclosure with url {args.expected_url}, found {len(matches)}\n")
        return 1
    sig = matches[0].get(f"{{{SPARKLE_NS}}}edSignature")
    if not sig:
        sys.stderr.write("error: the expected enclosure has no sparkle:edSignature\n")
        return 1
    if not os.path.exists(args.archive):
        sys.stderr.write(f"error: archive not found: {args.archive}\n")
        return 1
    ok, err = su_verify(args.archive, sig)
    if not ok:
        sys.stderr.write(f"error: the new archive's signature did not verify over its bytes: {err}\n")
        return 1
    print(f"  ok (new archive)  {os.path.basename(args.archive)}")
    print("cryptographic verification passed: feed-level signature + new archive")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
