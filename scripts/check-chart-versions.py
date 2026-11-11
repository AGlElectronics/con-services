#!/usr/bin/env python3
"""Check the versions of the Den and module Helm charts in deploy/charts/.

Every app (Den and each module) has its own version MAJOR.MINOR.PATCH, and
its chart is versioned with it. For every chart (or only the one named by
--tag) this checks that:

- Chart.yaml `version` is MAJOR.MINOR.PATCH and `appVersion` is the same;
- the annotation `conservices.io/den-major` equals the chart's MAJOR (a
  module's MAJOR is the Den MAJOR it is built for; Den's is its own);
- every image tag set in values.yaml is `<version>-BUILD`.

  python3 scripts/check-chart-versions.py
      every chart
  python3 scripts/check-chart-versions.py --base origin/main
      also: a chart changed since that ref must have a higher version
      (only once the app has a release tag <app>/v*; needs the tags)
  python3 scripts/check-chart-versions.py --tag hr/v1.12.1
      a release tag: only that chart, and its version must equal the tag
  python3 scripts/check-chart-versions.py --tag hr/v1.12.1 --list-images
      after the checks, print "<repository> <version>" for every image

Needs PyYAML (and git for --base). Docs: docs/operations/versioning.md
"""

import argparse
import pathlib
import re
import subprocess
import sys

import yaml

ANNOTATION = "conservices.io/den-major"
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
TAG = re.compile(r"^([a-z][a-z0-9-]*)/v(.+)$")


def parse_version(text):
    m = SEMVER.match(str(text))
    return tuple(int(p) for p in m.groups()) if m else None


def images(values, path="values"):
    """Yield (path, repository, tag) for every {repository, tag} block."""
    if isinstance(values, dict):
        if isinstance(values.get("repository"), str) and "tag" in values:
            yield path, values["repository"], str(values.get("tag") or "")
        for key, value in values.items():
            yield from images(value, f"{path}.{key}")
    elif isinstance(values, list):
        for i, value in enumerate(values):
            yield from images(value, f"{path}[{i}]")


def load_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def check_chart(chart_dir, errors):
    """Check one chart; return (version tuple or None, chart metadata)."""
    name = chart_dir.name
    meta = load_yaml(chart_dir / "Chart.yaml")
    where = f"{chart_dir.as_posix()}/Chart.yaml"
    if meta.get("name") != name:
        errors.append(f"{where}: name is {meta.get('name')!r}, want {name!r} (the folder name, used in the release tag {name}/vX.Y.Z)")
    version = parse_version(meta.get("version"))
    if version is None:
        errors.append(f"{where}: version {meta.get('version')!r} is not MAJOR.MINOR.PATCH")
        return None, meta
    text = ".".join(map(str, version))
    if str(meta.get("appVersion")) != text:
        errors.append(f"{where}: appVersion {meta.get('appVersion')!r} must equal version {text!r} (the chart is versioned with its app)")
    den_major = (meta.get("annotations") or {}).get(ANNOTATION)
    if den_major is None:
        errors.append(f"{where}: annotation {ANNOTATION} is missing; set it to \"{version[0]}\"")
    elif str(den_major) != str(version[0]):
        errors.append(f"{where}: {ANNOTATION} is {den_major!r} but the chart's MAJOR is {version[0]}; "
                      "a module's MAJOR always equals the Den MAJOR it is built for")
    values_file = chart_dir / "values.yaml"
    if values_file.exists():
        tag_re = re.compile(rf"^{re.escape(text)}-[1-9][0-9]*$")
        for path, _, tag in images(load_yaml(values_file)):
            if tag and not tag_re.match(tag):
                errors.append(f"{values_file.as_posix()}: {path}.tag is {tag!r}, want {text}-BUILD "
                              "(all images of a release share the app's version)")
    return version, meta


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def released(name):
    """Whether the app has a chart release tag <name>/v* yet."""
    return bool(git("tag", "--list", f"{name}/v*").split())


def check_bumps(charts_dir, base, versions, errors):
    """A chart changed since `base` must have a higher version than at `base`.

    Charts of apps without a release tag <app>/v* are skipped: before its
    first release a chart may change while staying at its first version.
    """
    changed = git("diff", "--name-only", f"{base}...HEAD", "--", charts_dir.as_posix()).split()
    names = sorted({pathlib.PurePosixPath(p).parts[len(charts_dir.parts)] for p in changed
                    if len(pathlib.PurePosixPath(p).parts) > len(charts_dir.parts) + 1})
    for name in names:
        if name not in versions:
            continue  # removed, or already reported
        if not released(name):
            print(f"{name}: not released yet (no tag {name}/v*), version bump not required")
            continue
        try:
            old_meta = yaml.safe_load(git("show", f"{base}:{charts_dir.as_posix()}/{name}/Chart.yaml")) or {}
        except subprocess.CalledProcessError:
            print(f"{name}: new chart")
            continue
        old = parse_version(old_meta.get("version"))
        new = versions[name]
        if old is not None and new is not None and new <= old:
            errors.append(f"{charts_dir.as_posix()}/{name}: files changed but version {'.'.join(map(str, new))} is not higher than "
                          f"{'.'.join(map(str, old))} on {base}; bump version and appVersion in its Chart.yaml "
                          "(PATCH for a fix, MINOR for a feature)")
        elif old is not None and new is not None:
            print(f"{name}: {'.'.join(map(str, old))} -> {'.'.join(map(str, new))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--charts", default="deploy/charts", help="folder with one chart per app")
    parser.add_argument("--base", help="git ref to compare with: changed charts must bump their version")
    parser.add_argument("--tag", help="release tag <app>/vMAJOR.MINOR.PATCH: check only that chart")
    parser.add_argument("--list-images", action="store_true", help="with --tag: print '<repository> <version>' per image")
    args = parser.parse_args()

    charts_dir = pathlib.Path(args.charts)
    errors, warnings = [], []
    all_charts = sorted(p.parent for p in charts_dir.glob("*/Chart.yaml"))

    if args.tag:
        m = TAG.match(args.tag)
        if not m or parse_version(m.group(2)) is None:
            sys.exit(f"Tag {args.tag!r} is not <app>/vMAJOR.MINOR.PATCH (for example hr/v1.12.1, no pre-release suffix)")
        app, want = m.group(1), m.group(2)
        chart_dir = charts_dir / app
        if chart_dir not in all_charts:
            sys.exit(f"Tag {args.tag!r}: there is no chart {chart_dir.as_posix()} "
                     f"(apps: {', '.join(p.name for p in all_charts)})")
        version, meta = check_chart(chart_dir, errors)
        if version is not None and ".".join(map(str, version)) != want:
            errors.append(f"{chart_dir.as_posix()}/Chart.yaml: version {meta.get('version')} does not match the tag {args.tag}; "
                          f"delete the tag, set version and appVersion to {want}, then tag again")
        selected = {app: version}
    else:
        selected = {p.name: check_chart(p, errors)[0] for p in all_charts}

    den = selected.get("den")
    if den is None and (charts_dir / "den" / "Chart.yaml").exists():
        den = parse_version(load_yaml(charts_dir / "den" / "Chart.yaml").get("version"))
    if den is not None:
        for name, version in selected.items():
            if name != "den" and version is not None and version[0] != den[0]:
                warnings.append(f"{name} {'.'.join(map(str, version))} targets Den MAJOR {version[0]}, "
                                f"but the Den chart here is {'.'.join(map(str, den))}; "
                                "a cluster can only run it with a Den of the same MAJOR")

    if args.base:
        check_bumps(charts_dir, args.base, selected, errors)

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"\n{len(errors)} problem(s). See docs/operations/versioning.md.", file=sys.stderr)
        sys.exit(1)

    if args.list_images:
        if not args.tag:
            sys.exit("--list-images needs --tag")
        app = TAG.match(args.tag).group(1)
        values_file = charts_dir / app / "values.yaml"
        for _, repository, _ in images(load_yaml(values_file)) if values_file.exists() else []:
            print(f"{repository} {want}")
        return

    for name, version in selected.items():
        print(f"{name}: {'.'.join(map(str, version))}")
    print(f"chart-versions: {len(selected)} chart(s) OK")


if __name__ == "__main__":
    main()
