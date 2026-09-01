#!/bin/bash
# Test suite for the codemap hook scripts. No framework; needs bash, jq, and
# git — the same tools the hooks themselves rely on (jq is a hard dependency
# of the hooks; git is optional for the hooks but required to test worktrees).
#
#   bash tests/run.sh
#
# Each case feeds a script the JSON that Claude Code's hook runner would,
# with CLAUDE_PROJECT_DIR pointing at a throwaway project. Payloads are
# encoded with jq — raw printf into a JSON template broke on any value
# containing quotes or backslashes.

set -u

scripts="$(cd "$(dirname "$0")/../scripts" && pwd)"
live_test="$(cd "$(dirname "$0")" && pwd)/live-claude-code.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

proj="$work/proj"
mkdir -p "$proj/docs/codemap"

pass=0
fail=0

check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

# The runner writes a JSON payload to every hook's stdin — feed one to announce
# too, so the drain-before-exit behavior is exercised the way production runs it.
announce() { printf '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-announce.sh" 2>&1; }
guard()    { jq -cn --arg c "$2" '{"tool_input":{"command":$c}}' | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-commit-guard.sh" 2>&1; }
guard_raw(){ printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-commit-guard.sh" 2>&1; }
stale()    { jq -cn --arg f "$2" '{"tool_input":{"file_path":$f}}' | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-stale.sh" 2>&1; }
queue()    { bash "$scripts/codemap-queue.sh" "$@" 2>&1; }

# Variants that carry the payload's cwd — the hooks must resolve the active
# checkout from it instead of trusting CLAUDE_PROJECT_DIR alone (review R1).
announce_at() { jq -cn --arg d "$2" '{"hook_event_name":"SessionStart","cwd":$d}' | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-announce.sh" 2>&1; }
guard_at()    { jq -cn --arg d "$2" --arg c "$3" '{"cwd":$d,"tool_input":{"command":$c}}' | CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-commit-guard.sh" 2>&1; }

# A PATH stripped of jq forces the missing-dependency branch — the hooks must
# report it loudly in codemap projects instead of silently mistracking (R3).
# Fixtures for these cases are pre-encoded here, while jq is still on PATH.
# git stays linked in: the no-jq fallback resolves the active checkout from the
# hook process's own working directory (F5), which needs git but not jq — so
# the helpers also cd to that directory, the way the hook runner does.
nojq="$work/nojq"
mkdir -p "$nojq"
for c in bash cat grep sort tail awk; do
  ln -s "$(command -v "$c")" "$nojq/$c"
done
command -v git >/dev/null 2>&1 && ln -s "$(command -v git)" "$nojq/git"
guard_nojq()    { (cd "${3:-$1}" && printf '%s' "$2" | PATH="$nojq" CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-commit-guard.sh" 2>&1); }
stale_nojq()    { (cd "${3:-$1}" && printf '%s' "$2" | PATH="$nojq" CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-stale.sh" 2>&1); }
announce_nojq() { (cd "${2:-$1}" && printf '{"hook_event_name":"SessionStart"}' | PATH="$nojq" CLAUDE_PROJECT_DIR="$1" bash "$scripts/codemap-announce.sh" 2>&1); }

# --- hook wiring -------------------------------------------------------------

for s in codemap-announce.sh codemap-stale.sh codemap-commit-guard.sh codemap-queue.sh; do
  # hooks.json invokes the hook scripts directly, and the injected refresh
  # instructions invoke codemap-queue.sh; a lost exec bit ships green in
  # bash-wrapped tests but breaks every install.
  check "wiring: $s is executable" "yes" "$([[ -x "$scripts/$s" ]] && echo yes)"
done
check "wiring: shared lib ships next to the hooks" \
  "yes" "$([[ -f "$scripts/codemap-lib.sh" ]] && echo yes)"
check "wiring: commit tokenizer ships next to the hooks" \
  "yes" "$([[ -f "$scripts/codemap-git-commit.awk" ]] && echo yes)"
check "wiring: live Claude Code scenario is executable" \
  "yes" "$([[ -x "$live_test" ]] && echo yes)"

# The live scenario spends model tokens only with an explicit --live flag.
# Its dry run must be deterministic and exercise fixture/command construction
# without requiring Claude authentication or calling a model.
live_dry="$work/live-dry"
live_out=$(CODEMAP_LIVE_WORKDIR="$live_dry" \
  CODEMAP_LIVE_CLAUDE="claude-command-not-installed" \
  bash "$live_test" --dry-run 2>&1); live_rc=$?
check "live scenario: dry run succeeds without Claude CLI or authentication" \
  "0" "$live_rc"
check "live scenario: dry run creates the isolated Git fixture" \
  "yes" "$([[ -d "$live_dry/.git" && -f "$live_dry/src/inventory.ts" && -f "$live_dry/src/report.ts" ]] && echo yes)"
check "live scenario: dry run shows all four phases using the local plugin" \
  "yes" "$([[ "$live_out" == *"1/4 init"* && "$live_out" == *"2/4 edit"* && "$live_out" == *"3/4 refresh"* && "$live_out" == *"4/4 commit-guard"* && "$live_out" == *"--plugin-dir"* && "$live_out" == *"claude-command-not-installed"* ]] && echo yes)"
check "live scenario: dry run does not pretend a codemap was generated" \
  "yes" "$([[ ! -d "$live_dry/docs/codemap" && "$live_out" == *"no model calls were made"* ]] && echo yes)"

# --- codemap-announce.sh -----------------------------------------------------

mkdir -p "$work/bare"
check "announce: silent in a project without docs/codemap/" \
  "" "$(announce "$work/bare")"

out=$(announce "$proj")
check "announce: injects routing rules when docs/codemap/ exists" \
  "yes" "$([[ "$out" == *"docs/codemap/README.md"* ]] && echo yes)"
check "announce: no stale line when .stale is absent" \
  "yes" "$([[ "$out" != *"stale file"* ]] && echo yes)"
# Wholesale clearing of .stale loses edits recorded during a refresh (R2);
# the injected instruction must route through the claim protocol instead.
check "announce: injected rules do not say to empty .stale" \
  "yes" "$([[ "$out" != *"empty .stale"* ]] && echo yes)"
check "announce: injected rules name the queue tool for refreshes" \
  "yes" "$([[ "$out" == *codemap-queue.sh* ]] && echo yes)"

# Empty .stale is the state right after codemap-init; this used to trip a
# "0\n0" capture from grep -c and spray a math error on every session start.
touch "$proj/docs/codemap/.stale"
out=$(announce "$proj")
check "announce: empty .stale produces no error and no stale line" \
  "yes" "$([[ "$out" != *[Ee]rror* && "$out" != *"stale file"* ]] && echo yes)"

printf 'a.swift\nb.swift\n' > "$proj/docs/codemap/.stale"
check "announce: reports pending count" \
  "yes" "$([[ "$(announce "$proj")" == *"Currently 2 stale file(s)"* ]] && echo yes)"

# --- codemap-commit-guard.sh -------------------------------------------------

check "guard: ignores non-commit commands" \
  "0" "$(guard "$proj" "ls -la" >/dev/null; echo $?)"

: > "$proj/docs/codemap/.stale"
check "guard: quiet after commit when .stale is empty" \
  "0" "$(guard "$proj" "git commit -m x" >/dev/null; echo $?)"

printf 'a.swift\n' > "$proj/docs/codemap/.stale"
check "guard: exit 2 after commit with pending entries" \
  "2" "$(guard "$proj" "git commit -m x" >/dev/null; echo $?)"
check "guard: reminder names the pending count" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" == *"1 file(s)"* ]] && echo yes)"
check "guard: reminder does not say to empty .stale" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" != *"empty .stale"* ]] && echo yes)"
check "guard: reminder names the queue tool" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" == *codemap-queue.sh* ]] && echo yes)"
check "guard: catches git -C <path> commit" \
  "2" "$(guard "$proj" "git -C /some/repo commit -m x" >/dev/null; echo $?)"
check "guard: catches a commit after && chaining" \
  "2" "$(guard "$proj" "cd sub && git commit -m x" >/dev/null; echo $?)"

# Quote-aware detection (R4): a regex over whitespace boundaries both missed
# quoted paths with spaces and false-fired on `git commit` inside quoted text.
check "guard: catches git -C with a quoted path containing spaces" \
  "2" "$(guard "$proj" 'git -C "/tmp/project with spaces" commit -m x' >/dev/null; echo $?)"
check "guard: catches git -c with a quoted value before commit" \
  "2" "$(guard "$proj" 'git -c user.name="A B" commit -m x' >/dev/null; echo $?)"
check "guard: catches a commit chained after a quoted cd path" \
  "2" "$(guard "$proj" 'cd "/tmp/some dir" && git commit -m x' >/dev/null; echo $?)"
check "guard: catches a commit on the second line of a multiline command" \
  "2" "$(guard "$proj" "$(printf 'git status\ngit commit -m x')" >/dev/null; echo $?)"
check "guard: catches a commit behind a leading VAR= assignment" \
  "2" "$(guard "$proj" "GIT_AUTHOR_NAME=t git commit -m x" >/dev/null; echo $?)"
check "guard: ignores git commit inside a single-quoted string" \
  "0" "$(guard "$proj" "echo 'please run git commit -m x'" >/dev/null; echo $?)"
check "guard: ignores git commit inside a double-quoted string" \
  "0" "$(guard "$proj" 'echo "then git commit -m x"' >/dev/null; echo $?)"
check "guard: ignores git commit inside a comment" \
  "0" "$(guard "$proj" "$(printf 'ls\n# git commit -m x later\n')" >/dev/null; echo $?)"

# Ordinary executable forms the first tokenizer missed (F3): shell keywords in
# command position, empty quoted arguments, and command substitution inside
# double quotes all execute the commit they carry.
check "guard: catches a commit inside an if/then branch" \
  "2" "$(guard "$proj" "if true; then git commit -m x; fi" >/dev/null; echo $?)"
check "guard: catches a commit inside an else branch" \
  "2" "$(guard "$proj" "if false; then :; else git commit -m x; fi" >/dev/null; echo $?)"
check "guard: catches a commit inside a while/do body" \
  "2" "$(guard "$proj" "while true; do git commit -m x; done" >/dev/null; echo $?)"
check "guard: catches a commit inside a brace group" \
  "2" "$(guard "$proj" "{ git commit -m x; }" >/dev/null; echo $?)"
check "guard: empty quoted -C value does not swallow the commit subcommand" \
  "2" "$(guard "$proj" 'git -C "" commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016 # the unexpanded $(…) literals ARE the fixtures
check "guard: catches command substitution inside double quotes" \
  "2" "$(guard "$proj" 'echo "$(git commit -m x)"' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches backtick substitution inside double quotes" \
  "2" "$(guard "$proj" 'echo "`git commit -m x`"' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches bare command substitution" \
  "2" "$(guard "$proj" 'echo $(git commit -m x)' >/dev/null; echo $?)"
check "guard: catches a commit inside a subshell" \
  "2" "$(guard "$proj" "(git commit -m x)" >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: quoted text resumed after a substitution stays literal" \
  "0" "$(guard "$proj" 'echo "$(git log) then git commit"' >/dev/null; echo $?)"

# A closing )/` must restore the enclosing quote context (G3): a single
# toggling state let quoted text after "$(…)" scan as commands and treated a
# real command after the closing quote as quoted text.
# shellcheck disable=SC2016
check "guard: quoted text with ordinary arguments after a substitution stays literal" \
  "0" "$(guard "$proj" 'echo "$(git log) then git commit -m x"' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a real command after a closed quoted substitution" \
  "2" "$(guard "$proj" 'echo "$(git log)"; git commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a real command after a closed quoted backtick substitution" \
  "2" "$(guard "$proj" 'echo "`git log`"; git commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a commit nested two substitutions deep inside quotes" \
  "2" "$(guard "$proj" 'echo "$(echo "$(git commit -m x)")"' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: a bare subshell inside a quoted substitution does not desync the contexts" \
  "0" "$(guard "$proj" 'echo "$( (git log) ) then git commit -m x"' >/dev/null; echo $?)"

# A substitution must stay part of the argument and command it interrupts
# (H4): entering "$(…)" used to discard the outer words, so an option value
# containing a substitution hid a real commit, and literal arguments after a
# closed substitution were mistaken for a fresh command.
# shellcheck disable=SC2016
check "guard: catches a commit whose -C value is a quoted substitution" \
  "2" "$(guard "$proj" 'git -C "$(pwd)" commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a commit whose -c value contains a substitution" \
  "2" "$(guard "$proj" 'git -c user.name="$(whoami)" commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a commit whose -C value is a bare substitution" \
  "2" "$(guard "$proj" 'git -C $(pwd) commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: catches a commit with a substitution in a later argument" \
  "2" "$(guard "$proj" 'git commit -m "$(date)"' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: text appended to a substitution stays an argument of echo" \
  "0" "$(guard "$proj" 'echo "$(git log)git" commit -m x' >/dev/null; echo $?)"
# shellcheck disable=SC2016
check "guard: words after a closed substitution stay echo's arguments" \
  "0" "$(guard "$proj" 'echo "$(git log)" git commit -m x' >/dev/null; echo $?)"

# Read-only commands that merely contain commit-ish substrings must not fire —
# the old substring globs matched all three of these.
check "guard: ignores git log --grep with 'commit' in the query" \
  "0" "$(guard "$proj" "git log --grep 'fix commit'" >/dev/null; echo $?)"
check "guard: ignores git stash list piped to grep commit" \
  "0" "$(guard "$proj" "git stash list | grep commit" >/dev/null; echo $?)"
check "guard: ignores git push with 'commit' in a later argument" \
  "0" "$(guard "$proj" "git push && gh pr create -t 'Add commit guard'" >/dev/null; echo $?)"

# Duplicate .stale lines (possible under concurrent stale hooks) count once.
printf 'a.swift\na.swift\nb.swift\n' > "$proj/docs/codemap/.stale"
check "guard: counts duplicate .stale lines once" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" == *"2 file(s)"* ]] && echo yes)"
check "announce: counts duplicate .stale lines once" \
  "yes" "$([[ "$(announce "$proj")" == *"Currently 2 stale file(s)"* ]] && echo yes)"
printf 'a.swift\n' > "$proj/docs/codemap/.stale"

# "git commit" appearing only in tool output must not fire the guard — the
# old greedy-sed regression captured past the command field and did exactly that.
payload='{"tool_input":{"command":"git log --oneline"},"tool_response":{"stdout":"a1b2c3 tell people to git commit often"}}'
check "guard: no false positive on 'git commit' inside tool_response" \
  "0" "$(guard_raw "$proj" "$payload" >/dev/null; echo $?)"

# --- refresh claim protocol (R2 / F1 / F2) -----------------------------------
# Refresh completion must never clear work recorded after the refresh began.
# Claim, complete, and recovery are owned by one executable, codemap-queue.sh,
# which shares a lock with the stale hook's append — these tests drive that
# executable, not a transcript of documented shell steps.

cm="$proj/docs/codemap"
qreset() { rm -f "$cm/.stale" "$cm/.stale.claimed" "$cm/.stale.batch" "$cm/.stale.claim-token"; }
touch "$proj/A.ts" "$proj/B.ts"
qreset
stale "$proj" "$proj/A.ts" >/dev/null

out=$(queue claim "$proj")
tok=$(printf '%s\n' "$out" | head -1 | awk '{print $2}')
check "claim: prints a token line followed by the claimed paths" \
  "yes" "$([[ "$out" == "token $tok"$'\n'"A.ts" && -n "$tok" ]] && echo yes)"
check "claim: pending entry moved into .stale.claimed" \
  "A.ts" "$(cat "$cm/.stale.claimed")"
check "claim: the live queue is consumed" \
  "yes" "$([[ ! -f "$cm/.stale" ]] && echo yes)"

# Edits during the refresh — a different file, and the claimed file again:
stale "$proj" "$proj/B.ts" >/dev/null
stale "$proj" "$proj/A.ts" >/dev/null
check "claim: new edit during refresh lands in a fresh .stale" \
  "yes" "$(grep -qxF "B.ts" "$cm/.stale" && echo yes)"
check "claim: re-edit of a claimed file is queued again, not suppressed" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale" && echo yes)"

# An in-progress (or interrupted) refresh keeps its claimed batch visible:
check "guard: claimed-but-unfinished entries still trigger the reminder" \
  "2" "$(guard "$proj" "git commit -m x" >/dev/null; echo $?)"
check "guard: pending count spans .stale and .stale.claimed without double-counting" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" == *"2 file(s)"* ]] && echo yes)"
check "announce: pending count includes an interrupted claimed batch" \
  "yes" "$([[ "$(announce "$proj")" == *"Currently 2 stale file(s)"* ]] && echo yes)"

# Completion deletes only the claimed batch; refresh-time edits survive:
check "complete: the claim's token completes the batch" \
  "0" "$(queue complete "$tok" "$proj" >/dev/null; echo $?)"
check "complete: the claimed batch is gone" \
  "yes" "$([[ ! -f "$cm/.stale.claimed" && ! -f "$cm/.stale.claim-token" ]] && echo yes)"
check "complete: edits recorded during the refresh stay pending" \
  "2" "$(guard "$proj" "git commit -m x" >/dev/null; echo $?)"

qreset
check "claim: reports nothing pending without creating a batch" \
  "yes" "$([[ "$(queue claim "$proj")" == *"nothing pending"* && ! -f "$cm/.stale.claimed" ]] && echo yes)"
check "complete: refuses when nothing is claimed" \
  "1" "$(queue complete sometoken "$proj" >/dev/null; echo $?)"
check "queue: complete without a token is a usage error" \
  "1" "$(queue complete >/dev/null; echo $?)"

# --- interruption recovery: every intermediate state a crash can leave -------

# (a) F2 regression — a batch left behind by an interrupted claim step must be
# merged by the next claim, never overwritten by newer pending work.
qreset
printf 'A.ts\n' > "$cm/.stale.batch"
printf 'B.ts\n' > "$cm/.stale"
check "recover: a leftover .stale.batch alone still counts as pending" \
  "yes" "$([[ "$(guard "$proj" "git commit -m x")" == *"2 file(s)"* ]] && echo yes)"
out=$(queue claim "$proj")
tok=$(printf '%s\n' "$out" | head -1 | awk '{print $2}')
check "recover: claim merges an interrupted batch with new work (F2)" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "recover: nothing pending after the merged batch completes" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"

# (b)+(c) an interrupted refresh (claimed batch + its token) is taken over by
# the next claim, and the superseded token can no longer delete anything —
# this is also the two-simultaneous-refreshers case (F2's shared-file loss).
qreset
printf 'old.ts\n' > "$cm/.stale.claimed"
printf 'deadtoken\n' > "$cm/.stale.claim-token"
stale "$proj" "$proj/B.ts" >/dev/null
out=$(queue claim "$proj")
tok2=$(printf '%s\n' "$out" | head -1 | awk '{print $2}')
check "recover: re-claim merges an interrupted batch with new pending work" \
  "yes" "$(grep -qxF "old.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "ownership: a superseded token is refused" \
  "1" "$(queue complete deadtoken "$proj" >/dev/null; echo $?)"
check "ownership: the refused complete deletes nothing" \
  "yes" "$(grep -qxF "old.ts" "$cm/.stale.claimed" && echo yes)"
check "ownership: the current token still completes" \
  "0" "$(queue complete "$tok2" "$proj" >/dev/null; echo $?)"

# Two live refreshers, end to end: the second claim absorbs the first one's
# batch, and only the second owner may complete it.
qreset
stale "$proj" "$proj/A.ts" >/dev/null
tok1=$(queue claim "$proj" | head -1 | awk '{print $2}')
stale "$proj" "$proj/B.ts" >/dev/null
tok2=$(queue claim "$proj" | head -1 | awk '{print $2}')
check "ownership: a second claim absorbs the first refresher's batch" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "ownership: the first refresher cannot complete the shared batch" \
  "1" "$(queue complete "$tok1" "$proj" >/dev/null; echo $?)"
check "ownership: no pending work was lost across the double claim" \
  "2" "$(queue pending "$proj")"
check "ownership: the second refresher completes everything" \
  "yes" "$(queue complete "$tok2" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"

# (d) a crash between complete's two deletions leaves an orphaned token;
# retrying complete with that token must succeed instead of wedging.
qreset
printf 'orphantok\n' > "$cm/.stale.claim-token"
check "recover: retrying complete after a mid-complete crash succeeds" \
  "0" "$(queue complete orphantok "$proj" >/dev/null; echo $?)"
check "recover: the orphaned token is cleaned up" \
  "yes" "$([[ ! -f "$cm/.stale.claim-token" ]] && echo yes)"

# A filesystem error while completing a refresh must never be reported as a
# successful completion. If the claimed batch cannot be removed, keep its
# token so the same owner can retry. If only token cleanup fails, report the
# failure and let the existing orphan-token recovery path finish the cleanup.
cat > "$work/fail_rm_path.sh" <<'EOF'
rm() {
  for arg in "$@"; do
    if [[ "$arg" == "${CODEMAP_TEST_FAIL_RM_PATH:-}" ]]; then return 1; fi
  done
  command rm "$@"
}
EOF
cm_phys=$(cd "$cm" 2>/dev/null && pwd -P)

qreset
stale "$proj" "$proj/A.ts" >/dev/null
tok=$(queue claim "$proj" | head -1 | awk '{print $2}')
out=$(BASH_ENV="$work/fail_rm_path.sh" \
  CODEMAP_TEST_FAIL_RM_PATH="$cm_phys/.stale.claimed" \
  bash "$scripts/codemap-queue.sh" complete "$tok" "$proj" 2>&1); rc=$?
check "complete failure: a claimed-batch removal error fails loudly" \
  "yes" "$([[ "$rc" == "1" && "$out" == *"failed"* && "$out" != *"completed"* ]] && echo yes)"
check "complete failure: a claimed-batch removal error keeps the batch and token" \
  "yes" "$([[ -f "$cm/.stale.claimed" && -f "$cm/.stale.claim-token" ]] && echo yes)"
check "complete failure: retrying the same token completes the preserved batch" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"

qreset
stale "$proj" "$proj/A.ts" >/dev/null
tok=$(queue claim "$proj" | head -1 | awk '{print $2}')
out=$(BASH_ENV="$work/fail_rm_path.sh" \
  CODEMAP_TEST_FAIL_RM_PATH="$cm_phys/.stale.claim-token" \
  bash "$scripts/codemap-queue.sh" complete "$tok" "$proj" 2>&1); rc=$?
check "complete failure: a token removal error fails loudly" \
  "yes" "$([[ "$rc" == "1" && "$out" == *"failed"* && "$out" != *"completed"* ]] && echo yes)"
check "complete failure: a token removal error leaves only the retryable token" \
  "yes" "$([[ ! -f "$cm/.stale.claimed" && -f "$cm/.stale.claim-token" ]] && echo yes)"
check "complete failure: retrying cleans up the orphaned token" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ ! -f "$cm/.stale.claim-token" ]] && echo yes)"

# (e) a crash while holding the queue lock: an aged lock is broken instead of
# disabling tracking forever.
qreset
mkdir "$cm/.stale.lock"
touch -t 202001010000 "$cm/.stale.lock"
stale "$proj" "$proj/A.ts" >/dev/null
check "recover: a stale lock from a crashed process is broken, edit recorded" \
  "A.ts" "$(cat "$cm/.stale" 2>/dev/null)"
check "recover: the broken lock is gone afterwards, and no reap residue is left" \
  "yes" "$([[ ! -d "$cm/.stale.lock" && ! -d "$cm/.stale.lock.breaker" ]] && echo yes)"

# --- deterministic writer/claim interleaving (F1) ----------------------------
# The review's loss schedule: a hook has opened its append descriptor on
# .stale when a claim renames the file away — the write then lands in an
# unlinked file. BASH_ENV pauses the hook at exactly that point (the caller's
# redirection is applied before the paused function body runs); the claim must
# block on the shared lock until the append finishes.

cat > "$work/pause_echo.sh" <<'EOF'
echo() {
  if [[ "${1:-}" == "${CODEMAP_TEST_PAUSE_ON:-}" && -p "${CODEMAP_TEST_FIFO_READY:-}" ]]; then
    builtin echo ready > "$CODEMAP_TEST_FIFO_READY"
    read -r _ < "$CODEMAP_TEST_FIFO_GO"
  fi
  builtin echo "$@"
}
EOF
cat > "$work/pause_sort.sh" <<'EOF'
sort() {
  if [[ -p "${CODEMAP_TEST_FIFO_READY:-}" ]]; then
    printf 'ready\n' > "$CODEMAP_TEST_FIFO_READY"
    read -r _ < "$CODEMAP_TEST_FIFO_GO"
  fi
  command sort "$@"
}
EOF

# (i) writer paused inside its append critical section vs. a claim.
qreset
stale "$proj" "$proj/A.ts" >/dev/null
mkfifo "$work/f1a.ready" "$work/f1a.go"
exec 8<>"$work/f1a.ready" 9<>"$work/f1a.go"
jq -cn --arg f "$proj/B.ts" '{"tool_input":{"file_path":$f}}' \
  | BASH_ENV="$work/pause_echo.sh" CODEMAP_TEST_PAUSE_ON="B.ts" \
    CODEMAP_TEST_FIFO_READY="$work/f1a.ready" CODEMAP_TEST_FIFO_GO="$work/f1a.go" \
    CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
writer=$!
read -t 15 -r _ <&8   # writer is at the append: descriptor open, lock held
bash "$scripts/codemap-queue.sh" claim "$proj" > "$work/f1a.out" 2>&1 &
claimer=$!
sleep 0.5
check "F1: claim blocks while a writer is inside the append critical section" \
  "yes" "$(kill -0 "$claimer" 2>/dev/null && echo yes)"
printf 'go\n' >&9
wait "$writer" 2>/dev/null
wait "$claimer" 2>/dev/null
tok=$(head -1 "$work/f1a.out" | awk '{print $2}')
check "F1: the overlapped append is in the claim snapshot, not lost" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "F1: completing that claim leaves nothing pending and nothing lost" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"
exec 8<&- 9<&-

# (ii) the mirror image: a claim paused mid-transition vs. a writer. The edit
# must block, then land in a fresh .stale — not in the void, not in the batch.
qreset
printf 'A.ts\n' > "$cm/.stale"
mkfifo "$work/f1b.ready" "$work/f1b.go"
exec 8<>"$work/f1b.ready" 9<>"$work/f1b.go"
BASH_ENV="$work/pause_sort.sh" \
  CODEMAP_TEST_FIFO_READY="$work/f1b.ready" CODEMAP_TEST_FIFO_GO="$work/f1b.go" \
  bash "$scripts/codemap-queue.sh" claim "$proj" > "$work/f1b.out" 2>&1 &
claimer=$!
read -t 15 -r _ <&8   # claim is mid-transition, lock held
jq -cn --arg f "$proj/B.ts" '{"tool_input":{"file_path":$f}}' \
  | CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
writer=$!
sleep 0.5
check "F1: a writer blocks while a claim transition is in progress" \
  "yes" "$(kill -0 "$writer" 2>/dev/null && echo yes)"
printf 'go\n' >&9
wait "$claimer" 2>/dev/null
wait "$writer" 2>/dev/null
tok=$(head -1 "$work/f1b.out" | awk '{print $2}')
check "F1: the claim snapshot holds exactly the pre-claim path" \
  "A.ts" "$(cat "$cm/.stale.claimed" 2>/dev/null)"
check "F1: the edit made during the claim lands in a fresh .stale" \
  "B.ts" "$(cat "$cm/.stale" 2>/dev/null)"
check "F1: after completion the during-claim edit is still pending" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "1" ]] && echo yes)"
exec 8<&- 9<&-

# --- two reapers vs. one orphan lock (G1) ------------------------------------
# The review's loss schedule: two processes independently observe the same
# orphan lock; the writer reaps it and acquires a FRESH lock first, and the
# claimer's earlier "it is stale" decision must not reap that fresh lock out
# from under the writer's open append descriptor. The claimer is paused at the
# exact moment its stale decision is about to be acted on: before the reap
# mutex (current code) or before the reaping mv (the code under review).

cat > "$work/pause_reap.sh" <<'EOF'
mkdir() {
  if [[ "${1:-}" == *".stale.lock.breaker" && -p "${CODEMAP_TEST_FIFO_READY:-}" ]]; then
    builtin echo ready > "$CODEMAP_TEST_FIFO_READY"
    read -r _ < "$CODEMAP_TEST_FIFO_GO"
  fi
  command mkdir "$@"
}
mv() {
  if [[ "${1:-}" == *".stale.lock" && -p "${CODEMAP_TEST_FIFO_READY:-}" ]]; then
    builtin echo ready > "$CODEMAP_TEST_FIFO_READY"
    read -r _ < "$CODEMAP_TEST_FIFO_GO"
  fi
  command mv "$@"
}
EOF

qreset
printf 'A.ts\n' > "$cm/.stale"
mkdir "$cm/.stale.lock"
touch -t 202001010000 "$cm/.stale.lock"
mkfifo "$work/g1c.ready" "$work/g1c.go" "$work/g1w.ready" "$work/g1w.go"
exec 8<>"$work/g1c.ready" 9<>"$work/g1c.go" 6<>"$work/g1w.ready" 7<>"$work/g1w.go"
BASH_ENV="$work/pause_reap.sh" \
  CODEMAP_TEST_FIFO_READY="$work/g1c.ready" CODEMAP_TEST_FIFO_GO="$work/g1c.go" \
  bash "$scripts/codemap-queue.sh" claim "$proj" > "$work/g1.out" 2>&1 &
claimer=$!
read -t 15 -r _ <&8   # claimer decided the orphan is stale, has not reaped yet
jq -cn --arg f "$proj/B.ts" '{"tool_input":{"file_path":$f}}' \
  | BASH_ENV="$work/pause_echo.sh" CODEMAP_TEST_PAUSE_ON="B.ts" \
    CODEMAP_TEST_FIFO_READY="$work/g1w.ready" CODEMAP_TEST_FIFO_GO="$work/g1w.go" \
    CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
writer=$!
read -t 15 -r _ <&6   # writer reaped the orphan itself; fresh lock, append fd open
printf 'go\n' >&9     # resume the claimer, its stale age decision in hand
sleep 0.5
check "G1: the delayed reaper does not delete the writer's fresh lock" \
  "yes" "$([[ -d "$cm/.stale.lock" ]] && echo yes)"
check "G1: the claimer blocks behind the fresh lock instead of claiming" \
  "yes" "$(kill -0 "$claimer" 2>/dev/null && echo yes)"
printf 'go\n' >&7
wait "$writer" 2>/dev/null
wait "$claimer" 2>/dev/null
tok=$(head -1 "$work/g1.out" | awk '{print $2}')
check "G1: the overlapped edit is in the claim snapshot, not lost" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "G1: completing the claim leaves nothing pending and nothing lost" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"
exec 8<&- 9<&- 6<&- 7<&-

# The victim's side of the same defect: a holder whose lock was broken (the
# documented >5s stall case) and replaced must not delete the successor's
# lock instance when it unlocks.
qreset
mkfifo "$work/g1u.ready" "$work/g1u.go"
exec 8<>"$work/g1u.ready" 9<>"$work/g1u.go"
jq -cn --arg f "$proj/B.ts" '{"tool_input":{"file_path":$f}}' \
  | BASH_ENV="$work/pause_echo.sh" CODEMAP_TEST_PAUSE_ON="B.ts" \
    CODEMAP_TEST_FIFO_READY="$work/g1u.ready" CODEMAP_TEST_FIFO_GO="$work/g1u.go" \
    CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
writer=$!
read -t 15 -r _ <&8         # writer holds its lock, paused in the critical section
rm -rf "$cm/.stale.lock"    # simulate a reap of the stalled writer's lock…
mkdir "$cm/.stale.lock"     # …and a successor acquiring a new instance
printf 'successor\n' > "$cm/.stale.lock/owner.successor"  # …with its owner file in place
printf 'go\n' >&9
wait "$writer" 2>/dev/null
check "G1: unlock leaves a successor's lock instance alone" \
  "yes" "$([[ -d "$cm/.stale.lock" ]] && echo yes)"
check "G1: the stalled writer's edit itself was still recorded" \
  "B.ts" "$(cat "$cm/.stale" 2>/dev/null)"
rm -rf "$cm/.stale.lock"
exec 8<&- 9<&-

# --- a stalled holder's unlock vs. a successor's live lock (H1) --------------
# The review's loss schedule: an outgoing holder enters unlock — in the code
# under review its owner comparison has already PASSED — and stalls at the
# removal itself. Its lock ages past the threshold, is reaped, and a real
# edit hook acquires a fresh one. The resumed removal must not destroy that
# fresh lock: deletion is keyed to the instance's own owner-file NAME plus an
# rmdir that fails while any successor's owner file exists, not to a saved
# comparison. (The reap of the aged lock itself is the documented >5s-stall
# limitation and is exercised deliberately here; the successor is resumed
# well inside the threshold.)
cat > "$work/pause_rm.sh" <<'EOF'
rm() {
  if [[ "$*" == *".stale.lock/owner"* && -p "${CODEMAP_TEST_FIFO_READY:-}" ]]; then
    builtin echo ready > "$CODEMAP_TEST_FIFO_READY"
    read -r _ < "$CODEMAP_TEST_FIFO_GO"
  fi
  command rm "$@"
}
EOF
qreset
mkfifo "$work/h1h.ready" "$work/h1h.go" "$work/h1w.ready" "$work/h1w.go"
exec 8<>"$work/h1h.ready" 9<>"$work/h1h.go" 6<>"$work/h1w.ready" 7<>"$work/h1w.go"
# The outgoing holder: a real stale hook (recording A.ts) whose unlock is
# paused at the owner removal — after the comparison in the pre-fix code.
jq -cn --arg f "$proj/A.ts" '{"tool_input":{"file_path":$f}}' \
  | BASH_ENV="$work/pause_rm.sh" \
    CODEMAP_TEST_FIFO_READY="$work/h1h.ready" CODEMAP_TEST_FIFO_GO="$work/h1h.go" \
    CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
holder=$!
read -t 15 -r _ <&8         # unlock entered, removal not yet performed
touch -t 202001010000 "$cm/.stale.lock"   # the holder stalls past the threshold
jq -cn --arg f "$proj/B.ts" '{"tool_input":{"file_path":$f}}' \
  | BASH_ENV="$work/pause_echo.sh" CODEMAP_TEST_PAUSE_ON="B.ts" \
    CODEMAP_TEST_FIFO_READY="$work/h1w.ready" CODEMAP_TEST_FIFO_GO="$work/h1w.go" \
    CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1 &
writer=$!
read -t 15 -r _ <&6         # successor reaped the orphan; fresh lock, append fd open
printf 'go\n' >&9           # resume the stalled removal
wait "$holder" 2>/dev/null
check "H1: a stalled holder's resumed unlock leaves the successor's lock intact" \
  "yes" "$([[ -d "$cm/.stale.lock" ]] && echo yes)"
bash "$scripts/codemap-queue.sh" claim "$proj" > "$work/h1.out" 2>&1 &
claimer=$!
sleep 0.5
check "H1: a claim blocks behind the successor's lock instead of proceeding" \
  "yes" "$(kill -0 "$claimer" 2>/dev/null && echo yes)"
printf 'go\n' >&7
wait "$writer" 2>/dev/null
wait "$claimer" 2>/dev/null
tok=$(head -1 "$work/h1.out" | awk '{print $2}')
check "H1: no pending work was lost across the stalled unlock" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "H1: the recovered batch completes cleanly" \
  "yes" "$(queue complete "$tok" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"
exec 8<&- 9<&- 6<&- 7<&-

# --- a takeover that fails midway (G2) ---------------------------------------
# A second claim absorbs the first refresher's batch plus new work, then fails
# before finishing. The first refresher's token must already be revoked at
# that point: its complete may not delete paths it never refreshed. Fault
# points: normalization (sort) and the batch rewrite (mv) — both after the
# absorb, exercising the claim's real error branches.
printf 'sort() { return 1; }\n' > "$work/fail_sort.sh"
printf 'mv() { return 1; }\n'   > "$work/fail_mv.sh"
# A sort can also emit part of its output and then die (killed mid-stream,
# read error): the pipeline's observed status is grep's, so this used to look
# like success and truncate the batch to the fragment under a fresh token (H2).
# shellcheck disable=SC2016 # the unexpanded body IS the injected fixture
printf 'sort() { command head -n 1 "${@: -1}"; return 1; }\n' > "$work/fail_sort_partial.sh"
for fault in fail_sort fail_sort_partial fail_mv; do
  qreset
  stale "$proj" "$proj/A.ts" >/dev/null
  tok=$(queue claim "$proj" | head -1 | awk '{print $2}')
  stale "$proj" "$proj/B.ts" >/dev/null
  out=$(BASH_ENV="$work/$fault.sh" bash "$scripts/codemap-queue.sh" claim "$proj" 2>&1); rc=$?
  check "G2 ($fault): the interrupted takeover reports failure" \
    "1" "$rc"
  check "G2 ($fault): the failed takeover issued no token" \
    "yes" "$(! printf '%s\n' "$out" | grep -q '^token ' && [[ ! -s "$cm/.stale.claim-token" ]] && echo yes)"
  check "G2 ($fault): the old token was revoked before the batch grew" \
    "yes" "$([[ ! -s "$cm/.stale.claim-token" ]] && echo yes)"
  check "G2 ($fault): the superseded refresher cannot complete the grown batch" \
    "1" "$(queue complete "$tok" "$proj" >/dev/null; echo $?)"
  check "G2 ($fault): the refused complete lost no pending work" \
    "2" "$(queue pending "$proj")"
  tok2=$(queue claim "$proj" | head -1 | awk '{print $2}')
  check "G2 ($fault): a re-run claim recovers both paths under a new token" \
    "yes" "$([[ -n "$tok2" ]] && grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
  check "G2 ($fault): the recovered batch completes cleanly" \
    "yes" "$(queue complete "$tok2" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"
done

# --- an error while probing the batch for emptiness (H3) ---------------------
# grep exit 2 is a read/execution error, not proof that the batch is empty:
# treating any nonzero probe as "nothing pending" deleted the entire merged
# batch and reported success. A probe failure must keep every file on disk
# and fail the claim; re-running claim is then the recovery, as for G2.
# shellcheck disable=SC2016 # the unexpanded body IS the injected fixture
printf 'grep() { if [[ "${1:-}" == "-q" ]]; then return 2; fi; command grep "$@"; }\n' > "$work/fail_grepq.sh"
qreset
stale "$proj" "$proj/A.ts" >/dev/null
tok=$(queue claim "$proj" | head -1 | awk '{print $2}')
stale "$proj" "$proj/B.ts" >/dev/null
out=$(BASH_ENV="$work/fail_grepq.sh" bash "$scripts/codemap-queue.sh" claim "$proj" 2>&1); rc=$?
check "H3: a failing emptiness probe reports failure, not an empty queue" \
  "yes" "$([[ "$rc" == "1" && "$out" != *"nothing pending"* ]] && echo yes)"
check "H3: the probe failure deleted nothing" \
  "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "H3: the superseded token still cannot complete the kept batch" \
  "1" "$(queue complete "$tok" "$proj" >/dev/null; echo $?)"
check "H3: no pending work was lost" \
  "2" "$(queue pending "$proj")"
tok2=$(queue claim "$proj" | head -1 | awk '{print $2}')
check "H3: a re-run claim recovers the kept batch under a new token" \
  "yes" "$([[ -n "$tok2" ]] && grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
check "H3: the recovered batch completes cleanly" \
  "yes" "$(queue complete "$tok2" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"

# --- a claim whose snapshot delivery fails (I1) ------------------------------
# The token used to be recorded and printed before the batch was read back,
# and that final read was unchecked: a partial or empty delivery still exited
# 0, and the exposed token authorized deleting paths the caller never saw.
# Delivery is now checked and the token is armed only after the full snapshot
# went out — a token line printed by a failed claim must not complete.
# shellcheck disable=SC2016 # the unexpanded body IS the injected fixture
printf 'cat() { if [[ "$#" == 1 && "$1" == */.stale.claimed ]]; then command head -n 1 "$1"; return 1; fi; command cat "$@"; }\n' > "$work/fail_cat_partial.sh"
# shellcheck disable=SC2016 # the unexpanded body IS the injected fixture
printf 'cat() { if [[ "$#" == 1 && "$1" == */.stale.claimed ]]; then return 1; fi; command cat "$@"; }\n' > "$work/fail_cat_empty.sh"
for fault in fail_cat_partial fail_cat_empty; do
  qreset
  stale "$proj" "$proj/A.ts" >/dev/null
  tok=$(queue claim "$proj" | head -1 | awk '{print $2}')
  stale "$proj" "$proj/B.ts" >/dev/null
  out=$(BASH_ENV="$work/$fault.sh" bash "$scripts/codemap-queue.sh" claim "$proj" 2>&1); rc=$?
  check "I1 ($fault): a failed snapshot delivery fails the claim" \
    "1" "$rc"
  badtok=$(printf '%s\n' "$out" | awk '/^token /{print $2; exit}')
  check "I1 ($fault): a token exposed by the failed claim cannot complete" \
    "1" "$(queue complete "${badtok:-missing}" "$proj" >/dev/null; echo $?)"
  check "I1 ($fault): the superseded token stays refused too" \
    "1" "$(queue complete "$tok" "$proj" >/dev/null; echo $?)"
  check "I1 ($fault): the full batch is preserved on disk" \
    "yes" "$(grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
  check "I1 ($fault): no pending work was lost" \
    "2" "$(queue pending "$proj")"
  tok2=$(queue claim "$proj" | head -1 | awk '{print $2}')
  check "I1 ($fault): a retried claim recovers both paths under a new token" \
    "yes" "$([[ -n "$tok2" ]] && grep -qxF "A.ts" "$cm/.stale.claimed" && grep -qxF "B.ts" "$cm/.stale.claimed" && echo yes)"
  check "I1 ($fault): the recovered batch completes cleanly" \
    "yes" "$(queue complete "$tok2" "$proj" >/dev/null && [[ "$(queue pending "$proj")" == "0" ]] && echo yes)"
done

qreset
printf 'a.swift\n' > "$cm/.stale"

# --- codemap-stale.sh --------------------------------------------------------

: > "$proj/docs/codemap/.stale"
touch "$proj/Foo.swift" "$proj/notes.txt"
mkdir -p "$proj/node_modules" && touch "$proj/node_modules/dep.js"
mkdir -p "$proj/packages/web/node_modules/dep" && touch "$proj/packages/web/node_modules/dep/index.js"
mkdir -p "$proj/docs/site" && touch "$proj/docs/site/config.ts"
touch "$work/elsewhere.swift"

stale "$proj" "$proj/Foo.swift" >/dev/null
check "stale: records an edited source file (relative path)" \
  "Foo.swift" "$(cat "$proj/docs/codemap/.stale")"

stale "$proj" "$proj/Foo.swift" >/dev/null
check "stale: does not record duplicates" \
  "1" "$(grep -c . "$proj/docs/codemap/.stale")"

stale "$proj" "$proj/notes.txt" >/dev/null
stale "$proj" "$proj/node_modules/dep.js" >/dev/null
stale "$proj" "$proj/packages/web/node_modules/dep/index.js" >/dev/null
stale "$proj" "$work/elsewhere.swift" >/dev/null
check "stale: ignores non-source, vendored (any depth), and out-of-project files" \
  "1" "$(grep -c . "$proj/docs/codemap/.stale")"

stale "$proj" "$proj/docs/site/config.ts" >/dev/null
check "stale: tracks real source under docs/ (only docs/codemap/ is excluded)" \
  "yes" "$(grep -qxF "docs/site/config.ts" "$proj/docs/codemap/.stale" && echo yes)"

# A partial rewrite of .stale can drop the trailing newline; the hook must
# repair it instead of concatenating the next path onto the last line.
printf 'docs/site/config.ts' > "$proj/docs/codemap/.stale"
stale "$proj" "$proj/Foo.swift" >/dev/null
check "stale: appending after a missing trailing newline keeps lines intact" \
  "2" "$(grep -c . "$proj/docs/codemap/.stale")"

# The hook promises to report when an edit cannot be queued. A directory at
# the queue path is a deterministic cross-platform write failure: the old
# unchecked append printed a shell error but still exited 0 as if it worked.
rm -f "$proj/docs/codemap/.stale"
mkdir "$proj/docs/codemap/.stale"
out=$(stale "$proj" "$proj/Foo.swift"); rc=$?
check "stale write failure: exits nonzero instead of hiding the lost edit" \
  "2" "$rc"
check "stale write failure: says the edit was not recorded" \
  "yes" "$([[ "$out" == *"NOT recorded"* ]] && echo yes)"
check "stale write failure: leaves the invalid queue target untouched" \
  "yes" "$([[ -d "$proj/docs/codemap/.stale" ]] && echo yes)"
rmdir "$proj/docs/codemap/.stale"
touch "$proj/docs/codemap/.stale"

# .extensions extends the built-in list — a replacing whitelist would silently
# stop tracking languages the project adopts after codemap-init.
printf 'tf\n' > "$proj/docs/codemap/.extensions"
touch "$proj/main.tf"
: > "$proj/docs/codemap/.stale"
stale "$proj" "$proj/main.tf" >/dev/null
stale "$proj" "$proj/Foo.swift" >/dev/null
check "stale: .extensions adds project extensions" \
  "yes" "$(grep -qxF "main.tf" "$proj/docs/codemap/.stale" && echo yes)"
check "stale: built-in extensions stay tracked alongside .extensions" \
  "yes" "$(grep -qxF "Foo.swift" "$proj/docs/codemap/.stale" && echo yes)"
rm "$proj/docs/codemap/.extensions"

# A trailing slash on CLAUDE_PROJECT_DIR passes the -d activation guard but used
# to break the "$root"/* containment match, silently disabling tracking.
: > "$proj/docs/codemap/.stale"
stale "$proj/" "$proj/Foo.swift" >/dev/null
check "stale: tolerates trailing slash on CLAUDE_PROJECT_DIR" \
  "Foo.swift" "$(cat "$proj/docs/codemap/.stale")"

check "stale: silent in a project without docs/codemap/" \
  "" "$(touch "$work/bare/A.swift"; stale "$work/bare" "$work/bare/A.swift")"

# --- JSON escape handling (R3, jq present) -----------------------------------
# The old sed fallback dropped any payload whose strings used JSON escapes;
# these fixtures are valid JSON produced by a real encoder (jq itself).

: > "$proj/docs/codemap/.stale"
touch "$proj/we\"ird.swift"
stale "$proj" "$proj/we\"ird.swift" >/dev/null
check "stale: records a path containing a double quote" \
  "yes" "$(grep -qxF 'we"ird.swift' "$proj/docs/codemap/.stale" && echo yes)"

touch "$proj/back\\slash.swift"
stale "$proj" "$proj/back\\slash.swift" >/dev/null
check "stale: records a path containing a backslash" \
  "yes" "$(grep -qxF 'back\slash.swift' "$proj/docs/codemap/.stale" && echo yes)"

# Same non-ASCII path, serialized with \uXXXX escapes (jq -a) — still valid JSON.
touch "$proj/한글.swift"
jq -acn --arg f "$proj/한글.swift" '{"tool_input":{"file_path":$f}}' \
  | CLAUDE_PROJECT_DIR="$proj" bash "$scripts/codemap-stale.sh" >/dev/null 2>&1
check "stale: decodes a \\uXXXX-escaped non-ASCII path" \
  "yes" "$(grep -qxF '한글.swift' "$proj/docs/codemap/.stale" && echo yes)"

# .stale is line-based, so a path containing a newline cannot be stored; the
# hook must skip it without corrupting the file (documented limitation).
nlfile="$proj/$(printf 'bad\nname').swift"
touch "$nlfile"
before=$(grep -c . "$proj/docs/codemap/.stale")
stale "$proj" "$nlfile" >/dev/null
check "stale: skips a newline-containing path instead of corrupting .stale" \
  "$before" "$(grep -c . "$proj/docs/codemap/.stale")"

# --- worktree and cwd resolution (R1, real git) ------------------------------
# CLAUDE_PROJECT_DIR stays at the original project root for the whole session;
# the hooks must route state to the checkout that actually owns the edit.

if command -v git >/dev/null 2>&1; then
  repo="$work/repo"
  git init -q -b main "$repo"
  mkdir -p "$repo/docs/codemap" "$repo/src"
  echo index > "$repo/docs/codemap/README.md"
  touch "$repo/src/A.ts"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
  wt="$repo/.claude/worktrees/feature"
  git -C "$repo" worktree add -q "$wt" -b feat-nested
  sib="$work/repo-sibling"
  git -C "$repo" worktree add -q "$sib" -b feat-sibling

  stale "$repo" "$wt/src/A.ts" >/dev/null
  check "worktree: nested edit lands in the worktree's own .stale" \
    "src/A.ts" "$(cat "$wt/docs/codemap/.stale" 2>/dev/null)"
  check "worktree: nested edit leaves the main checkout's .stale untouched" \
    "yes" "$([[ ! -s "$repo/docs/codemap/.stale" ]] && echo yes)"

  stale "$repo" "$sib/src/A.ts" >/dev/null
  check "worktree: sibling edit lands in the sibling's own .stale" \
    "src/A.ts" "$(cat "$sib/docs/codemap/.stale" 2>/dev/null)"
  check "worktree: sibling edit leaves the main checkout's .stale untouched" \
    "yes" "$([[ ! -s "$repo/docs/codemap/.stale" ]] && echo yes)"

  check "worktree: pending worktree entries trigger the guard" \
    "2" "$(guard_at "$repo" "$wt" "git commit -m x" >/dev/null; echo $?)"
  check "worktree: announce counts the active worktree's pending files" \
    "yes" "$([[ "$(announce_at "$repo" "$wt")" == *"Currently 1 stale file(s)"* ]] && echo yes)"

  # State isolation: pending work in the main checkout must not fire in a
  # clean worktree, and vice versa.
  rm -f "$wt/docs/codemap/.stale" "$sib/docs/codemap/.stale"
  printf 'src/A.ts\n' > "$repo/docs/codemap/.stale"
  check "worktree: main-checkout backlog does not fire in a clean worktree" \
    "0" "$(guard_at "$repo" "$wt" "git commit -m x" >/dev/null; echo $?)"
  check "worktree: main-checkout backlog still fires with cwd at the main root" \
    "2" "$(guard_at "$repo" "$repo" "git commit -m x" >/dev/null; echo $?)"
  check "worktree: cwd in a source subdirectory resolves to the checkout root" \
    "2" "$(guard_at "$repo" "$repo/src" "git commit -m x" >/dev/null; echo $?)"

  stale "$repo" "$repo/src/A.ts" >/dev/null
  check "worktree: ordinary in-repo edit still records normally" \
    "yes" "$(grep -qxF "src/A.ts" "$repo/docs/codemap/.stale" && echo yes)"

  # Monorepo subproject ownership must survive a worktree (F4): the configured
  # project sits below the git toplevel, and every worktree of the repo holds
  # the same subproject at the same relative path.
  mono="$work/mono"
  git init -q -b main "$mono"
  mkdir -p "$mono/apps/service/docs/codemap" "$mono/apps/service/src"
  echo index > "$mono/apps/service/docs/codemap/README.md"
  touch "$mono/apps/service/src/A.ts"
  git -C "$mono" add -A
  git -C "$mono" -c user.name=t -c user.email=t@t commit -qm init
  mwt="$work/mono-feature"
  git -C "$mono" worktree add -q "$mwt" -b mono-feat
  msub="$mono/apps/service"
  wsub="$mwt/apps/service"

  stale "$msub" "$wsub/src/A.ts" >/dev/null
  check "monorepo-worktree: edit lands in the worktree subproject's own .stale" \
    "src/A.ts" "$(cat "$wsub/docs/codemap/.stale" 2>/dev/null)"
  check "monorepo-worktree: original subproject's .stale stays untouched" \
    "yes" "$([[ ! -s "$msub/docs/codemap/.stale" ]] && echo yes)"
  check "monorepo-worktree: pending entries fire the guard from the worktree" \
    "2" "$(guard_at "$msub" "$wsub" "git commit -m x" >/dev/null; echo $?)"
  check "monorepo-worktree: guard resolves from a deeper source directory too" \
    "2" "$(guard_at "$msub" "$wsub/src" "git commit -m x" >/dev/null; echo $?)"
  check "monorepo-worktree: announce counts the worktree subproject's queue" \
    "yes" "$([[ "$(announce_at "$msub" "$wsub")" == *"Currently 1 stale file(s)"* ]] && echo yes)"

  stale "$msub" "$msub/src/A.ts" >/dev/null
  check "monorepo-worktree: original subproject edits still record normally" \
    "src/A.ts" "$(cat "$msub/docs/codemap/.stale")"
else
  echo "SKIP: git not on PATH — worktree cases not run" >&2
fi

# --- missing jq (dependency contract, R3) ------------------------------------
# Without jq the hooks cannot parse their payloads. In a codemap project they
# must say so (install hint, non-zero for the tracking hooks) instead of
# pretending the edit or commit was handled; elsewhere they stay silent.

: > "$proj/docs/codemap/.stale"
stale_payload=$(jq -cn --arg f "$proj/Foo.swift" '{"tool_input":{"file_path":$f}}')
out=$(stale_nojq "$proj" "$stale_payload")
check "no-jq: stale hook exits 2 in a codemap project" \
  "2" "$(stale_nojq "$proj" "$stale_payload" >/dev/null; echo $?)"
check "no-jq: stale hook names jq in its diagnostic" \
  "yes" "$([[ "$out" == *jq* ]] && echo yes)"
check "no-jq: stale hook records nothing" \
  "0" "$(grep -c . "$proj/docs/codemap/.stale" 2>/dev/null)"

printf 'a.swift\n' > "$proj/docs/codemap/.stale"
guard_payload=$(jq -cn --arg c "git commit -m x" '{"tool_input":{"command":$c}}')
out=$(guard_nojq "$proj" "$guard_payload")
check "no-jq: guard exits 2 in a codemap project" \
  "2" "$(guard_nojq "$proj" "$guard_payload" >/dev/null; echo $?)"
check "no-jq: guard names jq in its diagnostic" \
  "yes" "$([[ "$out" == *jq* ]] && echo yes)"

out=$(announce_nojq "$proj")
check "no-jq: announce reports the missing dependency at session start" \
  "yes" "$([[ "$out" == *jq* && "$out" == *codemap* ]] && echo yes)"

check "no-jq: hooks stay silent in a project without docs/codemap/" \
  "" "$(stale_nojq "$work/bare" "$stale_payload"; guard_nojq "$work/bare" "$guard_payload"; announce_nojq "$work/bare")"

# The diagnostic gate must consult the active checkout, not only the original
# project root (F5): here only the worktree opted in, and the hook's own
# working directory is the JSON-free context that finds it.
if command -v git >/dev/null 2>&1; then
  f5r="$work/f5repo"
  git init -q -b main "$f5r"
  touch "$f5r/A.ts"
  git -C "$f5r" add -A
  git -C "$f5r" -c user.name=t -c user.email=t@t commit -qm init
  f5wt="$work/f5-feature"
  git -C "$f5r" worktree add -q "$f5wt" -b f5-feat
  mkdir -p "$f5wt/docs/codemap"

  out=$(stale_nojq "$f5r" "$stale_payload" "$f5wt")
  check "no-jq: stale hook exits 2 when only the active worktree opted in" \
    "2" "$(stale_nojq "$f5r" "$stale_payload" "$f5wt" >/dev/null; echo $?)"
  check "no-jq: worktree stale diagnostic names jq" \
    "yes" "$([[ "$out" == *jq* ]] && echo yes)"
  check "no-jq: guard exits 2 when only the active worktree opted in" \
    "2" "$(guard_nojq "$f5r" "$guard_payload" "$f5wt" >/dev/null; echo $?)"
  check "no-jq: announce reports the missing dependency from the worktree" \
    "yes" "$([[ "$(announce_nojq "$f5r" "$f5wt")" == *jq* ]] && echo yes)"
else
  echo "SKIP: git not on PATH — no-jq worktree cases not run" >&2
fi

# -----------------------------------------------------------------------------

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
