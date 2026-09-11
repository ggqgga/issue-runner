#!/usr/bin/env bash
# epic-sweep.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 resume-sweep.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것(#258 수용 기준):
#   ① leaf 가 1건 이상이고 **전부 CLOSED** → closed 이벤트 + 코멘트 1 + close 1.
#   ② leaf 중 하나라도 열려 있으면 **쓰기 0**·이벤트 0(조용히 넘긴다).
#   ③ leaf 0 → note("연결된 leaf 없음")·쓰기 0. 옛 에픽은 닫지 않는다.
#   ④ 산문 속 `… epic #N …`(줄 시작 아님)은 leaf 가 아니다 — 검색은 산문도 물어 온다.
#   ⑤ 검색이 상한에 닿으면 **닫지 않고** warn(조용한 오판 금지) — rc 는 0(실패 아님, 보류).
#   ⑥ `--dry-run` 은 쓰기 0 으로 같은 이벤트를 `dry_run:true` 로 낸다.
#   ⑦ 마커(`<!-- epic-sweep -->`)가 이미 있으면 코멘트를 다시 안 달고 close 만 한다(멱등).
#   ⑧ `deploy-wait` 에픽은 건드리지 않는다 · `full-cycle`·`needs-human` 에픽은 닫는다.
#   ⑨ 조회·쓰기 실패는 "해당 없음" 으로 위장되지 않는다(warn + exit 1) — 코멘트가 실패하면
#      close 까지 가지 않는다(다음 틱이 코멘트부터 다시 시도).
#   ⑩ leaf 판정 정규식은 loop-status.sh(#260)와 **같은 문자열**이다(두 계산기 금지).
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
  STUB_EPICS_FAIL=""; STUB_SEARCH_FAIL=""; STUB_COMMENT_FAIL=""; STUB_CLOSE_FAIL=""
  STUB_COMMENTS_FAIL=""
  WORKDIR="$tmp/work"; LIMIT=100; PER=100; ARGS=()
}

run() {
  (cd "$WORKDIR" && PATH="$tmp/bin:$PATH" \
    EPIC_LIST_LIMIT="${LIMIT:-100}" EPIC_SEARCH_PER_PAGE="${PER:-100}" \
    bash "$sut_dir/epic-sweep.sh" "${ARGS[@]+"${ARGS[@]}"}") >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}

export STUB_LOG="$tmp/gh.log" STUB_EPICS="$tmp/epics.json" STUB_SEARCH="$tmp/search.json"
export STUB_COMMENTS="$tmp/comments.json"
export STUB_EPICS_FAIL="" STUB_SEARCH_FAIL="" STUB_COMMENT_FAIL="" STUB_CLOSE_FAIL=""
export STUB_COMMENTS_FAIL=""
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
check "코멘트 조회조차 안 한다" "$([ "$(count_cmd 'api repos')" = 0 ] && echo ok || echo no)"
reset
ARGS=(--dry-run)
search '[]'
run
check "note 도 dry_run:true" "$([ "$(ev note | jq -r '.dry_run')" = 'true' ] && echo ok || echo no)"

echo "── ⑦ 마커가 이미 있으면 코멘트 안 달고 close 만 ──"
reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
comments '[{"body":"이전 틱 — leaf 전부 종료로 자동 종료 <!-- epic-sweep -->","created_at":"2026-09-11T00:00:00Z"}]'
run
check "closed 이벤트" "$(has_ev closed)"
check "코멘트 0회" "$([ "$(count_cmd 'issue comment')" = 0 ] && echo ok || echo no)"
check "close 1회" "$([ "$(count_cmd 'issue close')" = 1 ] && echo ok || echo no)"

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

reset
search "$(jq -n --argjson a "$(leaf 101 100 closed)" '[$a]')"
STUB_COMMENTS_FAIL=1
run
check "마커 조회 실패 → warn" "$(has_ev warn)"
check "마커 조회 실패 → rc 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "마커 조회 실패 → 쓰기 0(중복 코멘트 위험)" "$(no_writes)"

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

echo "epic-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
