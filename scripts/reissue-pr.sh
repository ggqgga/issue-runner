#!/usr/bin/env bash
# reissue-pr.sh — 재디스패치 상한에 닿은 PR 의 **처방**을 한 자리에 모은 결정적 헬퍼 (#301).
#
# usage:
#   reissue-pr.sh <owner/repo> <pr> <issue>               # 재발행(기본 처방)
#   reissue-pr.sh grant-round <owner/repo> <pr> <issue>   # 사람 예외 회차(`회차 허용:`) 판정·적용
#
# 배경(왜 held 가 아니라 재발행인가): `VERIFY_ATTEMPTS_LIMIT` 에 닿으면 예전엔 `hold:policy`
# 로 사람에게 "한 회차 더 줄까" 를 물었다. 2026-09-11 하루에 그 질문이 네 PR 에서 나왔고 넷
# 다 사람이 한 회차를 줬는데 셋이 그 회차도 BLOCKER 로 끝나 **같은 질문이 다시** 올라왔다.
# 상한에 닿은 PR 은 대개 누적된 반송 문맥이 문제라, 회차를 얹으면 BLOCKER 가 위치만 옮겨
# 다닌다. 그래서 기본 처방을 **재발행**(PR 을 닫고 검증자의 마지막 스펙으로 새 이슈)으로
# 바꾸고, 예외 회차는 사람이 문형 한 줄로만 준다.
#
# ── 쓰기 순서가 이 스크립트의 안전 계약이다 ────────────────────────────────
#   발행 → 확인 → (재발행 마커) → blocked-by 이전 → PR 닫기 → 원 이슈 닫기
# 순서를 뒤집으면 원 이슈가 닫히고 새 이슈가 없는 **유실**이 난다. 그래서:
#   · 조회가 하나라도 실패하면 아무것도 쓰지 않는다(exit 2 — 빈 결과와 실패를 구분한다).
#   · 새 이슈 발행·확인이 실패하면 **아무것도 닫지 않는다**(exit 3).
#   · 발행 뒤 단계가 실패하면 닫기를 멈추고 exit 4 — 원 이슈가 열려 있어야 다음 틱이 이어간다.
#   · `blocked-by:<구>` 이전은 **원 이슈를 닫기 전**이다. 닫힌 블로커는 eligible 게이트가
#     "해제" 로 읽어(block-issue.sh 머리말) 하위 이슈가 조기에 풀린다.
# 멱등: 발행 직후 원 이슈에 `<!-- reissued: #N -->` 마커를 남긴다. 뒤 단계가 실패해 다음 틱이
# 다시 불려도 그 마커를 보고 **새 이슈를 또 만들지 않고** 닫기부터 이어간다.
#
# 상태 파일 없음 — 상태는 GitHub 의 코멘트 마커·라벨·이슈 상태가 전부다(레포 규약).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../skills/verify-runner/references/reissue.md"
LIMIT="${VERIFY_ATTEMPTS_LIMIT:-3}"
MARKER_WORKER='<!-- bodat:worker -->'

usage() {
  cat >&2 <<'USAGE'
usage:
  reissue-pr.sh <owner/repo> <pr> <issue>               # 재발행
  reissue-pr.sh grant-round <owner/repo> <pr> <issue>   # `회차 허용: +1 — 범위: …` 판정·적용
USAGE
}

die() { local code="$1"; shift; echo "reissue-pr: $*" >&2; exit "$code"; }
warn() { echo "reissue-pr: $*" >&2; }

_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

mode=reissue
if [ "${1:-}" = "grant-round" ]; then
  mode=grant
  shift
fi
repo="${1:-}"
pr="${2:-}"
issue="${3:-}"
[ "$#" -eq 3 ] || { usage; exit 64; }
case "$repo" in */*) ;; *) usage; exit 64 ;; esac
_int "$pr" || { usage; exit 64; }
_int "$issue" || { usage; exit 64; }
_int "$LIMIT" && [ "$LIMIT" -ge 1 ] || die 64 "VERIFY_ATTEMPTS_LIMIT 은 1 이상의 정수여야 한다 (받은 값: '$LIMIT')"

# 인용(코드펜스·인라인 코드) 안의 문형은 **신호가 아니다**. 이 판정기는 `resume-sweep.sh` 가
# 마커에 쓰는 것과 **같은 한 자리**(jq-unquote.sh)다 — 두 벌로 갈라지면 사람 눈에 안 보이는
# 두 번째 계산기가 생긴다(#197 이 네 회차를 돈 축). 못 얻으면 fail-closed 로 끊는다:
# 정의 없이 돌리면 판정이 파싱 실패가 되고, 그건 "인용을 안 걷어낸" 게 아니라 판정이 꺼진 것이다.
JQ_UNQUOTE=$("$SCRIPT_DIR/jq-unquote.sh" 2>/dev/null) || JQ_UNQUOTE=""
[ -n "$JQ_UNQUOTE" ] || die 2 "jq-unquote.sh 에서 인용 제거 정의를 못 얻었다 — 경로·실행비트 확인"

tmp=$(mktemp -d) || tmp=""
[ -n "$tmp" ] && [ -d "$tmp" ] || die 2 "임시 디렉터리 생성 실패"
trap 'rm -rf "$tmp"' EXIT

# ── 조회 (전부 fail-closed — 빈 결과와 실패를 구분한다) ────────────────────
comments_of() {  # comments_of <이슈|PR 번호> — 코멘트 전량 JSON 배열(페이지네이션은 헬퍼가)
  "$SCRIPT_DIR/pr-comments.sh" "$repo" "$1"
}

# 사람이 준 예외 회차 문형. 판정 조건 셋:
#   ⑴ **줄 머리**에서 시작한다(`(^|\n)` — jq/Oniguruma 의 `^` 는 줄 머리가 아니라 문자열
#      머리라 직접 쓴다. 실측: `test("^```")` 는 2행의 펜스에 거짓이다).
#   ⑵ **머신 코멘트는 제외**한다(`<!-- bodat:worker -->` 가 든 코멘트 — 루프가 자기 문장을
#      사람 지시로 되읽으면 서킷 브레이커가 스스로 풀린다).
#   ⑶ **인용 안은 신호가 아니다** — 코드펜스·인라인 코드는 `unquoted` 가 먼저 지운다.
#      이 기능의 문서(SKILL·README)와 이 파일 자체가 문형을 글자 그대로 적으므로, 그걸
#      코멘트에 붙여넣어도 판정이 켜지면 안 된다(테스트 ⑥-b 가 실제 문서 파일을 읽어 문다).
# `[ \t]` 를 쓰는 이유: Oniguruma 의 `\s` 는 개행을 포함해, 줄을 넘어 매칭되면 한 줄 계약이
# 무너진다(앞 줄의 `회차 허용:` 과 뒷 줄의 `범위:` 가 한 신호로 붙는다).
GRANT_RE='(^|\n)[ \t]*회차 허용:[ \t]*\+1[ \t]*—[ \t]*범위:[ \t]*(?<s>[^\n]*[^ \t\n])'

grant_scopes() {  # grant_scopes <코멘트 JSON> → 매칭된 범위 문장을 줄마다 (없으면 빈 출력)
  printf '%s' "$1" | jq -r "$JQ_UNQUOTE"' [ .[]? | .body // ""
      | select(test("<!--\\s*bodat:worker\\s*-->") | not)
      | unquoted
      | capture($re)? | .s ] | .[]' --arg re "$GRANT_RE" 2>/dev/null
}

marker_count() {  # marker_count <코멘트 JSON> <마커 정규식>
  printf '%s' "$1" | jq -r "$JQ_UNQUOTE"' [ .[]? | .body // "" | unquoted
      | select(test($re)) ] | length' --arg re "$2" 2>/dev/null
}

attempt_of() {  # attempt_of <PR 본문> → verify-attempt 값(없으면 0)
  local n
  n=$(printf '%s\n' "$1" | grep -o '<!-- *verify-attempt: *[0-9][0-9]* *-->' | tail -1 \
      | grep -o '[0-9][0-9]*' | tail -1)
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,headRefName,headRefOid,body 2>/dev/null) \
  || die 2 "PR #$pr 조회 실패 — 아무것도 쓰지 않았다"
printf '%s' "$pr_json" | jq -e 'type=="object"' >/dev/null 2>&1 \
  || die 2 "PR #$pr 조회 결과가 오브젝트가 아니다 — 아무것도 쓰지 않았다"
pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""')
head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
attempt=$(attempt_of "$pr_body")

issue_comments=$(comments_of "$issue") \
  || die 2 "이슈 #$issue 코멘트 조회 실패 — 아무것도 쓰지 않았다"

granted=$(marker_count "$issue_comments" '<!--\s*round-granted\s*-->')
_int "$granted" || die 2 "round-granted 마커 판정 실패(jq) — 아무것도 쓰지 않았다"

# ── grant-round — 사람 예외 회차 ───────────────────────────────────────────
if [ "$mode" = grant ]; then
  scopes=$(grant_scopes "$issue_comments")
  if [ -z "$scopes" ]; then
    echo "none: 회차 허용 문형 없음 (#$issue)"
    exit 0
  fi
  if [ "$granted" -ge 1 ]; then
    warn "warn: 회차 허용 중복 — 이슈 #$issue 은 이미 <!-- round-granted --> 가 있다(예외는 이슈당 한 번). 무시한다"
    echo "ignored: 두 번째 회차 허용 (#$issue)"
    exit 0
  fi
  n_scopes=$(printf '%s\n' "$scopes" | grep -c . || true)
  [ "$n_scopes" -le 1 ] || warn "warn: 회차 허용이 $n_scopes 건 — 가장 오래된 한 건만 적용한다 (#$issue)"
  scope=$(printf '%s\n' "$scopes" | head -1)
  target=$((LIMIT - 1))

  # 마커 코멘트가 **먼저**다 — 카운터 없는 허용은 상한이 안 걸리는 무한 재시도가 된다
  # (resume-sweep 의 "마커 먼저 → 라벨" 과 같은 이유).
  if ! gh issue comment "$issue" --repo "$repo" --body "회차 허용 접수: attempt 을 $target 로 되돌린다 — 범위: $scope
<!-- round-granted -->
$MARKER_WORKER" >/dev/null 2>&1; then
    die 4 "회차 허용 마커 코멘트 실패 (#$issue) — 아직 아무것도 적용하지 않았다, 다음 틱 재시도"
  fi

  # PR 본문 attempt 를 LIMIT-1 **로 되돌린다**. 이미 그 아래면 되돌릴 것이 없다 —
  # 덮어쓰면 남은 정상 회차를 깎는다(허용이 회차를 뺏는 방향으로 틀리면 안 된다).
  if [ "$attempt" -ge "$target" ]; then
    if printf '%s' "$pr_body" | grep -q '<!-- *verify-attempt: *[0-9][0-9]* *-->'; then
      printf '%s' "$pr_body" | sed "s/<!-- *verify-attempt: *[0-9][0-9]* *-->/<!-- verify-attempt: $target -->/g" > "$tmp/prbody.md"
    else
      printf '%s\n<!-- verify-attempt: %s -->\n' "$pr_body" "$target" > "$tmp/prbody.md"
    fi
    if ! gh pr edit "$pr" --repo "$repo" --body-file "$tmp/prbody.md" >/dev/null 2>&1; then
      die 4 "PR #$pr 본문 verify-attempt 갱신 실패 — 마커는 남았다(중복 적용은 안 된다), 사람 확인"
    fi
  else
    warn "note: PR #$pr 의 attempt=$attempt 은 이미 $target 이하 — 되돌릴 것이 없다(회차를 깎지 않는다)"
  fi

  echo "granted: #$issue — 범위: $scope"
  exit 0
fi

# ── 재발행 ────────────────────────────────────────────────────────────────
# 살아있는 예외 회차는 재발행에 밟히지 않는다. `round-granted` 마커가 있고 아직 그 회차를
# 안 쓴 상태(attempt < LIMIT)면 이번엔 재디스패치가 답이다 — 호출자가 범위 문장을 반송
# 프롬프트에 싣는다. (허용 회차가 소진되면 attempt 가 LIMIT 에 닿아 여기를 통과한다.)
if [ "$granted" -ge 1 ] && [ "$attempt" -lt "$LIMIT" ]; then
  live_scope=$(grant_scopes "$issue_comments" | head -1)
  [ -n "$live_scope" ] || live_scope="(원 코멘트를 못 찾음 — 이슈 #$issue 의 회차 허용 코멘트를 읽어라)"
  echo "grant-live: #$issue — 범위: $live_scope"
  exit 65
fi

issue_json=$(gh issue view "$issue" --repo "$repo" --json number,title,body,labels,state 2>/dev/null) \
  || die 2 "이슈 #$issue 조회 실패 — 아무것도 쓰지 않았다"
printf '%s' "$issue_json" | jq -e 'type=="object"' >/dev/null 2>&1 \
  || die 2 "이슈 #$issue 조회 결과가 오브젝트가 아니다 — 아무것도 쓰지 않았다"
issue_title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
issue_state=$(printf '%s' "$issue_json" | jq -r '.state // ""')
[ -n "$issue_title" ] || die 2 "이슈 #$issue 제목이 비었다 — 조회가 어긋났다, 아무것도 쓰지 않았다"

pr_comments=$(comments_of "$pr") \
  || die 2 "PR #$pr 코멘트 조회 실패 — 검증자 스펙 없이 발행하지 않는다(아무것도 쓰지 않았다)"

# 검증자의 **마지막** 코멘트 본문을 원문 그대로 싣는다(요약하지 않는다 — 요약이 스펙을 깎는다).
findings=$(printf '%s' "$pr_comments" | jq -r '
  [ .[]? | .body // "" | select(startswith("검증자 리뷰:")) ] | last // ""')
if [ -z "$findings" ]; then
  findings="(PR #$pr 에서 \`검증자 리뷰:\` 코멘트를 못 찾았다 — 그 PR 의 코멘트를 직접 읽어라.)"
else
  findings=$(printf '%s' "$findings" | grep -vF "$MARKER_WORKER")
fi
last_bounce=$(printf '%s' "$pr_comments" | jq -r '
  [ .[]? | .body // "" | select(startswith("재검증 실패:")) | split("\n")[0] ] | last // ""')
[ -n "$last_bounce" ] || last_bounce="(반송 코멘트 없음)"

epic_line=$(printf '%s\n' "$issue_body" | grep -m1 -E '^Epic #[0-9]+' || true)

# 이미 재발행한 이슈인가 — 마커가 있으면 새 이슈를 또 만들지 않고 닫기부터 이어간다.
new=$(printf '%s' "$issue_comments" | jq -r "$JQ_UNQUOTE"'
  [ .[]? | .body // "" | unquoted | capture("<!--\\s*reissued:\\s*#(?<n>[0-9]+)\\s*-->")? | .n ] | last // ""' 2>/dev/null)
_int "$new" || new=""

if [ -z "$new" ]; then
  [ -f "$TEMPLATE" ] || die 2 "템플릿 없음: $TEMPLATE — 아무것도 쓰지 않았다"
  tpl=$(cat "$TEMPLATE") || die 2 "템플릿 읽기 실패: $TEMPLATE"
  body="$tpl"
  body=${body//<PR>/$pr}
  body=${body//<ISSUE>/$issue}
  body=${body//<EPIC_LINE>/$epic_line}
  body=${body//<BRANCH>/$head_ref}
  body=${body//<HEAD_SHA>/$head_sha}
  body=${body//<LAST_BOUNCE>/$last_bounce}
  body=${body//<VERIFIER_FINDINGS>/$findings}
  body=${body//<ISSUE_BODY>/$issue_body}
  printf '%s\n' "$body" > "$tmp/newbody.md"

  # 라벨 상속 — 레인·단계 라벨은 새 이슈로 넘기지 않는다(그건 "지금 누가 들고 있나" 라서
  # 새 이슈에선 거짓이다). `spinoff` 는 애초에 안 붙는다 — 재발행은 파생이 아니라 재시도다.
  label_args=()
  printf '%s' "$issue_json" | jq -r '.labels[]?.name // empty' > "$tmp/labels.txt" \
    || die 2 "이슈 #$issue 라벨 파싱 실패 — 아무것도 닫지 않았다"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in
      agent-ready|agent:claimed|needs-human|harvesting|deploy-wait|spinoff|dup|loop-dashboard|epic|full-cycle) continue ;;
      flow:*|hold:*) continue ;;
    esac
    label_args+=(--label "$l")
  done < "$tmp/labels.txt"
  label_args+=(--label agent-ready)

  title="$issue_title (재발행 ← #$issue)"
  url=$(gh issue create --repo "$repo" --title "$title" --body-file "$tmp/newbody.md" \
        "${label_args[@]}" 2>"$tmp/create.err") || url=""
  if [ -z "$url" ]; then
    # 레포에 없는 라벨 하나가 발행 **전체**를 실패시킨다 — 라벨 없이 다시 내고 뒤에서 붙인다.
    warn "warn: 라벨 포함 발행 실패($(tail -1 "$tmp/create.err" 2>/dev/null)) — 라벨 없이 재시도"
    url=$(gh issue create --repo "$repo" --title "$title" --body-file "$tmp/newbody.md" 2>>"$tmp/create.err") || url=""
    relabel=1
  else
    relabel=0
  fi
  [ -n "$url" ] || die 3 "새 이슈 발행 실패 — 아무것도 닫지 않았다 ($(tail -1 "$tmp/create.err" 2>/dev/null))"
  new=$(printf '%s' "$url" | grep -o '[0-9][0-9]*$')
  _int "$new" || die 3 "새 이슈 번호를 못 읽었다(출력: $url) — 아무것도 닫지 않았다"

  # 확인 — 발행이 실제로 열린 이슈를 만들었나. 여기까지 통과해야 닫기로 간다.
  conf=$(gh issue view "$new" --repo "$repo" --json number,state 2>/dev/null) || conf=""
  conf_state=$(printf '%s' "$conf" | jq -r '.state // ""' 2>/dev/null)
  [ "$conf_state" = "OPEN" ] || die 3 "새 이슈 #$new 확인 실패(state='$conf_state') — 아무것도 닫지 않았다"

  # 멱등 앵커 — 이 마커 뒤로는 다시 불려도 발행하지 않는다.
  if ! gh issue comment "$issue" --repo "$repo" --body "재발행: #$issue → #$new (attempt 상한 $LIMIT)
<!-- reissued: #$new -->
$MARKER_WORKER" >/dev/null 2>&1; then
    die 4 "재발행 마커 코멘트 실패 — 새 이슈 #$new 는 발행됐다. 닫기를 멈춘다(다음 틱이 중복 발행하지 않도록 사람이 마커를 확인하라)"
  fi

  if [ "$relabel" = 1 ]; then
    for a in "${label_args[@]}"; do
      if [ "$a" = "--label" ] || [ -z "$a" ]; then continue; fi
      gh issue edit "$new" --repo "$repo" --add-label "$a" >/dev/null 2>&1 \
        || warn "warn: 새 이슈 #$new 에 라벨 '$a' 부착 실패"
    done
    back=$(gh issue view "$new" --repo "$repo" --json labels 2>/dev/null) || back=""
    if ! printf '%s' "$back" | jq -e '[.labels[]?.name] | index("agent-ready")' >/dev/null 2>&1; then
      die 4 "새 이슈 #$new 에 agent-ready 가 없다 — 레인에 못 든다. 닫기를 멈춘다(사람이 부착: gh issue edit $new --repo $repo --add-label agent-ready)"
    fi
  fi
else
  warn "note: 이슈 #$issue 은 이미 #$new 로 재발행돼 있다 — 발행을 건너뛰고 닫기만 이어간다"
fi

# blocked-by 이전 — **원 이슈를 닫기 전**에.
blocked=$(gh issue list --repo "$repo" --state open --label "blocked-by:$issue" --json number --limit 100 2>/dev/null) || blocked="__FAIL__"
[ "$blocked" != "__FAIL__" ] || die 4 "blocked-by:$issue 조회 실패 — 원 이슈를 닫지 않는다(닫힌 블로커는 해제로 읽힌다)"
for b in $(printf '%s' "$blocked" | jq -r '.[]?.number // empty' 2>/dev/null); do
  "$SCRIPT_DIR/block-issue.sh" "$repo" "$b" "$new" >/dev/null 2>&1 \
    || die 4 "#$b 의 blocked-by 를 #$new 로 옮기지 못했다 — 원 이슈를 닫지 않는다"
  gh issue edit "$b" --repo "$repo" --remove-label "blocked-by:$issue" >/dev/null 2>&1 \
    || die 4 "#$b 에서 blocked-by:$issue 제거 실패 — 원 이슈를 닫지 않는다"
done

# PR 닫기 — 브랜치는 남긴다(`--delete-branch` 를 쓰지 않는다. 새 워커가 참고한다).
if [ "$pr_state" = "OPEN" ]; then
  gh pr close "$pr" --repo "$repo" --comment "재발행으로 닫는다 — 후속 이슈 #$new (원 이슈 #$issue, attempt 상한 $LIMIT).
브랜치 \`$head_ref\` 는 남겨 둔다(마지막 head \`$head_sha\`) — 새 워커가 참고하되 그대로 이어받지 않는다.
$MARKER_WORKER" >/dev/null 2>&1 \
    || die 4 "PR #$pr 닫기 실패 — 원 이슈를 닫지 않는다(다음 틱 재시도)"
fi

# 원 이슈 닫기 — not planned(재발행이라 '완료' 가 아니다).
if [ "$issue_state" = "OPEN" ]; then
  gh issue close "$issue" --repo "$repo" --reason "not planned" \
    --comment "재발행으로 닫는다 — 후속 이슈 #$new. PR #$pr 은 닫혔고 브랜치 \`$head_ref\` 는 남아 있다.
$MARKER_WORKER" >/dev/null 2>&1 \
    || die 4 "원 이슈 #$issue 닫기 실패 — 다음 틱이 마커를 보고 이어간다"
fi

echo "재발행: #$issue → #$new (PR #$pr 닫음, attempt 상한 $LIMIT)"
