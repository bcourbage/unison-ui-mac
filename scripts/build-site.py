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


def unison_version() -> str:
    """Read the embedded Unison version from the Makefile (single source of
    truth: `UNISON_VERSION ?= X`), so the site never hardcodes it."""
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*UNISON_VERSION\s*\??=\s*(\S+)', line)
            if m:
                return m.group(1)
    raise SystemExit("error: UNISON_VERSION not found in Makefile")


UNISON_VERSION = unison_version()
UNISON_TAG_URL = f"https://github.com/bcpierce00/unison/releases/tag/v{UNISON_VERSION}"

# Screenshots shipped in the repo's assets/, reused by the landing page and the
# SoftwareApplication JSON-LD.
SCREENSHOTS = [
    "screenshot-sync-review.png",
    "screenshot-profile-editor.png",
    "screenshot-settings-sync.png",
    "screenshot-settings-reconcile.png",
]


def png_info(path):
    """Return (width_px, height_px, dpi) from a PNG's IHDR and pHYs chunks.
    Pure-stdlib so it runs on the CI runner without Pillow."""
    with open(path, "rb") as f:
        data = f.read()
    w = int.from_bytes(data[16:20], "big")   # IHDR is always the first chunk
    h = int.from_bytes(data[20:24], "big")
    dpi = 72.0                                # macOS point base; 1x if no pHYs
    i = 8
    while i + 12 <= len(data):
        length = int.from_bytes(data[i:i + 4], "big")
        ctype = data[i + 4:i + 8]
        if ctype == b"pHYs":
            chunk = data[i + 8:i + 8 + length]
            ppu_x, unit = int.from_bytes(chunk[0:4], "big"), chunk[8]
            if unit == 1 and ppu_x:           # pixels per metre -> dpi
                dpi = ppu_x * 0.0254
            break
        if ctype == b"IDAT":                  # pHYs precedes image data
            break
        i += 12 + length
    return w, h, dpi


def screenshot_display_sizes():
    """CSS display size (logical points) for each screenshot, so the lightbox
    shows it at true 1:1 — a 2x Retina capture (144 dpi) renders at half its
    pixel size, i.e. the size the window actually was on screen."""
    sizes = {}
    for name in SCREENSHOTS:
        w, h, dpi = png_info(os.path.join(ROOT, "assets", name))
        scale = (dpi / 72.0) or 1.0
        sizes[name] = [round(w / scale), round(h / scale)]
    return sizes


LB_SIZES = screenshot_display_sizes()

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
    {
        "slug": "credits",
        "nav": "Credits",
        "in_nav": False,  # reachable from the footer, not the top nav
        "title": f"Credits — {APP_NAME}",
        "desc": ("Acknowledgements and licenses for Unison UI for macOS: the Unison "
                 "File Synchronizer (GPLv3) and the Sparkle update framework (MIT)."),
        "source": ("md", os.path.join(CONTENT, "credits.md")),
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
{headscript}
{jsonld}
</head>
<body>
<header class="site-header">
  <a class="brand" href="{root}/">
    <img src="{root}/assets/Unison-macOS-Default-512x512@1x.png" alt="{app} app icon" width="28" height="28">
    <span>{app}</span>
  </a>
  <nav class="site-nav">{nav}<button class="theme-toggle" type="button" hidden aria-label="Switch color theme"></button></nav>
</header>
<main class="{mainclass}">
{content}
</main>
<footer class="site-footer">
  <p>{app} is an independent, open-source project (GPLv3), not affiliated with the
  upstream <a href="https://github.com/bcpierce00/unison">Unison File Synchronizer</a>.
  It is built on Unison and depends on its actively maintained synchronization
  engine, with thanks to that project's maintainers.</p>
  <p><a href="{repo}">GitHub</a> · <a href="{root}/install/">Install</a> ·
  <a href="{root}/faq/">FAQ</a> · <a href="{root}/manual/">Manual</a> ·
  <a href="{root}/credits/">Credits</a> ·
  <a href="{repo}/blob/main/CHANGELOG.md">Changelog</a></p>
</footer>
{script}
</body>
</html>
"""

# Site-wide: add a Copy button to any command block marked copyable — a
# <pre data-copyable> or a <code class="copyable"> (fenced block). Passed to the
# template as a format VALUE so its braces are never parsed by str.format.
COPY_SCRIPT = """<script>
(function () {
  var ICON = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>';
  function enhance(pre) {
    var code = pre.querySelector("code") || pre;
    var text = code.textContent.trim();
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy-btn";
    btn.setAttribute("aria-label", "Copy command to clipboard");
    btn.innerHTML = ICON + '<span class="copy-label">Copy</span>';
    btn.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(text).then(function () {
        var label = btn.querySelector(".copy-label");
        var prev = label.textContent;
        label.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(function () { label.textContent = prev; btn.classList.remove("copied"); }, 1500);
      });
    });
    var box = document.createElement("div");
    box.className = "install-box";
    pre.parentNode.insertBefore(box, pre);
    box.appendChild(pre);
    box.appendChild(btn);
  }
  var targets = [];
  document.querySelectorAll("pre[data-copyable]").forEach(function (p) { targets.push(p); });
  document.querySelectorAll("code.copyable").forEach(function (c) {
    var pre = c.parentElement;
    if (pre && pre.tagName === "PRE" && targets.indexOf(pre) === -1) targets.push(pre);
  });
  targets.forEach(enhance);
})();

// Reveal: the "Install with Homebrew" button shows/hides its command block.
// Progressive enhancement: the block is visible without JS; JS collapses it on
// load, then toggles it, so the button and the command are never both showing
// the same thing at once.
(function () {
  var toggle = document.getElementById("brew-toggle");
  var box = document.getElementById("brew-box");
  if (!toggle || !box) return;
  function set(open) {
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.classList.toggle("active", open);
    box.hidden = !open;
  }
  set(false);
  toggle.addEventListener("click", function () {
    set(toggle.getAttribute("aria-expanded") !== "true");
  });
})();

// Lightbox: click a screenshot to view it full size. Left/right move between
// screenshots and STOP at the ends (no wrap): the arrows disable at the first
// and last image.
(function () {
  var shots = document.querySelector(".shots");
  if (!shots) return;
  var imgs = Array.prototype.slice.call(shots.querySelectorAll("figure img"));
  if (!imgs.length) return;

  var overlay = document.createElement("div");
  overlay.className = "lightbox";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-modal", "true");
  overlay.hidden = true;
  overlay.innerHTML =
    '<button class="lb-close" type="button" aria-label="Close">✕</button>' +
    '<button class="lb-prev" type="button" aria-label="Previous screenshot">‹</button>' +
    '<div class="lb-stage"><img class="lb-img" alt=""></div>' +
    '<button class="lb-next" type="button" aria-label="Next screenshot">›</button>';
  document.body.appendChild(overlay);

  var big = overlay.querySelector(".lb-img");
  var prev = overlay.querySelector(".lb-prev");
  var next = overlay.querySelector(".lb-next");
  var close = overlay.querySelector(".lb-close");
  var idx = 0;

  function show(i) {
    idx = i;
    big.src = imgs[i].currentSrc || imgs[i].src;
    big.alt = imgs[i].alt || "";
    // 1:1 at the screenshot's logical (point) size, not its 2x pixel size.
    var s = (window.__LB_SIZES || {})[(big.src || "").split("/").pop()];
    if (s) { big.style.width = s[0] + "px"; big.style.height = s[1] + "px"; }
    else { big.style.width = ""; big.style.height = ""; }
    prev.disabled = i <= 0;
    next.disabled = i >= imgs.length - 1;
    overlay.scrollTop = 0;
    overlay.scrollLeft = 0;
  }
  function open(i) {
    show(i);
    overlay.hidden = false;
    document.body.style.overflow = "hidden";
    close.focus();
  }
  function shut() {
    overlay.hidden = true;
    document.body.style.overflow = "";
    big.removeAttribute("src");
  }
  imgs.forEach(function (el, i) {
    el.style.cursor = "zoom-in";
    el.addEventListener("click", function () { open(i); });
  });
  prev.addEventListener("click", function () { if (idx > 0) show(idx - 1); });
  next.addEventListener("click", function () { if (idx < imgs.length - 1) show(idx + 1); });
  close.addEventListener("click", shut);
  overlay.addEventListener("click", function (e) { if (e.target === overlay) shut(); });
  document.addEventListener("keydown", function (e) {
    if (overlay.hidden) return;
    var k = e.key;
    if (k === "Escape" || k === "Esc") shut();
    else if ((k === "ArrowLeft" || k === "Left") && idx > 0) show(idx - 1);
    else if ((k === "ArrowRight" || k === "Right") && idx < imgs.length - 1) show(idx + 1);
  });
})();

// Theme toggle: cycle Auto (follows system) -> Light -> Dark, remembered in
// localStorage. The no-flash applier in <head> has already set data-theme on
// load; this wires the button's icon/label and the click behavior.
(function () {
  var btn = document.querySelector(".theme-toggle");
  if (!btn) return;
  var root = document.documentElement;
  var SUN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"></path></svg>';
  var MOON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"></path></svg>';
  var AUTO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"></circle><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"></path></svg>';
  var ICON = { auto: AUTO, light: SUN, dark: MOON };
  var LABEL = { auto: "Theme: Auto (follows system)", light: "Theme: Light", dark: "Theme: Dark" };
  function current() {
    try { var t = localStorage.getItem("ui-theme"); return (t === "light" || t === "dark") ? t : "auto"; }
    catch (e) { return "auto"; }
  }
  function apply(mode) {
    if (mode === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", mode);
    btn.innerHTML = ICON[mode];
    btn.setAttribute("aria-label", LABEL[mode]);
    btn.setAttribute("title", LABEL[mode]);
  }
  apply(current());
  btn.hidden = false;
  btn.addEventListener("click", function () {
    var order = ["auto", "light", "dark"];
    var next = order[(order.indexOf(current()) + 1) % order.length];
    try { if (next === "auto") localStorage.removeItem("ui-theme"); else localStorage.setItem("ui-theme", next); }
    catch (e) {}
    apply(next);
  });
})();
</script>"""


# Applied synchronously in <head> before first paint, so a saved Light/Dark choice
# does not flash the system theme first. Passed to the template as a format VALUE.
HEAD_SCRIPT = ('<script>try{var t=localStorage.getItem("ui-theme");'
               'if(t==="light"||t==="dark")'
               'document.documentElement.setAttribute("data-theme",t);}catch(e){}</script>')


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
        if not p.get("in_nav", True):
            continue
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


def substitute_tokens(text: str) -> str:
    """Version/cask/repo live in one place; pages reference them as tokens."""
    return (text.replace("{{VERSION}}", VERSION)
                .replace("{{CASK}}", html.escape(CASK))
                .replace("{{REPO}}", REPO_URL)
                .replace("{{UNISON_VERSION}}", UNISON_VERSION)
                .replace("{{UNISON_TAG_URL}}", UNISON_TAG_URL))


def load_content(page) -> str:
    kind, ref = page["source"]
    if kind == "html":
        with open(os.path.join(CONTENT, ref), encoding="utf-8") as f:
            return substitute_tokens(f.read())
    with open(ref, encoding="utf-8") as f:
        md_text = f.read()
    # The MANUAL renders verbatim; site markdown (install, faq) gets tokens.
    if kind != "manual":
        md_text = substitute_tokens(md_text)
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
    sizes_script = ("<script>window.__LB_SIZES="
                    + json.dumps(LB_SIZES, separators=(",", ":")) + ";</script>\n")
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
            headscript=HEAD_SCRIPT,
            script=sizes_script + COPY_SCRIPT,
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
