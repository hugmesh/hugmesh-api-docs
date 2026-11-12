#!/usr/bin/env bash
# =============================================================================
# check-spec-mirror.sh — assert each committed spec mirror is a byte-for-byte
# copy of the spec its backend commits.
#
# src/assets/specs/openapi-admin.json is a COPY of the admin BFF's committed
# src/main/resources/openapi/openapi.json. The navigator renders it as the
# reference page, so a stale copy documents an API the service no longer has:
# the copy taken on 2026-10-15 still told readers that `hardwareClass` accepts
# six boards (`x86|rpi5|frite|jetson|orangepi5|orangepizero2`) after the BFF
# started accepting every generator platform from its vendored worklist schema.
#
# scripts/spec-mirror.lock records, per mirror, where the copy came from (repo,
# commit, path) and the sha256 of that source file. This guard:
#
#   1. always (offline): the mirror's sha256 equals the recorded one. A hand
#      edit, a partial re-sync (one hunk carried over by hand) or a copy from a
#      different commit all fail here;
#   2. with --source NAME=FILE: FILE (a checkout of the backend's spec) has the
#      recorded sha256 and the mirror equals it byte for byte;
#   3. with --fetch: the same as 2, against the file at the recorded commit on
#      GitHub (public repos, no token), so the recorded hash is proven to be the
#      backend's file and not just a hash of whatever the mirror holds.
#
# It never rewrites a mirror. To re-sync, copy the backend file over the mirror
# and update the commit and sha256 on its lock row.
#
# Usage: check-spec-mirror.sh [--root DIR] [--source NAME=FILE]... [--fetch]
#   --root DIR   repo root (default: the parent of this script's directory), so
#                the battery (check-spec-mirror.test.sh) can point the guard at
#                a deliberately broken COPY.
# =============================================================================
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
fetch=0
declare -A sources=()

while [ $# -gt 0 ]; do
  case $1 in
    --root) root=$2; shift 2 ;;
    --source)
      case $2 in
        *=?*) sources[${2%%=*}]=${2#*=} ;;
        *) echo "check-spec-mirror: --source wants NAME=FILE, got '$2'" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --fetch) fetch=1; shift ;;
    *) echo "check-spec-mirror: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

lock=$root/scripts/spec-mirror.lock
if [ ! -f "$lock" ]; then
  echo "FAIL: no lock file at scripts/spec-mirror.lock" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# On a mismatch, say what the admin spec's platform field says on each side.
# Diagnostic only: jq may be absent, and the byte comparison is the verdict.
show_platforms() {
  command -v jq >/dev/null 2>&1 || return 0
  while [ $# -ge 2 ]; do
    printf '      %s hardwareClass: %s\n' "$1" \
      "$(jq -c '.components.schemas.BatchImageSpec.properties.hardwareClass // "absent"' "$2" 2>/dev/null || echo unreadable)" >&2
    shift 2
  done
}

rows=0
failures=0
declare -A seen=()
while IFS= read -r line || [ -n "$line" ]; do
  case $line in ''|'#'*) continue ;; esac
  read -r name mirror repo commit path sha extra <<<"$line"
  if [ -z "${sha:-}" ] || [ -n "${extra:-}" ] \
    || ! [[ $commit =~ ^[0-9a-f]{40}$ ]] || ! [[ $sha =~ ^[0-9a-f]{64}$ ]] \
    || ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "FAIL: malformed lock row: $line" >&2
    echo "      want: NAME MIRROR OWNER/REPO <40-hex commit> SOURCE_PATH <64-hex sha256>" >&2
    failures=$((failures + 1))
    continue
  fi
  rows=$((rows + 1))
  seen[$name]=1

  if [ ! -f "$root/$mirror" ]; then
    echo "FAIL [$name]: mirror $mirror is missing" >&2
    failures=$((failures + 1))
    continue
  fi
  got=$(sha_of "$root/$mirror")
  if [ "$got" != "$sha" ]; then
    echo "FAIL [$name]: $mirror is not the copy of $repo@${commit:0:12}:$path the lock records" >&2
    echo "      recorded sha256 $sha" >&2
    echo "      mirror   sha256 $got" >&2
    echo "      re-sync: copy the backend file over the mirror, then update this lock row" >&2
    failures=$((failures + 1))
  else
    echo "ok   [$name]: $mirror matches the recorded sha256 ($repo@${commit:0:12})"
  fi

  src=${sources[$name]:-}
  if [ -z "$src" ] && [ "$fetch" = 1 ]; then
    src=$work/$name.json
    if ! curl -fsSL --retry 3 -o "$src" "https://raw.githubusercontent.com/$repo/$commit/$path"; then
      echo "FAIL [$name]: could not fetch $repo@$commit:$path" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  [ -n "$src" ] || continue
  if [ ! -f "$src" ]; then
    echo "FAIL [$name]: source file $src is missing" >&2
    failures=$((failures + 1))
    continue
  fi
  src_sha=$(sha_of "$src")
  if [ "$src_sha" != "$sha" ]; then
    echo "FAIL [$name]: the backend spec ($repo@${commit:0:12}:$path) is not what the lock records" >&2
    echo "      recorded sha256 $sha" >&2
    echo "      source   sha256 $src_sha" >&2
    failures=$((failures + 1))
  fi
  if ! cmp -s "$src" "$root/$mirror"; then
    echo "FAIL [$name]: $mirror differs from the backend spec $repo@${commit:0:12}:$path" >&2
    show_platforms "mirror " "$root/$mirror" "backend" "$src"
    failures=$((failures + 1))
  else
    echo "ok   [$name]: $mirror equals $repo@${commit:0:12}:$path byte for byte"
  fi
done <"$lock"

for name in "${!sources[@]}"; do
  if [ -z "${seen[$name]:-}" ]; then
    echo "FAIL: --source names '$name', which has no lock row" >&2
    failures=$((failures + 1))
  fi
done

if [ "$rows" -eq 0 ]; then
  echo "FAIL: scripts/spec-mirror.lock has no rows: nothing was checked" >&2
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  echo "check-spec-mirror: $failures failure(s)" >&2
  exit 1
fi
echo "check-spec-mirror: $rows mirror(s) ok"
