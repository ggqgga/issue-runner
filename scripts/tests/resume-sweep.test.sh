#!/usr/bin/env bash
# resume-sweep.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 release-labels.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것:
#   ① 창 전(RESUME_AFTER_MIN 미만)엔 아무것도 편집하지 않는다 — waiting 만.
#   ② 마커 없음 → 1 · N=1 → 2 로 세고, 본문의 나머지는 한 글자도 안 바뀐다.
#   ③ 상한(LIMIT) 초과는 재개가 아니라 hold:policy 승격이고 needs-human 은 남는다.
#   ④ 사유 라벨(hold:*) 없는 needs-human 은 손대지 않고 warn 만 — 사람이 붙였을 수 있다.
#   ⑤ 목록 조회 실패는 "이슈 없음" 으로 위장되지 않는다(exit 2, fail-loud).
#   ⑥ 사람이 먼저 needs-human 을 뗀 경합은 **편집 전** 재조회로 잡는다 — 사후 readback
#      만으로는 원리적으로 구분이 안 된다(없는 라벨 제거는 no-op 라 기대와 똑같아 보인다).
#   ⑦ readback 이 기대와 다르면 resumed 를 내지 않고 warn 한다.
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
yn() { if [ "$1" = 0 ]; then echo ok; else echo no; fi; }

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

# ── gh 스텁 — 라벨/본문 상태를 파일로 들고 edit 를 실제로 반영한다 ──────────
# (반영하지 않으면 readback 단언이 스텁의 고정 응답을 확인하는 공회전이 된다.)
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
sub="${1:-} ${2:-}"
case "$sub" in
  "issue list")
    if [ -n "${STUB_LIST_FAIL:-}" ]; then echo "gh: list boom" >&2; exit 1; fi
    cat "$STUB_ISSUES"; exit 0 ;;
  "issue view")
    # 호출 순번별 오버라이드(STUB_VIEW_1·STUB_VIEW_2 …)로 편집 전/후 응답을 가른다.
    n=$(cat "$STUB_VIEW_N" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$STUB_VIEW_N"
    var="STUB_VIEW_$n"; v="${!var:-}"
    if [ -n "$v" ]; then
      [ "$v" = "__FAIL__" ] && exit 1
      [ "$v" = "__EMPTY__" ] && { printf '\n'; exit 0; }
      printf '%s\n' "$v"; exit 0
    fi
    cat "$STUB_LABELS"; exit 0 ;;
  "issue edit")
    body_mode=0
    for a in "$@"; do [ "$a" = "--body-file" ] && body_mode=1; done
    if [ "$body_mode" = 1 ] && [ -n "${STUB_BODY_EDIT_FAIL:-}" ]; then exit 1; fi
    if [ "$body_mode" = 0 ] && [ -n "${STUB_LABEL_EDIT_FAIL:-}" ]; then exit 1; fi
    cur=$(cat "$STUB_LABELS")
    while [ $# -gt 0 ]; do
      case "$1" in
        --remove-label) cur=$(printf '%s' ",$cur," | sed "s/,$2,/,/g" | sed 's/^,//; s/,$//'); shift 2 ;;
        --add-label)    case ",$cur," in *",$2,"*) ;; *) cur="${cur:+$cur,}$2" ;; esac; shift 2 ;;
        --body-file)    cp "$2" "$STUB_BODY"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$cur" > "$STUB_LABELS"
    exit 0 ;;
  "issue comment")
    [ -z "${STUB_COMMENT_FAIL:-}" ] || exit 1
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp/bin/gh"

# ── 픽스처 · 실행 헬퍼 ─────────────────────────────────────────────────────
# setup <라벨csv> <분전> <본문>
setup() {
  printf '%s' "$1" > "$tmp/labels"
  printf '%s' "$3" > "$tmp/body"
  jq -n --argjson n 42 --arg l "$1" --arg u "$(ts "$2")" --arg b "$3" \
    '[{number:$n, labels: ($l|split(",")|map(select(length>0)|{name:.})), updatedAt:$u, body:$b}]' \
    > "$tmp/issues.json"
  : > "$tmp/gh.log"
  printf '0' > "$tmp/view.n"
  # unset 하면 export 속성이 날아가 이후 대입이 스텁에 안 전달된다 — 빈 값으로 되돌린다.
  STUB_LIST_FAIL=""; STUB_BODY_EDIT_FAIL=""; STUB_LABEL_EDIT_FAIL=""; STUB_COMMENT_FAIL=""
  STUB_VIEW_1=""; STUB_VIEW_2=""; STUB_VIEW_3=""
}

# run — 이벤트는 $out, 종료코드는 $RC 로. **명령치환으로 부르지 않는다**
# (서브셸이면 RC 가 밖으로 못 나와 exit 2 단언이 공회전한다).
run() {
  (cd "$tmp/work" && PATH="$tmp/bin:$PATH" \
    RESUME_AFTER_MIN="${RA:-120}" LADDER_RESUME_LIMIT="${RL:-2}" \
    bash "$sut_dir/resume-sweep.sh") >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}
export STUB_LOG="$tmp/gh.log" STUB_ISSUES="$tmp/issues.json" STUB_LABELS="$tmp/labels"
export STUB_BODY="$tmp/body" STUB_VIEW_N="$tmp/view.n"
export STUB_LIST_FAIL="" STUB_BODY_EDIT_FAIL="" STUB_LABEL_EDIT_FAIL="" STUB_COMMENT_FAIL=""
export STUB_VIEW_1="" STUB_VIEW_2="" STUB_VIEW_3=""
RC=0
out=""

ev()     { printf '%s' "$out" | jq -r 'select(.event=="'"$1"'")' 2>/dev/null; }
has_ev() { if [ -n "$(ev "$1")" ]; then echo ok; else echo no; fi; }
no_ev()  { if [ -z "$(ev "$1")" ]; then echo ok; else echo no; fi; }
edits()  { grep -c 'issue edit' "$tmp/gh.log" 2>/dev/null || true; }
no_edit(){ if [ "$(edits)" = 0 ]; then echo ok; else echo no; fi; }
# 라벨 판정은 함수로 — `case` 안의 `$( )` 를 또 `$( )` 로 감싸면 bash 가 오파싱한다.
hasl()   { case ",$(cat "$tmp/labels")," in *",$1,"*) echo ok ;; *) echo no ;; esac; }
lacksl() { case ",$(cat "$tmp/labels")," in *",$1,"*) echo no ;; *) echo ok ;; esac; }
saysl()  { if printf '%s' "$out" | grep -q "$1"; then echo ok; else echo no; fi; }
body_is(){ if [ "$(cat "$tmp/body")" = "$1" ]; then echo ok; else echo no; fi; }

BODY_PLAIN='## 사다리 실패
①/② 칸 출력: rc=1 & 재시도 필요
- [ ] TEST 워커'

# ── ① 창 전 — waiting 만, 무편집 ───────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 10 "$BODY_PLAIN"
run
check "창 전: waiting 이벤트"          "$(has_ev waiting)"
check "창 전: minutes 가 실린다"       "$(printf '%s' "$out" | jq -e '.minutes >= 9 and .minutes <= 11' >/dev/null 2>&1 && echo ok || echo no)"
check "창 전: resumed 없음"            "$(no_ev resumed)"
check "창 전: 편집 0회"                "$(no_edit)"
check "창 전: 라벨 불변"               "$(hasl needs-human)"

# ── ② 창 후 · 마커 없음 → 1 ────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
run
plain_bytes=$(printf '%s' "$BODY_PLAIN" | wc -c | tr -d ' ')
check "마커 없음: resumed"             "$(has_ev resumed)"
check "마커 없음: attempt=1"           "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 1' >/dev/null 2>&1 && echo ok || echo no)"
check "마커 없음: 본문에 마커 1 추가"  "$(grep -qF '<!-- ladder-resume: 1 -->' "$tmp/body" && echo ok || echo no)"
check "마커 없음: 원문이 접두로 보존"  "$([ "$(head -c "$plain_bytes" "$tmp/body")" = "$BODY_PLAIN" ] && echo ok || echo no)"
check "마커 없음: needs-human 해제"    "$(lacksl needs-human)"
check "마커 없음: hold:ladder 해제"    "$(lacksl hold:ladder)"
check "마커 없음: agent-ready 유지"    "$(hasl agent-ready)"
check "마커 없음: 코멘트 1회"          "$(grep -q 'issue comment .*재개 1/2' "$tmp/gh.log" && echo ok || echo no)"
check "비공허 실증: 목록 조회가 스텁을 탄다" "$(grep -q 'issue list --repo owner/repo' "$tmp/gh.log" && echo ok || echo no)"

# ── ③ N=1 → 2 · 본문 나머지 불변 ──────────────────────────────────────────
BODY_M1="$BODY_PLAIN

<!-- ladder-resume: 1 -->"
BODY_M2="$BODY_PLAIN

<!-- ladder-resume: 2 -->"
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_M1"
run
check "N=1: resumed attempt=2"         "$(printf '%s' "$out" | jq -e 'select(.event=="resumed") | .attempt == 2' >/dev/null 2>&1 && echo ok || echo no)"
check "N=1: 마커만 2 로 · 나머지 불변" "$(body_is "$BODY_M2")"

# ── ④ N=2 → 상한 초과 승격 (LIMIT=2) ──────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_M2"
run
check "N=2: escalated"                 "$(has_ev escalated)"
check "N=2: resumed 아님"              "$(no_ev resumed)"
check "N=2: hold:policy 부착"          "$(hasl hold:policy)"
check "N=2: hold:ladder 해제"          "$(lacksl hold:ladder)"
check "N=2: needs-human 유지"          "$(hasl needs-human)"
check "N=2: 본문 불변"                 "$(body_is "$BODY_M2")"
check "N=2: 상한 코멘트"               "$(grep -q 'issue comment .*재개 상한 초과(2)' "$tmp/gh.log" && echo ok || echo no)"

# ── ⑤ hold:* 부재 → warn · 무편집 ─────────────────────────────────────────
setup "needs-human,agent-ready" 200 "$BODY_PLAIN"
run
check "hold 없음: warn"                "$(has_ev warn)"
check "hold 없음: 사유 문구"           "$(saysl 'hold:\* 부재')"
check "hold 없음: 편집 0회"            "$(no_edit)"
check "hold 없음: 본문 불변"           "$(body_is "$BODY_PLAIN")"

# ── ⑥ hold:conflict — 사람 몫이라 이벤트도 편집도 없다 ────────────────────
setup "needs-human,hold:conflict,agent-ready" 200 "$BODY_PLAIN"
run
check "hold:conflict: 무이벤트"        "$([ -z "$out" ] && echo ok || echo no)"
check "hold:conflict: 편집 0회"        "$(no_edit)"

# ── ⑦ 사람이 먼저 needs-human 을 뗀 경합 — 편집 전 재조회가 잡는다 ────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
STUB_VIEW_1='hold:ladder,agent-ready'   # 목록 조회 이후 사람이 needs-human 을 뗌
run
check "경합: warn"                     "$(has_ev warn)"
check "경합: 사람 조작 문구"           "$(saysl '사람 조작 경합')"
check "경합: resumed 없음"             "$(no_ev resumed)"
check "경합: 편집 0회(마커도 안 올린다)" "$(no_edit)"
check "경합: 본문 불변"                "$(body_is "$BODY_PLAIN")"

# ── ⑧ readback 불일치 → resumed 대신 warn ────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
STUB_VIEW_2='needs-human,hold:ladder,agent-ready'   # 편집 후에도 그대로 보인다
run
check "readback 불일치: warn"          "$(has_ev warn)"
check "readback 불일치: resumed 없음"  "$(no_ev resumed)"
check "readback 불일치: 문구"          "$(saysl 'readback 불일치')"

# ── ⑨ 목록 조회 실패 → exit 2 · stderr (fail-loud) ────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
STUB_LIST_FAIL=1
run
check "조회 실패: exit 2"              "$([ "$RC" = 2 ] && echo ok || echo no)"
check "조회 실패: stderr 사유"         "$(grep -q '목록 조회 실패' "$tmp/err" && echo ok || echo no)"
check "조회 실패: 이벤트 없음"         "$([ -z "$out" ] && echo ok || echo no)"
check "조회 실패: 편집 0회"            "$(no_edit)"

# ── ⑩ 본문 갱신 실패 → 라벨은 그대로(무한 재시도 방지 순서) ───────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
STUB_BODY_EDIT_FAIL=1
run
check "본문 실패: warn"                "$(has_ev warn)"
check "본문 실패: resumed 없음"        "$(no_ev resumed)"
check "본문 실패: needs-human 유지"    "$(hasl needs-human)"
check "본문 실패: hold:ladder 유지"    "$(hasl hold:ladder)"

# ── ⑪ 정상 경로 exit 0 ────────────────────────────────────────────────────
setup "needs-human,hold:ladder,agent-ready" 200 "$BODY_PLAIN"
run
check "정상 경로: exit 0"              "$([ "$RC" = 0 ] && echo ok || echo no)"

echo "resume-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
