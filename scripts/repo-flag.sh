#!/usr/bin/env bash
# usage: repo-flag.sh <owner/repo> <flag>
# repos.conf 의 해당 레포 줄에 <flag> 토큰이 있으면 exit 0, 없으면 exit 1.
#
# repos.conf 형식: "<owner/repo> <절대경로> [flag ...]" — 공백 구분, # 시작 줄은 주석.
# 3번째 이후 필드가 플래그다. 경로를 바꿀 필요 없이 플래그만 주고 싶으면 경로 자리에
# `-` 를 적는다(repo-dir.sh 가 기본 경로 해석으로 되돌린다).
#
# 정의된 플래그:
#   link-secrets  make-worktree.sh 가 메인 체크아웃의 .env·config/master.key 를
#                 워크트리에 심링크한다. 기본은 **off** — 무인 워커 작업공간에
#                 라이브 시크릿을 두지 않는다(#109). 켜면 그 레포에 한해 워커가
#                 credential 의존 테스트를 메인과 동일하게 돌릴 수 있다.
#
# 테스트용 env: ISSUE_RUNNER_REPOS_CONF 로 conf 경로를 갈아끼운다.
set -euo pipefail
repo="${1:?usage: repo-flag.sh <owner/repo> <flag>}"
flag="${2:?usage: repo-flag.sh <owner/repo> <flag>}"
base="$(cd "$(dirname "$0")/.." && pwd)"
conf="${ISSUE_RUNNER_REPOS_CONF:-$base/repos.conf}"

[ -f "$conf" ] || exit 1

awk -v r="$repo" -v f="$flag" '
  !/^[[:space:]]*#/ && $1==r {
    for (i = 3; i <= NF; i++) if ($i == f) { found = 1 }
    exit
  }
  END { exit found ? 0 : 1 }
' "$conf"
