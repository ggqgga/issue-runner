#!/usr/bin/env bash
# make-worktree.sh 픽스처 테스트 — 네트워크 무접속(gh 는 PATH 스텁, origin 은 로컬 bare 레포).
#
# #445: `--sync` 는 verify-runner 1단계·closeout 3단계·revalidate 경로가 각자 산문으로
# 복붙하던 `git fetch` + `git reset --hard origin/<head>` 를 한 자리로 옮긴 것이다. 무는 것:
#   ⑴ 기존 worktree 가 옛 SHA 를 물고 있어도 원격 head 로 **실제로** 옮겨진다
#   ⑵ 추적 파일에 미커밋 변경이 있으면 **덮지 않고** exit 3 (작업 유실 방지)
#   ⑶ untracked 파일·link-secrets 심링크는 거부 사유가 **아니다**(`reset --hard` 가 안 건드린다 —
#      여기서 거부하면 정작 이 옵션이 필요한 레포가 영구 exit 3 이 된다)
#   ⑷ 원격에 그 브랜치가 없으면 되감지 않고 exit 4
#   ⑸ `--branch` 로 `agent/issue-*` 아닌 head 도 동기화할 수 있다(verify-runner 의 head)
#   ⑹ **마지막 줄은 여전히 worktree 절대경로**다 — 호출자 셋이 그 줄로 경로를 읽는다
#   ⑺ `--sync` 없는 종전 호출의 거동은 그대로다(#109 스모크와 같은 계약)
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/make-worktree.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub" "$tmp/proj"

# gh 스텁 — 이 스크립트가 쓰는 gh 는 `repo view --json defaultBranchRef` 와 (미존재 시) clone 뿐.
printf '#!/bin/sh\ncase "$*" in *defaultBranchRef*) echo main ;; *) echo "" ;; esac\n' > "$tmp/stub/gh"
chmod +x "$tmp/stub/gh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/proj/r"
git -C "$tmp/proj/r" config user.email t@t; git -C "$tmp/proj/r" config user.name t
git -C "$tmp/proj/r" commit -q --allow-empty -m init
git -C "$tmp/proj/r" remote add origin "$tmp/origin.git"
git -C "$tmp/proj/r" push -q -u origin main
printf 'o/r -\n' > "$tmp/repos.conf"

mkwt() {  # mkwt <인자...> — OUT/RC/LAST 를 채운다.
  OUT=$(ISSUE_RUNNER_REPOS_CONF="$tmp/repos.conf" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
        PATH="$tmp/stub:$PATH" bash "$SUT" "$@" 2>"$tmp/err.log")
  RC=$?
  LAST=$(printf '%s\n' "$OUT" | tail -1)
  ERR=$(cat "$tmp/err.log")
}

# 원격에 agent/issue-9 브랜치를 두 커밋으로 만들어 둔다(옛 SHA / 새 SHA).
work="$tmp/seed"
git clone -q "$tmp/origin.git" "$work"
git -C "$work" config user.email t@t; git -C "$work" config user.name t
git -C "$work" checkout -q -b agent/issue-9
echo one > "$work/a.txt"; git -C "$work" add a.txt; git -C "$work" commit -q -m one
git -C "$work" push -q -u origin agent/issue-9
OLD=$(git -C "$work" rev-parse HEAD)

echo "── --sync ───────────────────────────────────────────────────────"

# ① 첫 호출(worktree 생성) — 원격 브랜치 위에서 나므로 이미 동기, SHA 를 낸다
mkwt --sync o/r 9
wt="$LAST"
{ [ "$RC" = 0 ] && [ -d "$wt" ]; } && ok || bad "① 생성 rc=$RC last=[$LAST] err=[$ERR]"
printf '%s\n' "$OUT" | grep -q "^synced: $OLD$" && ok || bad "① synced SHA 줄이 없다: [$OUT]"
[ "$(git -C "$wt" rev-parse HEAD)" = "$OLD" ] && ok || bad "① 생성 HEAD 가 원격 head 가 아니다"

# ② 원격이 앞서 나간 뒤 --sync → worktree HEAD 가 새 SHA 로 옮겨진다
echo two > "$work/a.txt"; git -C "$work" commit -qam two; git -C "$work" push -q origin agent/issue-9
NEW=$(git -C "$work" rev-parse HEAD)
[ "$(git -C "$wt" rev-parse HEAD)" = "$OLD" ] && ok || bad "② 전제: worktree 가 아직 옛 SHA 여야 한다"
mkwt --sync o/r 9
{ [ "$RC" = 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$NEW" ]; } && ok \
  || bad "② 동기화 실패 rc=$RC head=$(git -C "$wt" rev-parse HEAD) 기대=$NEW"
printf '%s\n' "$OUT" | grep -q "^synced: $NEW$" && ok || bad "② synced 가 새 SHA 가 아니다: [$OUT]"
[ "$LAST" = "$wt" ] && ok || bad "② 마지막 줄이 worktree 경로가 아니다: [$LAST] (호출자 계약)"

# ③ --sync 없이 부르면 동기화하지 않는다(종전 거동 불변) — 옛 SHA 로 되돌려 확인
git -C "$wt" reset --hard "$OLD" >/dev/null 2>&1
mkwt o/r 9
{ [ "$RC" = 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$OLD" ] && [ "$LAST" = "$wt" ]; } && ok \
  || bad "③ --sync 없는 호출이 worktree 를 건드렸다(종전 계약 위반)"
printf '%s\n' "$OUT" | grep -q '^synced:' && bad "③ --sync 없는데 synced 줄을 냈다" || ok

# ④ 추적 파일에 미커밋 변경 → 덮지 않고 exit 3
echo dirty >> "$wt/a.txt"
mkwt --sync o/r 9
{ [ "$RC" = 3 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$OLD" ]; } && ok \
  || bad "④ 더티 rc=$RC (기대 3) · HEAD 가 덮였나=$(git -C "$wt" rev-parse HEAD)"
printf '%s\n' "$ERR" | grep -q '미커밋 변경' && ok || bad "④ 더티 사유가 stderr 에 없다"
grep -q dirty "$wt/a.txt" && ok || bad "④ 더티 파일이 날아갔다(작업 유실)"
git -C "$wt" checkout -- a.txt

# ⑤ untracked 파일·심링크는 거부 사유가 아니다 — 동기화가 진행된다
printf 'SECRET=live\n' > "$wt/.env"          # link-secrets 레포의 형상(추적 안 됨)
echo scratch > "$wt/scratch.txt"
mkwt --sync o/r 9
{ [ "$RC" = 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$NEW" ]; } && ok \
  || bad "⑤ untracked 때문에 거부됐다 rc=$RC err=[$ERR] (link-secrets 레포 영구 exit 3 회귀)"
[ -f "$wt/.env" ] && ok || bad "⑤ untracked 파일이 사라졌다"
rm -f "$wt/.env" "$wt/scratch.txt"

# ⑥ 원격에 브랜치가 없으면 되감지 않고 exit 4
mkdir -p "$tmp/proj/r/.claude/worktrees/issue-77"   # worktree 처럼 보이는 디렉토리
mkwt --sync o/r 77
[ "$RC" = 4 ] && ok || bad "⑥ 원격 브랜치 없음 rc=$RC (기대 4)"
printf '%s\n' "$ERR" | grep -q '원격 브랜치 없음' && ok || bad "⑥ 사유가 stderr 에 없다"

# ⑦ --branch 로 agent/issue-* 아닌 head 도 동기화한다(verify-runner 의 head 형태)
git -C "$work" checkout -q -b feature/x
echo three > "$work/a.txt"; git -C "$work" commit -qam three; git -C "$work" push -q -u origin feature/x
FEAT=$(git -C "$work" rev-parse HEAD)
mkwt --sync --branch feature/x o/r 9
{ [ "$RC" = 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$FEAT" ]; } && ok \
  || bad "⑦ --branch 동기화 실패 rc=$RC head=$(git -C "$wt" rev-parse HEAD) 기대=$FEAT"

# ⑧ worktree 루트가 아닌 디렉토리(반쯤 만들어진 것)는 **메인 체크아웃을 되감지 않는다**.
#    `.claude/worktrees/issue-N` 은 메인 체크아웃 **안**이라 `git -C` 가 성공해 버린다 —
#    루트 확인이 없으면 여기서 `reset --hard` 가 메인 체크아웃을 덮는다(가장 나쁜 회귀).
mkdir -p "$tmp/proj/r/.claude/worktrees/issue-88"
MAIN_BEFORE=$(git -C "$tmp/proj/r" rev-parse HEAD)
mkwt --sync --branch agent/issue-9 o/r 88
[ "$RC" = 3 ] && ok || bad "⑧ 가짜 worktree rc=$RC (기대 3)"
[ "$(git -C "$tmp/proj/r" rev-parse HEAD)" = "$MAIN_BEFORE" ] && ok \
  || bad "⑧ 메인 체크아웃 HEAD 가 움직였다 — reset --hard 가 메인을 덮었다"
printf '%s\n' "$ERR" | grep -q 'worktree 루트가 아니다' && ok || bad "⑧ 사유가 stderr 에 없다"

echo "── 계약(usage·실행비트) ──────────────────────────────────────────"

# ⑧ 인자 부족 → 비0 (종전과 같이 exit 1)
mkwt --sync o/r
[ "$RC" != 0 ] && ok || bad "⑧ 인자 부족인데 rc=0"

# ⑨ 실행 비트 — 세 루프 SKILL 이 직접 exec 한다
[ -x "$SUT" ] && ok || bad "⑨ make-worktree.sh 실행 비트 없음"

echo "make-worktree.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
