#!/usr/bin/env bash
# usage: repo-dir.sh <owner/repo>
# 레포의 로컬 경로를 stdout 에 출력한다. 우선순위:
#   1) repos.conf 매핑 (형식: "<owner/repo> <절대경로> [flag ...]" — 공백 구분, 경로에
#      공백 불가, # 시작 줄은 주석. 경로 자리의 `-` 는 "기본 경로 그대로"를 뜻한다
#      (플래그만 주려는 줄 — repo-flag.sh 참조). repos.conf 는 gitignore — 머신마다
#      다르다. 예시는 repos.conf.example)
#   2) $ISSUE_RUNNER_PROJECTS_ROOT/<repo-name> (기본값: $HOME/Projects)
# 디렉토리가 존재하면 물리 경로(pwd -P)로 정규화해 출력 — local-ci slug 계산이
# 사람의 머지 게이트(실제 경로 기준)와 일치해야 하기 때문.
#
# 테스트용 env: ISSUE_RUNNER_REPOS_CONF 로 conf 경로를 갈아끼운다.
set -euo pipefail
repo="${1:?usage: repo-dir.sh <owner/repo>}"
name=${repo#*/}
base="$(cd "$(dirname "$0")/.." && pwd)"
conf="${ISSUE_RUNNER_REPOS_CONF:-$base/repos.conf}"

dir=""
if [ -f "$conf" ]; then
  dir=$(awk -v r="$repo" '!/^[[:space:]]*#/ && $1==r {print $2; exit}' "$conf")
fi
[ "$dir" = "-" ] && dir=""          # 경로 자리 `-` = 기본 경로 해석으로 폴백
[ -z "$dir" ] && dir="${ISSUE_RUNNER_PROJECTS_ROOT:-$HOME/Projects}/$name"

# ~ 확장 (conf 에 ~/ 로 적은 경우)
# SC2088: "~/"* 는 conf 입력의 리터럴 틸드 접두를 매칭하는 패턴 — 확장 의도 아님(다음 줄이 $HOME 치환).
# shellcheck disable=SC2088
case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac

if [ -d "$dir" ]; then
  (cd "$dir" && pwd -P)
else
  printf '%s\n' "$dir"
fi
