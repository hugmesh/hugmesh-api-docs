#!/usr/bin/env bash
# =============================================================================
# check-ci-wiring.sh — assert this repo's pen-test CI wiring is PRESENT and, more
# importantly, NOT INERT.
#
# WHY THIS EXISTS. The org-wide failure mode is not a missing job, it is a job
# that LOOKS like it scanned. `.pentest-dast-*` runs the shared harness from the
# INCLUDING repo's checkout (PENTEST_HARNESS_DIR, default `tests/pentest`). A repo
# that `include:`s the template but neither vendors nor fetches the harness gets a
# `pentest:dast` entry in the pipeline that dies having scanned nothing — and
# because the pen-test stage is deliberately `allow_failure: true`, that reads as
# a shrug next to a job name that reads as "DAST ran". 24 of 26 onboarded repos
# were in exactly that state (see memory hugmesh-dast-inert).
#
# So this guard does not just grep for job names. It asserts the harness is
# REACHABLE at the path the job will actually run from, and that overriding
# `before_script` has not silently dropped what the shared base does there.
#
# Pure bash + grep/sed: no YAML library, no network, no Docker — it must be
# runnable on the plain shell runner and in a pre-commit hook.
#
# Usage: check-ci-wiring.sh [CI_FILE] [REPO_ROOT]
#   CI_FILE   defaults to <repo>/.gitlab-ci.yml
#   REPO_ROOT defaults to the directory containing CI_FILE
# Both are parameters so the mutation battery (check-ci-wiring.test.sh) can point
# the guard at a deliberately-broken COPY. A guard that can only ever be run
# against the known-good file cannot be shown to detect anything.
# =============================================================================
set -u
# NEVER inherit pipefail here: `<producer> | grep` where grep exits early turns a
# found match into a failed pipeline (memory: pipefail-sigpipe-grep-q). Every grep
# below is drained to /dev/null and -q is never used, but belt and braces.
set +o pipefail

# bash 5.3 localises every name in a `local a=$1 b=$a` list BEFORE assigning, so
# `b` reads the (unset) local under `set -u`. One `local` per assignment, always.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_FILE="${1:-${SELF_DIR}/../.gitlab-ci.yml}"
REPO_ROOT="${2:-$(cd "$(dirname "${CI_FILE}")" && pwd)}"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  printf 'ok  : %s\n' "$*"
}

# Print the block belonging to top-level key $1: the key line, plus every
# following line that is indented, blank, or a comment, stopping at the next
# column-0 key. Comment lines are STRIPPED from the output — a check must never
# be satisfied by prose in a comment (that is how a "wired" claim survives the
# wiring being deleted).
block_of() {
  local key
  key="$1"
  awk -v k="$key" '
    index($0, k ":") == 1 { inblk = 1; next }
    inblk && /^[^[:space:]#]/ { inblk = 0 }
    inblk { sub(/[[:space:]]*#.*$/, ""); if ($0 ~ /[^[:space:]]/) print }
  ' "$CI_FILE"
}

# Whole file with comments stripped, for the structural greps.
code_only() {
  sed -e 's/[[:space:]]*#.*$//' "$CI_FILE"
}

if [ ! -f "$CI_FILE" ]; then
  printf 'FATAL: no CI file at %s\n' "$CI_FILE" >&2
  exit 2
fi

printf '== check-ci-wiring: %s\n' "$CI_FILE"

# -- 1. the shared pen-test template is included -------------------------------
INCLUDE_BLOCK="$(block_of include)"
if printf '%s\n' "$INCLUDE_BLOCK" | grep -F "hugmesh/hugmesh-generator" >/dev/null &&
   printf '%s\n' "$INCLUDE_BLOCK" | grep -F "/tests/pentest/ci/pentest-stage.gitlab-ci.yml" >/dev/null; then
  ok "includes the generator's pentest-stage template"
else
  fail "no include: of hugmesh/hugmesh-generator /tests/pentest/ci/pentest-stage.gitlab-ci.yml"
fi

# -- 2. the pentest stage is declared ------------------------------------------
if code_only | grep -E '^stages:.*\bpentest\b' >/dev/null; then
  ok "'pentest' is in stages:"
else
  fail "'pentest' missing from stages: — the extending jobs would not run"
fi

# -- 3/4. concrete jobs bind to the hidden templates, and stay non-blocking -----
# allow_failure: true on the pen-test stage is DELIBERATE POLICY, not an
# oversight: a finding must never red an onboarded repo's pipeline (the findings
# land in the archived scorecard/SARIF for triage). This guard asserts it is
# PRESENT so nobody "hardens" it away by accident.
check_pentest_job() {
  local job
  job="$1"
  local expect
  expect="$2"
  local shown
  shown="${expect//\\/}"
  local body
  body="$(block_of "$job")"
  if [ -z "$body" ]; then
    fail "job '$job' is absent"
    return
  fi
  if printf '%s\n' "$body" | grep -E "extends:[[:space:]]*${expect}([[:space:]]|$)" >/dev/null; then
    ok "$job extends $shown"
  else
    fail "$job does not extend $shown"
  fi
  if printf '%s\n' "$body" | grep -E '^[[:space:]]+allow_failure:[[:space:]]*true[[:space:]]*$' >/dev/null; then
    ok "$job keeps allow_failure: true (deliberate policy)"
  else
    fail "$job lost allow_failure: true — pen-test findings must not red the pipeline"
  fi
}

check_pentest_job "pentest:sca" '\.pentest-sca'
check_pentest_job "pentest:dast" '\.pentest-dast-baseline'

# -- 5. THE ANTI-INERTNESS CHECK: the harness is reachable ---------------------
# The base job runs `bash "${PENTEST_HARNESS_DIR}/run-pentest.sh"`. That resolves
# only if the repo vendors the harness at the default path, or the job fetches it
# to the path it then points PENTEST_HARNESS_DIR at. Anything else is a job that
# scans nothing.
DAST_BODY="$(block_of "pentest:dast")"
HARNESS_DIR="$(printf '%s\n' "$DAST_BODY" |
  sed -n 's/^[[:space:]]*PENTEST_HARNESS_DIR:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)"

if [ -f "${REPO_ROOT}/tests/pentest/run-pentest.sh" ] && [ -z "$HARNESS_DIR" ]; then
  ok "harness is VENDORED at tests/pentest/run-pentest.sh (template default)"
elif [ -n "$HARNESS_DIR" ]; then
  # The fetch must land at a path the harness dir sits under. Compare on the
  # literal text after stripping the CI_PROJECT_DIR prefix both sides share.
  HARNESS_REL="${HARNESS_DIR#\$\{CI_PROJECT_DIR\}/}"
  HARNESS_TOP="${HARNESS_REL%%/*}"
  if [ -z "$HARNESS_TOP" ]; then
    fail "PENTEST_HARNESS_DIR ('$HARNESS_DIR') has no fetchable path component"
  elif printf '%s\n' "$DAST_BODY" | grep -E "git clone.+hugmesh-generator" >/dev/null &&
       printf '%s\n' "$DAST_BODY" | grep -F "$HARNESS_TOP" | grep -F "git clone" >/dev/null; then
    ok "harness is FETCHED at CI time into ${HARNESS_TOP}/ and PENTEST_HARNESS_DIR points inside it"
  else
    fail "pentest:dast sets PENTEST_HARNESS_DIR='$HARNESS_DIR' but never clones the harness into ${HARNESS_TOP}/ — the job would run no scan"
  fi
else
  fail "pentest:dast neither vendors tests/pentest/run-pentest.sh nor fetches the harness — the job would die on a bare exit 127 having scanned nothing"
fi

# -- 6. an overridden before_script must re-splice the base's ------------------
# `extends:` REPLACES arrays; it does not concatenate them. A job that overrides
# before_script to add its harness fetch silently drops what .pentest-dast-base
# does there: the "no harness" FATAL and the pinned-nuclei install that makes
# `run-pentest.sh --nuclei` more than a self-skip. `!reference` splices it back.
if printf '%s\n' "$DAST_BODY" | grep -E '^[[:space:]]+before_script:' >/dev/null; then
  if printf '%s\n' "$DAST_BODY" | grep -F '!reference [.pentest-dast-base, before_script]' >/dev/null; then
    ok "pentest:dast re-splices the base before_script (keeps the harness FATAL + pinned nuclei)"
  else
    fail "pentest:dast overrides before_script without '!reference [.pentest-dast-base, before_script]' — the pinned-nuclei install and the missing-harness FATAL are dropped"
  fi
else
  ok "pentest:dast does not override before_script (base before_script intact)"
fi

# -- 7. every job's stage is declared ------------------------------------------
# A job whose `stage:` is not in `stages:` is a hard pipeline error, and it is an
# easy one to introduce when adding a stage list to a previously single-stage file.
DECLARED="$(code_only | sed -n 's/^stages:[[:space:]]*\[\(.*\)\].*/\1/p' | tr -d ' ' | tr ',' '\n')"
if [ -z "$DECLARED" ]; then
  DECLARED="$(block_of stages | sed -n 's/^[[:space:]]*-[[:space:]]*//p')"
fi
UNDECLARED=0
while read -r used; do
  [ -n "$used" ] || continue
  if ! printf '%s\n' "$DECLARED" | grep -Fx "$used" >/dev/null; then
    fail "a job declares stage '$used', which is not in stages:"
    UNDECLARED=$((UNDECLARED + 1))
  fi
done <<< "$(code_only | sed -n 's/^[[:space:]]\{1,\}stage:[[:space:]]*//p' | sort -u)"
[ "$UNDECLARED" -eq 0 ] && ok "every job's stage: is declared in stages:"

# -- 8. the pen-test jobs are not gated behind a blocking earlier stage --------
# Stage ordering is itself a gate: `pentest` runs only if every earlier stage
# SUCCEEDS. build:image is (correctly) not allow_failure, so under plain stage
# ordering a registry-login or docker-build failure on the default branch removes
# BOTH security jobs from the pipeline — silently, because a job that never ran
# leaves nothing in the MR widget to notice. That is the same "looks like it
# scanned" class this guard exists for, arriving from the other direction. A
# pen-test job is safe if it declares `needs:` (stage ordering no longer gates
# it) OR if nothing that can fail runs earlier. The generator holds the same
# invariant over its own build:images job (lint:image-builder-always-on).
stage_index() {                       # <stage-name> -> position in stages:, or -1
  local want
  want="$1"
  local i
  i=0
  local s
  while read -r s; do
    [ -n "$s" ] || continue
    if [ "$s" = "$want" ]; then printf '%s\n' "$i"; return; fi
    i=$((i + 1))
  done <<< "$DECLARED"
  printf '%s\n' "-1"
}

# Top-level job keys: a column-0 name whose line is just `name:`. `stages:` and
# the other value-carrying keys never match; the block-shaped reserved words are
# filtered by name.
job_names() {
  code_only | sed -n 's/^\([A-Za-z][A-Za-z0-9_.:-]*\):[[:space:]]*$/\1/p'
}

PENTEST_IDX="$(stage_index pentest)"
BLOCKERS=""
while read -r job; do
  [ -n "$job" ] || continue
  case "$job" in
    include|variables|default|workflow|cache|before_script|after_script|image|services) continue ;;
  esac
  JOB_BODY="$(block_of "$job")"
  JOB_STAGE="$(printf '%s\n' "$JOB_BODY" | sed -n 's/^[[:space:]]*stage:[[:space:]]*//p' | head -1)"
  [ -n "$JOB_STAGE" ] || JOB_STAGE="test"
  JOB_IDX="$(stage_index "$JOB_STAGE")"
  [ "$JOB_IDX" -ge 0 ] || continue                       # undeclared: check 7 owns it
  [ "$JOB_IDX" -lt "$PENTEST_IDX" ] || continue          # not earlier: cannot gate
  if printf '%s\n' "$JOB_BODY" | grep -E '^[[:space:]]+allow_failure:[[:space:]]*true[[:space:]]*$' >/dev/null; then
    continue                                             # earlier, but cannot fail the stage
  fi
  BLOCKERS="${BLOCKERS} ${job}"
done <<< "$(job_names)"

for pjob in pentest:sca pentest:dast; do
  PJOB_BODY="$(block_of "$pjob")"
  [ -n "$PJOB_BODY" ] || continue                        # absence is check 3/4's finding
  if printf '%s\n' "$PJOB_BODY" | grep -E '^[[:space:]]+needs:' >/dev/null; then
    ok "$pjob declares needs: — an earlier stage failing cannot delete the scan"
  elif [ -z "${BLOCKERS// /}" ]; then
    ok "$pjob is ungated: no job that can fail runs in an earlier stage"
  else
    fail "$pjob declares no needs:, so it runs only if${BLOCKERS} succeed — a failed build would silently remove the security scan from the pipeline"
  fi
done

# -----------------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d check(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall checks passed\n'
