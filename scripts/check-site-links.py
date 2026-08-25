#!/usr/bin/env python3
"""Check a built site for broken internal links and fragments.

For every .html file under <site-dir>, resolve each href/src that points inside
the site (relative, non-scheme, non-fragment-only-external) to a file on disk,
following directory-style links to index.html, and verify the target exists. For
links with a #fragment into an .html target, verify an element with that id (or a
named anchor) exists. External links (http/https/mailto/data/tel) are not fetched.

Exit 0 if clean, 1 if any issue is found. Pure stdlib.

Usage: check-site-links.py <site-dir>
"""
import os
import sys
from html.parser import HTMLParser
from urllib.parse import urldefrag, unquote

EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "data:", "tel:", "//")


class Collector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if d.get("id"):
            self.ids.add(d["id"])
        if tag == "a" and d.get("name"):
            self.ids.add(d["name"])
        for attr in ("href", "src"):
            if d.get(attr):
                self.links.append(d[attr])


def parse(path):
    c = Collector()
    with open(path, encoding="utf-8") as f:
        c.feed(f.read())
    return c


def link_kind(link):
    if not link or link.startswith(EXTERNAL_PREFIXES):
        return "external"
    # A single leading slash is a host-root link. On this PROJECT Pages site
    # (served under /unison-ui-mac/) it resolves to the wrong place — e.g.
    # href="/install/" points at bcourbage.github.io/install/, not the project
    # subpath — so it is a bug to catch, not to skip.
    if link.startswith("/"):
        return "root-absolute"
    return "internal"


def resolve(html_path, link):
    """(target_path, fragment) for an internal (relative) link."""
    base, frag = urldefrag(link)
    if base == "":                       # same-page fragment
        return (html_path, frag or None)
    target = os.path.normpath(os.path.join(os.path.dirname(html_path), unquote(base)))
    if base.endswith("/") or os.path.isdir(target) or not os.path.splitext(target)[1]:
        target = os.path.join(target, "index.html")
    return (target, frag or None)


def find_issues(site_dir):
    site_dir = os.path.abspath(site_dir)
    html_files = []
    for dirpath, _, names in os.walk(site_dir):
        for n in names:
            if n.endswith(".html"):
                html_files.append(os.path.join(dirpath, n))
    parsed = {p: parse(p) for p in html_files}

    issues = []
    for path, coll in sorted(parsed.items()):
        rel = os.path.relpath(path, site_dir)
        for link in coll.links:
            kind = link_kind(link)
            if kind == "external":
                continue
            if kind == "root-absolute":
                issues.append((rel, link, "root-absolute"))
                continue
            target, frag = resolve(path, link)
            if os.path.commonpath([site_dir, os.path.abspath(target)]) != site_dir:
                issues.append((rel, link, "escapes-site"))
                continue
            if not os.path.isfile(target):
                issues.append((rel, link, "missing-target"))
                continue
            if frag and target.endswith(".html"):
                tcoll = parsed.get(target) or parse(target)
                if frag not in tcoll.ids:
                    issues.append((rel, link, "missing-fragment"))
    return len(html_files), issues


def main(site_dir):
    n_pages, issues = find_issues(site_dir)
    for rel, link, kind in issues:
        print(f"{rel}: {link} -> {kind}")
    print(f"checked {n_pages} pages, issues={len(issues)}")
    return 1 if issues else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-site-links.py <site-dir>")
    raise SystemExit(main(sys.argv[1]))
