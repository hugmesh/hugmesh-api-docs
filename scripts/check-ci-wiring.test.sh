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

# seed_scripts <dir>: make a scratch copy look like a real checkout.
# Check 9 asserts the CI file names a battery script that EXISTS on disk, so a
# scratch dir holding nothing but a .gitlab-ci.yml would fail every mutation for
# a reason that has nothing to do with the mutation — a battery that reports
# "detected" for the wrong reason is not evidence. Every scratch tree therefore
# carries the two scripts.
seed_scripts() {
  local dir
  dir="$1"
  mkdir -p "${dir}/scripts"
  cp "$GUARD" "${dir}/scripts/check-ci-wiring.sh"
  cp "${SELF_DIR}/check-ci-wiring.test.sh" "${dir}/scripts/check-ci-wiring.test.sh"
}

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
  seed_scripts "$dir"
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

# The pen-test jobs' `needs: []` is load-bearing: without it, stage ordering puts
# them behind build:image, which is not allow_failure, so a failed image build on
# the default branch deletes both security jobs from the pipeline.
mutate "remove needs: [] from the pen-test jobs (a failed build then deletes the scan)" '
  /^pentest:(sca|dast):/ { inblk = 1 }
  inblk && /^[^ \t#]/ && !/^pentest:(sca|dast):/ { inblk = 0 }
  inblk && /^  needs: \[\]$/ { next }
  { print }
'

# --- the mutations that an earlier version of the guard did NOT catch ---------
# Each of these three leaves pentest:dast 100% inert at runtime, and each of them
# passed the substring-shaped checks the guard shipped with. They are the nearest
# neighbours of the real bug, which is exactly where a guard has to fire.
mutate "clone lands beside PENTEST_HARNESS_DIR, not at it" '
  { if ($0 ~ /git clone --depth 1/) sub(/\/\.pentest-harness"$/, "/.pentest-harness-old\""); print }
'

mutate "splice the base before_script BEFORE the fetch (FATAL fires on an absent tree)" '
  /^    - !reference \[\.pentest-dast-base, before_script\]$/ { next }
  /^  before_script:$/ { print; print "    - !reference [.pentest-dast-base, before_script]"; next }
  { print }
'

mutate "point PENTEST_HARNESS_DIR at a wrong subpath inside the fetched clone" '
  { sub(/\.pentest-harness\/tests\/pentest"$/, ".pentest-harness/tests/security\""); print }
'

mutate "skew the harness clone off the ref the include: pins" '
  { if ($0 ~ /git clone --depth 1/) sub(/--branch main/, "--branch v1"); print }
'

# `extends:` REPLACES arrays. Restating two of the base's three rules looks like a
# faithful copy and deletes SCA from every scheduled pipeline.
mutate "restate the base rules on pentest:sca (drops the scheduled pipeline)" '
  /^pentest:sca:/ {
    print
    print "  rules:"
    print "    - if: $CI_PIPELINE_SOURCE == \"merge_request_event\""
    print "    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH"
    next
  }
  { print }
'

# The release job is subject to the same rule as the security jobs: this file put
# a lint stage in front of build, so without an explicit needs: a red guard would
# silently swallow the image build (and the ArgoCD input that tracks its tag).
mutate "remove needs: [] from build:image (a red lint stage then deletes the release job)" '
  /^build:image:/ { inblk = 1 }
  inblk && /^[^ \t#]/ && !/^build:image:/ { inblk = 0 }
  inblk && /^  needs: \[\]$/ { next }
  { print }
'

# --- the mutations that retire the GUARD rather than the wiring ---------------
# Checks 1-8 only matter if something runs them. None of these five edits touches
# a pen-test job, and before checks 9-11 existed every one of them left the guard
# printing "ok" on its way to scanning nothing.
mutate "allow_failure on the wiring guard job (the guard goes advisory)" '
  /^lint:ci-wiring:/ { print; print "  allow_failure: true"; next }
  { print }
'

mutate "when: manual on the wiring guard job (nothing checks an MR)" '
  /^lint:ci-wiring:/ { print; print "  when: manual"; next }
  { print }
'

mutate "the lint job runs the guard but not the battery that proves it can fail" '
  { sub(/check-ci-wiring\.test\.sh/, "check-ci-wiring.sh"); print }
'

mutate "the wiring guard job deleted outright" '
  /^lint:ci-wiring:/ { skip = 1; next }
  skip && /^[^ \t#]/ { skip = 0 }
  !skip { print }
'

mutate "the lint job runs a battery that is not in the repo" '
  { sub(/scripts\/check-ci-wiring\.test\.sh/, "ci/check-ci-wiring.test.sh"); print }
'

# `allow_failure: true` makes a FINDING non-blocking (policy). `when: manual`
# makes the SCAN optional, which is a different thing wearing the same clothes:
# the pipeline still shows a `pentest:dast` entry.
mutate "when: manual on pentest:dast (a scan nobody clicks is not a scan)" '
  /^pentest:dast:/ { print; print "  when: manual"; next }
  { print }
'

mutate "when: manual on pentest:sca" '
  /^pentest:sca:/ { print; print "  when: manual"; next }
  { print }
'

# The fetch is the one place this pipeline pulls executable code from off-repo and
# runs it on a privileged runner.
mutate "harness cloned from a literal foreign host instead of this pipeline org" '
  { if ($0 ~ /git clone --depth 1/) sub(/\$\{ORG_BASE\}/, "https://example.invalid/attacker"); print }
'

mutate "harness cloned from a same-org NEIGHBOUR of the generator" '
  { if ($0 ~ /git clone --depth 1/) sub(/hugmesh-generator\.git/, "hugmesh-generator-fork.git"); print }
'

mutate "harness cloned from an undefined variable (origin not pinned to this server)" '
  { if ($0 ~ /git clone --depth 1/) sub(/\$\{ORG_BASE\}/, "${MIRROR_BASE}"); print }
'

# --- leg 4: positive control for the VENDORED branch -------------------------
# The guard must accept the other legitimate shape (harness vendored at the
# template's default path, no PENTEST_HARNESS_DIR override), or it is not a
# check on reachability, just a check on one spelling.
VEND="${WORK}/vendored"
mkdir -p "${VEND}/tests/pentest"
seed_scripts "$VEND"
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
seed_scripts "$NOVEND"
cp "${VEND}/.gitlab-ci.yml" "${NOVEND}/.gitlab-ci.yml"
if bash "$GUARD" "${NOVEND}/.gitlab-ci.yml" "$NOVEND" >/dev/null 2>&1; then
  report fail "no PENTEST_HARNESS_DIR and no vendored harness was accepted — the inert case"
else
  report pass "no override + no vendored harness is rejected (negative control)"
fi

# --- leg 6: positive control for check 8 -------------------------------------
# `needs:` is one of TWO ways to be ungated; the other is having nothing that can
# fail run earlier. Without this control, check 8 would just be "grep for needs:"
# and would wrongly red a repo whose pen-test stage genuinely runs first.
UNGATED="${WORK}/ungated"
mkdir -p "$UNGATED"
seed_scripts "$UNGATED"
awk '
  { sub(/^stages: \[lint, build, pentest\]$/, "stages: [pentest, lint, build]") }
  /^pentest:(sca|dast):/ { inblk = 1 }
  inblk && /^[^ \t#]/ && !/^pentest:(sca|dast):/ { inblk = 0 }
  inblk && /^  needs: \[\]$/ { next }
  { print }
' "$REAL_CI" > "${UNGATED}/.gitlab-ci.yml"
if cmp -s "$REAL_CI" "${UNGATED}/.gitlab-ci.yml"; then
  report fail "ungated-shape control did not change the file"
elif bash "$GUARD" "${UNGATED}/.gitlab-ci.yml" "$UNGATED" >"${UNGATED}/out.log" 2>&1; then
  report pass "pen-test stage running first, with no needs:, is accepted (positive control)"
else
  report fail "a pen-test stage that nothing precedes was rejected — check 8 is over-fitted to needs:"
  cat "${UNGATED}/out.log" >&2
fi

# --- leg 7: positive control for check 11 -------------------------------------
# The org's other fetch-shaped repo (hugmesh-admin-ui) builds the clone url from
# the CI_SERVER_* triple + CI_JOB_TOKEN rather than from CI_REPOSITORY_URL. That
# is equally CI-derived and must pass, or check 11 is not "the source is pinned to
# this pipeline's server", just "the source is spelled ${ORG_BASE}".
SERVERVAR="${WORK}/serverurl"
mkdir -p "$SERVERVAR"
seed_scripts "$SERVERVAR"
awk '
  /^    - ORG_BASE=/ { next }
  {
    if ($0 ~ /git clone --depth 1/) {
      sub(/"\$\{ORG_BASE\}\/hugmesh-generator\.git"/,
          "\"${CI_SERVER_PROTOCOL}://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}:${CI_SERVER_PORT}/hugmesh/hugmesh-generator.git\"")
    }
    print
  }
' "$REAL_CI" > "${SERVERVAR}/.gitlab-ci.yml"
if cmp -s "$REAL_CI" "${SERVERVAR}/.gitlab-ci.yml"; then
  report fail "CI_SERVER_* clone-shape control did not change the file"
elif bash "$GUARD" "${SERVERVAR}/.gitlab-ci.yml" "$SERVERVAR" >"${SERVERVAR}/out.log" 2>&1; then
  report pass "a clone url built from CI_SERVER_*/CI_JOB_TOKEN is accepted (positive control)"
else
  report fail "the CI_SERVER_* clone shape was rejected — check 11 is over-fitted to \${ORG_BASE}"
  cat "${SERVERVAR}/out.log" >&2
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
