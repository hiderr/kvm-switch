#!/bin/bash
# Agent-to-agent chat over the `agent-debug` git branch.
# Each agent writes only to its OWN file (comm/<me>.log) => no merge conflicts.
#   KVM_AGENT=claude ./chat.sh send "hello"
#   ./chat.sh read           # print merged conversation, newest last
#   ./chat.sh wait [secs]    # block until a NEW peer message appears (poll)
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root of this worktree (branch agent-debug)
BRANCH=agent-debug
ME="${KVM_AGENT:-}"
CMD="${1:-read}"

# Resolve a GitHub token with push access to hiderr/kvm-switch.
# Prefer the `hiderr` account; fall back to the active gh account.
auth_header() {
  local t
  t=$(gh auth token --user hiderr 2>/dev/null) || t=$(gh auth token 2>/dev/null) || t=""
  [ -n "$t" ] || return 0
  printf 'Authorization: Basic %s' "$(printf 'x-access-token:%s' "$t" | base64 | tr -d '\n')"
}
HDR="$(auth_header)"
gitx() { if [ -n "$HDR" ]; then git -c http.extraheader="$HDR" "$@"; else git "$@"; fi; }

case "$CMD" in
  send)
    [ -n "$ME" ] || { echo "ERROR: set KVM_AGENT=claude|codex"; exit 1; }
    MSG="${2:-}"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gitx fetch -q origin "$BRANCH"
    git rebase -q "origin/$BRANCH" 2>/dev/null || { git rebase --abort 2>/dev/null || true; git reset -q --hard "origin/$BRANCH"; }
    mkdir -p comm
    printf '[%s] %s: %s\n' "$ts" "$ME" "$MSG" >> "comm/$ME.log"
    git add "comm/$ME.log"
    git commit -q -m "chat($ME) $ts"
    gitx push -q origin "HEAD:$BRANCH" || {
      gitx fetch -q origin "$BRANCH"; git rebase -q "origin/$BRANCH"; gitx push -q origin "HEAD:$BRANCH";
    }
    echo "sent @ $ts"
    ;;
  read)
    gitx fetch -q origin "$BRANCH" 2>/dev/null || true
    echo "===== conversation (newest last) ====="
    { git show "origin/$BRANCH:comm/claude.log" 2>/dev/null || true
      git show "origin/$BRANCH:comm/codex.log"  2>/dev/null || true; } | sort
    ;;
  wait)
    SECS="${2:-20}"
    peer="codex"; [ "$ME" = "codex" ] && peer="claude"
    before=$(git show "origin/$BRANCH:comm/$peer.log" 2>/dev/null | wc -l | tr -d ' ')
    end=$(( $(date +%s) + SECS ))
    while [ "$(date +%s)" -lt "$end" ]; do
      gitx fetch -q origin "$BRANCH" 2>/dev/null || true
      now=$(git show "origin/$BRANCH:comm/$peer.log" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$now" -gt "$before" ]; then
        git show "origin/$BRANCH:comm/$peer.log" 2>/dev/null | tail -n $(( now - before ))
        exit 0
      fi
      sleep 3
    done
    echo "(no new $peer message in ${SECS}s)"
    ;;
  *)
    echo "usage: KVM_AGENT=claude|codex $0 {send \"msg\"|read|wait [secs]}"
    ;;
esac
