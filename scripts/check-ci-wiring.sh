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
# REACHABLE at the path the job will actually run from — comparing the fetch
# destination to PENTEST_HARNESS_DIR exactly, not as a substring — that overriding
# `before_script` has not silently dropped what the shared base does there AND
# splices it back after the fetch rather than before it, that template and harness
# are pinned to the same ref, that `rules:` is inherited rather than restated
# (`extends:` REPLACES arrays), and that no job in this file is gated behind an
# earlier stage implicitly.
#
# It then asserts the same thing about ITSELF (checks 9-11), because everything
# above is only worth the paper it is printed on if something still RUNS it and
# the scans it guards still RUN unattended. Five edits that touch no pen-test job
# at all — allow_failure or `when: manual` on the job that runs this battery,
# pointing that job at the guard instead of the battery, deleting the job, naming
# a battery that is not in the repo — each retired the whole apparatus while every
# check above kept printing "ok". So did `when: manual` on a pen-test job itself
# (allow_failure makes a FINDING non-blocking; `when: manual` makes the SCAN
# optional and still shows the job), and so did swapping the harness fetch's
# CI-derived origin for a literal host.
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

# `when: manual`, `when: "manual"` and `when: 'manual'` are the SAME YAML. The
# first form of checks 9 and 10 grepped for the bare word, so QUOTING it — one
# keystroke, nothing a reviewer would stop on — retired the guard job and either
# pen-test job while every check kept printing "ok". Same class as the mutations
# those checks were written to catch, one spelling away.
has_gated_when() {
  printf '%s\n' "$1" |
    grep -E "^[[:space:]]+when:[[:space:]]*['\"]?(manual|never|delayed)['\"]?[[:space:]]*\$" >/dev/null
}

# `allow_failure: true` is one spelling of "this job cannot red the pipeline".
# GitLab documents another — `allow_failure:` with an `exit_codes:` map — and the
# battery exits 1, which is exactly the status that form would excuse. Checks 3/4
# assert the PRESENCE of the policy `true` on the pen-test jobs, so they stay
# strict; check 9 asserts its ABSENCE on the guard job, so it has to reject every
# spelling but an explicit `false`.
has_allow_failure_true() {
  printf '%s\n' "$1" | grep -E '^[[:space:]]+allow_failure:[[:space:]]*true[[:space:]]*$' >/dev/null
}
has_any_allow_failure() {
  printf '%s\n' "$1" | grep -E '^[[:space:]]+allow_failure:' >/dev/null || return 1
  if printf '%s\n' "$1" | grep -E '^[[:space:]]+allow_failure:[[:space:]]*false[[:space:]]*$' >/dev/null; then
    return 1
  fi
  return 0
}

# The lines under a job's `<key>:` list, in order — every line indented deeper
# than the key, so a rules: entry's continuation (`when:`, `changes:`) comes with
# it. Check 9 needs `script:` in ORDER (what runs BEFORE the battery is what
# decides whether the battery runs at all) and `rules:` as a set (what the job
# actually runs ON).
list_items() {
  printf '%s\n' "$1" | awk -v k="$2" '
    !inl && $0 ~ "^[[:space:]]+" k ":[[:space:]]*$" {
      match($0, /^[[:space:]]*/); keyind = RLENGTH; inl = 1; next
    }
    inl {
      match($0, /^[[:space:]]*/)
      if (RLENGTH > keyind) { print; next }
      inl = 0
    }
  '
}

# The POSITIONAL arguments of a `git clone` command line, one per line: quotes
# honoured, flags and the values of value-taking flags dropped.
#
# Parsing them positionally rather than with a fixed-shape regex is not tidiness.
# The earlier form anchored BOTH the source and the destination to end-of-line,
# so appending a perfectly benign `--quiet` made this file report three FAILs —
# "clones nothing" (check 5), "'' is not hugmesh-generator" and "could not read
# the SOURCE url" (check 11) — all pointing review at a problem that is not
# there. A guard whose false positives are one flag away is a guard people learn
# to click past, which is the failure mode it exists to prevent.
clone_args() {
  printf '%s\n' "$1" | awk '
    {
      sub(/^.*git[[:space:]]+clone[[:space:]]+/, "")
      n = 0; cur = ""; inq = 0; started = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\"") { inq = !inq; started = 1; continue }
        if (!inq && (c == " " || c == "\t")) {
          if (started) { tok[++n] = cur; cur = ""; started = 0 }
          continue
        }
        cur = cur c; started = 1
      }
      if (started) tok[++n] = cur
      skip = 0
      for (i = 1; i <= n; i++) {
        if (skip) { skip = 0; continue }
        t = tok[i]
        if (substr(t, 1, 1) == "-") {
          if (t ~ /^(-b|-o|-u|-c|-j|--branch|--depth|--origin|--reference|--reference-if-able|--separate-git-dir|--template|--config|--jobs|--filter|--upload-pack|--shallow-since|--shallow-exclude|--server-option)$/) skip = 1
          continue
        }
        print t
      }
    }'
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

# The ref and the template path the include: names are load-bearing for checks 5
# and 6b below: the harness is fetched from the SAME repo at the SAME ref, and it
# lives at the template path's grandparent (/tests/pentest/ci/<file> -> tests/pentest).
INC_REF="$(printf '%s\n' "$INCLUDE_BLOCK" |
  sed -n "s/^[[:space:]]*ref:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]*\).*/\1/p" | head -1)"
INC_FILE="$(printf '%s\n' "$INCLUDE_BLOCK" |
  sed -n "s/^[[:space:]]*file:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]*\).*/\1/p" | head -1)"
TPL_HARNESS="tests/pentest"
case "$INC_FILE" in
  */*/*) TPL_CI_DIR="${INC_FILE%/*}"; TPL_HARNESS="${TPL_CI_DIR%/*}"; TPL_HARNESS="${TPL_HARNESS#/}" ;;
esac
[ -n "$TPL_HARNESS" ] || TPL_HARNESS="tests/pentest"

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
  if has_allow_failure_true "$body"; then
    ok "$job keeps allow_failure: true (deliberate policy)"
  else
    fail "$job lost allow_failure: true — pen-test findings must not red the pipeline"
  fi
}

check_pentest_job "pentest:sca" '\.pentest-sca'
check_pentest_job "pentest:dast" '\.pentest-dast-baseline'

# -- 5. THE ANTI-INERTNESS CHECK: the harness is reachable ---------------------
# The base job runs `bash "${PENTEST_HARNESS_DIR}/run-pentest.sh"`. That resolves
# only if the repo vendors the harness at that path, or the job fetches it to the
# path it then points PENTEST_HARNESS_DIR at. Anything else is a job that scans
# nothing.
#
# "Points inside it" is NOT a substring question, and an earlier version of this
# check asked it as one (`grep -F "$HARNESS_TOP" | grep -F "git clone"`). Two
# one-line, entirely ordinary edits defeated that form while leaving the job 100%
# inert, with the guard printing "ok":
#   * clone into `.pentest-harness-old` and leave PENTEST_HARNESS_DIR alone — the
#     harness lands somewhere the job never looks;
#   * point PENTEST_HARNESS_DIR at `.pentest-harness/tests/security` — a plausible
#     edit if the generator ever moved the harness.
# So the fetch destination is EXTRACTED and compared exactly, and the sub-path
# inside the clone is compared against the harness root the include: itself names
# (/tests/pentest/ci/pentest-stage.gitlab-ci.yml -> tests/pentest) — the only path
# in this file that is known to exist in the cloned tree.
DAST_BODY="$(block_of "pentest:dast")"
HARNESS_DIR="$(printf '%s\n' "$DAST_BODY" |
  sed -n 's/^[[:space:]]*PENTEST_HARNESS_DIR:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)"
HARNESS_REL="${HARNESS_DIR#\$\{CI_PROJECT_DIR\}/}"

# The clone line, its position in the job body (check 6 needs the order), and the
# destination it writes to (its last quoted argument).
CLONE_LINE="$(printf '%s\n' "$DAST_BODY" | grep -n 'git clone' | head -1)"
CLONE_LNO="${CLONE_LINE%%:*}"
CLONE_POS="$(clone_args "$CLONE_LINE")"
CLONE_SRC="$(printf '%s\n' "$CLONE_POS" | sed -n '1p')"
CLONE_DEST="$(printf '%s\n' "$CLONE_POS" | sed -n '2p')"
CLONE_REL="${CLONE_DEST#\$\{CI_PROJECT_DIR\}/}"
CLONE_BRANCH="$(printf '%s\n' "$CLONE_LINE" |
  sed -n 's/^.*git clone .*--branch[[:space:]]\{1,\}"\{0,1\}\([^[:space:]"]*\).*/\1/p')"

if [ -z "$HARNESS_DIR" ]; then
  if [ -f "${REPO_ROOT}/${TPL_HARNESS}/run-pentest.sh" ]; then
    ok "harness is VENDORED at ${TPL_HARNESS}/run-pentest.sh (template default)"
  else
    fail "pentest:dast neither vendors ${TPL_HARNESS}/run-pentest.sh nor fetches the harness — the job would die on a bare exit 127 having scanned nothing"
  fi
elif [ -f "${REPO_ROOT}/${HARNESS_REL}/run-pentest.sh" ]; then
  ok "harness is VENDORED at ${HARNESS_REL}/run-pentest.sh"
elif [ -z "$CLONE_DEST" ]; then
  fail "pentest:dast sets PENTEST_HARNESS_DIR='$HARNESS_DIR', vendors nothing there, and clones nothing — the job would run no scan"
elif ! printf '%s\n' "$DAST_BODY" | grep -E "git clone.+hugmesh-generator" >/dev/null; then
  fail "pentest:dast's clone is not of hugmesh-generator, so the harness would not be at '$HARNESS_REL' — the job would run no scan"
elif [ "$HARNESS_REL" = "${CLONE_REL}/${TPL_HARNESS}" ]; then
  ok "harness is FETCHED into ${CLONE_REL}/ and PENTEST_HARNESS_DIR is exactly ${CLONE_REL}/${TPL_HARNESS}"
else
  fail "pentest:dast clones into '${CLONE_REL}' but PENTEST_HARNESS_DIR is '${HARNESS_REL}' — expected exactly '${CLONE_REL}/${TPL_HARNESS}' (the harness root the include: names). The harness would not be where the job looks, and the job would run no scan."
fi

# -- 6. an overridden before_script must re-splice the base's, AFTER the fetch --
# `extends:` REPLACES arrays; it does not concatenate them. A job that overrides
# before_script to add its harness fetch silently drops what .pentest-dast-base
# does there: the "no harness" FATAL and the pinned-nuclei install that makes
# `run-pentest.sh --nuclei` more than a self-skip. `!reference` splices it back.
#
# ORDER IS PART OF THE INVARIANT, not a style preference. The base's first act is
# to FATAL if ${PENTEST_HARNESS_DIR}/run-pentest.sh is missing. Spliced above the
# fetch — the conventional place to put a base splice, and a one-line edit anyone
# tidying this file might make — that FATAL fires against a directory that has not
# been cloned yet, exits 1, and (the stage being allow_failure) reads as a shrug.
if printf '%s\n' "$DAST_BODY" | grep -E '^[[:space:]]+before_script:' >/dev/null; then
  REF_LINE="$(printf '%s\n' "$DAST_BODY" | grep -Fn '!reference [.pentest-dast-base, before_script]' | head -1)"
  REF_LNO="${REF_LINE%%:*}"
  if [ -z "$REF_LINE" ]; then
    fail "pentest:dast overrides before_script without '!reference [.pentest-dast-base, before_script]' — the pinned-nuclei install and the missing-harness FATAL are dropped"
  elif [ -z "$CLONE_LNO" ]; then
    ok "pentest:dast re-splices the base before_script (keeps the harness FATAL + pinned nuclei)"
  elif [ "$REF_LNO" -gt "$CLONE_LNO" ]; then
    ok "pentest:dast re-splices the base before_script AFTER the fetch (the harness FATAL runs against a tree that exists)"
  else
    fail "pentest:dast splices the base before_script BEFORE the harness fetch — the base's missing-harness FATAL fires against a directory that has not been cloned yet, exits 1, and the job scans nothing"
  fi
else
  ok "pentest:dast does not override before_script (base before_script intact)"
fi

# -- 6b. the fetched harness and the included template are the SAME ref ---------
# The file's own argument for fetching rather than vendoring is that `include:`
# already pins the template to a ref, so cloning that same ref keeps template and
# harness in lockstep "by construction". That only holds while the two refs are
# actually equal, and nothing but this check makes them stay equal.
if [ -n "$CLONE_DEST" ]; then
  if [ -n "$INC_REF" ] && [ "$INC_REF" = "$CLONE_BRANCH" ]; then
    ok "template and harness are the same ref (${INC_REF}) — no template/harness skew"
  else
    fail "include: pins ref '${INC_REF:-<none>}' but the harness clone takes branch '${CLONE_BRANCH:-<none>}' — the job would run one version's harness against another version's template"
  fi
fi

# -- 6c. `rules:` must be INHERITED from the base, not restated ----------------
# Same mechanism as check 6, applied to this file's own jobs: `extends:` REPLACES
# arrays. .pentest-sca declares THREE rules (merge request, default branch, and
# `$CI_PIPELINE_SOURCE == "schedule"`); a job that restates the first two looks
# like a faithful copy and silently deletes SCA from every scheduled pipeline.
# There is no partial merge to get right, so the invariant is: don't override.
for pjob in pentest:sca pentest:dast; do
  PJ_BODY="$(block_of "$pjob")"
  [ -n "$PJ_BODY" ] || continue
  if printf '%s\n' "$PJ_BODY" | grep -E '^[[:space:]]+rules:' >/dev/null; then
    fail "$pjob overrides rules: — extends: REPLACES arrays, so the base's rules are dropped wholesale (.pentest-sca's third rule is the scheduled pipeline). Inherit them."
  else
    ok "$pjob inherits the base's rules: (nothing dropped by array replacement)"
  fi
done

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

# -- 8. NO job is gated behind an earlier stage IMPLICITLY ---------------------
# Stage ordering is itself a gate: a stage runs only if every earlier stage
# SUCCEEDS, and a job that never ran leaves nothing in the MR widget to notice.
# That is the same "looks like it scanned" class this guard exists for, arriving
# from the other direction, and it bites the security jobs hardest: build:image is
# (correctly) not allow_failure, so under plain stage ordering a registry-login or
# docker-build failure on the default branch would remove BOTH pen-test jobs.
#
# The rule is applied to EVERY job, not just the pen-test pair. This file adds a
# `lint` stage in front of `build`, so the same implicit gate now points at the
# release job too — and a guard that only ever looked at two hardcoded job names
# could not see the coupling it had just introduced. A job is safe if it states
# its dependencies EXPLICITLY (`needs: []` for none, `needs: [job]` for a real one
# — the shape the org's angular-mfe skeleton uses) or if nothing that can fail
# runs earlier. The generator holds the same invariant over its own build:images
# job (lint:image-builder-always-on).
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

# One pass to record every job's stage index and whether it can fail the stage.
JOB_META=""
while read -r job; do
  [ -n "$job" ] || continue
  case "$job" in
    include|variables|default|workflow|cache|stages|before_script|after_script|image|services) continue ;;
  esac
  JOB_BODY="$(block_of "$job")"
  JOB_STAGE="$(printf '%s\n' "$JOB_BODY" | sed -n 's/^[[:space:]]*stage:[[:space:]]*//p' | head -1)"
  if [ -z "$JOB_STAGE" ]; then
    # No `stage:` here means it is inherited from what the job extends, which is
    # not in this file. Every .pentest-* hidden job in the included template is
    # `stage: pentest`; anything else falls back to GitLab's own default. Getting
    # this wrong would silently drop the pen-test jobs OUT of this check, which is
    # exactly the class of hole the check exists to close.
    if printf '%s\n' "$JOB_BODY" | grep -E '^[[:space:]]+extends:[[:space:]]*\.pentest-' >/dev/null; then
      JOB_STAGE="pentest"
    else
      JOB_STAGE="test"
    fi
  fi
  JOB_IDX="$(stage_index "$JOB_STAGE")"
  [ "$JOB_IDX" -ge 0 ] || continue                       # undeclared: check 7 owns it
  JOB_AF=0
  # Strict `true` on purpose: `allow_failure: exit_codes:` still lets the job fail
  # the stage on any other status, so it stays counted as a potential blocker.
  if has_allow_failure_true "$JOB_BODY"; then
    JOB_AF=1                                             # cannot fail the stage
  fi
  JOB_META="${JOB_META}${JOB_IDX} ${JOB_AF} ${job}
"
done <<< "$(job_names)"

while read -r idx af job; do
  [ -n "${job:-}" ] || continue
  BLOCKERS=""
  while read -r oidx oaf ojob; do
    [ -n "${ojob:-}" ] || continue
    [ "$oidx" -lt "$idx" ] || continue                    # not earlier: cannot gate
    [ "$oaf" -eq 0 ] || continue                          # earlier, but cannot fail
    BLOCKERS="${BLOCKERS} ${ojob}"
  done <<< "$JOB_META"
  JOB_BODY="$(block_of "$job")"
  if printf '%s\n' "$JOB_BODY" | grep -E '^[[:space:]]+needs:' >/dev/null; then
    ok "$job states its dependencies (needs:) — an earlier stage failing cannot silently delete it"
  elif [ -z "${BLOCKERS// /}" ]; then
    ok "$job is ungated: no job that can fail runs in an earlier stage"
  else
    fail "$job declares no needs:, so it runs only if${BLOCKERS} succeed — an earlier failure would silently remove it from the pipeline. State the dependency (needs: [] for none)."
  fi
done <<< "$JOB_META"

# -- 9. the wiring guard itself must be BLOCKING, AUTOMATIC, AND ACTUALLY RUN --
# Checks 1-8 all live in a file that only matters if something RUNS it. Every one
# of these edits retires the whole apparatus without touching a single pen-test
# job, and each left every check above printing "ok" until the sub-check named
# beside it was written:
#   * `allow_failure: true` on the guard job — it goes advisory, and a red guard
#     becomes an orange shrug in exactly the pipeline view this repo has already
#     learned not to trust                                                  (9a)
#   * ...or `allow_failure:` with an `exit_codes:` map, GitLab's other spelling.
#     The battery exits 1; that form excuses exactly that status              (9a)
#   * `when: manual` — it never runs unattended, so nothing on a merge request or
#     the default branch is ever checked                                     (9b)
#   * ...or `when: "manual"`. Quoting a scalar changes no YAML and defeated the
#     bare-word grep 9b (and check 10) shipped with                          (9b)
#   * narrowing `rules:` to a condition that never matches — no forbidden word
#     anywhere, the job simply is never created. "Skip lint on MRs to save runner
#     time" is a likelier real edit than `when: manual` ever was             (9c)
#   * `|| true` on the invocation, a `true ||` in front of it, an `- exit 0` or a
#     `set +e` above it, or piping it through `tee` (GitLab sets no pipefail).
#     Naming a script is not running it: this is the allow_failure edit written
#     in shell instead of YAML                                               (9d)
#   * pointing the job at check-ci-wiring.sh instead of check-ci-wiring.test.sh —
#     the guard still runs, but the battery that proves the guard can FAIL does
#     not, which is the same "a check that cannot fail passes for free" hole the
#     battery exists to close                                       (job scan)
#   * naming a battery that is not in the repo                               (9e)
#   * ...or replacing the battery with `exit 0` under the right name, with no CI
#     edit at all                                                            (9e)
#   * deleting the job outright.
# So the guard asserts its own invocation. This is not circular: the deletion case
# is caught wherever the guard is run OTHER than from the job it is checking —
# locally, in review, or from `npm run check:ci-wiring` / `npm run test:ci-wiring`
# (this repo wires no pre-commit hook today; the scripts are shaped to survive one
# if it is ever added) — and the neutering edits are caught in CI too, because in
# every one of them the job still runs.
GUARD_JOB=""
GUARD_SCRIPT=""
while read -r job; do
  [ -n "$job" ] || continue
  case "$job" in
    include|variables|default|workflow|cache|stages|before_script|after_script|image|services) continue ;;
  esac
  CAND="$(block_of "$job" |
    sed -n 's/^.*[[:space:]]\([^[:space:]"]*check-ci-wiring\.test\.sh\).*$/\1/p' | head -1)"
  if [ -n "$CAND" ]; then
    GUARD_JOB="$job"
    GUARD_SCRIPT="$CAND"
    break
  fi
done <<< "$(job_names)"

if [ -z "$GUARD_JOB" ]; then
  fail "no job in this file runs check-ci-wiring.test.sh — every check in this guard is then unreachable from CI, and the wiring can go inert with nothing to notice. (A job that runs check-ci-wiring.sh alone is NOT enough: the battery is what proves these checks can fail.)"
else
  ok "$GUARD_JOB runs the mutation battery ($GUARD_SCRIPT)"
  GUARD_BODY="$(block_of "$GUARD_JOB")"

  # 9a. BLOCKING — in every spelling, not just `allow_failure: true`.
  if has_any_allow_failure "$GUARD_BODY"; then
    fail "$GUARD_JOB carries allow_failure in some form other than an explicit 'false' — the guard becomes advisory, so a broken wiring check reds nothing. allow_failure is deliberate policy on the PEN-TEST stage (a finding must not block); it is the opposite of policy here (a guard that cannot fail is not a guard). Note this rejects GitLab's 'allow_failure: exit_codes:' map too: the battery exits 1, which is precisely the status that form excuses."
  else
    ok "$GUARD_JOB is blocking (no allow_failure in any form) — a broken wiring check reds the pipeline"
  fi

  # 9b. AUTOMATIC — quoted scalars included (see has_gated_when).
  if has_gated_when "$GUARD_BODY"; then
    fail "$GUARD_JOB carries when: manual/never/delayed — it would not run on a merge request or the default branch, so nothing checks the wiring unless a human remembers to click it"
  else
    ok "$GUARD_JOB runs automatically (no when: manual/never/delayed)"
  fi

  # 9c. ...and its `rules:` must actually COVER the pipelines that matter.
  # Asserting "no when: manual" says nothing about whether the job is ever
  # created. Replacing the rules with a branch condition that never matches —
  # "skip lint on MRs to save runner time" is the likelier real-world edit than
  # `when: manual` ever was — retires the guard just as completely, and left every
  # other check printing "ok".
  GUARD_RULES="$(list_items "$GUARD_BODY" rules)"
  if [ -z "$GUARD_RULES" ]; then
    ok "$GUARD_JOB declares no rules: — it runs on every pipeline"
  else
    # Accept every spelling that COVERS the pipeline, not just the org's usual
    # one — a check that reds `$CI_COMMIT_BRANCH == "main"` is a false positive of
    # exactly the kind this commit is removing elsewhere.
    RULES_MISS=""
    printf '%s\n' "$GUARD_RULES" |
      grep -E 'merge_request_event|CI_MERGE_REQUEST_(IID|ID)' >/dev/null ||
      RULES_MISS="${RULES_MISS} merge requests,"
    printf '%s\n' "$GUARD_RULES" |
      grep -E "CI_DEFAULT_BRANCH|CI_COMMIT_(BRANCH|REF_NAME)[[:space:]]*==[[:space:]]*[\"']" >/dev/null ||
      RULES_MISS="${RULES_MISS} the default branch,"
    if [ -n "$RULES_MISS" ]; then
      fail "$GUARD_JOB's rules: do not cover${RULES_MISS%,} — a rules: set that never matches retires this guard exactly as when: manual does, without using the word. Keep an '\$CI_PIPELINE_SOURCE == \"merge_request_event\"' rule and a '\$CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH' rule, or drop rules: altogether."
    else
      ok "$GUARD_JOB's rules: cover merge requests and the default branch"
    fi
  fi

  # 9d. the battery must be run UNCONDITIONALLY, not merely NAMED.
  # `- bash …test.sh || true`, `- true || bash …test.sh` and an `- exit 0` item
  # above the invocation all leave the battery mentioned in the file and dead in
  # the pipeline — the same neutering class as allow_failure, spelled in shell
  # instead of YAML. A pipe counts too: GitLab does not set pipefail, so
  # `… | tee log` hands the job tee's exit status.
  GUARD_RUN_ITEMS="$(list_items "$GUARD_BODY" script)"
  if ! printf '%s\n' "$GUARD_RUN_ITEMS" | grep -F 'check-ci-wiring.test.sh' >/dev/null; then
    GUARD_RUN_ITEMS="$GUARD_BODY"          # invoked from before_script/after_script
  fi
  INV_LNO="$(printf '%s\n' "$GUARD_RUN_ITEMS" | grep -nF 'check-ci-wiring.test.sh' | head -1)"
  INV_LNO="${INV_LNO%%:*}"
  INV_LINE="$(printf '%s\n' "$GUARD_RUN_ITEMS" | sed -n "${INV_LNO:-1}p")"
  NEUTERED=""
  case "$INV_LINE" in
    *'||'*) NEUTERED="a || short-circuit on the invocation itself" ;;
    *'|'*)  NEUTERED="a pipe — GitLab does not set pipefail, so the job takes the LAST command's exit status, not the battery's" ;;
  esac
  if [ -z "$NEUTERED" ] && [ "${INV_LNO:-1}" -gt 1 ]; then
    PRE="$(printf '%s\n' "$GUARD_RUN_ITEMS" | sed -n "1,$((INV_LNO - 1))p")"
    if printf '%s\n' "$PRE" | grep -E '(^|[[:space:];&|])exit([[:space:]]|$)' >/dev/null; then
      NEUTERED="an earlier script item that exits before the battery is ever reached"
    elif printf '%s\n' "$PRE" | grep -E 'set[[:space:]]+\+(e|o[[:space:]]+errexit)' >/dev/null; then
      NEUTERED="an earlier 'set +e', which stops a failing battery from failing the job"
    fi
  fi
  if [ -n "$NEUTERED" ]; then
    fail "$GUARD_JOB names the battery but does not run it unconditionally: ${NEUTERED}. Naming a script is not running it; this is the allow_failure edit written in shell instead of YAML."
  else
    ok "$GUARD_JOB runs the battery unconditionally (no ||, no pipe, nothing exits or relaxes errexit before it)"
  fi

  # 9e. the battery must exist AND be more than a file with the right NAME.
  # An existence test is satisfied by `#!/usr/bin/env bash` + `exit 0`, with no
  # edit to this CI file at all. A static check on another script's body is an
  # inherent regress — a determined rewrite always wins — but the CHEAPEST
  # spelling of it should not.
  if [ ! -f "${REPO_ROOT}/${GUARD_SCRIPT}" ]; then
    fail "$GUARD_JOB runs '${GUARD_SCRIPT}', which does not exist in this repo — the job would die on a bare 'No such file'"
  elif ! sed -e 's/[[:space:]]*#.*$//' "${REPO_ROOT}/${GUARD_SCRIPT}" |
         grep -F 'check-ci-wiring.sh' >/dev/null; then
    fail "the battery at ${GUARD_SCRIPT} never mentions check-ci-wiring.sh (comments stripped) — a two-line 'exit 0' file under the right NAME satisfies a mere existence test and turns this whole apparatus green for free"
  else
    ok "the battery exists at ${GUARD_SCRIPT} and runs this guard"
  fi
fi

# -- 10. the pen-test jobs must run AUTOMATICALLY ------------------------------
# `allow_failure: true` (policy, check 3/4) makes a FINDING non-blocking. It does
# not make the scan optional. `when: manual` does — and it is the tidiest possible
# way to stop scanning while leaving a `pentest:dast` entry in the pipeline view,
# which is the exact shape of the org-wide inertness this file exists against.
# `when: never` and `when: delayed` are the same edit wearing different hats.
for pjob in pentest:sca pentest:dast; do
  PJ_BODY="$(block_of "$pjob")"
  [ -n "$PJ_BODY" ] || continue
  if has_gated_when "$PJ_BODY"; then
    fail "$pjob carries when: manual/never/delayed — a scan that runs only when somebody clicks is not a scan on a merge request or the default branch, and the pipeline still shows the job"
  else
    ok "$pjob runs automatically (no when: manual/never/delayed)"
  fi
done

# -- 11. the harness is fetched from THIS pipeline's own org, not a literal host -
# Check 5 proves the harness lands where the job looks; it does not ask where the
# harness came FROM. The fetch is the one place this pipeline pulls executable
# code from off-repo and runs it on a privileged runner, so the source has to be
# derived from the pipeline's own CI_ variables (CI_REPOSITORY_URL here, the
# CI_SERVER_* triple in the org's other fetch-shaped repo) rather than written out
# as a literal host that review has to eyeball. A hardcoded scheme://host in this
# line passes every other check in this file.
if [ -n "$CLONE_LINE" ]; then
  CLONE_VAR="$(printf '%s\n' "$CLONE_SRC" | sed -n 's/^\${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p')"
  if [ -z "$CLONE_SRC" ]; then
    # FIRST, not last: an earlier ordering ran the name test on the empty string
    # and led with "the harness clone source '' is not hugmesh-generator[.git] —
    # a neighbouring name…", sending review after a supply-chain problem that did
    # not exist when the real fault was a line this file could not parse.
    fail "could not read the harness clone's SOURCE url from: ${CLONE_LINE#*:}"
  else
    # It must name the generator itself, not a neighbour of it. Check 5's
    # `hugmesh-generator` grep is a substring test, so `hugmesh-generator-fork.git`
    # satisfies it while the privileged runner executes somebody else's harness.
    case "$CLONE_SRC" in
      */hugmesh-generator.git|*/hugmesh-generator)
        ok "the harness clone names hugmesh-generator exactly" ;;
      *)
        fail "the harness clone source '${CLONE_SRC}' is not hugmesh-generator[.git] — a neighbouring name (hugmesh-generator-fork.git) satisfies the substring test in check 5 while the privileged runner executes a different repo's harness" ;;
    esac
    if [ -z "$CLONE_VAR" ]; then
      fail "the harness clone source '${CLONE_SRC}' does not start with a CI-derived variable. This job clones code and runs it on the privileged runner; the source must come from the pipeline's own CI_ variables (e.g. \${ORG_BASE} derived from CI_REPOSITORY_URL, or \${CI_SERVER_PROTOCOL}://...\${CI_SERVER_HOST}), never a literal host."
    else
      case "$CLONE_VAR" in
        CI_*)
          ok "the harness clone source is built from ${CLONE_VAR} (a CI-provided variable)" ;;
        *)
          # SHELL IS LAST-ASSIGNMENT-WINS, and the first form of this check asked
          # only whether SOME assignment of the origin derived from a CI_
          # variable. Appending one line after the honest derivation —
          #     - ORG_BASE="https://evil.invalid/attacker"
          # — left this check printing "ok  : …itself derived from a CI_ variable
          # in this job" while the privileged runner cloned and executed an
          # attacker's tree. That is the exact invariant this check advertises, so
          # EVERY assignment has to hold: each must begin with an expansion (a
          # literal scheme://host as the value's first component is the thing being
          # excluded) and each must mention a CI_ variable.
          ASSIGN_LINES="$(printf '%s\n' "$DAST_BODY" | grep -E "(^|[^A-Za-z0-9_])${CLONE_VAR}=")"
          ASSIGN_N=0
          ASSIGN_BAD=0
          while IFS= read -r aline; do
            [ -n "$aline" ] || continue
            ASSIGN_N=$((ASSIGN_N + 1))
            ASHOWN="$(printf '%s' "$aline" | sed 's/^[[:space:]]*-[[:space:]]*//')"
            ARHS="${aline#*${CLONE_VAR}=}"
            ARHS="${ARHS#\"}"
            ARHS="${ARHS#\'}"
            case "$ARHS" in
              '$'*) ;;
              *)
                ASSIGN_BAD=$((ASSIGN_BAD + 1))
                fail "the harness clone origin \${${CLONE_VAR}} is assigned from something that is not an expansion: '${ASHOWN}'. Shell is last-assignment-wins, so one extra line after the honest derivation silently redirects the fetch whose contents this job then RUNS on a privileged runner."
                continue ;;
            esac
            if ! printf '%s\n' "$aline" | grep -E 'CI_[A-Z_]+' >/dev/null; then
              ASSIGN_BAD=$((ASSIGN_BAD + 1))
              fail "the harness clone origin \${${CLONE_VAR}} is assigned from '${ASHOWN}', which names no CI_ variable — the fetched code's origin is not pinned to this pipeline's own server"
            fi
          done <<< "$ASSIGN_LINES"
          if [ "$ASSIGN_N" -eq 0 ]; then
            fail "the harness clone source starts with \${${CLONE_VAR}}, which this job never assigns — the fetched code's origin is not pinned to this pipeline's own server"
          elif [ "$ASSIGN_BAD" -eq 0 ]; then
            ok "the harness clone source is built from ${CLONE_VAR}, and ALL ${ASSIGN_N} assignment(s) of it in this job derive from a CI_ variable (shell is last-assignment-wins)"
          fi ;;
      esac
    fi
  fi
fi

# -----------------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d check(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall checks passed\n'
