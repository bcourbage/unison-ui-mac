#!/usr/bin/env python3
"""Convert a release-notes markdown file to a Sparkle "What's New" HTML fragment.

Sparkle's generate_appcast embeds a sidecar file as an inline <description> only
when it is an HTML *fragment* (no <!DOCTYPE> and no <body>). This converter emits
exactly that fragment from the small, fixed markdown subset the project's
release notes use:

    # H1 / ## H2 headings
    - bullet lists (one item per line; blank line or non-"- " line ends the list)
    paragraphs (blank-line separated)
    inline **bold**, `code`, and [text](url) links

It is intentionally not a general markdown engine: it covers the house style in
release-notes/*.md and nothing else, so the output is predictable and testable.
Unknown constructs degrade to escaped text rather than guessing.

Usage: release-notes-to-html.py <input.md>   # writes the fragment to stdout
"""
import html
import re
import sys

_BOLD = re.compile(r"\*\*(.+?)\*\*")
# Single-asterisk emphasis, run AFTER _BOLD so `**bold**` is already consumed. The
# content excludes `*` (so it can't span across a bold run) and can't be
# space-hugging, and neither delimiter may be adjacent to another `*` — so a
# stray or paired asterisk isn't turned into <em>.
_EMPH = re.compile(r"(?<![\\*])\*(?!\s)([^*]+?)(?<!\s)\*(?!\*)")
_CODE = re.compile(r"`([^`]+?)`")
_LINK = re.compile(r"\[([^\]]+)\]\((https?://[^\s)]+)\)")


def _inline(text: str) -> str:
    """Escape HTML, then re-introduce the allowed inline markup as tags.

    Escaping first means link URLs and text are safe; the markup regexes run on
    the escaped string and emit tags whose inner text is already escaped.
    """
    out = html.escape(text, quote=False)
    out = _LINK.sub(
        lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>',
        out,
    )
    out = _BOLD.sub(r"<strong>\1</strong>", out)
    out = _EMPH.sub(r"<em>\1</em>", out)
    out = _CODE.sub(r"<code>\1</code>", out)
    return out


def convert(md: str) -> str:
    lines = md.splitlines()
    blocks: list[str] = []
    i = 0
    n = len(lines)
    para: list[str] = []

    def flush_para() -> None:
        if para:
            blocks.append("<p>" + _inline(" ".join(para).strip()) + "</p>")
            para.clear()

    while i < n:
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            flush_para()
            i += 1
            continue
        if stripped.startswith("## "):
            flush_para()
            blocks.append("<h2>" + _inline(stripped[3:].strip()) + "</h2>")
            i += 1
            continue
        if stripped.startswith("# "):
            flush_para()
            blocks.append("<h1>" + _inline(stripped[2:].strip()) + "</h1>")
            i += 1
            continue
        if stripped.startswith("- "):
            flush_para()
            items: list[str] = []
            while i < n and lines[i].strip().startswith("- "):
                # Gather continuation lines (indented, not a new bullet/blank).
                item = lines[i].strip()[2:]
                i += 1
                while i < n and lines[i].strip() and not lines[i].strip().startswith(("- ", "#")):
                    item += " " + lines[i].strip()
                    i += 1
                items.append("<li>" + _inline(item.strip()) + "</li>")
            blocks.append("<ul>\n" + "\n".join(items) + "\n</ul>")
            continue
        para.append(stripped)
        i += 1

    flush_para()
    return "\n".join(blocks) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: release-notes-to-html.py <input.md>\n")
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        md = f.read()
    frag = convert(md)
    # Guard the one invariant Sparkle cares about: it must be a fragment.
    low = frag.lower()
    if "<!doctype" in low or "<body" in low:
        sys.stderr.write("error: output is not an HTML fragment\n")
        return 1
    sys.stdout.write(frag)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
