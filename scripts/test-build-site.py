#!/usr/bin/env python3
"""Unit tests for build-site.py. Run: python scripts/test-build-site.py"""
import importlib.util
import os
import shutil
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("build_site", os.path.join(_HERE, "build-site.py"))
bs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bs)


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


if __name__ == "__main__":
    unittest.main()
