#!/usr/bin/env python3
"""Build the static product site for GitHub Pages into an output directory.

Renders a small set of pages from `site/content/` (and the repository's
`MANUAL.md`) into a shared template with per-page SEO metadata and JSON-LD, then
copies the shared stylesheet and image assets and emits `sitemap.xml`,
`robots.txt`, and `.nojekyll`.

It NEVER produces `appcast.xml`: the Sparkle feed lives on the same GitHub Pages
host and is published only by the release workflow. The deploy workflow syncs
this output over the Pages branch while preserving `appcast.xml` byte-for-byte.

Usage: build-site.py <output-dir>
Requires: Python 3, the `markdown` package (pinned in CI; a venv locally).
"""
import html
import json
import os
import re
import shutil
import sys

import markdown

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
CONTENT = os.path.join(SITE, "content")

SITE_URL = "https://bcourbage.github.io/unison-ui-mac"
APP_NAME = "Unison UI for macOS"
REPO_URL = "https://github.com/bcourbage/unison-ui-mac"
CASK = "brew install --cask bcourbage/tap/unison-ui-mac"


def marketing_version() -> str:
    """Read MARKETING_VERSION from project.yml (single source of truth)."""
    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*MARKETING_VERSION:\s*"([^"]+)"', line)
            if m:
                return m.group(1)
    raise SystemExit("error: MARKETING_VERSION not found in project.yml")


VERSION = marketing_version()

# Screenshots shipped in the repo's assets/, reused by the landing page and the
# SoftwareApplication JSON-LD.
SCREENSHOTS = [
    "screenshot-sync-review.png",
    "screenshot-profile-editor.png",
    "screenshot-settings-sync.png",
    "screenshot-settings-reconcile.png",
]

# --- Pages ------------------------------------------------------------------
# Each page: slug ("" = homepage), nav label, <title>, meta description, and the
# content source (an HTML fragment under site/content/, a markdown file, or the
# repo MANUAL.md). `jsonld` is a list of schema.org objects embedded as JSON-LD.
WEBSITE_LD = {
    "@context": "https://schema.org",
    "@type": "WebSite",
    "name": APP_NAME,
    "url": SITE_URL + "/",
}
SOFTWAREAPP_LD = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": APP_NAME,
    "operatingSystem": "macOS 15",
    "applicationCategory": "UtilitiesApplication",
    "softwareVersion": VERSION,
    "url": SITE_URL + "/",
    "downloadUrl": REPO_URL + "/releases/latest",
    "softwareHelp": SITE_URL + "/manual/",
    "isAccessibleForFree": True,
    # Free and open source. No aggregateRating/review is included: Google's
    # software-app rich result requires a GENUINE rating, and none is fabricated.
    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    "license": "https://www.gnu.org/licenses/gpl-3.0.html",
    "screenshot": [f"{SITE_URL}/assets/{s}" for s in SCREENSHOTS],
}

PAGES = [
    {
        "slug": "",
        "nav": "Home",
        "title": f"{APP_NAME} — Native GUI for Unison File Synchronizer",
        "desc": ("A native macOS app for two-way file synchronization: a modern "
                 "Swift and AppKit interface for the Unison File Synchronizer, with "
                 "local and SSH roots and visual conflict review. macOS 15+, Apple "
                 "Silicon, free and open source."),
        "source": ("html", "index.html"),
        "jsonld": [WEBSITE_LD, SOFTWAREAPP_LD],
    },
    {
        "slug": "install",
        "nav": "Install",
        "title": f"Install — {APP_NAME}",
        "desc": ("How to install Unison UI for macOS: a one-line Homebrew cask, a "
                 "signed and notarized .app download, or build from source. macOS 15 "
                 "or later, Apple Silicon."),
        "source": ("md", os.path.join(CONTENT, "install.md")),
        "jsonld": [],
    },
    {
        "slug": "faq",
        "nav": "FAQ",
        "title": f"FAQ — {APP_NAME}",
        "desc": ("Frequently asked questions about Unison UI for macOS: requirements, "
                 "two-way synchronization, SSH remotes, conflict review, updates, and "
                 "its relationship to the upstream Unison File Synchronizer."),
        "source": ("md", os.path.join(CONTENT, "faq.md")),
        "jsonld": [],
    },
    {
        "slug": "manual",
        "nav": "Manual",
        "title": f"Manual — {APP_NAME}",
        "desc": ("The feature-by-feature user guide for Unison UI for macOS: profiles, "
                 "roots, the reconcile window, conflict review, diffing, and settings."),
        "source": ("manual", os.path.join(ROOT, "MANUAL.md")),
        "jsonld": [],
    },
]

TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{app}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{ogimage}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{ogimage}">
<link rel="icon" href="{root}/assets/Unison-macOS-Default-512x512@1x.png">
<link rel="stylesheet" href="{root}/style.css">
{jsonld}
</head>
<body>
<header class="site-header">
  <a class="brand" href="{root}/">
    <img src="{root}/assets/Unison-macOS-Default-512x512@1x.png" alt="{app} app icon" width="28" height="28">
    <span>{app}</span>
  </a>
  <nav class="site-nav">{nav}</nav>
</header>
<main class="{mainclass}">
{content}
</main>
<footer class="site-footer">
  <p>{app} is an independent, open-source project (GPLv3). It is not affiliated
  with the upstream <a href="https://github.com/bcpierce00/unison">Unison File Synchronizer</a>.</p>
  <p><a href="{repo}">GitHub</a> · <a href="{root}/install/">Install</a> ·
  <a href="{root}/faq/">FAQ</a> · <a href="{root}/manual/">Manual</a> ·
  <a href="{repo}/blob/main/CHANGELOG.md">Changelog</a></p>
</footer>
</body>
</html>
"""


def rel_href(target_slug: str, active_slug: str) -> str:
    """A RELATIVE link (this is a project Pages site under /unison-ui-mac/, so
    domain-absolute paths would resolve to the wrong host root)."""
    up = "" if active_slug == "" else "../"
    if target_slug == "":
        return up if up else "./"
    return f"{up}{target_slug}/"


def nav_html(active_slug: str) -> str:
    items = []
    for p in PAGES:
        href = rel_href(p["slug"], active_slug)
        cls = ' class="active"' if p["slug"] == active_slug else ""
        items.append(f'<a href="{href}"{cls}>{html.escape(p["nav"])}</a>')
    items.append(f'<a href="{REPO_URL}">GitHub</a>')
    return "\n".join(items)


def render_markdown(md_text: str) -> str:
    return markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "toc", "sane_lists", "attr_list"],
        output_format="html5",
    )


def load_content(page) -> str:
    kind, ref = page["source"]
    if kind == "html":
        with open(os.path.join(CONTENT, ref), encoding="utf-8") as f:
            body = f.read()
        # Substitute a few tokens so version/cask live in one place.
        return (body.replace("{{VERSION}}", VERSION)
                    .replace("{{CASK}}", html.escape(CASK))
                    .replace("{{REPO}}", REPO_URL))
    with open(ref, encoding="utf-8") as f:
        md_text = f.read()
    rendered = render_markdown(md_text)
    if kind == "manual":
        note = ('<p class="doc-note">This page is generated from '
                f'<a href="{REPO_URL}/blob/main/MANUAL.md">MANUAL.md</a> in the '
                "repository; it is the same guide bundled in the app's Help menu.</p>")
        rendered = note + rendered
    return f'<article class="doc">\n{rendered}\n</article>'


def jsonld_block(objs) -> str:
    if not objs:
        return ""
    out = []
    for o in objs:
        out.append('<script type="application/ld+json">'
                   + json.dumps(o, separators=(",", ":")) + "</script>")
    return "\n".join(out)


def build(outdir: str) -> None:
    if os.path.abspath(outdir) in (ROOT, os.path.dirname(ROOT)):
        raise SystemExit("refusing to build into the repo root")
    shutil.rmtree(outdir, ignore_errors=True)
    os.makedirs(outdir, exist_ok=True)

    ogimage = f"{SITE_URL}/assets/social-preview.png"
    urls = []
    for page in PAGES:
        slug = page["slug"]
        canonical = SITE_URL + "/" + (f"{slug}/" if slug else "")
        page_html = TEMPLATE.format(
            title=html.escape(page["title"]),
            desc=html.escape(page["desc"]),
            canonical=canonical,
            app=html.escape(APP_NAME),
            ogimage=ogimage,
            root="." if slug == "" else "..",
            repo=REPO_URL,
            nav=nav_html(slug),
            mainclass="home" if slug == "" else "page",
            jsonld=jsonld_block(page["jsonld"]),
            content=load_content(page),
        )
        dest_dir = outdir if slug == "" else os.path.join(outdir, slug)
        os.makedirs(dest_dir, exist_ok=True)
        with open(os.path.join(dest_dir, "index.html"), "w", encoding="utf-8") as f:
            f.write(page_html)
        urls.append(canonical)
        print(f"built {canonical}")

    # Stylesheet + image assets.
    shutil.copyfile(os.path.join(SITE, "static", "style.css"),
                    os.path.join(outdir, "style.css"))
    assets_out = os.path.join(outdir, "assets")
    os.makedirs(assets_out, exist_ok=True)
    for name in os.listdir(os.path.join(ROOT, "assets")):
        if name.lower().endswith((".png", ".jpg", ".jpeg", ".svg")):
            shutil.copyfile(os.path.join(ROOT, "assets", name),
                            os.path.join(assets_out, name))

    # sitemap.xml + robots.txt + .nojekyll (serve files as-is, no Jekyll).
    sm = ['<?xml version="1.0" encoding="UTF-8"?>',
          '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in urls:
        sm.append(f"  <url><loc>{u}</loc></url>")
    sm.append("</urlset>")
    with open(os.path.join(outdir, "sitemap.xml"), "w", encoding="utf-8") as f:
        f.write("\n".join(sm) + "\n")
    with open(os.path.join(outdir, "robots.txt"), "w", encoding="utf-8") as f:
        f.write(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")
    open(os.path.join(outdir, ".nojekyll"), "w").close()
    print(f"wrote sitemap.xml, robots.txt, .nojekyll, {len(SCREENSHOTS)} screenshots")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: build-site.py <output-dir>")
    build(sys.argv[1])
