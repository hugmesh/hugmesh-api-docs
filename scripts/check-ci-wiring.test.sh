#!/usr/bin/env bash
# =============================================================================
# check-ci-wiring.test.sh — the guard THAT guards.
#
# check-ci-wiring.sh passing against the real .gitlab-ci.yml proves nothing on its
# own: a check that can never fail passes for free, which is precisely how the
# pen-test wiring went inert org-wide in the first place. So this battery breaks
# the CI file one way at a time, in a COPY, and asserts the guard catches each
# break. Every mutation is verified to have actually changed the file before its
# result is believed — a rewrite that silently matched nothing would otherwise
# look like a guard that failed to fire.
#
# Mutations are awk programs, not perl/python one-liners, so the battery needs
# nothing the plain shell runner does not already have. Runs in well under a
# second: no network, no Docker.
# =============================================================================
set -u
set +o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/.." && pwd)"
GUARD="${SELF_DIR}/check-ci-wiring.sh"
REAL_CI="${REPO_ROOT}/.gitlab-ci.yml"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
  local verdict
  verdict="$1"
  shift
  if [ "$verdict" = "pass" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$*"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$*" >&2
  fi
}

# --- leg 1: the real file must PASS ------------------------------------------
if bash "$GUARD" "$REAL_CI" "$REPO_ROOT" >"${WORK}/real.log" 2>&1; then
  report pass "real .gitlab-ci.yml passes the guard"
else
  report fail "real .gitlab-ci.yml FAILS the guard"
  cat "${WORK}/real.log" >&2
fi

# --- leg 2: a missing file must be a hard FATAL, not a pass -------------------
bash "$GUARD" "${WORK}/does-not-exist.yml" "$WORK" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
  report pass "absent CI file exits 2 (FATAL), never 0"
else
  report fail "absent CI file did not exit 2"
fi

# --- leg 3: the mutation battery ---------------------------------------------
# mutate <name> <awk program>: apply the program to a COPY of the real CI file,
# assert the copy actually differs, then assert the guard rejects it.
mutate() {
  local name
  name="$1"
  local prog
  prog="$2"
  local dir
  dir="${WORK}/m$((PASS + FAIL))"
  mkdir -p "$dir"
  awk "$prog" "$REAL_CI" > "${dir}/.gitlab-ci.yml"
  if cmp -s "$REAL_CI" "${dir}/.gitlab-ci.yml"; then
    report fail "mutation '${name}' did NOT change the file — the mutation itself is broken"
    return
  fi
  if bash "$GUARD" "${dir}/.gitlab-ci.yml" "$dir" >"${dir}/out.log" 2>&1; then
    report fail "mutation '${name}' was NOT detected (guard still passed)"
  else
    report pass "mutation '${name}' detected"
  fi
}

mutate "drop the generator include" '
  /^include:/ { skip = 1; next }
  skip && /^[^ \t#]/ { skip = 0 }
  !skip { print }
'

mutate "drop pentest from stages" '
  { sub(/^stages: \[lint, build, pentest\]$/, "stages: [lint, build]"); print }
'

mutate "delete the whole pentest:dast job" '
  /^pentest:dast:/ { skip = 1; next }
  skip && /^[^ \t#]/ { skip = 0 }
  !skip { print }
'

mutate "rebind pentest:dast to the wrong hidden job" '
  { sub(/extends: \.pentest-dast-baseline/, "extends: .pentest-dast-full"); print }
'

mutate "strip allow_failure from pentest:dast" '
  /^pentest:dast:/ { inblk = 1 }
  inblk && /^[^ \t#]/ && !/^pentest:dast:/ { inblk = 0 }
  inblk && /^  allow_failure: true$/ { next }
  { print }
'

mutate "strip allow_failure from pentest:sca" '
  /^pentest:sca:/ { inblk = 1 }
  inblk && /^[^ \t#]/ && !/^pentest:sca:/ { inblk = 0 }
  inblk && /^  allow_failure: true$/ { next }
  { print }
'

mutate "remove the harness fetch (job goes inert)" '
  /^    - git clone --depth 1 --branch main/ { next }
  { print }
'

mutate "point PENTEST_HARNESS_DIR where nothing is fetched" '
  /PENTEST_HARNESS_DIR:/ { print "    PENTEST_HARNESS_DIR: \"tests/pentest\""; next }
  { print }
'

mutate "drop the !reference splice (loses pinned nuclei + harness FATAL)" '
  /^    - !reference \[\.pentest-dast-base, before_script\]$/ { next }
  { print }
'

mutate "give a job an undeclared stage" '
  { sub(/^  stage: lint$/, "  stage: security"); print }
'

# --- leg 4: positive control for the VENDORED branch -------------------------
# The guard must accept the other legitimate shape (harness vendored at the
# template's default path, no PENTEST_HARNESS_DIR override), or it is not a
# check on reachability, just a check on one spelling.
VEND="${WORK}/vendored"
mkdir -p "${VEND}/tests/pentest"
printf '#!/usr/bin/env bash\n' > "${VEND}/tests/pentest/run-pentest.sh"
awk '
  /^  variables:$/ { drop = 1; next }
  drop && /PENTEST_HARNESS_DIR:/ { drop = 0; next }
  { print }
' "$REAL_CI" > "${VEND}/.gitlab-ci.yml"
if cmp -s "$REAL_CI" "${VEND}/.gitlab-ci.yml"; then
  report fail "vendored-shape control did not change the file"
elif bash "$GUARD" "${VEND}/.gitlab-ci.yml" "$VEND" >"${VEND}/out.log" 2>&1; then
  report pass "vendored-harness shape is accepted (positive control)"
else
  report fail "vendored-harness shape rejected — guard is over-fitted to the fetch shape"
  cat "${VEND}/out.log" >&2
fi

# --- leg 5: negative control for the VENDORED branch -------------------------
# ...and it must NOT accept that shape when the vendored harness is absent.
NOVEND="${WORK}/vendored-missing"
mkdir -p "$NOVEND"
cp "${VEND}/.gitlab-ci.yml" "${NOVEND}/.gitlab-ci.yml"
if bash "$GUARD" "${NOVEND}/.gitlab-ci.yml" "$NOVEND" >/dev/null 2>&1; then
  report fail "no PENTEST_HARNESS_DIR and no vendored harness was accepted — the inert case"
else
  report pass "no override + no vendored harness is rejected (negative control)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
