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
# 종료 코드: pass=0, fail=1 (워커가 실패를 인지하고 고치도록).
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
out="$HOME/.claude/.local-ci/$slug"
mkdir -p "$out"

if (cd "$wt" && bin/ci >"$out/$sha.log" 2>&1); then verdict=pass; else verdict=fail; fi
printf '%s\n' "$verdict" > "$out/$sha.result"
echo "run-local-ci: $verdict ($short) → $out/$sha.result"

# GitHub commit status 게시 — 웹 머지 UI에서도 local-ci 결과가 보이게 (#6).
# 실패(네트워크, 미push SHA 등)는 경고만 — CI 판정/exit code 에 영향 없음.
if [ "$verdict" = "pass" ]; then state=success; else state=failure; fi
if gh api "repos/$repo/statuses/$sha" \
     -f state="$state" -f context=local-ci \
     -f description="bin/ci $verdict ($short)" >/dev/null 2>&1; then
  echo "run-local-ci: commit status 게시됨 — local-ci=$state ($short)"
else
  echo "run-local-ci: 경고 — commit status 게시 실패 ($repo@$short), CI 판정에는 영향 없음" >&2
fi

[ "$verdict" = "pass" ]
