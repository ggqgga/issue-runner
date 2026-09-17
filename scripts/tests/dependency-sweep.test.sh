#!/usr/bin/env bash
# dependency-sweep.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# epic-sweep.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것(#581 수용 기준 — 격자는 이슈 Test plan 의 일곱 칸 + 조회 실패·422 판정어, 칸마다 1케이스):
#   ① 본문 `Blocked by #N` 줄만 있는 쌍 → linked + POST 1(블로커의 REST id 로)
#   ② `blocked-by:<N>` 라벨만 있는 쌍 → linked + POST 1
#   ③ 이미 네이티브 관계가 있는 쌍 → 쓰기 0. 본문에 없는 기존 관계도 지우지 않는다(DELETE 0)
#   ④ 닫힌 블로커 → 쓰기 0
#   ⑤ 산문 속 `blocked by #N`(줄 시작 아님) → 블로커가 아니다(쓰기 0)
#   ⑥ `--dry-run` → 쓰기 0 · 이벤트에 dry_run:true
#   ⑦ POST 실패 1건 → warn + rc 1, 다음 쌍은 계속 linked
#   ⑧ 조회 실패(블로커 조회) → warn + rc 1, 다음 쌍은 계속 linked
#   ⑨ 422 라도 "already" 가 아닌 사유("does not exist")는 진짜 실패다 → warn + rc 1
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
mkdir -p "$sut_dir" "$tmp/bin" "$tmp/work/.loop"
cp "$DIR/dependency-sweep.sh" "$sut_dir/dependency-sweep.sh"
cp -R "$DIR/lib" "$sut_dir/lib"
chmod +x "$sut_dir"/*.sh
echo 'owner/repo' > "$tmp/work/.loop/repos"

# ── gh 스텁 ────────────────────────────────────────────────────────────────
# issue list → $STUB_LIST · api issues/<b> → $STUB_ISSUES[b](없으면 404) ·
# api issues/<n>/dependencies/blocked_by GET → $STUB_DEPS[n] · POST → 로그만(실패 번호는 $STUB_POST_FAIL).
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
cat >/dev/null
case "${1:-} ${2:-}" in
  "issue list") cat "$STUB_LIST"; exit 0 ;;
esac
[ "${1:-}" = "api" ] || exit 1
method=GET
path=""
jqf=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --jq) jqf="$2"; shift ;;
    -F|-f) shift ;;
    --paginate) ;;
    *) path="$1" ;;
  esac
  shift
done
path="${path%%\?*}"
case "$path" in
  repos/owner/repo/issues/*/dependencies/blocked_by)
    n="${path#repos/owner/repo/issues/}"; n="${n%%/*}"
    if [ "$method" = "POST" ]; then
      case " ${STUB_POST_FAIL:-} " in *" $n "*) echo "gh: boom (HTTP 500)" >&2; exit 1 ;; esac
      [ -z "${STUB_POST_422:-}" ] || { echo "{\"message\":\"$STUB_POST_422\"}"; echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
      echo '{}'; exit 0
    fi
    out=$(jq -c --arg n "$n" '.[$n] // []' "$STUB_DEPS")
    if [ -n "$jqf" ]; then printf '%s' "$out" | jq -r "$jqf"; else printf '%s\n' "$out"; fi
    exit 0 ;;
  repos/owner/repo/issues/*)
    b="${path#repos/owner/repo/issues/}"
    case " ${STUB_ISSUE_FAIL:-} " in *" $b "*) echo "gh: boom (HTTP 502)" >&2; exit 1 ;; esac
    out=$(jq -c --arg b "$b" '.[$b] // empty' "$STUB_ISSUES")
    [ -n "$out" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [ -n "$jqf" ]; then printf '%s' "$out" | jq -r "$jqf"; else printf '%s\n' "$out"; fi
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp/bin/gh"

export STUB_LOG="$tmp/gh.log" STUB_LIST="$tmp/list.json" STUB_ISSUES="$tmp/issues.json" STUB_DEPS="$tmp/deps.json"
export STUB_POST_FAIL="" STUB_ISSUE_FAIL="" STUB_POST_422=""

# issue <번호> <본문> [라벨 콤마목록] — 열린 이슈 목록의 한 행
issue() {
  jq -nc --argjson n "$1" --arg b "$2" --arg l "${3:-}" \
    '{number:$n, body:$b, labels:([$l | split(",")[] | select(. != "") | {name:.}])}'
}
list() { printf '%s' "$1" > "$STUB_LIST"; }

reset() {
  list '[]'
  # 블로커 5 는 열림(id 5005), 6 은 닫힘(id 6006), 7 은 열림(id 7007)
  printf '%s' '{"5":{"id":5005,"number":5,"state":"open"},"6":{"id":6006,"number":6,"state":"closed"},"7":{"id":7007,"number":7,"state":"open"}}' > "$STUB_ISSUES"
  printf '%s' '{}' > "$STUB_DEPS"
  : > "$STUB_LOG"
  STUB_POST_FAIL=""; STUB_ISSUE_FAIL=""; STUB_POST_422=""
  ARGS=()
}

run() {
  (cd "$tmp/work" && PATH="$tmp/bin:$PATH" \
    bash "$sut_dir/dependency-sweep.sh" "${ARGS[@]+"${ARGS[@]}"}" </dev/null) >"$tmp/out" 2>"$tmp/err"
  RC=$?
  out=$(cat "$tmp/out")
}

ev() { printf '%s' "$out" | jq -c 'select(.event=="'"$1"'")' 2>/dev/null; }
posts() { local n; n=$(grep -cE '(^| )-X POST' "$STUB_LOG" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
no_delete() { if grep -q 'DELETE' "$STUB_LOG"; then echo no; else echo ok; fi; }
is() { [ "$1" = "$2" ] && echo ok || echo "no($1≠$2)"; }

echo "── ① 본문 줄만 → linked + POST 1 ──"
reset
list "[$(issue 10 $'설명\nBlocked by #5 — 스키마를 읽는다')]"
run
check "① linked 1건" "$(is "$(ev linked | jq -c '[.number,.blocker]')" '[10,5]')"
check "① POST 1회" "$(is "$(posts)" 1)"
check "① POST 는 블로커 REST id" "$(grep -q 'issues/10/dependencies/blocked_by.*issue_id=5005' "$STUB_LOG" && echo ok || echo no)"
check "① rc 0" "$(is "$RC" 0)"

echo "── ② 라벨만 → linked + POST 1 ──"
reset
list "[$(issue 11 '본문' 'agent-ready,blocked-by:7')]"
run
check "② linked 1건" "$(is "$(ev linked | jq -c '[.number,.blocker]')" '[11,7]')"
check "② POST 1회" "$(is "$(posts)" 1)"

echo "── ③ 이미 있음 → 쓰기 0 · 본문에 없는 관계 보존 ──"
reset
list "[$(issue 12 'Blocked by #5')]"
printf '%s' '{"12":[{"id":5005,"number":5},{"id":9009,"number":9}]}' > "$STUB_DEPS"
run
check "③ POST 0" "$(is "$(posts)" 0)"
check "③ DELETE 0" "$(no_delete)"
check "③ linked 없음" "$(is "$(ev linked)" '')"
check "③ rc 0" "$(is "$RC" 0)"

echo "── ④ 닫힌 블로커 → 쓰기 0 ──"
reset
list "[$(issue 13 'Blocked by #6')]"
run
check "④ POST 0" "$(is "$(posts)" 0)"
check "④ rc 0" "$(is "$RC" 0)"

echo "── ⑤ 산문 언급 → 블로커 아님 ──"
reset
list "[$(issue 14 '이건 사실상 blocked by #5 인 셈이다')]"
run
check "⑤ POST 0" "$(is "$(posts)" 0)"
check "⑤ linked 없음" "$(is "$(ev linked)" '')"

echo "── ⑥ --dry-run → 쓰기 0 · dry_run:true ──"
reset
ARGS=(--dry-run)
list "[$(issue 15 'Blocked by #5')]"
run
check "⑥ POST 0" "$(is "$(posts)" 0)"
check "⑥ linked 예측에 dry_run:true" "$(is "$(ev linked | jq -r '.dry_run')" true)"

echo "── ⑦ POST 실패 1건 → warn + rc 1, 다음 쌍 계속 ──"
reset
list "[$(issue 16 'Blocked by #5'),$(issue 17 'Blocked by #7')]"
STUB_POST_FAIL="16"
run
check "⑦ warn 은 #16" "$(is "$(ev warn | jq -r '.number')" 16)"
check "⑦ #17 은 linked" "$(is "$(ev linked | jq -c '[.number,.blocker]')" '[17,7]')"
check "⑦ rc 1" "$(is "$RC" 1)"

echo "── ⑧ 블로커 조회 실패 → warn + rc 1, 다음 쌍 계속 ──"
reset
list "[$(issue 18 $'Blocked by #7\nblocked-by #5')]"
STUB_ISSUE_FAIL="7"
run
check "⑧ warn 은 #18 ← #7" "$(is "$(ev warn | jq -c '[.number,.blocker]')" '[18,7]')"
check "⑧ #18 ← #5 는 linked" "$(is "$(ev linked | jq -c '[.number,.blocker]')" '[18,5]')"
check "⑧ rc 1" "$(is "$RC" 1)"

echo "── ⑨ 422 does not exist → warn + rc 1 ──"
reset
list "[$(issue 19 'Blocked by #5')]"
STUB_POST_422="Issue does not exist"
run
check "⑨ warn 은 #19" "$(is "$(ev warn | jq -r '.number')" 19)"
check "⑨ note 로 묻히지 않는다" "$(is "$(ev note)" '')"
check "⑨ rc 1" "$(is "$RC" 1)"

echo "dependency-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
