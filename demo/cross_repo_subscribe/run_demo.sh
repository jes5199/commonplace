#!/usr/bin/env bash
# CROSS-REPO LIVE SUBSCRIPTION — "my main server subscribes to the other
# server, and when the other edits, my replica updates live."
#
# Two separate-rooted Commonplace workspaces as two plain OS processes.
# NO shared Erlang cookie, NO epmd, NO BEAM distribution — OTHER is just
# an HTTP URL to MAIN. Reuses the cross-repo Slice-0 federation machinery
# (PullClient poll loop + PeerTrust root-pinning + the :read-cert-gated
# federation serve with existence-hiding).
#
#   OTHER — owns doc D, grants MAIN a scoped :read cert (D only, not E),
#           serves federation over HTTP, then edits D three times.
#   MAIN  — pins OTHER's root, subscribes to D via PullClient, and prints
#           D's replicated content each poll as OTHER's edits land. Its
#           attempt to read the ungranted doc E is existence-hidden.
#
# Run from repo root:  bash demo/cross_repo_subscribe/run_demo.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SHARED="$(mktemp -d /tmp/cp_xrepo_sub.XXXXXX)"
DIR_OTHER="$SHARED/otherA/.commonplace"
DIR_MAIN="$SHARED/mainB/.commonplace"
mkdir -p "$DIR_OTHER" "$DIR_MAIN"
PORT=$((43000 + RANDOM % 2000))

cleanup() {
  # EXACT-target kills only — never a broad beam/elixir sweep.
  pkill -f "cross_repo_subscribe/other.exs" 2>/dev/null || true
  pkill -f "cross_repo_subscribe/main.exs" 2>/dev/null || true
  [ -n "${CP_KEEP_SHARED:-}" ] || rm -rf "$SHARED"
}
trap cleanup EXIT
echo "SHARED=$SHARED  PORT=$PORT"
echo "(no epmd, no cookie, no --sname, no BEAM distribution below)"

echo "=== launching OTHER (host of D; :read-cert-gated federation serve) ==="
setsid elixir -S mix run --no-start demo/cross_repo_subscribe/other.exs "$DIR_OTHER" "$SHARED" "$PORT" \
  > "$SHARED/other.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

echo "=== launching MAIN (subscriber; separate trust domain) ==="
setsid elixir -S mix run --no-start demo/cross_repo_subscribe/main.exs "$DIR_MAIN" "$SHARED" \
  > "$SHARED/main.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

# Wait for MAIN to finish (it writes main_done with its exit code).
for _ in $(seq 1 120); do
  [ -f "$SHARED/main_done" ] && break
  sleep 0.5
done

echo
echo "=== interleaved [OTHER]/[MAIN] transcript (by wall-clock ms) ==="
if [ -f "$SHARED/session.log" ]; then
  sort -n "$SHARED/session.log" | sed 's/^[0-9]* //'
else
  echo "(no session log produced)"; echo "--- OTHER log ---"; cat "$SHARED/other.log"
  echo "--- MAIN log ---"; cat "$SHARED/main.log"
fi

RC=1
if [ -f "$SHARED/main_done" ]; then
  RC="$(cat "$SHARED/main_done")"
else
  echo "!! MAIN never signalled done — dumping logs:"
  echo "--- OTHER log ---"; cat "$SHARED/other.log"
  echo "--- MAIN log ---"; cat "$SHARED/main.log"
fi

echo
echo "=== done (main rc=$RC) ==="
exit "$RC"
