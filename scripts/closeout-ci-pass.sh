#!/usr/bin/env bash
# PR head SHA 의 로컬 CI 캐시가 pass 면 exit 0, 아니면(fail·진행중·없음) exit 1.
# ci-gate-before-pr-merge.sh 의 로컬 CI 분기와 동일 계약 — closeout 진입 조건용.
set -uo pipefail
repo=${1:?repo}; pr=${2:?pr_num}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

root=$("$SCRIPT_DIR/repo-dir.sh" "$repo" 2>/dev/null)
[ -n "$root" ] && [ -x "$root/bin/ci" ] || exit 1   # 로컬 CI 옵트인 레포만 대상

sha=$(gh pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null \
  | jq -r '.headRefOid // empty')
[ -n "$sha" ] || exit 1

slug=$(printf '%s' "$root" | sed 's#[/ ]#_#g; s#^_##')
result="$HOME/.claude/.local-ci/$slug/$sha.result"
[ -f "$result" ] && [ "$(cat "$result" 2>/dev/null)" = pass ]
