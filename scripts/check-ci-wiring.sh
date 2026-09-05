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
# The scan itself lives in an array too. `extends:` REPLACES arrays — the reason
# checks 6 and 6c exist — and `script:` is the array the scan is written in, so two
# lines on pentest:dast
#     script:
#       - echo DAST-temporarily-disabled
# left the job name, the stage, allow_failure, needs, the harness fetch, the ref
# pin and the !reference splice all untouched, every check above printing "ok", and
# the job running an echo. Check 6d closes that; it is the shortest possible
# spelling of the exact failure the first paragraph describes.
#
# It then asserts the same thing about ITSELF (checks 9-12), because everything
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
# And the same edits keep arriving one level out from wherever the last check
# looked, so checks 9-12 look there too:
#   * GitLab concatenates before_script and script into ONE shell, so an `exit 0`
#     in the guard job's own before_script — or in a top-level `default:
#     before_script`, which applies to every job declaring none, and this one
#     declares none — ends that shell SUCCESSFUL having run nothing         (9d)
#   * `;` is `|| true` with one character changed, `&` never takes the status at
#     all, and a wrapping `if` or `!` takes its own                         (9d)
#   * a `changes:` clause leaves both `if:` conditions literally present in the
#     file while creating the job on essentially no pipeline                (9c)
#   * a top-level `workflow: rules:` deletes the guard AND both scans together:
#     $CI_COMMIT_BRANCH is unset on a merge_request_event, so a lone default-branch
#     rule there suppresses every merge-request pipeline. `workflow` is in the
#     reserved-key list checks 8 and 9 skip to tell jobs from configuration, which
#     is exactly why nothing had looked at it                          (check 12)
#   * and `include:` was matched by SUBSTRING, so `hugmesh/hugmesh-generator-fork`
#     satisfied it — the same hole check 11 closes on the clone, on the side where
#     the template IS the code the privileged runner executes         (check 1)
#
# The mirror of all that is FALSE POSITIVES, which are how a guard gets clicked
# past: `--branch=main`, an unbraced `$ORG_BASE`, a `when: never` rule that
# excludes only tag pipelines, and a `2>&1` on the invocation are each identical in
# meaning to a spelling this file already accepts, and each of them used to red the
# pipeline with a supply-chain- or retirement-shaped accusation. They are tested as
# hard as the rejections (check-ci-wiring.test.sh, leg 9).
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

# The shallowest indentation in a job body — i.e. the column its OWN keys sit at.
# block_of() drops the `job:` line, so every remaining line is indented, and the
# job-level keys are the least-indented of them.
job_min_indent() {
  printf '%s\n' "$1" | awk '
    /[^[:space:]]/ { match($0, /^[[:space:]]*/); if (m == 0 || RLENGTH < m) m = RLENGTH }
    END { print (m ? m : 2) }
  '
}

# `when: manual`, `when: "manual"` and `when: 'manual'` are the SAME YAML. The
# first form of checks 9 and 10 grepped for the bare word, so QUOTING it — one
# keystroke, nothing a reviewer would stop on — retired the guard job and either
# pen-test job while every check kept printing "ok". Same class as the mutations
# those checks were written to catch, one spelling away.
#
# SCOPED TO THE JOB'S OWN KEYS, not the whole body. A `when:` nested inside a
# `rules:` entry gates THAT ENTRY, not the job, and reading the two as the same
# thing red-lit `- if: $CI_COMMIT_TAG` / `when: never` — an entirely ordinary
# "don't lint tag pipelines" rule that leaves merge-request and default-branch
# coverage fully intact — with "it would not run on a merge request or the default
# branch". A guard whose false positives are one ordinary rule away is a guard
# people learn to click past. Rules-level gating is check 9c's job, and it now
# discounts a manual/never/delayed entry from COVERAGE instead (see rules_cover).
has_gated_when() {
  local ind
  ind="$(job_min_indent "$1")"
  printf '%s\n' "$1" |
    grep -E "^[[:space:]]{${ind}}when:[[:space:]]*['\"]?(manual|never|delayed)['\"]?[[:space:]]*\$" >/dev/null
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

# A `rules:` list re-grouped one ENTRY per line: the `- if:` line with each of its
# continuation lines (`changes:`, `exists:`, `when:`) appended after a ` ~ `, so a
# clause always travels with the condition it narrows. list_items() alone returns a
# flat line list, and asking "does this job's rules: mention merge_request_event?"
# of a flat list cannot see that the rule which mentions it also carries a
# `changes:` that switches it off on every pipeline but one.
rules_entries() {
  list_items "$1" rules | awk '
    /^[[:space:]]*-[[:space:]]/ { if (n) print buf; buf = $0; n = 1; next }
    n { sub(/^[[:space:]]*/, " ~ "); buf = buf $0; next }
    END { if (n) print buf }
  '
}

# rules_cover <rules-block>: which of "merge requests" / "the default branch" a
# rules: list actually COVERS, printed as two 0/1 flags.
#
# An entry only counts when it can create the pipeline unconditionally:
#   * `when: never` on the entry means it EXCLUDES rather than includes;
#   * `when: manual` / `delayed` creates a job nobody runs unattended, which is the
#     very thing check 9b rejects at the job level;
#   * a `changes:` or `exists:` clause narrows the entry to a subset of diffs, so
#     the pipeline it names is NOT covered. This is the likelier real edit than
#     `when: manual` ever was: `- if: <merge request>` + `changes: [deploy/**]`
#     leaves both `if:` strings literally present in the file — satisfying any
#     grep over the flat list — while the job is created on essentially nothing,
#     including every merge request that edits only scripts/.
rules_cover() {
  local mr
  mr=0
  local def
  def=0
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *'when: never'*|*'when: "never"'*|*"when: 'never'"*) continue ;;
      *'when: manual'*|*'when: "manual"'*|*"when: 'manual'"*) continue ;;
      *'when: delayed'*|*'when: "delayed"'*|*"when: 'delayed'"*) continue ;;
    esac
    if printf '%s\n' "$entry" | grep -E '(changes|exists):' >/dev/null; then
      continue
    fi
    if printf '%s\n' "$entry" |
         grep -E 'merge_request_event|CI_MERGE_REQUEST_(IID|ID)' >/dev/null; then
      mr=1
    fi
    if printf '%s\n' "$entry" |
         grep -E "CI_DEFAULT_BRANCH|CI_COMMIT_(BRANCH|REF_NAME)[[:space:]]*==[[:space:]]*[\"']" >/dev/null; then
      def=1
    fi
  done <<< "$(rules_entries "$1")"
  printf '%s %s\n' "$mr" "$def"
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

# EVERY token of a `git clone` command line, flags included, quotes honoured.
# clone_args() above deliberately throws the flags away; check 6b needs the VALUE
# of one of them.
clone_tokens() {
  printf '%s\n' "$1" | awk '
    {
      sub(/^.*git[[:space:]]+clone[[:space:]]+/, "")
      cur = ""; inq = 0; started = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\"") { inq = !inq; started = 1; continue }
        if (!inq && (c == " " || c == "\t")) {
          if (started) { print cur; cur = ""; started = 0 }
          continue
        }
        cur = cur c; started = 1
      }
      if (started) print cur
    }'
}

# The branch a `git clone` line takes, in BOTH spellings GNU git accepts.
# `--branch main`, `--branch=main` and `-b main` are the same command line; the
# first form of check 6b was a sed that required whitespace after `--branch`, so
# `--branch=main` reported "include: pins ref 'main' but the harness clone takes
# branch '<none>' — the job would run one version's harness against another
# version's template", a supply-chain-shaped accusation against a semantically
# identical edit. Same false-positive class as the trailing `--quiet` that
# clone_args() exists to absorb.
clone_branch() {
  clone_tokens "$1" | awk '
    take { print; exit }
    /^(--branch|-b)$/ { take = 1; next }
    /^(--branch|-b)=/ { sub(/^[^=]*=/, ""); print; exit }
  '
}

if [ ! -f "$CI_FILE" ]; then
  printf 'FATAL: no CI file at %s\n' "$CI_FILE" >&2
  exit 2
fi

printf '== check-ci-wiring: %s\n' "$CI_FILE"

# -- 1. the shared pen-test template is included -------------------------------
# The project name is matched EXACTLY, not as a substring — the same hole check 11
# closes on the clone, on the higher-value side of the pair. `grep -F
# "hugmesh/hugmesh-generator"` is satisfied by
# `project: 'hugmesh/hugmesh-generator-fork'`, and with the clone line left alone
# every other check in this file passes too, so the guard exits 0 while the
# include supplies .pentest-dast-base's entire before_script (a curl plus an
# `unzip -d /usr/local/bin/`) and .pentest-dast-baseline's script, both of which
# then execute on the `privileged` runner. Here the template IS the executed code,
# so a neighbouring name matters more here than it does on the clone.
INCLUDE_BLOCK="$(block_of include)"
INC_PROJECT="$(printf '%s\n' "$INCLUDE_BLOCK" |
  sed -n "s/^[[:space:]]*-\{0,1\}[[:space:]]*project:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]*\).*/\1/p" | head -1)"

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

INC_OK=1
case "$INC_PROJECT" in
  */hugmesh-generator) ;;
  '') INC_OK=0
      fail "no include: with a 'project:' — nothing pulls in the shared pen-test template, so .pentest-sca / .pentest-dast-baseline do not exist and both jobs are hard pipeline errors" ;;
  *)  INC_OK=0
      fail "include: names project '${INC_PROJECT}', which is not <group>/hugmesh-generator. A neighbouring name ('hugmesh/hugmesh-generator-fork') satisfies a substring test while supplying the before_script and script this pipeline then executes on the privileged runner — the same hole check 11 closes on the clone, on the side where the template IS the executed code." ;;
esac
if [ "$INC_OK" -eq 1 ] && [ "$INC_FILE" != "/tests/pentest/ci/pentest-stage.gitlab-ci.yml" ]; then
  INC_OK=0
  fail "include: names file '${INC_FILE:-<none>}', not '/tests/pentest/ci/pentest-stage.gitlab-ci.yml' — a different file in the same repo defines different (or no) .pentest-* jobs"
fi
[ "$INC_OK" -eq 1 ] && ok "includes ${INC_PROJECT}${INC_FILE} (project and file matched exactly, not as substrings)"

# -- 2. the pentest stage is declared ------------------------------------------
# The declared stage list, read from either YAML spelling — `stages: [a, b]` or a
# block list — because check 7 and check 8 both need it as a list anyway, and
# because asking the question as a regex over the raw line answered it only for
# the flow spelling. (It also drops this file's one GNU-only construct, a `\b`
# word boundary, which mawk-era runners and busybox grep do not owe us.)
DECLARED="$(code_only | sed -n 's/^stages:[[:space:]]*\[\(.*\)\].*/\1/p' | tr -d ' ' | tr ',' '\n')"
if [ -z "$DECLARED" ]; then
  DECLARED="$(block_of stages | sed -n 's/^[[:space:]]*-[[:space:]]*//p')"
fi
if printf '%s\n' "$DECLARED" | grep -Fx 'pentest' >/dev/null; then
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
CLONE_BRANCH="$(clone_branch "$CLONE_LINE")"

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

# -- 6d. `script:` must be INHERITED too — that is where the SCAN lives ---------
# The same mechanism as checks 6 and 6c, applied to the one array that IS the
# scan. `.pentest-sca` and `.pentest-dast-baseline` each declare a `script:`; a
# job that extends one of them and states its own REPLACES it wholesale. Two
# lines on pentest:dast —
#     script:
#       - echo DAST-temporarily-disabled
# — leave the job name, the stage, allow_failure, the harness fetch, the ref pin
# and the !reference splice all exactly as they are, and every other check in this
# file printed "ok" while the job's only command was an echo. That is not a
# near-miss of the failure this guard exists for, it IS the failure this guard
# exists for, written in the shortest possible form: "the org-wide failure mode is
# not a missing job, it is a job that LOOKS like it scanned."
#
# An override is only accepted when it splices the base's script back in with
# `!reference [<the job's own extends: target>, script]`, the same escape hatch
# check 6 allows for before_script.
for pjob in pentest:sca pentest:dast; do
  PJ_BODY="$(block_of "$pjob")"
  [ -n "$PJ_BODY" ] || continue
  if ! printf '%s\n' "$PJ_BODY" | grep -E '^[[:space:]]+script:' >/dev/null; then
    ok "$pjob inherits the base's script: — the scan itself is not overridden"
    continue
  fi
  PJ_BASE="$(printf '%s\n' "$PJ_BODY" |
    sed -n 's/^[[:space:]]*extends:[[:space:]]*\(\.[A-Za-z0-9_.-]*\).*/\1/p' | head -1)"
  if [ -n "$PJ_BASE" ] &&
     printf '%s\n' "$(list_items "$PJ_BODY" script)" |
       grep -F "!reference [${PJ_BASE}, script]" >/dev/null; then
    ok "$pjob overrides script: but splices ${PJ_BASE}'s own script back with !reference"
  else
    fail "$pjob overrides script: — extends: REPLACES arrays, so the base's scan is dropped wholesale and the job runs only what is written here. This is the whole failure mode in two lines: the job, its stage, allow_failure, the harness fetch and the ref pin all survive, and the pipeline still shows a '$pjob' entry. Inherit it, or splice it back with '!reference [${PJ_BASE:-<the base>}, script]'."
  fi
done

# -- 7. every job's stage is declared ------------------------------------------
# A job whose `stage:` is not in `stages:` is a hard pipeline error, and it is an
# easy one to introduce when adding a stage list to a previously single-stage file.
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
  if ! printf '%s\n' "$GUARD_BODY" | grep -E '^[[:space:]]+rules:' >/dev/null; then
    ok "$GUARD_JOB declares no rules: — it runs on every pipeline"
  elif [ -z "$GUARD_RULES" ]; then
    # `rules: [...]` on one line, or `rules: []`. The block form is the only shape
    # this guard can read, and a rules: set it cannot read is a rules: set that can
    # retire it while this check prints "ok" — the same "unreadable therefore
    # green" hole as every other one in this file.
    fail "$GUARD_JOB's rules: are not in the block form this guard can read (flow style, or an empty list). An empty rules: creates the job on NO pipeline; a flow-style one cannot be checked for coverage at all. Write them as a block list, or drop rules: altogether."
  else
    # Accept every spelling that COVERS the pipeline, not just the org's usual
    # one — a check that reds `$CI_COMMIT_BRANCH == "main"` is a false positive of
    # exactly the kind this commit is removing elsewhere. But COVERS is the word:
    # a rule narrowed by `changes:`/`exists:`, or one carrying its own
    # `when: never/manual/delayed`, names a pipeline without covering it. See
    # rules_cover().
    read -r RULES_MR RULES_DEF <<< "$(rules_cover "$GUARD_BODY")"
    RULES_MISS=""
    [ "$RULES_MR" -eq 1 ] || RULES_MISS="${RULES_MISS} merge requests,"
    [ "$RULES_DEF" -eq 1 ] || RULES_MISS="${RULES_MISS} the default branch,"
    if [ -n "$RULES_MISS" ]; then
      fail "$GUARD_JOB's rules: do not cover${RULES_MISS%,} — a rules: set that never matches retires this guard exactly as when: manual does, without using the word. A rule that names the pipeline but carries a 'changes:'/'exists:' clause, or its own 'when: never/manual/delayed', does not count: the condition is still spelled out in the file while the job is created on essentially nothing. Keep an unconditional '\$CI_PIPELINE_SOURCE == \"merge_request_event\"' rule and an unconditional '\$CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH' rule, or drop rules: altogether."
    else
      ok "$GUARD_JOB's rules: cover merge requests and the default branch, unconditionally"
    fi
  fi

  # 9d. the battery must be run UNCONDITIONALLY, not merely NAMED.
  # `- bash …test.sh || true`, `- true || bash …test.sh` and an `- exit 0` item
  # above the invocation all leave the battery mentioned in the file and dead in
  # the pipeline — the same neutering class as allow_failure, spelled in shell
  # instead of YAML. A pipe counts too: GitLab does not set pipefail, so
  # `… | tee log` hands the job tee's exit status.
  # GitLab concatenates before_script and script into ONE shell script, so what
  # runs before the battery is not only the earlier `script:` items. A job's own
  # `before_script: [- exit 0]` ends that shell SUCCESSFUL having run nothing, and
  # so does a top-level `default: before_script:` (which applies to every job that
  # declares none — and lint:ci-wiring is precisely such a job, which is why the
  # argument that a default cannot shadow the pen-test jobs "because both already
  # define one" does not cover the job this check is about). The deprecated
  # column-0 `before_script:` is the same key by another name.
  GUARD_PRE="$(list_items "$GUARD_BODY" before_script)"
  if [ -z "$GUARD_PRE" ]; then
    GUARD_PRE="$(list_items "$(block_of default)" before_script)"
  fi
  if [ -z "$GUARD_PRE" ]; then
    GUARD_PRE="$(block_of before_script)"
  fi
  GUARD_RUN_ITEMS="$(list_items "$GUARD_BODY" script)"
  if [ -n "$GUARD_PRE" ]; then
    GUARD_RUN_ITEMS="$(printf '%s\n%s\n' "$GUARD_PRE" "$GUARD_RUN_ITEMS")"
  fi
  if ! printf '%s\n' "$GUARD_RUN_ITEMS" | grep -F 'check-ci-wiring.test.sh' >/dev/null; then
    GUARD_RUN_ITEMS="$GUARD_BODY"          # invoked from after_script, or an odd shape
  fi
  INV_LNO="$(printf '%s\n' "$GUARD_RUN_ITEMS" | grep -nF 'check-ci-wiring.test.sh' | head -1)"
  INV_LNO="${INV_LNO%%:*}"
  INV_LINE="$(printf '%s\n' "$GUARD_RUN_ITEMS" | sed -n "${INV_LNO:-1}p")"
  NEUTERED=""
  # What the item runs BEFORE reaching the battery, and what it runs AFTER. The
  # two are not symmetric: `cd scripts; bash …test.sh` still hands the job the
  # battery's status, `bash …test.sh; true` does not — `;` is `|| true` with one
  # character changed, and the first form of this check rejected `||` and let `;`
  # straight through. Redirections are stripped first so an ordinary
  # `> wiring.log 2>&1` is not read as a background `&`.
  INV_CMD="$(printf '%s' "$INV_LINE" | sed 's/^[[:space:]]*-[[:space:]]*//')"
  INV_TAIL="${INV_LINE#*check-ci-wiring.test.sh}"
  INV_TAIL="${INV_TAIL//&&/  }"
  INV_TAIL="${INV_TAIL//2>&1/ }"
  INV_TAIL="${INV_TAIL//>&/ }"
  INV_TAIL="${INV_TAIL//&>/ }"
  case "$INV_CMD" in
    'if '*|'while '*|'until '*|'! '*|'{ '*|'('*)
      NEUTERED="a shell construct wrapped round the invocation (${INV_CMD%% *}…), whose own status — not the battery's — is what the job takes" ;;
  esac
  if [ -z "$NEUTERED" ]; then
    case "$INV_LINE" in
      *'||'*) NEUTERED="a || short-circuit on the invocation itself" ;;
      *'|'*)  NEUTERED="a pipe — GitLab does not set pipefail, so the job takes the LAST command's exit status, not the battery's" ;;
    esac
  fi
  if [ -z "$NEUTERED" ]; then
    case "$INV_TAIL" in
      *';'*) NEUTERED="a ';' after the invocation — the shell takes the LAST command's exit status, so whatever follows the battery decides the job. This is '|| true' with one character changed" ;;
      *'&'*) NEUTERED="a '&' after the invocation — the battery is backgrounded and the job never waits for it, let alone takes its exit status" ;;
    esac
  fi
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
    ok "$GUARD_JOB runs the battery unconditionally (no ||, pipe, ';', '&' or wrapping construct; nothing exits or relaxes errexit before it, in before_script or script)"
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
  # `${ORG_BASE}/…` and `$ORG_BASE/…` are the same shell. Reading only the braced
  # spelling made the unbraced one FAIL with "does not start with a CI-derived
  # variable … never a literal host" — a supply-chain accusation against an
  # identical line.
  CLONE_VAR="$(printf '%s\n' "$CLONE_SRC" | sed -n 's/^\${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p')"
  [ -n "$CLONE_VAR" ] ||
    CLONE_VAR="$(printf '%s\n' "$CLONE_SRC" | sed -n 's/^\$\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')"
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

# -- 12. a top-level `workflow:` must not retire the whole file ----------------
# Check 9c's own argument is that "a rules: set that never matches retires this
# guard exactly as when: manual does, without using the word". The same edit ONE
# LEVEL UP does it to every job at once:
#     workflow:
#       rules:
#         - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
# CI_COMMIT_BRANCH is unset on a merge_request_event, so no merge-request pipeline
# is created at all — deleting lint:ci-wiring, pentest:sca and pentest:dast
# together, from every MR, with no forbidden word anywhere and nothing in the
# pipeline view to notice. `workflow` is in the reserved-key skip list that checks
# 8 and 9 use to tell jobs from configuration, which is exactly why nothing looked
# at it. Same coverage test as 9c, including the `changes:` narrowing.
WORKFLOW_BLOCK="$(block_of workflow)"
if [ -z "$WORKFLOW_BLOCK" ]; then
  ok "no top-level workflow: — each job's own rules: decide when it runs"
elif ! printf '%s\n' "$WORKFLOW_BLOCK" | grep -E '^[[:space:]]+rules:' >/dev/null; then
  ok "the top-level workflow: declares no rules: — it cannot suppress a pipeline"
elif [ -z "$(list_items "$WORKFLOW_BLOCK" rules)" ]; then
  fail "the top-level workflow: rules: are not in the block form this guard can read (flow style, or an empty list) — an empty workflow rules: creates NO pipeline at all, and a flow-style one cannot be checked for coverage. Write them as a block list, or drop workflow: altogether."
else
  read -r WF_MR WF_DEF <<< "$(rules_cover "$WORKFLOW_BLOCK")"
  WF_MISS=""
  [ "$WF_MR" -eq 1 ] || WF_MISS="${WF_MISS} merge requests,"
  [ "$WF_DEF" -eq 1 ] || WF_MISS="${WF_MISS} the default branch,"
  if [ -n "$WF_MISS" ]; then
    fail "the top-level workflow: rules: do not cover${WF_MISS%,} — no pipeline is created there at all, so lint:ci-wiring, pentest:sca and pentest:dast are ALL deleted together, and every per-job check in this file goes on printing ok. (\$CI_COMMIT_BRANCH is unset on a merge_request_event, so a lone default-branch rule is exactly this edit.)"
  else
    ok "the top-level workflow: rules: still cover merge requests and the default branch"
  fi
fi

# -----------------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d check(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall checks passed\n'
