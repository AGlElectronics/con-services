"""MkDocs hook: shows the root CHANGELOG.md on the docs page changelog.md.

The page contains the marker below; the hook replaces it with the changelog,
without its "# Changelog" title, and turns links written for GitHub
(`docs/<page>.md`, relative to the repository root) into links between
pages of the site.
"""

from pathlib import Path
import re

MARKER = "<!-- root-changelog -->"
CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def on_page_markdown(markdown, page, config, files):
    if page.file.src_uri != "changelog.md" or MARKER not in markdown:
        return markdown
    text = CHANGELOG.read_text(encoding="utf-8")
    text = re.sub(r"\A# Changelog\s*\n", "", text)
    text = text.replace("](docs/", "](")
    return markdown.replace(MARKER, text)
