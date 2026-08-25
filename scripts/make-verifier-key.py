#!/usr/bin/env python3
"""Print a Sparkle VERIFIER-ONLY key (base64) for a public SUPublicEDKey.

Sparkle's `sign_update --verify --ed-key-file <file>` reads the 32-byte Ed25519
public key from the last 32 bytes of a 96-byte key blob and ignores the first 64.
So `64 zero bytes || decoded(SUPublicEDKey)` is a key that AUTHENTICATES a feed
with no private material. This lets a deploy authenticate the appcast without ever
holding the private signing key.

Proven against the pinned Sparkle 2.9.6: a valid feed verifies (rc 0), while a
tampered feed or a wrong public key fail (rc 1). Regression-tested in
scripts/test-verify-appcast.py.

Usage: make-verifier-key.py <SUPublicEDKey-base64>   # prints the verifier key
"""
import base64
import binascii
import sys


def verifier_key(public_key_b64: str) -> str:
    # Strict decode (outer whitespace trimmed, no other stray characters), matching
    # how Sparkle decodes SUPublicEDKey. Python's default b64decode is permissive
    # and would silently normalize e.g. "validkey!!!!" to the clean bytes, so the
    # gate could authenticate with a key Sparkle clients reject.
    try:
        pub = base64.b64decode(public_key_b64.strip(), validate=True)
    except (binascii.Error, ValueError) as e:
        raise SystemExit(f"invalid base64 public key: {e}")
    if len(pub) != 32:
        raise SystemExit(f"public key is {len(pub)} bytes, expected 32")
    return base64.b64encode(b"\x00" * 64 + pub).decode()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: make-verifier-key.py <SUPublicEDKey-base64>")
    sys.stdout.write(verifier_key(sys.argv[1]))
