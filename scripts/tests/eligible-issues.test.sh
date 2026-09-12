#!/usr/bin/env bash
# eligible-issues.test.sh 픽스처 테스트 (#247) — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# 가드하는 것:
#   ① 블로커 없는 후보는 stdout 에 남는다 — 그리고 **stdout 바이트가 그대로다**
#      (디스패처 파이프라인의 SSOT. 진단이 한 글자라도 새면 여기서 빨개진다).
#   ② OPEN 블로커로 탈락한 이슈마다 stderr `blocked: <repo>#<num> ← #<b>(<상태>)`.
#      `<상태>` 는 블로커의 라벨로 정한다(needs-human→사람대기 · hold:conflict→사람대기
#      (#244 — `loop-status.sh` 의 사람대기 버킷 정의와 같은 집합) · 그 밖 hold:*→보류(#244) ·
#      agent:claimed→구현중 ·
#      flow:verify→검증대기 · verifying→검증중(#275) · flow:ready→마감대기 · harvesting→마감중 ·
#      그 밖→대기).
#   ③ 블로커가 CLOSED·MERGED(PR)·미존재면 통과하고 `blocked:` 줄이 없다.
#   ④ 블로커 조회 일시 오류는 `(조회오류)` — 빈 결과와 실패를 구분한다(PR#139).
#   ⑤ 본문 `Blocked by #N` 과 라벨 `blocked-by:N` 이 같은 번호를 가리키면 **한 번만** 조회한다
#      (dedupe). 한 이슈에 OPEN 블로커가 둘이면 첫 번째에서 멈춘다(break 유지 = 호출 수 증가 0).
#   ⑥ 검색 창 경고 (#277 이후) — 창은 한 페이지가 아니라 **실질 상한**
#      `SEARCH_WINDOW × SEARCH_MAX_PAGES`(기본 50×5=250) 이다. `total > 250` 절단 ·
#      `200 < total ≤ 250` 임박 · 그 아래 침묵 · `total_count` 미상은 침묵이 아니라 warn.
#   ⑨ 페이지네이션 (#277) — 후보가 한 페이지를 넘으면 `page=2,3,…` 을 이어 받아 합친다.
#      실측 형상(후보 53 > 창 50)에서 **가장 새 3건**이 stdout 에 남고, `blocked-summary:` 도
#      합친 전체 후보를 센다. 창 안(34)이면 호출은 **1회 그대로**다(비용 회귀).
#      상한 소진·임박 경계·빈 페이지 정지·페이지 조회 실패는 상수를 env 로 줄여(창 5×3=15) 문다.
#   ⑦ 스캔 끝 요약 `blocked-summary: 막힘 N건 (사람대기 블로커 M건)` 의 N·M 이 정확하다.
#   ⑩ 본문 조회 실패 (#330) — 한 건이 죽어도 **그 후보만** 빠지고 나머지 판정·stdout 은
#      살아남는다(수정 전: `set -e` 로 스크립트가 비0 종료해 목록이 통째로 증발).
#   ⑪ page=1 조회 실패 (#330) — `rc≠0` 이고 stdout 이 **비어 있다**. 빈 목록 + rc=0 으로
#      둔갑하면 디스패처가 "신규 0" 으로 읽어 빈 큐와 구분 없이 지나간다(레이트리밋 사고).
#   ⑫ 창 상수 env 방어 (#330) — 비숫자·선행 0·하한·per_page 클램프·임박선 바닥이
#      **요청(per_page)과 상한 산술에 실제로 반영**된다.
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
#   Ⓔ⑧ `loop-status.sh`(#260)·`epic-sweep.sh`(#313) 와 정규식이 갈리지 않는다 — 계산기는 셋이고
#       인벤토리(`scripts/*.sh` 전수)까지 센다(넷째가 생기면 여기서 먼저 말한다).
#   Ⓔ⑨ 여러 줄 본문 — `Epic #N` 이 둘째 줄 이후여도 잡히고, 줄이 둘이면 **첫 매치 하나만**,
#       선행 0(`Epic #0700`)은 벗겨 `loop-status.sh` 의 `tonumber` 와 같은 값이 된다.
#   Ⓔ⑩ 진행 라벨 목록이 이 파일 안 **두 자리**(시작 판정 · 후보 제외)에서 갈리지 않는다.
#   Ⓔ⑪ (b) 창(100) 절단·창 크기 미상도 말한다 — 부분 힌트를 침묵으로 두지 않는다.
#   Ⓔ⑫ **두 축의 교차** — 페이지(#277·#315)를 전부 모은 뒤 **한 번** 정렬한다. 2페이지에만 있는
#       시작-에픽 leaf 가 1페이지 후보보다 앞이고, 2페이지의 진행 라벨 row 가 (a) 출처가 된다.
#   Ⓔ⑬ 정렬 키 경계값 — 빈 본문 · `Epic` 줄 없음 · P 라벨 없음이 겹쳐도 안 죽고 종전 자리를 지킨다.
#   Ⓔ⑭ 큰 본문 × 페이지 병합 — 합치는 경로가 **argv 를 안 탄다**(ARG_MAX). `body` 를 실은 뒤
#       페이로드가 21배가 됐다 — `--argjson` 이면 기본 상수 구간에서 틱이 통째로 죽는다.
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
    # #277: SUT 는 페이지를 이어 받는다 — `-f page=N` 을 읽어 페이지별 픽스처를 낸다.
    # per_page 도 남긴다 — env 방어(비숫자 정규화 · 하한 · per_page≤100 클램프)가
    # **실제로 요청에 반영됐는지**는 warn 문구만으로는 안 보인다(⑫).
    page=1
    pp=""
    pprev=""
    for a in "$@"; do
      case "$pprev" in
        -f|--field|-F|--raw-field)
          case "$a" in
            page=*) page="${a#page=}" ;;
            per_page=*) pp="${a#per_page=}" ;;
          esac ;;
      esac
      pprev="$a"
    done
    printf 'search page=%s per_page=%s\n' "$page" "$pp" >> "$STUB_CALL_LOG"
    if [ -f "$STUB_DIR/search.p$page.fail" ]; then
      cat "$STUB_DIR/search.p$page.fail" >&2
      exit 1
    fi
    sfx="$STUB_DIR/search.p$page.json"
    if [ ! -f "$sfx" ]; then
      # 1페이지는 예전 이름(search.json)을 그대로 받는다. 2페이지 이상인데 픽스처가
      # 없으면 **예기치 않은 호출**이다 — 조용한 빈 JSON 대신 드러낸다.
      if [ "$page" = 1 ]; then sfx="$STUB_DIR/search.json"
      else echo "gh stub: 검색 페이지 픽스처 없음(예기치 않은 page=$page): $args" >&2; exit 1; fi
    fi
    [ -n "$jqf" ] || { echo "gh stub: search 는 -q 로 불러야 한다: $args" >&2; exit 1; }
    jq -r "$jqf" "$sfx" || exit 1
    exit 0 ;;
esac

if [ "${1:-} ${2:-}" = "issue view" ]; then
  num="${3:-}"
  case "$args" in
    *"--json body"*)
      printf 'body %s\n' "$num" >> "$STUB_CALL_LOG"
      [ -n "$jqf" ] || { echo "gh stub: 본문 조회는 -q 로 불러야 한다: $args" >&2; exit 1; }
      # 블로커 조회와 같은 이음매 — `body.<num>.fail` 이 있으면 그 내용을 stderr 로 내고 실패한다.
      if [ -f "$STUB_DIR/body.$num.fail" ]; then
        cat "$STUB_DIR/body.$num.fail" >&2
        exit 1
      fi
      # `body.<num>.warn` 은 **성공하면서** stderr 로도 쓰는 갈래다(gh 의 업데이트 알림 등).
      [ -f "$STUB_DIR/body.$num.warn" ] && cat "$STUB_DIR/body.$num.warn" >&2
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
  printf '{"total_count":0,"items":[]}\n' > "$fx/closed.json"
  printf '%s' "$fx"
}
add_issue_to() {  # add_issue_to <fx> <검색파일> <num> <라벨 JSON 배열(문자열)> <제목> <본문> [생성시각]
  local fx="$1" file="$2" num="$3" labels="$4" title="$5" body="$6" created="${7:-2026-01-01T00:00:00Z}"
  # 실제 REST `search/issues` 의 item 은 `body` 를 포함한다(#257 실측) — 진행 라벨 row 의
  # 에픽 판정이 그 필드를 쓰므로 스텁도 같은 형상이어야 한다. 페이지를 이어 받아도(#277)
  # 같다: 2페이지 이후 item 에도 본문이 실려야 (a) 가 그 장의 leaf 를 본다.
  jq --argjson n "$num" --argjson l "$labels" --arg t "$title" --arg c "$created" --arg b "$body" \
    '.items += [{repository_url: "https://api.github.com/repos/owner/repo",
                 number: $n, title: $t,
                 labels: [$l[] | {name: .}],
                 created_at: $c, body: $b}]' "$fx/$file" > "$fx/s.tmp"
  mv "$fx/s.tmp" "$fx/$file"
  jq -n --arg b "$body" '{body: $b}' > "$fx/body.$num.json"
}
add_issue() {  # add_issue <fx> <num> <라벨 JSON 배열(문자열)> <제목> <본문> [생성시각]
  add_issue_to "$1" search.json "${@:2}"
}
mkpage() {  # mkpage <fx> <page> <total_count> — 그 페이지의 빈 픽스처를 만든다
  printf '{"total_count":%s,"items":[]}\n' "$3" > "$1/search.p$2.json"
}
bulk_issues() {  # bulk_issues <fx> <검색파일> <시작번호> <개수> — 블로커 없는 후보를 한 번에
  # 한 건씩 add_issue 로 쌓으면 53건 픽스처에 jq 를 100번 넘게 띄운다 — items 는 jq 한 번,
  # 본문 픽스처는 printf 로 만든다(본문이 비면 블로커 없음 = 전부 통과).
  local fx="$1" file="$2" from="$3" n="$4" i end
  jq --argjson f "$from" --argjson n "$n" \
    '.items += [range($f; $f + $n) | {
        repository_url: "https://api.github.com/repos/owner/repo",
        number: ., title: "bulk \(.)",
        labels: [{name: "agent-ready"}],
        created_at: "2026-03-01T00:00:00Z"}]' "$fx/$file" > "$fx/b.tmp"
  mv "$fx/b.tmp" "$fx/$file"
  i="$from"; end=$((from + n))
  while [ "$i" -lt "$end" ]; do printf '{"body":""}\n' > "$fx/body.$i.json"; i=$((i + 1)); done
}
bulk_big_issues() {  # bulk_big_issues <fx> <검색파일> <시작번호> <개수> <본문바이트>
  # 본문이 큰 후보를 한 번에. ARG_MAX 격자(Ⓔ⑭) 전용 — 페이지 병합 페이로드를 키운다.
  local fx="$1" file="$2" from="$3" n="$4" sz="$5" i end
  jq --argjson f "$from" --argjson n "$n" --argjson sz "$sz" \
    '.items += [range($f; $f + $n) | {
        repository_url: "https://api.github.com/repos/owner/repo",
        number: ., title: "big \(.)",
        labels: [{name: "agent-ready"}],
        created_at: "2026-03-01T00:00:00Z",
        body: ("x" * $sz)}]' "$fx/$file" > "$fx/b.tmp"
  mv "$fx/b.tmp" "$fx/$file"
  i="$from"; end=$((from + n))
  while [ "$i" -lt "$end" ]; do printf '{"body":""}\n' > "$fx/body.$i.json"; i=$((i + 1)); done
}
add_blocker() {  # add_blocker <fx> <num> <state> <라벨 JSON 배열(문자열)>
  jq -n --arg s "$3" --argjson l "$4" '{state: $s, labels: [$l[] | {name: .}]}' > "$1/blocker.$2.json"
}
add_blocker_fail() {  # add_blocker_fail <fx> <num> <에러문>
  printf '%s\n' "$3" > "$1/blocker.$2.fail"
}
add_closed_leaf() {  # add_closed_leaf <fx> <owner/repo> <본문>
  # total_count 는 실응답처럼 items 수를 따라간다(창 절단 픽스처는 set_closed_total 로 따로 세운다).
  jq --arg r "https://api.github.com/repos/$2" --arg b "$3" \
    '.items += [{repository_url: $r, body: $b}] | .total_count = (.items | length)' \
    "$1/closed.json" > "$1/c.tmp"
  mv "$1/c.tmp" "$1/closed.json"
}
set_closed_total() {  # set_closed_total <fx> <total_count(JSON — 숫자 또는 null)>
  jq --argjson t "$2" '.total_count = $t' "$1/closed.json" > "$1/c.tmp"
  mv "$1/c.tmp" "$1/closed.json"
}
set_closed_fail() {  # set_closed_fail <fx> <에러문>
  printf '%s\n' "$2" > "$1/closed.fail"
}
add_body_fail() {  # add_body_fail <fx> <num> <에러문(여러 줄 가능)>
  printf '%s\n' "$3" > "$1/body.$2.fail"
}
add_body_stderr() {  # add_body_stderr <fx> <num> <성공하면서 stderr 로 쓰는 문구>
  printf '%s\n' "$3" > "$1/body.$2.warn"
}

OUT=""; ERR=""; LOG=""; RC=0
run_sut() {  # run_sut <fx> [env 대입…] — 기본 상수(창 50 × 5페이지 = 250)
  local fx="$1"
  shift
  OUT="$fx/stdout"; ERR="$fx/stderr"; LOG="$fx/calls.log"
  : > "$LOG"
  RC=0
  ( cd "$cwd" && PATH="$tmp/bin:$PATH" STUB_DIR="$fx" STUB_CALL_LOG="$LOG" \
      env "$@" bash "$SUT" ) > "$OUT" 2> "$ERR" || RC=$?
}
# 상한·경계 격자용 — 상수를 창 5 × 3페이지(실질 상한 15, 임박선 12)로 줄여 부른다.
# 250건 픽스처를 만들지 않고도 같은 산술을 문다(운영 기본값은 SUT 안에 그대로 있다).
run_sut_small() {  # run_sut_small <fx>
  run_sut "$1" ELIGIBLE_SEARCH_WINDOW=5 ELIGIBLE_SEARCH_MAX_PAGES=3
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
ck "① 검색 1회" "$(count_of "$LOG" 'search page=')" "1"
# 창 안(34 ≤ 50)이면 2페이지를 부르지 않는다 — 페이지네이션이 **틱 비용을 늘리지 않는다**는 회귀.
ck "① page=1 한 번" "$(count_of "$LOG" 'search page=1')" "1"
ck "① page=2 는 안 부른다(창 안 = 호출 1회 그대로)" "$(count_of "$LOG" 'search page=2')" "0"
no_line "① 창 경고 침묵(34 ≤ 실질 상한 250)" "$ERR" "warn: 검색 창"
no_line "① 조회 실패 0건이면 집계 warn 도 침묵" "$ERR" "warn: 본문 조회 실패"

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
add_issue "$fx" 23 '["agent-ready"]' '검증중 블로커' 'Blocked by #913'
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
# verify-runner 가 집은 순간의 점유 라벨(#275) — `대기`(= 곧 집힐 것)로 읽히면 안 된다.
add_blocker "$fx" 913 OPEN   '["agent-ready","verifying"]'
run_sut "$fx"
ck "② exit 0" "$RC" "0"
has_line "② 사람대기"   "$ERR" "blocked: owner/repo#11 ← #900(사람대기)"
has_line "② 구현중"     "$ERR" "blocked: owner/repo#12 ← #901(구현중)"
has_line "② 검증대기"   "$ERR" "blocked: owner/repo#13 ← #902(검증대기)"
has_line "② 마감대기"   "$ERR" "blocked: owner/repo#14 ← #903(마감대기)"
has_line "② 마감중"     "$ERR" "blocked: owner/repo#15 ← #904(마감중)"
has_line "② 검증중(verifying, #275)" "$ERR" "blocked: owner/repo#23 ← #913(검증중)"
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
has_line "⑦ 요약 — 막힘 8건 · 사람대기 1건" "$ERR" "blocked-summary: 막힘 8건 (사람대기 블로커 1건)"
ck "⑦ 요약은 한 줄뿐" "$(count_of "$ERR" 'blocked-summary:')" "1"
ck "⑤ 블로커 조회는 후보당 한 번(11건)" "$(count_of "$LOG" 'blocker ')" "11"

# ── ②-b (#244) 기계 정지(hold:*)인 블로커는 `대기` 가 아니라 `보류` ────────────
# 기계 정지가 `needs-human` 을 떼고 사유 라벨만 남기게 된 뒤, 이 줄이 없으면 홀드된
# 블로커가 `대기`(= 곧 집힐 것)로 읽혀 하위가 왜 안 풀리는지 사람 눈에 안 보인다.
# `사람대기` 카운트에는 들어가지 않는다 — 보류는 루프가 푸는 게이트지 사람 몫이 아니다.
fx=$(mkfx bh 34)
add_issue "$fx" 31 '["agent-ready"]' 'hold:ladder 블로커' 'Blocked by #910'
add_issue "$fx" 32 '["agent-ready"]' 'hold:policy 블로커' 'Blocked by #911'
add_issue "$fx" 33 '["agent-ready"]' 'needs-human+hold 블로커' 'Blocked by #912'
add_blocker "$fx" 910 OPEN '["agent-ready","hold:ladder"]'
add_blocker "$fx" 911 OPEN '["agent-ready","hold:policy","flow:verify"]'
add_blocker "$fx" 912 OPEN '["agent-ready","needs-human","hold:ladder"]'
run_sut "$fx"
ck "②-b exit 0" "$RC" "0"
has_line "②-b hold:ladder 단독 → 보류" "$ERR" "blocked: owner/repo#31 ← #910(보류)"
has_line "②-b hold:policy + 단계 라벨 → 보류(단계보다 앞)" "$ERR" "blocked: owner/repo#32 ← #911(보류)"
has_line "②-b needs-human 이 있으면 종전대로 사람대기" "$ERR" "blocked: owner/repo#33 ← #912(사람대기)"
has_line "②-b 요약 — 보류는 사람대기 카운트에 안 든다" "$ERR" \
  "blocked-summary: 막힘 3건 (사람대기 블로커 1건)"

# ── ②-c (#244 반송②) `hold:conflict` 는 `보류` 가 아니라 `사람대기` ───────────
# `loop-status.sh` 는 사람대기 버킷을 `needs-human` ∪ `hold:conflict` 로 정의한다
# (:592). 충돌은 루프가 재시도로 못 푸는 사람 몫이라 그렇다. 여기서만 일반 `hold:*`
# 갈래로 보내면 같은 라벨을 두 스크립트가 다르게 읽고, 막힌 하위 이슈가 `사람대기
# 블로커` 카운트에서 빠져 경보에 안 잡힌다. 갈래 **순서**가 판정의 전부다 —
# `*",hold:conflict,"*` 가 일반 `*",hold:"*` 뒤로 가면 이 칸이 다시 빨개진다.
fx=$(mkfx bc 34)
add_issue "$fx" 41 '["agent-ready"]' 'hold:conflict 블로커' 'Blocked by #920'
add_issue "$fx" 42 '["agent-ready"]' 'hold:ladder 블로커' 'Blocked by #921'
add_blocker "$fx" 920 OPEN '["agent-ready","hold:conflict"]'
add_blocker "$fx" 921 OPEN '["agent-ready","hold:ladder"]'
run_sut "$fx"
ck "②-c exit 0" "$RC" "0"
has_line "②-c hold:conflict 단독 → 사람대기(loop-status 와 일치)" "$ERR" \
  "blocked: owner/repo#41 ← #920(사람대기)"
has_line "②-c hold:ladder 는 종전대로 보류" "$ERR" "blocked: owner/repo#42 ← #921(보류)"
has_line "②-c 요약 — conflict 는 사람대기 카운트에 든다" "$ERR" \
  "blocked-summary: 막힘 2건 (사람대기 블로커 1건)"

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

# ── ⑥ 검색 창 경고 (#277) — 기준은 한 페이지가 아니라 실질 상한 ─────────────
# 페이지네이션 이후 "창 50" 은 더 이상 손실선이 아니다 — 51~250 은 이어 받아 전부 본다.
# 그래서 55 는 절단도 임박도 아니고, 2페이지를 **실제로 부른다**.
fx=$(mkfx w55 55); mkpage "$fx" 2 55
bulk_issues "$fx" search.json    200 1
bulk_issues "$fx" search.p2.json 201 1
run_sut "$fx"
ck "⑥ 55 → exit 0" "$RC" "0"
ck "⑥ 55 → 2페이지를 부른다" "$(count_of "$LOG" 'search page=2')" "1"
no_line "⑥ 55 는 절단이 아니다(실질 상한 250)" "$ERR" "검색 창 절단"
no_line "⑥ 55 는 임박도 아니다(임박선 200)" "$ERR" "검색 창 임박"
no_line "⑥ 55 에서 창 경고는 한 줄도 없다" "$ERR" "warn: 검색"
ck "⑥ 55 → 두 페이지가 합쳐진다" "$(jq -c '[.[].number]' "$OUT")" '[200,201]'

# 창 크기를 **못 읽은** 경우는 침묵이 아니다 — 침묵은 "창에 여유가 있다"는 주장이고,
# 모르는 것을 안다고 말하면 큐가 죽는 신호가 그대로 사라진다(PR#139 의 빈 결과≠실패).
# total_count 를 못 읽으면 페이지를 이어 받을 근거도 없다 — 1페이지로 끝낸다.
fx=$(mkfx wnull null); run_sut "$fx"
ck "⑥ 미상이어도 exit 0" "$RC" "0"
has_line "⑥ total_count 미상 → 침묵이 아니라 warn" "$ERR" \
  "warn: 검색 창 크기 미상 — total_count 를 못 읽었다(창 절단 여부 판정 불가): [null]"
ck "⑥ 미상이어도 stdout 은 후보 JSON 뿐" "$(cat "$OUT")" "[]"
ck "⑥ 미상이면 2페이지를 안 부른다(근거 없는 추가 호출 금지)" "$(count_of "$LOG" 'search page=2')" "0"

# ── ⑨ 페이지네이션 (#277) — 실측 형상(53 > 창 50)을 기본 상수로 그대로 ────────
# 근거: PR #273 검증 틱 stderr `agent-ready 후보 53건 > 창 50` — 가장 새 3건이 조용히
# 사라졌다. 1페이지 50건(#10..#59) + 2페이지 3건(#60·#61·#62).
# #62 는 2페이지에만 있는 **막힌** 이슈다 — `blocked-summary:` 가 합친 전체 후보를 센다는
# 단언을 같은 픽스처에서 함께 문다(2페이지를 안 받으면 이 줄 자체가 안 나온다).
fx=$(mkfx p53 53)
mkpage "$fx" 2 53
bulk_issues "$fx" search.json 10 50
bulk_issues "$fx" search.p2.json 60 2
add_issue_to "$fx" search.p2.json 62 '["agent-ready"]' '2페이지의 막힌 이슈' 'Blocked by #900' \
  '2026-03-01T00:00:00Z'
add_blocker "$fx" 900 OPEN '["needs-human","hold:policy"]'
run_sut "$fx"
ck "⑨ exit 0" "$RC" "0"
ck "⑨ 검색 2회(창을 넘으면 이어 받는다)" "$(count_of "$LOG" 'search page=')" "2"
ck "⑨ page=2 를 실제로 불렀다" "$(count_of "$LOG" 'search page=2')" "1"
ck "⑨ page=3 은 안 부른다(2페이지로 total 을 덮었다)" "$(count_of "$LOG" 'search page=3')" "0"
no_line "⑨ 53건 전부 받았으니 절단 warn 없음" "$ERR" "검색 창 절단"
no_line "⑨ 53 은 임박도 아니다" "$ERR" "검색 창 임박"
ck "⑨ stdout 52건 (후보 53 − 막힘 1)" "$(jq 'length' "$OUT")" "52"
# ★이 칸이 이 이슈의 심장이다 — 페이지네이션을 되돌리면 60·61 이 사라져 `[]` 가 된다.
ck "⑨ 2페이지 후보가 stdout 에 있다(수정 전엔 증발)" \
  "$(jq -c '[.[].number] | map(select(. >= 60)) | sort' "$OUT")" '[60,61]'
has_line "⑨ 2페이지의 막힌 이슈도 blocked 줄로 말한다" "$ERR" "blocked: owner/repo#62 ← #900(사람대기)"
has_line "⑨ 요약은 합친 전체 후보 기준" "$ERR" "blocked-summary: 막힘 1건 (사람대기 블로커 1건)"

# ⑨-f 운영 **기본 상수**(창 50 × 5페이지 = 250)를 직접 문다 — 아래 경계 격자는 env 로 줄인
# 값에서만 돌기 때문에, 기본값이 조용히 바뀌면(예 5→2) 그 격자는 전부 초록인 채로 남는다.
# 페이지당 1건씩만 싣는다(관심사는 몇 장을 부르고 어떤 문구가 나오는가).
fx=$(mkfx cap251 251)
for pg in 2 3 4 5; do mkpage "$fx" "$pg" 251; done
bulk_issues "$fx" search.json     300 1
bulk_issues "$fx" search.p2.json  301 1
bulk_issues "$fx" search.p3.json  302 1
bulk_issues "$fx" search.p4.json  303 1
bulk_issues "$fx" search.p5.json  304 1
run_sut "$fx"
ck "⑨-f exit 0" "$RC" "0"
ck "⑨-f 기본 상한까지 5페이지를 부른다" "$(count_of "$LOG" 'search page=')" "5"
ck "⑨-f 기본 상한 너머(page=6)는 안 부른다" "$(count_of "$LOG" 'search page=6')" "0"
has_line "⑨-f 기본 실질 상한은 250(= 50 × 5)" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 251건 > 창 250(페이지 5 × 50), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"

# ── ⑨ 상한·경계 격자 — 상수를 창 5 × 3페이지(상한 15 · 임박선 12)로 줄여 문다 ──
# 페이지당 1건씩만 싣는다: 이 칸들의 관심사는 **몇 페이지를 부르고 무슨 warn 이 나는가**이고,
# 페이지 채움 여부는 SUT 의 루프 조건(page × 창 < total)과 무관하다.

# ⑨-a 상한 소진 → 절단 warn 은 **그대로 유지**된다(조용히 자르지 않는다).
fx=$(mkfx cap16 16)
mkpage "$fx" 2 16; mkpage "$fx" 3 16
bulk_issues "$fx" search.json     100 1
bulk_issues "$fx" search.p2.json  101 1
bulk_issues "$fx" search.p3.json  102 1
run_sut_small "$fx"
ck "⑨-a exit 0" "$RC" "0"
ck "⑨-a 상한까지 3페이지를 부른다" "$(count_of "$LOG" 'search page=')" "3"
ck "⑨-a 상한 너머(page=4)는 안 부른다" "$(count_of "$LOG" 'search page=4')" "0"
has_line "⑨-a 상한 소진 → 절단 warn 유지" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 16건 > 창 15(페이지 3 × 5), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"
ck "⑨-a 받은 만큼은 후보로 낸다" "$(jq -c '[.[].number]' "$OUT")" '[100,101,102]'

# ⑨-b 임박 — 상한 이하지만 80% 선(12)을 넘었다.
fx=$(mkfx soft13 13)
mkpage "$fx" 2 13; mkpage "$fx" 3 13
bulk_issues "$fx" search.json     110 1
bulk_issues "$fx" search.p2.json  111 1
bulk_issues "$fx" search.p3.json  112 1
run_sut_small "$fx"
has_line "⑨-b 13/15 → 임박 warn" "$ERR" "warn: 검색 창 임박 13/15"
no_line "⑨-b 13 은 절단이 아니다" "$ERR" "검색 창 절단"

# ⑨-c 임박선과 같으면(12) 침묵 — 경계는 `>` 다.
fx=$(mkfx soft12 12)
mkpage "$fx" 2 12; mkpage "$fx" 3 12
bulk_issues "$fx" search.json     120 1
bulk_issues "$fx" search.p2.json  121 1
bulk_issues "$fx" search.p3.json  122 1
run_sut_small "$fx"
no_line "⑨-c 12/15 → 침묵(임박선과 같음)" "$ERR" "warn: 검색 창"

# ⑨-d 빈 페이지가 오면 멈춘다 — total_count 와 실제 페이지가 어긋나도 무한 루프가 없다.
fx=$(mkfx empty2 13)
mkpage "$fx" 2 13; mkpage "$fx" 3 13
bulk_issues "$fx" search.json 130 1
run_sut_small "$fx"
ck "⑨-d exit 0" "$RC" "0"
ck "⑨-d 빈 2페이지에서 멈춘다(page=3 미호출)" "$(count_of "$LOG" 'search page=3')" "0"
ck "⑨-d 받은 만큼은 후보로 낸다" "$(jq -c '[.[].number]' "$OUT")" '[130]'
# 조용히 멈추면 total(13)이 상한(15) 이하라 절단 warn 도 안 나 **완전 침묵**이 된다 —
# 이 스크립트가 없애려던 조용한 드롭 그 자체다. 멈춘 사실을 반드시 말한다.
has_line "⑨-d 빈 페이지를 조용히 넘기지 않는다" "$ERR" \
  "warn: 검색 page=2 가 비었다 — total_count 13건 중 1건만 받았다(search 인덱스 지연 · 다음 틱 재시도)"

# ⑨-e 다음 페이지 조회 실패는 **부분 목록으로 둔갑시키지 않는다**(PR#139: 빈 결과 ≠ 실패).
# 조용히 1페이지만 들고 가면 이 이슈가 고치려던 드롭이 그대로 재현된다 — 이번 틱을 접는다.
fx=$(mkfx pfail 13)
mkpage "$fx" 2 13
printf 'gh: HTTP 502 Bad Gateway\n' > "$fx/search.p2.fail"
bulk_issues "$fx" search.json 140 1
run_sut_small "$fx"
ck "⑨-e 페이지 조회 실패 → exit 1" "$RC" "1"
ck "⑨-e 부분 후보 목록을 stdout 으로 내지 않는다" "$(cat "$OUT")" ""
has_line "⑨-e 실패를 말한다" "$ERR" \
  "eligible-issues: 검색 page=2 조회 실패 — 부분 후보 목록을 정상으로 쓰지 않는다(이번 틱 중단): gh: HTTP 502 Bad Gateway"

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
# 머지로 계산기가 **셋**이 됐다 (#313 이 `epic-sweep.sh` 를 더했다) — 인벤토리를 파일 목록으로
# 떠서 전수로 맞댄다. 새 파일이 같은 줄을 또 파싱하면 여기서 개수가 어긋나 빨개진다.
es_rx=$(grep -oE "\^\[\[:space:\]\]\*epic\[\[:space:\]\]\+#\(\?<n>\[0-9\]\+\)" "$DIR/epic-sweep.sh" | head -n 1)
es_norm=$(printf '%s' "$es_rx" | sed 's/(?<n>//; s/)$//')
ck "Ⓔ⑧ epic-sweep 쪽 정규식을 실제로 찾았다" "$es_rx" '^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)'
ck "Ⓔ⑧ 세 파일의 에픽 판정이 갈리지 않는다" "$es_norm" "$ei_rx"
ck "Ⓔ⑧ epic-sweep 도 capture(...; \"i\")" \
  "$(grep -c -- 'capture("\^\[\[:space:\]\]\*epic\[\[:space:\]\]+#(?<n>\[0-9\]+)"; "i")' "$DIR/epic-sweep.sh")" "1"
# 인벤토리 자체를 센다 — `Epic #N` 을 파싱하는 스크립트가 넷째로 늘면 이 줄이 먼저 말한다.
epic_parsers=$(grep -lE "\^\[\[:space:\]\]\*epic\[\[:space:\]\]\+#" "$DIR"/*.sh | sed "s|.*/||" | sort | tr '\n' ' ')
ck "Ⓔ⑧ 에픽 판정을 가진 스크립트는 이 셋뿐" "$epic_parsers" "eligible-issues.sh epic-sweep.sh loop-status.sh "

# ── Ⓔ⑨ 여러 줄 본문 · 첫 매치 하나만 · 선행 0 ────────────────────────────
# ⑴ `Epic #N` 이 본문 첫 줄이 아니어도 잡힌다(실제 이슈 본문의 정상형).
# ⑵ `Epic #` 줄이 둘이면 **첫 것만** — 둘째까지 집으면 `--argjson` 이 죽어 큐가 멈춘다.
# ⑶ `Epic #0700` 의 선행 0 은 벗긴다 — `loop-status.sh` 는 `tonumber` 라 이미 700 이고,
#    안 벗기면 `--argjson` 이 `0700` 을 못 읽어 스크립트가 그 자리에서 죽는다.
fx=$(mkfx e9 34)
add_issue "$fx" 100 '["agent-ready","P2"]' '둘째 줄의 에픽 · 줄 둘' \
  '배경 한 줄
Epic #700
Epic #701' '2026-01-09T00:00:00Z'
add_issue "$fx" 101 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
add_issue "$fx" 102 '["agent-ready","P2"]' '선행 0' 'Epic #0700' '2026-01-10T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
run_sut "$fx"
ck "Ⓔ⑨ exit 0(선행 0·복수 줄이 큐를 죽이지 않는다)" "$RC" "0"
ck "Ⓔ⑨ 둘째 줄의 에픽도 잡고, 첫 매치 하나만 쓴다" \
  "$(jq -c '[.[] | select(.number == 100) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":700,"s":true}]'
ck "Ⓔ⑨ 선행 0 은 벗긴다(loop-status 의 tonumber 와 같은 값)" \
  "$(jq -c '[.[] | select(.number == 102) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":700,"s":true}]'
ck "Ⓔ⑨ 시작한 둘이 앞, 그 안에서는 오래된 순" "$(jq -c '[.[].number]' "$OUT")" '[100,102,101]'

# ── Ⓔ⑩ 진행 라벨 목록이 이 파일 안 두 자리에서 갈리지 않는다 ──────────────
# 시작 판정(`any(. == …)`)과 후보 제외(`case ",$labels," in … continue`)는 같은 집합이어야
# 한다. 제외 쪽에만 새 진행 라벨이 들어가면 그 레인의 leaf 는 후보에서도 빠지고 시작
# 판정도 못 줘서 finish-first 가 조용히 한 출처를 잃는다(빨개지는 곳이 없던 자리다).
# `needs-human` 은 **의도된 차이** — 진행이 아니라 사람 대기라 시작 집합에 안 든다.
a_line=$(grep -n 'any(\. ==' "$DIR/eligible-issues.sh" | head -n 1)
a_labels=$(printf '%s' "$a_line" | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
loop_labels=$(grep -E '^[[:space:]]*case ",\$labels," in .*continue' "$DIR/eligible-issues.sh" \
  | grep -oE '\*",[^,"]+,"\*' | sed 's/^\*",//; s/,"\*$//' | sort -u)
loop_prog=$(printf '%s\n' "$loop_labels" | grep -v '^needs-human$' | grep -v '^$' | sort -u)
ck "Ⓔ⑩ 시작 판정 쪽 진행 라벨 4개를 실제로 찾았다" \
  "$(printf '%s\n' "$a_labels" | grep -c .)" "4"
ck "Ⓔ⑩ 후보 제외 쪽에서도 같은 4개를 찾았다" \
  "$(printf '%s\n' "$loop_prog" | grep -c .)" "4"
ck "Ⓔ⑩ 두 자리의 진행 라벨 집합이 같다" \
  "$(printf '%s' "$a_labels" | tr '\n' ' ')" "$(printf '%s' "$loop_prog" | tr '\n' ' ')"

# ── Ⓔ⑪ (b) 창 절단·창 크기 미상도 말한다 ─────────────────────────────────
# 이 검색은 한 장(per_page 100)뿐이다 — 닫힌 leaf 가 창을 넘으면 시작 집합이 **부분**이
# 되고, 그 사실이 침묵하면 "정렬이 왜 이렇지" 를 아무도 되짚을 수 없다.
TRUNC_101='warn: 에픽 시작 집합 부분 조회 — 최근 14일 닫힌 leaf 101건 > 창 100, finish-first 힌트가 부분적이다'
fx=$(mkfx e11a 34)
add_issue "$fx" 110 '["agent-ready","P2"]' '에픽 leaf' 'Epic #700' '2026-01-09T00:00:00Z'
add_issue "$fx" 111 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
set_closed_total "$fx" 101
run_sut "$fx"
ck "Ⓔ⑪ 절단이어도 exit 0" "$RC" "0"
has_line "Ⓔ⑪ 101 → 절단 warn" "$ERR" "$TRUNC_101"
ck "Ⓔ⑪ 절단이어도 받아 온 만큼은 시작 판정에 쓴다" "$(jq -c '[.[].number]' "$OUT")" '[110,111]'
fx=$(mkfx e11b 34)
add_issue "$fx" 112 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
set_closed_total "$fx" 100
run_sut "$fx"
no_line "Ⓔ⑪ 100 → 침묵(경계는 >)" "$ERR" "에픽 시작 집합 부분 조회"
fx=$(mkfx e11c 34)
add_issue "$fx" 113 '["agent-ready","P2"]' '에픽 없음' '본문만 있다' '2026-01-01T00:00:00Z'
set_closed_total "$fx" null
run_sut "$fx"
ck "Ⓔ⑪ 미상이어도 exit 0" "$RC" "0"
has_line "Ⓔ⑪ total_count 미상 → 침묵이 아니라 warn" "$ERR" \
  "warn: 에픽 시작 집합 창 크기 미상 — total_count 를 못 읽었다(닫힌 leaf 절단 여부 판정 불가)"
no_line "Ⓔ⑪ 미상은 조회 실패가 아니다" "$ERR" "에픽 시작 집합 조회 실패"

# ── Ⓔ⑫ 두 축의 교차 — 페이지를 **전부 모은 뒤 한 번** 정렬한다 (#257 × #277) ──
# 이 칸이 이번 머지 해소의 심장이다. 페이지네이션(#315)과 finish-first(#257)는 같은 함수를
# 고치는데, 정렬이 **페이지별로** 돌면 전역 순서가 아니라 "1페이지 안에서의 순서 + 2페이지
# 안에서의 순서" 가 되어 'Epic 먼저' 가 거짓이 된다 — 그 형상에선 아래 두 단언이 갈린다:
#   · 2페이지에만 있는 시작-에픽 leaf(#210)가 1페이지의 에픽 없는 후보들보다 **앞**에 온다.
#   · 2페이지의 진행 라벨 row(#211)가 1페이지 후보(#202)에 **시작 판정을 준다**((a) 출처가
#     1페이지에 갇히면 #202 는 종전 자리로 떨어진다).
# 창은 env 로 5 × 3 페이지로 줄인다(총 7건 = 1페이지 5 + 2페이지 2).
fx=$(mkfx e12 7)
mkpage "$fx" 2 7
add_issue "$fx" 200 '["agent-ready","P2"]' '에픽 없음 (1p)' '본문만 있다' '2026-01-01T00:00:00Z'
add_issue "$fx" 201 '["agent-ready","P2"]' '에픽 없음 (1p)' '본문만 있다' '2026-01-02T00:00:00Z'
add_issue "$fx" 202 '["agent-ready","P2"]' '2페이지 row 가 시작시킨 leaf (1p)' 'Epic #701' '2026-01-08T00:00:00Z'
add_issue "$fx" 203 '["agent-ready","P2"]' '에픽 없음 (1p)' '본문만 있다' '2026-01-03T00:00:00Z'
add_issue "$fx" 204 '["agent-ready","P2"]' '에픽 없음 (1p)' '본문만 있다' '2026-01-04T00:00:00Z'
add_issue_to "$fx" search.p2.json 210 '["agent-ready","P2"]' '닫힌 leaf 가 시작시킨 leaf (2p)' \
  'Epic #700' '2026-01-09T00:00:00Z'
add_issue_to "$fx" search.p2.json 211 '["agent-ready","flow:verify"]' '2페이지의 진행 라벨 row' \
  'Epic #701' '2026-01-05T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
run_sut_small "$fx"
ck "Ⓔ⑫ exit 0" "$RC" "0"
ck "Ⓔ⑫ 2페이지를 이어 받았다" "$(count_of "$LOG" 'search page=2')" "1"
ck "Ⓔ⑫ page=3 은 안 부른다(2페이지로 total 7 을 덮었다)" "$(count_of "$LOG" 'search page=3')" "0"
# 손계산: 전부 P2 → 시작한 에픽 먼저(202 01-08 · 210 01-09) → 나머지는 오래된 순.
ck "Ⓔ⑫ 전역 정렬 — 페이지를 모은 뒤 한 번 정렬한다" \
  "$(jq -c '[.[].number]' "$OUT")" '[202,210,200,201,203,204]'
# 페이지별로 따로 정렬해 이어 붙였다면 1페이지 6건이 먼저 오고 210 이 꼴찌다.
ck "Ⓔ⑫ 페이지별 정렬 순서가 아니다" \
  "$(jq -c '[.[].number] == [202,200,201,203,204,210]' "$OUT")" 'false'
ck "Ⓔ⑫ (a) 출처가 2페이지 row 에서도 나온다 — #202 가 시작 판정을 받았다" \
  "$(jq -c '[.[] | select(.number == 202) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":701,"s":true}]'
ck "Ⓔ⑫ 2페이지 진행 라벨 row 본문 조회 0회(추가 호출 없음)" "$(count_of "$LOG" 'body 211')" "0"
ck "Ⓔ⑫ 진행 라벨 row 는 후보에서 빠진다" \
  "$(jq -c '[.[].number] | index(211)' "$OUT")" 'null'

# ── Ⓔ⑬ 정렬 키의 경계값 — 빈 본문 · `Epic` 줄 없음 · P 라벨 없음 ──────────
# `gh issue view --json body -q '.body // ""'` 는 본문이 비면 **빈 문자열**을 준다. 그 값이
# `epic_of` 에 들어가면 grep 이 한 줄도 못 물어 파이프가 비는데, 이 스크립트는
# `set -euo pipefail` 아래라 그 자리에 가드가 없으면 큐 전체가 멈춘다. P 라벨 없음(prio=3)
# 까지 같은 픽스처에서 함께 문다 — 세 경계가 겹치는 행이 실제 재고에 가장 흔하다.
fx=$(mkfx e13 3)
add_issue "$fx" 220 '["agent-ready"]'      'P 없음 · 빈 본문'   '' '2026-01-02T00:00:00Z'
add_issue "$fx" 221 '["agent-ready","P2"]' 'P2 · 빈 본문'       '' '2026-01-01T00:00:00Z'
add_issue "$fx" 222 '["agent-ready"]'      'P 없음 · 시작 에픽' 'Epic #700' '2026-01-05T00:00:00Z'
add_closed_leaf "$fx" owner/repo 'Epic #700'
run_sut "$fx"
ck "Ⓔ⑬ 빈 본문에서도 exit 0(파이프라인이 안 죽는다)" "$RC" "0"
# 손계산: P2(221) → P 없음(prio 3) 안에서 시작한 에픽(222) → 나머지(220).
ck "Ⓔ⑬ P 없음 칸 안에서도 finish-first 가 돈다" "$(jq -c '[.[].number]' "$OUT")" '[221,222,220]'
ck "Ⓔ⑬ 빈 본문은 epic null · epic_started false" \
  "$(jq -c '[.[] | select(.number == 220 or .number == 221) | {e:.epic, s:.epic_started}]' "$OUT")" \
  '[{"e":null,"s":false},{"e":null,"s":false}]'
ck "Ⓔ⑬ P 라벨이 없으면 priority 는 종전대로 3" \
  "$(jq -c '[.[] | {n:.number, p:.priority}]' "$OUT")" \
  '[{"n":221,"p":2},{"n":222,"p":3},{"n":220,"p":3}]'
no_line "Ⓔ⑬ 빈 본문이 warn 을 만들지 않는다" "$ERR" "warn:"

# ── Ⓔ⑭ 큰 본문 × 페이지 병합 — 합치는 경로가 argv 를 타면 안 된다 (#257 × #277) ──
# 이 PR 이 검색 투영에 `body` 를 되돌려 얹어(시작 집합 (a) 의 출처) 페이지 병합 페이로드가
# **21배**가 됐다(실측: 한 페이지 50건 = body 없이 6941 bytes → 있으면 152441 bytes).
# `--argjson` 으로 합치면 그 누적이 통째로 커맨드라인 인자가 되어 ARG_MAX(1048576)에 걸리고,
# `set -e` 아래라 **디스패치 틱 전체가 죽는다**. 실측 여유는 28% 뿐이었다 —
# 기본 상수(50×5=250)의 마지막 병합이 상한의 78% 를 쓰고, 건당 본문 평균이 4020 bytes 를
# 넘으면 터진다(오늘 라이브 평균 3133 bytes). 같은 실패를 `loop-status.sh:601-604` 가
# 이미 문서로 남겼다(그쪽은 `--slurpfile` 로 막았다).
#
# 격자는 창 5 × 3페이지에 본문 150KB × 10건을 실어 **어느 박스에서도** 확실히 상한을 넘긴다
# (한 병합의 두 인자 합 ≈ 1.5MB > 1.04MB). argv 경로면 여기서 `Argument list too long`.
# 건수는 적게(페이지당 2건), 본문은 크게(300KB) — 병합 한 번의 두 인자 합 ≈ 1.2MB 로
# 상한을 확실히 넘기면서 스텁 호출 수는 4건뿐이라 스위트가 안 느려진다.
fx=$(mkfx e14 10)
mkpage "$fx" 2 10
bulk_big_issues "$fx" search.json    300 2 300000
bulk_big_issues "$fx" search.p2.json 305 2 300000
run_sut_small "$fx"
ck "Ⓔ⑭ 1.2MB 페이지 병합에서도 exit 0(argv 경로면 Argument list too long)" "$RC" "0"
ck "Ⓔ⑭ 두 페이지 후보가 하나도 안 없어진다" "$(jq 'length' "$OUT")" "4"
ck "Ⓔ⑭ 2페이지 후보가 실제로 있다" \
  "$(jq -c '[.[].number] | map(select(. >= 305)) | sort' "$OUT")" '[305,306]'
ck "Ⓔ⑭ 2페이지를 이어 받았다" "$(count_of "$LOG" 'search page=2')" "1"
no_line "Ⓔ⑭ 큰 본문이 진단을 만들지 않는다" "$ERR" "warn:"
# ── ⑩ 본문 조회 실패는 **그 후보만** 접는다 (#330) ────────────────────────
# 수정 전: `body=$(gh issue view …)` 에 가드가 없어 `set -euo pipefail`(:15) 아래서
# 단 한 건의 502 가 스크립트를 비0 종료시켰다 — **앞서 정상 판정한 후보까지** stdout 째로
# 버려져 디스패처가 그 틱을 "후보 0" 으로 읽는다(창이 250 으로 커진 뒤 호출 수가 5배라
# 같은 단건 실패 확률에서 틱 사망 확률도 5배). 자세는 바로 아래 블로커 조회와 같다.
fx=$(mkfx bodyfail 34)
add_issue "$fx" 30 '["agent-ready"]' '앞 후보' ''
add_issue "$fx" 31 '["agent-ready"]' '본문 조회가 죽는 후보' '' '2026-01-01T00:00:31Z'
add_issue "$fx" 32 '["agent-ready"]' '뒤 후보' '' '2026-01-01T00:00:32Z'
# 실제 gh 오류문은 여러 줄로 온다 — warn 은 ④ Report 가 옮기는 **한 줄**이어야 한다.
add_body_fail "$fx" 31 'gh: HTTP 502 Bad Gateway
try again later'
run_sut "$fx"
ck "⑩ 한 건이 실패해도 스크립트는 끝까지 간다(exit 0)" "$RC" "0"
ck "⑩ 앞·뒤 후보가 stdout 에 남는다(목록 전체를 버리지 않는다)" \
  "$(jq -c '[.[].number]' "$OUT")" '[30,32]'
ck "⑩ 실패 다음 후보도 판정한다(루프가 안 끊긴다)" "$(count_of "$LOG" 'body 32')" "1"
has_line "⑩ 실패를 한 줄 warn 으로 말한다(여러 줄 오류문은 접는다)" "$ERR" \
  "warn: owner/repo#31 본문 조회 실패 — 블로커 미상이라 이번 틱 후보에서 제외(다음 틱 재시도): gh: HTTP 502 Bad Gateway try again later"
# 오류문 접기를 지우면 `try again later` 가 **둘째 줄**로 떨어진다 — 줄 수를 직접 센다
# (후보별 warn 1 + 집계 warn 1 + blocked-summary 1 = 3줄이 이 픽스처의 stderr 전부다).
ck "⑩ stderr 는 정확히 3줄(오류문이 줄을 늘리지 않는다)" "$(wc -l < "$ERR" | tr -d ' ')" "3"
# 후보별 warn 만 두면 2차 레이트리밋에서 100줄로 풀려 ④ Report 에 **숫자로는** 안 남는다.
has_line "⑩ 몇 건이 빠졌는지 집계 한 줄" "$ERR" \
  "warn: 본문 조회 실패 1건 — 그만큼 이번 틱 후보에서 빠졌다(다음 틱 재시도)"
# 빈 본문으로 이어 가지 않는다(PR#139: 빈 결과 ≠ 실패) — 본문을 못 읽으면 "Blocked by #N"
# 유무가 **미상**이라, 통과시키면 블로커 0건으로 읽혀 게이트가 증명 없이 열린다.
no_line "⑩ 실패 후보를 빈 본문으로 통과시키지 않는다" "$OUT" '"number": 31'
# `막힘` 은 **OPEN 블로커로 탈락한 수**라는 정의를 그대로 둔다(SKILL.md ③-2 계약) —
# 조회 실패는 그 정의가 아니라 `warn:` 줄로 Report 에 실린다.
has_line "⑩ blocked-summary 정의는 안 바뀐다(OPEN 블로커 0건)" "$ERR" "blocked-summary: 막힘 0건"

# ── ⑩-b 성공 경로의 stderr 가 **본문에 섞이지 않는다** ─────────────────────
# 조회 값을 `2>&1` 로 받으면 성공했을 때도 gh 의 stderr 한 줄이 본문에 붙고, 그 문자열을
# 아래 `Blocked by #N` 파싱이 그대로 훑는다 — **유령 블로커**로 정상 후보가 소리 없이
# 큐에서 빠진다(이 PR 이 막으려는 결함과 같은 모양). 바로 아래 블로커 조회는 `2>&1` 을
# 쓰지만 그쪽은 성공 출력에 TAB 구분자가 있어 오염을 검사해 걸러낸다 — 자유 문자열인
# 본문엔 그 이음매가 없으므로 여기서는 stderr 를 **따로** 받는다.
# 픽스처 문구는 일부러 결정적이다(실제 gh 알림 문구가 이 정규식에 걸린다는 주장이 아니라,
# "stderr 는 어떤 내용이든 본문에 안 들어간다"를 무는 칸이다).
fx=$(mkfx bodystderr 34)
add_issue "$fx" 33 '["agent-ready"]' '본문은 깨끗한데 gh 가 stderr 로도 쓴다' ''
add_body_stderr "$fx" 33 'Blocked by #900'
run_sut "$fx"
ck "⑩-b exit 0" "$RC" "0"
ck "⑩-b stderr 문구가 블로커로 둔갑하지 않는다(블로커 조회 0회)" "$(count_of "$LOG" 'blocker ')" "0"
no_line "⑩-b 유령 블로커로 탈락시키지 않는다" "$ERR" "blocked: owner/repo#33"
ck "⑩-b 후보는 그대로 stdout 에 남는다" "$(jq -c '[.[].number]' "$OUT")" '[33]'

# ── ⑪ page=1 조회 실패는 fail-closed — 빈 목록으로 둔갑시키지 않는다 (#330) ──
# search 2차 레이트리밋은 이 레포가 이미 사고로 기록한 모양이다: stdout `[]` + rc=0 이면
# 디스패처가 "신규 0" 으로 읽어 **빈 큐와 구분 없이** 조용히 지나간다. 그래서 단언은
# `rc≠0` 과 `stdout 이 비어 있음`(부분/빈 목록 미채택)을 **함께** 물어야 한다.
# `search.p1.fail` 이 먼저 걸려 스텁은 `search.json` 을 아예 안 읽는다 — 후보 픽스처를
# 두지 않는 것이 형상 그대로다(있어도 판정에 안 쓰인다).
fx=$(mkfx p1fail 13)
printf 'gh: HTTP 403 API rate limit exceeded\n' > "$fx/search.p1.fail"
run_sut_small "$fx"
ck "⑪ page=1 조회 실패 → exit 1" "$RC" "1"
ck "⑪ 빈 후보 목록을 stdout 으로 내지 않는다(빈 큐와 구분)" "$(cat "$OUT")" ""
has_line "⑪ 어느 페이지에서 끊겼는지 말한다" "$ERR" \
  "eligible-issues: 검색 page=1 조회 실패 — 후보 목록 없이 진행하지 않는다(이번 틱 중단): gh: HTTP 403 API rate limit exceeded"
ck "⑪ 2페이지를 부르지 않는다" "$(count_of "$LOG" 'search page=2')" "0"

# ── ⑫ env 방어 — 정규화·하한·클램프가 **요청에 실제로 반영**된다 (#330) ──────
# 창 상수는 테스트 격자용 이음매라 임의 문자열이 들어올 수 있다. warn 문구만 보면
# 값이 어떻게 정규화됐는지 안 보이므로 스텁이 남긴 `per_page=` 를 함께 문다.

# ⑫-a `0` → 하한(≥1)에 걸려 기본값 50 으로 되돌린다. per_page=0 은 창이 없는 요청이다.
fx=$(mkfx env0 51)
bulk_issues "$fx" search.json 160 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=0 ELIGIBLE_SEARCH_MAX_PAGES=1
ck "⑫-a exit 0" "$RC" "0"
has_line "⑫-a 0 → per_page 는 기본값 50" "$LOG" "search page=1 per_page=50"
has_line "⑫-a 0 → 실질 상한도 50(페이지 1 × 50)" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 51건 > 창 50(페이지 1 × 50), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"

# ⑫-b `abc` → 비숫자는 기본값으로. 정규화를 지우면 `[ abc -ge 1 ]` 이 셸 오류를 stderr 로
# 흘려 ④ Report 가 옮기는 진단이 오염된다.
fx=$(mkfx envabc 51)
bulk_issues "$fx" search.json 161 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=abc ELIGIBLE_SEARCH_MAX_PAGES=1
ck "⑫-b exit 0" "$RC" "0"
has_line "⑫-b abc → per_page 는 기본값 50" "$LOG" "search page=1 per_page=50"
no_line "⑫-b 셸 산술 오류가 stderr 로 새지 않는다" "$ERR" "integer expression"

# ⑫-c `200` → search API 의 per_page 상한은 100 이다. 안 깎으면 1페이지부터 422 로 틱이 죽는다.
fx=$(mkfx env200 101)
bulk_issues "$fx" search.json 162 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=200 ELIGIBLE_SEARCH_MAX_PAGES=1
ck "⑫-c exit 0" "$RC" "0"
has_line "⑫-c 200 → per_page 는 100 으로 깎인다" "$LOG" "search page=1 per_page=100"
has_line "⑫-c 깎인 값이 상한 산술에도 반영된다(페이지 1 × 100)" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 101건 > 창 100(페이지 1 × 100), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"

# ⑫-d `010` → 10진수로 읽는다. `$((010))` 은 8진수 8 이라 창이 조용히 좁아진다.
fx=$(mkfx env010 11)
bulk_issues "$fx" search.json 163 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=010 ELIGIBLE_SEARCH_MAX_PAGES=1
ck "⑫-d exit 0" "$RC" "0"
has_line "⑫-d 010 → per_page 는 10(8진수 8 이 아니다)" "$LOG" "search page=1 per_page=10"
has_line "⑫-d 상한 산술도 10 기준" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 11건 > 창 10(페이지 1 × 10), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"

# ⑫-f `ELIGIBLE_SEARCH_MAX_PAGES=010` → 10진수 10. `$((5 * 010))` 은 8진수라 40 인데
# 루프 조건 `[ "$page" -lt "$SEARCH_MAX_PAGES" ]` 는 test(1) 이라 10 으로 읽는다 —
# 정규화가 없으면 **상한 산술과 루프가 갈린다**(창 40 이라 경고해 놓고 10페이지까지 돈다).
fx=$(mkfx envmp010 51)
mkpage "$fx" 2 51
bulk_issues "$fx" search.json 165 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=5 ELIGIBLE_SEARCH_MAX_PAGES=010
ck "⑫-f exit 0" "$RC" "0"
has_line "⑫-f 010 → 실질 상한은 50(= 5 × 10)" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 51건 > 창 50(페이지 10 × 5), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"

# ⑫-g `ELIGIBLE_SEARCH_MAX_PAGES=abc` → 기본값 5. 정규화를 지우면 `[ abc -ge 1 ]` 이
# 셸 오류를 stderr 로 흘려 ④ Report 가 옮기는 진단이 오염된다.
fx=$(mkfx envmpabc 26)
mkpage "$fx" 2 26
bulk_issues "$fx" search.json 166 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=5 ELIGIBLE_SEARCH_MAX_PAGES=abc
ck "⑫-g exit 0" "$RC" "0"
has_line "⑫-g abc → 실질 상한은 기본값 5페이지(= 5 × 5)" "$ERR" \
  "warn: 검색 창 절단 — agent-ready 후보 26건 > 창 25(페이지 5 × 5), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)"
no_line "⑫-g 셸 산술 오류가 stderr 로 새지 않는다" "$ERR" "integer expression"

# ⑫-h `ELIGIBLE_SEARCH_MAX_PAGES=0` → 하한에 걸려 기본값 5. 0 이면 실질 상한이 0 이라
# 후보가 몇 건이든 "절단" 을 외치고 2페이지를 영영 안 받는다(페이지네이션 자체가 꺼진다).
fx=$(mkfx envmp0 6)
mkpage "$fx" 2 6
bulk_issues "$fx" search.json 167 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=5 ELIGIBLE_SEARCH_MAX_PAGES=0
ck "⑫-h exit 0" "$RC" "0"
no_line "⑫-h 0 → 상한 0 으로 굳지 않는다(절단 warn 없음)" "$ERR" "검색 창 절단"
ck "⑫-h 0 → 페이지네이션이 살아 있다(page=2 호출)" "$(count_of "$LOG" 'search page=2')" "1"

# ⑫-e 상한이 아주 작으면 80% 임박선이 0 으로 깎인다 — 바닥이 없으면 후보 1건에도 임박
# warn 이 상시 켜져 진짜 상한 신호가 묻힌다(경고가 늘 켜져 있으면 신호가 아니다).
fx=$(mkfx envsoft 1)
bulk_issues "$fx" search.json 164 1
run_sut "$fx" ELIGIBLE_SEARCH_WINDOW=1 ELIGIBLE_SEARCH_MAX_PAGES=1
ck "⑫-e exit 0" "$RC" "0"
no_line "⑫-e 상한과 같은 후보 수에 임박 warn 이 켜지지 않는다" "$ERR" "검색 창 임박"
no_line "⑫-e 절단도 아니다(1 > 1 이 아니다)" "$ERR" "검색 창 절단"
ck "⑫-e 후보는 그대로 낸다" "$(jq -c '[.[].number]' "$OUT")" '[164]'

echo "eligible-issues.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
