#!/usr/bin/env bash
# local-ci.sh — `git push` 직후 레포의 bin/ci 를 백그라운드로 돌려
# GitHub Actions 를 대체한다(Actions 과금 0). 결과는 HEAD SHA 키로 캐시되고,
# 머지 게이트(ci-gate-before-pr-merge.sh)가 이를 읽어 판정한다.
# 동시에 GitHub commit status(컨텍스트 local-ci, 무료 REST — Actions 아님)를
# pending→success/failure 로 게시해 PR 체크 영역에서도 결과가 보인다.
#
# bin/ci 는 언어 무관 컨벤션 — Rails 8 네이티브(bin/ci + config/ci.rb)든
# 직접 작성한 폴리글롯 스크립트(예: Temphra 의 Python+TS)든 실행 파일이기만
# 하면 된다. 전역 hook(모든 프로젝트 공용)이라 bin/ci 없는 레포에선 무조건
# no-op — 타 프로젝트 안전. PostToolUse(Bash, if: git push*). macOS bash 3.2 대상.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && cmd=$(printf '%s' "$input" \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

# self-filter — git push 아니면 패스스루(settings if 매칭 누락 경로에서도 안전)
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)' \
  || exit 0

# repo 루트 — git repo 아니면 no-op
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$ROOT" || exit 0

# opt-in 가드 — 실행 가능한 bin/ci 를 가진 레포만(언어 무관). 그 외 no-op.
[ -x bin/ci ] || exit 0

# mise toolchain 해결 — shim 을 PATH 맨 앞에(quality-gate.sh 와 동일 이유:
# 시스템 ruby 로 잡혀 Gemfile 파싱이 깨지는 것 방지). shim 부재 시 무해.
if [ -d "$HOME/.local/share/mise/shims" ]; then
  PATH="$HOME/.local/share/mise/shims:$PATH"; export PATH
fi

SHA=$(git rev-parse HEAD 2>/dev/null) || exit 0
SLUG=$(printf '%s' "$ROOT" | sed 's#[/ ]#_#g; s#^_##')
NAME=$(basename "$ROOT")
DIR="$HOME/.claude/.local-ci/$SLUG"
mkdir -p "$DIR" 2>/dev/null

# 7일 지난 캐시 prune
find "$DIR" -type f -mtime +7 -delete 2>/dev/null

RESULT="$DIR/$SHA.result"
LOG="$DIR/$SHA.log"
LOCK="$DIR/.lock"

# dedup — 이 SHA 이미 검사됐으면 재실행 안 함
[ -f "$RESULT" ] && { printf '로컬 CI: %s 이미 검사됨(%s)\n' "$(printf '%s' "$SHA" | cut -c1-8)" "$(cat "$RESULT")" >&2; exit 0; }

# repo 단위 lock(mkdir = 원자 토큰) — 동시 bin/ci 의 테스트 DB 경합 방지.
# mkdir 성공 = 소유. 회수는 mtime 이 아니라 소유 PID 생존으로 판단 — 느린 실행이
# 아직 살아있으면(>10분이어도) 절대 뺏지 않는다(락 탈취 후 이중 rm 경쟁 방지).
short=$(printf '%s' "$SHA" | cut -c1-8)
# 락이 죽었나? pid 살아있으면 살아있음. pid 미기록(갓 생성 중)이면 30분 backstop.
lock_dead() {
  if [ -f "$LOCK/pid" ]; then
    p=$(cat "$LOCK/pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 1
    return 0
  fi
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ] && return 0
  return 1
}
got_lock=0
if mkdir "$LOCK" 2>/dev/null; then
  got_lock=1
elif lock_dead; then
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null && got_lock=1
fi
if [ "$got_lock" != 1 ]; then
  printf '로컬 CI: 다른 검사 진행 중 — %s 는 건너뜀(완료 후 재push 시 검사)\n' "$short" >&2
  exit 0
fi

# 백그라운드 실행 — hook 반환 후에도 생존(nohup + fd 리다이렉트 + </dev/null + disown).
# 값은 환경변수로 주입(문자열 보간 회피).
RESULT="$RESULT" LOG="$LOG" LOCK="$LOCK" SHA="$SHA" ROOT="$ROOT" NAME="$NAME" \
nohup bash -c '
  echo $$ > "$LOCK/pid" 2>/dev/null   # 락 소유권(자기 PID) 기록 — 첫 동작
  cd "$ROOT" || { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; exit 0; }
  # 시작 status(pending) — PR 체크 영역에 "실행 중" 표시. 게시 실패는 무시
  # (gh 미설치/미인증/원격 부재여도 로컬 CI 본연 동작엔 영향 없음).
  if command -v gh >/dev/null 2>&1; then
    gh api "repos/{owner}/{repo}/statuses/$SHA" -f state=pending \
      -f context="local-ci" -f description="bin/ci 실행 중 (로컬)" >/dev/null 2>&1
  fi
  ci_start=$SECONDS
  if bin/ci >"$LOG" 2>&1; then verdict=pass; else verdict=fail; fi
  dur=$(( SECONDS - ci_start ))
  printf "%s\n" "$verdict" > "$RESULT"
  # 결과 status 게시 — PR/커밋 페이지에 ✅/❌ 로 반영. 머지 게이트는 여전히
  # 로컬 캐시($RESULT)로 판정하므로 status 는 표시용(네트워크 단절에도 게이트 무손상).
  if command -v gh >/dev/null 2>&1; then
    if [ "$verdict" = pass ]; then st=success; ds="bin/ci 통과 (로컬, ${dur}s)"
    else st=failure; ds="bin/ci 실패 (로컬, ${dur}s) — 로그: ~/.claude/.local-ci"; fi
    gh api "repos/{owner}/{repo}/statuses/$SHA" -f state="$st" \
      -f context="local-ci" -f description="$ds" >/dev/null 2>&1
  fi
  # 여전히 자신이 소유할 때만 락 해제 — stale 회수로 새 소유자가 들어왔으면 그 락을 보존
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
  if command -v osascript >/dev/null 2>&1; then
    short=$(printf "%s" "$SHA" | cut -c1-8)
    if [ "$verdict" = pass ]; then
      osascript -e "display notification \"로컬 CI 통과 $short\" with title \"✅ $NAME\"" >/dev/null 2>&1
    else
      osascript -e "display notification \"로컬 CI 실패 $short — bin/ci 로그 확인\" with title \"❌ $NAME\"" >/dev/null 2>&1
    fi
  fi
' >/dev/null 2>&1 </dev/null &
disown 2>/dev/null

printf '로컬 CI 백그라운드 시작 (%s) — 완료 시 알림, 머지는 게이트가 판정\n' "$short" >&2
exit 0
