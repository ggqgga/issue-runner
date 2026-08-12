#!/usr/bin/env bash
# usage: make-worktree.sh <owner/repo> <issue-number>
# 레포가 ~/Projects/<name>에 없으면 clone, 있으면 fetch 후
# .claude/worktrees/issue-<N> 에 agent/issue-<N> 브랜치로 worktree 생성.
# 성공 시 worktree 절대경로를 stdout 마지막 줄에 출력.
set -euo pipefail
repo="${1:?usage: make-worktree.sh <owner/repo> <num>}"
num="${2:?usage: make-worktree.sh <owner/repo> <num>}"
here="$(cd "$(dirname "$0")" && pwd)"
dir="$("$here/repo-dir.sh" "$repo")"
branch="agent/issue-$num"
wt="$dir/.claude/worktrees/issue-$num"

# 시크릿 파일 — repos.conf 의 link-secrets 플래그가 있는 레포에서만 워크트리에 심링크
# 한다(#109). 기본 off: 무인 워커 작업공간에 라이브 시크릿을 두지 않는다.
secret_files=".env config/master.key"
link_secrets=0
if "$here/repo-flag.sh" "$repo" link-secrets; then link_secrets=1; fi

# 플래그가 off 인데 이전(기본 on 시절)에 깔린 심링크가 남아 있으면 회수한다.
# **우리가 만든 것만** 지운다 = 대상이 정확히 메인 체크아웃의 같은 파일($dir/$f)인
# 심링크. 실제 파일이나 다른 곳을 가리키는 심링크는 워커/사용자 소유물이라 보존한다.
reap_secret_links() {
  local w="$1" f tgt
  for f in $secret_files; do
    if [ -L "$w/$f" ]; then
      tgt=$(readlink "$w/$f")
      if [ "$tgt" = "$dir/$f" ]; then
        rm -f "$w/$f"
        echo "secrets: 기존 심링크 회수 $f (repos.conf link-secrets 없음 — #109)" >&2
      else
        echo "secrets: $f 는 우리가 만든 심링크가 아님(→ $tgt) — 보존" >&2
      fi
    fi
  done
}

# 심링크 생성. 이미 우리 대상을 가리키면 no-op, 다른 대상을 가리키는 심링크(깨진 것
# 포함)나 실제 파일이 있으면 덮어쓰지 않고 경고만 한다 — 워커가 의도적으로 둔 것을
# 조용히 갈아끼우면 디버깅이 불가능해진다. (`[ ! -e ]` 는 깨진 심링크에 참이라
# 대상 확인 없이 ln -s 를 부르면 "File exists" 로 죽는다.)
link_secret_files() {
  local w="$1" f tgt
  for f in $secret_files; do
    [ -f "$dir/$f" ] || continue
    if [ -L "$w/$f" ]; then
      tgt=$(readlink "$w/$f")
      if [ "$tgt" = "$dir/$f" ]; then continue; fi
      echo "secrets: $f 에 다른 대상(→ $tgt)의 심링크가 있어 건드리지 않음" >&2
      continue
    fi
    if [ -e "$w/$f" ]; then
      echo "secrets: $f 가 실제 파일로 있어 심링크하지 않음" >&2
      continue
    fi
    mkdir -p "$(dirname "$w/$f")"
    ln -s "$dir/$f" "$w/$f"
  done
}

[ -d "$dir/.git" ] || gh repo clone "$repo" "$dir"
git -C "$dir" fetch origin --prune

default=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name')

# .claude/ 를 레포 오염 없이 로컬에서만 무시
mkdir -p "$dir/.git/info"
grep -qx '.claude/' "$dir/.git/info/exclude" 2>/dev/null \
  || echo '.claude/' >> "$dir/.git/info/exclude"

if [ -d "$wt" ]; then
  echo "exists: $wt" >&2
  if [ "$link_secrets" = 1 ]; then link_secret_files "$wt"; else reap_secret_links "$wt"; fi
  echo "$wt"
  exit 0
fi

mkdir -p "$dir/.claude/worktrees"
if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  # 원격에 브랜치가 이미 있음(보수 재투입 케이스) — 그 위에 worktree
  git -C "$dir" worktree add "$wt" -B "$branch" "origin/$branch" >/dev/null
else
  git -C "$dir" worktree add "$wt" -b "$branch" "origin/$default" >/dev/null
fi

# 로컬 전용 gitignore 설정(.env·credentials key 등)의 심링크 — git 추적 안 되는
# 파일이라 worktree 체크아웃에 안 깔린다. 메인 한 곳만 관리하고 worktree 가 그것을
# 참조하면 워커가 foreman run·credentials 의존 테스트를 메인과 동일하게 돌릴 수 있다.
#
# 다만 그건 무인 워커의 작업공간에 **라이브 시크릿**을 놓는다는 뜻이고, 이슈 본문이
# 곧 워커 프롬프트인 구조와 곱해지면 프롬프트 인젝션 → 유출 경로가 된다(#109).
# 그래서 기본 off 이고, repos.conf 의 `link-secrets` 플래그로 레포별 opt-in 한다
# (repos.conf 는 머신별·gitignore — 위험 지갑이 사용자 손에 남는다).
# 플래그 없이 도는 레포에선 credential 의존 테스트가 못 돌 수 있다 — 워커는 그걸
# 실패가 아니라 skip 으로 보고해야 한다(README 참조).
if [ "$link_secrets" = 1 ]; then
  link_secret_files "$wt"
else
  for f in $secret_files; do
    if [ -f "$dir/$f" ]; then
      echo "secrets: $f 미링크 (repos.conf link-secrets 없음 — #109)" >&2
    fi
  done
fi

echo "$wt"
