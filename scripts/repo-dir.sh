#!/usr/bin/env bash
# usage: repo-dir.sh <owner/repo>
# 레포의 로컬 경로를 stdout 에 출력한다. 우선순위:
#   1) repos.conf 매핑 (형식: "<owner/repo> <절대경로>" — 공백 구분, 경로에 공백 불가,
#      # 시작 줄은 주석. repos.conf 는 gitignore — 머신마다 다르다. 예시는 repos.conf.example)
#   2) $ISSUE_RUNNER_PROJECTS_ROOT/<repo-name> (기본값: $HOME/Projects)
# 디렉토리가 존재하면 물리 경로(pwd -P)로 정규화해 출력 — local-ci slug 계산이
# 사람의 머지 게이트(실제 경로 기준)와 일치해야 하기 때문.
set -euo pipefail
repo="${1:?usage: repo-dir.sh <owner/repo>}"
name=${repo#*/}
base="$(cd "$(dirname "$0")/.." && pwd)"
conf="$base/repos.conf"

dir=""
if [ -f "$conf" ]; then
  dir=$(awk -v r="$repo" '!/^[[:space:]]*#/ && $1==r {print $2; exit}' "$conf")
fi
[ -z "$dir" ] && dir="${ISSUE_RUNNER_PROJECTS_ROOT:-$HOME/Projects}/$name"

# ~ 확장 (conf 에 ~/ 로 적은 경우)
case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac

if [ -d "$dir" ]; then
  (cd "$dir" && pwd -P)
else
  printf '%s\n' "$dir"
fi
