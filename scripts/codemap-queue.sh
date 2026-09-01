#!/bin/bash
# codemap-queue.sh — the single executable owner of the codemap refresh queue.
# The refresh workflow and the tests both run these operations; the queue files
# (.stale, .stale.claimed, .stale.batch, .stale.claim-token) are never edited
# by hand or by ad-hoc shell snippets.
#
#   codemap-queue.sh claim [project-root]
#       Atomically move everything pending — the live queue, plus any batch or
#       claimed file left by an interrupted refresh — into .stale.claimed and
#       take ownership of it. Prints "token <value>" and then the claimed
#       paths, one per line (sorted, deduplicated). Re-running claim is the
#       recovery mechanism: it merges unfinished work and issues a new token,
#       which invalidates the previous claimant.
#   codemap-queue.sh complete <token> [project-root]
#       Delete the claimed batch, but only if <token> still owns it. A stale
#       token (a newer claim absorbed the batch) deletes nothing and exits 1.
#   codemap-queue.sh pending [project-root]
#       Print the number of unique paths awaiting a refresh.
#
# All queue transitions run under the same lock as the hook that appends to
# .stale, so a claim can never race a half-finished append (or vice versa).
# project-root defaults to the checkout owning the current directory.

set -u

# shellcheck source=scripts/codemap-lib.sh disable=SC1091
. "${BASH_SOURCE[0]%/*}/codemap-lib.sh"

die() { printf 'codemap-queue: %s\n' "$1" >&2; exit 1; }

op="${1:-}"
case "$op" in
  claim)    root_arg="${2:-}" ;;
  complete) token_arg="${2:-}"; root_arg="${3:-}"
            [[ -n "$token_arg" ]] || die "complete needs the token printed by claim (usage: complete <token> [project-root])" ;;
  pending)  root_arg="${2:-}" ;;
  *) die "usage: codemap-queue.sh claim [project-root] | complete <token> [project-root] | pending [project-root]" ;;
esac

if [[ -n "$root_arg" ]]; then
  [[ -d "$root_arg/docs/codemap" ]] || die "no docs/codemap under $root_arg"
  root="$root_arg"
else
  root=$(codemap_root "$PWD") || die "no opted-in checkout owns $PWD (pass the project root explicitly)"
fi
root=$(cd "$root" 2>/dev/null && pwd -P) || die "cannot resolve $root"
d="$root/docs/codemap"
claimed="$d/.stale.claimed"
tokenfile="$d/.stale.claim-token"

if [[ "$op" == "pending" ]]; then
  codemap_pending_count "$root"
  exit 0
fi

codemap_lock "$root" || die "could not acquire $d/.stale.lock — another queue operation is stuck; nothing was changed. If no codemap process is running, remove the stuck .stale.lock (and .stale.lock.breaker if present) by hand"
trap codemap_unlock EXIT

case "$op" in
  claim)
    # Revoke the previous claimant FIRST: everything absorbed below becomes
    # deletable by whoever holds the current token, so the old token must stop
    # working before the batch it authorizes can grow (review G2). If this
    # claim fails or dies at any later point, no token exists — the old
    # refresher's complete is refused, every merged path stays on disk and
    # counted, and re-running claim recovers the batch under a fresh token.
    rm -f "$tokenfile" || die "failed to revoke the previous claim token"
    # Absorb order does not matter for safety (append-before-remove keeps every
    # path counted at any crash point); batch first only to mirror its age.
    codemap_absorb "$d/.stale.batch" "$claimed" || die "failed to absorb .stale.batch"
    codemap_absorb "$d/.stale" "$claimed"       || die "failed to absorb .stale"
    # The batch may be deleted as empty only on a POSITIVE no-content answer
    # (grep exit 1). Exit >1 is a read/execution error, not a determination
    # that nothing is pending — deleting on it destroyed the whole batch
    # (review H3). On probe failure the batch stays put and the claim fails;
    # the token is already revoked, so re-running claim recovers everything.
    probe=1
    if [[ -s "$claimed" ]]; then
      grep -q . "$claimed"
      probe=$?
      (( probe > 1 )) && die "could not inspect the claimed batch (grep exit $probe) — nothing was deleted; re-run claim"
    fi
    if (( probe != 0 )); then
      rm -f "$claimed" "$tokenfile"
      printf 'codemap: nothing pending to claim.\n'
      exit 0
    fi
    tmp="$claimed.tmp.$$"
    # The pipeline's observed status is grep's alone: a sort that emits some
    # lines and then dies looks like success, and the mv would replace the
    # full batch with the fragment (review H2). Gate the rewrite on both
    # stages, keeping the batch unchanged on any normalization failure.
    sort -u "$claimed" | grep . > "$tmp"
    norm=("${PIPESTATUS[@]}")
    if (( norm[0] != 0 || norm[1] != 0 )); then
      rm -f "$tmp"
      die "failed to normalize the claimed batch — it was left unchanged and no token was issued; re-run claim"
    fi
    mv "$tmp" "$claimed" || { rm -f "$tmp"; die "failed to rewrite $claimed"; }
    token=$( (od -An -N8 -tx1 /dev/urandom 2>/dev/null || printf '%s.%s.%s' "$$" "$SECONDS" "$RANDOM") | tr -d ' \n')
    # Deliver, then arm. The snapshot read-back and the token+snapshot output
    # are checked operations, and the token is recorded only after the full
    # snapshot went out (review I1: the final read was unchecked and the
    # token was already on disk, so a partial delivery exited 0 and its token
    # authorized deleting paths the caller never saw). If any delivery step
    # fails, no token is armed — a token line the caller may have seen is
    # refused by complete — the batch stays claimed on disk, and re-running
    # claim recovers it.
    snapshot=$(cat "$claimed") || die "failed to read back the claimed batch — it is preserved; re-run claim"
    printf 'token %s\n%s\n' "$token" "$snapshot" || die "failed to deliver the claim snapshot — the batch is preserved and the printed token is not valid; re-run claim"
    printf '%s\n' "$token" > "$tokenfile" || die "failed to record the claim token — the batch is preserved and the printed token is not valid; re-run claim"
    ;;
  complete)
    stored=""
    [[ -f "$tokenfile" ]] && stored=$(cat "$tokenfile")
    if [[ -z "$stored" && ! -f "$claimed" ]]; then
      die "nothing is claimed — run claim first"
    fi
    if [[ "$stored" != "$token_arg" ]]; then
      die "stale token — a newer claim took ownership of the batch, or a takeover was interrupted after revoking it; your unfinished paths are still in the batch and nothing was deleted. Re-run claim to take over the current batch"
    fi
    # Claimed-first ordering: if this is interrupted in between, the orphaned
    # token matches an absent batch, and retrying complete below succeeds.
    rm -f "$claimed" || die "failed to remove the claimed batch — it remains pending under the same token; re-run complete with that token"
    rm -f "$tokenfile" || die "failed to remove the claim token after completing the batch — re-run complete with the same token to finish cleanup"
    printf 'codemap: refresh batch completed.\n'
    ;;
esac
exit 0
