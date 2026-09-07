#!/usr/bin/env bash
# local-ci.sh — `git push` 직후 레포의 bin/ci 를 **박스 전역 큐**(scripts/ci-queue.sh)에
# 넣는다. GitHub Actions 대체(과금 0). 결과는 HEAD SHA 키로 캐시되고, 머지 게이트
# (ci-gate-before-pr-merge.sh)가 이를 읽어 판정한다. commit status(컨텍스트 local-ci)는
# 큐가 대기열→실행 중→success/failure 로 게시한다.
#
# 이 훅은 얇다 — ROOT·SHA 를 정해 큐에 백그라운드로 넘기고 세션에 `wait` 명령을 알린 뒤
# 즉시 반환. 직렬화·dedup·유령 회수·캐시 prune·status 게시는 전부 ci-queue.sh 의 몫
# (Plans/ci-queue.md, #127). 예전의 워크트리별 락("다른 검사 진행 중 — 건너뜀")은 없다 —
# 못 잡으면 버리는 게 아니라 줄을 선다.
#
# ROOT 는 **세션 cwd 가 아니라** 훅 입력의 `cwd` 를 기준으로, 명령 **선두**의
# `cd <경로> &&` / `cd <경로>;` 를 따라간 곳에서 `git rev-parse --show-toplevel` 로 잡는다
# (예전엔 세션 cwd 라 `cd <워크트리> && git push` 가 메인 체크아웃 HEAD 를 검사했다).
# 선두 cd 한 번만 인정한다 — `git -C <dir> push` 는 위 self-filter(`git push` 인접)에
# 걸리지 않아 훅 자체가 뜨지 않고, `(cd x && …)`·`cd a && cd b` 는 cwd 로 떨어진다.
#
# bin/ci 는 언어 무관 컨벤션 — 실행 파일이기만 하면 된다. 전역 hook 이라 bin/ci 없는
# 레포에선 no-op. PostToolUse(Bash, if: git push*). macOS bash 3.2 대상.
set -u

input=$(cat)
cmd=""; base=""
{ IFS= read -r cmd; IFS= read -r base; } \
  < <(printf '%s' "$input" | jq -r '[.tool_input.command // "", .cwd // ""] | .[]' 2>/dev/null)
[ -z "$cmd" ] && cmd=$(printf '%s' "$input" \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

# self-filter — git push 아니면 패스스루(settings if 매칭 누락 경로에서도 안전)
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)' \
  || exit 0

[ -n "$base" ] && [ -d "$base" ] || base=$PWD
note=""   # 세션에 덧붙일 경고(선두 cd 해석 실패 등)
ctx() { printf '%s' "$1" | jq -Rs '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: . } }'; }

# 선두 `cd <경로> &&|;` — 그 경로로 옮긴다(따옴표 벗김·~ 전개·상대경로는 base 기준)
lead=$(printf '%s' "$cmd" \
  | sed -n -E 's/^[[:space:]]*cd[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^;&|[:space:]]+))[[:space:]]*(&&|;).*/\2\3\4/p')
if [ -n "$lead" ]; then
  case "$lead" in
    \~|\~/*) lead="$HOME${lead#\~}" ;;
    /*) ;;
    *) lead="$base/$lead" ;;
  esac
  if [ -d "$lead" ]; then base=$lead
  else note="⚠️ 선두 cd 경로($lead)를 디렉터리로 해석하지 못해 세션 cwd($base) 기준으로 잡았습니다 — 워크트리 push 였다면 그 워크트리에서 \`ci-queue.sh run <ROOT> <SHA>\` 로 직접 넣으세요. "; fi
fi

# repo 루트 — git repo 아니면 no-op · opt-in 가드 — 실행 가능한 bin/ci 를 가진 레포만
ROOT=$(git -C "$base" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] && [ -x "$ROOT/bin/ci" ] || exit 0
SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || exit 0

# scripts/ 위치 — ci-gate-before-pr-merge.sh 와 같은 규칙: ISSUE_RUNNER_SCRIPTS 환경변수 →
# 이 훅 파일(심링크면 따라간 실제 위치)의 ../scripts → 설치 경로(README 설치 계약).
src="$0"
while [ -L "$src" ]; do
  d=$(cd "$(dirname "$src")" && pwd); src=$(readlink "$src")
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
Q=""
for cand in "${ISSUE_RUNNER_SCRIPTS:-}" "$(cd "$(dirname "$src")/.." && pwd)/scripts" "$HOME/.claude/skills/issue-runner/scripts"; do
  [ -n "$cand" ] && [ -x "$cand/ci-queue.sh" ] && { Q="$cand/ci-queue.sh"; break; }
done
if [ -z "$Q" ]; then
  # exit 0 의 stderr 는 세션에 안 보인다 — 실패도 additionalContext 로 알린다(머지 게이트에서야 아는 일 방지)
  ctx "❌ 로컬 CI: scripts/ci-queue.sh 를 찾지 못해 ${SHA:0:8} 를 큐에 넣지 못했습니다(issue-runner 설치·심링크 확인, ISSUE_RUNNER_SCRIPTS 로 지정 가능). 이 커밋은 CI 결과가 없어 머지 게이트에 막힙니다."
  exit 0
fi

# 백그라운드 — hook 반환 후에도 생존(nohup + fd 리다이렉트 + </dev/null + disown)
nohup "$Q" run "$ROOT" "$SHA" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null

# 세션에 직접 알린다(additionalContext) — 결과를 기다리는 표준 통로는 `wait` 를 백그라운드
# Bash 로 띄우는 것. 끝나면 명령이 종료되고 Claude Code 가 세션을 깨운다 — sleep 폴링 금지.
ctx "${note}로컬 CI 큐 등록: ${SHA:0:8} (ROOT $ROOT — 박스 전체 직렬, 다른 세션·워크트리 포함). 결과 대기는 지금 이 명령을 Bash run_in_background=true 로 실행하세요: $Q wait $SHA  — pass/fail/폐기가 정해지면 명령이 끝나고 세션이 자동으로 깨어납니다(종료 코드 0=pass·1=fail·2=큐에 없음·124=타임아웃). sleep 폴링·bin/ci 직접 실행 금지. 머지는 게이트가 판정."
exit 0
