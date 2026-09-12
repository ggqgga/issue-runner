#!/usr/bin/env bash
# resume-sweep.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 release-labels.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것:
#   ① 창 전(RESUME_AFTER_MIN 미만)엔 아무것도 쓰지 않는다 — waiting 만.
#   ② 재개 횟수 = **마커 코멘트 개수**(0·1·2). 본문은 읽지도 쓰지도 않는다
#      (`--body-file` 이 남의 글을 덮어쓰던 경로를 없앤 것 — 로그에 나타나면 회귀).
#   ③ 순서 계약: **마커 코멘트 먼저 → 라벨**. 코멘트가 실패하면 라벨은 안 건드린다
#      (카운터 없는 재개 = 상한이 안 걸리는 무한 재시도).
#   ④ 정지 라벨은 이슈와 **PR 양쪽**에 미러돼 있다 — 재개·승격이 PR 도 함께 되돌린다.
#      안 그러면 PR 이 영구 needs-human 으로 남고 뒤 전이가 그 라벨을 안 뗀다.
#   ⑤ 두 쿼리(AND 재개 대상 · 사유 점검)가 각각 상한에 닿으면 알린다.
#   ⑥ 사유 라벨 없는 needs-human 은 손대지 않고 warn 만 · 사람 몫 hold 동존도 재개 금지.
#      단 배포 대기 라벨(deploy-wait·full-cycle)이면 **정상 상태**라 warn 이 아니라 note (#190).
#   ⑦ 조회 실패는 "없음" 으로 위장되지 않는다(exit 2) · 상수 오타는 쓰기 전에 exit 64.
#   ⑧ 사람 조작 경합은 **쓰기 전** 재조회로 잡는다(사후 readback 으론 원리적으로 불가).
#   ⑨ (#265) 정지 미러 정리 — 이슈엔 정지 라벨이 없고 짝이 되는 **열린** PR 에만 남은 사본을
#      뗀다. 격자(이슈 정지 有/無 × PR 정지 有/無)로 편집 유무를 각 칸에서 단언하고,
#      이슈에 정지가 **남아 있으면** 절대 떼지 않는 것(사람 게이트 보존)을 함께 못 박는다.
#      짝은 head `agent/issue-*` + Closes 링크로 증명된 것만 — 사람 세션 PR·`Refs` 전용 PR
#      을 벗기지 않는다. 정지 판별은 열거가 아니라 `hold:` **접두**(#242 게이트와 같은 눈).
#      조회·편집 실패는 라벨을 안 떼고 warn / 쓰기 뒤 실패·경합은 warn_after_edit 으로 갈린다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
skip=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    pass=$((pass + 1))
  elif [ "$cond" = "skip" ]; then
    # 부재를 실패로 접지 않는다(#193 closeout 재재심 BLOCKER) — 조용한 no 대신 눈에 보이는
    # skip 줄을 남긴다. pass/fail 어느 쪽에도 안 셈해 "빠졌다"는 사실이 합계에서 안 숨는다.
    skip=$((skip + 1))
    echo "  ⇢ skip: $name"
  else
    fail=$((fail + 1))
    echo "  ✗ $name"
  fi
}

ts() {  # ts <분 전> → RFC3339 UTC
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── SUT 사본 + gh-login 스텁 ────────────────────────────────────────────────
sut_dir="$tmp/scripts"
mkdir -p "$sut_dir" "$tmp/bin" "$tmp/work/.loop"
cp "$DIR/resume-sweep.sh" "$sut_dir/resume-sweep.sh"
cat > "$sut_dir/gh-login.sh" <<'STUB'
#!/bin/sh
echo tester
STUB
chmod +x "$sut_dir"/*.sh
echo 'owner/repo' > "$tmp/work/.loop/repos"
mkdir -p "$tmp/noscope"   # .loop/repos 가 없는 세션 = 계정 전체 탐색 경로

# ── gh 스텁 — 라벨·코멘트·PR 상태를 파일로 들고 편집을 실제로 반영한다 ─────
# (반영하지 않으면 readback·마커 카운트 단언이 스텁의 고정 응답을 확인하는 공회전이 된다.)
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"

labels_json() {  # labels_json <콤마목록> — {"labels":[…]}
  jq -n --arg l "$1" '{labels: ($l|split(",")|map(select(length>0)|{name:.}))}'
}
edit_labels() {  # edit_labels <상태파일> <인자…>
  local f="$1"; shift
  local cur; cur=$(cat "$f")
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove-label) cur=$(printf '%s' ",$cur," | sed "s/,$2,/,/g" | sed 's/^,//; s/,$//'); shift 2 ;;
      --add-label)    case ",$cur," in *",$2,"*) ;; *) cur="${cur:+$cur,}$2" ;; esac; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s' "$cur" > "$f"
}

case "${1:-} ${2:-}" in
  "api repos/"*)
    # (#265 ⑷) 라벨 이벤트 이력 — "사람이 뗐다" 의 양성 증거 관문이 읽는다.
    # 기본값은 **정상 해제 이력**(이슈의 unlabeled 가 PR 의 labeled 보다 늦다) — 그래야
    # 기존 격자 칸들이 이 관문이 아니라 각자의 이유로 갈린다. 픽스처에 줄이 있으면 그것만
    # 쓴다(부분 실패·옛 에피소드 재현). 줄 형식: `<번호> <ev>|<라벨>|<시각>;<ev>|…`
    enum=${2#*/issues/}; enum=${enum%%/*}
    case ",${STUB_MIRROR_EVENTS_FAIL:-}," in *",$enum,"*) echo "gh: events boom" >&2; exit 1 ;; esac
    eline=$(grep "^$enum " "${STUB_MIRROR_EVENTS:-/dev/null}" 2>/dev/null || true)
    if [ -n "$eline" ]; then
      erest=${eline#* }
      [ "$erest" = "__NONE__" ] || printf '%s\n' "$erest" | tr ';' '\n' | tr '|' '\t'
      exit 0
    fi
    if [ -f "${STUB_MIRROR_PRS:-/dev/null}" ] \
       && jq -e --arg n "$enum" 'any(.number == ($n|tonumber))' "$STUB_MIRROR_PRS" >/dev/null 2>&1; then
      # PR 쪽 기본 — 지금 달고 있는 정지 라벨을 T0 에 붙였다
      jq -r --arg n "$enum" '.[] | select(.number == ($n|tonumber)) | .labels[].name
             | select(. == "needs-human" or startswith("hold:"))
             | "labeled\t" + . + "\t2026-01-01T00:00:00Z"' "$STUB_MIRROR_PRS"
    else
      # 이슈 쪽 기본 — 알려진 정지 라벨을 T1(T0 보다 늦게) 뗐다
      for l in needs-human hold:policy hold:conflict hold:ladder hold:manual; do
        printf 'unlabeled\t%s\t2026-01-02T00:00:00Z\n' "$l"
      done
    fi
    exit 0 ;;
  "issue list")
    case "$*" in
      *hold:ladder*)
        [ -z "${STUB_LADDER_FAIL:-}" ] || { echo "gh: ladder list boom" >&2; exit 1; }
        cat "$STUB_LADDER" ;;
      *hold:policy*) if [ -s "${STUB_POLICY:-/dev/null}" ]; then cat "$STUB_POLICY"; else echo '[]'; fi ;;
      *)
        [ -z "${STUB_HUMAN_FAIL:-}" ] || { echo "gh: human list boom" >&2; exit 1; }
        cat "$STUB_HUMAN" ;;
    esac
    exit 0 ;;
  "issue view")
    # (#265) 정지 미러 정리 갈래는 **다른 이슈 번호**를 읽는다 — 미러 픽스처에 등록된
    # 번호면 그 라벨을 돌려준다(기존 42번 픽스처와 번호로 갈린다). `__FAIL__` 은 조회 실패.
    if [ -f "${STUB_MIRROR_ISSUES:-/dev/null}" ]; then
      mline=$(grep "^${3:-} " "$STUB_MIRROR_ISSUES" || true)
      if [ -n "$mline" ]; then
        # (#397) 재시도 마커 카운트는 **이 이슈의 코멘트**를 읽는다 — 라벨 조회와 인자로 갈린다.
        case "$*" in
          *comments*)
            if [ -f "$STUB_MIRROR_COMMENTS.${3:-}" ]; then
              jq -n --slurpfile c "$STUB_MIRROR_COMMENTS.${3:-}" '{comments: $c[0]}'
            else
              echo '{"comments":[]}'
            fi
            exit 0 ;;
        esac
        mrest=${mline#* }
        mstate=${mrest%% *}
        mlabels=${mrest#* }
        # 경합 픽스처 — PR 편집이 **이미 일어난 뒤**의 조회에만 다른 답을 준다. 편집 전
        # 재조회로는 못 닫는 창(transition.sh 가 PR 을 먼저 고친다)을 그대로 재현한다.
        if [ -n "${STUB_MIRROR_RACE:-}" ] && [ -f "$STUB_MIRROR_EDITED" ]; then
          [ "$STUB_MIRROR_RACE" = "__FAIL__" ] && exit 1
          mlabels="$STUB_MIRROR_RACE"
        fi
        [ "$mstate" = "__FAIL__" ] && exit 1
        [ "$mlabels" = "__NONE__" ] && mlabels=""
        jq -n --arg l "$mlabels" --arg s "$mstate" \
          '{labels: ($l|split(",")|map(select(length>0)|{name:.})), state: $s}'
        exit 0
      fi
    fi
    case "$*" in
      *comments*)
        [ -z "${STUB_COMMENTS_FAIL:-}" ] || exit 1
        jq -n --slurpfile c "$STUB_COMMENTS" '{comments: $c[0]}'; exit 0 ;;
      *labels,updatedAt*)
        v="${STUB_STATE_LABELS:-}"
        [ "$v" = "__FAIL__" ] && exit 1
        [ "$v" = "__EMPTY__" ] && v=""
        [ -n "${STUB_STATE_LABELS:-}" ] || v=$(cat "$STUB_LABELS")
        jq -n --arg l "$v" --arg u "$(cat "${STUB_UPDATED_LIVE:-$STUB_UPDATED}")" \
          '{labels: ($l|split(",")|map(select(length>0)|{name:.})), updatedAt: $u}'
        exit 0 ;;
      *)
        v="${STUB_READBACK_LABELS:-}"
        [ "$v" = "__FAIL__" ] && exit 1
        [ "$v" = "__EMPTY__" ] && v=""
        [ -n "${STUB_READBACK_LABELS:-}" ] || v=$(cat "$STUB_LABELS")
        labels_json "$v"; exit 0 ;;
    esac ;;
  "issue edit")
    [ -z "${STUB_LABEL_EDIT_FAIL:-}" ] || exit 1
    edit_labels "$STUB_LABELS" "$@"
    exit 0 ;;
  "issue comment")
    [ -z "${STUB_COMMENT_FAIL:-}" ] || exit 1
    # 실제로 코멘트가 쌓여야 마커 카운트가 다음 조회에 반영된다.
    cnum="${3:-}"
    body=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && { body="$2"; break; }
      shift
    done
    # (#397) 미러 픽스처의 이슈면 **그 이슈의** 코멘트 파일에 쌓는다 — 재개(ladder) 픽스처와
    # 섞이면 두 회차가 서로의 마커를 센다.
    if [ -f "${STUB_MIRROR_ISSUES:-/dev/null}" ] && grep -q "^$cnum " "$STUB_MIRROR_ISSUES"; then
      [ -f "$STUB_MIRROR_COMMENTS.$cnum" ] || echo '[]' > "$STUB_MIRROR_COMMENTS.$cnum"
      jq --arg b "$body" '. + [{body: $b}]' "$STUB_MIRROR_COMMENTS.$cnum" > "$STUB_MIRROR_COMMENTS.$cnum.tmp" \
        && mv "$STUB_MIRROR_COMMENTS.$cnum.tmp" "$STUB_MIRROR_COMMENTS.$cnum"
      exit 0
    fi
    jq --arg b "$body" '. + [{body: $b}]' "$STUB_COMMENTS" > "$STUB_COMMENTS.tmp" \
      && mv "$STUB_COMMENTS.tmp" "$STUB_COMMENTS"
    exit 0 ;;
  "pr list")
    # (#265) 정지 미러 정리 갈래의 목록 조회 — 재개 미러(`--head agent/issue-N`)와
    # **인자로** 갈린다(이쪽만 closingIssuesReferences 를 요구한다).
    case "$*" in
      *closingIssuesReferences*)
        [ -z "${STUB_MIRROR_LIST_FAIL:-}" ] || { echo "gh: mirror pr list boom" >&2; exit 1; }
        cat "$STUB_MIRROR_PRS"; exit 0 ;;
    esac
    [ -z "${STUB_PR_FAIL:-}" ] || { echo "gh: pr list boom" >&2; exit 1; }
    prnum=$(cat "$STUB_PR_NUM")
    if [ -z "$prnum" ]; then echo '[]'; exit 0; fi
    jq -n --argjson n "$prnum" --arg l "$(cat "$STUB_PR_LABELS")" \
      '[{number: $n, labels: ($l|split(",")|map(select(length>0)|{name:.}))}]'
    exit 0 ;;
  "pr edit")
    # 미러 픽스처에 든 PR 이면 그 배열 안의 라벨을 실제로 갱신한다 — 안 그러면 readback
    # 단언이 스텁의 고정 응답을 확인하는 공회전이 된다(이 스위트의 기존 규율).
    if [ -f "${STUB_MIRROR_PRS:-/dev/null}" ] \
       && jq -e --arg n "${3:-}" 'any(.number == ($n|tonumber))' "$STUB_MIRROR_PRS" >/dev/null 2>&1; then
      [ -z "${STUB_MIRROR_EDIT_FAIL:-}" ] || exit 1
      : > "$STUB_MIRROR_EDITED"
      jq -r --arg n "${3:-}" '.[] | select(.number == ($n|tonumber)) | [.labels[].name] | join(",")' \
        "$STUB_MIRROR_PRS" > "$STUB_MIRROR_ONE"
      edit_labels "$STUB_MIRROR_ONE" "$@"
      jq --arg n "${3:-}" --arg l "$(cat "$STUB_MIRROR_ONE")" \
        'map(if .number == ($n|tonumber)
             then .labels = ($l|split(",")|map(select(length>0)|{name:.})) else . end)' \
        "$STUB_MIRROR_PRS" > "$STUB_MIRROR_PRS.tmp" && mv "$STUB_MIRROR_PRS.tmp" "$STUB_MIRROR_PRS"
      exit 0
    fi
    [ -z "${STUB_PR_EDIT_FAIL:-}" ] || exit 1
    edit_labels "$STUB_PR_LABELS" "$@"
    exit 0 ;;
  "pr view")
    # (#395) ③-b PR 단독 재심이 읽는 **PR 코멘트**. 라벨 조회(readback)와 인자로 갈린다.
    case "$*" in
      *comments*)
        [ -z "${STUB_PR_COMMENTS_FAIL:-}" ] || exit 1
        jq -n --slurpfile c "$STUB_PR_COMMENTS" '{comments: $c[0]}'; exit 0 ;;
    esac
    if [ -f "${STUB_MIRROR_PRS:-/dev/null}" ] \
       && jq -e --arg n "${3:-}" 'any(.number == ($n|tonumber))' "$STUB_MIRROR_PRS" >/dev/null 2>&1; then
      v="${STUB_MIRROR_READBACK:-}"
      [ "$v" = "__FAIL__" ] && exit 1
      if [ -z "$v" ]; then
        v=$(jq -r --arg n "${3:-}" '.[] | select(.number == ($n|tonumber)) | [.labels[].name] | join(",")' \
          "$STUB_MIRROR_PRS")
      fi
      labels_json "$v"; exit 0
    fi
    labels_json "$(cat "$STUB_PR_LABELS")"; exit 0 ;;
  "search issues")
    [ -z "${STUB_SEARCH_FAIL:-}" ] || { echo "gh: search boom" >&2; exit 1; }
    # 실측 재현(#236): gh search CLI 는 **질의 문자열 안의** `is:` 한정자를 오파싱해
    # rc=0 · 빈손을 돌려준다 — 실패가 아니라 "0건" 으로 보이는 것이 이 버그의 해악이다.
    # (2026-09-12 gh 2.95.0, --owner ggqgga: `label:needs-human` 단독 → 3개 레포 /
    #  `label:needs-human is:open` · `… is:issue` · 둘 다 → 각각 0건 / `--state open`
    #  플래그 → 정상.) 스텁이 이 오파싱을 흉내 내야 옛 질의로 되돌렸을 때 빨개진다.
    # 검사 대상은 **질의 인자 하나**($3)다 — 전 인자를 훑으면 나중에 jq 표현식이나
    # 필드명에 `is:` 가 섞였을 때 코드가 멀쩡한데 스텁이 빈손을 돌려 가짜 실패가 난다.
    case "${3:-}" in *"is:"*) exit 0 ;; esac
    # (#331 반송) 라벨별 갈래 — `$STUB_SEARCH.<라벨>` 이 있으면 **그 라벨 질의만** 그 파일로
    # 답한다(기본 픽스처는 라벨과 무관하게 같은 목록). 탐색 집합에 어떤 라벨이 드는지를
    # 실측하려면 "그 라벨을 물었을 때만 나오는 레포" 를 만들 수 있어야 한다.
    if [ -f "$STUB_SEARCH.${3#label:}" ]; then cat "$STUB_SEARCH.${3#label:}"; exit 0; fi
    cat "$STUB_SEARCH"; exit 0 ;;
  "search prs")
    # (#331) 계정 전체 모드의 **PR 축** — ④ 정지 미러가 겨누는 상태(이슈는 깨끗하고 PR 에만
    # 정지 라벨)를 담은 레포는 이슈 축 질의에 **절대** 안 나온다. 실패는 이슈 축과 **따로**
    # 낸다(한쪽만 죽는 픽스처를 만들 수 있어야 "각각 구분한다" 가 실측된다).
    [ -z "${STUB_SEARCH_PRS_FAIL:-}" ] || { echo "gh: search prs boom" >&2; exit 1; }
    case "${3:-}" in *"is:"*) exit 0 ;; esac
    if [ -f "$STUB_SEARCH_PRS.${3#label:}" ]; then cat "$STUB_SEARCH_PRS.${3#label:}"; exit 0; fi
    cat "$STUB_SEARCH_PRS"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp/bin/gh"

# ── jq 스텁 — 기본은 진짜 jq 로 그대로 넘긴다 ──────────────────────────────
# 쓰는 곳은 하나다: (#229) 재조회 쪽 배포 대기 판정이 **실패**했을 때 fail-closed 인지.
# 그 실패는 픽스처(데이터)로는 못 만든다 — 어댑터가 라벨 콤마목록에서 row-json 을 **스스로**
# 만들어 넣기 때문에 어떤 라벨이 와도 JSON 은 항상 정상이다. 즉 유일한 도달 경로가 도구
# 실패라, 인자에 표식(`deploy-wait-adapter`)이 있는 **그 한 호출만** 실패시킨다.
REAL_JQ=$(command -v jq)
export REAL_JQ
cat > "$tmp/bin/jq" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_JQ_FAIL_PAT:-}" ]; then
  case "$*" in *"$STUB_JQ_FAIL_PAT"*) echo "jq: stubbed failure" >&2; exit 5 ;; esac
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$tmp/bin/jq"

# ── 픽스처 · 실행 헬퍼 ─────────────────────────────────────────────────────
# setup <이슈라벨csv> <분전> <마커코멘트수>
#   ladder 쿼리(라벨 AND)는 서버가 거르므로, hold:ladder 가 없으면 빈 배열을 돌려준다.
setup() {
  local labels="$1" mins="$2" markers="$3" i
  printf '%s' "$labels" > "$tmp/labels"
  printf '%s' "$(ts "$mins")" > "$tmp/updated"
  jq -n --argjson n 42 --arg l "$labels" --arg u "$(ts "$mins")" \
    '[{number:$n, labels: ($l|split(",")|map(select(length>0)|{name:.})), updatedAt:$u}]' \
    > "$tmp/human.json"
  cp "$tmp/human.json" "$tmp/row.json"
  case ",$labels," in
    *,hold:ladder,*) cp "$tmp/row.json" "$tmp/ladder.json" ;;
    *) echo '[]' > "$tmp/ladder.json" ;;
  esac
  # ② 는 `--label needs-human` 으로 거는 서버 쿼리다 — 라벨이 없으면 행이 안 온다.
  # (#244 로 ① 이 hold:ladder 단독 쿼리가 된 뒤엔 이 구분이 실제로 갈린다.)
  case ",$labels," in
    *,needs-human,*) : ;;
    *) echo '[]' > "$tmp/human.json" ;;
  esac
  case ",$labels," in
    *,hold:policy,*) cp "$tmp/row.json" "$tmp/policy.json" ;;
    *) echo '[]' > "$tmp/policy.json" ;;
  esac
  echo '[]' > "$tmp/comments.json"
  i=0
  while [ "$i" -lt "$markers" ]; do
    i=$((i + 1))
    jq --arg b "재개 $i/2: 사다리 재시도 — <!-- ladder-resume: $i --><!-- bodat:worker -->" \
      '. + [{body: $b}]' "$tmp/comments.json" > "$tmp/comments.tmp" && mv "$tmp/comments.tmp" "$tmp/comments.json"
  done
  printf '' > "$tmp/pr.num"        # 기본: 연결 PR 없음
  printf '' > "$tmp/pr.labels"
  printf 'owner/repo\n' > "$tmp/search"
  : > "$tmp/search.prs"          # (#331) 기본: PR 축 탐색 0건 — 합집합의 이슈 축만 남는다
  rm -f "$tmp"/search.needs-human "$tmp"/search.prs.needs-human "$tmp"/search.hold:* "$tmp"/search.prs.hold:*
  echo '[]' > "$tmp/mirror.prs.json"   # (#265) 기본: 정지 미러 정리 대상 없음
  : > "$tmp/mirror.issues"
  : > "$tmp/mirror.events"            # (#265 ⑷) 기본: 이력 픽스처 없음(스텁이 정상 해제로 답한다)
  echo '[]' > "$tmp/pr.comments.json"  # (#395) 기본: PR 코멘트 0건
  rm -f "$tmp"/mirror.comments.*       # (#397) 기본: 재시도 마커 0개
  MRL=3
  STUB_PR_COMMENTS_FAIL=""
  : > "$tmp/gh.log"
  # unset 하면 export 속성이 날아가 이후 대입이 스텁에 안 전달된다 — 빈 값으로 되돌린다.
  STUB_LADDER_FAIL=""; STUB_HUMAN_FAIL=""; STUB_LABEL_EDIT_FAIL=""; STUB_COMMENT_FAIL=""
  STUB_COMMENTS_FAIL=""; STUB_SEARCH_FAIL=""; STUB_SEARCH_PRS_FAIL=""; STUB_PR_FAIL=""; STUB_PR_EDIT_FAIL=""
  STUB_STATE_LABELS=""; STUB_READBACK_LABELS=""; STUB_UPDATED_LIVE=""; STUB_JQ_FAIL_PAT=""
  STUB_MIRROR_LIST_FAIL=""; STUB_MIRROR_EDIT_FAIL=""; STUB_MIRROR_READBACK=""
  STUB_MIRROR_RACE=""; rm -f "$tmp/mirror.edited"; STUB_MIRROR_EVENTS_FAIL=""
  WORKDIR="$tmp/work"; RA=120; RL=2; LL=200
}

with_pr() {  # with_pr <PR번호> <PR라벨csv>
  printf '%s' "$1" > "$tmp/pr.num"
  printf '%s' "$2" > "$tmp/pr.labels"
}

# run — 이벤트는 $out, 종료코드는 $RC 로. **명령치환으로 부르지 않는다**
# (서브셸이면 RC 가 밖으로 못 나와 exit 2·64 단언이 공회전한다).
run() { run_sut "$sut_dir/resume-sweep.sh"; }
# run_sut <스크립트경로> — run 과 같은 환경으로 **다른 사본**을 돌린다. 뮤테이션 방증
# (#331)이 쓴다: 합집합을 뺀 사본이 같은 픽스처에서 실제로 빨개지는지 스위트 안에서 본다.
run_sut() {
  (cd "$WORKDIR" && PATH="$tmp/bin:$PATH" \
    RESUME_AFTER_MIN="${RA:-120}" LADDER_RESUME_LIMIT="${RL:-2}" \
    RESUME_LIST_LIMIT="${LL:-200}" MIRROR_RETRY_LIMIT="${MRL:-3}" \
    bash "$1") >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}
export STUB_LOG="$tmp/gh.log" STUB_LABELS="$tmp/labels" STUB_UPDATED="$tmp/updated"
export STUB_LADDER="$tmp/ladder.json" STUB_HUMAN="$tmp/human.json" STUB_POLICY="$tmp/policy.json"
export STUB_COMMENTS="$tmp/comments.json" STUB_SEARCH="$tmp/search"
export STUB_SEARCH_PRS="$tmp/search.prs" STUB_SEARCH_PRS_FAIL=""
export STUB_PR_NUM="$tmp/pr.num" STUB_PR_LABELS="$tmp/pr.labels"
export STUB_LADDER_FAIL="" STUB_HUMAN_FAIL="" STUB_LABEL_EDIT_FAIL="" STUB_COMMENT_FAIL=""
export STUB_COMMENTS_FAIL="" STUB_SEARCH_FAIL="" STUB_PR_FAIL="" STUB_PR_EDIT_FAIL=""
export STUB_STATE_LABELS="" STUB_READBACK_LABELS="" STUB_UPDATED_LIVE="" STUB_JQ_FAIL_PAT=""
export STUB_MIRROR_PRS="$tmp/mirror.prs.json" STUB_MIRROR_ISSUES="$tmp/mirror.issues"
export STUB_MIRROR_ONE="$tmp/mirror.one"
export STUB_MIRROR_LIST_FAIL="" STUB_MIRROR_EDIT_FAIL="" STUB_MIRROR_READBACK=""
export STUB_MIRROR_RACE="" STUB_MIRROR_EDITED="$tmp/mirror.edited"
export STUB_MIRROR_EVENTS="$tmp/mirror.events" STUB_MIRROR_EVENTS_FAIL=""
export STUB_PR_COMMENTS="$tmp/pr.comments.json" STUB_PR_COMMENTS_FAIL=""
export STUB_MIRROR_COMMENTS="$tmp/mirror.comments"
WORKDIR="$tmp/work"
RC=0
out=""

ev()      { printf '%s' "$out" | jq -r 'select(.event=="'"$1"'")' 2>/dev/null; }
has_ev()  { if [ -n "$(ev "$1")" ]; then echo ok; else echo no; fi; }
no_ev()   { if [ -z "$(ev "$1")" ]; then echo ok; else echo no; fi; }
# 패턴은 반드시 `-e` 로 넘기고 파일은 `--` 뒤에 둔다 — `-` 로 시작하는 패턴(`--body-file`)을
# 맨몸으로 주면 grep 이 그것을 옵션으로 먹고 **파일 인자를 패턴으로** 삼아 stdin 을 읽는다.
# 그러면 이 스위트가 stdin 이 EOF 가 아닌 환경(파이프·터미널)에서 조용히 매달린다(실측).
counts()  { grep -c -e "$1" -- "$tmp/gh.log" 2>/dev/null || true; }
none()    { if [ "$(counts "$1")" = 0 ]; then echo ok; else echo no; fi; }
some()    { if [ "$(counts "$1")" != 0 ]; then echo ok; else echo no; fi; }
hasl()    { case ",$(cat "$tmp/labels")," in *",$1,"*) echo ok ;; *) echo no ;; esac; }
lacksl()  { case ",$(cat "$tmp/labels")," in *",$1,"*) echo no ;; *) echo ok ;; esac; }
haspl()   { case ",$(cat "$tmp/pr.labels")," in *",$1,"*) echo ok ;; *) echo no ;; esac; }
lackspl() { case ",$(cat "$tmp/pr.labels")," in *",$1,"*) echo no ;; *) echo ok ;; esac; }
saysl()   { if printf '%s' "$out" | grep -q "$1"; then echo ok; else echo no; fi; }
markers() { jq '[.[] | select(.body | test("ladder-resume"))] | length' "$tmp/comments.json"; }

# ── ① 창 전 — waiting 만, 무쓰기 ───────────────────────────────────────────
setup "hold:ladder,agent-ready" 10 0
run
check "창 전: waiting 이벤트"            "$(has_ev waiting)"
check "창 전: minutes 가 실린다"         "$(printf '%s' "$out" | jq -e '.minutes >= 9 and .minutes <= 11' >/dev/null 2>&1 && echo ok || echo no)"
check "창 전: resumed 없음"              "$(no_ev resumed)"
check "창 전: 편집 0회"                  "$(none 'issue edit')"
check "창 전: 코멘트 0회"                "$(none 'issue comment')"
check "창 전: 코멘트 조회조차 안 한다"    "$(none 'json comments')"

# ── ② 마커 0개 → 1번째 재개 ────────────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
run
check "마커 0: resumed"                  "$(has_ev resumed)"
check "마커 0: attempt=1"                "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 1' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 0: 마커 코멘트가 쌓인다"      "$([ "$(markers)" = 1 ] && echo ok || echo no)"
check "마커 0: 코멘트 본문에 마커"        "$(grep -q 'issue comment .*<!-- ladder-resume: 1 -->' "$tmp/gh.log" && echo ok || echo no)"
check "마커 0: hold:ladder 해제"          "$(lacksl hold:ladder)"
check "마커 0: agent-ready 유지"          "$(hasl agent-ready)"
check "본문은 건드리지 않는다(--body-file 부재)" "$(none '--body-file')"
check "기본 상한은 200 (env 미지정)"        "$(grep -q -- '--limit 200' "$tmp/gh.log" && echo ok || echo no)"
check "비공허 실증: hold:ladder 단독 쿼리로 목록을 뜬다(#244)" "$(grep -q 'issue list --repo owner/repo .*--label hold:ladder' "$tmp/gh.log" && echo ok || echo no)"
check "① 쿼리에 needs-human 이 없다(#244)" "$(grep -q 'issue list .*--label needs-human --label hold:ladder' "$tmp/gh.log" && echo no || echo ok)"

# ── ③ 마커 1개 → 2번째 재개 ────────────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 1
run
check "마커 1: attempt=2"                "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 1: 마커가 2개로"             "$([ "$(markers)" = 2 ] && echo ok || echo no)"

# ── ④ 마커 2개 → 상한 초과 승격 (LIMIT=2) ─────────────────────────────────
setup "hold:ladder,agent-ready" 200 2
run
check "마커 2: escalated"                "$(has_ev escalated)"
check "마커 2: resumed 아님"             "$(no_ev resumed)"
check "마커 2: attempt=2 · limit=2"      "$(printf '%s' "$out" | jq -e 'select(.event=="escalated") | .attempt == 2 and .limit == 2' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 2: hold:policy 부착"         "$(hasl hold:policy)"
check "마커 2: hold:ladder 해제"         "$(lacksl hold:ladder)"
check "마커 2: 승격 코멘트엔 마커 없음"   "$([ "$(markers)" = 2 ] && echo ok || echo no)"
check "마커 2: 상한 코멘트"              "$(grep -q 'issue comment .*사다리 재개 상한(2) 초과' "$tmp/gh.log" && echo ok || echo no)"

# ── ⑤ [P1] PR 미러 해제 — 재개 ────────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
with_pr 77 "hold:ladder,flow:verify"
run
check "PR 재개: resumed"                 "$(has_ev resumed)"
check "PR 재개: PR hold:ladder 해제"     "$(lackspl hold:ladder)"
check "PR 재개: PR flow:verify 유지"     "$(haspl flow:verify)"
check "PR 재개: pr edit 을 실제로 부른다" "$(some 'pr edit 77')"

# ── ⑥ [P1] PR 미러 승격 ───────────────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 2
with_pr 77 "hold:ladder"
run
check "PR 승격: escalated"               "$(has_ev escalated)"
check "PR 승격: PR hold:policy 부착"     "$(haspl hold:policy)"
check "PR 승격: PR hold:ladder 해제"     "$(lackspl hold:ladder)"

# ── ⑦ 연결 PR 없음 → 이슈만 (정상) ────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
run
check "PR 없음: resumed"                 "$(has_ev resumed)"
check "PR 없음: pr edit 0회"             "$(none 'pr edit')"
check "PR 없음: warn 없음"               "$(no_ev warn)"
check "PR 없음: after-edit warn 없음"    "$(no_ev warn_after_edit)"

# ── ⑧ 정지 라벨 없는 PR 은 건드리지 않는다 ────────────────────────────────
# (레포에 없는 라벨을 remove 하면 gh 가 편집 전체를 실패시키므로 불필요한 편집은 안 낸다.)
setup "hold:ladder,agent-ready" 200 0
with_pr 77 "flow:verify"
run
check "무관 PR: pr edit 0회"             "$(none 'pr edit')"
check "무관 PR: resumed"                 "$(has_ev resumed)"

# ── ⑨ PR 편집 실패 → warn_after_edit (이슈는 이미 반영됨) ─────────────────
setup "hold:ladder,agent-ready" 200 0
with_pr 77 "hold:ladder"
STUB_PR_EDIT_FAIL=1
run
check "PR 편집 실패: warn_after_edit"    "$(has_ev warn_after_edit)"
check "PR 편집 실패: PR 번호가 문구에"    "$(saysl 'PR #77')"
check "PR 편집 실패: 이슈 재개는 그대로"  "$(has_ev resumed)"
check "PR 편집 실패: 이슈 라벨은 반영됨"  "$(lacksl hold:ladder)"

# ── ⑩ [P1] 마커 코멘트 실패 → 라벨 무편집 (순서 계약) ─────────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_COMMENT_FAIL=1
run
check "코멘트 실패: warn"                "$(has_ev warn)"
check "코멘트 실패: resumed 없음"        "$(no_ev resumed)"
check "코멘트 실패: hold:ladder 유지"    "$(hasl hold:ladder)"
check "코멘트 실패: 라벨 편집 0회"       "$(none 'issue edit')"

# ── ⑪ 코멘트 조회 실패 → 상한을 못 지키므로 무편집 ────────────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_COMMENTS_FAIL=1
run
check "코멘트 조회 실패: warn"           "$(has_ev warn)"
check "코멘트 조회 실패: 무편집"         "$(none 'issue edit')"
check "코멘트 조회 실패: 코멘트도 0회"   "$(none 'issue comment')"

# ── ⑫ (#244) 사유 라벨 없는 needs-human = **정상** — note · 무편집 ────────
# 기계 정지가 hold:* 하나만 붙게 된 뒤, 맨 needs-human 은 "사람이 직접 세웠다" 라는
# 정상 상태다. 교정할 불변식 위반이 없으므로 warn 이 아니다(#190 이 세운 정의:
# warn 은 루프가 교정 가능한 불변식 위반일 때만). 관측에서 지우지는 않는다 → note.
setup "needs-human,agent-ready" 200 0
run
check "hold 없음: note"                  "$(has_ev note)"
check "hold 없음: warn 아님"             "$(no_ev warn)"
check "hold 없음: 사람이 세운 정지 문구"  "$(saysl '사람이 직접 세운 정지')"
check "hold 없음: 편집 0회"              "$(none 'issue edit')"
check "hold 없음: resumed 없음"          "$(no_ev resumed)"

# ── ⑫-b (#244) 사람이 세운 needs-human 이 hold:ladder 와 동존 → 자동 재개 금지 ──
# `needs-human` 은 이제 "사람이 직접 세웠다" 하나만 뜻한다. 루프가 그 손을 떼면 안 되므로
# (이 파일 머리 주석의 규율) 창이 지나도 재개하지 않는다 — 그리고 **떼지도 않는다**.
# 이 가드가 없으면 재개가 hold:ladder 만 치우고 needs-human 을 남겨, 게이트(#242)가 계속
# 막는데 재개 횟수만 소진되는 "재개했는데 안 풀리는" 상태가 된다.
setup "needs-human,hold:ladder,agent-ready" 200 0
run
check "needs-human 동존: warn"            "$(has_ev warn)"
check "needs-human 동존: 문구"            "$(saysl '사람이 세운 needs-human 동존')"
check "needs-human 동존: resumed 없음"    "$(no_ev resumed)"
check "needs-human 동존: escalated 없음"  "$(no_ev escalated)"
check "needs-human 동존: 편집 0회"        "$(none 'issue edit')"
check "needs-human 동존: 코멘트 0회"      "$(none 'issue comment')"
check "needs-human 동존: 라벨 그대로"     "$(hasl needs-human)"
# 상한을 소진한 경우도 같은 답 — 승격 갈래로 새지 않는다
setup "needs-human,hold:ladder,agent-ready" 200 2
run
check "needs-human 동존(상한 소진): escalated 없음" "$(no_ev escalated)"
check "needs-human 동존(상한 소진): hold:policy 안 붙는다" "$(lacksl hold:policy)"

# ── ⑫-c (#244) 재개·승격은 `hold:ladder` 만 되돌린다 — PR 미러도 같은 축 ──
# 사람이 PR 에 직접 붙인 needs-human 을 재개가 벗기면 그 손이 조용히 사라진다.
setup "hold:ladder,agent-ready" 200 0
with_pr 77 "needs-human,hold:ladder,flow:verify"
run
check "PR 미러: resumed"                  "$(has_ev resumed)"
check "PR 미러: PR hold:ladder 해제"      "$(lackspl hold:ladder)"
check "PR 미러: PR needs-human 은 안 뗀다" "$(haspl needs-human)"
check "PR 미러: PR flow:verify 유지"      "$(haspl flow:verify)"
check "PR 미러: --remove-label needs-human 을 안 보낸다" \
  "$(grep -q 'pr edit .*--remove-label needs-human' "$tmp/gh.log" && echo no || echo ok)"
check "이슈 편집도 needs-human 을 안 보낸다" \
  "$(grep -q 'issue edit .*--remove-label needs-human' "$tmp/gh.log" && echo no || echo ok)"

# ── ⑬ hold:conflict — 재개 대상도 warn 대상도 아니다 ──────────────────────
setup "hold:conflict,agent-ready" 200 0
run
check "hold:conflict: 무이벤트"          "$([ -z "$out" ] && echo ok || echo no)"
check "hold:conflict: 편집 0회"          "$(none 'issue edit')"

# ── ⑭ 사람 몫 hold 동존 → 자동 재개 안 함 ─────────────────────────────────
setup "hold:ladder,hold:policy,agent-ready" 200 0
run
check "hold 동존: warn"                  "$(has_ev warn)"
check "hold 동존: 문구"                  "$(saysl '사람 몫 hold:\* 동존')"
check "hold 동존: resumed 없음"          "$(no_ev resumed)"
check "hold 동존: 편집 0회"              "$(none 'issue edit')"

# ── ⑮ 사람 조작 경합 — 쓰기 전 재조회가 잡는다 ────────────────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_STATE_LABELS='agent-ready'   # 목록 조회 이후 사람이 hold:ladder 를 뗌
run
check "경합: warn"                       "$(has_ev warn)"
check "경합: 사람 조작 문구"             "$(saysl '사람 조작 경합')"
check "경합: resumed 없음"               "$(no_ev resumed)"
check "경합: 코멘트 0회(마커도 안 남긴다)" "$(none 'issue comment')"
check "경합: 편집 0회"                   "$(none 'issue edit')"

# ── ⑯ 재조회 실패 → 손대지 않는다 ─────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_STATE_LABELS='__FAIL__'
run
check "재조회 실패: warn"                "$(has_ev warn)"
check "재조회 실패: 문구"                "$(saysl '재조회 실패')"
check "재조회 실패: 무편집"              "$(none 'issue edit')"

# ── ⑰ readback 라벨 0개는 성공 · 불일치는 warn_after_edit ─────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_READBACK_LABELS='__EMPTY__'
run
check "라벨 0개 readback: resumed"       "$(has_ev resumed)"
check "라벨 0개 readback: warn 없음"     "$(no_ev warn)"
check "라벨 0개 readback: after-edit 없음" "$(no_ev warn_after_edit)"
setup "hold:ladder,agent-ready" 200 0
STUB_READBACK_LABELS='hold:ladder,agent-ready'
run
check "readback 불일치: warn_after_edit" "$(has_ev warn_after_edit)"
check "readback 불일치: 순수 warn 아님"  "$(no_ev warn)"
check "readback 불일치: resumed 없음"    "$(no_ev resumed)"

# ── ⑱ 라벨 편집 실패 → 마커는 이미 남았다(warn_after_edit) ────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_LABEL_EDIT_FAIL=1
run
check "라벨 실패: warn_after_edit"       "$(has_ev warn_after_edit)"
check "라벨 실패: resumed 없음"          "$(no_ev resumed)"
check "라벨 실패: 마커는 남았다"         "$([ "$(markers)" = 1 ] && echo ok || echo no)"

# ── ⑲ 두 쿼리 각각의 조회 실패 → exit 2 (fail-loud) ───────────────────────
setup "hold:ladder,agent-ready" 200 0
STUB_LADDER_FAIL=1
run
check "ladder 조회 실패: exit 2"         "$([ "$RC" = 2 ] && echo ok || echo no)"
check "ladder 조회 실패: stderr"         "$(grep -q 'hold:ladder 목록 조회 실패' "$tmp/err" && echo ok || echo no)"
check "ladder 조회 실패: resumed 없음"   "$(no_ev resumed)"
setup "hold:ladder,agent-ready" 200 0
STUB_HUMAN_FAIL=1
run
check "human 조회 실패: exit 2"          "$([ "$RC" = 2 ] && echo ok || echo no)"
check "human 조회 실패: 재개는 그대로"   "$(has_ev resumed)"

# ── ⑳ [P2] 두 쿼리 상한 warn ──────────────────────────────────────────────
# 상한값 자체는 RESUME_LIST_LIMIT 로 낮춰 재현한다 — 200행 픽스처는 프로세스 수백 개라
# 박스가 붐빌 때 CI 를 통째로 민다(경로는 값과 무관하게 같다). 기본값이 200 이라는 사실은
# 위 ②의 `--limit 200` 단언이 지킨다.
setup "hold:ladder,agent-ready" 10 0     # 창 안 = 쓰기 없음
LL=3
jq -n --arg u "$(ts 10)" '[range(3) | {number: (.+1000), labels: [{name:"hold:ladder"}], updatedAt: $u}]' \
  > "$tmp/ladder.json"
run
check "ladder 상한: warn"                "$(has_ev warn)"
check "ladder 상한: 쿼리 이름"           "$(saysl '목록 상한 도달(hold:ladder)')"
setup "hold:conflict,agent-ready" 200 0   # hold 있음 = 사유 warn 안 남
LL=3
jq -n --arg u "$(ts 200)" '[range(3) | {number: (.+1000), labels: [{name:"needs-human"},{name:"hold:conflict"}], updatedAt: $u}]' \
  > "$tmp/human.json"
run
check "human 상한: warn"                 "$(has_ev warn)"
check "human 상한: 쿼리 이름"            "$(saysl '목록 상한 도달(needs-human)')"
setup "hold:ladder,agent-ready" 10 0
run
check "상한 미만: 상한 warn 없음"        "$(printf '%s' "$out" | grep -q '목록 상한 도달' && echo no || echo ok)"

# ── ㉑ [P2] 상수 값 검증 — GitHub 쓰기 전에 exit 64 ───────────────────────
setup "hold:ladder,agent-ready" 200 0
RA='120m'
run
check "잘못된 RESUME_AFTER_MIN: exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 RESUME_AFTER_MIN: stderr"  "$(grep -q 'RESUME_AFTER_MIN' "$tmp/err" && echo ok || echo no)"
check "잘못된 RESUME_AFTER_MIN: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"
setup "hold:ladder,agent-ready" 200 0
RL='-1'
run
check "잘못된 LADDER_RESUME_LIMIT: exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 LADDER_RESUME_LIMIT: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"

# ── ㉒ .loop/repos 부재 = 계정 전체 탐색 ──────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"; STUB_SEARCH_FAIL=1
run
check "탐색 실패: exit 2"                "$([ "$RC" = 2 ] && echo ok || echo no)"
check "탐색 실패: stderr 사유"           "$(grep -q '탐색 실패' "$tmp/err" && echo ok || echo no)"
check "탐색 실패: 무편집"                "$(none 'issue edit')"
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; awk 'BEGIN{for(i=1;i<=3;i++) print "owner/r" i}' > "$tmp/search"
run
check "탐색 상한: warn"                  "$(has_ev warn)"
check "탐색 상한: 문구"                  "$(saysl '탐색 상한 도달')"
check "탐색 상한: exit 0"                "$([ "$RC" = 0 ] && echo ok || echo no)"
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; awk 'BEGIN{for(i=1;i<=2;i++) print "owner/r" i}' > "$tmp/search"
run
check "탐색 상한 미만: warn 없음"        "$(no_ev warn)"

# ── ㉒-b (#236) 폴백 질의는 `is:` 한정자를 쓰지 않는다 ─────────────────────
# 옛 질의(`label:needs-human is:open is:issue`)는 gh search 오파싱으로 항상 빈손이라,
# 스윕이 레포 0개를 훑고 exit 0 · 무출력으로 끝나 "멈춘 건 없음" 과 구분되지 않았다.
# 닫힌 이슈·PR 배제라는 **의도는 그대로**이고 수단만 `--state open` 플래그로 옮긴다.
# (#244 로 픽스처 라벨에서 `needs-human` 을 뺐다 — 사람이 세운 정지가 동존하면 재개하지
#  않는 것이 이 PR 의 설계라, 옛 픽스처는 `resumed` 대신 warn 으로 끝난다. 이 케이스가
#  묻는 것은 **폴백 질의의 형태**이지 재개 조건이 아니므로 단언은 한 줄도 안 줄인다.)
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
printf 'owner/repo\n' > "$tmp/search"
run
check "폴백 질의: is: 한정자 없음"       "$(none 'search issues .*is:')"
check "폴백 질의: --state open 플래그"   "$(some 'search issues .*--state open')"
check "폴백 열거: 레포를 실제로 훑는다"  "$(some 'issue list')"
check "폴백 열거: 재개까지 간다"         "$(has_ev resumed)"
check "폴백 열거: exit 0"                "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── ㉒-c (#236) 스코프 갈래(.loop/repos 있음)는 미변경 — 탐색을 아예 안 부른다 ──
setup "hold:ladder,agent-ready" 200 0
run
check "스코프 갈래: search 미호출"       "$(none 'search issues')"
check "스코프 갈래: search prs 도 미호출" "$(none 'search prs')"
check "스코프 갈래: 재개까지 간다"       "$(has_ev resumed)"

# ── ㉒-d (#244) 계정 전체 탐색은 정지 라벨을 전부 훑는다(#331 반송으로 hold:conflict 까지 넷) ──
# 스코프 탐색이 `label:needs-human` 하나였던 것은 "기계 정지엔 needs-human 이 늘 붙는다" 는
# 전제 위에 서 있었다. 그 전제를 이 이슈가 없앴으므로, `hold:ladder`/`hold:policy` 만 달린
# 레포는 탐색에서 통째로 빠져 **영영 안 스윕된다**(재개가 조용히 죽는 경로).
# 부정 라벨은 넣지 않는다(#21) — 긍정 라벨을 라벨마다 한 번씩 합집합(sort -u)한다. 모든 쿼리가
# `is:` 한정자 없이 `--state open` 플래그다(#236 — ㉒-b 와 같은 형태).
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"; echo '[]' > "$tmp/policy.json"
printf 'owner/repo\n' > "$tmp/search"
run
check "탐색: needs-human 쿼리 유지"   "$(some 'search issues label:needs-human .*--state open')"
check "탐색: hold:ladder 도 훑는다"    "$(some 'search issues label:hold:ladder .*--state open')"
check "탐색: hold:policy 도 훑는다"    "$(some 'search issues label:hold:policy .*--state open')"
check "탐색: 부정 라벨은 안 쓴다(#21)" "$(none 'search issues .*-label:')"
check "탐색: is: 한정자 없음(#236)"    "$(none 'search issues .*is:')"
# 여러 쿼리가 같은 레포를 돌려줘도 스윕은 한 번이다(sort -u) — ① 목록 조회 횟수로 실측한다.
check "탐색: 중복 레포는 한 번만 스윕" "$([ "$(counts 'issue list --repo owner/repo .*--label hold:ladder')" = 1 ] && echo ok || echo no)"
check "탐색: exit 0"                   "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── ㉓ 정상 경로 exit 0 ───────────────────────────────────────────────────
setup "hold:ladder,agent-ready" 200 0
run
check "정상 경로: exit 0"                "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── ㉔~㉗ (#190) 배포 대기 라벨의 사유 없는 needs-human 은 warn 이 아니라 note ────
# warn 은 "루프가 교정 가능한 불변식 위반" 일 때만이다(#188 이 loop-status.sh 에서 정한 정의).
# 배포 대기 이슈는 사유 라벨 없이 needs-human 으로 쉬는 것이 **정상 상태**라 교정할 것이
# 없다 — 그런데 머지될 때마다 늘어 진짜 "사람이 사유 없이 붙인 needs-human" 을 묻는다.
# 그렇다고 그냥 빼면 존재가 관측에서 사라지므로 note 로 강등한다.

# ── ㉔ deploy-wait(정본 축) → warn 0 · note 1 · 무편집 ─────────────────────
setup "needs-human,deploy-wait" 200 0
run
check "deploy-wait: note"                "$(has_ev note)"
check "deploy-wait: warn 없음"           "$(no_ev warn)"
check "deploy-wait: 문구가 라벨을 남긴다" "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("deploy-wait"))' >/dev/null 2>&1 && echo ok || echo no)"
check "deploy-wait: 편집 0회"            "$(none 'issue edit')"
check "deploy-wait: exit 0"              "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── ㉕ full-cycle(과도기 축) → warn 0 · note 1 (실측 #5000 형태) ───────────
# 사람 세션 스킬 full-cycle §7 이 배포 대기 이슈에 needs-human+full-cycle 만 붙이고
# deploy-wait 를 빠뜨려 생긴 구멍이다 — 그쪽이 deploy-wait 를 붙이면 이 갈래는 뗀다.
setup "needs-human,full-cycle" 200 0
run
check "full-cycle: note"                 "$(has_ev note)"
check "full-cycle: warn 없음"            "$(no_ev warn)"
check "full-cycle: 문구가 라벨을 남긴다" "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("full-cycle"))' >/dev/null 2>&1 && echo ok || echo no)"
check "full-cycle: 편집 0회"             "$(none 'issue edit')"

# ── ㉖ (#244) 배포 대기 라벨이 없어도 note 지만 **문구가 다르다** ──────────
# ⑫ 와 같은 픽스처다(의도). 두 갈래가 note 로 합쳐졌으니 이제 구분되는 것은 문구다 —
# 어느 이유로 조용해졌는지(배포 레인이라서 / 사람이 직접 세워서)가 뭉개지면 다음 사람이
# 두 상태를 못 가른다.
setup "needs-human,agent-ready" 200 0
run
check "배포 대기 라벨 없음: note"          "$(has_ev note)"
check "배포 대기 라벨 없음: warn 아님"     "$(no_ev warn)"
check "배포 대기 라벨 없음: 배포 레인 문구 아님" \
  "$(printf '%s' "$out" | grep -q '배포 대기(라벨' && echo no || echo ok)"

# ── ㉗ 과도기 축의 부작용을 못박는다 — full-cycle 이면 구현 이슈여도 note ──
# 제목이 배포 대기 형태가 아닌 구현 이슈(agent-ready 를 달았던 모양)라도 지금은 note 로
# 강등된다. 판별은 **라벨로만** 하기 때문이다(제목은 사람이 자유롭게 쓴다) — 스크립트가
# title 을 애초에 조회조차 하지 않으므로 제목 축은 원천적으로 불가능하다. 이 트레이드오프는
# 의도된 것이고, 실측상 그런 이슈(needs-human+full-cycle 인 구현 이슈)는 계정 전체에 0건이다.
setup "needs-human,full-cycle,agent-ready" 200 0
run
check "full-cycle 구현 이슈: 그래도 note" "$(has_ev note)"
check "full-cycle 구현 이슈: warn 없음"   "$(no_ev warn)"
check "제목은 조회조차 안 한다(라벨 축)"   "$(grep -q -- '--json [^ ]*title' "$tmp/gh.log" && echo no || echo ok)"

# ── ㉘ (#190) 강등은 `hold:*` 가드 **안쪽**이다 — 사유 라벨이 있으면 note 도 아니다 ──
# 배포 대기 라벨이 붙어 있어도 `hold:*` 가 있으면 ② 는 그 행을 아예 보지 않는다(무편집 통과)
# — 판정을 가드 밖으로 끌어내는 리팩터가 이 단언 없이는 전건 통과한다. ③ 이 정상적으로
# 집어 가는지(policy_review_due)까지 확인해 "흘러갔다" 를 실증한다.
# 이 테스트가 그대로 #201 Test plan ⓒ(deploy-wait + hold:policy + 노트 **있음** → 종전대로
# policy_review_due 창 판정)다 — #201 의 no-note 갈래 변경이 이 갈래(due)엔 손대지 않았다는
# 회귀 증거로 겸한다(사전 리뷰 지적 대응 — 신규 diff 에는 없던 기존 테스트라 안 보였다).
setup "deploy-wait,hold:policy" 200 0
jq --arg b "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->" \
  '. + [{body: $b}]' "$tmp/comments.json" > "$tmp/c.tmp" && mv "$tmp/c.tmp" "$tmp/comments.json"
run
check "deploy-wait+hold:policy: note 아님"     "$(no_ev note)"
check "deploy-wait+hold:policy: ② warn 도 아님" "$(printf '%s' "$out" | grep -q '사유 없음' && echo no || echo ok)"
check "deploy-wait+hold:policy: ③ 으로 흐른다"  "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .number == 42' >/dev/null 2>&1 && echo ok || echo no)"
check "deploy-wait+hold:policy: 편집 0회"      "$(none 'issue edit')"

# ── ㉙ (#190) 두 축이 동존하면 정본 축(deploy-wait)이 문구에 남는다 ────────
# 우선순위가 결정론적이어야 다음 사람이 "어느 라벨로 걸렀나" 를 되짚을 수 있다.
setup "needs-human,deploy-wait,full-cycle" 200 0
run
check "두 축 동존: note 1건"                "$(has_ev note)"
check "두 축 동존: 정본 축 deploy-wait 를 적는다" "$(printf '%s' "$out" | jq -e 'select(.event=="note") | (.msg | test("deploy-wait")) and (.msg | test("full-cycle") | not)' >/dev/null 2>&1 && echo ok || echo no)"
check "두 축 동존: warn 없음"               "$(no_ev warn)"

# ── policy 재심 due(#155) — 창 넘긴 hold:policy 에 재심 마커가 없으면 1회 이벤트, 무편집
note() { jq --arg b "$1" '. + [{body: $b}]' "$tmp/comments.json" > "$tmp/c.tmp" && mv "$tmp/c.tmp" "$tmp/comments.json"; }
# ⓑ(#201) 회귀 방지 — 배포 대기가 **아닌** no-note 는 계속 warn 이다(진짜 규약 위반).
setup "hold:policy,agent-ready" 200 0
run
check "policy 재심 질문 없음: warn(no-note)" "$(printf '%s' "$out" | grep -q 'hold-note' && echo ok || echo no)"
check "policy 재심 질문 없음: due 안 냄" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
check "policy 재심 질문 없음(배포 대기 아님): note 없음" "$(no_ev note)"

# ── ⓐ(#201) 배포 대기 + hold:policy + no-note → warn 아니라 note(조치 불가 반복 억제) ──
# ②(사유 없는 needs-human)와 같은 deploy_wait_row 공유 술어를 쓴다. 실측 근거는
# ggqgga/BodaT#5013 — 배포 레인이 transition.sh 를 거치지 않고 라벨을 직접 붙여 사람이
# 답할 질문이 코멘트 산문에 있었는데도 `<!-- hold-note: policy -->` 마커가 없었다.
setup "deploy-wait,hold:policy" 200 0
run
check "배포대기 policy no-note: note"          "$(has_ev note)"
check "배포대기 policy no-note: warn 아님"      "$(no_ev warn)"
check "배포대기 policy no-note: due 안 냄"      "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
check "배포대기 policy no-note: 문구에 deploy-wait·hold:policy" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("deploy-wait")) and (.msg | test("hold:policy"))' >/dev/null 2>&1 && echo ok || echo no)"
check "배포대기 policy no-note: 편집 0회"       "$(none 'issue edit')"

# ── ⓐ'(#201) full-cycle 과도기 축도 같은 술어를 공유한다(②와 동일 트레이드오프) ──
setup "full-cycle,hold:policy" 200 0
run
check "full-cycle policy no-note: note"        "$(has_ev note)"
check "full-cycle policy no-note: warn 아님"    "$(no_ev warn)"

setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재심: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "policy 재심: policy_review_due 이벤트" "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .number == 42' >/dev/null 2>&1 && echo ok || echo no)"
check "policy 재심: 무편집" "$(grep -q 'issue edit' "$tmp/gh.log" && echo no || echo ok)"
check "policy 재심: hold:policy 단독 쿼리(#244)" \
  "$(grep -q 'issue list .*--label needs-human --label hold:policy' "$tmp/gh.log" && echo no || echo ok)"
check "policy 재심: needs-human 없이도 집는다(#244)" \
  "$(grep -q 'issue list --repo owner/repo .*--label hold:policy' "$tmp/gh.log" && echo ok || echo no)"
setup "hold:policy,agent-ready" 30 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재심 창 안: 이벤트 없음" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"

# ── ③-h (#244 반송②) 사람이 세운 `needs-human` 이 동존하면 재심 대상이 아니다 ──
# ③ 은 `--label hold:policy` 단독 쿼리라 사람이 손으로 `needs-human` 을 더한 건도
# 집어 온다. 그대로 `policy_review_due` 를 내면 디스패처가 그 판정에서
# `verify-redispatch` 를 부를 수 있고, 그 전이는 `needs-human` 과 `hold:*` 를 **둘 다**
# 뗀다(transition.sh:147-148) — 이 이슈가 방금 "루프가 치우면 안 되는 것" 으로 정의한
# 라벨을 루프가 치운다. ①(sweep_issue :479-484)에는 이 배제가 있는데 ③ 에는 없었다.
# 조용한 continue 로 두지 않는다(#247) — 왜 재심이 안 도는지가 어디에도 안 남는다.
# `warn` 이 아니라 `note` 인 근거는 resume-sweep.sh 의 갈래 주석에.
setup "needs-human,hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "③-h needs-human 동존: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "③-h needs-human 동존: policy_review_due 안 냄" \
  "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
check "③-h needs-human 동존: note 로 남긴다(조용한 스킵 아님)" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("needs-human"))' >/dev/null 2>&1 && echo ok || echo no)"
check "③-h needs-human 동존: warn 아님" "$(no_ev warn)"
check "③-h needs-human 동존: 무편집" "$(none 'issue edit')"
# 대조군 — 같은 픽스처에서 needs-human 만 빼면 종전대로 due 가 난다(배제가 과하지 않다).
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "③-h 대조군: needs-human 없으면 종전대로 due" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .number == 42' >/dev/null 2>&1 && echo ok || echo no)"
# ── ③-r (#351) needs-human 배제는 목록 스냅샷이 아니라 **편집 직전 재조회**로 판정한다 ──
# 목록 조회 → 사람이 needs-human 부착 → 같은 틱에 ③ 이 스냅샷(row)만 보고 due 를 내면
# 디스패처가 verify-redispatch 로 그 정지를 벗긴다(#151 부류). ①(sweep_issue)이 쓰는
# read_state 를 ③ 도 due 직전에 다시 부른다 — 스냅샷엔 없고 재조회에만 needs-human 이 있는
# 픽스처에서 due 0 · note 1 · 전이/편집 0 이어야 한다.
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
STUB_STATE_LABELS='needs-human,hold:policy,agent-ready'   # 목록 조회 이후 사람이 needs-human 을 붙임
run
check "③-r 재조회 needs-human: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "③-r 재조회 needs-human: policy_review_due 안 냄" "$(no_ev policy_review_due)"
check "③-r 재조회 needs-human: note 로 남긴다" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("needs-human"))' >/dev/null 2>&1 && echo ok || echo no)"
check "③-r 재조회 needs-human: warn 아님" "$(no_ev warn)"
check "③-r 재조회 needs-human: 무편집" "$(none 'issue edit')"
check "③-r 재조회 needs-human: ①과 같은 재조회(labels,updatedAt)를 불렀다" "$(some 'issue view 42 .*--json labels,updatedAt')"
# 재조회 자체가 실패하면 "needs-human 없음" 으로 폴백하지 않는다(fail-closed, ①의 ⑯과 같은 축) —
# 폴백하면 정확히 이 갈래가 막으려는 사고(사람 게이트를 조용히 벗기는 것)가 조회 실패 경로에서 재현된다.
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
STUB_STATE_LABELS='__FAIL__'
run
check "③-r 재조회 실패: policy_review_due 안 냄" "$(no_ev policy_review_due)"
check "③-r 재조회 실패: warn 으로 알린다" "$([ "$(has_ev warn)" = ok ] && [ "$(saysl '재조회 실패')" = ok ] && echo ok || echo no)"
check "③-r 재조회 실패: 무편집" "$(none 'issue edit')"
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note "재심: 사람 몫 유지 <!-- policy-review: kept --><!-- bodat:worker -->"
run
check "policy 재심 마커 있음: 다시 안 냄" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
# 옛 홀드의 재심 마커 뒤에 새 질문(hold-note)이 오면 새 에피소드 → 다시 due
note "사람 확인(policy): 이번엔 C인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재홀드: 새 질문 뒤엔 다시 due" "$(printf '%s' "$out" | grep -q policy_review_due && echo ok || echo no)"
# 승격(escalated) 코멘트가 hold-note 를 품는다 — 승격 건도 재심 대상이 된다
setup "hold:ladder,agent-ready" 200 2
run
check "승격 코멘트에 hold-note:policy" "$(grep -q 'hold-note: policy' "$tmp/gh.log" && echo ok || echo no)"

# ── ㉚ (#193) 번호를 못 구한 줄도 **유효 JSON 으로** 나간다 ────────────────
# 재현: `sweep_issue`·② 는 목록 행을 jq 로 파싱해 번호를 얻는데, 그 파싱이 깨지면
# `num`(`hnum`)이 **빈 문자열**이 된다. 세 헬퍼의 `"number":%s` 는 따옴표 **밖**이라
# 그대로 `{…,"number":,"msg":…}` 가 나가 줄 전체가 JSON 이 아니었다 — 관대한 파서에선
# 그 줄이 통째로 유실되고 엄격한 파서에선 읽기가 멈춘다. 어느 쪽이든 **경보가 조용히
# 사라지는** 방향이라, 요구는 셋이다: (a) 줄은 나간다(삼키지 않는다) (b) 유효 JSON 이다
# (c) 번호를 못 구했다는 사실이 줄에서 읽힌다.
# 픽스처는 number 를 JSON **문자열**로 박아 그 상태를 만든다(실경로인 jq 실패와 `num` 의
# 모양이 같다 — 둘 다 빈 문자열). 세 헬퍼를 각각 그 경로로 몰아 따로 확인한다.
bad_num_rows() {  # bad_num_rows <출력파일> <number 자리에 박을 값> <라벨csv> <updatedAt>
  jq -n --arg n "$2" --arg l "$3" --arg u "$4" \
    '[{number:$n, labels: ($l|split(",")|map(select(length>0)|{name:.})), updatedAt:$u}]' > "$1"
}
lines_all_json() {  # 출력의 **모든** 줄이 유효 JSON 인가 — 빈 출력(삼킴)도 실패
  local line
  [ -s "$tmp/out" ] || { echo no; return; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || { echo no; return; }
  done < "$tmp/out"
  echo ok
}
evq() {  # evq <이벤트> <jq 식> — 깨진 줄이 섞이면 jq 가 실패해 no
  jq -e "select(.event==\"$1\") | $2" "$tmp/out" >/dev/null 2>&1 && echo ok || echo no
}
# 패턴은 `-e` 로 넘기고 파일은 `--` 뒤에 — `-` 로 시작하는 패턴을 맨몸으로 주면 grep 이
# 그것을 옵션으로 먹고 파일 인자를 패턴 삼아 stdin 을 읽는다(스위트가 조용히 매달린다).
nlines() { grep -c -e "$1" -- "$tmp/out" 2>/dev/null || true; }
# 미상 표식은 **앞머리**에 원본 토큰을 인용해 붙는다 — `번호 파싱 실패('<토큰>') — `.
# 뒤에 오는 기존 문구는 한 바이트도 안 바뀐다(디스패처 SKILL.md 가 문구로 분기한다).
# jq 문자열 안의 `'` 은 작은따옴표 — 셸 작은따옴표 안이라 맨몸으로 못 쓴다.
unknown_prefix() {  # unknown_prefix <이벤트> <원본 토큰>
  jq -e --arg t "$2" \
    "select(.event==\"$1\") | .msg | startswith(\"번호 파싱 실패(\\u0027\" + \$t + \"\\u0027) — \")" \
    "$tmp/out" >/dev/null 2>&1 && echo ok || echo no
}

# (가) emit_warn — ① 이 updatedAt 을 못 읽은 줄. 번호도 함께 비어 있다.
setup "hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" ""
echo '[]' > "$tmp/human.json"
run
check "빈 번호 warn: 모든 줄이 유효 JSON"     "$(lines_all_json)"
check "빈 번호 warn: 줄을 삼키지 않는다"       "$([ "$(nlines '"event":"warn"')" = 1 ] && echo ok || echo no)"
check "빈 번호 warn: number 는 0"             "$(evq warn '.number == 0')"
check "빈 번호 warn: 기존 문구 그대로"         "$(evq warn '.msg | test("updatedAt 해석 불가")')"
check "빈 번호 warn: 번호 미상·원본 토큰이 앞머리에" "$(unknown_prefix warn '')"

# (나) emit_note — ② 배포 대기(#190) 줄. hnum 이 비어도 note 는 나가야 한다.
setup "needs-human,agent-ready" 200 0
echo '[]' > "$tmp/ladder.json"
bad_num_rows "$tmp/human.json" "" "needs-human,deploy-wait" "$(ts 200)"
run
check "빈 번호 note: 모든 줄이 유효 JSON"     "$(lines_all_json)"
check "빈 번호 note: 줄을 삼키지 않는다"       "$([ "$(nlines '"event":"note"')" = 1 ] && echo ok || echo no)"
check "빈 번호 note: number 는 0"             "$(evq note '.number == 0')"
check "빈 번호 note: 기존 문구 그대로"         "$(evq note '.msg | test("배포 대기\\(라벨 deploy-wait\\)")')"
check "빈 번호 note: 번호 미상·원본 토큰이 앞머리에" "$(unknown_prefix note '')"

# (다) emit_warn_after_edit — 쓰기 뒤 readback 조회가 실패한 줄.
setup "hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
STUB_READBACK_LABELS="__FAIL__"
run
check "빈 번호 warn_after_edit: 모든 줄이 유효 JSON" "$(lines_all_json)"
check "빈 번호 warn_after_edit: 줄을 삼키지 않는다"   "$([ "$(nlines '"event":"warn_after_edit"')" = 1 ] && echo ok || echo no)"
check "빈 번호 warn_after_edit: number 는 0"         "$(evq warn_after_edit '.number == 0')"
check "빈 번호 warn_after_edit: 기존 문구 그대로"     "$(evq warn_after_edit '.msg | test("재개 readback 조회 실패")')"
check "빈 번호 warn_after_edit: 번호 미상·토큰 앞머리" "$(unknown_prefix warn_after_edit '')"

# (라) 정상 경로 무회귀 — 번호가 있으면 표식이 붙지 않는다(문구가 한 바이트도 안 바뀐다).
setup "needs-human,agent-ready" 200 0
run
check "정상 번호: number 유지·표식 없음" "$(evq note '.number == 42 and (.msg | test("번호 파싱 실패") | not)')"

# ── ㉛ (#193) `msg` 없는 이벤트 넷도 같은 자리를 안전하게 — waiting·escalated·resumed·
#    policy_review_due. 이쪽은 사실을 적을 `msg` 칸이 없어 **형식 안전만** 취한다(번호 0).
#    방출 조건은 안 바뀐다 — 특히 waiting 은 원래 조용히 넘기는 이벤트라 줄 수가 늘면 안 된다.
#    이슈 본문 `## 범위 — 한 자리가 아니라 파일 전역이다` 가 요구한 넓히기.
setup "hold:ladder,agent-ready" 10 0
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" "$(ts 10)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 waiting(창 전): 유효 JSON"    "$(lines_all_json)"
check "빈 번호 waiting(창 전): 1줄만"        "$([ "$(nlines '"event":"waiting"')" = 1 ] && echo ok || echo no)"
check "빈 번호 waiting(창 전): number 는 0"  "$(evq waiting '.number == 0')"
check "빈 번호 waiting(창 전): minutes 유지"  "$(evq waiting '.minutes >= 9 and .minutes <= 11')"

# 창 재판정 경로(목록 스냅샷 뒤 사람이 건드려 live updatedAt 이 새 기준이 된 경우)의 waiting.
setup "hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
printf '%s' "$(ts 5)" > "$tmp/updated.livefile"
STUB_UPDATED_LIVE="$tmp/updated.livefile"
run
check "빈 번호 waiting(창 재판정): 유효 JSON"   "$(lines_all_json)"
check "빈 번호 waiting(창 재판정): number 는 0" "$(evq waiting '.number == 0')"
check "빈 번호 waiting(창 재판정): 무편집"      "$(none 'issue edit')"

# 재개(resumed) — 번호가 비어도 줄은 유효 JSON 이어야 한다.
setup "hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 resumed: 유효 JSON"      "$(lines_all_json)"
check "빈 번호 resumed: number 는 0"    "$(evq resumed '.number == 0')"
check "빈 번호 resumed: attempt 유지"   "$(evq resumed '.attempt == 1')"

# 승격(escalated) — 마커 2개로 상한 초과.
setup "hold:ladder,agent-ready" 200 2
bad_num_rows "$tmp/ladder.json" "" "hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 escalated: 유효 JSON"        "$(lines_all_json)"
check "빈 번호 escalated: number 는 0"      "$(evq escalated '.number == 0')"
check "빈 번호 escalated: attempt·limit 유지" "$(evq escalated '.attempt == 2 and .limit == 2')"

# policy 재심 due — ③ 의 pnum 이 빈 경우.
setup "hold:policy,agent-ready" 200 0
bad_num_rows "$tmp/policy.json" "" "hold:policy,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/ladder.json"
echo '[]' > "$tmp/human.json"
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "빈 번호 policy_review_due: 유효 JSON"   "$(lines_all_json)"
check "빈 번호 policy_review_due: number 는 0" "$(evq policy_review_due '.number == 0')"
check "빈 번호 policy_review_due: 무편집"      "$(none 'issue edit')"

# 정상 번호(42)일 때 넷 다 번호를 그대로 싣는다 — 바이트 무회귀 가드.
setup "hold:ladder,agent-ready" 10 0
run
check "정상 번호 waiting: number 42 유지" "$(evq waiting '.number == 42')"
setup "hold:ladder,agent-ready" 200 0
run
check "정상 번호 resumed: number 42 유지" "$(evq resumed '.number == 42')"
setup "hold:ladder,agent-ready" 200 2
run
check "정상 번호 escalated: number 42 유지" "$(evq escalated '.number == 42')"
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "정상 번호 policy_review_due: number 42 유지" "$(evq policy_review_due '.number == 42')"

# ── ㉜ (#193 재심) 번호 검증은 **정규 JSON 정수 형태**로 — `01` 은 미상 처리 ──────
# 사람 게이트 재심(#193 코멘트 `<!-- policy-review: resumed -->`)의 판정: 선행 0 토큰은
# 정상 번호의 특이 표기가 **아니다**. `num` 의 출처는 `jq -r '.number|tostring'` 하나뿐이고
# jq 는 `1` 을 `"1"` 로 낸다 — `01` 을 낼 경로가 없으니 그건 **파싱이 어긋났다는 증거**다.
# 그래서 `01 → 1` 정규화는 채택하지 않는다(출처가 말하지 않은 번호를 지어내는 것 —
# 틀린 번호를 단 경보는 번호 없는 경보보다 나쁘다: 읽는 사람이 무고한 이슈를 연다).
# `_nonneg_int()`(모든 문자가 숫자인가)로는 `01`·`007` 이 통과해 `"number":01` 이 나가고,
# RFC 8259 는 선행 0 을 금지하므로 그 줄은 **여전히 깨진 JSON** 이었다.
# `jq` 는 관대해서 `{"number":01}` 을 **조용히 `1` 로 읽는다**(실측 jq-1.7.1-apple).
# 즉 `01` 이 나가면 엄격한 파서(python json)는 줄을 **거절**하고, 관대한 파서는 **없는
# 이슈 #1** 로 읽는다 — 이 이슈가 막으려던 두 실패(조용한 유실 · 틀린 번호)가 정확히 그 둘이다.
# 그래서 계약 단언은 `jq` 만으로 두지 않고 **엄격 파서**로도 한 번 더 문다(jq 로만 재면
# `01` 회귀가 초록으로 통과한다 — 실측으로 확인한 공허 단언 경로).
# closeout 재재심(#193 2회차 반송) — README 가 선언한 요구사항은 `gh`·`jq`·bash 뿐이라
# python3 는 이 스위트가 트리에 처음 들여온 의존성이다. 없는 박스에서 엄격 파서 단언이
# 전부 `no` 로 접히면 `bin/ci` 가 필수 게이트에서 통째로 빨개진다(재현: python3 를 exit 127
# 스텁으로 가리면 237 passed / 15 failed) — 그래서 두 갈래로 나눈다:
#   ① `number_token_json_int` — 파서 없이 **방출된 바이트**를 `case`/`grep -E` 로 직접 문다.
#      01·007 회귀는 이 단언 하나로 어느 박스에서나 잡힌다(주 단언).
#   ② `strict_json_all` — python3 가 있으면 엄격 파서로 한 번 더 물어 보조 확증한다. 없으면
#      **skip** 을 눈에 보이게 돌려준다(조용한 no 금지) — check() 가 skip 을 실패로 안 센다.
number_token_json_int() {  # number_token_json_int <이벤트> — 그 줄의 number 토큰이 정규 JSON 정수 리터럴(0|[1-9][0-9]*)인가
  local line n
  line=$(grep -m1 "\"event\":\"$1\"" "$tmp/out") || { echo no; return; }
  n=$(printf '%s' "$line" | grep -oE '"number":[^,}]*')
  n=${n#'"number":'}
  case "$n" in
    0) echo ok ;;
    [1-9]) echo ok ;;
    [1-9][0-9]*) echo ok ;;
    *) echo no ;;
  esac
}
strict_json_all() {  # 출력의 모든 줄이 RFC 8259 로 파싱되는가 (빈 출력 = 삼킴 = 실패 · python3 없으면/못 돌면 skip)
  [ -s "$tmp/out" ] || { echo no; return; }
  local rc
  python3 -c 'import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    json.loads(line)
    n += 1
sys.exit(0 if n else 1)' "$tmp/out" >/dev/null 2>&1
  rc=$?
  # 127 = "명령을 못 찾음"(PATH 부재의 표준 셸 종료값 — python3 를 exit 127 스텁으로 가려
  # 재현한 closeout 시나리오도 같은 값을 낸다). command -v 로 미리 가리면 이 스텁을 못 잡는다
  # (스텁은 PATH 상엔 실존 파일이라 command -v 는 통과하고, 실행 시점에야 127 을 낸다) — 그래서
  # 실행 결과의 종료값으로 판정한다.
  if [ "$rc" -eq 127 ]; then
    echo skip
    return
  fi
  [ "$rc" -eq 0 ] && echo ok || echo no
}
emit_line_for() {  # emit_line_for <number 자리에 박을 토큰> — warn 줄 하나로 몬다
  setup "hold:ladder,agent-ready" 200 0
  bad_num_rows "$tmp/ladder.json" "$1" "hold:ladder,agent-ready" ""
  echo '[]' > "$tmp/human.json"
  run
}
check_accept() {  # check_accept <정규 토큰>
  emit_line_for "$1"
  check "정규 '$1': 모든 줄이 유효 JSON"      "$(lines_all_json)"
  check "정규 '$1': number 토큰이 정규 JSON 정수 리터럴(바이트 단언)" "$(number_token_json_int warn)"
  check "정규 '$1': 엄격 파서로도 파싱된다"    "$(strict_json_all)"
  check "정규 '$1': number 를 그대로 싣는다"   "$(jq -e --argjson n "$1" 'select(.event=="warn") | .number == $n' "$tmp/out" >/dev/null 2>&1 && echo ok || echo no)"
  check "정규 '$1': 미상 표식 없음(문구 무변)" "$(evq warn '.msg | test("번호 파싱 실패") | not')"
}
check_reject() {  # check_reject <비정규 토큰>
  emit_line_for "$1"
  check "비정규 '$1': 모든 줄이 유효 JSON"      "$(lines_all_json)"
  check "비정규 '$1': number 토큰이 정규 JSON 정수 리터럴(바이트 단언, 0 으로 낮춘 값)" "$(number_token_json_int warn)"
  check "비정규 '$1': 엄격 파서로도 파싱된다"    "$(strict_json_all)"
  check "비정규 '$1': 줄을 삼키지 않는다"        "$([ "$(nlines '"event":"warn"')" = 1 ] && echo ok || echo no)"
  check "비정규 '$1': number 는 0"              "$(evq warn '.number == 0')"
  check "비정규 '$1': 원본 토큰을 앞머리에 인용"  "$(unknown_prefix warn "$1")"
  check "비정규 '$1': 기존 문구가 뒤에 그대로"    "$(evq warn '.msg | test("updatedAt 해석 불가")')"
}

# 통과시켜야 할 것 — `0` 단독도 정규다("특정 이슈가 아니다" 로 이미 쓰는 값).
for t in 0 1 42 1234; do check_accept "$t"; done
# 걸러야 할 것 — 선행 0·부호·소수점·지수·빈 값·공백. 전부 JSON 정수 리터럴이 아니다.
for t in 01 007 +1 1.0 1e3 '' ' ' '1 2'; do check_reject "$t"; done

# 이 이슈의 계약은 "정수처럼 생겼나" 가 아니라 **"JSON 으로 읽히나"** 다 — 토큰에 따옴표·
# 역슬래시가 섞여 들어와도 줄은 파싱돼야 한다(인용을 맨몸으로 박으면 원래 버그의 재현이다).
for t in '1"2' '1\2' 'a"b\c'; do
  emit_line_for "$t"
  check "따옴표 섞인 토큰 '$t': 줄이 jq . 로 파싱된다"   "$(lines_all_json)"
  check "따옴표 섞인 토큰 '$t': number 토큰이 정규 JSON 정수 리터럴(바이트 단언)" "$(number_token_json_int warn)"
  check "따옴표 섞인 토큰 '$t': 엄격 파서로도 파싱된다"  "$(strict_json_all)"
  check "따옴표 섞인 토큰 '$t': number 는 0"           "$(evq warn '.number == 0')"
  check "따옴표 섞인 토큰 '$t': 줄을 삼키지 않는다"     "$([ "$(nlines '"event":"warn"')" = 1 ] && echo ok || echo no)"
done

# ── ㉝ (#193 재심) `_nonneg_int()` 는 안 바꿨다 — env exit 64 게이트 3건 무회귀 ────
# 방출용 술어를 별도 이름으로 세운 이유가 이것이다: 저 헬퍼까지 정규형으로 좁히면
# 사람이 `RESUME_AFTER_MIN=060` 으로 써 온 환경이 갑자기 죽는다(이 이슈의 범위 밖).
setup "hold:ladder,agent-ready" 200 0
RA='060'
run
check "RESUME_AFTER_MIN=060: exit 64 아님(관대함 유지)" "$([ "$RC" != 64 ] && echo ok || echo no)"
check "RESUME_AFTER_MIN=060: 60분으로 읽혀 재개된다"     "$(has_ev resumed)"
setup "hold:ladder,agent-ready" 200 0
RL='02'
run
check "LADDER_RESUME_LIMIT=02: exit 64 아님" "$([ "$RC" != 64 ] && echo ok || echo no)"
setup "hold:ladder,agent-ready" 200 0
LL='0200'
run
check "RESUME_LIST_LIMIT=0200: exit 64 아님" "$([ "$RC" != 64 ] && echo ok || echo no)"
# 진짜 비정수는 여전히 exit 64 (세 게이트 모두).
setup "hold:ladder,agent-ready" 200 0
LL='1000x'
run
check "잘못된 RESUME_LIST_LIMIT: exit 64"   "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 RESUME_LIST_LIMIT: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"

# ── ㉞ (#217) 배포 대기 티켓의 hold:ladder — 재개·승격이 note 갈래와 같은 답을 읽는다 ──
# 실측 ggqgga/BodaT#5040: 같은 실행이 `resumed`(①)와 배포 대기 `note`(②)를 동시에 냈다.
# ②는 hold:ladder 가 있는 행을 애초에 안 보므로(②의 "hold:* 없음" 가드) note 는 여기(①)
# 에서 대신 낸다 — deploy_wait_row 공유 술어(②·③과 동일, #201) 를 여기서도 쓴다.

# ⓐ deploy-wait + needs-human + hold:ladder, 창 경과 → note 만, 라벨 그대로
setup "hold:ladder,deploy-wait,agent-ready" 200 0
run
check "ⓐ deploy-wait+hold:ladder 창 경과: note"        "$(has_ev note)"
check "ⓐ: resumed 아님"                                "$(no_ev resumed)"
check "ⓐ: warn 아님"                                    "$(no_ev warn)"
check "ⓐ: hold:ladder 유지(라벨 그대로)"                "$(hasl hold:ladder)"
check "ⓐ: 편집 0회"                                     "$(none 'issue edit')"
check "ⓐ: 마커 코멘트도 0회"                            "$(none 'issue comment')"
check "ⓐ: 문구에 deploy-wait"                           "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("deploy-wait"))' >/dev/null 2>&1 && echo ok || echo no)"

# ⓑ 회귀 방지 — deploy-wait 없는 needs-human+hold:ladder, 창 경과 → 종전대로 resumed·라벨 해제
setup "hold:ladder,agent-ready" 200 0
run
check "ⓑ 배포 대기 아님: resumed(회귀 없음)"            "$(has_ev resumed)"
check "ⓑ: hold:ladder 해제"                             "$(lacksl hold:ladder)"
check "ⓑ: note 아님"                                     "$(no_ev note)"

# ⓒ deploy-wait + hold:ladder, 재개 마커 2개(상한 소진) → escalated 아님, hold:policy 안 붙는다
setup "hold:ladder,deploy-wait,agent-ready" 200 2
run
check "ⓒ deploy-wait 상한 소진: escalated 아님"          "$(no_ev escalated)"
check "ⓒ: note"                                          "$(has_ev note)"
check "ⓒ: hold:policy 안 붙는다"                         "$(lacksl hold:policy)"
check "ⓒ: hold:ladder 유지(승격 안 함)"                  "$(hasl hold:ladder)"
check "ⓒ: 편집 0회"                                      "$(none 'issue edit')"
check "ⓒ: 상한 초과 코멘트도 안 남긴다"                  "$(none '사다리 재개 상한')"

# ⓓ 회귀 방지 — deploy-wait 없는 상한 소진 → 종전대로 escalated
setup "hold:ladder,agent-ready" 200 2
run
check "ⓓ 배포 대기 아님 상한 소진: escalated(회귀 없음)" "$(has_ev escalated)"
check "ⓓ: hold:policy 부착"                              "$(hasl hold:policy)"
check "ⓓ: note 아님"                                      "$(no_ev note)"

# full-cycle(과도기 축)도 같은 술어를 공유한다 — ②·③과 동일 트레이드오프.
setup "hold:ladder,full-cycle,agent-ready" 200 0
run
check "full-cycle+hold:ladder 창 경과: note"             "$(has_ev note)"
check "full-cycle+hold:ladder: resumed 아님"             "$(no_ev resumed)"
check "full-cycle+hold:ladder: 편집 0회"                 "$(none 'issue edit')"

# ⓔ (사전 리뷰) deploy_wait_row 판정 자체가 실패(labels 모양이 배열이 아님) → warn·무편집
# fail-open 이면 "배포 대기 아님" 으로 폴백해 그대로 재개해버린다 — 이 이슈가 막으려는
# 사고를 판정 실패 경로에서 재현하는 것. number·updatedAt 추출은 .labels 를 안 보므로
# 위 창 판정까지는 정상 통과하고, deploy_wait_row 의 `.labels[].name` 에서만 깨진다.
setup "hold:ladder,agent-ready" 200 0
jq -n --argjson n 42 --arg u "$(ts 200)" '[{number:$n, labels:"broken", updatedAt:$u}]' > "$tmp/ladder.json"
run
check "ⓔ 판정 실패: warn"                                "$(has_ev warn)"
check "ⓔ 판정 실패: 문구"                                "$(saysl '배포 대기 판정 실패')"
check "ⓔ 판정 실패: resumed 아님"                        "$(no_ev resumed)"
check "ⓔ 판정 실패: note 아님"                           "$(no_ev note)"
check "ⓔ 판정 실패: 편집 0회"                            "$(none 'issue edit')"
check "ⓔ 판정 실패: 코멘트 0회"                          "$(none 'issue comment')"

# ── ㉟ (#229) 배포 대기 제외는 **재조회 결과**로 판정한다 — want 열 격자 전수 단언 ──
# #217 의 제외는 목록 조회 스냅샷(row)만 봤다. 기본 RESUME_AFTER_MIN=120 에서는 라벨이
# 붙는 순간 updatedAt 이 갱신돼 창 게이트가 **우연히** 경합 가드 노릇을 했지만, `_nonneg_int`
# 는 0 을 정상값으로 받으므로 RESUME_AFTER_MIN=0(디버깅·강제 재개)이면 그 우연이 사라지고
# 낡은 row 로만 판정하는 제외는 사람 게이트를 그대로 벗겨낸다. 그래서 이 격자는 전부 RA=0
# 에서 돈다 — 120 이면 waiting 으로 빠져 이 경로에 **도달조차 못 한다**.
# 축: (목록 row 의 배포대기 유/무) × (재조회 cur 의 배포대기 유/무/판정실패) × (재개·승격).
# 반례를 하나씩 닫지 않고 want 열로 전수 단언한다(PR#202 교훈 — 개별 반례만 막으면 같은
# 축을 여러 회차 돈다). 경합은 실시간으로 흉내 낼 필요가 없다: 목록 스텁과 read_state
# 스텁에 **다른 응답**을 주는 것이 곧 "목록 조회와 편집 사이에 라벨이 바뀌었다" 이다.
#
#   row(목록)        cur(재조회)      갈래    want        이유
#   ───────────────  ───────────────  ──────  ──────────  ──────────────────────────────
#   없음             없음             재개    resumed     #217 정상 재개(회귀 방지)
#   없음             없음             승격    escalated   종전 승격(회귀 방지)
#   없음             deploy-wait      재개    note        ← 이 이슈가 막는 사고
#   없음             deploy-wait      승격    note        ← 승격 갈래도 같은 제외
#   없음             full-cycle       재개    note        과도기 축도 같은 술어
#   없음             full-cycle       승격    note        과도기 축도 같은 술어
#   없음             판정실패         재개    warn        fail-closed(폴백 금지)
#   없음             판정실패         승격    warn        fail-closed(폴백 금지)
#   deploy-wait      없음             재개    resumed     ← 반대 방향: 낡은 row 로 막지 않는다
#   deploy-wait      없음             승격    escalated   ← 반대 방향(승격 갈래)
#   deploy-wait      deploy-wait      재개    note        ⓐ 와 같은 답(둘 다 있음)
#   deploy-wait      deploy-wait      승격    note        ⓒ 와 같은 답(둘 다 있음)
#   deploy-wait      판정실패         재개    warn        fail-closed
#   full-cycle       없음             재개    resumed     반대 방향(과도기 축)
#
# (row 자체가 깨진 경우는 위 ⓔ 가 문다 — 그쪽은 여기 재조회 이전 단계다.)
dw_want() {  # dw_want <이름> <row 라벨csv> <cur 라벨csv|__CUR_FAIL__> <마커수> <want>
  local name="$1" rowlab="$2" curlab="$3" mk="$4" want="$5" got
  setup "$rowlab" 200 "$mk"
  RA=0
  if [ "$curlab" = "__CUR_FAIL__" ]; then
    STUB_STATE_LABELS="$rowlab"          # 라벨 자체는 정상 — 판정 도구만 실패시킨다
    STUB_JQ_FAIL_PAT='deploy-wait-adapter'
  else
    STUB_STATE_LABELS="$curlab"
  fi
  run
  STUB_JQ_FAIL_PAT=""
  # 이벤트 **집합**으로 비교한다 — 원하는 갈래가 나왔는지뿐 아니라 곁가지가 함께 나오지
  # 않았는지까지 한 단언이 문다(실측 #5040 은 resumed 와 note 가 **동시에** 난 사고였다).
  got=$(printf '%s' "$out" | jq -r 'select(.event != null) | .event' 2>/dev/null | sort -u | tr '\n' ' ')
  got=${got% }
  check "격자 $name → $want" "$([ "$got" = "$want" ] && echo ok || echo "no($got)")"
  case "$want" in
    note|warn)
      check "격자 $name: 편집 0회"          "$(none 'issue edit')"
      check "격자 $name: 코멘트 0회"        "$(none 'issue comment')"
      check "격자 $name: hold:ladder 유지"  "$(hasl hold:ladder)" ;;
    resumed)
      check "격자 $name: hold:ladder 해제"  "$(lacksl hold:ladder)"
      check "격자 $name: needs-human 안 붙는다" "$(lacksl needs-human)" ;;
    escalated)
      check "격자 $name: hold:policy 부착"  "$(hasl hold:policy)"
      check "격자 $name: needs-human 안 붙는다" "$(lacksl needs-human)" ;;
  esac
}

NHL='hold:ladder,agent-ready'
dw_want "row없음/cur없음/재개"        "$NHL"              "$NHL"                          0 resumed
dw_want "row없음/cur없음/승격"        "$NHL"              "$NHL"                          2 escalated
dw_want "row없음/cur=deploy-wait/재개" "$NHL"             "$NHL,deploy-wait"              0 note
dw_want "row없음/cur=deploy-wait/승격" "$NHL"             "$NHL,deploy-wait"              2 note
dw_want "row없음/cur=full-cycle/재개"  "$NHL"             "$NHL,full-cycle"               0 note
dw_want "row없음/cur=full-cycle/승격"  "$NHL"             "$NHL,full-cycle"               2 note
dw_want "row없음/cur판정실패/재개"     "$NHL"             "__CUR_FAIL__"                  0 warn
dw_want "row없음/cur판정실패/승격"     "$NHL"             "__CUR_FAIL__"                  2 warn
dw_want "row=deploy-wait/cur없음/재개" "$NHL,deploy-wait" "$NHL"                          0 resumed
dw_want "row=deploy-wait/cur없음/승격" "$NHL,deploy-wait" "$NHL"                          2 escalated
dw_want "row=deploy-wait/cur=deploy-wait/재개" "$NHL,deploy-wait" "$NHL,deploy-wait"      0 note
dw_want "row=deploy-wait/cur=deploy-wait/승격" "$NHL,deploy-wait" "$NHL,deploy-wait"      2 note
dw_want "row=deploy-wait/cur판정실패/재개"     "$NHL,deploy-wait" "__CUR_FAIL__"          0 warn
dw_want "row=full-cycle/cur없음/재개"  "$NHL,full-cycle"  "$NHL"                          0 resumed

# 문구 단언 — 기존 note 문구를 그대로 재사용하는지(디스패처 SKILL 이 문구로 분기한다)와
# 재조회 쪽 warn 이 **어느 쪽 판정이 실패했는지** 구분되는지.
setup "$NHL" 200 0
RA=0
STUB_STATE_LABELS="$NHL,deploy-wait"
run
check "㉟ 문구: 기존 note 문구 재사용" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("배포 대기\\(라벨 deploy-wait\\) — 배포 레인의 정상 상태라 warn 아님"))' >/dev/null 2>&1 && echo ok || echo no)"

setup "$NHL" 200 0
RA=0
STUB_STATE_LABELS="$NHL"
STUB_JQ_FAIL_PAT='deploy-wait-adapter'
run
STUB_JQ_FAIL_PAT=""
check "㉟ 문구: 재조회 쪽 판정 실패임을 적는다" "$(saysl '재조회')"
check "㉟ 재조회 판정 실패: 배포 대기 문구"     "$(saysl '배포 대기')"

# ── (#197) 인용된 마커는 제어 신호가 아니다 ────────────────────────────────
# 마커는 루프끼리 주고받는 신호인데, 그 신호를 **설명하는 글**(백틱 인라인 코드·코드펜스)이
# substring 매칭에 걸려 신호 자체로 읽히던 회귀. 실측(ggqgga/issue-runner#174)에서 재심
# 코멘트가 본문에 hold-note 을 인용해 **자기 자신을 새 에피소드 경계**로 만들었고, 경계
# 뒤(range($q+1; …))에는 재심 마커가 없어 판정이 매 틱 `due` 로 되돌아왔다(영구 반복).

# ⓐ 인용된 hold-note + 같은 코멘트 안의 **진짜** 재심 마커 → reviewed (due 아님)
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note '재심: 사람 몫 유지 — 이벤트마다 에피소드 경계(마지막 `` `<!-- hold-note: policy -->` ``)를 잡고 그 뒤를 본다 <!-- policy-review: kept --><!-- bodat:worker -->'
run
check "#174 인용 hold-note: 경계가 아니다(due 재발 없음)" "$(no_ev policy_review_due)"
check "#174 인용 hold-note: warn 도 아니다"              "$(no_ev warn)"

# 코드펜스로 인용한 hold-note 도 같다(같은 코멘트에 진짜 재심 마커가 맨몸으로 붙어 있다).
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note '재심: 사람 몫 유지 — 예시는 아래와 같다
```
<!-- hold-note: policy -->
```
<!-- policy-review: kept --><!-- bodat:worker -->'
run
check "코드펜스 인용 hold-note: due 재발 없음" "$(no_ev policy_review_due)"

# ⓑ 진짜 새 hold-note(맨몸 마커) 뒤에 재심 마커가 없으면 여전히 `due` — 인용 제거가
#    진짜 질문까지 지워 버리면 이 단언이 빨개진다(과다 필터 방증).
setup "hold:policy,agent-ready" 200 0
note '재심: 지난 홀드는 사람 몫 유지 <!-- policy-review: kept --><!-- bodat:worker -->'
note "사람 확인(policy): 이번엔 C인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "새 질문 뒤 마커 없음: 여전히 due" "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .number == 42' >/dev/null 2>&1 && echo ok || echo no)"

# ⓒ 회귀 없음 — 블록쿼트(`>`) 안의 **맨몸** 마커는 정상 신호로 계속 센다. 블록쿼트로 남의
#    코멘트를 통째 인용하는 일은 이 루프에 없고, 걸러 버리면 진짜 마커를 잃는다(#197 방향 A).
setup "hold:policy,agent-ready" 200 0
note '> 사람 확인(policy): A인가 B인가
> <!-- hold-note: policy --><!-- bodat:worker -->'
run
check "블록쿼트 맨몸 hold-note: 질문으로 센다(due)" "$(has_ev policy_review_due)"
check "블록쿼트 맨몸 hold-note: warn 없음(no-note 로 안 샌다)" "$(no_ev warn)"

# ⓓ 인용된 `ladder-resume` 은 재개 횟수를 올리지 않는다 — 아직 재개 여지가 있는 이슈가
#    상한(2) 초과로 조기에 사람 대기(hold:policy)로 승격되던 둘째 축.
setup "hold:ladder,agent-ready" 200 0
note '디버깅 메모: 스윕은 `<!-- ladder-resume: 1 -->` 를 남긴다'
note '인수인계 메모:
```
<!-- ladder-resume: 2 -->
```'
run
check "인용 ladder-resume: 개수 0 → 첫 재개" "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 1' >/dev/null 2>&1 && echo ok || echo no)"
check "인용 ladder-resume: 조기 승격 없음"    "$(no_ev escalated)"

# 인용 2개 + 진짜 1개 → 진짜 1개만 세어 2번째 재개(상한 2 안쪽)
setup "hold:ladder,agent-ready" 200 1
note '참고: `<!-- ladder-resume: 9 -->` 와 `<!-- ladder-resume: 8 -->` 는 인용일 뿐이다'
run
check "인용 2 + 진짜 1: attempt=2(승격 아님)" "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"

# 회귀: 코멘트 **끝에 맨몸으로** 붙은 정상 마커는 계속 세어진다(상한이 그대로 걸린다).
setup "hold:ladder,agent-ready" 200 2
run
check "맨몸 마커 2개: 상한 초과 승격(회귀 없음)" "$(has_ev escalated)"

# ⓔ 과다 필터 방증 — 산문이 한 줄 안에서 백틱 세 개를 **언급**해도(펜스를 여는 게 아니다)
#    그 사이의 맨몸 마커는 살아남는다. 펜스에 줄 앵커가 없으면 두 언급 사이가 통째로 지워져
#    재개 횟수가 **과소집계**되고, 상한이 영영 안 걸려 무한 재개가 된다(원래 버그보다 나쁘다).
setup "hold:ladder,agent-ready" 200 0
note '펜스는 ``` 로 연다
재개 1/2: 사다리 재시도 — <!-- ladder-resume: 1 --><!-- bodat:worker -->
닫을 때도 ``` 를 쓴다'
run
check "줄 중간 백틱셋 언급 사이의 맨몸 마커: 그대로 센다(attempt=2)" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"

# ⓕ 세 번째 지점 — `policy-review` 를 **인용만** 한 코멘트는 재심으로 세지 않는다.
#    이 방향의 오탐이 셋 중 가장 위험하다: 거짓 `reviewed` 는 사람 정책 게이트를 실제 재심
#    없이 통과시키고, 그 이슈는 아무도 다시 묻지 않는다(조용한 유실).
setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note '메모: 재심 코멘트는 `<!-- policy-review: kept -->` 마커를 남긴다(아직 안 남겼다)'
run
check "인용 policy-review: 재심으로 안 센다(due 유지)" "$(has_ev policy_review_due)"

# ── (#197 반송) 백틱 구분자 **길이 맞춤** — 다섯 형태 × 세 판정 지점 ────────
# 첫 회차의 인라인 패스는 백틱을 **하나씩** 짝지었다. 그러면 짝수 길이 구분자(백틱 2개로
# 여는 스팬)가 "빈 스팬 두 개" 로 갈려 **알맹이(마커)만 맨몸으로 남는다** — 인용인데 신호로
# 세진다(마감 검증 실측: 네 형태 중 이중 백틱만 `마커로 셈=true`). CommonMark 의 코드 스팬은
# 여는 백틱 런과 **같은 길이**의 닫는 런까지가 한 스팬이므로 그 규칙으로 맞춘다.
# 아래는 다섯 형태(단일·이중·삼중 백틱 인용 · 펜스 · 맨몸)를 **세 판정 지점 모두**
# (ladder-resume 개수 · hold-note 경계 · policy-review 재심)에서 무는 격자다.
# 되돌리면(백틱 하나씩 짝짓기) `[double]` 줄만 빨개진다 — 뮤테이션 방증은 PR 본문에.

quoted_note() {  # quoted_note <형태> <마커> → 그 마커를 <형태>로 인용한 코멘트 본문
  case "$1" in
    single) printf '메모: `%s` 를 남긴다' "$2" ;;
    double) printf '메모: ``%s`` 를 남긴다' "$2" ;;
    triple) printf '메모: ```%s``` 를 남긴다' "$2" ;;
    fence)  printf '메모: 아래 형태로 남긴다\n```\n%s\n```' "$2" ;;
    *)      echo "quoted_note: 알 수 없는 형태 $1" >&2; return 1 ;;
  esac
}

for form in single double triple fence; do
  # ① ladder-resume 개수 — 인용은 재개 횟수를 올리지 않는다(조기 승격 금지)
  setup "hold:ladder,agent-ready" 200 0
  note "$(quoted_note "$form" '<!-- ladder-resume: 1 -->')"
  run
  check "[$form] 인용 ladder-resume: 안 센다(attempt=1)" \
    "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 1' >/dev/null 2>&1 && echo ok || echo no)"
  check "[$form] 인용 ladder-resume: 조기 승격 없음" "$(no_ev escalated)"

  # ② hold-note 경계 — 인용은 새 에피소드 경계가 아니다
  #    (#174 형태: 인용된 hold-note 과 **진짜** 재심 마커가 한 코멘트 안에 공존)
  setup "hold:policy,agent-ready" 200 0
  note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
  note "$(quoted_note "$form" '<!-- hold-note: policy -->')
<!-- policy-review: kept --><!-- bodat:worker -->"
  run
  check "[$form] 인용 hold-note: 경계 아님(due 재발 없음)" "$(no_ev policy_review_due)"

  # ③ policy-review — 인용만 한 코멘트는 재심이 아니다(거짓 reviewed = 조용한 유실)
  setup "hold:policy,agent-ready" 200 0
  note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
  note "$(quoted_note "$form" '<!-- policy-review: kept -->')"
  run
  check "[$form] 인용 policy-review: 재심으로 안 센다(due 유지)" "$(has_ev policy_review_due)"
done

# 다섯째 형태 = **맨몸**(대조군). 세 지점 모두 반대 방향으로 나와야 한다 — 인용 제거가
# **더** 지우는 쪽으로 틀리면(맨몸 마커 유실) 상한이 안 걸려 원래 버그보다 나쁘다.
setup "hold:ladder,agent-ready" 200 0
note "재개 1/2: 사다리 재시도 <!-- ladder-resume: 1 --><!-- bodat:worker -->"
run
check "[bare] 맨몸 ladder-resume: 센다(attempt=2)" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"

setup "hold:policy,agent-ready" 200 0
note "재심: 지난 홀드는 사람 몫 유지 <!-- policy-review: kept --><!-- bodat:worker -->"
note "사람 확인(policy): 이번엔 C인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "[bare] 맨몸 hold-note: 새 경계로 센다(due)" "$(has_ev policy_review_due)"

setup "hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note "재심: 사람 몫 유지 <!-- policy-review: kept --><!-- bodat:worker -->"
run
check "[bare] 맨몸 policy-review: 재심으로 센다(due 없음)" "$(no_ev policy_review_due)"

# ── (#197 반송 attempt3) 가변 길이 펜스·백틱 런 경계 — 17건 격자 ───────────────
# 마감 검증 BLOCKER: 인라인은 닫는 런의 **뒤만** 보고(앞쪽 최대런 여부를 안 물어) 더 긴
# 런의 접미부를 짧은 스팬의 닫기로 오인했고, 펜스는 여는 문자·길이를 안 물고 닫는 줄 뒤에
# 아무 텍스트나 허용해 조기 종료했다. 위 두 회차는 매번 지적된 한 사례만 닫아 같은 축에서
# 반복됐다 — 이번엔 `unquoted` 정의를 스크립트에서 그대로 뽑아(손타이핑 대조 금지) CommonMark
# 규칙 그대로의 17건을 **직접** 문다(세 판정 지점은 전부 이 정의 하나를 공유하므로 — 위
# 동기화 검사로 이미 보장 — 여기서 한 번만 확인하면 충분하다).
grid_unq=$(grep -o 'def unquoted:.*;' "$DIR/resume-sweep.sh" | head -1)
check "격자: 스크립트에 인용 제거 정의(def unquoted)" "$([ -n "$grid_unq" ] && echo ok || echo no)"

GRID_MARKER='<!-- ladder-resume: 1 -->'

grid_check() {  # grid_check <label> <want:true|false> <text>
  local label="$1" want="$2" text="$3" got
  got=$(printf '%s' "$text" \
    | jq -Rs "$grid_unq"' (unquoted | test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))')
  check "[격자] $label (want=$want)" "$([ "$got" = "$want" ] && echo ok || echo no)"
}

grid_check "맨몸 마커" \
  true "$(printf '그냥 텍스트 %s' "$GRID_MARKER")"

grid_check "단일 백틱" \
  false "$(printf '`%s`' "$GRID_MARKER")"

grid_check "이중 백틱" \
  false "$(printf '``%s``' "$GRID_MARKER")"

grid_check "삼중 인라인" \
  false "$(printf '```%s```' "$GRID_MARKER")"

grid_check "이중런 안 삼중런" \
  false "$(printf '``foo ```x``` %s bar``' "$GRID_MARKER")"

grid_check "정상 삼중 펜스" \
  false "$(printf '```\n%s\n```' "$GRID_MARKER")"

grid_check "펜스 언어태그" \
  false "$(printf '```bash\n%s\n```' "$GRID_MARKER")"

grid_check "들여쓴 펜스" \
  false "$(printf '  ```\n  %s\n  ```' "$GRID_MARKER")"

grid_check "닫는펜스 아닌 줄" \
  false "$(printf '```\n``` not-a-close\n%s\n```' "$GRID_MARKER")"

grid_check "사중 펜스 안 삼중줄" \
  false "$(printf '````\n```\n%s\n````' "$GRID_MARKER")"

grid_check "혼재(인용+맨몸)" \
  true "$(printf '메모: `%s` 를 남긴다. 실제로는 %s' "$GRID_MARKER" "$GRID_MARKER")"

grid_check "닫히지 않은 백틱" \
  true "$(printf '` 이건 안 닫힌 백틱입니다 %s' "$GRID_MARKER")"

grid_check "펜스 둘 사이 맨몸" \
  true "$(printf '```\ndecoy code\n```\n\n%s\n\n```\ndecoy2\n```' "$GRID_MARKER")"

grid_check "물결 펜스" \
  false "$(printf '~~~\n%s\n~~~' "$GRID_MARKER")"

grid_check "닫는 펜스가 더 김" \
  false "$(printf '```\n%s\n````' "$GRID_MARKER")"

grid_check "펜스 미닫힘(문서 끝까지)" \
  false "$(printf '```\n%s' "$GRID_MARKER")"

grid_check "물결 펜스로 백틱 펜스 닫기 시도" \
  false "$(printf '```\n%s\n~~~' "$GRID_MARKER")"

# g18 (#197 반송 attempt4 회귀): 줄 머리의 인라인 삼중 백틱은 CommonMark 상 펜스가 아니다
# (백틱 펜스의 info string 엔 백틱이 못 온다 — 물결 펜스에는 이 제약이 없다). attempt3 의
# 펜스 정규식은 이 제약을 안 봐서 줄 첫머리의 코드 스팬을 "안 닫힌 펜스"로 읽고 `$` 대안으로
# 문서 끝까지 지웠다 — 뒤따르는 맨몸 마커가 함께 사라져 수용 기준 2번(맨몸 마커는 계속
# 세어진다)이 깨졌다(#197 마감 검증 attempt4 실측: `policy-review: kept` 유실 →
# policy_review_due 매 틱 재발, 과소 카운트 방향의 영구 반복).
grid_check "g18 줄머리 인라인 삼중백틱 뒤 맨몸 마커" \
  true "$(printf '```example``` 라는 인라인 코드입니다.\n본문 설명.\n%s' "$GRID_MARKER")"

# ── (#230, #197 후속) 세 구석 — CommonMark 규칙을 말로 적고 그 규칙으로 격자를 세운다 ──
# h1 (인라인 코드 스팬, CommonMark §6.1): 코드 스팬은 여는 백틱 런과 **정확히 같은 길이**의
#   닫는 런으로 닫힌다. 길이가 다른 런은 스팬을 안 연다(코드가 아니다 → 마커를 센다). 여는
#   런은 그 위치에서 뽑을 수 있는 **최대런**이어야 한다(런의 일부만 여는 건 CommonMark 에
#   없다) — 그래서 여는 런은 앞뒤 모두 백틱이 없는 최대련으로 **고정**되어야 하고(축소
#   백트래킹 금지), 그 고정된 길이와 정확히 같은(앞뒤에 백틱이 안 붙은) 닫는 런만 스팬을
#   닫는다.
# h2 (펜스, CommonMark §4.5): 펜스는 **원문에 나온 순서대로** 연다/닫는다 — 물결 펜스 열림은
#   같은 종류(물결)의, 길이 이상인 닫는 줄에서만 닫히고, 그 사이의 어떤 텍스트(다른 종류의
#   펜스 구분자 포함)도 전부 **펜스의 내용**이다. 백틱 펜스와 물결 펜스는 서로의 내용물을
#   닫지 못한다(종류가 다르면 짝이 아니다).
# h3 (줄 경계 정규화): CommonMark 의 "줄"은 개행 관례(LF·CRLF·CR)에 무관하다 — 닫는 펜스 뒤
#   허용되는 공백은 그 줄의 **끝**까지이고, CRLF 문서에서 그 끝은 `\r` 앞이다. 매칭 전
#   `\r\n`→`\n` 정규화는 이 무관성을 구현으로 옮긴 것뿐, 규칙을 바꾸지 않는다.
#
# 되돌리면(h1: 축소 백트래킹 허용 / h2: 두 gsub 로 분리 / h3: CRLF 정규화 제거) **해당
# 픽스처만** 빨개져야 한다 — 뮤테이션 방증 로그는 PR 본문에 붙인다.

grid_check "h1 여는3런+닫는2런: 짧은 닫는 런과 안 짝지어진다(마커를 센다)" \
  true "$(printf '```%s`` 뒤' "$GRID_MARKER")"

grid_check "h1 여는2런+닫는3런: 반대 방향 회귀(계속 마커를 세야 한다)" \
  true "$(printf '``%s``` 뒤' "$GRID_MARKER")"

grid_check "h2 물결 펜스 안 단독 백틱 줄: 안쪽은 내용, 마커는 실제 물결 닫힘 뒤" \
  true "$(printf '~~~\n```\nexample\n~~~\n%s' "$GRID_MARKER")"

grid_check "h2 대칭: 백틱 펜스 안 단독 물결 줄" \
  true "$(printf '```\n~~~\nexample\n```\n%s' "$GRID_MARKER")"

grid_check "h3 CRLF 본문의 정상 닫힌 펜스 뒤 맨몸 마커" \
  true "$(printf '```\r\ncode\r\n```\r\n%s' "$GRID_MARKER")"

# ── (#265) 정지 미러 정리 — 사람이 이슈에서만 푼 홀드의 PR 사본을 뗀다 ──────
# 기계 정지는 이슈와 PR **양쪽**에 붙는데(#244 가 보존 대상으로 적은 규약) 사람이 푸는
# 경로엔 PR 사본을 되돌리는 자리가 없었다 — 그 PR 은 네 게이트(#242·#262)에서 확정적으로
# 빠지고 이슈는 이미 깨끗해 needs-human 칸에도 안 뜬다. 격자를 **한 번의 실행**으로 돌려
# 칸끼리 새지 않는 것까지 함께 본다.
#
#   PR / 이슈            want
#   ──────────────────   ────────────────────────────────────────────────
#   201 / 301 정지 無    무편집 (뗄 것이 없다)
#   202 / 302 정지 無    **편집** — PR 정지 라벨만 빠지고 flow:verify 는 남는다
#   203 / 303 정지 有    무편집 — 살아 있는 사람 게이트를 벗겨내지 않는다
#   204 / 304 정지 有    무편집 (PR 에 뗄 것도 없다)
#   205 / 305 CLOSED     **편집** — 이슈만 닫힌 경로도 같은 정리 대상
#   206 / (연결 없음)    무편집 — 대조할 이슈가 없다(transition.sh 의 `issue=-` 홀드)
#   207 / 307 정지 無    **편집** — `needs-human` 없이 `hold:*` 만 남아도 대상(#244 대비)
#   208 / 308 정지 無    무편집 — head 는 agent 인데 **Closes 링크가 없다**(`Refs #N` 전용).
#                        짝이 증명 안 됐으므로 PR 에만 정지가 남는 게 정상일 수 있다
#   209 / 309 정지 無    무편집 — head 가 `feat/*`(사람 세션 PR). 사람이 직접 붙였을 수
#                        있는 표식을 루프가 떼지 않는다(②갈래와 같은 규율)
#   210 / 310 정지 無    **편집** — 열거에 없는 `hold:<새사유>` 도 **접두**로 잡는다.
#                        네 게이트가 접두로 보므로(#242) 여기만 열거면 그 PR 이 조용히 좌초한다
mirror_prs() { printf '%s' "$1" > "$tmp/mirror.prs.json"; }
mirror_issue() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$tmp/mirror.issues"; }
# (#265 ⑷) 라벨 이벤트 이력 픽스처 — `<ev>|<라벨>|<시각>` 을 `;` 로 잇는다. `__NONE__` = 이력 없음.
mirror_events() { printf '%s %s\n' "$1" "$2" >> "$tmp/mirror.events"; }
mpl() {  # mpl <PR번호> — 그 PR 의 현재 라벨 콤마목록
  jq -r --arg n "$1" '.[] | select(.number == ($n|tonumber)) | [.labels[].name] | join(",")' \
    "$tmp/mirror.prs.json"
}
mev() {  # mev <PR번호> — 그 PR 의 mirror_cleared 이벤트(없으면 빈 문자열)
  printf '%s' "$out" | jq -c --arg n "$1" 'select(.event=="mirror_cleared" and .pr==($n|tonumber))' 2>/dev/null
}

setup "needs-human,hold:policy" 10 0
mirror_prs '[
 {"number":201,"headRefName":"agent/issue-301","labels":[{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":301}]},
 {"number":202,"headRefName":"agent/issue-302","labels":[{"name":"needs-human"},{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":302}]},
 {"number":203,"headRefName":"agent/issue-303","labels":[{"name":"needs-human"},{"name":"hold:conflict"}],
  "closingIssuesReferences":[{"number":303}]},
 {"number":204,"headRefName":"agent/issue-304","labels":[{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":304}]},
 {"number":205,"headRefName":"agent/issue-305","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":305}]},
 {"number":206,"headRefName":"feat/사람이-연-브랜치","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[]},
 {"number":207,"headRefName":"agent/issue-307","labels":[{"name":"hold:ladder"}],
  "closingIssuesReferences":[{"number":307}]},
 {"number":208,"headRefName":"agent/issue-308","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[]},
 {"number":209,"headRefName":"feat/사람이-연-브랜치-309","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":309}]},
 {"number":210,"headRefName":"agent/issue-310","labels":[{"name":"hold:manual"}],
  "closingIssuesReferences":[{"number":310}]}
]'
mirror_issue 301 OPEN "agent-ready,flow:verify"
mirror_issue 302 OPEN "agent-ready,flow:verify"
mirror_issue 303 OPEN "agent-ready,needs-human,hold:conflict"
mirror_issue 304 OPEN "agent-ready,needs-human,hold:ladder"
mirror_issue 305 CLOSED "__NONE__"
mirror_issue 307 OPEN "agent-ready"
mirror_issue 308 OPEN "agent-ready"
mirror_issue 309 OPEN "agent-ready"
mirror_issue 310 OPEN "agent-ready"
run
check "미러 격자: exit 0"                    "$([ "$RC" = 0 ] && echo ok || echo no)"
check "미러 ①(둘 다 없음): 무편집"           "$(none 'pr edit 201')"
check "미러 ①: 이벤트 없음"                  "$([ -z "$(mev 201)" ] && echo ok || echo no)"
check "미러 ②(PR 에만 남음): 정지 라벨 제거" "$([ "$(mpl 202)" = "flow:verify" ] && echo ok || echo no)"
check "미러 ②: mirror_cleared 이벤트"        "$([ -n "$(mev 202)" ] && echo ok || echo no)"
check "미러 ②: 이벤트에 이슈·PR·제거 목록"   "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==202) | .number==302 and .issue_state=="OPEN" and .removed=="hold:policy,needs-human"' >/dev/null 2>&1 && echo ok || echo no)"
check "미러 ③(이슈에 정지 잔존): 무편집"     "$(none 'pr edit 203')"
check "미러 ③: PR 라벨 그대로"               "$([ "$(mpl 203)" = "needs-human,hold:conflict" ] && echo ok || echo no)"
check "미러 ③: 이벤트 없음"                  "$([ -z "$(mev 203)" ] && echo ok || echo no)"
check "미러 ④(이슈에만 정지): 무편집"        "$(none 'pr edit 204')"
check "미러 ⑤(이슈 CLOSED): 정리된다"        "$([ "$(mpl 205)" = "" ] && echo ok || echo no)"
check "미러 ⑤: 이벤트에 CLOSED 가 실린다"    "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==205) | .issue_state=="CLOSED"' >/dev/null 2>&1 && echo ok || echo no)"
check "미러 ⑥(연결 이슈 없음): 무편집"       "$(none 'pr edit 206')"
check "미러 ⑥: PR 라벨 그대로"               "$([ "$(mpl 206)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 ⑦(hold 만): 정리된다"             "$([ "$(mpl 207)" = "" ] && echo ok || echo no)"
check "미러 ⑦: needs-human 없이 hold 만도 대상" "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==207) | .removed=="hold:ladder"' >/dev/null 2>&1 && echo ok || echo no)"
# 없는 라벨을 --remove-label 로 넘기면 gh 가 편집 **전체**를 실패시킨다(transition.sh:67) —
# PR 이 실제로 달고 있는 정지 라벨만 인자에 싣는지 호출 로그로 못 박는다.
check "미러: 안 달린 정지 라벨은 remove 인자에 없다" \
  "$(grep -q 'pr edit 207 .*--remove-label needs-human' "$tmp/gh.log" && echo no || echo ok)"
# 짝짓기 좁히기 — 경보(loop-status)와 **같은 규칙**이어야 한다. 넓으면 사람이 붙인 표식·
# `issue=-` 로 붙은 정상 홀드를 루프가 벗겨낸다.
check "미러 ⑧(Closes 링크 없음): 무편집"     "$(none 'pr edit 208')"
check "미러 ⑧: PR 라벨 그대로"               "$([ "$(mpl 208)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 ⑧: 이슈 조회조차 안 한다"        "$(none 'issue view 308')"
check "미러 ⑨(사람 세션 head): 무편집"       "$(none 'pr edit 209')"
check "미러 ⑨: PR 라벨 그대로"               "$([ "$(mpl 209)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 ⑨: 이슈 조회조차 안 한다"        "$(none 'issue view 309')"
# 열거가 아니라 접두 — 네 게이트(#242)가 `hold:` 접두로 보므로 사유가 늘어도 안 깨져야 한다.
check "미러 ⑩(hold:<새사유>): 접두로 잡는다" "$([ "$(mpl 210)" = "" ] && echo ok || echo no)"
check "미러 ⑩: removed 에 새 사유"           "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==210) | .removed=="hold:manual"' >/dev/null 2>&1 && echo ok || echo no)"

# ── (#265 재검증) 짝은 **head 의 N 이 closes 안에 있을 때만** · 편집은 closes 전건이 깨끗할 때만 ──
# 위 격자의 PR 은 전부 closes 가 한 건이라 `[0]` 과 브랜치의 N 이 우연히 같았다. 이 레포
# 실데이터엔 **순서가 뒤집힌** PR 이 있다(PR #113 head=`agent/issue-109` refs=`[108,109]`) —
# `[0]` 을 무조건 짝으로 쓰면 브랜치의 이슈가 아닌 쪽을 보고 **살아 있는 사람 게이트를 벗긴다**.
# 그리고 짝 인정만으로는 **묶음 디스패치**가 안 닫힌다: `Closes #A`·`Closes #B` 를 단 PR 에
# 전이는 이슈 인자를 하나만 받아(`transition.sh`) #B 에만 정지가 붙을 수 있으므로, 편집은
# **closes 전건이 정지 라벨 0개일 때만** 한다(짝은 메시지·이벤트의 대표 번호일 뿐이다).
#
#   PR / head / closes             이슈                         want
#   ─────────────────────────────  ──────────────────────────  ────────────────────────────
#   220 agent/issue-342 [399,342]  399 깨끗 · 342 정지 有       무편집 — #113 모양(순서 역전)
#   221 agent/issue-343 [395]      브랜치의 N 이 closes 밖      무편집 · 이슈 조회조차 안 함
#   222 agent/issue-344 [398,344]  둘 다 깨끗                   **편집** · 짝은 398 이 아니라 344
#   223 agent/issue-345 [345,397]  345 깨끗 · 397 정지 有       무편집 — 묶음 디스패치 갈래
#   224 agent/issue-346 [346]      346 이 `hold:policy` **만**  무편집 — has_stop 접두 갈래
setup "needs-human,hold:policy" 10 0
mirror_prs '[
 {"number":220,"headRefName":"agent/issue-342","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":399},{"number":342}]},
 {"number":221,"headRefName":"agent/issue-343","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":395}]},
 {"number":222,"headRefName":"agent/issue-344","labels":[{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":398},{"number":344}]},
 {"number":223,"headRefName":"agent/issue-345","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":345},{"number":397}]},
 {"number":224,"headRefName":"agent/issue-346","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":346}]}
]'
mirror_issue 399 OPEN "agent-ready"
mirror_issue 395 OPEN "agent-ready"
mirror_issue 398 OPEN "agent-ready"
mirror_issue 397 OPEN "agent-ready,hold:policy"
mirror_issue 342 OPEN "agent-ready,needs-human,hold:conflict"
mirror_issue 343 OPEN "agent-ready"
mirror_issue 344 OPEN "agent-ready"
mirror_issue 345 OPEN "agent-ready"
mirror_issue 346 OPEN "agent-ready,hold:policy"
run
check "미러 격자2: exit 0"                      "$([ "$RC" = 0 ] && echo ok || echo no)"
# ① 순서 역전(#113 모양) — `[0]`(#399)만 보면 깨끗해 보이지만 브랜치의 이슈 #342 는 정지 중이다
check "미러 ⑪(closes 순서 역전): 무편집"        "$(none 'pr edit 220')"
check "미러 ⑪: PR 라벨 그대로"                  "$([ "$(mpl 220)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 ⑪: 이벤트 없음"                     "$([ -z "$(mev 220)" ] && echo ok || echo no)"
# ② 브랜치의 N 이 closes 에 없다 → 짝이 성립 안 함(무편집·무조회). `Refs #N` 전용 PR 과
#    같은 자리다 — 짝이 증명 안 된 채 남은 정지는 정상일 수 있다.
check "미러 ⑫(브랜치 N 이 closes 밖): 무편집"   "$(none 'pr edit 221')"
check "미러 ⑫: 이슈 조회조차 안 한다(343)"      "$(none 'issue view 343')"
check "미러 ⑫: 다른 closes 도 조회 안 한다(395)" "$(none 'issue view 395')"
# ③ 전부 깨끗하면 종전대로 정리된다 — 짝은 `[0]`(#398)이 아니라 **브랜치의 이슈 #344** 다
check "미러 ⑬(둘 다 깨끗): 정리된다"            "$([ "$(mpl 222)" = "flow:verify" ] && echo ok || echo no)"
check "미러 ⑬: 이벤트의 짝은 [0] 이 아니라 344" "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==222) | .number==344' >/dev/null 2>&1 && echo ok || echo no)"
# ④ 묶음 디스패치 — 짝(#345)은 깨끗해도 같은 PR 이 닫는 #397 에 사람 게이트가 살아 있다
check "미러 ⑭(묶음 디스패치의 딴 이슈 정지): 무편집" "$(none 'pr edit 223')"
check "미러 ⑭: PR 라벨 그대로"                  "$([ "$(mpl 223)" = "needs-human,hold:policy" ] && echo ok || echo no)"
# ⑤ has_stop 의 **접두 갈래 단독** — `needs-human` 없이 `hold:policy` 만 남은 이슈.
#    이 칸이 없으면(#244 로 needs-human 이 기계 정지에서 빠진 뒤) 접두 갈래를 열거로
#    되돌리는 리팩터가 전건 초록인 채로 살아 있는 홀드의 PR 미러를 떼기 시작한다.
check "미러 ⑮(이슈가 hold: 접두만): 무편집"     "$(none 'pr edit 224')"
check "미러 ⑮: PR 라벨 그대로"                  "$([ "$(mpl 224)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 ⑮: 이벤트 없음"                     "$([ -z "$(mev 224)" ] && echo ok || echo no)"

# ── (#331 쌍둥이 정합) ⑶ 전건 게이트는 **CLOSED 도** 판정한다 ──────────────
# 여기 `read_labels_state` 는 닫는 이슈를 번호로 실제 조회하므로 상태와 무관하게 라벨을
# 본다(상태는 이벤트에 실을 뿐 판정에 쓰지 않는다 — 그 함수 주석). 경보(`loop-status.sh`
# 의 mirror 블록)는 **이미 받은 열린 이슈 목록 안에서만** 보고 있어서 아래 첫 칸에서 두
# 술어가 갈렸다 — 경보 warn 0 인데 여기서는 편집(#293 마감 검증의 비차단 WARN).
# **같은 번호·같은 모양의 픽스처를 `loop-status.test.sh` 도 들고 있다**(거기 #93·#94) —
# 두 스위트가 같은 입력에 같은 판정을 낸다는 것이 이 절의 주장이다.
#
#   PR / head / closes                  이슈                        want
#   ──────────────────────────────────  ─────────────────────────  ──────────────────
#   193 agent/issue-93 [93, 97]         93 OPEN 깨끗 · 97 CLOSED 깨끗   **편집**
#   194 agent/issue-94 [94, 96]         94 OPEN 깨끗 · 96 CLOSED 정지 有  무편집
setup "needs-human,hold:policy" 10 0
mirror_prs '[
 {"number":193,"headRefName":"agent/issue-93","labels":[{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":93},{"number":97}]},
 {"number":194,"headRefName":"agent/issue-94","labels":[{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":94},{"number":96}]}
]'
mirror_issue 93 OPEN "agent-ready,flow:verify"
mirror_issue 97 CLOSED "agent-ready"
mirror_issue 94 OPEN "agent-ready,flow:verify"
mirror_issue 96 CLOSED "agent-ready,needs-human,hold:policy"
run
check "쌍둥이: exit 0"                          "$([ "$RC" = 0 ] && echo ok || echo no)"
check "쌍둥이 ①(닫힌 짝도 깨끗): 정리된다"       "$([ "$(mpl 193)" = "flow:verify" ] && echo ok || echo no)"
check "쌍둥이 ①: 짝은 브랜치의 이슈 #93"         "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==193) | .number==93' >/dev/null 2>&1 && echo ok || echo no)"
check "쌍둥이 ①: CLOSED 인 #97 도 실제로 조회한다" "$(some 'issue view 97')"
check "쌍둥이 ②(닫힌 이슈에 정지 잔존): 무편집"  "$(none 'pr edit 194')"
check "쌍둥이 ②: PR 라벨 그대로"                "$([ "$(mpl 194)" = "hold:policy,flow:verify" ] && echo ok || echo no)"
check "쌍둥이 ②: 이벤트 없음"                    "$([ -z "$(mev 194)" ] && echo ok || echo no)"

# 묶음 디스패치의 **딴** closes 이슈 조회가 실패해도 떼지 않는다(fail-safe 는 짝과 같다)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":225,"headRefName":"agent/issue-347","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":347},{"number":396}]}]'
mirror_issue 347 OPEN "agent-ready"
mirror_issue 396 __FAIL__ ""
run
check "미러 묶음 조회 실패: 무편집"             "$(none 'pr edit 225')"
check "미러 묶음 조회 실패: warn"               "$(saysl '이슈 #396 라벨 조회 실패')"

# 이슈 조회 실패 → **떼지 않고** warn (fail-safe: 사람 게이트를 벗겨내는 방향으로 틀리지 않는다)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":211,"headRefName":"agent/issue-311","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":311}]}]'
mirror_issue 311 __FAIL__ ""
run
check "미러 이슈 조회 실패: 무편집"          "$(none 'pr edit 211')"
check "미러 이슈 조회 실패: 라벨 그대로"     "$([ "$(mpl 211)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 이슈 조회 실패: warn"            "$(saysl '연결 이슈 #311 라벨 조회 실패')"
check "미러 이슈 조회 실패: warn_after_edit 아님" "$(no_ev warn_after_edit)"

# PR 편집 실패 → 아직 아무것도 안 바뀌었다 → warn (warn_after_edit 아님)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":212,"headRefName":"agent/issue-312","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":312}]}]'
mirror_issue 312 OPEN "agent-ready"
STUB_MIRROR_EDIT_FAIL=1
run
check "미러 편집 실패: 라벨 그대로"          "$([ "$(mpl 212)" = "needs-human,hold:policy" ] && echo ok || echo no)"
check "미러 편집 실패: warn"                 "$(saysl 'PR #212 정지 미러 해제 실패')"
check "미러 편집 실패: warn_after_edit 아님" "$(no_ev warn_after_edit)"

# readback 조회 실패 → 쓰기는 이미 나갔다 → warn_after_edit
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":213,"headRefName":"agent/issue-313","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":313}]}]'
mirror_issue 313 OPEN "agent-ready"
STUB_MIRROR_READBACK="__FAIL__"
run
check "미러 readback 실패: warn_after_edit"  "$(has_ev warn_after_edit)"
check "미러 readback 실패: mirror_cleared 아님" "$([ -z "$(mev 213)" ] && echo ok || echo no)"

# readback 에 정지 라벨이 남아 있다 → warn_after_edit (성공으로 위장하지 않는다)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":214,"headRefName":"agent/issue-314","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":314}]}]'
mirror_issue 314 OPEN "agent-ready"
STUB_MIRROR_READBACK="needs-human"
run
check "미러 readback 불일치: warn_after_edit" "$(saysl 'PR #214 정지 미러 readback 불일치')"
check "미러 readback 불일치: mirror_cleared 아님" "$([ -z "$(mev 214)" ] && echo ok || echo no)"

# 경합 — `transition.sh` 는 PR 을 먼저, 이슈를 나중에 고친다. 그래서 "PR 엔 이미 붙었고
# 이슈엔 아직" 인 창이 있고, 편집 **전** 재조회로는 그 창을 못 닫는다(그때 이슈는 정말
# 깨끗하다). 편집 뒤 한 번 더 읽어 정지가 생겼으면 성공으로 위장하지 않는다.
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":216,"headRefName":"agent/issue-316","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":316}]}]'
mirror_issue 316 OPEN "agent-ready"
STUB_MIRROR_RACE="agent-ready,needs-human,hold:conflict"
run
check "미러 경합: mirror_cleared 아님"       "$([ -z "$(mev 216)" ] && echo ok || echo no)"
check "미러 경합: warn_after_edit"           "$(saysl '이슈 #316 에 정지 라벨이 생겼다')"

# 편집 뒤 이슈 재조회 실패 → 경합 여부를 모른다(성공으로 접지 않는다)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":217,"headRefName":"agent/issue-317","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":317}]}]'
mirror_issue 317 OPEN "agent-ready"
STUB_MIRROR_RACE="__FAIL__"
run
check "미러 경합 재조회 실패: mirror_cleared 아님" "$([ -z "$(mev 217)" ] && echo ok || echo no)"
check "미러 경합 재조회 실패: warn_after_edit"     "$(saysl '이슈 #317 재조회 실패')"

# 목록 조회 실패 → "정리 대상 없음" 으로 위장하지 않는다(exit 2 + stderr)
setup "needs-human,hold:policy" 10 0
mirror_prs '[{"number":215,"headRefName":"agent/issue-315","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":315}]}]'
mirror_issue 315 OPEN "agent-ready"
STUB_MIRROR_LIST_FAIL=1
run
check "미러 목록 조회 실패: exit 2"          "$([ "$RC" = 2 ] && echo ok || echo no)"
check "미러 목록 조회 실패: stderr 한 줄"    "$(grep -q '정지 미러' "$tmp/err" && echo ok || echo no)"
check "미러 목록 조회 실패: 무편집"          "$(none 'pr edit 215')"

# ── (#265 재검증 attempt 3) 두 관문: 맨몸 needs-human · **양성 증거**(라벨 이벤트 이력) ──
# 지금까지의 술어는 전부 *부재*(이슈에 정지 라벨이 없다)였는데, 부재는 셋을 구분 못 한다:
# ⓐ 사람이 뗐다 ⓑ 기계가 뗐다 ⓒ **애초에 못 붙었다**. ⓒ 는 `transition.sh` 의 적용 순서가
# 만드는 실재 상태다(PR 먼저·이슈 나중 → 이슈 편집 실패). 그 칸을 그대로 떼면 살아 있는
# 홀드를 기계가 벗기고, `verify-held`·`closeout-blocked` 는 단계 라벨도 이미 뗀 뒤라 어느
# 루프도 못 집는 좌초가 된다. 그래서 이력으로 증명한다 — 존재가 아니라 **시각 비교**로
# (#225: 가장 늦은 것이 이긴다 · 같은 PR 이 두 번 홀드되면 옛 해제가 새 부분 실패를 위장).
# 한 번의 실행으로 `want` 열 전수 단언 — 칸끼리 새지 않는 것까지 함께 본다.
#
#   PR / 이슈 / 이력                              want
#   ────────────────────────────────────────────  ───────────────────────────────────────
#   230 / 330  PR 라벨이 맨몸 `needs-human`       무편집 + warn · 이슈 **조회조차 안 함**
#   231 / 331  이슈에 `unlabeled` 이력 없음(ⓒ)    무편집 + warn(부분 실패 의심)
#   232 / 332  이슈 해제가 PR 부착보다 **이르다**  무편집 + warn(옛 에피소드)
#   233 / 333  이슈 해제가 PR 부착보다 **늦다**    **편집** — 종전대로 정리된다
#   234 / 334  이슈 이력 조회 실패                무편집 + warn
#   235 / 335  PR 이력 조회 실패                  무편집 + warn
#   236 / 336  PR 에 `labeled` 이력 없음          무편집 + warn(이력 미상)
#   237 / 337  이슈 해제 == PR 부착(같은 초)      무편집 + warn(동시각은 증명이 아니다)
setup "needs-human,hold:policy" 10 0
mirror_prs '[
 {"number":230,"headRefName":"agent/issue-330","labels":[{"name":"needs-human"},{"name":"flow:ready"}],
  "closingIssuesReferences":[{"number":330}]},
 {"number":231,"headRefName":"agent/issue-331","labels":[{"name":"needs-human"},{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":331}]},
 {"number":232,"headRefName":"agent/issue-332","labels":[{"name":"hold:conflict"}],
  "closingIssuesReferences":[{"number":332}]},
 {"number":233,"headRefName":"agent/issue-333","labels":[{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":333}]},
 {"number":234,"headRefName":"agent/issue-334","labels":[{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":334}]},
 {"number":235,"headRefName":"agent/issue-335","labels":[{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":335}]},
 {"number":236,"headRefName":"agent/issue-336","labels":[{"name":"hold:policy"}],
  "closingIssuesReferences":[{"number":336}]},
 {"number":237,"headRefName":"agent/issue-337","labels":[{"name":"hold:ladder"}],
  "closingIssuesReferences":[{"number":337}]}
]'
mirror_issue 330 OPEN "agent-ready"
mirror_issue 331 OPEN "agent-ready"
mirror_issue 332 OPEN "agent-ready"
mirror_issue 333 OPEN "agent-ready"
mirror_issue 334 OPEN "agent-ready"
mirror_issue 335 OPEN "agent-ready"
mirror_issue 336 OPEN "agent-ready"
mirror_issue 337 OPEN "agent-ready"
# 이력 픽스처가 없는 번호는 스텁이 **정상 해제**로 답한다(PR labeled 2026-01-01 < 이슈
# unlabeled 2026-01-02) — 233 이 그 기본을 그대로 쓴다.
mirror_events 331 "__NONE__"                               # ⓒ — 이슈는 그 라벨을 받은 적이 없다
mirror_events 332 "unlabeled|hold:conflict|2025-12-01T00:00:00Z"   # 옛 에피소드의 해제
mirror_events 236 "__NONE__"                               # PR 쪽 부착 이력이 없다
mirror_events 337 "unlabeled|hold:ladder|2026-01-01T00:00:00Z"     # PR 부착과 **같은 초**
STUB_MIRROR_EVENTS_FAIL="334,235"
run
check "이력 격자: exit 0"                        "$([ "$RC" = 0 ] && echo ok || echo no)"
# ⑯ 맨몸 needs-human — 기계는 이 모양을 만들 수 없다(세 홀드 전이는 --reason 필수라 언제나
#    hold:<사유> 와 쌍이다). 사람이 머지 직전에 PR 에만 세운 브레이크를 루프가 떼면
#    closeout-eligible 의 유일한 제동이 풀린다. ②갈래가 이슈에 세운 규율과 같은 자리다.
check "⑯ 맨몸 needs-human: 무편집"               "$(none 'pr edit 230')"
check "⑯ PR 라벨 그대로"                         "$([ "$(mpl 230)" = "needs-human,flow:ready" ] && echo ok || echo no)"
check "⑯ warn 문구(사유 없음)"                   "$(saysl 'PR #230 정지 미러 — needs-human 사유 없음')"
check "⑯ mirror_cleared 아님"                    "$([ -z "$(mev 230)" ] && echo ok || echo no)"
check "⑯ 이슈 조회조차 안 한다"                  "$(none 'issue view 330')"
# ⑰ 양성 증거 없음 = 전이 부분 실패(ⓒ) — 이 칸이 이번 반송의 BLOCKER 다
check "⑰ 이력 없음(부분 실패): 무편집"           "$(none 'pr edit 231')"
check "⑰ PR 라벨 그대로"                         "$([ "$(mpl 231)" = "needs-human,hold:policy" ] && echo ok || echo no)"
#    보고되는 라벨은 결정적이다 — `mirror_row` 의 jq 가 정지 라벨을 `sort` 해서 넘기므로
#    `hold:policy` < `needs-human`(사전순) 이라 언제나 `hold:policy` 가 먼저 걸린다.
check "⑰ warn 문구(붙었다 떨어진 이력 없다)"     "$(saysl '이슈 #331 의 hold:policy: 붙었다 떨어진 이력이 없다')"
check "⑰ mirror_cleared 아님"                    "$([ -z "$(mev 231)" ] && echo ok || echo no)"
# ⑱ 존재만 보면 통과하는 칸 — 옛 에피소드의 해제가 새 부분 실패를 ⓐ 로 위장한다(#225)
check "⑱ 옛 에피소드 해제: 무편집"               "$(none 'pr edit 232')"
check "⑱ warn 문구(PR 부착보다 이르다)"          "$(saysl '해제(2025-12-01T00:00:00Z)가 PR 부착(2026-01-01T00:00:00Z)보다 이르다')"
check "⑱ mirror_cleared 아님"                    "$([ -z "$(mev 232)" ] && echo ok || echo no)"
# ⑲ 증거가 서면 종전대로 정리된다 — 새 관문이 정상 경로를 막지 않는다는 대조군
check "⑲ 정상 해제 이력: 정리된다"               "$([ "$(mpl 233)" = "flow:verify" ] && echo ok || echo no)"
check "⑲ mirror_cleared 이벤트"                  "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==233) | .number==333 and .removed=="hold:policy"' >/dev/null 2>&1 && echo ok || echo no)"
# ⑳㉑ 이력 조회 실패는 **증명 실패**다 — fail-safe 방향(떼지 않는다)은 이 갈래 전체와 같다
check "⑳ 이슈 이력 조회 실패: 무편집"            "$(none 'pr edit 234')"
check "⑳ warn 문구"                              "$(saysl '이슈 #334 라벨 이력 조회 실패')"
check "㉑ PR 이력 조회 실패: 무편집"              "$(none 'pr edit 235')"
check "㉑ warn 문구"                              "$(saysl 'PR #235 정지 미러 — PR 라벨 이력 조회 실패')"
check "㉒ PR 부착 이력 없음: 무편집"              "$(none 'pr edit 236')"
check "㉒ warn 문구"                              "$(saysl 'PR 의 hold:policy: 붙은 이력이 없다')"
check "㉓ 동시각은 증명이 아니다: 무편집"         "$(none 'pr edit 237')"
check "㉓ warn 문구(이르다 갈래로 접는다)"        "$(saysl '해제(2026-01-01T00:00:00Z)가 PR 부착(2026-01-01T00:00:00Z)보다 이르다')"
# 이력 관문은 전부 **편집 전** 실패다 — warn 이지 warn_after_edit 이 아니다
check "이력 관문: warn_after_edit 0건"           "$(no_ev warn_after_edit)"

# ── (#331) 계정 전체 모드의 레포 탐색 = 이슈 축 ∪ PR 축 ────────────────────
# ④ 정지 미러가 겨누는 상태는 정의상 **이슈는 깨끗하고 PR 에만** 정지 라벨이 남은 모양이라,
# `gh search issues` 축 하나로는 그 상태가 있는 레포를 **영영 못 찾는다**(실측: PR #293 자신이
# 두 라벨을 달고 있었는데 결과에 안 나왔다 · `ggqgga/BoDAC` 은 `needs-human` 이슈 0건).
# 여기 픽스처가 정확히 그 조건이다: 이슈 축 0건 · PR 축 1건.
setup "needs-human,hold:policy" 10 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
: > "$tmp/search"                          # 이슈 축 0건 — 실패가 아니라 진짜 0건(rc=0)
printf 'owner/prsonly\n' > "$tmp/search.prs"
mirror_prs '[{"number":401,"headRefName":"agent/issue-501",
  "labels":[{"name":"needs-human"},{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":501}]}]'
mirror_issue 501 OPEN "agent-ready,flow:verify"
run
check "㉒-d 합집합: PR 축만 있는 레포를 순회한다" "$(some 'pr list --repo owner/prsonly')"
# PR 축도 이슈 축 ㉒-b 와 같은 형태다 — `is:` 대신 `--state open` **플래그**(#236). 회귀하면
# "레포를 못 찾는다" 가 아니라 이 줄이 먼저 빨개져 원인(#236 재발)이 보인다.
check "㉒-d 합집합: PR 축도 --state open 플래그"  "$(some 'search prs label:needs-human .*--state open')"
check "㉒-d 합집합: PR 축도 is: 한정자 없음(#236)" "$(none 'search prs .*is:')"
check "㉒-d 합집합: ④ 교정까지 간다"              "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==401) | .number==501 and .removed=="hold:policy,needs-human"' >/dev/null 2>&1 && echo ok || echo no)"
check "㉒-d 합집합: PR 정지 라벨이 실제로 빠진다" "$([ "$(mpl 401)" = "flow:verify" ] && echo ok || echo no)"
check "㉒-d 합집합: exit 0"                       "$([ "$RC" = 0 ] && echo ok || echo no)"

# 대조 단언(뮤테이션 방증) — **합집합을 빼면** 같은 픽스처에서 아무 것도 안 난다. 이 사본은
# 라벨 루프(네 라벨 × 두 축, #244 와 합쳐진 형태)에서 PR 축 결과를 `search.raw` 에 붙이는
# 줄(`pr_hits=` 바로 다음 `cat`)만 버린 것(= #331 이전의 동작)이다. 픽스처와 단언이
# 그대로인 채 **코드만** 갈리므로, 새 테스트가 빨개지는 이유가 합집합 그 자체임을 고정한다.
mut="$sut_dir/resume-sweep.no-union.sh"
sed '/pr_hits=\$(grep -c \. "\$tmp\/search\.one"/{n;s|cat "\$tmp/search\.one" >> "\$tmp/search\.raw"|: # 뮤턴트: PR 축 결과를 버린다|;}' \
  "$sut_dir/resume-sweep.sh" > "$mut"
check "㉒-d 뮤턴트: 합집합 한 줄만 갈렸다" \
  "$([ "$(diff "$sut_dir/resume-sweep.sh" "$mut" | grep -c '^[<>]')" = 2 ] && echo ok || echo no)"
setup "needs-human,hold:policy" 10 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
: > "$tmp/search"
printf 'owner/prsonly\n' > "$tmp/search.prs"
mirror_prs '[{"number":401,"headRefName":"agent/issue-501",
  "labels":[{"name":"needs-human"},{"name":"hold:policy"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":501}]}]'
mirror_issue 501 OPEN "agent-ready,flow:verify"
run_sut "$mut"
check "㉒-d 대조: 합집합 없으면 레포를 못 찾는다" "$(none 'pr list --repo owner/prsonly')"
check "㉒-d 대조: mirror_cleared 없음"            "$([ -z "$(mev 401)" ] && echo ok || echo no)"
check "㉒-d 대조: PR 정지 라벨이 그대로 남는다"   "$([ "$(mpl 401)" = "needs-human,hold:policy,flow:verify" ] && echo ok || echo no)"
check "㉒-d 대조: 그런데 exit 0 — 조용한 좌초다"  "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── (#331) 호출(라벨 × 축)은 **각각** 실패를 가른다 — 빈 목록 ≠ 실패 ────────
# `gh search` 는 부차 레이트리밋에서 빈 출력 + rc=0 을 낸다. 그래서 판정은 출력 형태가
# 아니라 **종료 코드**다. 한쪽만 죽어도 중단한다 — 성공한 쪽만으로 도는 부분 스코프는
# "그 레포엔 멈춘 건이 없다" 와 구분되지 않는 조용한 축소이고, 이 갈래가 막으려는 해악이다.
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"; STUB_SEARCH_PRS_FAIL=1
run
check "PR 축 탐색 실패: exit 2"          "$([ "$RC" = 2 ] && echo ok || echo no)"
check "PR 축 탐색 실패: stderr 가 축을 밝힌다" "$(grep -q '탐색 실패(PR)' "$tmp/err" && echo ok || echo no)"
check "PR 축 탐색 실패: 무편집"          "$(none 'issue edit')"
check "PR 축 탐색 실패: 레포를 하나도 안 훑는다" "$(none 'issue list')"
# 이슈 축 실패도 축을 밝힌다(기존 ㉒ 의 `탐색 실패` 단언과 겹치되 축까지 못 박는다).
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"; STUB_SEARCH_FAIL=1
run
check "이슈 축 탐색 실패: exit 2"        "$([ "$RC" = 2 ] && echo ok || echo no)"
check "이슈 축 탐색 실패: stderr 가 축을 밝힌다" "$(grep -q '탐색 실패(이슈)' "$tmp/err" && echo ok || echo no)"
check "이슈 축 탐색 실패: PR 축을 부르지도 않는다" "$(none 'search prs')"
# 빈 목록은 실패가 **아니다** — 둘 다 0건이면 조용히 exit 0(스윕할 것이 없다).
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
: > "$tmp/search"; : > "$tmp/search.prs"
run
check "둘 다 0건: 실패가 아니다(exit 0)"  "$([ "$RC" = 0 ] && echo ok || echo no)"
check "둘 다 0건: 탐색 실패 문구 없음"    "$(grep -q '탐색 실패' "$tmp/err" && echo no || echo ok)"
check "둘 다 0건: 두 축을 다 부른다"      "$([ "$(counts 'search issues')" != 0 ] && [ "$(counts 'search prs')" != 0 ] && echo ok || echo no)"
# #244 의 세 라벨 + `hold:conflict`(#331 반송) = 네 라벨 × 두 축 = 8 쿼리다 — PR 축도 네 라벨
# 각각을 묻는다.
check "둘 다 0건: 네 라벨 × 두 축 = 8 쿼리" "$([ "$(counts 'search issues')" = 4 ] && [ "$(counts 'search prs')" = 4 ] && echo ok || echo no)"
check "둘 다 0건: PR 축도 hold:ladder 를 묻는다" "$(some 'search prs label:hold:ladder .*--state open')"
check "둘 다 0건: PR 축도 hold:policy 를 묻는다" "$(some 'search prs label:hold:policy .*--state open')"
check "둘 다 0건: PR 축도 hold:conflict 를 묻는다" "$(some 'search prs label:hold:conflict .*--state open')"
check "둘 다 0건: PR 축도 is: 한정자 없음(#236)" "$(none 'search prs .*is:')"

# ── (#331 반송) 탐색 집합의 4번째 라벨 = `hold:conflict` — 이슈 축 · PR 축 각 1건 ────
# `closeout-blocked --reason conflict` 등은 #244 이후 `hold:conflict` **하나만** 붙인다(`needs-human`
# 동반 없음). 그래서 그 레포에 다른 정지가 0건이면 `needs-human`·`hold:ladder`·`hold:policy`
# 어느 질의로도 안 잡혀 계정 전체 모드에서 **영구 배제**였다 — main #244 의 선재 사각을 PR 축이
# 그대로 복제한 것(마감 검증 codex P1, 사람 결정 (a): 이 PR 에서 4번째 라벨로 같이 닫는다).
# 스텁을 라벨별로 갈라 `hold:conflict` 질의에만 레포를 돌려준다 — 그 라벨을 묻지 않으면 못 찾는다.
# 이슈 축: `hold:conflict` 만 달린 이슈가 있는 레포(사람이 결정할 충돌 — ①②③ 어느 갈래도 아니지만
# 그 레포의 열린 PR 정지 미러(④)는 봐야 한다).
setup "hold:conflict,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"; echo '[]' > "$tmp/policy.json"
: > "$tmp/search"; : > "$tmp/search.prs"
printf 'owner/conflictonly\n' > "$tmp/search.hold:conflict"
run
check "hold:conflict 이슈 축: 그 라벨을 묻는다"       "$(some 'search issues label:hold:conflict .*--state open')"
check "hold:conflict 이슈 축: 레포가 순회 집합에 든다" "$(some 'pr list --repo owner/conflictonly')"
check "hold:conflict 이슈 축: exit 0"                 "$([ "$RC" = 0 ] && echo ok || echo no)"
# PR 축: 이슈는 깨끗하고 PR 에만 `hold:conflict` 가 남은 레포(사람이 이슈 쪽만 풀었다) — ④ 가
# 실제로 떼는 모양(격자 ⑦·⑩)이라, 탐색이 못 찾으면 교정이 영영 안 돈다.
setup "agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"; echo '[]' > "$tmp/policy.json"
: > "$tmp/search"; : > "$tmp/search.prs"
printf 'owner/prconflict\n' > "$tmp/search.prs.hold:conflict"
mirror_prs '[{"number":402,"headRefName":"agent/issue-502",
  "labels":[{"name":"hold:conflict"},{"name":"flow:verify"}],
  "closingIssuesReferences":[{"number":502}]}]'
mirror_issue 502 OPEN "agent-ready,flow:verify"
run
check "hold:conflict PR 축: 그 라벨을 묻는다"          "$(some 'search prs label:hold:conflict .*--state open')"
check "hold:conflict PR 축: 레포가 순회 집합에 든다"    "$(some 'pr list --repo owner/prconflict')"
check "hold:conflict PR 축: ④ 교정까지 간다"           "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==402) | .number==502 and .removed=="hold:conflict"' >/dev/null 2>&1 && echo ok || echo no)"
check "hold:conflict PR 축: PR 정지 라벨이 실제로 빠진다" "$([ "$(mpl 402)" = "flow:verify" ] && echo ok || echo no)"
check "hold:conflict PR 축: exit 0"                    "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── (#331 반송) 합집합의 두 축이 **동시에** 비어있지 않을 때 — dedupe 와 양쪽 순회 ────
# 앞 절들은 전부 한쪽 축을 비운 채 돌아, 운영에서 가장 흔한 모양(같은 레포가 양축에 잡힘)의
# dedupe 와 서로 다른 두 레포가 둘 다 순회되는지가 무가드였다(`sort -u`→`cat` 회귀에도 초록).
# 픽스처: 이슈 축 `[owner/both, owner/issonly]` · PR 축 `[owner/both, owner/pronly]`.
#   · owner/both  — 양축에 잡힘 → **한 번만** 순회(① 목록 조회 횟수로 실측)
#   · owner/issonly · owner/pronly — 한쪽에만 → 둘 다 순회
setup "hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"; echo '[]' > "$tmp/policy.json"
printf 'owner/both\nowner/issonly\n' > "$tmp/search"
printf 'owner/both\nowner/pronly\n'  > "$tmp/search.prs"
run
check "양축 동시: 양축에 잡힌 레포는 한 번만 순회" "$([ "$(counts 'issue list --repo owner/both .*--label hold:ladder')" = 1 ] && echo ok || echo no)"
check "양축 동시: 이슈 축에만 있는 레포도 순회"   "$([ "$(counts 'issue list --repo owner/issonly .*--label hold:ladder')" = 1 ] && echo ok || echo no)"
check "양축 동시: PR 축에만 있는 레포도 순회"     "$([ "$(counts 'issue list --repo owner/pronly .*--label hold:ladder')" = 1 ] && echo ok || echo no)"
check "양축 동시: 순회 레포 수 = 3"               "$([ "$(counts 'issue list --repo .*--label hold:ladder')" = 3 ] && echo ok || echo no)"
check "양축 동시: exit 0"                         "$([ "$RC" = 0 ] && echo ok || echo no)"

# ── (#331) PR 쪽 상한 도달도 기존 `탐색 상한 도달` 규율 그대로 ─────────────
# 라벨과 축을 문구에 밝힌다 — 여럿이 닿으면 같은 줄이 겹쳐 어느 질의가 잘렸는지 못 가른다.
# (스텁은 라벨과 무관하게 같은 목록을 돌려주므로 네 라벨이 모두 닿아 warn 이 넷 난다 —
#  단언은 `needs-human` 줄로 대표한다.)
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; : > "$tmp/search"
awk 'BEGIN{for(i=1;i<=3;i++) print "owner/p" i}' > "$tmp/search.prs"
run
check "PR 축 상한: warn"                 "$(has_ev warn)"
check "PR 축 상한: 문구가 라벨과 축을 밝힌다" "$(saysl '탐색 상한 도달(3, label:needs-human, PR)')"
check "PR 축 상한: 이슈 축 문구는 안 난다" "$(printf '%s' "$out" | grep -q '탐색 상한 도달(3, label:[^,]*, 이슈)' && echo no || echo ok)"
check "PR 축 상한: exit 0"               "$([ "$RC" = 0 ] && echo ok || echo no)"
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; : > "$tmp/search"
awk 'BEGIN{for(i=1;i<=2;i++) print "owner/p" i}' > "$tmp/search.prs"
run
check "PR 축 상한 미만: warn 없음"       "$(no_ev warn)"
# 이슈 축이 닿았을 때 PR 축 문구가 섞이지 않는다(반대 방향 대조군).
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; awk 'BEGIN{for(i=1;i<=3;i++) print "owner/r" i}' > "$tmp/search"; : > "$tmp/search.prs"
run
check "이슈 축 상한: 문구가 라벨과 축을 밝힌다" "$(saysl '탐색 상한 도달(3, label:needs-human, 이슈)')"
check "이슈 축 상한: PR 축 문구는 안 난다" "$(printf '%s' "$out" | grep -q '탐색 상한 도달(3, label:[^,]*, PR)' && echo no || echo ok)"

# ══════════════════════════════════════════════════════════════════════════════
# ⑨-r (#397) 정지 미러 정리의 **재시도 주체** — 증거 부재가 영구 warn 으로 남지 않는다
#
# ④ 의 양성 증거 게이트는 증거를 못 얻으면 warn 만 냈고, 다시 시도하는 주체가 없어 같은 줄이
# 매 틱 반복됐다. 이제 회차를 마커 코멘트로 세어 `N/상한` 을 문구에 싣고, 상한에 닿으면
# `mirror_retry_exhausted` 로 사람 몫이 된다(전이는 SKILL 이 건다 — 스크립트는 이벤트만).
# ══════════════════════════════════════════════════════════════════════════════
mr_markers() {  # mr_markers <이슈> — 그 이슈에 쌓인 mirror-retry 마커 수
  if [ -f "$tmp/mirror.comments.$1" ]; then
    jq '[.[] | select(.body | test("mirror-retry"))] | length' "$tmp/mirror.comments.$1"
  else echo 0; fi
}
mr_setup() {  # mr_setup — 증거를 못 얻는 미러 형상(이슈에 해제 이력 없음 = ⓒ)
  setup "" 200 0
  mirror_prs '[{"number":241,"headRefName":"agent/issue-341","labels":[{"name":"hold:policy"}],
                "closingIssuesReferences":[{"number":341}]}]'
  : > "$tmp/mirror.issues"; mirror_issue 341 OPEN "agent-ready"
  : > "$tmp/mirror.events"; mirror_events 341 "__NONE__"
}

mr_setup
run
check "⑨-r 증거 없음 1회: 마커 코멘트 1개" "$([ "$(mr_markers 341)" = 1 ] && echo ok || echo no)"
check "⑨-r 증거 없음 1회: warn 에 회차(1/3)" "$(saysl '(재시도 1/3)')"
check "⑨-r 증거 없음 1회: 라벨 무편집"       "$(none 'pr edit 241')"
check "⑨-r 증거 없음 1회: 상한 이벤트 없음"  "$(no_ev mirror_retry_exhausted)"
# 마커는 코멘트가 **스스로 품는다**(카운터와 알림이 한 번의 append) — gh.log 는 본문의
# 줄바꿈에서 잘리므로 쌓인 코멘트 본문을 직접 본다.
check "⑨-r 마커 본문이 자기 회차를 품는다" \
  "$(jq -e '.[-1].body | test("<!-- mirror-retry:") and test("정지 미러 재시도 1/3")' "$tmp/mirror.comments.341" >/dev/null 2>&1 && echo ok || echo no)"

# 다음 틱 — 같은 상태면 회차가 **올라간다**(매 틱 같은 줄이 아니다).
run
check "⑨-r 다음 틱: 마커 2개"               "$([ "$(mr_markers 341)" = 2 ] && echo ok || echo no)"
check "⑨-r 다음 틱: warn 에 2/3"            "$(saysl '(재시도 2/3)')"

# 상한 도달 — 마커 3개 상태에서는 코멘트를 더 쌓지 않고 이벤트를 낸다.
run
check "⑨-r 3회차: 마커 3개"                 "$([ "$(mr_markers 341)" = 3 ] && echo ok || echo no)"
run
check "⑨-r 상한 도달: mirror_retry_exhausted" "$(has_ev mirror_retry_exhausted)"
check "⑨-r 상한 도달: 이슈·PR·회차가 실린다" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_retry_exhausted") | .number==341 and .pr==241 and .attempts==3 and .limit==3' >/dev/null 2>&1 && echo ok || echo no)"
check "⑨-r 상한 도달: 마커를 더 쌓지 않는다"  "$([ "$(mr_markers 341)" = 3 ] && echo ok || echo no)"
check "⑨-r 상한 도달: 라벨은 끝까지 무편집"   "$(none 'pr edit 241')"
check "⑨-r 상한 도달: 전이는 스크립트가 걸지 않는다" "$(none 'issue edit 341')"

# 증거가 서면 종전대로 정리된다 — 재시도 관문이 정상 경로를 막지 않는다(대조군).
mr_setup
: > "$tmp/mirror.events"   # 이력 픽스처 없음 = 스텁이 정상 해제로 답한다
run
check "⑨-r 대조군(증거 있음): 정리된다"     "$(printf '%s' "$out" | jq -e 'select(.event=="mirror_cleared" and .pr==241)' >/dev/null 2>&1 && echo ok || echo no)"
check "⑨-r 대조군: 마커를 쌓지 않는다"       "$([ "$(mr_markers 341)" = 0 ] && echo ok || echo no)"

# 상수 오타는 **쓰기 전에** 멈춘다(다른 두 상수와 같은 규율).
mr_setup
MRL=3x run
MRL=3
check "⑨-r MIRROR_RETRY_LIMIT 오타: exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "⑨-r MIRROR_RETRY_LIMIT 오타: 무편집"  "$(none 'pr edit 241')"

# ══════════════════════════════════════════════════════════════════════════════
# ⑩ (#395) PR 단독 `hold:policy` 재심 — ③ 이 이슈만 스캔해 영영 안 오르던 칸
#
# `verify-held`·`closeout-blocked` 는 `<issue>=-` 로도 PR 에 `hold:policy` 를 붙인다. 그 홀드는
# 이슈 목록에 없어 재심(#155)에 안 올랐다. 축 하나(연결 이슈 유무)를 움직여 중복 금지와
# 발행을 함께 문다 — 판정(창·마커·needs-human)은 이슈 축과 **같은 함수**를 쓴다.
# ══════════════════════════════════════════════════════════════════════════════
pr_comments() { printf '%s' "$1" > "$tmp/pr.comments.json"; }
pr_policy_rows() {  # pr_policy_rows <closes JSON> <분전> [라벨csv]
  jq -n --argjson c "$1" --arg u "$(ts "$2")" --arg l "${3:-hold:policy}" \
    '[{number:701, headRefName:"fix/사람이-연-브랜치",
       labels: ($l|split(",")|map({name:.})), closingIssuesReferences:$c, updatedAt:$u}]' \
    > "$tmp/mirror.prs.json"
}
# 이번 홀드의 질문(hold-note)만 있고 재심 마커는 없다 = due.
pp_note='[{"body":"사람 확인(policy): 이 정책은 사람이 답해야 하나\n<!-- hold-note: policy --><!-- bodat:worker -->"}]'

setup "" 200 0
pr_policy_rows '[]' 200
pr_comments "$pp_note"
run
check "⑩ PR 단독 hold:policy(창 초과): policy_review_due 발행" "$(has_ev policy_review_due)"
check "⑩ PR 단독: pr 필드로 축이 갈린다(number 는 null)" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .pr == 701 and .number == null' >/dev/null 2>&1 && echo ok || echo no)"
check "⑩ PR 단독: minutes 가 실린다" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .minutes >= 199' >/dev/null 2>&1 && echo ok || echo no)"
check "⑩ PR 단독: 무편집(라벨·코멘트 안 건드린다)" \
  "$([ "$(counts 'pr edit')" = 0 ] && [ "$(counts 'pr comment')" = 0 ] && echo ok || echo no)"

# 연결 이슈가 있으면 **이슈 축만** — PR 축 이벤트는 0(중복 금지, AC 3번).
setup "" 200 0
pr_policy_rows '[{"number":333}]' 200
pr_comments "$pp_note"
run
check "⑩ 연결 이슈 있는 PR: PR 축 이벤트 0" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .pr != null' >/dev/null 2>&1 && echo no || echo ok)"

# 창 안이면 조용히 넘긴다(코멘트 조회조차 안 한다 — 이슈 축과 같은 규율).
setup "" 10 0
pr_policy_rows '[]' 10
pr_comments "$pp_note"
run
check "⑩ 창 안: 이벤트 없음"        "$(no_ev policy_review_due)"
check "⑩ 창 안: PR 코멘트 조회 안 함" "$([ "$(counts 'pr view 701 .*comments')" = 0 ] && echo ok || echo no)"

# 이번 홀드가 이미 재심됐으면 다시 묻지 않는다(에피소드 판정이 PR 축에도 선다).
setup "" 200 0
pr_policy_rows '[]' 200
pr_comments '[{"body":"사람 확인(policy): 질문\n<!-- hold-note: policy -->"},
              {"body":"재심: 사람 몫 유지 — 근거\n<!-- policy-review: kept -->"}]'
run
check "⑩ 이미 재심(reviewed): 다시 안 낸다" "$(no_ev policy_review_due)"

# 질문(hold-note)이 없으면 재심 불가 — warn 만(이슈 축과 같은 처분).
setup "" 200 0
pr_policy_rows '[]' 200
pr_comments '[{"body":"그냥 코멘트"}]'
run
check "⑩ 질문 없음: due 안 냄"  "$(no_ev policy_review_due)"
check "⑩ 질문 없음: warn 한 줄" "$(saysl '질문(hold-note) 코멘트가 없다')"

# 사람이 세운 needs-human 동존이면 재심 안 한다(#244) — note, warn 아님.
setup "" 200 0
pr_policy_rows '[]' 200 "hold:policy,needs-human"
pr_comments "$pp_note"
run
check "⑩ needs-human 동존: due 안 냄" "$(no_ev policy_review_due)"
check "⑩ needs-human 동존: note(정상 상태)" "$(has_ev note)"
check "⑩ needs-human 동존: warn 아님"       "$(no_ev warn)"

# 마커 조회 실패는 "재심 안 함" 으로 조용히 접지 않는다.
setup "" 200 0
pr_policy_rows '[]' 200
pr_comments "$pp_note"
STUB_PR_COMMENTS_FAIL=1 run
STUB_PR_COMMENTS_FAIL=""
check "⑩ 코멘트 조회 실패: due 안 냄" "$(no_ev policy_review_due)"
check "⑩ 코멘트 조회 실패: warn"      "$(has_ev warn)"

# ── (#197) 프롬프트와 스크립트가 같은 수를 센다 — jq 인용 제거 정의 동기화 ──
# 디스패처(SKILL.md ③-4d)도 같은 jq 로 재개 횟수를 센다. 정의가 갈라지면 사람 눈에 안 보이는
# 두 번째 계산기가 다른 수를 센다. **스크립트에서 뽑은 문자열**을 두 SKILL 에서 grep -F 로
# 대조한다(손타이핑 대조는 한글·백틱이 뭉개져 오탐을 낸다).
root=$(cd "$DIR/.." && pwd)
unq=$(grep -o 'def unquoted:.*;' "$DIR/resume-sweep.sh" | head -1)
check "스크립트에 인용 제거 정의(def unquoted)" "$([ -n "$unq" ] && echo ok || echo no)"
for f in SKILL.md SKILL.en.md; do
  check "$f 의 재개 횟수 jq 가 같은 정의를 쓴다" \
    "$([ -n "$unq" ] && grep -qF -- "$unq" "$root/$f" && echo ok || echo no)"
done

if [ "$skip" -gt 0 ]; then
  echo "resume-sweep: $pass passed, $fail failed, $skip skipped (python3 없음)"
else
  echo "resume-sweep: $pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
