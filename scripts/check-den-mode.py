#!/usr/bin/env python3
"""Fail unless every rendered module backend runs with DEN_MODE=required.

Kubernetes is the reference setup, where every module waits for Den until
it is paired. This reads the manifests rendered by the "Deploy validate"
workflow (helm template with default values, kubectl kustomize) and checks
each module backend Deployment (<name>-backend, Den's excluded): the value
it gets from its ConfigMaps (envFrom) or its own env must be "required".
Every Helm chart of a module (helm-<module>*.yaml) must contain a backend.

  python3 scripts/check-den-mode.py <dir with rendered *.yaml>

Needs PyYAML. Docs: docs/contributing/ci.md
"""

import pathlib
import sys

import yaml


def backends(docs):
    for d in docs:
        if d.get("kind") != "Deployment":
            continue
        name = d["metadata"]["name"]
        if name.endswith("-backend") and not name.startswith("den-"):
            yield d


def den_mode(deploy, configmaps):
    """DEN_MODE the backend container sees; env wins over envFrom."""
    ns = deploy["metadata"].get("namespace")
    pod = deploy["spec"]["template"]["spec"]
    containers = [c for c in pod["containers"] if c["name"] == "backend"] or pod["containers"][:1]
    c = containers[0]
    for e in c.get("env") or []:
        if e.get("name") == "DEN_MODE":
            return e.get("value", "<valueFrom>")
    value = None
    for src in c.get("envFrom") or []:
        ref = (src.get("configMapRef") or {}).get("name")
        data = configmaps.get((ns, ref)) or configmaps.get((None, ref)) or {}
        if "DEN_MODE" in data:
            value = data["DEN_MODE"]
    return value


def main():
    out = pathlib.Path(sys.argv[1])
    errors, checked = [], 0
    for f in sorted(out.glob("*.yaml")):
        docs = [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if isinstance(d, dict)]
        configmaps = {
            (d["metadata"].get("namespace"), d["metadata"]["name"]): d.get("data") or {}
            for d in docs if d.get("kind") == "ConfigMap"
        }
        found = list(backends(docs))
        if f.name.startswith("helm-") and not f.name.startswith("helm-den") and not found:
            errors.append(f"{f.name}: no module backend Deployment rendered")
        for d in found:
            checked += 1
            mode = den_mode(d, configmaps)
            if mode != "required":
                errors.append(f"{f.name}: Deployment {d['metadata']['name']} has DEN_MODE={mode!r}, want 'required'")
    if not checked:
        errors.append(f"{out}: no module backend Deployment found in any *.yaml")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"\n{len(errors)} problem(s). Kubernetes defaults must keep modules waiting for Den "
              "(den.mode / DEN_MODE=required); see docs/concepts/pairing.md.", file=sys.stderr)
        sys.exit(1)
    print(f"den-mode: {checked} module backend(s), all DEN_MODE=required")


if __name__ == "__main__":
    main()
