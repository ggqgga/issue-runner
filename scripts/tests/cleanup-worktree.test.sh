#!/usr/bin/env bash
# cleanup-worktree.sh 픽스처 테스트 — 네트워크 무접속(실제 git worktree 로 돌린다).
#
# #62: reconcile.sh 와 closeout-reconcile.sh(MERGED 분기)가 공유하는 worktree 처분 헬퍼다.
# 두 방향으로 치명적이라 네 갈래를 전부 문다:
#   ⑴ clean + `--merged` → 실제로 제거된다(안 지우면 워크트리가 무한히 쌓인다)
#   ⑵ 더티 → 제거 보류 + warn JSON. `--merged` 여도 더티 가드는 유지한다(작업 유실 방지)
#   ⑶ 플래그 없는 기본 호출 + upstream 없음 → 미push 가드로 보류 + warn JSON
#      (`--merged` 는 squash 머지로 원격 head 가 사라지는 함정에서만 이 가드를 푼다)
#   ⑷ worktree 가 이미 없으면 no-op — exit 0·무출력(멱등)
# warn JSON 은 산문이 아니라 **계약**이다 — 호출측 reconcile 이 그 줄을 이벤트로 파싱한다.
#
# SUT 는 sibling 경로로 repo-dir.sh 를 부르므로 사본을 tmp 로 옮기지 않고 제자리에서 돌린다.
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/cleanup-worktree.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

mk_repo() {  # mk_repo <issue-num> — o/r 레포 + agent/issue-<N> worktree 를 새로 만든다
  rm -rf "$tmp/proj"; mkdir -p "$tmp/proj/r"
  git -C "$tmp/proj/r" init -q
  git -C "$tmp/proj/r" config user.email t@t
  git -C "$tmp/proj/r" config user.name t
  git -C "$tmp/proj/r" commit -q --allow-empty -m init
  git -C "$tmp/proj/r" worktree add -q -b "agent/issue-$1" \
    "$tmp/proj/r/.claude/worktrees/issue-$1" >/dev/null 2>&1
}
run_clean() {  # run_clean <repo> <issue-num> [--merged] — OUT/RC 를 채운다
  # repos.conf 는 머신별이라 반드시 갈아끼운다(있으면 repo-dir.sh 가 남의 매핑을 읽는다).
  OUT=$(ISSUE_RUNNER_REPOS_CONF="$tmp/none.conf" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
        bash "$SUT" "$@" 2>&1)
  RC=$?
}

echo "── ⑴ clean + --merged → 제거 ──────────────────────────────────────"
mk_repo 5
run_clean o/r 5 --merged
[ "$RC" = 0 ] && ok || bad "⑴ exit $RC (기대 0) out=[$OUT]"
[ ! -d "$tmp/proj/r/.claude/worktrees/issue-5" ] && ok || bad "⑴ worktree 가 안 지워졌다"
[ -z "$OUT" ] && ok || bad "⑴ 성공 경로인데 출력이 있다: [$OUT] (이벤트 JSON 은 호출측 몫)"

echo "── ⑵ 더티 + --merged → 보류 ───────────────────────────────────────"
mk_repo 6
echo dirty > "$tmp/proj/r/.claude/worktrees/issue-6/x.txt"
git -C "$tmp/proj/r/.claude/worktrees/issue-6" add x.txt   # 추적 대상으로 올려 더티 확정
run_clean o/r 6 --merged
[ "$RC" = 1 ] && ok || bad "⑵ exit $RC (기대 1)"
printf '%s' "$OUT" | jq -e 'select(.event=="warn" and .number==6)' >/dev/null 2>&1 && ok \
  || bad "⑵ warn JSON 누락 out=[$OUT]"
[ -d "$tmp/proj/r/.claude/worktrees/issue-6" ] && ok || bad "⑵ 더티인데 제거됐다(작업 유실)"

echo "── ⑶ 기본 호출 + upstream 없음 → 미push 가드 ──────────────────────"
mk_repo 7
run_clean o/r 7
[ "$RC" = 1 ] && ok || bad "⑶ exit $RC (기대 1)"
printf '%s' "$OUT" | jq -e 'select(.event=="warn" and .number==7)' >/dev/null 2>&1 && ok \
  || bad "⑶ warn JSON 누락 out=[$OUT]"
[ -d "$tmp/proj/r/.claude/worktrees/issue-7" ] && ok || bad "⑶ 미push 인데 제거됐다"

echo "── ⑷ worktree 없음 → 멱등 no-op ──────────────────────────────────"
rm -rf "$tmp/proj"; mkdir -p "$tmp/proj/r"
git -C "$tmp/proj/r" init -q
run_clean o/r 99 --merged
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "⑷ exit $RC out=[$OUT] (기대 0·무출력)"

echo "cleanup-worktree.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
