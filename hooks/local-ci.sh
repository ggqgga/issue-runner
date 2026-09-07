#!/usr/bin/env bash
# local-ci.sh — `git push` 직후 레포의 bin/ci 를 **박스 전역 큐**(scripts/ci-queue.sh)에
# 넣는다. GitHub Actions 대체(과금 0). 결과는 HEAD SHA 키로 캐시되고, 머지 게이트
# (ci-gate-before-pr-merge.sh)가 이를 읽어 판정한다. commit status(컨텍스트 local-ci)는
# 큐가 대기열→실행 중→success/failure 로 게시한다.
#
# 이 훅은 얇다 — ROOT·SHA 를 정해 큐에 백그라운드로 넘기고 즉시 반환. 직렬화·dedup·
# 유령 회수·status 게시는 전부 ci-queue.sh 의 몫(Plans/ci-queue.md, #127). 예전의
# 워크트리별 락("다른 검사 진행 중 — 건너뜀")은 없다 — 못 잡으면 버리는 게 아니라 줄을 선다.
#
# ROOT 는 **세션 cwd 가 아니라** 훅 입력의 `cwd` 를 기준으로, 명령 앞머리의
# `cd <경로> &&` / `cd <경로>;` 를 따라간 곳에서 `git rev-parse --show-toplevel` 로 잡는다
# (예전엔 세션 cwd 라 `cd <워크트리> && git push` 가 메인 체크아웃 HEAD 를 검사했다).
#
# bin/ci 는 언어 무관 컨벤션 — 실행 파일이기만 하면 된다. 전역 hook 이라 bin/ci 없는
# 레포에선 no-op. PostToolUse(Bash, if: git push*). macOS bash 3.2 대상.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && cmd=$(printf '%s' "$input" \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

# self-filter — git push 아니면 패스스루(settings if 매칭 누락 경로에서도 안전)
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)' \
  || exit 0

# 기준 디렉터리 — 훅 입력 cwd(없으면 프로세스 cwd)
base=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$base" ] && [ -d "$base" ] || base=$PWD

# 명령 앞머리 `cd <경로> &&|;` — 그 경로로 옮긴다(따옴표 벗김·~ 전개·상대경로는 base 기준)
lead=$(printf '%s' "$cmd" \
  | sed -n -E 's/^[[:space:]]*cd[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^;&|[:space:]]+))[[:space:]]*(&&|;).*/\2\3\4/p')
if [ -n "$lead" ]; then
  case "$lead" in
    "~") lead=$HOME ;;
    \~/*) lead="$HOME/${lead#\~/}" ;;
    /*) ;;
    *) lead="$base/$lead" ;;
  esac
  [ -d "$lead" ] && base=$lead
fi

# repo 루트 — git repo 아니면 no-op
ROOT=$(git -C "$base" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

# opt-in 가드 — 실행 가능한 bin/ci 를 가진 레포만(언어 무관). 그 외 no-op.
[ -x "$ROOT/bin/ci" ] || exit 0

SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || exit 0
short=$(printf '%s' "$SHA" | cut -c1-8)
SLUG=$(printf '%s' "$ROOT" | sed 's#[/ ]#_#g; s#^_##')
DIR="$HOME/.claude/.local-ci/$SLUG"
mkdir -p "$DIR" 2>/dev/null

# 7일 지난 캐시 prune
find "$DIR" -type f -mtime +7 -delete 2>/dev/null

# dedup(빠른 길) — 이 SHA 이미 검사됐으면 큐에 넣지 않는다(큐도 같은 검사를 하지만 프로세스 절약)
if [ -f "$DIR/$SHA.result" ]; then
  printf '로컬 CI: %s 이미 검사됨(%s)\n' "$short" "$(cat "$DIR/$SHA.result")" >&2
  exit 0
fi

# ci-queue.sh 위치 — 훅은 개별 심링크라 인접 scripts/ 가 없을 수 있다 → 심링크를 따라간 실제
# 위치의 ../scripts, 그다음 설치 경로로 폴백(ci-gate 의 repo-dir.sh 관행).
src="$0"
while [ -L "$src" ]; do
  d=$(cd "$(dirname "$src")" && pwd); src=$(readlink "$src")
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
here=$(cd "$(dirname "$src")" && pwd)
Q=""
for cand in "$here/../scripts/ci-queue.sh" "$HOME/.claude/skills/issue-runner/scripts/ci-queue.sh"; do
  [ -x "$cand" ] && { Q="$cand"; break; }
done
if [ -z "$Q" ]; then
  printf '로컬 CI: ci-queue.sh 를 찾지 못해 %s 를 큐에 넣지 못했습니다 (issue-runner 설치 확인)\n' "$short" >&2
  exit 0
fi

# mise toolchain — shim 을 PATH 앞에(큐도 같은 처리를 하지만 훅 환경에서 먼저 보장)
if [ -d "$HOME/.local/share/mise/shims" ]; then
  PATH="$HOME/.local/share/mise/shims:$PATH"; export PATH
fi

Q="$(cd "$(dirname "$Q")" && pwd)/ci-queue.sh"

ahead=0
for t in "$HOME/.claude/.local-ci/.queue"/*; do [ -f "$t" ] && ahead=$((ahead + 1)); done
# 백그라운드 — hook 반환 후에도 생존(nohup + fd 리다이렉트 + </dev/null + disown)
nohup "$Q" run "$ROOT" "$SHA" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null

# 세션에 직접 알린다(additionalContext) — 결과를 기다리는 표준 통로는 `wait` 를 백그라운드
# Bash 로 띄우는 것. 끝나면 명령이 종료되고 Claude Code 가 세션을 깨운다 — sleep 폴링 금지.
msg=$(printf '로컬 CI 큐 등록: %s (앞에 %s건 — 박스 전체 직렬, 다른 세션·워크트리 포함). 결과 대기는 지금 이 명령을 Bash run_in_background=true 로 실행하세요: %s wait %s  — pass/fail/폐기가 정해지면 명령이 끝나고 세션이 자동으로 깨어납니다(종료 코드 0=pass·1=fail·2=큐에 없음·124=타임아웃). sleep 폴링·bin/ci 직접 실행 금지. 머지는 게이트가 판정.' \
  "$short" "$ahead" "$Q" "$SHA")
printf '%s' "$msg" | jq -Rs '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: . } }'
exit 0
