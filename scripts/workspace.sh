#!/usr/bin/env bash
# Manage the Con Services workspace: the con-services repository plus the
# module and GitOps repositories that live inside it as ignored folders.
#
#   scripts/workspace.sh clone    clone every repository that is missing
#   scripts/workspace.sh status   branch, uncommitted changes, ahead/behind
#   scripts/workspace.sh pull     fetch and fast-forward every clean repository
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
org="https://github.com/AGlElectronics"

# Folder name = repository name. Keep in sync with scripts/workspace.ps1 and
# the ignore list in .gitignore.
repos=(den hr Rally stash finance wiki desk learn tasks con-services-gitops)

state() {
  local path="$1" branch dirty counts
  branch="$(git -C "$path" branch --show-current)"
  dirty="$(git -C "$path" status --porcelain | wc -l | tr -d ' ')"
  counts="$(git -C "$path" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null || echo '- -')"
  printf '%-22s %-10s %-6s %s\n' "$2" "$branch" "$dirty" "$counts"
}

case "${1:-status}" in
  clone)
    for r in "${repos[@]}"; do
      if [[ -d "$root/$r/.git" ]]; then echo "ok      $r"; continue; fi
      git clone "$org/$r.git" "$root/$r" || echo "warning: could not clone $r (no access?)" >&2
    done
    ;;
  status)
    printf '%-22s %-10s %-6s %s\n' REPO BRANCH DIRTY 'AHEAD BEHIND'
    state "$root" con-services
    for r in "${repos[@]}"; do
      if [[ -d "$root/$r/.git" ]]; then state "$root/$r" "$r"; else printf '%-22s (missing)\n' "$r"; fi
    done
    ;;
  pull)
    for r in . "${repos[@]}"; do
      name="$r"; [[ "$r" == . ]] && name=con-services
      path="$root/$r"
      if [[ ! -d "$path/.git" ]]; then echo "missing $name"; continue; fi
      if [[ -n "$(git -C "$path" status --porcelain)" ]]; then echo "skip    $name (uncommitted changes)"; continue; fi
      if git -C "$path" pull --ff-only --quiet; then echo "pulled  $name"; else echo "warning: could not fast-forward $name" >&2; fi
    done
    ;;
  *)
    echo "usage: $0 {clone|status|pull}" >&2
    exit 2
    ;;
esac
