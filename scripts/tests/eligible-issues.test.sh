#!/usr/bin/env bash
# eligible-issues.test.sh 픽스처 테스트 (#247) — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# 가드하는 것:
#   ① 블로커 없는 후보는 stdout 에 남는다 — 그리고 **stdout 바이트가 그대로다**
#      (디스패처 파이프라인의 SSOT. 진단이 한 글자라도 새면 여기서 빨개진다).
#   ② OPEN 블로커로 탈락한 이슈마다 stderr `blocked: <repo>#<num> ← #<b>(<상태>)`.
#      `<상태>` 는 블로커의 라벨로 정한다(needs-human→사람대기 · agent:claimed→구현중 ·
#      flow:verify→검증대기 · flow:ready→마감대기 · harvesting→마감중 · 그 밖→대기).
#   ③ 블로커가 CLOSED·MERGED(PR)·미존재면 통과하고 `blocked:` 줄이 없다.
#   ④ 블로커 조회 일시 오류는 `(조회오류)` — 빈 결과와 실패를 구분한다(PR#139).
#   ⑤ 본문 `Blocked by #N` 과 라벨 `blocked-by:N` 이 같은 번호를 가리키면 **한 번만** 조회한다
#      (dedupe). 한 이슈에 OPEN 블로커가 둘이면 첫 번째에서 멈춘다(break 유지 = 호출 수 증가 0).
#   ⑥ 검색 창 경고 — `total_count > 50` 절단 · `40 < total ≤ 50` 임박 · 40 이하 침묵.
#      경계(40·41·50·51)를 함께 문다.
#   ⑦ 스캔 끝 요약 `blocked-summary: 막힘 N건 (사람대기 블로커 M건)` 의 N·M 이 정확하다.
#
# 에픽 finish-first 정렬 (#257) — Ⓔ 로 시작하는 절:
#   Ⓔ① `Epic #N` 이 하나도 없는 입력은 **순서가 종전과 같다**(회귀 0) + 새 필드는 null/false.
#   Ⓔ② 같은 P 안에서 시작한 에픽의 leaf 가 앞으로 온다(늦게 만들어졌어도).
#   Ⓔ③ 에픽 축은 P 경계를 넘지 않는다 — P1 단발이 P2 에픽 leaf 보다 앞.
#   Ⓔ④ 시작 판정 출처 (a) — 진행 라벨(agent:claimed·flow:verify·flow:ready·harvesting) row 의
#       **검색 item body**. 그 row 들에 `gh issue view --json body` 를 부르지 않는다(호출 수 불변).
#   Ⓔ⑤ 시작 판정 출처 (b) — 최근 닫힌 leaf. 키는 **same-repo**(`repo#N`)라 다른 레포는 안 센다.
#   Ⓔ⑥ 산문 속 `… epic #N …` 은 안 잡히고, 앞 공백만 있는 줄 시작은 잡힌다.
#   Ⓔ⑦ (b) 조회 실패 → 정확한 warn 한 줄 + 시작 집합을 통째로 비워 **정렬은 종전**.
#
# 기대 줄은 **손으로 적는다** — SUT 의 jq 를 베껴 기대값을 만들면 공허하게 통과한다
# (loop-status.test.sh·transition.test.sh 의 관행).
# 스텁은 **원본 API 응답 픽스처**를 들고 SUT 가 넘긴 `-q` 를 직접 적용한다 — 필터를 스텁이
# 대신 흉내 내면 SUT 의 필터가 틀려도 통과한다(loop-status.test.sh 의 timeline 스텁과 같은 관행).
# 예기치 않은 호출 형태는 조용한 빈 JSON 대신 exit 1 로 드러낸다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/eligible-issues.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 작업 cwd — $PWD/.loop/repos 부재라 in_scope 는 전 레포 허용(fail-open, hold-gate.test.sh 전제와 동일)
cwd="$tmp/cwd"
mkdir -p "$cwd"

pass=0
fail=0
ck() {  # ck <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; echo "      기대: [$3]"; echo "      실제: [$2]"; fi
}
has_line() {  # has_line <이름> <파일> <정확히 일치할 줄>
  if grep -qxF -- "$3" "$2"; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; echo "      기대(줄): [$3]"; echo "      실제:"; sed 's/^/        /' "$2"; fi
}
no_line() {  # no_line <이름> <파일> <나오면 안 되는 부분문자열>
  if grep -qF -- "$3" "$2"; then fail=$((fail + 1)); echo "  ✗ $1"; echo "      나오면 안 됨: [$3]"; echo "      실제:"; sed 's/^/        /' "$2"
  else pass=$((pass + 1)); fi
}
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# ── gh PATH 스텁 ───────────────────────────────────────────────────────────
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
jqf=""
prev=""
for a in "$@"; do
  case "$prev" in -q|--jq) jqf="$a" ;; esac
  prev="$a"
done

# gh-login.sh 의 사용자 확인 (REST → GraphQL 폴백 순서)
case "$args" in
  *"api user"*|*"api graphql"*) printf 'tester\n'; exit 0 ;;
esac

# 에픽 시작 집합 (b) 의 닫힌 leaf 검색 (#257) — 후보 검색과 **다른 토큰**으로 적는다
# (`search` 를 세는 기존 칸이 이 호출까지 끌어가면 안 된다).
case "$args" in
  *"is:closed"*)
    printf 'closed-scan\n' >> "$STUB_CALL_LOG"
    if [ -f "$STUB_DIR/closed.fail" ]; then
      cat "$STUB_DIR/closed.fail" >&2
      exit 1
    fi
    [ -n "$jqf" ] || { echo "gh stub: 닫힌 leaf 검색은 -q 로 불러야 한다: $args" >&2; exit 1; }
    jq -r "$jqf" "$STUB_DIR/closed.json" || exit 1
    exit 0 ;;
esac

case "$args" in
  *search/issues*)
    printf 'search\n' >> "$STUB_CALL_LOG"
    [ -n "$jqf" ] || { echo "gh stub: search 는 -q 로 불러야 한다: $args" >&2; exit 1; }
    jq -r "$jqf" "$STUB_DIR/search.json" || exit 1
    exit 0 ;;
esac

if [ "${1:-} ${2:-}" = "issue view" ]; then
  num="${3:-}"
  case "$args" in
    *"--json body"*)
      printf 'body %s\n' "$num" >> "$STUB_CALL_LOG"
      [ -n "$jqf" ] || { echo "gh stub: 본문 조회는 -q 로 불러야 한다: $args" >&2; exit 1; }
      [ -f "$STUB_DIR/body.$num.json" ] || { echo "gh stub: 본문 픽스처 없음: #$num" >&2; exit 1; }
      jq -r "$jqf" "$STUB_DIR/body.$num.json" || exit 1
      exit 0 ;;
    *"--json state,labels"*)
      printf 'blocker %s\n' "$num" >> "$STUB_CALL_LOG"
      [ -n "$jqf" ] || { echo "gh stub: 블로커 조회는 -q 로 불러야 한다: $args" >&2; exit 1; }
      if [ -f "$STUB_DIR/blocker.$num.fail" ]; then
        cat "$STUB_DIR/blocker.$num.fail" >&2
        exit 1
      fi
      [ -f "$STUB_DIR/blocker.$num.json" ] || { echo "gh stub: 블로커 픽스처 없음: #$num" >&2; exit 1; }
      jq -r "$jqf" "$STUB_DIR/blocker.$num.json" || exit 1
      exit 0 ;;
  esac
fi
echo "gh stub: 예기치 않은 호출: $args" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

# ── 픽스처 빌더 ────────────────────────────────────────────────────────────
mkfx() {  # mkfx <이름> <total_count> → 픽스처 디렉터리 경로(빈 items)
  local fx="$tmp/fx.$1"
  mkdir -p "$fx"
  printf '{"total_count":%s,"items":[]}\n' "$2" > "$fx/search.json"
  # (b) 닫힌 leaf 검색은 **매 틱 한 번** 불린다 — 기본은 빈 결과(시작 집합 없음)다.
  printf '{"items":[]}\n' > "$fx/closed.json"
  printf '%s' "$fx"
}
add_issue() {  # add_issue <fx> <num> <라벨 JSON 배열(문자열)> <제목> <본문> [생성시각]
  local fx="$1" num="$2" labels="$3" title="$4" body="$5" created="${6:-2026-01-01T00:00:00Z}"
  # 실제 REST `search/issues` 의 item 은 `body` 를 포함한다(#257 실측) — 진행 라벨 row 의
  # 에픽 판정이 그 필드를 쓰므로 스텁도 같은 형상이어야 한다.
  jq --argjson n "$num" --argjson l "$labels" --arg t "$title" --arg c "$created" --arg b "$body" \
    '.items += [{repository_url: "https://api.github.com/repos/owner/repo",
                 number: $n, title: $t,
                 labels: [$l[] | {name: .}],
                 created_at: $c, body: $b}]' "$fx/search.json" > "$fx/s.tmp"
  mv "$fx/s.tmp" "$fx/search.json"
  jq -n --arg b "$body" '{body: $b}' > "$fx/body.$num.json"
}
add_blocker() {  # add_blocker <fx> <num> <state> <라벨 JSON 배열(문자열)>
  jq -n --arg s "$3" --argjson l "$4" '{state: $s, labels: [$l[] | {name: .}]}' > "$1/blocker.$2.json"
}
add_blocker_fail() {  # add_blocker_fail <fx> <num> <에러문>
  printf '%s\n' "$3" > "$1/blocker.$2.fail"
}
add_closed_leaf() {  # add_closed_leaf <fx> <owner/repo> <본문>
  jq --arg r "https://api.github.com/repos/$2" --arg b "$3" \
    '.items += [{repository_url: $r, body: $b}]' "$1/closed.json" > "$1/c.tmp"
  mv "$1/c.tmp" "$1/closed.json"
}
set_closed_fail() {  # set_closed_fail <fx> <에러문>
  printf '%s\n' "$2" > "$1/closed.fail"
}

OUT=""; ERR=""; LOG=""; RC=0
run_sut() {  # run_sut <fx>
  OUT="$1/stdout"; ERR="$1/stderr"; LOG="$1/calls.log"
  : > "$LOG"
  RC=0
  ( cd "$cwd" && PATH="$tmp/bin:$PATH" STUB_DIR="$1" STUB_CALL_LOG="$LOG" \
      bash "$SUT" ) > "$OUT" 2> "$ERR" || RC=$?
}

# ── ① 블로커 없음 → stdout 포함 · stdout 바이트 불변 · 블로커 조회 0회 ──────
fx=$(mkfx a 34)
# 줄 머리가 아닌 곳의 "blocked by #900" 은 블로커가 아니다(과잉 제외 금지 — 정상 후보 소실).
add_issue "$fx" 10 '["agent-ready","P1"]' '블로커 없음' \
  '설명 한 줄
이 건은 한때 blocked by #900 이라고 적혀 있었지만 지금은 아니다.'
run_sut "$fx"
ck "① exit 0" "$RC" "0"
# 기대 stdout 은 손으로 적는다 — jq 기본(2칸 들여쓰기) 형식 그대로.
cat > "$tmp/want.a" <<'WANT'
[
  {
    "repo": "owner/repo",
    "number": 10,
    "title": "블로커 없음",
    "priority": 1,
    "createdAt": "2026-01-01T00:00:00Z",
    "epic": null,
    "epic_started": false
  }
]
WANT
# `$( )` 대조는 양 끝 개행을 잘라 먹는다 — 후행 개행이 생기거나 사라져도 통과한다.
# 이 이슈의 심장이 "stdout 이 한 바이트도 안 바뀐다" 이므로 여기는 cmp 로 바이트를 맞댄다.
if cmp -s "$OUT" "$tmp/want.a"; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "  ✗ ① stdout 바이트 동일(진단이 stdout 으로 새지 않는다)"; diff "$tmp/want.a" "$OUT" | sed 's/^/      /'; fi
no_line "① blocked: 줄 없음" "$ERR" "blocked: "
has_line "① 요약 — 막힘 0건" "$ERR" "blocked-summary: 막힘 0건"
ck "① 블로커 조회 0회" "$(count_of "$LOG" 'blocker ')" "0"
ck "① 본문 조회 1회" "$(count_of "$LOG" 'body 10')" "1"
ck "① 검색 1회" "$(count_of "$LOG" 'search')" "1"
no_line "① 창 경고 침묵(34 ≤ 40)" "$ERR" "warn: 검색 창"

# ── ②③④⑦ 블로커 상태 격자 ────────────────────────────────────────────────
fx=$(mkfx b 34)
add_issue "$fx" 11 '["agent-ready"]' '사람대기 블로커' 'Blocked by #900'
add_issue "$fx" 12 '["agent-ready"]' '구현중 블로커' 'Blocked by #901'
add_issue "$fx" 13 '["agent-ready"]' '검증대기 블로커' 'Blocked by #902'
add_issue "$fx" 14 '["agent-ready"]' '마감대기 블로커' 'Blocked by #903'
add_issue "$fx" 15 '["agent-ready"]' '마감중 블로커' 'Blocked by #904'
add_issue "$fx" 16 '["agent-ready"]' '라벨 없는 블로커' 'Blocked by #905'
add_issue "$fx" 17 '["agent-ready"]' 'CLOSED 블로커' 'Blocked by #906' '2026-01-01T00:00:17Z'
add_issue "$fx" 18 '["agent-ready"]' 'MERGED PR 블로커' 'Blocked by #907' '2026-01-01T00:00:18Z'
add_issue "$fx" 19 '["agent-ready"]' '조회 실패 블로커' 'Blocked by #908'
add_issue "$fx" 20 '["agent-ready"]' '미존재 블로커' 'Blocked by #909' '2026-01-01T00:00:20Z'
add_blocker "$fx" 900 OPEN   '["needs-human","hold:policy"]'
add_blocker "$fx" 901 OPEN   '["agent-ready","agent:claimed"]'
add_blocker "$fx" 902 OPEN   '["agent-ready","flow:verify"]'
add_blocker "$fx" 903 OPEN   '["agent-ready","flow:ready"]'
add_blocker "$fx" 904 OPEN   '["agent-ready","harvesting"]'
add_blocker "$fx" 905 OPEN   '[]'
add_blocker "$fx" 906 CLOSED '["agent-ready"]'
add_blocker "$fx" 907 MERGED '[]'
add_blocker_fail "$fx" 908 'gh: HTTP 502 Bad Gateway'
add_blocker_fail "$fx" 909 'GraphQL: Could not resolve to an Issue with the number of 909.'
run_sut "$fx"
ck "② exit 0" "$RC" "0"
has_line "② 사람대기"   "$ERR" "blocked: owner/repo#11 ← #900(사람대기)"
has_line "② 구현중"     "$ERR" "blocked: owner/repo#12 ← #901(구현중)"
has_line "② 검증대기"   "$ERR" "blocked: owner/repo#13 ← #902(검증대기)"
has_line "② 마감대기"   "$ERR" "blocked: owner/repo#14 ← #903(마감대기)"
has_line "② 마감중"     "$ERR" "blocked: owner/repo#15 ← #904(마감중)"
has_line "② 그 밖은 대기" "$ERR" "blocked: owner/repo#16 ← #905(대기)"
ck "③ CLOSED 는 blocked 줄 없음" "$(count_of "$ERR" 'blocked: owner/repo#17')" "0"
ck "③ MERGED PR 은 blocked 줄 없음" "$(count_of "$ERR" 'blocked: owner/repo#18')" "0"
has_line "④ 조회 일시 오류 → (조회오류)" "$ERR" "blocked: owner/repo#19 ← #908(조회오류)"
# 미존재는 게이트 무시(통과)라 `blocked:` 줄이 없다 — 다만 기존 warn 은 그대로 남는다
# (통과시킨 이유를 말하지 않으면 "왜 막힌 채로 안 남았지" 를 다음 사람이 못 읽는다).
ck "③ 미존재 블로커는 blocked 줄 없음(게이트 무시)" "$(count_of "$ERR" 'blocked: owner/repo#20')" "0"
has_line "③ 미존재는 이유를 warn 으로 남긴다" "$ERR" \
  "warn: owner/repo#20 blocked-by #909 미존재 — 영구 정체 방지 위해 게이트 무시(통과)"
# 통과한 셋만 stdout 에 남는다 — 번호를 손으로 적는다.
# 통과분의 createdAt 을 서로 다르게 줬으므로 이 순서는 sort_by 의 안정성이 아니라
# **정렬 자체**가 근거다(셋 다 우선순위 없음 = 3).
ck "②③ stdout 통과분(오래된 순)" \
  "$(jq -c '[.[].number]' "$OUT")" '[17,18,20]'
no_line "② 진단이 stdout 으로 새지 않는다" "$OUT" "blocked"
has_line "⑦ 요약 — 막힘 7건 · 사람대기 1건" "$ERR" "blocked-summary: 막힘 7건 (사람대기 블로커 1건)"
ck "⑦ 요약은 한 줄뿐" "$(count_of "$ERR" 'blocked-summary:')" "1"
ck "⑤ 블로커 조회는 후보당 한 번(10건)" "$(count_of "$LOG" 'blocker ')" "10"

# ── ⑤ 본문 ∪ 라벨 dedupe — 같은 번호는 한 번만 조회한다 ────────────────────
fx=$(mkfx c 34)
add_issue "$fx" 21 '["agent-ready","blocked-by:900"]' '본문·라벨 중복 블로커' \
  '배경 설명
Blocked by #900'
add_blocker "$fx" 900 OPEN '["needs-human","hold:ladder"]'
run_sut "$fx"
ck "⑤ exit 0" "$RC" "0"
ck "⑤ 같은 블로커는 한 번만 조회" "$(count_of "$LOG" 'blocker 900')" "1"
ck "⑤ blocked 줄도 한 줄" "$(count_of "$ERR" 'blocked: ')" "1"
has_line "⑤ blocked 줄" "$ERR" "blocked: owner/repo#21 ← #900(사람대기)"
ck "⑤ stdout 은 빈 배열" "$(cat "$OUT")" "[]"
has_line "⑦ 요약 — 막힘 1건 · 사람대기 1건" "$ERR" "blocked-summary: 막힘 1건 (사람대기 블로커 1건)"

# ── ⑤ 첫 OPEN 블로커에서 멈춘다(break 유지 — 둘째는 조회하지 않는다) ───────
fx=$(mkfx d 34)
add_issue "$fx" 22 '["agent-ready"]' '블로커 둘' \
  'Blocked by #910
Blocked by #911'
add_blocker "$fx" 910 OPEN '["agent:claimed"]'
add_blocker "$fx" 911 OPEN '["needs-human"]'
run_sut "$fx"
ck "⑤ exit 0" "$RC" "0"
ck "⑤ 첫 블로커만 조회" "$(count_of "$LOG" 'blocker 910')" "1"
ck "⑤ 둘째 블로커는 조회 안 함" "$(count_of "$LOG" 'blocker 911')" "0"
has_line "⑤ 첫 블로커로 보고" "$ERR" "blocked: owner/repo#22 ← #910(구현중)"
has_line "⑦ 요약 — 사람대기 0건(첫 블로커가 구현중)" "$ERR" "blocked-summary: 막힘 1건 (사람대기 블로커 0건)"

# ── ⑥ 검색 창 경고 — 경계 그대로 ───────────────────────────────────────────
TRUNC_55='warn: 검색 창 절단 — agent-ready 후보 55건 > 창 50, 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)'
TRUNC_51='warn: 검색 창 절단 — agent-ready 후보 51건 > 창 50, 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)'
fx=$(mkfx w55 55); run_sut "$fx"
has_line "⑥ 55 → 절단 warn" "$ERR" "$TRUNC_55"
ck "⑥ 55 에서도 stdout 은 후보 JSON 뿐" "$(cat "$OUT")" "[]"
fx=$(mkfx w51 51); run_sut "$fx"
has_line "⑥ 51 → 절단 warn(경계 바로 위)" "$ERR" "$TRUNC_51"
fx=$(mkfx w50 50); run_sut "$fx"
has_line "⑥ 50 → 임박 warn(창과 같음)" "$ERR" "warn: 검색 창 임박 50/50"
no_line "⑥ 50 은 절단이 아니다" "$ERR" "검색 창 절단"
fx=$(mkfx w45 45); run_sut "$fx"
has_line "⑥ 45 → 임박 warn" "$ERR" "warn: 검색 창 임박 45/50"
fx=$(mkfx w41 41); run_sut "$fx"
has_line "⑥ 41 → 임박 warn(soft 바로 위)" "$ERR" "warn: 검색 창 임박 41/50"
fx=$(mkfx w40 40); run_sut "$fx"
no_line "⑥ 40 → 침묵(soft 와 같음)" "$ERR" "warn: 검색 창"
fx=$(mkfx w34 34); run_sut "$fx"
no_line "⑥ 34 → 침묵" "$ERR" "warn: 검색 창"
# 창 크기를 **못 읽은** 경우는 침묵이 아니다 — 침묵은 "창에 여유가 있다"는 주장이고,
# 모르는 것을 안다고 말하면 큐가 죽는 신호가 그대로 사라진다(PR#139 의 빈 결과≠실패).
fx=$(mkfx wnull null); run_sut "$fx"
ck "⑥ 미상이어도 exit 0" "$RC" "0"
has_line "⑥ total_count 미상 → 침묵이 아니라 warn" "$ERR" \
  "warn: 검색 창 크기 미상 — total_count 를 못 읽었다(창 절단 여부 판정 불가): [null]"
ck "⑥ 미상이어도 stdout 은 후보 JSON 뿐" "$(cat "$OUT")" "[]"

# ══ 에픽 finish-first 정렬 (#257) ═════════════════════════════════════════
# 기대 순서는 **손으로** 적는다 — SUT 의 sort_by 를 베끼면 공허하게 통과한다.

# ── Ⓔ① `Epic #N` 이 하나도 없으면 순서가 종전과 같다(회귀 0) ──────────────
# 종전 규칙만으로 손계산: P1(#41) → P2 는 오래된 순(#42 01-02, #40 01-03).
fx=$(mkfx e1 34)
add_issue "$fx" 40 '["agent-ready","P2"]' '에픽 없음 A' '본문만 있다' '2026-01-03T00:00:00Z'
add_issue "$fx" 41 '["agent-ready","P1"]' '에픽 없음 B' '본문만 있다' '2026-01-05T00:00:00Z'
add_issue "$fx" 42 '["agent-ready","P2"]' '에픽 없음 C' '본문만 있다' '2026-01-02T00:00:00Z'
run_sut "$fx"
ck "Ⓔ① exit 0" "$RC" "0"
ck "Ⓔ① 순서는 종전과 동일(P → 오래된 순)" "$(jq -c '[.[].number]' "$OUT")" '[41,42,40]'
ck "Ⓔ① 새 필드는 맨 뒤에 붙고 기존 필드는 이름·순서 불변" \
  "$(jq -c '.[0] | keys_unsorted' "$OUT")" \
  '["repo","number","title","priority","createdAt","epic","epic_started"]'
ck "Ⓔ① epic 은 null" "$(jq -c '[.[].epic]' "$OUT")" '[null,null,null]'
ck "Ⓔ① epic_started 는 false" "$(jq -c '[.[].epic_started]' "$OUT")" '[false,false,false]'
ck "Ⓔ① 닫힌 leaf 검색 1회(추가 gh 호출은 이것뿐)" "$(count_of "$LOG" 'closed-scan')" "1"
ck "Ⓔ① 후보 검색은 여전히 1회" "$(count_of "$LOG" 'search')" "1"
no_line "Ⓔ① 조회 성공이면 warn 없음" "$ERR" "warn: 에픽 시작 집합 조회 실패"

# ── Ⓔ② 같은 P 안에서 시작한 에픽의 leaf 가 앞 ────────────────────────────
# #51 은 #50 보다 8일 늦게 만들어졌지만 에픽 #700 이 이미 시작됐다(닫힌 leaf).
fx=$(mkfx e2 34)
add_issue "$fx" 50 '["agent-ready","P2"]' '에픽 없는 P2' '본문만 있다' '2026-01-01T00:00:00Z'
add_issue "$fx" 51 '["agent-ready","P2"]' '시작한 에픽의 P2 leaf' \
  'Epic #700

배경 설명' '2026-01-09T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700
닫힌 leaf'
run_sut "$fx"
ck "Ⓔ② exit 0" "$RC" "0"
ck "Ⓔ② 시작한 에픽의 leaf 가 앞" "$(jq -c '[.[].number]' "$OUT")" '[51,50]'
ck "Ⓔ② epic 번호를 싣는다" "$(jq -c '[.[] | {n:.number, e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"n":51,"e":700,"s":true},{"n":50,"e":null,"s":false}]'

# ── Ⓔ③ 에픽 축은 P 경계를 넘지 않는다 ────────────────────────────────────
fx=$(mkfx e3 34)
add_issue "$fx" 60 '["agent-ready","P1"]' 'P1 단발(에픽 없음)' '본문만 있다' '2026-01-09T00:00:00Z'
add_issue "$fx" 61 '["agent-ready","P2"]' 'P2 시작-에픽 leaf' 'Epic #700' '2026-01-01T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
run_sut "$fx"
ck "Ⓔ③ exit 0" "$RC" "0"
ck "Ⓔ③ P 가 먼저다 — P1 단발이 P2 에픽 leaf 보다 앞" "$(jq -c '[.[].number]' "$OUT")" '[60,61]'
ck "Ⓔ③ P2 leaf 는 시작 판정을 받았다(순서만 P 에 졌다)" \
  "$(jq -c '[.[] | select(.number == 61) | .epic_started]' "$OUT")" '[true]'

# ── Ⓔ④ 출처 (a) 만으로 — 진행 라벨 row 의 검색 item body ─────────────────
# 진행 라벨 네 가지가 모두 시작 판정을 낸다. 그 row 들엔 `gh issue view --json body` 를
# 부르지 않는다(추가 호출 0 — 그게 이 출처를 고른 이유다).
fx=$(mkfx e4 34)
add_issue "$fx" 30 '["agent-ready","agent:claimed"]' '구현중 leaf' 'Epic #700'
add_issue "$fx" 31 '["agent-ready","flow:verify"]'   '검증중 leaf' 'Epic #701'
add_issue "$fx" 32 '["agent-ready","flow:ready"]'    '마감대기 leaf' 'Epic #702'
add_issue "$fx" 33 '["agent-ready","harvesting"]'    '마감중 leaf' 'Epic #703'
add_issue "$fx" 34 '["agent-ready","P2"]' '에픽 없음' '본문만 있다'      '2026-01-01T00:00:00Z'
add_issue "$fx" 35 '["agent-ready","P2"]' 'claimed 에픽 leaf' 'Epic #700' '2026-01-05T00:00:00Z'
add_issue "$fx" 36 '["agent-ready","P2"]' 'verify 에픽 leaf'  'Epic #701' '2026-01-06T00:00:00Z'
add_issue "$fx" 37 '["agent-ready","P2"]' 'ready 에픽 leaf'   'Epic #702' '2026-01-07T00:00:00Z'
add_issue "$fx" 38 '["agent-ready","P2"]' 'harvest 에픽 leaf' 'Epic #703' '2026-01-08T00:00:00Z'
run_sut "$fx"
ck "Ⓔ④ exit 0" "$RC" "0"
ck "Ⓔ④ 진행 라벨 네 가지가 모두 시작 판정을 낸다" "$(jq -c '[.[].number]' "$OUT")" '[35,36,37,38,34]'
ck "Ⓔ④ agent:claimed row 본문 조회 0회" "$(count_of "$LOG" 'body 30')" "0"
ck "Ⓔ④ flow:verify row 본문 조회 0회"   "$(count_of "$LOG" 'body 31')" "0"
ck "Ⓔ④ flow:ready row 본문 조회 0회"    "$(count_of "$LOG" 'body 32')" "0"
ck "Ⓔ④ harvesting row 본문 조회 0회"    "$(count_of "$LOG" 'body 33')" "0"
ck "Ⓔ④ 닫힌 leaf 검색은 (a) 와 무관하게 1회" "$(count_of "$LOG" 'closed-scan')" "1"

# ── Ⓔ⑤ 출처 (b) 만으로 · 키는 same-repo ──────────────────────────────────
# 닫힌 leaf 는 owner/repo 의 #800 과 other/repo 의 #801 둘. #801 은 **다른 레포**라
# owner/repo#72 를 시작시키지 않는다(같은 번호를 가진 남의 에픽에 묻어가지 않는다).
fx=$(mkfx e5 34)
add_issue "$fx" 70 '["agent-ready","P2"]' '같은 레포 에픽 leaf' 'Epic #800' '2026-01-09T00:00:00Z'
add_issue "$fx" 71 '["agent-ready","P2"]' '에픽 없음'           '본문만 있다' '2026-01-01T00:00:00Z'
add_issue "$fx" 72 '["agent-ready","P2"]' '다른 레포 에픽 번호' 'Epic #801' '2026-01-08T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #800'
add_closed_leaf "$fx" other/repo 'Epic #801'
run_sut "$fx"
ck "Ⓔ⑤ exit 0" "$RC" "0"
ck "Ⓔ⑤ 같은 레포 에픽만 시작 — #72 는 종전 자리" "$(jq -c '[.[].number]' "$OUT")" '[70,71,72]'
ck "Ⓔ⑤ 다른 레포 닫힌 leaf 는 시작 판정을 못 준다" \
  "$(jq -c '[.[] | select(.number == 72) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":801,"s":false}]'

# ── Ⓔ⑥ 산문 속 `epic #N` 은 안 잡히고, 앞 공백 줄 시작은 잡힌다 ──────────
fx=$(mkfx e6 34)
add_issue "$fx" 80 '["agent-ready","P2"]' '산문 언급' \
  '이 건은 epic #700 의 꼬리다 — 줄 시작이 아니다.' '2026-01-09T00:00:00Z'
add_issue "$fx" 81 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
add_issue "$fx" 82 '["agent-ready","P2"]' '앞 공백 줄 시작' \
  '   epic #700' '2026-01-10T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
run_sut "$fx"
ck "Ⓔ⑥ exit 0" "$RC" "0"
ck "Ⓔ⑥ 산문은 안 잡히고 앞 공백 줄 시작만 앞으로" "$(jq -c '[.[].number]' "$OUT")" '[82,81,80]'
ck "Ⓔ⑥ 산문 언급 이슈의 epic 은 null" \
  "$(jq -c '[.[] | select(.number == 80) | .epic]' "$OUT")" '[null]'
ck "Ⓔ⑥ 앞 공백·소문자도 같은 에픽으로 읽는다" \
  "$(jq -c '[.[] | select(.number == 82) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":700,"s":true}]'

# ── Ⓔ⑦ (b) 조회 실패 → warn + 정렬은 종전 ────────────────────────────────
# (a) 에 기여자(#90, agent:claimed · Epic #700)가 있어도 시작 집합을 **통째로** 비운다 —
# 절반만 되비친 순서는 아무도 재현할 수 없다. 조용한 성공으로 위장하지 않는다.
fx=$(mkfx e7 34)
add_issue "$fx" 90 '["agent-ready","agent:claimed"]' '구현중 leaf' 'Epic #700'
add_issue "$fx" 91 '["agent-ready","P2"]' '에픽 leaf' 'Epic #700' '2026-01-09T00:00:00Z'
add_issue "$fx" 92 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
set_closed_fail "$fx" 'gh: HTTP 503 Service Unavailable'
run_sut "$fx"
ck "Ⓔ⑦ 실패해도 exit 0(계속 진행)" "$RC" "0"
has_line "Ⓔ⑦ 침묵하지 않는다 — warn 한 줄" "$ERR" \
  "warn: 에픽 시작 집합 조회 실패 — finish-first 없이 정렬"
ck "Ⓔ⑦ 정렬은 종전(오래된 순)" "$(jq -c '[.[].number]' "$OUT")" '[92,91]'
ck "Ⓔ⑦ epic 파싱 자체는 살아 있다(시작 판정만 꺼진다)" \
  "$(jq -c '[.[] | select(.number == 91) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":700,"s":false}]'
no_line "Ⓔ⑦ 빈 큐로 위장하지 않는다" "$OUT" "[]"

# ── Ⓔ⑧ 두 번째 계산기 금지 — `loop-status.sh` 의 `epic_of` 와 **같은 판정** ────────
# 이 레포는 같은 규칙이 두 파일에 갈라져 사람 눈에 안 보이는 두 번째 계산기가 생기는
# 형상을 이미 겪었다(#197). 두 정규식을 원문에서 뽑아 **이름 붙은 그룹 표기만 벗기고**
# 문자 그대로 맞댄다 — 한쪽의 앵커·문자 클래스·대소문자 무시가 바뀌면 여기서 빨개진다.
# (끝 앵커 `$` 채택 여부는 #259 범위다 — 여기서는 "둘이 같다"만 잰다.)
ei_rx=$(grep -oE "\^\[\[:space:\]\]\*epic\[\[:space:\]\]\+#\[0-9\]\+" "$DIR/eligible-issues.sh" | head -n 1)
ls_rx=$(grep -oE "\^\[\[:space:\]\]\*epic\[\[:space:\]\]\+#\(\?<n>\[0-9\]\+\)" "$DIR/loop-status.sh" | head -n 1)
# jq 쪽의 `(?<n>…)` 는 **캡처 이름**일 뿐 판정에 관여하지 않는다 — 표기만 벗긴다.
ls_norm=$(printf '%s' "$ls_rx" | sed 's/(?<n>//; s/)$//')
ck "Ⓔ⑧ eligible 쪽 정규식을 실제로 찾았다" "$ei_rx" '^[[:space:]]*epic[[:space:]]+#[0-9]+'
ck "Ⓔ⑧ loop-status 쪽 정규식을 실제로 찾았다" "$ls_rx" '^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)'
ck "Ⓔ⑧ 두 파일의 에픽 판정이 갈리지 않는다" "$ei_rx" "$ls_norm"
# 대소문자 무시도 양쪽 다여야 한다(한쪽만 `-i`/`"i"` 가 빠지면 `Epic`/`epic` 이 갈린다).
ck "Ⓔ⑧ eligible 은 grep -oiE(대소문자 무시)" \
  "$(grep -c -- "grep -oiE '\^\[\[:space:\]\]\*epic" "$DIR/eligible-issues.sh")" "1"
ck "Ⓔ⑧ loop-status 는 capture(...; \"i\")" \
  "$(grep -c -- 'capture("\^\[\[:space:\]\]\*epic\[\[:space:\]\]+#(?<n>\[0-9\]+)"; "i")' "$DIR/loop-status.sh")" "1"

echo "eligible-issues.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
