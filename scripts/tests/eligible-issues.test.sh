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
  printf '%s' "$fx"
}
add_issue() {  # add_issue <fx> <num> <라벨 JSON 배열(문자열)> <제목> <본문> [생성시각]
  local fx="$1" num="$2" labels="$3" title="$4" body="$5" created="${6:-2026-01-01T00:00:00Z}"
  jq --argjson n "$num" --argjson l "$labels" --arg t "$title" --arg c "$created" \
    '.items += [{repository_url: "https://api.github.com/repos/owner/repo",
                 number: $n, title: $t,
                 labels: [$l[] | {name: .}],
                 created_at: $c}]' "$fx/search.json" > "$fx/s.tmp"
  mv "$fx/s.tmp" "$fx/search.json"
  jq -n --arg b "$body" '{body: $b}' > "$fx/body.$num.json"
}
add_blocker() {  # add_blocker <fx> <num> <state> <라벨 JSON 배열(문자열)>
  jq -n --arg s "$3" --argjson l "$4" '{state: $s, labels: [$l[] | {name: .}]}' > "$1/blocker.$2.json"
}
add_blocker_fail() {  # add_blocker_fail <fx> <num> <에러문>
  printf '%s\n' "$3" > "$1/blocker.$2.fail"
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
    "createdAt": "2026-01-01T00:00:00Z"
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

echo "eligible-issues.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
