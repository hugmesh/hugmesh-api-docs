#!/usr/bin/env bash
# check-spec-mirror.test.sh — exercises scripts/check-spec-mirror.sh against
# COPIES of this repo's mirrors and lock, each broken in one way, and asserts
# every one is refused. The first leg is the real tree, which must pass. Each
# mutation is checked to have actually changed the file it targets, so a
# mutation that silently did nothing cannot read as "the guard caught it".
#
# Offline: no network, no npm install. Needs bash, sha256sum, cmp, python3.
#
#   bash scripts/check-spec-mirror.test.sh        (npm run test:spec-mirror)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
guard="$here/check-spec-mirror.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
failures=0
mirror=src/assets/specs/openapi-admin.json

# copy_tree <dir>: the lock and every mirror it names, at the same paths.
copy_tree() {
  local dir=$1 line name m
  mkdir -p "$dir/scripts"
  cp "$repo/scripts/spec-mirror.lock" "$dir/scripts/spec-mirror.lock"
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    read -r name m _ <<<"$line"
    mkdir -p "$dir/$(dirname "$m")"
    cp "$repo/$m" "$dir/$m"
  done <"$repo/scripts/spec-mirror.lock"
}

# mutate <file> <old> <new>: replace the first <old> with <new> and REQUIRE
# that the bytes changed.
mutate() {
  local file=$1 old=$2 new=$3 before
  before=$(sha256sum "$file" | cut -d' ' -f1)
  python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  if [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$before" ]; then
    echo "BATTERY BUG: mutation left $file unchanged: $old" >&2
    exit 2
  fi
}

# expect <ok|fail> <leg name> <dir> [guard args...]
# Set WANT_MSG to also require that text in the guard's output, so a leg is
# only green when the RIGHT check refused it (several checks overlap).
expect() {
  local want=$1 name=$2 dir=$3 rc=0 msg_ok=1
  shift 3
  bash "$guard" --root "$dir" "$@" >"$work/out" 2>&1 || rc=$?
  if [ -n "${WANT_MSG:-}" ] && ! grep -qF -- "$WANT_MSG" "$work/out"; then
    msg_ok=0
  fi
  if [ "$msg_ok" = 1 ] && { { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -eq 1 ]; }; }; then
    pass=$((pass + 1))
    echo "pass: $name"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (wanted $want${WANT_MSG:+ saying '$WANT_MSG'}, guard exit $rc)" >&2
    sed 's/^/    | /' "$work/out" >&2
  fi
}

# leg <name>: a fresh copy of the tree for one mutation.
leg() { rm -rf "$work/t"; copy_tree "$work/t"; echo "$work/t"; }

# The admin row as the lock records it, so a re-sync needs no battery edit.
read -r _ _ _ admin_commit _ admin_sha < <(grep '^admin ' "$repo/scripts/spec-mirror.lock")

# A backend source identical to the real mirror (the lock records its hash).
cp "$repo/$mirror" "$work/backend.json"

# 0. The real tree passes, offline and against an identical backend file.
expect ok "real tree (offline)" "$repo"
expect ok "real tree vs identical backend" "$repo" --source "admin=$work/backend.json"

# 1. The platform field put back to the pre-sync six-board pattern.
t=$(leg)
mutate "$t/$mirror" '"enum" : [ "x86", "rpi5", "frite", "jetson", "orangepi5", "orangepizero2", "orangepizero2w", "orangepizero3", "orangepi3-lts", "orangepi4-lts" ]' \
  '"pattern" : "x86|rpi5|frite|jetson|orangepi5|orangepizero2"'
expect fail "hardwareClass reverted to the six-board pattern" "$t"
WANT_MSG="differs from the backend spec" expect fail "hardwareClass reverted, vs backend" "$t" --source "admin=$work/backend.json"

# 2. One platform dropped from the enum.
t=$(leg)
mutate "$t/$mirror" ', "orangepi4-lts" ]' ' ]'
expect fail "one platform dropped from the enum" "$t"

# 3. A partial re-sync: only the platform hunk is current, the rest is stale
#    (the mesh-token endpoints are removed again).
t=$(leg)
mutate "$t/$mirror" '"/bff/admin/mesh-tokens"' '"/bff/admin/mesh-tokens-stale"'
expect fail "partial re-sync (other hunks stale)" "$t"

# 4. The lock row's sha256 edited to a hash nobody computed.
t=$(leg)
mutate "$t/scripts/spec-mirror.lock" " $admin_sha" " $(printf '0%.0s' {1..64})"
WANT_MSG="is not the copy of" expect fail "lock sha256 edited" "$t"

# 5. Mirror and lock both moved to a hand-edited file: the offline check is
#    satisfied, so only the backend comparison can refuse it.
t=$(leg)
mutate "$t/$mirror" '"orangepi4-lts" ]' '"orangepi4-lts", "handmade" ]'
newsha=$(sha256sum "$t/$mirror" | cut -d' ' -f1)
mutate "$t/scripts/spec-mirror.lock" "$admin_sha" "$newsha"
expect ok "hand edit with a re-hashed lock passes OFFLINE (documented limit)" "$t"
WANT_MSG="differs from the backend spec" expect fail "hand edit with a re-hashed lock, vs backend" "$t" --source "admin=$work/backend.json"

# 6. The backend moved on (one more platform) but the mirror did not.
t=$(leg)
cp "$work/backend.json" "$work/backend-newer.json"
mutate "$work/backend-newer.json" '"orangepi4-lts" ]' '"orangepi4-lts", "riscv64" ]'
WANT_MSG="differs from the backend spec" expect fail "backend gained a platform, mirror did not" "$t" --source "admin=$work/backend-newer.json"
WANT_MSG="is not what the lock records" expect fail "backend gained a platform: lock names the old file" "$t" --source "admin=$work/backend-newer.json"

# 7. Fail closed: no mirror, no lock, an empty lock, a malformed row, an
#    unknown --source name, a missing source file.
t=$(leg); rm "$t/$mirror"
expect fail "mirror missing" "$t"
t=$(leg); rm "$t/scripts/spec-mirror.lock"
expect fail "lock missing" "$t"
t=$(leg); grep '^#' "$repo/scripts/spec-mirror.lock" >"$t/scripts/spec-mirror.lock"
expect fail "lock with no rows" "$t"
t=$(leg)
mutate "$t/scripts/spec-mirror.lock" " $admin_commit " " main "
WANT_MSG="malformed lock row" expect fail "lock row with a branch name for a commit" "$t"
t=$(leg)
mutate "$t/scripts/spec-mirror.lock" " $admin_sha" " ${admin_sha:0:12}"
WANT_MSG="malformed lock row" expect fail "lock row with a truncated sha256" "$t"
t=$(leg)
mutate "$t/scripts/spec-mirror.lock" " hugmesh/hugmesh-admin-bff-api " " example.com/hugmesh/hugmesh-admin-bff-api "
WANT_MSG="malformed lock row" expect fail "lock row whose repo is not OWNER/REPO" "$t"
t=$(leg)
mutate "$t/scripts/spec-mirror.lock" " $admin_sha" " $admin_sha extra"
WANT_MSG="malformed lock row" expect fail "lock row with an extra column" "$t"
t=$(leg)
expect fail "--source for a name with no lock row" "$t" --source "mod=$work/backend.json"
WANT_MSG="source file" expect fail "--source file missing" "$t" --source "admin=$work/does-not-exist.json"

echo "check-spec-mirror battery: $pass passed, $failures failed"
[ "$failures" -eq 0 ]
