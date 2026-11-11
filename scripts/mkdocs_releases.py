"""MkDocs hook: generates the table of current releases on operations/versioning.md.

The page contains the marker below; the hook replaces it with one row per app:

- Latest release: the highest chart release tag `<app>/vX.Y.Z` in this
  repository (the docs workflow checks out all tags).
- Den MAJOR: the MAJOR of that version (a module's MAJOR is the Den MAJOR it
  is built for).
- Needs Den: the "Needs Den: X.Y.Z" line of that version's section in the
  app's CHANGELOG.md, read from the app repository at its tag vX.Y.Z.

An app without a release tag shows the version being prepared in
deploy/charts/<app>/Chart.yaml. Without git or network the table still
builds; the missing cells say where to look instead.
"""

from datetime import datetime, timezone
from pathlib import Path
import logging
import re
import subprocess
import urllib.request

import yaml

log = logging.getLogger("mkdocs.hooks.releases")

MARKER = "<!-- release-table -->"
PAGE = "operations/versioning.md"
ROOT = Path(__file__).resolve().parent.parent
CHARTS = ROOT / "deploy" / "charts"
# (chart and tag name, display name, repository under AGlElectronics)
APPS = [
    ("den", "Den", "den"),
    ("hr", "HR", "hr"),
    ("rally", "Rally", "Rally"),
    ("stash", "Stash", "stash"),
    ("finance", "Finance", "finance"),
    ("learn", "Learn", "learn"),
    ("wiki", "Wiki", "wiki"),
    ("desk", "Desk", "desk"),
    ("tasks", "Tasks", "tasks"),
]
RAW = "https://raw.githubusercontent.com/AGlElectronics/{repo}/v{version}/CHANGELOG.md"
BLOB = "https://github.com/AGlElectronics/{repo}/blob/{ref}/CHANGELOG.md"
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def released_versions():
    """Return {app: (major, minor, patch)} of the highest tag <app>/vX.Y.Z."""
    try:
        out = subprocess.run(["git", "tag", "--list", "*/v*"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        log.info("release table: git tags not readable, showing no releases")
        return {}
    latest = {}
    for tag in out.split():
        app, _, version = tag.partition("/v")
        m = SEMVER.match(version)
        if m:
            parsed = tuple(int(p) for p in m.groups())
            if parsed > latest.get(app, (-1, -1, -1)):
                latest[app] = parsed
    return latest


def needs_den(repo, version):
    """The Needs Den version of `version` in the app's changelog, or None."""
    try:
        with urllib.request.urlopen(RAW.format(repo=repo, version=version), timeout=10) as response:
            text = response.read().decode("utf-8")
    except Exception as exc:  # no network, or the app tag does not exist
        log.info("release table: cannot read %s changelog at v%s: %s", repo, version, exc)
        return None
    section = re.search(rf"^## \[{re.escape(version)}\].*?(?=^## |\Z)", text, re.M | re.S)
    if not section:
        return None
    m = re.search(r"Needs Den:\s*`?([0-9]+\.[0-9]+\.[0-9]+)", section.group(0))
    return m.group(1) if m else None


def chart_version(app):
    try:
        meta = yaml.safe_load((CHARTS / app / "Chart.yaml").read_text(encoding="utf-8")) or {}
    except OSError:
        return None
    return str(meta.get("version")) if SEMVER.match(str(meta.get("version"))) else None


def table():
    released = released_versions()
    rows = [
        "| App | Latest release | Den MAJOR | Needs Den | Changelog |",
        "| --- | --- | --- | --- | --- |",
    ]
    for app, name, repo in APPS:
        if app in released:
            version = ".".join(map(str, released[app]))
            major = str(released[app][0])
            if app == "den":
                needs = "—"
            else:
                found = needs_den(repo, version)
                needs = f"`{found}` or later" if found else "see changelog"
            link = f"[v{version}]({BLOB.format(repo=repo, ref='v' + version)})"
            rows.append(f"| {name} | `{version}` | {major} | {needs} | {link} |")
        else:
            next_version = chart_version(app)
            preparing = f" (`{next_version}` in preparation)" if next_version else ""
            major = next_version.split(".")[0] if next_version else "—"
            link = f"[main]({BLOB.format(repo=repo, ref='main')})"
            rows.append(f"| {name} | not released yet{preparing} | {major} | — | {link} |")
    built = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows.append("")
    rows.append(f"*Generated from the release tags when this site was built ({built}).*")
    return "\n".join(rows)


def on_page_markdown(markdown, page, config, files):
    if page.file.src_uri != PAGE or MARKER not in markdown:
        return markdown
    return markdown.replace(MARKER, table())
