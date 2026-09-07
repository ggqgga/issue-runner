#!/usr/bin/env bash
# ci-gate-before-pr-merge.sh — `gh pr merge` 직전 게이트.
#
#  • 로컬 CI 세팅된 레포(실행 가능한 bin/ci 보유 — 언어 무관.
#    예: BoDAT=Rails 8 네이티브, Temphra=폴리글롯 스크립트):
#      local-ci.sh 가 push 때 캐시한 PR head SHA 의 결과로 판정.
#      pass=통과 / fail=차단(실패 스텝) / 진행중=차단 / 없음=차단. GitHub Actions 미사용.
#  • 그 외 레포:
#      기존 동작 — GitHub statusCheckRollup(Actions/commit status)으로 판정.
#
# 차단은 exit 2 + stderr(다음 턴에 Claude/사용자가 즉시 인지). PreToolUse(Bash, if: gh pr merge*).
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && cmd=$(printf '%s' "$input" \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

# self-filter — settings 의 if 매칭이 빠진 경로에서도 안전하게 패스스루.
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
  || exit 0

# --repo 플래그 (#47) — closeout 등 계정 전체 머저는 cwd 밖 레포 PR을 머지한다.
# 있으면 조회·캐시 경로를 그 레포 기준으로 잡고, 없으면 cwd 기준(기존 동작 100% 보존).
flag_repo=$(printf '%s' "$cmd" | sed -n -E 's/.*--repo[ =]+([^ ]+).*/\1/p' | head -1)
gh_pr_view() {  # $1=대상, 이후=추가 인자. flag_repo 있으면 --repo 주입.
  if [ -n "$flag_repo" ]; then gh pr view "$1" --repo "$flag_repo" "${@:2}"
  else gh pr view "$1" "${@:2}"; fi
}

# PR 대상 추출 — `gh pr merge` 는 <번호>·<URL>·<브랜치명> 을 모두 받는다.
# "gh pr merge" 뒤 첫 비플래그 토큰이 대상 (플래그만 있으면 현재 브랜치 PR).
target=$(printf '%s' "$cmd" | awk '{
  for (i = 1; i <= NF - 2; i++)
    if ($i ~ /(^|[;|&])gh$/ && $(i+1) == "pr" && $(i+2) == "merge") {
      for (j = i + 3; j <= NF; j++)
        if ($(j) !~ /^-/) { print $(j); exit }
      exit
    }
}')
if [ -n "$target" ]; then
  case "$target" in
    *[!0-9]*) # URL·브랜치명 — gh 로 PR 번호 해석 (gh pr view 도 세 형태 모두 받음)
      pr_num=$(gh_pr_view "$target" --json number 2>/dev/null | jq -r '.number // empty') ;;
    *) pr_num=$target ;;
  esac
else
  # 대상 인자 없이 호출 — 현재 브랜치의 PR.
  pr_num=$(gh pr view --json number 2>/dev/null | jq -r '.number // empty')
fi
# PR 식별 불가 — fail-closed. (통과시키면 URL/브랜치 머지가 게이트를 우회한다.)
if [ -z "$pr_num" ]; then
  printf 'gh pr merge 대상(%s)의 PR 번호를 확인할 수 없어 게이트 판정 불가 — 차단합니다.\nPR 번호로 다시 시도하거나 네트워크/인증(gh auth status)을 확인하세요.\n' \
    "${target:-현재 브랜치}" >&2
  exit 2
fi

# ── 문서 전용 PR 면제 (docs-only) ────────────────────────────────────
# 변경 파일이 전부 문서(Plans/·Docs/·*.md)면 CI 게이트를 건너뛴다 — 코드 변경 0 이라
# 테스트 영향이 없다(문서는 복잡한 CI 절차 없이 머지·배포). 파일 목록 조회 실패나
# 빈 목록은 면제하지 않고(fail-safe) 아래 정상 게이트로 떨어진다. 코드 파일이 하나라도
# 섞이면 nondoc 이 잡혀 게이트가 그대로 적용된다.
files=$(gh_pr_view "$pr_num" --json files 2>/dev/null | jq -r '.files[].path // empty')
if [ -n "$files" ]; then
  nondoc=$(printf '%s\n' "$files" | grep -vE '^(Plans|Docs)/|\.md$' | head -1)
  if [ -z "$nondoc" ]; then
    printf 'PR #%s 문서 전용(Plans/·Docs/·*.md) — CI 게이트 면제, 머지 허용.\n' "$pr_num" >&2
    exit 0
  fi
fi

# scripts/ 위치 — local-ci.sh 와 같은 규칙: ISSUE_RUNNER_SCRIPTS 환경변수 → 이 훅 파일
# (심링크면 따라간 실제 위치)의 ../scripts → 설치 경로(README 설치 계약).
src="$0"
while [ -L "$src" ]; do
  d=$(cd "$(dirname "$src")" && pwd); src=$(readlink "$src")
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
find_script() {  # <name> → 실행 가능한 경로 또는 빈 문자열
  local cand
  for cand in "${ISSUE_RUNNER_SCRIPTS:-}" "$(cd "$(dirname "$src")/.." && pwd)/scripts" "$HOME/.claude/skills/issue-runner/scripts"; do
    [ -n "$cand" ] && [ -x "$cand/$1" ] && { printf '%s' "$cand/$1"; return; }
  done
}

# ROOT — flag_repo 있으면 그 레포의 로컬 체크아웃(repo-dir.sh), 없으면 cwd(기존).
if [ -n "$flag_repo" ]; then
  rd=$(find_script repo-dir.sh)
  ROOT=""
  [ -n "$rd" ] && ROOT=$("$rd" "$flag_repo" 2>/dev/null)
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
fi

# ── 로컬 CI 레포 분기 ────────────────────────────────────────────────
if [ -n "$ROOT" ] && [ -x "$ROOT/bin/ci" ]; then

  # PR head SHA(무료 API — Actions 아님).
  sha=$(gh_pr_view "$pr_num" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty')
  if [ -z "$sha" ]; then
    printf 'PR #%s 의 head SHA 를 조회할 수 없습니다(gh pr view 실패). 네트워크/인증을 확인하세요.\n' "$pr_num" >&2
    exit 2
  fi
  short="${sha:0:8}"
  # 결과 조회는 큐에 위임(#127) — 키는 SHA, 슬러그 무관. SHA 는 커밋 고유값이고 큐가 실행
  # 직전 HEAD==SHA 를 검사하므로, 어느 워크트리에서 돌았든 같은 커밋의 결과다 — 워크트리
  # cwd 로 옮겨 머지해야 하던 함정을 닫는다. 큐 스크립트가 없으면 설치 결함으로 따로 말한다.
  q=$(find_script ci-queue.sh)
  if [ -z "$q" ]; then
    printf 'PR #%s 로컬 CI 판정 불가 — scripts/ci-queue.sh 를 찾지 못했습니다(issue-runner 설치·심링크 확인, ISSUE_RUNNER_SCRIPTS 로 지정 가능). 차단합니다.\n' "$pr_num" >&2
    exit 2
  fi
  if res=$("$q" result "$sha" 2>/dev/null); then
    verdict="${res%% *}"; log="${res#* }"; log="${log%.result}.log"
    [ "$verdict" = pass ] && exit 0
    printf 'PR #%s 로컬 CI 실패(%s).\n--- bin/ci 마지막 출력 ---\n%s\n----------------------------\n실패를 고치고 다시 push 하세요.\n' \
      "$pr_num" "$short" "$(tail -25 "$log" 2>/dev/null)" >&2
    exit 2
  fi

  # 결과 없음 — 큐에 물어 "실행 중 / 대기열 N번째 / 없음" 을 구분해 안내한다. 판정은 셋 다
  # 차단(exit 2) — 기다리는 통로는 `ci-queue.sh wait <SHA>` 를 백그라운드 Bash 로 띄우는 것.
  qs=$("$q" status "$sha" 2>/dev/null || echo none)
  case "$qs" in
    running) state="실행 중" ;;
    queued*) state="대기열 ${qs#queued }번째" ;;
    *)
      printf 'PR #%s 로컬 CI 결과 없음(%s) — 큐에도 없습니다.\n해당 커밋을 단독 `git push` 하면 훅이 큐에 넣거나, 워크트리에서 `%s run <ROOT> %s` 로 직접 넣은 뒤 머지하세요.\n' \
        "$pr_num" "$short" "$q" "$sha" >&2
      exit 2 ;;
  esac
  printf 'PR #%s 로컬 CI %s(%s). 기다리려면 `%s wait %s` 를 run_in_background 로 띄우세요 — 끝나면 깨어납니다.\n' \
    "$pr_num" "$state" "$short" "$q" "$sha" >&2
  exit 2
fi

# ── 그 외 레포 — 기존 GitHub statusCheckRollup 동작 ───────────────────
rollup=$(gh_pr_view "$pr_num" --json statusCheckRollup 2>/dev/null)
if [ -z "$rollup" ]; then
  printf 'CI 상태를 조회할 수 없습니다 (gh pr view 실패). 네트워크 또는 인증 상태를 확인하세요.\n' >&2
  exit 2
fi

checks=$(printf '%s' "$rollup" | jq -c '.statusCheckRollup // []')
count=$(printf '%s' "$checks" | jq 'length')

if [ "$count" = "0" ]; then
  printf 'PR #%s 에 등록된 CI 체크가 없습니다.\nCI 워크플로우가 트리거됐는지 확인한 뒤 다시 머지를 시도하세요.\n' "$pr_num" >&2
  exit 2
fi

# 미완료 (status != COMPLETED 이고 commit-status state 도 SUCCESS/FAILURE 가 아닌 것).
pending=$(printf '%s' "$checks" | jq -r '
  .[]
  | select(
      ((.status // "") != "COMPLETED")
      and ((.state // "") != "SUCCESS")
      and ((.state // "") != "FAILURE")
      and ((.state // "") != "ERROR")
    )
  | "  - \(.name // .context // .workflowName // "?") = \(.status // .state // "PENDING")"
' | head -20)

if [ -n "$pending" ]; then
  printf 'PR #%s 의 CI 가 아직 끝나지 않았습니다:\n%s\n완료 후 다시 머지를 시도하세요.\n' "$pr_num" "$pending" >&2
  exit 2
fi

# 비통과 항목 — SUCCESS-only allowlist (scripts/closeout-ci-pass.sh 와 SSOT 정렬, #60).
# 통과 모양(check-run: COMPLETED+SUCCESS / 레거시 commit-status: state==SUCCESS)을
# 정의하고 그 외를 전부 negate 한다. denylist 가 아니라 good-then-negate 라
# 미열거 종결값(STARTUP_FAILURE·NEUTRAL·SKIPPED·미래/오타 conclusion)도 자동으로
# 차단된다 — 비통과 PR 이 머지로 새는 경로를 닫는다. (위 pending 가 미완료를 먼저
# 거르므로 여기 negate 가 미완료와 충돌하지 않는다.)
failed=$(printf '%s' "$checks" | jq -r '
  .[]
  | select(
      (
        ((.status // "") == "COMPLETED") and ((.conclusion // "") == "SUCCESS")
      ) or (
        ((.status // "") == "") and ((.state // "") == "SUCCESS")
      )
      | not
    )
  | "  - \(.name // .context // .workflowName // "?") = \(.conclusion // .state // "?")"
' | head -20)

if [ -n "$failed" ]; then
  printf 'PR #%s 의 CI 가 통과하지 않은 체크를 포함합니다:\n%s\n원인을 해결한 뒤 머지하세요.\n' "$pr_num" "$failed" >&2
  exit 2
fi

# 여기까지 왔으면 모두 SUCCESS — 통과.
exit 0
