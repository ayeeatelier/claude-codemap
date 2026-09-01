# shellcheck shell=bash
# Shared helpers sourced by the codemap hook scripts and codemap-queue.sh.
# Not executable on its own.

# Appended to every missing-jq diagnostic so the fix is actionable in place.
# jq is a hard dependency: approximating the hook JSON with sed silently lost
# any payload using escaped quotes, backslashes, \uXXXX, or newlines.
# shellcheck disable=SC2034 # consumed by the hooks that source this file
CODEMAP_JQ_HINT="install jq to re-enable the codemap hooks (macOS: brew install jq, Debian/Ubuntu: sudo apt-get install jq)"

# codemap_root <context-dir>
# Print the root of the checkout whose docs/codemap owns <context-dir>, or
# return 1 when no opted-in checkout owns it. CLAUDE_PROJECT_DIR alone is not
# enough: it stays at the original project root for the whole session, so a
# git worktree entered later would read and write the wrong checkout's state.
#   1. CLAUDE_PROJECT_DIR wins while the context is in the same checkout —
#      this keeps monorepo-subdir projects (project root below the git
#      toplevel) and git-less projects (both toplevels empty) working.
#   2. In a different checkout (a worktree), the configured project keeps its
#      position relative to the git toplevel — a monorepo subproject exists at
#      the same relative path inside every worktree of the repo — so the
#      corresponding opted-in subproject there is used.
#   3. Otherwise the context's own worktree root is used, if it opted in.
codemap_root() {
  local ctx="$1" ctx_top="" cpd cpd_top="" cpd_phys cand
  [[ -n "$ctx" ]] && ctx_top=$(git -C "$ctx" rev-parse --show-toplevel 2>/dev/null)
  cpd="${CLAUDE_PROJECT_DIR:-}"
  cpd="${cpd%/}" # tolerate a trailing slash from wrappers
  if [[ -n "$cpd" && -d "$cpd/docs/codemap" ]]; then
    cpd_top=$(git -C "$cpd" rev-parse --show-toplevel 2>/dev/null)
    if [[ "$cpd_top" == "$ctx_top" ]]; then
      printf '%s\n' "$cpd"
      return 0
    fi
    if [[ -n "$cpd_top" && -n "$ctx_top" ]]; then
      # Physical path for the prefix strip: the toplevel git reports is
      # physical, while the env var may come through a symlink.
      cpd_phys=$(cd "$cpd" 2>/dev/null && pwd -P)
      if [[ "$cpd_phys" == "$cpd_top" || "$cpd_phys" == "$cpd_top"/* ]]; then
        cand="$ctx_top${cpd_phys#"$cpd_top"}"
        if [[ -d "$cand/docs/codemap" ]]; then
          printf '%s\n' "$cand"
          return 0
        fi
      fi
    fi
  fi
  if [[ -n "$ctx_top" && -d "$ctx_top/docs/codemap" ]]; then
    printf '%s\n' "$ctx_top"
    return 0
  fi
  return 1
}

# codemap_nojq_optin
# Whether a missing-jq diagnostic is warranted when the payload cannot be
# parsed: the original project opted in, or the checkout owning the hook
# process's own working directory did (a worktree entered mid-session) —
# $PWD is the fallback context that needs no JSON.
codemap_nojq_optin() {
  local cpd="${CLAUDE_PROJECT_DIR:-}"
  cpd="${cpd%/}"
  [[ -n "$cpd" && -d "$cpd/docs/codemap" ]] && return 0
  codemap_root "$PWD" >/dev/null 2>&1
}

# codemap_pending_count <root>
# Unique non-blank paths awaiting a refresh: the live queue (.stale), a batch
# claimed by an in-progress or interrupted refresh (.stale.claimed), and any
# leftover transient claim file (.stale.batch, written by older claim steps).
# Counting all three means a refresh that died mid-way keeps its work visible
# instead of losing it.
codemap_pending_count() {
  local d="$1/docs/codemap" n
  n=$(cat "$d/.stale" "$d/.stale.claimed" "$d/.stale.batch" 2>/dev/null | sort -u | grep -c .) || n=0
  printf '%s\n' "$n"
}

# --- queue synchronization ----------------------------------------------------
# Every queue writer (the stale hook's dedup+append) and every queue transition
# (claim/complete in codemap-queue.sh) runs inside the same mutex, so a rename
# can never race an already-opened append descriptor (review F1). The mutex is
# a mkdir'd directory: atomic on every platform, no flock needed (absent on
# stock macOS). Critical sections are a few file operations, so contention is
# milliseconds; a lock left by a crashed process is broken by age.
#
# Breaking a crashed holder's lock is itself serialized by a second mkdir
# mutex (.stale.lock.breaker), and the "is it stale?" decision is re-made
# inside it: an age observation made outside can describe a lock that was
# since reaped and re-acquired by someone else, and acting on it would delete
# the new owner's live lock (review G1). A fresh lock always carries a fresh
# mkdir mtime, so the re-check can never authorize reaping it, and with all
# reapers excluded a genuine orphan cannot change identity before the rmdir.
#
# The lock's identity lives in an owner file NAMED after the acquiring
# instance (owner.<pid>.<random>), never in file content that would need a
# compare-then-delete. Unlock removes only its own name and then rmdir, which
# fails while any other instance's owner file is present — so a holder that
# stalled past the reap threshold, lost its lock, and resumes arbitrarily
# later can never delete a successor's lock (review H1: the previous content
# comparison and rm were separate steps, and a comparison saved before the
# reap authorized deleting the successor).

CODEMAP_LOCK_HELD=""
CODEMAP_LOCK_OWNER=""

# codemap_dir_stale <dir>
# Whether <dir> exists and its mtime is past the crashed-holder threshold.
# The threshold (5s) is far above the millisecond critical sections; a live
# process stalled longer than that (SIGSTOP) is the documented limitation.
codemap_dir_stale() {
  local mtime now
  # GNU stat first: BSD stat rejects -c and prints nothing. The order
  # matters — GNU stat reads `-f %m <dir>` as a file-system query with <dir>
  # as the format, prints several lines, and fails, so an `||` chain that
  # starts with the BSD form captures that text ahead of the real value.
  mtime=$(stat -c %Y "$1" 2>/dev/null)
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$(stat -f %m "$1" 2>/dev/null)
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  (( now - mtime > 5 ))
}

# codemap_lock <root>
# Acquire <root>/docs/codemap/.stale.lock. Returns 1 only if the lock (or an
# orphaned breaker, which no automatic recovery can safely remove) stays in
# the way for the whole wait budget (~10s) — callers must then fail loudly
# and leave explicit recovery to a human.
codemap_lock() {
  local lock="$1/docs/codemap/.stale.lock" breaker own f ok tries=0
  breaker="$lock.breaker"
  CODEMAP_LOCK_OWNER="$$.${RANDOM}${RANDOM}"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      # Claim the fresh directory with this instance's own owner file, then
      # verify it is the only one there. The mkdir-to-write gap is the one
      # moment a stalled ex-holder's rmdir can still destroy the directory
      # (H1); if that happened, the write fails or a competitor's owner file
      # from a re-created directory shows up, and this instance backs out and
      # retries. Two instances can both back out of one directory, but never
      # both enter it: entering requires writing before the other's check and
      # checking before the other's write, which cannot hold for both.
      own="$lock/owner.$CODEMAP_LOCK_OWNER"
      ok=0
      if printf '%s\n' "$CODEMAP_LOCK_OWNER" > "$own" 2>/dev/null; then
        ok=1
        for f in "$lock"/owner.*; do
          [[ -e "$f" && "$f" != "$own" ]] && ok=0
        done
      fi
      if (( ok )); then
        CODEMAP_LOCK_HELD="$lock"
        return 0
      fi
      rm -f "$own"
      rmdir "$lock" 2>/dev/null
    elif codemap_dir_stale "$lock"; then
      if mkdir "$breaker" 2>/dev/null; then
        # Authoritative staleness check, now that no other reaper can run:
        # if the lock was reaped and re-acquired since the outer check, its
        # fresh mtime vetoes the reap and the new owner keeps its lock.
        if codemap_dir_stale "$lock"; then
          rm -f "$lock"/owner.*
          # rmdir, not rm -rf: an orphan holds nothing but owner files.
          # Unexpected content means the directory is not ours to destroy —
          # the rmdir fails and the wait budget below ends in the callers'
          # loud manual-recovery diagnostic instead of a silent spin.
          rmdir "$lock" 2>/dev/null
        fi
        rmdir "$breaker" 2>/dev/null
      else
        # Another process is reaping. A breaker past the threshold is itself
        # an orphan; force-removing it would reopen the two-reaper race, so
        # give up.
        codemap_dir_stale "$breaker" && return 1
      fi
    fi
    tries=$((tries + 1))
    (( tries > 200 )) && return 1
    sleep 0.05
  done
}

codemap_unlock() {
  # Remove only this instance's owner file — a name no other instance ever
  # touches — then rmdir, which succeeds only if no other owner file remains.
  # If a reaper broke this lock (the >5s stall case) and a successor acquired
  # a new one at the same path, the rmdir fails on the successor's owner file
  # and its lock is left intact. No comparison step exists to go stale (H1).
  if [[ -n "$CODEMAP_LOCK_HELD" && -n "$CODEMAP_LOCK_OWNER" ]]; then
    rm -f "$CODEMAP_LOCK_HELD/owner.$CODEMAP_LOCK_OWNER"
    rmdir "$CODEMAP_LOCK_HELD" 2>/dev/null
  fi
  CODEMAP_LOCK_HELD=""
  CODEMAP_LOCK_OWNER=""
  return 0
}

# codemap_absorb <src> <dst>
# Append <src>'s lines to <dst> and remove <src>. Append-before-remove keeps
# every path visible to codemap_pending_count at any crash point, and the
# newline repair keeps two paths from concatenating when <dst> lost its
# trailing newline. Call only while holding the queue lock.
codemap_absorb() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  [[ -s "$dst" && -n "$(tail -c1 "$dst" 2>/dev/null)" ]] && printf '\n' >> "$dst"
  cat "$src" >> "$dst" || return 1
  [[ -s "$dst" && -n "$(tail -c1 "$dst" 2>/dev/null)" ]] && printf '\n' >> "$dst"
  rm -f "$src"
}
