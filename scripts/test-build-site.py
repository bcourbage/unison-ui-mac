#!/usr/bin/env python3
"""Unit tests for build-site.py. Run: python scripts/test-build-site.py"""
import importlib.util
import os
import shutil
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bs = _load("build_site", "build-site.py")
links = _load("check_site_links", "check-site-links.py")


class RmtreeSafety(unittest.TestCase):
    def test_refuses_nonempty_without_sentinel(self):
        d = tempfile.mkdtemp()
        try:
            keep = os.path.join(d, "important.txt")
            with open(keep, "w") as f:
                f.write("do not delete")
            with self.assertRaises(SystemExit):
                bs.prepare_outdir(d)
            self.assertTrue(os.path.exists(keep), "unrelated file must not be deleted")
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_accepts_empty_then_prior_build(self):
        d = tempfile.mkdtemp()
        try:
            out = bs.prepare_outdir(d)  # empty dir is accepted
            self.assertTrue(os.path.exists(os.path.join(out, bs.BUILD_SENTINEL)))
            with open(os.path.join(out, "index.html"), "w") as f:
                f.write("x")
            out2 = bs.prepare_outdir(d)  # a prior build (sentinel present) is wiped + rebuilt
            self.assertFalse(os.path.exists(os.path.join(out2, "index.html")))
            self.assertTrue(os.path.exists(os.path.join(out2, bs.BUILD_SENTINEL)))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_refuses_repo_root(self):
        with self.assertRaises(SystemExit):
            bs.prepare_outdir(bs.ROOT)


class LinkRewrite(unittest.TestCase):
    def test_rewrites_repo_relative(self):
        out = bs.rewrite_repo_relative_links(
            '<a href="INSTALL.md">i</a><a href="docs/x.md#s">d</a>')
        self.assertIn(f'href="{bs.REPO_URL}/blob/main/INSTALL.md"', out)
        self.assertIn(f'href="{bs.REPO_URL}/blob/main/docs/x.md#s"', out)

    def test_preserves_absolute_and_fragments(self):
        html = ('<a href="https://x.example">x</a><a href="#top">t</a>'
                '<a href="mailto:a@b.example">m</a><img src="/a.png">')
        self.assertEqual(bs.rewrite_repo_relative_links(html), html)


class LinkChecker(unittest.TestCase):
    def _site(self, tmp, body):
        with open(os.path.join(tmp, "index.html"), "w") as f:
            f.write("<html><body>" + body + "</body></html>")
        return links.find_issues(tmp)

    def test_flags_root_absolute_internal_link(self):
        d = tempfile.mkdtemp()
        try:
            # A host-root link is wrong on a project subpath site and must be caught.
            _, issues = self._site(d, '<a href="/install/">bad</a>')
            self.assertTrue(any(kind == "root-absolute" for _, _, kind in issues))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_accepts_relative_and_external(self):
        d = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(d, "faq"))
            with open(os.path.join(d, "faq", "index.html"), "w") as f:
                f.write("<html><body>ok</body></html>")
            _, issues = self._site(d, '<a href="faq/">ok</a><a href="https://x.example">x</a>')
            self.assertEqual(issues, [])
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
