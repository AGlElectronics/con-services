#!/usr/bin/env bash
# Copies the shared Go packages (shared/go/<pkg>) into module backends, or
# checks that the copies have not drifted. Same behaviour as sync-shared.ps1.
#
#   scripts/sync-shared.sh --modules learn --packages denlink,groupmatch
#   scripts/sync-shared.sh --modules hr,stash,learn --check
#   scripts/sync-shared.sh --backend-dir ../hr/backend --check
#
# Options:
#   --modules a,b       module folders in the workspace root (<module>/backend)
#   --backend-dir path  a backend folder with go.mod (repeatable)
#   --packages a,b      packages to copy; default: those the backend already has
#   --check             compare only; exit 1 on drift
#
# Import paths github.com/AGlElectronics/con-services/shared/go/<x> become
# <module path>/internal/<x>; every file gets the header
#   // Code generated from con-services shared/go/<pkg>; DO NOT EDIT. Run scripts/sync-shared.
# Generated files no longer in shared/go are removed; other files are left alone.
# Docs: https://aglelectronics.github.io/con-services/concepts/shared-code/
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shared_go="$workspace/shared/go"
shared_module="github.com/AGlElectronics/con-services/shared/go"
marker="Code generated from con-services shared/go/"

modules=() backends=() packages=() check=0
split() { local IFS=,; for x in $1; do x="${x//[[:space:]]/}"; [ -n "$x" ] && printf '%s\n' "$x"; done; }
while [ $# -gt 0 ]; do
  case "$1" in
    --modules) mapfile -t -O "${#modules[@]}" modules < <(split "$2"); shift 2 ;;
    --backend-dir) backends+=("$2"); shift 2 ;;
    --packages) mapfile -t -O "${#packages[@]}" packages < <(split "$2"); shift 2 ;;
    --check) check=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

known=()
for d in "$shared_go"/*/; do
  compgen -G "$d*.go" >/dev/null && known+=("$(basename "$d")")
done
for p in "${packages[@]+"${packages[@]}"}"; do
  [[ " ${known[*]} " == *" $p "* ]] || { echo "Unknown package '$p'. shared/go has: ${known[*]}" >&2; exit 2; }
done
for m in "${modules[@]+"${modules[@]}"}"; do backends+=("$workspace/$m/backend"); done
[ "${#backends[@]}" -gt 0 ] || { echo "Name at least one module (--modules hr,learn) or backend folder (--backend-dir path)." >&2; exit 2; }

is_generated() { head -n 1 "$1" | tr -d '\r' | grep -qF "$marker"; }

# expected <pkg> <module path> <src file>: the generated copy on stdout (LF).
expected() {
  printf '// %s%s; DO NOT EDIT. Run scripts/sync-shared.\n\n' "$marker" "$1"
  tr -d '\r' < "$3" | sed "s#\"${shared_module//./\\.}/#\"$2/internal/#g"
}

drift=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for backend in "${backends[@]}"; do
  [ -f "$backend/go.mod" ] || { echo "No go.mod in $backend" >&2; exit 2; }
  backend="$(cd "$backend" && pwd)"
  modpath="$(awk '$1 == "module" { print $2; exit }' "$backend/go.mod" | tr -d '\r')"
  [ -n "$modpath" ] || { echo "No module line in $backend/go.mod" >&2; exit 2; }

  pkgs=("${packages[@]+"${packages[@]}"}")
  if [ "${#pkgs[@]}" -eq 0 ]; then
    for p in "${known[@]}"; do
      for f in "$backend/internal/$p"/*.go; do
        [ -f "$f" ] && is_generated "$f" && { pkgs+=("$p"); break; }
      done
    done
  fi
  if [ "${#pkgs[@]}" -eq 0 ]; then
    if [ "$check" = 1 ]; then echo "$backend: no shared packages adopted, nothing to check"; continue; fi
    echo "$backend has no shared packages yet; choose them with --packages (available: ${known[*]})." >&2; exit 2
  fi

  for pkg in "${pkgs[@]}"; do
    dir="$backend/internal/$pkg"
    for f in "$dir"/*.go; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"
      [ -f "$shared_go/$pkg/$name" ] && continue
      if is_generated "$f"; then
        if [ "$check" = 1 ]; then echo "DRIFT  $pkg/$name: no longer in shared/go (stale copy)"; drift=$((drift + 1))
        else rm -f "$f"; echo "removed $f"; fi
      else
        echo "warning: $f is not generated from shared/go; left alone" >&2
      fi
    done
    for src in "$shared_go/$pkg"/*.go; do
      name="$(basename "$src")"
      dst="$dir/$name"
      expected "$pkg" "$modpath" "$src" > "$tmp"
      if [ -f "$dst" ] && tr -d '\r' < "$dst" | cmp -s - "$tmp"; then continue; fi
      if [ "$check" = 1 ]; then
        if [ ! -f "$dst" ]; then echo "DRIFT  $pkg/$name: missing"
        elif ! is_generated "$dst"; then echo "DRIFT  $pkg/$name: exists but is not a generated copy"
        else
          echo "DRIFT  $pkg/$name: differs from shared/go/$pkg/$name"
          tr -d '\r' < "$dst" | diff -u --label "module internal/$pkg/$name" --label "shared/go/$pkg/$name" - "$tmp" | head -n 40 || true
        fi
        drift=$((drift + 1))
        continue
      fi
      mkdir -p "$dir"
      cp "$tmp" "$dst"
      echo "wrote   $dst"
    done
    [ "$check" = 1 ] && echo "checked $backend internal/$pkg"
  done
done

if [ "$check" = 1 ] && [ "$drift" -gt 0 ]; then
  echo
  echo "$drift file(s) differ from con-services shared/go. Fix the code in shared/go and run scripts/sync-shared, never edit the copies."
  exit 1
fi
[ "$check" = 1 ] || printf '\nDone. In each backend run: go mod tidy; go build ./...; go test ./internal/...\n'
