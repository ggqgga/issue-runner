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
#   ⑴ **줄 머리, 또는 공백·em dash·`*` 바로 뒤**에서 시작한다. 사람이 실제로 적는 줄은
#      `사람 결정: **ⓐ — 회차 허용: +1 — 범위: …** 그 외 수정 금지.` 처럼 머리말과 굵게 표시
#      뒤에 문형이 온다(2026-09-12 #283·#244 실측 — 문서가 규정한 문형과 파서가 읽는 형태가
#      갈리면 규칙이 없는 것과 같다, PR #318 반송 ⑶). 따옴표·등호·글자 바로 뒤(`'회차 허용:`·
#      `GRANT_PHRASE='…`)는 스크립트·문서 줄을 붙여넣은 인용이라 신호가 아니다 — 앞 글자
#      클래스 `[ \t—*]` 가 그 경계다. (`(^|\n)` 을 직접 쓰는 이유: jq/Oniguruma 의 `^` 는
#      줄 머리가 아니라 문자열 머리다. 실측: `test("^```")` 는 2행의 펜스에 거짓이다.)
#      범위는 문형 뒤 **줄 끝까지**이고 굵게 표시(`**`)만 걷어낸다 — 사람이 굵게 닫은 뒤 같은
#      줄에 덧붙인 문장("그 외 수정 금지.")도 범위의 일부다(경계를 좁히지 않는다).
#   ⑵ **머신 코멘트는 제외**한다(`<!-- bodat:worker -->` 가 든 코멘트 — 루프가 자기 문장을
#      사람 지시로 되읽으면 서킷 브레이커가 스스로 풀린다).
#   ⑶ **인용 안은 신호가 아니다** — 코드펜스·인라인 코드는 `unquoted` 가 먼저 지운다.
#      이 기능의 문서(SKILL·README)와 이 파일 자체가 문형을 글자 그대로 적으므로, 그걸
#      코멘트에 붙여넣어도 판정이 켜지면 안 된다(테스트 ⑥-b 가 실제 문서 파일을 읽어 문다).
# `[ \t]` 를 쓰는 이유: Oniguruma 의 `\s` 는 개행을 포함해, 줄을 넘어 매칭되면 한 줄 계약이
# 무너진다(앞 줄의 `회차 허용:` 과 뒷 줄의 `범위:` 가 한 신호로 붙는다).
GRANT_RE='(^|\n|[ \t—*])회차 허용:[ \t]*\+1[ \t]*—[ \t]*범위:[ \t]*(?<s>[^\n]*[^ \t\n])'

# jq 판정은 전부 **종료코드를 따로 검사**한다 — `2>/dev/null` 로 실패를 삼키면 "문형 없음"
# 으로 둔갑해, 사람이 이슈당 한 번뿐인 예외를 적었는데 흔적도 없이 재발행된다(#139 의 형제).
jq_or_die() {  # jq_or_die <코멘트 JSON> <필터> [--arg …] → stdout, 실패면 die 2
  local json="$1" filter="$2"; shift 2
  local out rc
  out=$(printf '%s' "$json" | jq -r "$JQ_UNQUOTE$filter" "$@" 2>"$tmp/jq.err"); rc=$?
  if [ "$rc" != 0 ]; then
    die 2 "jq 판정 실패(rc=$rc: $(tail -1 "$tmp/jq.err" 2>/dev/null)) — 아무것도 쓰지 않았다"
  fi
  printf '%s' "$out"
}

# 마커·문형은 **인덱스**로 선후를 잰다(코멘트 시각은 초 단위라 동초 선후를 못 가린다 —
# pr-comments.sh 의 순서 계약이 SSOT). 허용이 이미 적용된 뒤에도 사람 코멘트는 남으므로,
# 마커 **이후**의 문형만 "두 번째 요청" 이다 — 안 그러면 매 틱 warn 이 쌓인다.
last_marker_idx() {  # last_marker_idx <코멘트 JSON> <마커 정규식> → 마지막 인덱스(없으면 -1)
  jq_or_die "$1" ' [ .[]? | .body // "" | unquoted | test($re) ] | to_entries
      | [ .[] | select(.value) | .key ] | last // -1' --arg re "$2"
}

grant_rows() {  # grant_rows <코멘트 JSON> → "인덱스<TAB>범위" 줄마다 (사람 코멘트·인용 제외)
  jq_or_die "$1" ' [ .[]? | .body // "" ] | to_entries
      | [ .[] | select(.value | test("<!--\\s*bodat:worker\\s*-->") | not)
          | {i: .key, s: (.value | unquoted | capture($re)? | .s
                          | gsub("\\*\\*"; "") | sub("^[ \\t]+"; "") | sub("[ \\t]+$"; ""))} ]
      | map(select(.s != null and .s != ""))
      | .[] | "\(.i)\t\(.s)"' --arg re "$GRANT_RE"
}

loose_count() {  # loose_count <코멘트 JSON> → 문형이 어긋난 `회차 허용:` 사람 코멘트 수
  jq_or_die "$1" ' [ .[]? | .body // ""
      | select(test("<!--\\s*bodat:worker\\s*-->") | not)
      | unquoted | select(test("(^|\\n|[ \\t—*])회차 허용:")) ] | length'
}

# 새 이슈가 **열려 있고 레인에 들었는지**를 한 자리에서 확인한다. 발행 직후와 멱등
# 재진입(마커가 이미 있는 회차) **양쪽**이 이 함수를 지난다 — 재진입이 확인을 건너뛰면,
# 앞 회차가 라벨 부착에서 멈춰 둔 "레인 밖 새 이슈" 를 그대로 두고 원 이슈를 닫아
# 무인 루프가 스스로 못 푸는 유실이 된다(사전 리뷰 BLOCKER, #301).
ensure_lane() {  # ensure_lane <새 이슈> <실패 시 exit 코드>
  local n="$1" code="$2" v st
  v=$(gh issue view "$n" --repo "$repo" --json number,state,labels 2>/dev/null) || v=""
  [ -n "$v" ] || die "$code" "새 이슈 #$n 확인 조회 실패 — 아무것도 닫지 않았다"
  st=$(printf '%s' "$v" | jq -r '.state // ""' 2>/dev/null)
  [ "$st" = "OPEN" ] || die "$code" "새 이슈 #$n 이 OPEN 이 아니다(state='$st') — 아무것도 닫지 않았다"
  if printf '%s' "$v" | jq -e '[.labels[]?.name] | index("agent-ready")' >/dev/null 2>&1; then
    return 0
  fi
  warn "warn: 새 이슈 #$n 에 agent-ready 가 없다 — 부착을 시도한다"
  gh issue edit "$n" --repo "$repo" --add-label agent-ready >/dev/null 2>&1 || true
  v=$(gh issue view "$n" --repo "$repo" --json number,state,labels 2>/dev/null) || v=""
  printf '%s' "$v" | jq -e '[.labels[]?.name] | index("agent-ready")' >/dev/null 2>&1 \
    || die "$code" "새 이슈 #$n 에 agent-ready 가 없다 — 레인에 못 든다. 닫기를 멈춘다(사람이 부착: gh issue edit $n --repo $repo --add-label agent-ready)"
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

marker_idx=$(last_marker_idx "$issue_comments" '<!--\s*round-granted\s*-->')
case "$marker_idx" in ''|*[!0-9-]*) die 2 "round-granted 마커 인덱스 판정 실패('$marker_idx') — 아무것도 쓰지 않았다" ;; esac
granted=0
[ "$marker_idx" = "-1" ] || granted=1
grant_rows=$(grant_rows "$issue_comments")
# 마커 **이후**의 문형 = 아직 처리 안 된 요청. 이전 것은 이미 적용된 그 요청이다.
fresh_scopes=""
if [ -n "$grant_rows" ]; then
  fresh_scopes=$(printf '%s\n' "$grant_rows" | awk -F'\t' -v m="$marker_idx" '$1+0 > m+0 { sub(/^[^\t]*\t/, ""); print }')
fi
first_scope=$(printf '%s\n' "$grant_rows" | head -1 | sed 's/^[^\t]*\t//')
loose=$(loose_count "$issue_comments")
_int "$loose" || loose=0
n_strict=0
[ -z "$grant_rows" ] || n_strict=$(printf '%s\n' "$grant_rows" | grep -c . || true)
if [ "$loose" -gt "$n_strict" ]; then
  warn "warn: 이슈 #$issue 에 문형이 어긋난 '회차 허용:' 코멘트가 있다(${loose}건 중 ${n_strict}건만 인식) — 형식은 '회차 허용: +1 — 범위: <한 줄>'(em dash·빈 범위 금지 — 머리말 뒤에 와도 되지만 따옴표·등호 바로 뒤는 인용으로 본다)"
fi

# ── grant-round — 사람 예외 회차 ───────────────────────────────────────────
if [ "$mode" = grant ]; then
  if [ -z "$fresh_scopes" ]; then
    # 마커 이전의 문형만 있는 경우도 여기다 — 이미 적용된 요청이라 **조용히** 넘긴다
    # (매 틱 warn 을 쌓지 않는다). 새 요청이 오면 아래 ignored 로 간다.
    echo "none: 새 회차 허용 문형 없음 (#$issue)"
    exit 0
  fi
  if [ "$granted" -ge 1 ]; then
    warn "warn: 회차 허용 중복 — 이슈 #$issue 은 이미 <!-- round-granted --> 가 있다(예외는 이슈당 한 번). 무시한다"
    echo "ignored: 두 번째 회차 허용 (#$issue)"
    exit 0
  fi
  n_scopes=$(printf '%s\n' "$fresh_scopes" | grep -c . || true)
  [ "$n_scopes" -le 1 ] || warn "warn: 회차 허용이 $n_scopes 건 — 가장 오래된 한 건만 적용한다 (#$issue)"
  scope=$(printf '%s\n' "$fresh_scopes" | head -1)
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
  live_scope="$first_scope"
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
# `startswith` 로 좁히지 않는 이유: 이 레포엔 판정 줄을 코멘트 **중간**에 넣어 머리 매칭
# 게이트가 헛돈 실측 전례가 있다(그때 closeout 큐가 통째로 정체했다). 줄 머리면 센다.
findings=$(printf '%s' "$pr_comments" | jq -r '
  [ .[]? | .body // "" | select(test("(^|\n)검증자 리뷰:")) ] | last // ""') \
  || die 2 "PR #$pr 검증자 코멘트 파싱 실패 — 아무것도 쓰지 않았다"
findings=$(printf '%s' "$findings" | grep -vF "$MARKER_WORKER" || true)
if [ -z "$(printf '%s' "$findings" | tr -d '[:space:]')" ]; then
  # 재발행의 알맹이가 비었다 — 발행은 하되 **조용히 넘기지 않는다**(warn 이 ④ Report 에 뜬다).
  warn "warn: PR #$pr 에서 '검증자 리뷰:' 코멘트를 못 찾았다 — 새 이슈가 검증자 스펙 없이 나간다(사람이 PR 코멘트를 확인하라)"
  findings="(PR #$pr 에서 \`검증자 리뷰:\` 코멘트를 못 찾았다 — 그 PR 의 코멘트를 직접 읽어라.)"
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
  # gh 는 URL 을 **마지막 줄**에 낸다(앞줄에 경고가 섞일 수 있다). 줄을 안 좁히면 경고에 섞인
  # 숫자까지 물어 번호가 두 줄이 되고, 그러면 아래 `_int` 가 die 3 으로 떨어져 **이미 만들어진
  # 이슈가 고아**가 된다 — 마지막 줄의 `issues/<N>` 만 본다.
  new=$(printf '%s\n' "$url" | grep -oE 'issues/[0-9]+' | tail -1 | grep -oE '[0-9]+')
  _int "$new" || die 3 "새 이슈 번호를 못 읽었다(출력: $url) — 아무것도 닫지 않았다"

  # 확인 — 발행이 실제로 **열려 있고 레인에 든** 이슈를 만들었나. 통과해야 닫기로 간다.
  ensure_lane "$new" 3

  # 멱등 앵커 — 이 마커 뒤로는 다시 불려도 발행하지 않는다.
  # 실패해도 **멈추지 않는다**: 여기서 멈추면 다음 틱이 마커를 못 보고 같은 이슈를 또 내
  # (틱마다 중복 `agent-ready` 이슈가 증식) 고치려던 것보다 나빠진다. 이어서 PR·원 이슈를
  # 닫으면 그 PR 은 `is:open` 큐에서 빠져 재진입 자체가 없어진다 — 그게 더 좁은 창이다.
  if ! gh issue comment "$issue" --repo "$repo" --body "재발행: #$issue → #$new (attempt 상한 $LIMIT)
<!-- reissued: #$new -->
$MARKER_WORKER" >/dev/null 2>&1; then
    warn "warn: 재발행 마커 코멘트 실패 (#$issue → #$new) — 닫기는 계속한다. 뒤 단계가 실패하면 다음 틱이 **중복 발행**할 수 있으니 사람이 #$new 를 확인하라"
  fi

  if [ "$relabel" = 1 ]; then
    for a in "${label_args[@]}"; do
      if [ "$a" = "--label" ] || [ -z "$a" ]; then continue; fi
      gh issue edit "$new" --repo "$repo" --add-label "$a" >/dev/null 2>&1 \
        || warn "warn: 새 이슈 #$new 에 라벨 '$a' 부착 실패"
    done
    ensure_lane "$new" 4
  fi
else
  # **멱등 재진입도 같은 확인을 지난다** — 마커만 믿고 닫기로 건너뛰면, 앞 회차가 라벨
  # 부착에서 멈춘 그 이슈(레인 밖)를 그대로 둔 채 원 이슈를 닫아 조용한 유실이 된다.
  warn "note: 이슈 #$issue 은 이미 #$new 로 재발행돼 있다 — 발행을 건너뛰고 확인부터 이어간다"
  ensure_lane "$new" 4
fi

# blocked-by 이전 — **원 이슈를 닫기 전**에.
blocked=$(gh issue list --repo "$repo" --state open --label "blocked-by:$issue" --json number --limit 100 2>/dev/null) || blocked="__FAIL__"
[ "$blocked" != "__FAIL__" ] || die 4 "blocked-by:$issue 조회 실패 — 원 이슈를 닫지 않는다(닫힌 블로커는 해제로 읽힌다)"
# 상한(100)에 닿았으면 **잘렸을 수 있다** — 잘린 나머지는 닫힌 블로커를 가리킨 채 남으므로
# 조용히 넘기지 않고 알린다(이 레포의 목록 조회가 상한을 warn 으로 드러내는 규약과 같다).
n_blocked=$(printf '%s' "$blocked" | jq -r 'length') \
  || die 4 "blocked-by:$issue 목록 파싱 실패 — 원 이슈를 닫지 않는다(빈 목록과 구분한다)"
[ "$n_blocked" != "100" ] || warn "warn: blocked-by:$issue 가 조회 상한 100 에 닿았다 — 나머지는 손으로 옮겨야 한다 (#$issue → #$new)"
blocked_nums=$(printf '%s' "$blocked" | jq -r '.[]?.number // empty') \
  || die 4 "blocked-by:$issue 번호 파싱 실패 — 원 이슈를 닫지 않는다"
for b in $blocked_nums; do
  "$SCRIPT_DIR/block-issue.sh" "$repo" "$b" "$new" >/dev/null 2>&1 \
    || die 4 "#$b 의 blocked-by 를 #$new 로 옮기지 못했다 — 원 이슈를 닫지 않는다"
  gh issue edit "$b" --repo "$repo" --remove-label "blocked-by:$issue" >/dev/null 2>&1 \
    || die 4 "#$b 에서 blocked-by:$issue 제거 실패 — 원 이슈를 닫지 않는다"
done

# 블로커는 **라벨 ∪ 본문 줄**이다(규칙의 SSOT 는 `eligible-issues.sh`). 본문 줄로 건 이슈는
# 위 라벨 조회에 안 잡히는데, 원 이슈가 닫히면 그 줄은 "해제" 로 읽혀 하위가 조기에 풀린다.
# 남의 본문을 고치지는 않고(사람의 글이다) **새 번호 라벨을 얹어** 막힘을 잇고 warn 한다.
body_blocked=$(gh issue list --repo "$repo" --state open --search "\"Blocked by #$issue\" in:body" \
  --json number,body --limit 100 2>/dev/null) || body_blocked="__FAIL__"
[ "$body_blocked" != "__FAIL__" ] \
  || die 4 "본문 'Blocked by #$issue' 조회 실패 — 원 이슈를 닫지 않는다(닫힌 블로커는 해제로 읽힌다)"
body_blocked_nums=$(printf '%s' "$body_blocked" | jq -r --arg n "$issue" '
  .[]? | select((.body // "") | test("(^|\n)[ \t]*[Bb]locked[- ][Bb]y[ \t]+#" + $n + "([^0-9]|$)")) | .number') \
  || die 4 "본문 블로커 파싱 실패 — 원 이슈를 닫지 않는다"
for b in $body_blocked_nums; do
  case " $blocked_nums " in *" $b "*) continue ;; esac   # 라벨로 이미 옮긴 건 건너뛴다
  "$SCRIPT_DIR/block-issue.sh" "$repo" "$b" "$new" >/dev/null 2>&1 \
    || die 4 "#$b(본문 블로커)에 blocked-by:$new 를 붙이지 못했다 — 원 이슈를 닫지 않는다"
  warn "warn: #$b 의 본문 'Blocked by #$issue' 줄은 낡았다 — blocked-by:$new 라벨로 막힘을 이었다(본문은 사람이 고쳐라)"
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
