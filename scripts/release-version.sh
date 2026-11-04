#!/usr/bin/env bash
# release-version.sh — reads and checks the version for .github/workflows/release.yml.
#
# The version source is package.json `.version`. package-lock.json must carry
# the same string in both of its version fields, so the image, the lock and the
# tag can never disagree. The version must be MAJOR.MINOR.PATCH[-pre] with no
# `+build` part and no SNAPSHOT. A pull_request run is always refused: this
# workflow publishes, and publishing never happens from a PR.
#
# This script does not look at the ref. What a run publishes (main, release/X.Y,
# a beta tag vX.Y.Z-beta.N on main, a stable tag vX.Y.Z on release/X.Y), the
# image tags and the GitHub Release flags are decided by
# scripts/release-channel.sh from the version printed here.
#
# Inputs (environment): GITHUB_EVENT_NAME; optional REPO_ROOT
# (defaults to the directory above this script). Output: one `version=<v>` line
# on stdout. Exit 1 with a reason on stderr otherwise.
#
# Tested by scripts/release-version.test.sh (npm run test:release-version),
# which the release workflow's version job runs first.
set -euo pipefail

fail() {
  echo "release-version: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${REPO_ROOT:-"$script_dir/.."}
event=${GITHUB_EVENT_NAME:-}

[ -n "$event" ] || fail "GITHUB_EVENT_NAME is not set"

case "$event" in
  pull_request | pull_request_target)
    fail "refusing to publish from a $event run"
    ;;
esac

[ -f "$root/package.json" ] || fail "no package.json under $root"
[ -f "$root/package-lock.json" ] || fail "no package-lock.json under $root"

# One python call reads all three version fields; -I keeps it from importing
# anything out of the checkout.
versions=$(python3 -I - "$root/package.json" "$root/package-lock.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    pkg = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    lock = json.load(f)
root_pkg = (lock.get("packages") or {}).get("") or {}
print(pkg.get("version") or "")
print(lock.get("version") or "")
print(root_pkg.get("version") or "")
PY
) || fail "could not read package.json / package-lock.json"

pkg_version=$(printf '%s\n' "$versions" | sed -n 1p)
lock_version=$(printf '%s\n' "$versions" | sed -n 2p)
lock_root_version=$(printf '%s\n' "$versions" | sed -n 3p)

[ -n "$pkg_version" ] || fail "package.json has no version"
[ "$lock_version" = "$pkg_version" ] ||
  fail "package-lock.json version '$lock_version' does not match package.json '$pkg_version'"
[ "$lock_root_version" = "$pkg_version" ] ||
  fail "package-lock.json packages[\"\"].version '$lock_root_version' does not match package.json '$pkg_version'"

# MAJOR.MINOR.PATCH with an optional pre-release part. No `+build` metadata:
# OCI tags reject `+`. No SNAPSHOT: a published version is immutable.
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ "$pkg_version" =~ $semver ]] || fail "version '$pkg_version' is not MAJOR.MINOR.PATCH[-pre]"
case "$pkg_version" in
  *SNAPSHOT*) fail "version '$pkg_version' is a SNAPSHOT; never publish one" ;;
esac

printf 'version=%s\n' "$pkg_version"
