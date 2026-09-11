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
# 이 테스트가 그대로 #201 Test plan ⓒ(deploy-wait + hold:policy + 노트 **있음** → 종전대로
# policy_review_due 창 판정)다 — #201 의 no-note 갈래 변경이 이 갈래(due)엔 손대지 않았다는
# 회귀 증거로 겸한다(사전 리뷰 지적 대응 — 신규 diff 에는 없던 기존 테스트라 안 보였다).
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
# ⓑ(#201) 회귀 방지 — 배포 대기가 **아닌** no-note 는 계속 warn 이다(진짜 규약 위반).
setup "needs-human,hold:policy,agent-ready" 200 0
run
check "policy 재심 질문 없음: warn(no-note)" "$(printf '%s' "$out" | grep -q 'hold-note' && echo ok || echo no)"
check "policy 재심 질문 없음: due 안 냄" "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
check "policy 재심 질문 없음(배포 대기 아님): note 없음" "$(no_ev note)"

# ── ⓐ(#201) 배포 대기 + hold:policy + no-note → warn 아니라 note(조치 불가 반복 억제) ──
# ②(사유 없는 needs-human)와 같은 deploy_wait_row 공유 술어를 쓴다. 실측 근거는
# ggqgga/BodaT#5013 — 배포 레인이 transition.sh 를 거치지 않고 라벨을 직접 붙여 사람이
# 답할 질문이 코멘트 산문에 있었는데도 `<!-- hold-note: policy -->` 마커가 없었다.
setup "needs-human,deploy-wait,hold:policy" 200 0
run
check "배포대기 policy no-note: note"          "$(has_ev note)"
check "배포대기 policy no-note: warn 아님"      "$(no_ev warn)"
check "배포대기 policy no-note: due 안 냄"      "$(printf '%s' "$out" | grep -q policy_review_due && echo no || echo ok)"
check "배포대기 policy no-note: 문구에 deploy-wait·hold:policy" \
  "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("deploy-wait")) and (.msg | test("hold:policy"))' >/dev/null 2>&1 && echo ok || echo no)"
check "배포대기 policy no-note: 편집 0회"       "$(none 'issue edit')"

# ── ⓐ'(#201) full-cycle 과도기 축도 같은 술어를 공유한다(②와 동일 트레이드오프) ──
setup "needs-human,full-cycle,hold:policy" 200 0
run
check "full-cycle policy no-note: note"        "$(has_ev note)"
check "full-cycle policy no-note: warn 아님"    "$(no_ev warn)"

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
setup "needs-human,hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" ""
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
setup "needs-human,hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" "$(ts 200)"
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
check "정상 번호: number 유지·표식 없음" "$(evq warn '.number == 42 and (.msg | test("번호 파싱 실패") | not)')"

# ── ㉛ (#193) `msg` 없는 이벤트 넷도 같은 자리를 안전하게 — waiting·escalated·resumed·
#    policy_review_due. 이쪽은 사실을 적을 `msg` 칸이 없어 **형식 안전만** 취한다(번호 0).
#    방출 조건은 안 바뀐다 — 특히 waiting 은 원래 조용히 넘기는 이벤트라 줄 수가 늘면 안 된다.
#    이슈 본문 `## 범위 — 한 자리가 아니라 파일 전역이다` 가 요구한 넓히기.
setup "needs-human,hold:ladder,agent-ready" 10 0
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" "$(ts 10)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 waiting(창 전): 유효 JSON"    "$(lines_all_json)"
check "빈 번호 waiting(창 전): 1줄만"        "$([ "$(nlines '"event":"waiting"')" = 1 ] && echo ok || echo no)"
check "빈 번호 waiting(창 전): number 는 0"  "$(evq waiting '.number == 0')"
check "빈 번호 waiting(창 전): minutes 유지"  "$(evq waiting '.minutes >= 9 and .minutes <= 11')"

# 창 재판정 경로(목록 스냅샷 뒤 사람이 건드려 live updatedAt 이 새 기준이 된 경우)의 waiting.
setup "needs-human,hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
printf '%s' "$(ts 5)" > "$tmp/updated.livefile"
STUB_UPDATED_LIVE="$tmp/updated.livefile"
run
check "빈 번호 waiting(창 재판정): 유효 JSON"   "$(lines_all_json)"
check "빈 번호 waiting(창 재판정): number 는 0" "$(evq waiting '.number == 0')"
check "빈 번호 waiting(창 재판정): 무편집"      "$(none 'issue edit')"

# 재개(resumed) — 번호가 비어도 줄은 유효 JSON 이어야 한다.
setup "needs-human,hold:ladder,agent-ready" 200 0
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 resumed: 유효 JSON"      "$(lines_all_json)"
check "빈 번호 resumed: number 는 0"    "$(evq resumed '.number == 0')"
check "빈 번호 resumed: attempt 유지"   "$(evq resumed '.attempt == 1')"

# 승격(escalated) — 마커 2개로 상한 초과.
setup "needs-human,hold:ladder,agent-ready" 200 2
bad_num_rows "$tmp/ladder.json" "" "needs-human,hold:ladder,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/human.json"
run
check "빈 번호 escalated: 유효 JSON"        "$(lines_all_json)"
check "빈 번호 escalated: number 는 0"      "$(evq escalated '.number == 0')"
check "빈 번호 escalated: attempt·limit 유지" "$(evq escalated '.attempt == 2 and .limit == 2')"

# policy 재심 due — ③ 의 pnum 이 빈 경우.
setup "needs-human,hold:policy,agent-ready" 200 0
bad_num_rows "$tmp/policy.json" "" "needs-human,hold:policy,agent-ready" "$(ts 200)"
echo '[]' > "$tmp/ladder.json"
echo '[]' > "$tmp/human.json"
note "사람 확인(policy): A인가 B인가 <!-- hold-note: policy --><!-- bodat:worker -->"
run
check "빈 번호 policy_review_due: 유효 JSON"   "$(lines_all_json)"
check "빈 번호 policy_review_due: number 는 0" "$(evq policy_review_due '.number == 0')"
check "빈 번호 policy_review_due: 무편집"      "$(none 'issue edit')"

# 정상 번호(42)일 때 넷 다 번호를 그대로 싣는다 — 바이트 무회귀 가드.
setup "needs-human,hold:ladder,agent-ready" 10 0
run
check "정상 번호 waiting: number 42 유지" "$(evq waiting '.number == 42')"
setup "needs-human,hold:ladder,agent-ready" 200 0
run
check "정상 번호 resumed: number 42 유지" "$(evq resumed '.number == 42')"
setup "needs-human,hold:ladder,agent-ready" 200 2
run
check "정상 번호 escalated: number 42 유지" "$(evq escalated '.number == 42')"
setup "needs-human,hold:policy,agent-ready" 200 0
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
  setup "needs-human,hold:ladder,agent-ready" 200 0
  bad_num_rows "$tmp/ladder.json" "$1" "needs-human,hold:ladder,agent-ready" ""
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
setup "needs-human,hold:ladder,agent-ready" 200 0
RA='060'
run
check "RESUME_AFTER_MIN=060: exit 64 아님(관대함 유지)" "$([ "$RC" != 64 ] && echo ok || echo no)"
check "RESUME_AFTER_MIN=060: 60분으로 읽혀 재개된다"     "$(has_ev resumed)"
setup "needs-human,hold:ladder,agent-ready" 200 0
RL='02'
run
check "LADDER_RESUME_LIMIT=02: exit 64 아님" "$([ "$RC" != 64 ] && echo ok || echo no)"
setup "needs-human,hold:ladder,agent-ready" 200 0
LL='0200'
run
check "RESUME_LIST_LIMIT=0200: exit 64 아님" "$([ "$RC" != 64 ] && echo ok || echo no)"
# 진짜 비정수는 여전히 exit 64 (세 게이트 모두).
setup "needs-human,hold:ladder,agent-ready" 200 0
LL='1000x'
run
check "잘못된 RESUME_LIST_LIMIT: exit 64"   "$([ "$RC" = 64 ] && echo ok || echo no)"
check "잘못된 RESUME_LIST_LIMIT: gh 호출 0" "$([ ! -s "$tmp/gh.log" ] && echo ok || echo no)"

# ── ㉞ (#217) 배포 대기 티켓의 hold:ladder — 재개·승격이 note 갈래와 같은 답을 읽는다 ──
# 실측 ggqgga/BodaT#5040: 같은 실행이 `resumed`(①)와 배포 대기 `note`(②)를 동시에 냈다.
# ②는 hold:ladder 가 있는 행을 애초에 안 보므로(②의 "hold:* 없음" 가드) note 는 여기(①)
# 에서 대신 낸다 — deploy_wait_row 공유 술어(②·③과 동일, #201) 를 여기서도 쓴다.

# ⓐ deploy-wait + needs-human + hold:ladder, 창 경과 → note 만, 라벨 그대로
setup "needs-human,hold:ladder,deploy-wait,agent-ready" 200 0
run
check "ⓐ deploy-wait+hold:ladder 창 경과: note"        "$(has_ev note)"
check "ⓐ: resumed 아님"                                "$(no_ev resumed)"
check "ⓐ: warn 아님"                                    "$(no_ev warn)"
check "ⓐ: needs-human 유지(라벨 그대로)"                "$(hasl needs-human)"
check "ⓐ: hold:ladder 유지(라벨 그대로)"                "$(hasl hold:ladder)"
check "ⓐ: 편집 0회"                                     "$(none 'issue edit')"
check "ⓐ: 마커 코멘트도 0회"                            "$(none 'issue comment')"
check "ⓐ: 문구에 deploy-wait"                           "$(printf '%s' "$out" | jq -e 'select(.event=="note") | .number == 42 and (.msg | test("deploy-wait"))' >/dev/null 2>&1 && echo ok || echo no)"

# ⓑ 회귀 방지 — deploy-wait 없는 needs-human+hold:ladder, 창 경과 → 종전대로 resumed·라벨 해제
setup "needs-human,hold:ladder,agent-ready" 200 0
run
check "ⓑ 배포 대기 아님: resumed(회귀 없음)"            "$(has_ev resumed)"
check "ⓑ: needs-human 해제"                             "$(lacksl needs-human)"
check "ⓑ: hold:ladder 해제"                             "$(lacksl hold:ladder)"
check "ⓑ: note 아님"                                     "$(no_ev note)"

# ⓒ deploy-wait + hold:ladder, 재개 마커 2개(상한 소진) → escalated 아님, hold:policy 안 붙는다
setup "needs-human,hold:ladder,deploy-wait,agent-ready" 200 2
run
check "ⓒ deploy-wait 상한 소진: escalated 아님"          "$(no_ev escalated)"
check "ⓒ: note"                                          "$(has_ev note)"
check "ⓒ: hold:policy 안 붙는다"                         "$(lacksl hold:policy)"
check "ⓒ: hold:ladder 유지(승격 안 함)"                  "$(hasl hold:ladder)"
check "ⓒ: 편집 0회"                                      "$(none 'issue edit')"
check "ⓒ: 상한 초과 코멘트도 안 남긴다"                  "$(none '사다리 재개 상한')"

# ⓓ 회귀 방지 — deploy-wait 없는 상한 소진 → 종전대로 escalated
setup "needs-human,hold:ladder,agent-ready" 200 2
run
check "ⓓ 배포 대기 아님 상한 소진: escalated(회귀 없음)" "$(has_ev escalated)"
check "ⓓ: hold:policy 부착"                              "$(hasl hold:policy)"
check "ⓓ: note 아님"                                      "$(no_ev note)"

# full-cycle(과도기 축)도 같은 술어를 공유한다 — ②·③과 동일 트레이드오프.
setup "needs-human,hold:ladder,full-cycle,agent-ready" 200 0
run
check "full-cycle+hold:ladder 창 경과: note"             "$(has_ev note)"
check "full-cycle+hold:ladder: resumed 아님"             "$(no_ev resumed)"
check "full-cycle+hold:ladder: 편집 0회"                 "$(none 'issue edit')"

if [ "$skip" -gt 0 ]; then
  echo "resume-sweep: $pass passed, $fail failed, $skip skipped (python3 없음)"
else
  echo "resume-sweep: $pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
