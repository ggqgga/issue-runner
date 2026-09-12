#!/usr/bin/env bash
# usage: make-worktree.sh [--sync] [--branch <ref>] <owner/repo> <issue-number>
# 레포가 ~/Projects/<name>에 없으면 clone, 있으면 fetch 후
# .claude/worktrees/issue-<N> 에 agent/issue-<N> 브랜치로 worktree 생성.
# 성공 시 worktree 절대경로를 stdout 마지막 줄에 출력.
#
# ── `--sync` — 기존 worktree 를 PR 의 현재 head 로 강제 동기화 (#445) ──────────
# 이 스크립트는 worktree 가 이미 있으면 **그대로 반환**한다. 그래서 rebase·force-push 뒤에
# 부르면 **옛 SHA 가 체크아웃된 채**인데 호출자는 최신인 줄 안다 — verify-runner 1단계와
# closeout 3단계·revalidate 경로가 각자 산문으로 `git fetch` + `git reset --hard` 를 복붙하던
# 이유다(세 자리가 갈라지면 한 곳만 고쳐진다). `--sync` 는 그 절차를 한 자리로 옮긴 것이다:
#   · worktree 가 있으면 `git fetch origin <branch>` → `git reset --hard origin/<branch>`
#     (이 SHA 가 `closeout-ci-pass.sh` 가 `gh pr view headRefOid` 로 보는 바로 그 SHA다 —
#      안 맞추면 run-local-ci 가 옛 SHA 를 캐시해 영구 exit 2 로 남는다)
#   · 원격에 그 브랜치가 없으면 **덮지 않고** exit 4 (동기화 대상이 없는데 리셋하면 엉뚱한
#     커밋으로 되감긴다)
#   · **추적 파일에 미커밋 변경이 있으면 덮지 않고 exit 3** + stderr. 판정은
#     `git status --porcelain --untracked-files=no` 다 — `reset --hard` 는 추적 안 되는
#     파일을 건드리지 않으므로 untracked 를 세면 잘못 막는다. 특히 `link-secrets` 레포는
#     `.env`·`config/master.key` 심링크가 untracked 로 뜨므로, 그것까지 세면 정작 이 옵션이 필요한 레포에서
#     **영구 exit 3** 이 된다. 같은 exit 3 을 두 경우에 더 쓴다 — 대상이 그 worktree 의
#     **루트가 아니거나**(반쯤 만들어진 디렉토리는 메인 체크아웃 안이라 `git -C` 가 성공해
#     버리고, 확인 없이 진행하면 `reset --hard` 가 **메인 체크아웃**을 되감는다) `git status`
#     **조회 자체가 실패**하면(빈 결과와 실패를 섞지 않는다, PR#139) 덮지 않는다.
#   · worktree 가 없으면 종전 생성 경로 그대로(원격 브랜치가 있으면 그 위에 만들므로 이미 동기).
#   · `--branch <ref>` 로 head 브랜치를 지정할 수 있다(기본 `agent/issue-<N>`). verify-runner 의
#     head 는 `agent/issue-*` 가 아닐 수 있어 그 자리를 산문으로 두면 이 옵션 없이는 못 옮긴다.
#   · 동기화 결과 SHA 를 `synced: <sha>` 로 먼저 출력한다 — **마지막 줄은 여전히 worktree
#     절대경로**다(호출자 셋이 마지막 줄로 경로를 읽는 종전 계약, 깨지 마라).
set -euo pipefail

sync=0
branch_override=
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sync)   sync=1; shift ;;
    --branch) branch_override=${2:-}; shift 2 ;;
    --)       shift ;;
    -*)       echo "usage: make-worktree.sh [--sync] [--branch <ref>] <owner/repo> <num>" >&2; exit 1 ;;
    *)        pos[${#pos[@]}]=$1; shift ;;
  esac
done
repo=${pos[0]:-}
num=${pos[1]:-}
[ -n "$repo" ] && [ -n "$num" ] \
  || { echo "usage: make-worktree.sh [--sync] [--branch <ref>] <owner/repo> <num>" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
dir="$("$here/repo-dir.sh" "$repo")"
branch="${branch_override:-agent/issue-$num}"
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
  if [ "$sync" = 1 ]; then
    # 원격 head 로 강제 동기화 — 없는 브랜치로는 되감지 않는다(exit 4).
    if ! git -C "$dir" fetch origin "$branch" >/dev/null 2>&1 \
       || ! git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      echo "sync: 원격 브랜치 없음 origin/$branch — 동기화하지 않는다" >&2
      exit 4
    fi
    # 대상이 **정말 그 worktree 의 루트**인지 먼저 확인한다. 반쯤 만들어진(혹은 손으로 만든)
    # `.claude/worktrees/issue-N` 디렉토리는 메인 체크아웃 **안**에 있어서 `git -C` 가 성공해
    # 버린다 — 확인 없이 진행하면 `reset --hard` 가 **메인 체크아웃**을 되감는다.
    top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || top=
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=
    top_real=$(cd "$top" 2>/dev/null && pwd -P 2>/dev/null) || top_real=
    if [ -z "$top_real" ] || [ "$top_real" != "$wt_real" ]; then
      echo "sync: $wt 가 worktree 루트가 아니다(깨진 디렉토리?) — 덮지 않는다" >&2
      exit 3
    fi
    # 추적 파일의 미커밋 변경만 센다(`reset --hard` 는 untracked 를 건드리지 않고,
    # link-secrets 심링크가 untracked 로 떠 영구 거부가 되는 것을 막는다).
    # **조회 실패와 "깨끗함" 을 섞지 않는다**(PR#139 규율) — 못 읽었으면 덮지 않는다.
    if ! st=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null); then
      echo "sync: worktree 상태를 못 읽었다 — 덮지 않는다: $wt" >&2
      exit 3
    fi
    if [ -n "$st" ]; then
      echo "sync: worktree 에 미커밋 변경이 있어 덮지 않는다 — $wt" >&2
      exit 3
    fi
    git -C "$wt" reset --hard "origin/$branch" >/dev/null
    echo "synced: $(git -C "$wt" rev-parse HEAD)"
  fi
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

# 새로 만든 worktree 는 원격 브랜치가 있으면 그 위에서 났으므로 이미 동기 상태다 —
# `--sync` 호출자에게 같은 형태로 SHA 만 알려 준다(마지막 줄은 여전히 경로).
if [ "$sync" = 1 ]; then
  echo "synced: $(git -C "$wt" rev-parse HEAD)"
fi
echo "$wt"
