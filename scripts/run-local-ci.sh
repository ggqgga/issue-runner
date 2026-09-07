#!/usr/bin/env bash
# usage: run-local-ci.sh <owner/repo> <issue-number>
# worktree 에서 bin/ci 를 실행하고 결과를 local-ci 캐시에 기록한다.
# 캐시 키: <메인 레포 경로 slug>/<worktree HEAD SHA>.result — 사람이 메인 체크아웃에서
# `gh pr merge` 할 때 ci-gate-before-pr-merge.sh 가 읽는 위치와 일치해야 한다.
#
# 워커가 push 직후 직접 호출한다. push hook(local-ci.sh)은 워커 환경에서 cwd 문제로
# 발동하지 못하므로(세션 cwd가 비 git 디렉토리) 이 스크립트가 그 역할을 대신한다.
# 레포가 local-ci 옵트인(실행 가능한 bin/ci — 언어 무관)이 아니면 no-op.
# 가드는 전역 hook(local-ci.sh / ci-gate-before-pr-merge.sh)과 동일해야 한다 —
# hook 은 `[ -x bin/ci ]` 단독 가드라 config/ci.rb 를 추가로 요구하면
# 비-Rails 레포(예: Python)에서 여기만 skip 되어 캐시가 안 남고 머지 게이트에 걸린다.
# 종료 코드: 큐(ci-queue.sh run)의 것을 그대로 — 0=pass · 1=fail · 2=폐기(HEAD 이동) · 3=부재 · 124=대기 포기.
set -uo pipefail
repo="${1:?usage: run-local-ci.sh <owner/repo> <num>}"
num="${2:?usage: run-local-ci.sh <owner/repo> <num>}"
dir="$("$(cd "$(dirname "$0")" && pwd)/repo-dir.sh" "$repo")"
wt="$dir/.claude/worktrees/issue-$num"

[ -d "$wt" ] || { echo "run-local-ci: worktree 없음 ($wt)" >&2; exit 1; }
if [ ! -x "$wt/bin/ci" ]; then
  echo "run-local-ci: 레포가 local-ci 옵트인이 아님 — skip"
  exit 0
fi

sha=$(git -C "$wt" rev-parse HEAD)
short=$(printf '%s' "$sha" | cut -c1-8)
# slug 는 물리 경로 기준 — repo-dir.sh 가 물리 경로로 정규화해 주므로 $dir 그대로 사용.
# (사람이 실제 경로에서 머지할 때 게이트가 계산하는 slug 와 일치해야 한다.)
slug=$(printf '%s' "$dir" | sed 's#[/ ]#_#g; s#^_##')

# 박스 전역 큐 경유(#127) — 다른 세션·워크트리의 bin/ci 와 직렬화된다. 동기: 큐에서 기다렸다
# 실행하고 돌아온다(기존 계약 그대로 — 호출자는 끝날 때까지 블록). 결과 위치는 위 슬러그로
# 지정하고(디렉터리도 큐가 만든다), commit status(pending 대기열→실행 중→success/failure) 도 큐가 게시한다(#6).
# 종료 코드: 0=pass · 1=fail · 2=폐기(실행 시점 HEAD ≠ sha — 그 사이 워크트리가 움직임) · 3=워크트리 부재.
here_ci="$(cd "$(dirname "$0")" && pwd)/ci-queue.sh"
rc=0
"$here_ci" run "$wt" "$sha" --slug "$slug" --repo "$repo" || rc=$?
case "$rc" in
  0|1) echo "run-local-ci: $("$here_ci" result "$sha") ($short)" ;;   # dedup 이면 다른 슬러그일 수 있어 실경로를 큐에 묻는다
  2) echo "run-local-ci: 폐기 ($short) — 실행 시점 HEAD 가 달라 결과 없음. 현재 HEAD 로 다시 호출하라" >&2 ;;
  *) echo "run-local-ci: 큐 실행 실패 (exit $rc, $short)" >&2 ;;
esac
exit "$rc"   # 큐의 계약을 그대로 전달(0 pass · 1 fail · 2 폐기 · 3 부재 · 124) — 2 를 1 로 뭉개면 호출자가 재시도 정책을 오판한다
