"""Check that relative links in the public documents point at files in the repository: python3 Tools/test_docs_links.py."""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from urllib.parse import unquote


REPOSITORY = Path(__file__).resolve().parents[1]

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+).+?\1")
LINK = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")


def relative_link_targets(markdown):
    """Return the file paths that Markdown links and images refer to, without anchors."""
    targets = []
    fence = None
    for line in markdown.splitlines():
        marker = FENCE.match(line)
        if marker:
            # A fence closes only with the same character, at least as long as the opener.
            if fence is None:
                fence = marker.group(1)
            elif marker.group(1).startswith(fence):
                fence = None
            continue
        if fence is not None:
            continue
        for target in LINK.findall(CODE_SPAN.sub("", line)):
            path = unquote(target.split("#", 1)[0])
            if path and not SCHEME.match(target):
                targets.append(path)
    return targets


def missing_link_targets(document):
    """Return the relative links in a document whose target does not exist."""
    return [target for target in relative_link_targets(document.read_text())
            if not (document.parent / target).exists()]


def public_documents():
    return sorted([*REPOSITORY.glob("*.md"), *(REPOSITORY / "docs").rglob("*.md")])


class RepositoryDocumentLinkTests(unittest.TestCase):
    def test_relative_links_point_at_existing_paths(self):
        documents = public_documents()
        self.assertIn(REPOSITORY / "README.md", documents)
        for document in documents:
            with self.subTest(document=str(document.relative_to(REPOSITORY))):
                self.assertEqual(missing_link_targets(document), [])

    def test_relative_links_do_not_point_at_ignored_paths(self):
        """An ignored target, such as docs-local, exists only on the author's machine."""
        targets = set()
        for document in public_documents():
            for target in relative_link_targets(document.read_text()):
                path = (document.parent / target).resolve()
                if path.is_relative_to(REPOSITORY) and path != REPOSITORY:
                    targets.add(str(path.relative_to(REPOSITORY)))
        self.assertTrue(targets)
        result = subprocess.run(["git", "check-ignore", "--no-index", "--stdin"], cwd=REPOSITORY,
                                input="\n".join(sorted(targets)) + "\n", capture_output=True, text=True)
        # git exits with 1 when none of the paths is ignored.
        self.assertIn(result.returncode, (0, 1), result.stderr)
        self.assertEqual(result.stdout.splitlines(), [])


class LinkExtractionTests(unittest.TestCase):
    def test_links_and_images_are_collected_without_anchor_or_title(self):
        markdown = ('[a](docs/a.md) ![b](images/b.png "title") [c](docs/c.md#section)\n'
                    "[`Tools`](Tools) [d](<docs/d.md>)")
        self.assertEqual(relative_link_targets(markdown),
                         ["docs/a.md", "images/b.png", "docs/c.md", "Tools", "docs/d.md"])

    def test_percent_encoded_paths_are_decoded(self):
        self.assertEqual(relative_link_targets("[a](docs/my%20file.md)"), ["docs/my file.md"])

    def test_external_urls_and_page_anchors_are_skipped(self):
        markdown = "[a](https://example.com/a.md) [b](mailto:someone@example.com) [c](#section)"
        self.assertEqual(relative_link_targets(markdown), [])

    def test_code_spans_and_fenced_blocks_are_skipped(self):
        markdown = ("`![alt](image)` and ``[x](`y`.md)`` then [real](real.md)\n"
                    "```md\n[inside](inside.md)\n```\n"
                    "~~~~\n[tilde](tilde.md)\n```\n[still inside](still.md)\n~~~~\n"
                    "[after](after.md)\n")
        self.assertEqual(relative_link_targets(markdown), ["real.md", "after.md"])

    def test_missing_target_is_reported_relative_to_the_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "docs" / "present.md").write_text("[up](../README.md) [gone](gone.md)")
            readme = root / "README.md"
            readme.write_text("[ok](docs/present.md) [dir](docs) [bad](docs/absent.md#top)")
            self.assertEqual(missing_link_targets(readme), ["docs/absent.md"])
            self.assertEqual(missing_link_targets(root / "docs" / "present.md"), ["gone.md"])


if __name__ == "__main__":
    unittest.main()
