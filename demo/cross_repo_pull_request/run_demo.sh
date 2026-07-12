#!/usr/bin/env bash
# CROSS-REPO PULL REQUEST — "someone opens a PR against my doc; I stay
# sovereign — I apply it as MY OWN commit or I refuse it, and a forged PR
# cannot force a change."
#
# Two separate-rooted Commonplace workspaces as two plain OS processes.
# NO shared Erlang cookie, NO epmd, NO BEAM distribution — each peer is just
# an HTTP URL to the other. Bidirectional Slice-0 federation (both serve AND
# subscribe) + the B2 merge-request machinery (MergeRequest/Outbox/Apply).
#
#   REVIEWER  — OWNS doc D, sovereign. Grants PROPOSER a :read cert on D,
#               subscribes to PROPOSER's outbox, and per proposal either
#               APPLIES it as its OWN commit or REFUSES a forged one.
#   PROPOSER  — replicates D, authors a signed delta, publishes it to its
#               outbox as a merge-request, then drops a stranger-FORGED PR.
#
# Run from repo root:  bash demo/cross_repo_pull_request/run_demo.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SHARED="$(mktemp -d /tmp/cp_xrepo_pr.XXXXXX)"
DIR_REVIEWER="$SHARED/reviewer/.commonplace"
DIR_PROPOSER="$SHARED/proposer/.commonplace"
mkdir -p "$DIR_REVIEWER" "$DIR_PROPOSER"
PORT_REVIEWER=$((43000 + RANDOM % 2000))
PORT_PROPOSER=$((43000 + RANDOM % 2000))

cleanup() {
  # EXACT-target kills only — never a broad beam/elixir sweep.
  pkill -f "cross_repo_pull_request/reviewer.exs" 2>/dev/null || true
  pkill -f "cross_repo_pull_request/proposer.exs" 2>/dev/null || true
  [ -n "${CP_KEEP_SHARED:-}" ] || rm -rf "$SHARED"
}
trap cleanup EXIT
echo "SHARED=$SHARED  PORT_REVIEWER=$PORT_REVIEWER  PORT_PROPOSER=$PORT_PROPOSER"
echo "(no epmd, no cookie, no --sname, no BEAM distribution below)"

echo "=== launching REVIEWER (owner of D; sovereign apply-gate) ==="
setsid elixir -S mix run --no-start demo/cross_repo_pull_request/reviewer.exs "$DIR_REVIEWER" "$SHARED" "$PORT_REVIEWER" \
  > "$SHARED/reviewer.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

echo "=== launching PROPOSER (opens the PR; separate trust domain) ==="
setsid elixir -S mix run --no-start demo/cross_repo_pull_request/proposer.exs "$DIR_PROPOSER" "$SHARED" "$PORT_PROPOSER" \
  > "$SHARED/proposer.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

# Wait for REVIEWER to finish (it writes reviewer_done with its exit code).
for _ in $(seq 1 180); do
  [ -f "$SHARED/reviewer_done" ] && break
  sleep 0.5
done

echo
echo "=== interleaved [PROPOSER]/[REVIEWER] transcript (by wall-clock ms) ==="
if [ -f "$SHARED/session.log" ]; then
  sort -n "$SHARED/session.log" | sed 's/^[0-9]* //'
else
  echo "(no session log produced)"; echo "--- REVIEWER log ---"; cat "$SHARED/reviewer.log"
  echo "--- PROPOSER log ---"; cat "$SHARED/proposer.log"
fi

RC=1
if [ -f "$SHARED/reviewer_done" ]; then
  RC="$(cat "$SHARED/reviewer_done")"
else
  echo "!! REVIEWER never signalled done — dumping logs:"
  echo "--- REVIEWER log ---"; cat "$SHARED/reviewer.log"
  echo "--- PROPOSER log ---"; cat "$SHARED/proposer.log"
fi

# Independently confirm all three money-shots are present in the transcript.
SHOTS_OK=1
if [ -f "$SHARED/session.log" ]; then
  grep -q "MONEY-SHOT #1" "$SHARED/session.log" || SHOTS_OK=0
  grep -q "MONEY-SHOT #2" "$SHARED/session.log" || SHOTS_OK=0
  grep -q "MONEY-SHOT #3" "$SHARED/session.log" || SHOTS_OK=0
else
  SHOTS_OK=0
fi

echo
echo "=== done (reviewer rc=$RC, money-shots present=$SHOTS_OK) ==="
if [ "$RC" = "0" ] && [ "$SHOTS_OK" = "1" ]; then
  exit 0
else
  exit 1
fi
