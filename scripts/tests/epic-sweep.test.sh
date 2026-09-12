#!/usr/bin/env bash
# epic-sweep.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 resume-sweep.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것(#258 수용 기준):
#   ① leaf 가 1건 이상이고 **전부 CLOSED** → closed 이벤트 + 코멘트 1 + close 1.
#   ② leaf 중 하나라도 열려 있으면 **쓰기 0**·이벤트 0(조용히 넘긴다).
#   ③ leaf 0 → note("연결된 leaf 없음")·쓰기 0. 옛 에픽은 닫지 않는다.
#   ④ 산문 속 `… epic #N …`(줄 시작 아님)은 leaf 가 아니다 — 검색은 산문도 물어 온다.
#   ④-d (#327) leaf 는 **전용 줄**이다 — 줄 시작은 `Epic #N` 이어도 뒤에 산문이 붙으면
#      leaf 가 아니다(끝 앵커). 걸러야 할 것 4 · 걸러선 안 될 것 5 · 숫자 경계를 격자로 문다.
#   ④-e (#327) 그 조임의 **반대 방향** — 문장형 줄이 **열려 있어** 에픽을 붙잡던 경우는
#      이제 안 붙잡는다(= 닫는 쪽으로 움직인다). 닫는 방향이라 조용히 두지 않고 못 박는다.
#   ⑤ 검색이 상한에 닿으면 **닫지 않고** warn(조용한 오판 금지) — rc 는 0(실패 아님, 보류).
#   ⑥ `--dry-run` 은 쓰기 0 으로 같은 이벤트를 `dry_run:true` 로 낸다.
#   ⑦ (#377) 마커(`<!-- epic-sweep -->`)가 이미 있는데 에픽이 **열려 있으면** 사람이 되돌린 것이다 —
#      코멘트도 close 도 하지 않는다(note). `--dry-run` 도 같은 판정을 낸다(실측 재현 경로가 dry-run).
#   ⑦-b (#377) 코멘트 성공·close 실패의 중간 상태는 **같은 틱 안에서** close 를 재시도해 살린다
#      (다음 틱은 마커를 보고 사람 되돌림으로 읽으므로 이월할 수 없다) — 재시도 상한을 다 쓰면
#      warn + rc 1 이고 그 why 가 "다음 틱이 재시도하지 않는다" 를 말한다.
#   ⑧ `deploy-wait` 에픽은 건드리지 않는다 · `full-cycle`·`needs-human` 에픽은 닫는다.
#   ⑨ 조회·쓰기 실패는 "해당 없음" 으로 위장되지 않는다(warn + exit 1) — 코멘트가 실패하면
#      close 까지 가지 않는다(다음 틱이 코멘트부터 다시 시도).
#   ⑩ leaf 판정 정규식은 loop-status.sh(#260)와 **같은 문자열**이다(두 계산기 금지).
#      ⑪-b 는 그 문자열에 **끝 앵커가 있다**는 것까지 따로 문다 — 두 파일이 함께 되돌아가면
#      동일성 검사만으로는 초록이다(#327).
#   ⑪ 도구(jq) 실패는 fail-closed — 라벨을 못 읽으면 deploy-wait 가드가 "없다" 로 새면 안 되고,
#      leaf 번호 목록을 못 만들면 근거 빈 코멘트로 닫으면 안 된다(데이터로는 못 닿는 경로라
#      표식 붙은 그 한 호출만 jq 스텁으로 실패시킨다 — resume-sweep.test.sh 와 같은 수법).
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

# ── SUT 사본 ───────────────────────────────────────────────────────────────
sut_dir="$tmp/scripts"
mkdir -p "$sut_dir" "$tmp/bin" "$tmp/work/.loop" "$tmp/noscope"
cp "$DIR/epic-sweep.sh" "$sut_dir/epic-sweep.sh"
cp "$DIR/pr-comments.sh" "$sut_dir/pr-comments.sh"
chmod +x "$sut_dir"/*.sh
echo 'owner/repo' > "$tmp/work/.loop/repos"

# ── gh 스텁 — 편집을 실제로 반영한다 ───────────────────────────────────────
# (반영하지 않으면 마커 멱등 단언이 스텁의 고정 응답을 확인하는 공회전이 된다.)
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"

case "${1:-} ${2:-}" in
  "issue list")
    [ -z "${STUB_EPICS_FAIL:-}" ] || { echo "gh: epic list boom" >&2; exit 1; }
    cat "$STUB_EPICS"; exit 0 ;;
  "issue comment")
    [ -z "${STUB_COMMENT_FAIL:-}" ] || exit 1
    body=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && { body="$2"; break; }
      shift
    done
    jq --arg b "$body" '. + [{body: $b, created_at: "2026-09-12T00:00:00Z"}]' "$STUB_COMMENTS" \
      > "$STUB_COMMENTS.tmp" && mv "$STUB_COMMENTS.tmp" "$STUB_COMMENTS"
    exit 0 ;;
  "issue close")
    [ -z "${STUB_CLOSE_FAIL:-}" ] || exit 1
    # 처음 N 번만 실패 — 같은 틱 재시도(⑦-b)가 실제로 재시도하는지 센다.
    if [ "${STUB_CLOSE_FAIL_TIMES:-0}" -gt 0 ]; then
      n=$(cat "$STUB_CLOSE_CNT" 2>/dev/null || echo 0)
      n=$((n + 1)); printf '%s' "$n" > "$STUB_CLOSE_CNT"
      [ "$n" -gt "$STUB_CLOSE_FAIL_TIMES" ] || exit 1
    fi
    exit 0 ;;
esac

if [ "${1:-}" = "api" ]; then
  case "$*" in
    *search/issues*)
      [ -z "${STUB_SEARCH_FAIL:-}" ] || { echo "gh: search boom" >&2; exit 1; }
      cat "$STUB_SEARCH"; exit 0 ;;
    */comments*)
      [ -z "${STUB_COMMENTS_FAIL:-}" ] || { echo "gh: comments boom" >&2; exit 1; }
      # pr-comments.sh 가 주는 `--jq` 를 그대로 적용해야 그 헬퍼의 계약(줄줄이 오브젝트)이
      # 재현된다 — 고정 문자열을 돌려주면 헬퍼를 통과하는지가 확인되지 않는다.
      jqf=""
      while [ $# -gt 0 ]; do
        [ "$1" = "--jq" ] && { jqf="$2"; break; }
        shift
      done
      jq -c "$jqf" "$STUB_COMMENTS"; exit 0 ;;
  esac
fi
exit 1
STUB
chmod +x "$tmp/bin/gh"

# ── jq 스텁 — 기본은 진짜 jq 로 그대로 넘긴다 ──────────────────────────────
# 쓰는 곳은 둘: 라벨 파싱(`# epic-labels`)과 leaf 번호 목록(`# leaf-list`)의 **도구 실패**가
# fail-closed 인지. 둘 다 입력이 이미 유효 JSON 이라 데이터(픽스처)로는 못 닿는다 — 유일한
# 도달 경로가 도구 실패라, 인자에 표식이 있는 **그 한 호출만** 실패시킨다.
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

# ── 픽스처 헬퍼 ────────────────────────────────────────────────────────────
# epics <json배열> — 열린 epic 라벨 이슈 목록
epics() { printf '%s' "$1" > "$tmp/epics.json"; }
# search <items json배열> [total_count] [incomplete]
search() {
  jq -n --argjson items "$1" \
        --argjson total "${2:-$(printf '%s' "$1" | jq 'length')}" \
        --argjson inc "${3:-false}" \
    '{total_count: $total, incomplete_results: $inc, items: $items}' > "$tmp/search.json"
}
comments() { printf '%s' "${1:-[]}" > "$tmp/comments.json"; }

reset() {
  epics '[{"number":100,"title":"에픽","labels":[{"name":"epic"}]}]'
  search '[]'
  comments '[]'
  : > "$tmp/gh.log"
  : > "$tmp/close.cnt"
  STUB_EPICS_FAIL=""; STUB_SEARCH_FAIL=""; STUB_COMMENT_FAIL=""; STUB_CLOSE_FAIL=""
  STUB_CLOSE_FAIL_TIMES=0
  STUB_COMMENTS_FAIL=""; STUB_JQ_FAIL_PAT=""
  WORKDIR="$tmp/work"; LIMIT=100; PER=100; ARGS=()
}

run() {
  (cd "$WORKDIR" && PATH="$tmp/bin:$PATH" \
    EPIC_LIST_LIMIT="${LIMIT:-100}" EPIC_SEARCH_PER_PAGE="${PER:-100}" \
    EPIC_CLOSE_RETRIES=3 EPIC_CLOSE_RETRY_SLEEP=0 \
    bash "$sut_dir/epic-sweep.sh" "${ARGS[@]+"${ARGS[@]}"}") >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}

export STUB_LOG="$tmp/gh.log" STUB_EPICS="$tmp/epics.json" STUB_SEARCH="$tmp/search.json"
export STUB_COMMENTS="$tmp/comments.json" STUB_CLOSE_CNT="$tmp/close.cnt"
export STUB_EPICS_FAIL="" STUB_SEARCH_FAIL="" STUB_COMMENT_FAIL="" STUB_CLOSE_FAIL=""
export STUB_CLOSE_FAIL_TIMES=0
export STUB_COMMENTS_FAIL="" STUB_JQ_FAIL_PAT=""
RC=0
out=""

ev()     { printf '%s' "$out" | jq -c 'select(.event=="'"$1"'")' 2>/dev/null; }
has_ev() { if [ -n "$(ev "$1")" ]; then echo ok; else echo no; fi; }
no_ev()  { if [ -z "$(ev "$1")" ]; then echo ok; else echo no; fi; }
# 쓰기 0 — 코멘트·close 명령이 로그에 한 줄도 없어야 한다
no_writes() {
  if grep -qE '^issue (comment|close)' "$tmp/gh.log"; then echo no; else echo ok; fi
}
# grep -c 는 매치가 0건이어도 "0" 을 찍고 **exit 1** 로 끝난다 — `|| echo 0` 를 붙이면
# 0 이 두 줄 나와 `[ "$(count_cmd …)" = 0 ]` 이 항상 거짓이 된다(가드가 통째로 공회전).
count_cmd() { local n; n=$(grep -cE "^$1" "$tmp/gh.log" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
json_lines_ok() {  # 모든 줄이 유효한 JSON 인가
  if [ -z "$out" ]; then echo ok; return; fi
  if printf '%s\n' "$out" | jq -e . >/dev/null 2>&1; then echo ok; else echo no; fi
}

# leaf 본문 한 줄 — 전용 줄
leaf() {  # leaf <번호> <에픽번호> <state>
  jq -n --argjson n "$1" --arg b "Epic #$2" --arg s "$3" \
    '{number:$n, state:$s, body:$b}'
}
# 본문을 그대로 주는 판 — 경계값 격자(④-d)가 쓴다
leaf_body() {  # leaf_body <번호> <본문> <state>
  jq -n --argjson n "$1" --arg b "$2" --arg s "$3" \
    '{number:$n, state:$s, body:$b}'
}

echo "── ① leaf 3 전부 닫힘 → closed + 코멘트 1 + close 1 ──"
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" --argjson b "$(leaf 102 100 closed)" \
  --argjson c "$(leaf 103 100 closed)" '[$a,$b,$c]')"
run
check "closed 이벤트" "$(has_ev closed)"
check "leaves 목록이 정확" \
  "$([ "$(ev closed | jq -c '.leaves')" = '[101,102,103]' ] && echo ok || echo no)"
check "number = 에픽 번호" \
  "$([ "$(ev closed | jq -r '.number')" = '100' ] && echo ok || echo no)"
check "repo 필드" "$([ "$(ev closed | jq -r '.repo')" = 'owner/repo' ] && echo ok || echo no)"
check "코멘트 1회" "$([ "$(count_cmd 'issue comment')" = 1 ] && echo ok || echo no)"
check "close 1회" "$([ "$(count_cmd 'issue close')" = 1 ] && echo ok || echo no)"
check "close 는 --reason completed" \
  "$(grep -q 'issue close .*--reason completed' "$tmp/gh.log" && echo ok || echo no)"
check "코멘트에 마커" "$(grep -q 'issue comment.*<!-- epic-sweep -->' "$tmp/gh.log" && echo ok || echo no)"
check "코멘트에 leaf 번호" \
  "$(grep -q 'issue comment.*#101 #102 #103' "$tmp/gh.log" && echo ok || echo no)"
check "에픽당 검색 1회" "$([ "$(count_cmd 'api .*search/issues')" = 1 ] && echo ok || echo no)"
check "rc 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "출력이 전부 JSON" "$(json_lines_ok)"

echo "── ② leaf 중 1건 열림 → 이벤트 0 · 쓰기 0 ──"
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" --argjson b "$(leaf 102 100 open)" '[$a,$b]')"
run
check "closed 없음" "$(no_ev closed)"
check "note 없음" "$(no_ev note)"
check "warn 없음" "$(no_ev warn)"
check "쓰기 0" "$(no_writes)"
check "rc 0" "$([ "$RC" = 0 ] && echo ok || echo no)"

echo "── ③ leaf 0 → note · 쓰기 0 ──"
reset
search '[]'
run
check "note 이벤트" "$(has_ev note)"
check "why = 연결된 leaf 없음" \
  "$([ "$(ev note | jq -r '.why')" = '연결된 leaf 없음' ] && echo ok || echo no)"
check "closed 없음" "$(no_ev closed)"
check "쓰기 0" "$(no_writes)"

echo "── ④ 산문 속 epic #N 은 leaf 아님 ──"
reset
search "$(jq -n '[{number:500, state:"closed", body:"이 문서는 epic #100 이야기를 지나가며 한다"}]')"
run
check "note(= leaf 0)" "$(has_ev note)"
check "closed 없음 — 산문을 leaf 로 세면 닫혔을 것" "$(no_ev closed)"
check "쓰기 0" "$(no_writes)"

echo "── ④-b Epic #1000 은 Epic #100 의 leaf 가 아니다(접두 오매치) ──"
reset
search "$(jq -n '[{number:501, state:"closed", body:"Epic #1000"}]')"
run
check "note(= leaf 0)" "$(has_ev note)"
check "closed 없음" "$(no_ev closed)"

echo "── ④-c 에픽 자신은 자기 leaf 가 아니다 ──"
reset
search "$(jq -n '[{number:100, state:"open", body:"Epic #100"}]')"
run
check "note(= leaf 0)" "$(has_ev note)"
check "쓰기 0" "$(no_writes)"

echo "── ④-d 전용 줄 경계 — 줄 시작이 Epic #N 이어도 뒤에 산문이 붙으면 leaf 아님 (#327) ──"
# 걸러야 할 것 / 걸러선 안 될 것을 **함께** 격자로 단다. 끝 앵커를 되돌리면(= `[[:space:]]*$`
# 를 지우면) 앞 칸 전부가 leaf 로 새고, 그 leaf 가 CLOSED 라 에픽 #100 이 **닫힌다** —
# 이 이슈(#327)가 지목한 실패 시나리오 그 자체다. 각 칸은 leaf 후보 **하나만** 두어
# "닫힘/안 닫힘" 이 곧 "leaf 로 셌다/안 셌다" 가 되게 한다.
# 걸러야 할 것 — leaf 0(note) · 쓰기 0
while IFS='|' read -r nm body; do
  [ -n "$nm" ] || continue
  reset
  search "$(jq -n --argjson a "$(leaf_body 510 "$body" closed)" '[$a]')"
  run
  check "④-d 제외: $nm → note(leaf 0)" "$(has_ev note)"
  check "④-d 제외: $nm → closed 없음(회귀 단언 — 앵커 없으면 여기서 닫혔다)" "$(no_ev closed)"
  check "④-d 제외: $nm → 쓰기 0" "$(no_writes)"
done <<'GRID'
뒤에 산문|Epic #100 설명
뒤에 괄호|Epic #100 (부모)
뒤에 콜론|Epic #100:
뒤에 다른 번호|Epic #100 #200
GRID
# 걸러선 안 될 것 — leaf 1(closed) · leaves=[511]
esc_tab=$(printf '\t')
esc_cr=$(printf '\r')
while IFS='|' read -r nm body; do
  [ -n "$nm" ] || continue
  body=${body//@TAB@/$esc_tab}
  body=${body//@CR@/$esc_cr}
  body=${body//@SP@/  }
  reset
  search "$(jq -n --argjson a "$(leaf_body 511 "$body" closed)" '[$a]')"
  run
  check "④-d 포함: $nm → closed" "$(has_ev closed)"
  check "④-d 포함: $nm → leaves=[511]" \
    "$([ "$(ev closed | jq -c '.leaves')" = '[511]' ] && echo ok || echo no)"
done <<'GRID'
전용 줄|Epic #100
앞뒤 공백 + 소문자|  epic #100@SP@
대문자|EPIC #100
줄 끝 탭|Epic #100@TAB@
CRLF 본문의 캐리지리턴|Epic #100@CR@
GRID
# ④-e 조임의 **반대 방향** — 전용 줄 CLOSED leaf + 문장형 OPEN 줄
# 조임은 leaf 를 빼는 변경이라 두 방향이 있다. ④-d 는 "문장형만 있던 에픽을 이제 안 닫는다"
# 쪽이고, 이 칸은 "문장형이 **열려 있어** 에픽을 붙잡고 있던 경우 이제 닫는다" 쪽이다 —
# 전용 줄 규약(#259)상 문장형은 애초에 leaf 가 아니므로 이게 의도한 의미론이지만, **닫는
# 방향**이라 되돌리기가 사람 일이다. 그래서 조용히 두지 않고 여기에 못 박는다.
# 실측: 루프 스코프 세 레포(BodaT·issue-runner·BoDAC)의 문장형 줄 4건은 **전부 CLOSED**
# 이슈에 있어, 이 조임으로 새로 닫히는 에픽은 현재 0건이다(PR 본문 실측표).
reset
search "$(jq -n --argjson a "$(leaf_body 520 "Epic #100" closed)" \
                --argjson b "$(leaf_body 521 "Epic #100 은 아직 논의 중" open)" '[$a,$b]')"
run
check "④-e 문장형 OPEN 줄은 에픽을 붙잡지 않는다 → closed" "$(has_ev closed)"
check "④-e leaves 는 전용 줄 하나뿐([520])" \
  "$([ "$(ev closed | jq -c '.leaves')" = '[520]' ] && echo ok || echo no)"
# 숫자 경계 — 한 자리 에픽(#1)도 그대로 leaf 로 센다(`[0-9]+` 가 최소 1자리).
# 이 두 칸은 **끝 앵커 뮤테이션으론 안 뒤집힌다**(무회귀 가드다, 반증이 아니다) — 번호를
# 수로 뽑아 비교하는 한 `Epic #10` 이 에픽 #1 로 새는 경로가 없기 때문이다. ④-b(`Epic #1000`
# ≠ `Epic #100`)의 한 자리 판으로 남긴다.
reset
epics '[{"number":1,"title":"한 자리 에픽","labels":[{"name":"epic"}]}]'
search "$(jq -n --argjson a "$(leaf_body 512 "Epic #1" closed)" '[$a]')"
run
check "④-d 숫자 경계: Epic #1 은 에픽 #1 의 leaf" "$(has_ev closed)"
check "④-d 숫자 경계: leaves=[512]" \
  "$([ "$(ev closed | jq -c '.leaves')" = '[512]' ] && echo ok || echo no)"
reset
epics '[{"number":1,"title":"한 자리 에픽","labels":[{"name":"epic"}]}]'
search "$(jq -n --argjson a "$(leaf_body 513 "Epic #10" closed)" '[$a]')"
run
check "④-d 숫자 경계: Epic #10 은 에픽 #1 의 leaf 가 아니다" "$(has_ev note)"
check "④-d 숫자 경계: 닫지 않는다" "$(no_ev closed)"

echo "── ⑤ 검색 상한 도달 → warn · 닫지 않음 ──"
reset
PER=2
search "$(jq -n --argjson a "$(leaf 101 100 closed)" --argjson b "$(leaf 102 100 closed)" '[$a,$b]')" 5
run
check "warn 이벤트" "$(has_ev warn)"
check "why 에 조회 상한" \
  "$(ev warn | jq -r '.why' | grep -q '조회 상한' && echo ok || echo no)"
check "closed 없음" "$(no_ev closed)"
check "쓰기 0" "$(no_writes)"
check "rc 0 — 실패가 아니라 보류" "$([ "$RC" = 0 ] && echo ok || echo no)"

echo "── ⑤-b incomplete_results → warn · 닫지 않음 ──"
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')" 1 true
run
check "warn 이벤트" "$(has_ev warn)"
check "closed 없음" "$(no_ev closed)"
check "쓰기 0" "$(no_writes)"

echo "── ⑤-c 에픽 목록 상한 도달 → warn ──"
reset
LIMIT=1
epics '[{"number":100,"title":"에픽","labels":[{"name":"epic"}]}]'
search '[]'
run
check "warn 이벤트" "$(has_ev warn)"
check "why 에 목록 상한" \
  "$(ev warn | jq -r '.why' | grep -q '목록 상한' && echo ok || echo no)"
check "rc 0" "$([ "$RC" = 0 ] && echo ok || echo no)"

echo "── ⑥ --dry-run → 쓰기 0 · dry_run:true ──"
reset
ARGS=(--dry-run)
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
run
check "closed 이벤트" "$(has_ev closed)"
check "dry_run:true" "$([ "$(ev closed | jq -r '.dry_run')" = 'true' ] && echo ok || echo no)"
check "쓰기 0" "$(no_writes)"
# 코멘트 조회는 **읽기**라 dry-run 에서도 한다(#377) — 마커 게이트(⑦)를 같은 판정으로 내야
# dry-run 이 "다시 닫겠다" 고 거짓 예측하지 않는다. 위치 무관으로 센다 — `^api repos` 는
# pr-comments.sh 가 인자 순서를 바꾸면(예 `--paginate` 를 앞으로) 조용히 매치 0 이 된다.
check "코멘트 조회 1회(읽기 — 마커 게이트도 dry-run 에서 같은 판정)" \
  "$([ "$(count_cmd 'api .*comments')" = 1 ] && echo ok || echo no)"
reset
ARGS=(--dry-run)
search '[]'
run
check "note 도 dry_run:true" "$([ "$(ev note | jq -r '.dry_run')" = 'true' ] && echo ok || echo no)"

echo "── ⑦ 마커가 있는데 열려 있다 = 사람이 되돌렸다 → note · 쓰기 0 (#377) ──"
# 스윕이 닫은 에픽을 사람이 재오픈한 다음 틱. 마커가 코멘트만 막고 close 는 안 막으면 여기서
# 다시 닫힌다(그리고 새 코멘트가 없어 흔적도 없다) — 이슈 #377 실측 그 자체.
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
comments '[{"body":"이전 틱 — leaf 전부 종료로 자동 종료 <!-- epic-sweep -->","created_at":"2026-09-11T00:00:00Z"}]'
run
check "closed 없음(회귀 단언 — 게이트 없으면 여기서 다시 닫혔다)" "$(no_ev closed)"
check "note 이벤트" "$(has_ev note)"
check "why 에 되돌림" "$(ev note | jq -r '.why' | grep -q '되돌' && echo ok || echo no)"
check "쓰기 0(코멘트도 close 도)" "$(no_writes)"
check "rc 0 — 실패가 아니라 정상 상태" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "마커 확인을 위해 코멘트를 조회한다(1회)" \
  "$([ "$(count_cmd 'api .*comments')" = 1 ] && echo ok || echo no)"
# dry-run 도 같은 판정 — 이슈의 실측이 `--dry-run` 으로 "다시 닫겠다" 를 봤다.
reset
ARGS=(--dry-run)
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
comments '[{"body":"이전 틱 — leaf 전부 종료로 자동 종료 <!-- epic-sweep -->","created_at":"2026-09-11T00:00:00Z"}]'
run
check "dry-run: closed 예측 없음" "$(no_ev closed)"
check "dry-run: note dry_run:true" "$([ "$(ev note | jq -r '.dry_run')" = 'true' ] && echo ok || echo no)"
check "dry-run: 쓰기 0" "$(no_writes)"

echo "── ⑦-b 코멘트 성공·close 실패는 같은 틱에서 재시도한다 (#377) ──"
# 다음 틱은 마커를 보고 사람 되돌림으로 읽으므로 이 중간 상태는 이월할 수 없다.
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_CLOSE_FAIL_TIMES=1
run
check "첫 close 실패 → 재시도로 닫힘(closed 이벤트)" "$(has_ev closed)"
check "close 2회(실패 1 + 성공 1)" "$([ "$(count_cmd 'issue close')" = 2 ] && echo ok || echo no)"
check "코멘트는 1회뿐" "$([ "$(count_cmd 'issue comment')" = 1 ] && echo ok || echo no)"
check "warn 없음" "$(no_ev warn)"
check "rc 0" "$([ "$RC" = 0 ] && echo ok || echo no)"

echo "── ⑧ deploy-wait 에픽은 건드리지 않는다 ──"
reset
epics '[{"number":100,"title":"에픽","labels":[{"name":"epic"},{"name":"deploy-wait"}]}]'
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
run
check "closed 없음" "$(no_ev closed)"
check "note" "$(has_ev note)"
check "why 에 deploy-wait" "$(ev note | jq -r '.why' | grep -q 'deploy-wait' && echo ok || echo no)"
check "쓰기 0" "$(no_writes)"
check "검색조차 안 한다(라벨로 먼저 거른다)" \
  "$([ "$(count_cmd 'api .*search/issues')" = 0 ] && echo ok || echo no)"

echo "── ⑧-b full-cycle·needs-human 에픽은 닫는다(정리이지 결정이 아니다) ──"
reset
epics '[{"number":100,"title":"에픽","labels":[{"name":"epic"},{"name":"full-cycle"},{"name":"needs-human"}]}]'
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
run
check "closed 이벤트" "$(has_ev closed)"
check "close 1회" "$([ "$(count_cmd 'issue close')" = 1 ] && echo ok || echo no)"

echo "── ⑨ 실패는 '해당 없음' 으로 위장되지 않는다 ──"
reset
STUB_SEARCH_FAIL=1
run
check "검색 실패 → warn" "$(has_ev warn)"
check "검색 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "검색 실패 → 쓰기 0" "$(no_writes)"
check "검색 실패 → note 로 접지 않는다" "$(no_ev note)"

reset
STUB_EPICS_FAIL=1
run
check "에픽 목록 실패 → warn" "$(has_ev warn)"
check "에픽 목록 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "에픽 목록 실패 → 쓰기 0" "$(no_writes)"

reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_COMMENT_FAIL=1
run
check "코멘트 실패 → warn" "$(has_ev warn)"
check "코멘트 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "코멘트 실패 → close 안 함(다음 틱이 코멘트부터 재시도)" \
  "$([ "$(count_cmd 'issue close')" = 0 ] && echo ok || echo no)"
check "코멘트 실패 → closed 이벤트 없음" "$(no_ev closed)"

reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_CLOSE_FAIL=1
run
check "close 실패 → warn" "$(has_ev warn)"
check "close 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "close 실패 → closed 이벤트 없음" "$(no_ev closed)"
check "close 실패 → 상한(3)까지 같은 틱에서 재시도" \
  "$([ "$(count_cmd 'issue close')" = 3 ] && echo ok || echo no)"
check "close 실패 → why 가 다음 틱 재시도 없음을 말한다(마커가 남아 되돌림으로 읽힌다)" \
  "$(ev warn | jq -r '.why' | grep -q '다음 틱.*재시도하지 않' && echo ok || echo no)"

reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_COMMENTS_FAIL=1
run
check "마커 조회 실패 → warn" "$(has_ev warn)"
check "마커 조회 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "마커 조회 실패 → 쓰기 0(중복 코멘트 위험)" "$(no_writes)"

reset
epics '[{"number":100,"title":"에픽","labels":[{"name":"epic"},{"name":"deploy-wait"}]}]'
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_JQ_FAIL_PAT="epic-labels"
run
check "라벨 파싱 실패 → warn" "$(has_ev warn)"
check "라벨 파싱 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "라벨 파싱 실패 → 쓰기 0(deploy-wait 를 '없다' 로 읽지 않는다)" "$(no_writes)"
check "라벨 파싱 실패 → 검색조차 안 한다" \
  "$([ "$(count_cmd 'api .*search/issues')" = 0 ] && echo ok || echo no)"

reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_JQ_FAIL_PAT="leaf-list"
run
check "leaf 목록 생성 실패 → warn" "$(has_ev warn)"
check "leaf 목록 생성 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "leaf 목록 생성 실패 → 쓰기 0(근거 빈 코멘트로 닫지 않는다)" "$(no_writes)"
check "leaf 목록 생성 실패 → closed 이벤트 없음" "$(no_ev closed)"

echo "── ⑩ 스코프 ──"
reset
WORKDIR="$tmp/noscope"
run
check ".loop/repos 없고 --repo 도 없으면 exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
check "쓰기 0" "$(no_writes)"

reset
WORKDIR="$tmp/noscope"
ARGS=(--repo owner/repo)
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
run
check "--repo 로 스코프 지정" "$(has_ev closed)"

reset
WORKDIR="$tmp/noscope"
ARGS=(--repos-file "$tmp/work/.loop/repos")
search '[]'
run
check "--repos-file 로 스코프 지정" "$(has_ev note)"

reset
WORKDIR="$tmp/noscope"
ARGS=(--repos-file "$tmp/nope")
run
check "없는 --repos-file 은 exit 64" "$([ "$RC" = 64 ] && echo ok || echo no)"

echo "── ⑪ leaf 판정 정규식은 loop-status.sh 와 같은 문자열 ──"
# 두 계산기가 다른 leaf 를 세면 "에픽 leaf 전부 종료" warn 과 실제 종료가 갈린다.
pat_ls=$(grep -o 'capture("[^"]*epic[^"]*"; *"i")' "$DIR/loop-status.sh" | head -1)
pat_es=$(grep -o 'capture("[^"]*epic[^"]*"; *"i")' "$DIR/epic-sweep.sh" | head -1)
check "loop-status.sh 에 Epic 줄 capture 존재" "$([ -n "$pat_ls" ] && echo ok || echo no)"
check "epic-sweep.sh 가 같은 capture 를 쓴다" \
  "$([ -n "$pat_es" ] && [ "$pat_ls" = "$pat_es" ] && echo ok || echo no)"

# ⑪-b (#327) 두 파일이 **함께** 되돌아가면 ⑪ 은 계속 초록이다 — 끝 앵커의 존재를 따로 문다.
# 없앨 때 통과하던 형태(`Epic #100 설명`)의 행동은 ④-d 격자가 물고, 여기선 문자열 자체를 문다.
case "$pat_es" in
  *'#(?<n>[0-9]+)[[:space:]]*$"; "i")') anchored=ok ;;
  *) anchored=no ;;
esac
check "⑪-b 끝 앵커([[:space:]]*\$) — 전용 줄만 leaf (#327)" "$anchored"

echo "epic-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
