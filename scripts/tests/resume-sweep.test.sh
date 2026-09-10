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
#      안 그러면 PR 이 영구 사람대기로 남고 뒤 전이가 그 라벨을 안 뗀다.
#   ⑤ 두 쿼리(AND 재개 대상 · 사유 점검)가 각각 상한에 닿으면 알린다.
#   ⑥ 사유 라벨 없는 needs-human 은 손대지 않고 warn 만 · 사람 몫 hold 동존도 재개 금지.
#      단 배포 대기 라벨(deploy-wait·full-cycle)이면 **정상 상태**라 warn 이 아니라 note (#190).
#   ⑦ 조회 실패는 "없음" 으로 위장되지 않는다(exit 2) · 상수 오타는 쓰기 전에 exit 64.
#   ⑧ 사람 조작 경합은 **쓰기 전** 재조회로 잡는다(사후 readback 으론 원리적으로 불가).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    pass=$((pass + 1))
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
    body=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && { body="$2"; break; }
      shift
    done
    jq --arg b "$body" '. + [{body: $b}]' "$STUB_COMMENTS" > "$STUB_COMMENTS.tmp" \
      && mv "$STUB_COMMENTS.tmp" "$STUB_COMMENTS"
    exit 0 ;;
  "pr list")
    [ -z "${STUB_PR_FAIL:-}" ] || { echo "gh: pr list boom" >&2; exit 1; }
    prnum=$(cat "$STUB_PR_NUM")
    if [ -z "$prnum" ]; then echo '[]'; exit 0; fi
    jq -n --argjson n "$prnum" --arg l "$(cat "$STUB_PR_LABELS")" \
      '[{number: $n, labels: ($l|split(",")|map(select(length>0)|{name:.}))}]'
    exit 0 ;;
  "pr edit")
    [ -z "${STUB_PR_EDIT_FAIL:-}" ] || exit 1
    edit_labels "$STUB_PR_LABELS" "$@"
    exit 0 ;;
  "pr view")
    labels_json "$(cat "$STUB_PR_LABELS")"; exit 0 ;;
  "search issues")
    [ -z "${STUB_SEARCH_FAIL:-}" ] || { echo "gh: search boom" >&2; exit 1; }
    cat "$STUB_SEARCH"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp/bin/gh"

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
  case ",$labels," in
    *,hold:ladder,*) cp "$tmp/human.json" "$tmp/ladder.json" ;;
    *) echo '[]' > "$tmp/ladder.json" ;;
  esac
  case ",$labels," in
    *,hold:policy,*) cp "$tmp/human.json" "$tmp/policy.json" ;;
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
  : > "$tmp/gh.log"
  # unset 하면 export 속성이 날아가 이후 대입이 스텁에 안 전달된다 — 빈 값으로 되돌린다.
  STUB_LADDER_FAIL=""; STUB_HUMAN_FAIL=""; STUB_LABEL_EDIT_FAIL=""; STUB_COMMENT_FAIL=""
  STUB_COMMENTS_FAIL=""; STUB_SEARCH_FAIL=""; STUB_PR_FAIL=""; STUB_PR_EDIT_FAIL=""
  STUB_STATE_LABELS=""; STUB_READBACK_LABELS=""; STUB_UPDATED_LIVE=""
  WORKDIR="$tmp/work"; RA=120; RL=2; LL=200
}

with_pr() {  # with_pr <PR번호> <PR라벨csv>
  printf '%s' "$1" > "$tmp/pr.num"
  printf '%s' "$2" > "$tmp/pr.labels"
}

# run — 이벤트는 $out, 종료코드는 $RC 로. **명령치환으로 부르지 않는다**
# (서브셸이면 RC 가 밖으로 못 나와 exit 2·64 단언이 공회전한다).
run() {
  (cd "$WORKDIR" && PATH="$tmp/bin:$PATH" \
    RESUME_AFTER_MIN="${RA:-120}" LADDER_RESUME_LIMIT="${RL:-2}" \
    RESUME_LIST_LIMIT="${LL:-200}" \
    bash "$sut_dir/resume-sweep.sh") >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}
export STUB_LOG="$tmp/gh.log" STUB_LABELS="$tmp/labels" STUB_UPDATED="$tmp/updated"
export STUB_LADDER="$tmp/ladder.json" STUB_HUMAN="$tmp/human.json" STUB_POLICY="$tmp/policy.json"
export STUB_COMMENTS="$tmp/comments.json" STUB_SEARCH="$tmp/search"
export STUB_PR_NUM="$tmp/pr.num" STUB_PR_LABELS="$tmp/pr.labels"
export STUB_LADDER_FAIL="" STUB_HUMAN_FAIL="" STUB_LABEL_EDIT_FAIL="" STUB_COMMENT_FAIL=""
export STUB_COMMENTS_FAIL="" STUB_SEARCH_FAIL="" STUB_PR_FAIL="" STUB_PR_EDIT_FAIL=""
export STUB_STATE_LABELS="" STUB_READBACK_LABELS="" STUB_UPDATED_LIVE=""
WORKDIR="$tmp/work"
RC=0
out=""

ev()      { printf '%s' "$out" | jq -r 'select(.event=="'"$1"'")' 2>/dev/null; }
has_ev()  { if [ -n "$(ev "$1")" ]; then echo ok; else echo no; fi; }
no_ev()   { if [ -z "$(ev "$1")" ]; then echo ok; else echo no; fi; }
counts()  { grep -c "$1" "$tmp/gh.log" 2>/dev/null || true; }
none()    { if [ "$(counts "$1")" = 0 ]; then echo ok; else echo no; fi; }
some()    { if [ "$(counts "$1")" != 0 ]; then echo ok; else echo no; fi; }
hasl()    { case ",$(cat "$tmp/labels")," in *",$1,"*) echo ok ;; *) echo no ;; esac; }
lacksl()  { case ",$(cat "$tmp/labels")," in *",$1,"*) echo no ;; *) echo ok ;; esac; }
haspl()   { case ",$(cat "$tmp/pr.labels")," in *",$1,"*) echo ok ;; *) echo no ;; esac; }
lackspl() { case ",$(cat "$tmp/pr.labels")," in *",$1,"*) echo no ;; *) echo ok ;; esac; }
saysl()   { if printf '%s' "$out" | grep -q "$1"; then echo ok; else echo no; fi; }
markers() { jq '[.[] | select(.body | test("ladder-resume"))] | length' "$tmp/comments.json"; }

# ── ① 창 전 — waiting 만, 무쓰기 ───────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 10 0
run
check "창 전: waiting 이벤트"            "$(has_ev waiting)"
check "창 전: minutes 가 실린다"         "$(printf '%s' "$out" | jq -e '.minutes >= 9 and .minutes <= 11' >/dev/null 2>&1 && echo ok || echo no)"
check "창 전: resumed 없음"              "$(no_ev resumed)"
check "창 전: 편집 0회"                  "$(none 'issue edit')"
check "창 전: 코멘트 0회"                "$(none 'issue comment')"
check "창 전: 코멘트 조회조차 안 한다"    "$(none 'json comments')"

# ── ② 마커 0개 → 1번째 재개 ────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
run
check "마커 0: resumed"                  "$(has_ev resumed)"
check "마커 0: attempt=1"                "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 1' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 0: 마커 코멘트가 쌓인다"      "$([ "$(markers)" = 1 ] && echo ok || echo no)"
check "마커 0: 코멘트 본문에 마커"        "$(grep -q 'issue comment .*<!-- ladder-resume: 1 -->' "$tmp/gh.log" && echo ok || echo no)"
check "마커 0: needs-human 해제"          "$(lacksl needs-human)"
check "마커 0: hold:ladder 해제"          "$(lacksl hold:ladder)"
check "마커 0: agent-ready 유지"          "$(hasl agent-ready)"
check "본문은 건드리지 않는다(--body-file 부재)" "$(none -- '--body-file')"
check "기본 상한은 200 (env 미지정)"        "$(grep -q -- '--limit 200' "$tmp/gh.log" && echo ok || echo no)"
check "비공허 실증: AND 쿼리로 목록을 뜬다" "$(grep -q 'issue list --repo owner/repo .*--label needs-human --label hold:ladder' "$tmp/gh.log" && echo ok || echo no)"

# ── ③ 마커 1개 → 2번째 재개 ────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 1
run
check "마커 1: attempt=2"                "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 1: 마커가 2개로"             "$([ "$(markers)" = 2 ] && echo ok || echo no)"

# ── ④ 마커 2개 → 상한 초과 승격 (LIMIT=2) ─────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 2
run
check "마커 2: escalated"                "$(has_ev escalated)"
check "마커 2: resumed 아님"             "$(no_ev resumed)"
check "마커 2: attempt=2 · limit=2"      "$(printf '%s' "$out" | jq -e 'select(.event=="escalated") | .attempt == 2 and .limit == 2' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 2: hold:policy 부착"         "$(hasl hold:policy)"
check "마커 2: hold:ladder 해제"         "$(lacksl hold:ladder)"
check "마커 2: needs-human 유지"         "$(hasl needs-human)"
check "마커 2: 승격 코멘트엔 마커 없음"   "$([ "$(markers)" = 2 ] && echo ok || echo no)"
check "마커 2: 상한 코멘트"              "$(grep -q 'issue comment .*사다리 재개 상한(2) 초과' "$tmp/gh.log" && echo ok || echo no)"

# ── ⑤ [P1] PR 미러 해제 — 재개 ────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
with_pr 77 "needs-human,hold:ladder,flow:verify"
run
check "PR 재개: resumed"                 "$(has_ev resumed)"
check "PR 재개: PR needs-human 해제"     "$(lackspl needs-human)"
check "PR 재개: PR hold:ladder 해제"     "$(lackspl hold:ladder)"
check "PR 재개: PR flow:verify 유지"     "$(haspl flow:verify)"
check "PR 재개: pr edit 을 실제로 부른다" "$(some 'pr edit 77')"

# ── ⑥ [P1] PR 미러 승격 ───────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 2
with_pr 77 "needs-human,hold:ladder"
run
check "PR 승격: escalated"               "$(has_ev escalated)"
check "PR 승격: PR hold:policy 부착"     "$(haspl hold:policy)"
check "PR 승격: PR hold:ladder 해제"     "$(lackspl hold:ladder)"
check "PR 승격: PR needs-human 유지"     "$(haspl needs-human)"

# ── ⑦ 연결 PR 없음 → 이슈만 (정상) ────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
run
check "PR 없음: resumed"                 "$(has_ev resumed)"
check "PR 없음: pr edit 0회"             "$(none 'pr edit')"
check "PR 없음: warn 없음"               "$(no_ev warn)"
check "PR 없음: after-edit warn 없음"    "$(no_ev warn_after_edit)"

# ── ⑧ 정지 라벨 없는 PR 은 건드리지 않는다 ────────────────────────────────
# (레포에 없는 라벨을 remove 하면 gh 가 편집 전체를 실패시키므로 불필요한 편집은 안 낸다.)
setup "needs-human,hold:ladder,agent-ready" 200 0
with_pr 77 "flow:verify"
run
check "무관 PR: pr edit 0회"             "$(none 'pr edit')"
check "무관 PR: resumed"                 "$(has_ev resumed)"

# ── ⑨ PR 편집 실패 → warn_after_edit (이슈는 이미 반영됨) ─────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
with_pr 77 "needs-human,hold:ladder"
STUB_PR_EDIT_FAIL=1
run
check "PR 편집 실패: warn_after_edit"    "$(has_ev warn_after_edit)"
check "PR 편집 실패: PR 번호가 문구에"    "$(saysl 'PR #77')"
check "PR 편집 실패: 이슈 재개는 그대로"  "$(has_ev resumed)"
check "PR 편집 실패: 이슈 라벨은 반영됨"  "$(lacksl needs-human)"

# ── ⑩ [P1] 마커 코멘트 실패 → 라벨 무편집 (순서 계약) ─────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_COMMENT_FAIL=1
run
check "코멘트 실패: warn"                "$(has_ev warn)"
check "코멘트 실패: resumed 없음"        "$(no_ev resumed)"
check "코멘트 실패: needs-human 유지"    "$(hasl needs-human)"
check "코멘트 실패: hold:ladder 유지"    "$(hasl hold:ladder)"
check "코멘트 실패: 라벨 편집 0회"       "$(none 'issue edit')"

# ── ⑪ 코멘트 조회 실패 → 상한을 못 지키므로 무편집 ────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_COMMENTS_FAIL=1
run
check "코멘트 조회 실패: warn"           "$(has_ev warn)"
check "코멘트 조회 실패: 무편집"         "$(none 'issue edit')"
check "코멘트 조회 실패: 코멘트도 0회"   "$(none 'issue comment')"

# ── ⑫ 사유 라벨 없는 needs-human → warn · 무편집 ──────────────────────────
setup "needs-human,agent-ready" 200 0
run
check "hold 없음: warn"                  "$(has_ev warn)"
check "hold 없음: 사유 문구"             "$(saysl 'hold:\* 부재')"
check "hold 없음: 편집 0회"              "$(none 'issue edit')"
check "hold 없음: resumed 없음"          "$(no_ev resumed)"

# ── ⑬ hold:conflict — 재개 대상도 warn 대상도 아니다 ──────────────────────
setup "needs-human,hold:conflict,agent-ready" 200 0
run
check "hold:conflict: 무이벤트"          "$([ -z "$out" ] && echo ok || echo no)"
check "hold:conflict: 편집 0회"          "$(none 'issue edit')"

# ── ⑭ 사람 몫 hold 동존 → 자동 재개 안 함 ─────────────────────────────────
setup "needs-human,hold:ladder,hold:policy,agent-ready" 200 0
run
check "hold 동존: warn"                  "$(has_ev warn)"
check "hold 동존: 문구"                  "$(saysl '사람 몫 hold:\* 동존')"
check "hold 동존: resumed 없음"          "$(no_ev resumed)"
check "hold 동존: 편집 0회"              "$(none 'issue edit')"

# ── ⑮ 사람 조작 경합 — 쓰기 전 재조회가 잡는다 ────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_STATE_LABELS='hold:ladder,agent-ready'   # 목록 조회 이후 사람이 needs-human 을 뗌
run
check "경합: warn"                       "$(has_ev warn)"
check "경합: 사람 조작 문구"             "$(saysl '사람 조작 경합')"
check "경합: resumed 없음"               "$(no_ev resumed)"
check "경합: 코멘트 0회(마커도 안 남긴다)" "$(none 'issue comment')"
check "경합: 편집 0회"                   "$(none 'issue edit')"

# ── ⑯ 재조회 실패 → 손대지 않는다 ─────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_STATE_LABELS='__FAIL__'
run
check "재조회 실패: warn"                "$(has_ev warn)"
check "재조회 실패: 문구"                "$(saysl '재조회 실패')"
check "재조회 실패: 무편집"              "$(none 'issue edit')"

# ── ⑰ readback 라벨 0개는 성공 · 불일치는 warn_after_edit ─────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_READBACK_LABELS='__EMPTY__'
run
check "라벨 0개 readback: resumed"       "$(has_ev resumed)"
check "라벨 0개 readback: warn 없음"     "$(no_ev warn)"
check "라벨 0개 readback: after-edit 없음" "$(no_ev warn_after_edit)"
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_READBACK_LABELS='needs-human,hold:ladder,agent-ready'
run
check "readback 불일치: warn_after_edit" "$(has_ev warn_after_edit)"
check "readback 불일치: 순수 warn 아님"  "$(no_ev warn)"
check "readback 불일치: resumed 없음"    "$(no_ev resumed)"

# ── ⑱ 라벨 편집 실패 → 마커는 이미 남았다(warn_after_edit) ────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_LABEL_EDIT_FAIL=1
run
check "라벨 실패: warn_after_edit"       "$(has_ev warn_after_edit)"
check "라벨 실패: resumed 없음"          "$(no_ev resumed)"
check "라벨 실패: 마커는 남았다"         "$([ "$(markers)" = 1 ] && echo ok || echo no)"

# ── ⑲ 두 쿼리 각각의 조회 실패 → exit 2 (fail-loud) ───────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_LADDER_FAIL=1
run
check "ladder 조회 실패: exit 2"         "$([ "$RC" = 2 ] && echo ok || echo no)"
check "ladder 조회 실패: stderr"         "$(grep -q 'hold:ladder 목록 조회 실패' "$tmp/err" && echo ok || echo no)"
check "ladder 조회 실패: resumed 없음"   "$(no_ev resumed)"
setup "needs-human,hold:ladder,agent-ready" 200 0
STUB_HUMAN_FAIL=1
run
check "human 조회 실패: exit 2"          "$([ "$RC" = 2 ] && echo ok || echo no)"
check "human 조회 실패: 재개는 그대로"   "$(has_ev resumed)"

# ── ⑳ [P2] 두 쿼리 상한 warn ──────────────────────────────────────────────
# 상한값 자체는 RESUME_LIST_LIMIT 로 낮춰 재현한다 — 200행 픽스처는 프로세스 수백 개라
# 박스가 붐빌 때 CI 를 통째로 민다(경로는 값과 무관하게 같다). 기본값이 200 이라는 사실은
# 위 ②의 `--limit 200` 단언이 지킨다.
setup "needs-human,hold:ladder,agent-ready" 10 0     # 창 안 = 쓰기 없음
LL=3
jq -n --arg u "$(ts 10)" '[range(3) | {number: (.+1000), labels: [{name:"needs-human"},{name:"hold:ladder"}], updatedAt: $u}]' \
  > "$tmp/ladder.json"
run
check "ladder 상한: warn"                "$(has_ev warn)"
check "ladder 상한: 쿼리 이름"           "$(saysl '목록 상한 도달(needs-human+hold:ladder)')"
setup "needs-human,hold:conflict,agent-ready" 200 0   # hold 있음 = 사유 warn 안 남
LL=3
jq -n --arg u "$(ts 200)" '[range(3) | {number: (.+1000), labels: [{name:"needs-human"},{name:"hold:conflict"}], updatedAt: $u}]' \
  > "$tmp/human.json"
run
check "human 상한: warn"                 "$(has_ev warn)"
check "human 상한: 쿼리 이름"            "$(saysl '목록 상한 도달(needs-human)')"
setup "needs-human,hold:ladder,agent-ready" 10 0
run
check "상한 미만: 상한 warn 없음"        "$(printf '%s' "$out" | grep -q '목록 상한 도달' && echo no || echo ok)"

# ── ㉑ [P2] 상수 값 검증 — GitHub 쓰기 전에 exit 64 ───────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
RA='120m'
run
check "잘못된 RESUME_AFTER_MIN: exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 RESUME_AFTER_MIN: stderr"  "$(grep -q 'RESUME_AFTER_MIN' "$tmp/err" && echo ok || echo no)"
check "잘못된 RESUME_AFTER_MIN: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"
setup "needs-human,hold:ladder,agent-ready" 200 0
RL='-1'
run
check "잘못된 LADDER_RESUME_LIMIT: exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 LADDER_RESUME_LIMIT: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"

# ── ㉒ .loop/repos 부재 = 계정 전체 탐색 ──────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"; STUB_SEARCH_FAIL=1
run
check "탐색 실패: exit 2"                "$([ "$RC" = 2 ] && echo ok || echo no)"
check "탐색 실패: stderr 사유"           "$(grep -q '탐색 실패' "$tmp/err" && echo ok || echo no)"
check "탐색 실패: 무편집"                "$(none 'issue edit')"
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; awk 'BEGIN{for(i=1;i<=3;i++) print "owner/r" i}' > "$tmp/search"
run
check "탐색 상한: warn"                  "$(has_ev warn)"
check "탐색 상한: 문구"                  "$(saysl '탐색 상한 도달')"
check "탐색 상한: exit 0"                "$([ "$RC" = 0 ] && echo ok || echo no)"
setup "needs-human,hold:ladder,agent-ready" 200 0
WORKDIR="$tmp/noscope"
echo '[]' > "$tmp/ladder.json"; echo '[]' > "$tmp/human.json"
LL=3; awk 'BEGIN{for(i=1;i<=2;i++) print "owner/r" i}' > "$tmp/search"
run
check "탐색 상한 미만: warn 없음"        "$(no_ev warn)"

# ── ㉓ 정상 경로 exit 0 ───────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 0
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

# ── ㉖ 회귀 방지 — 배포 대기 라벨이 없으면 종전대로 warn ───────────────────
# ⑫ 와 같은 픽스처다(의도). 추가 단언은 "note 로는 내려가지 않는다" 쪽 —
# 강등 조건이 넓어져 진짜 사유 없는 needs-human 까지 조용해지면 이 줄이 잡는다.
setup "needs-human,agent-ready" 200 0
run
check "배포 대기 라벨 없음: 종전대로 warn" "$(has_ev warn)"
check "배포 대기 라벨 없음: note 아님"     "$(no_ev note)"
check "배포 대기 라벨 없음: 사유 문구"     "$(saysl 'hold:\* 부재')"

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
setup "needs-human,deploy-wait,hold:policy" 200 0
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
setup "needs-human,hold:policy,agent-ready" 200 0
run
check "policy 재심 질문 없음: warn(no-note)" "$(printf '%s' "$out" | grep -q 'hold-note' && echo ok || echo no)"
check "policy 재심 질문 없음: due 안 냄" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
setup "needs-human,hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재심: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "policy 재심: policy_review_due 이벤트" "$(printf '%s' "$out" | jq -e 'select(.event=="policy_review_due") | .number == 42' >/dev/null 2>&1 && echo ok || echo no)"
check "policy 재심: 무편집" "$(grep -q 'issue edit' "$tmp/gh.log" && echo no || echo ok)"
setup "needs-human,hold:policy,agent-ready" 30 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재심 창 안: 이벤트 없음" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
setup "needs-human,hold:policy,agent-ready" 200 0
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
note "재심: 사람 몫 유지 <!-- policy-review: kept --><!-- bodat:worker -->"
run
check "policy 재심 마커 있음: 다시 안 냄" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
# 옛 홀드의 재심 마커 뒤에 새 질문(hold-note)이 오면 새 에피소드 → 다시 due
note "사람 확인(policy): 이번엔 C인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "policy 재홀드: 새 질문 뒤엔 다시 due" "$(printf '%s' "$out" | grep -q policy_review_due && echo ok || echo no)"
# 승격(escalated) 코멘트가 hold-note 를 품는다 — 승격 건도 재심 대상이 된다
setup "needs-human,hold:ladder,agent-ready" 200 2
run
check "승격 코멘트에 hold-note:policy" "$(grep -q 'hold-note: policy' "$tmp/gh.log" && echo ok || echo no)"

echo "resume-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
