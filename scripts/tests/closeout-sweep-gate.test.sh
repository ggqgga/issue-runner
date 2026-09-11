#!/usr/bin/env bash
# closeout-sweep-gate.test.sh — ①-b 스윕 판정 픽스처 8종 (#218 a~h).
#
# ①-b 의 최종 조치는 SKILL.md 프로즈(LLM 워커가 읽고 따른다)지 셸 함수가 아니다.
# 그래서 이 파일은 "생산 로직" 이 아니라 SKILL.md ①-b 가 문서화한 결정 규칙을
# **그대로 거울처럼 재현한 핀 테스트**다 — `sweep_decide()` 는 여기서만 쓰는 테스트
# 헬퍼이고, 판정에 쓰는 값은 실제 `bounce-state.sh`·`finish-classify.sh` 를 그대로
# 호출해서 얻는다(두 헬퍼의 env 주입 계약 — `BOUNCE_COMMENTS_FILE`·`FC_COMMENTS_JSON`
# 등 — 을 그대로 쓰므로 gh 스텁이 필요 없다). mergeable 값은 ①-b 프로즈가 이미
# bounce-state.sh 를 `ok` 로 통과한 **뒤에만** 보므로 여기서도 매개변수로 직접 넘긴다
# (①-b 가 mergeable 을 실제로 어떻게 읽는지는 이 파일의 관심사가 아니다 — 그건 gh
# 호출 하나뿐이라 테스트할 로직이 없다).
#
# 구조적 배선(호출이 갈래를 가르기 **전**에 있는지)은 bin/ci 의 별도 grep 가드
# (`--json mergeable` 보다 `$SCRIPTS/bounce-state.sh` 가 앞인지)가 문다 — 그 가드는
# 문서 텍스트의 줄 순서를 잰다. 이 파일은 **판정 결과**가 맞는지를 잰다. 둘이 함께
# #218 의 회귀(반송된 MERGEABLE PR 이 `stale_reverify` 로 오분류·재디스패치)를 막는다.
#
# `sweep_decide()` 가 SKILL.md 본문과 달라지면 이 파일도 고쳐라(SSOT 는 SKILL.md —
# 이 파일은 그 계약의 회귀 감시일 뿐).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# ── 새 규칙(#218 두 번째 회차 — 사람 결정 (c)) — SKILL.md ①-b 1)·2) 절을 그대로
#    거울 재현 ─────────────────────────────────────────────────────────────
#   bounce == held/bounced/판정실패(그 외) → active(무접촉), mergeable 도
#     finish-classify 도 안 본다. `held` 는 스윕이 needs-human 으로 승격하던
#     계약이 폐지됐다(bounce-state.sh 는 여전히 held 를 구분해 내지만, 스윕은 그
#     값을 bounced 와 똑같이 취급한다 — bounce-state.sh 가 "이미 한 번 붙었다 뗀
#     held"와 "처음 보는 held"를 문자열만으로 구분할 수 없어서다).
#   bounce == ok, CONFLICTING → adopt_conflict(입양)
#   bounce == ok, 그 외        → finish-classify 결과를 그대로 조치로 사용
#     (finish-classify 자신의 `held` 행 — 반송 마커가 없는 순수 ⚠ — 은 이 폐지의
#     영향을 받지 않는다. 아래 (e) 가 그 대조군이다.)
sweep_decide() {
  local mergeable="$1" bounce_file="$2" fc_json="$3" fc_now="$4" fc_head_at="$5"
  local bstate rc=0 fc
  bstate=$(BOUNCE_COMMENTS_FILE="$bounce_file" bash "$DIR/bounce-state.sh" owner/repo 9 2>/dev/null) || rc=$?
  # #206 예외 갈래 — `bounced` **이면서 CONFLICTING** 인 한 칸만 무접촉에서 열린다.
  # (반송 뒤 교체 워커가 커밋까지 하고 ✅ 직전에 죽은 PR 이 세 레인 모두에서 빠지는
  #  정체. 재디스패치 갈래만 열고 입양은 어느 출력에서도 안 연다.)
  if [ "$rc" = 0 ] && [ "$bstate" = "bounced" ] && [ "$mergeable" = "CONFLICTING" ]; then
    fc=$(FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
      FC_CLAIMED_AT=none bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null)
    case "$fc" in
      stale_reverify|stale_inline) echo "redispatch" ;;
      *)                           echo "active" ;;
    esac
    return
  fi
  if [ "$rc" != 0 ] || [ "$bstate" != "ok" ]; then
    echo "active"
    return
  fi
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "adopt_conflict"
    return
  fi
  FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
    FC_CLAIMED_AT=none \
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}

# ── 이전 규칙(#218 attempt 2~4, 이번 회차 이전 — PR #225 as of attempt 4) ────
# `held` 를 만나면 즉시 needs-human 으로 승격하던 규칙. (c) 로 폐지되기 **전** 상태를
# 그대로 보존해 아래 뮤테이션 방증 4 의 "되돌리면" 쪽 베이스라인으로 쓴다.
sweep_decide_pre_c() {
  local mergeable="$1" bounce_file="$2" fc_json="$3" fc_now="$4" fc_head_at="$5"
  local bstate rc=0
  bstate=$(BOUNCE_COMMENTS_FILE="$bounce_file" bash "$DIR/bounce-state.sh" owner/repo 9 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ "$bstate" = "held" ]; then
    echo "held"
    return
  fi
  if [ "$rc" != 0 ] || [ "$bstate" != "ok" ]; then
    echo "active"
    return
  fi
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "adopt_conflict"
    return
  fi
  FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
    FC_CLAIMED_AT=none \
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}

# attempt-1 규칙(#218 첫 회차)은 별도 함수로 더 두지 않는다 — `bounced`/`held` 를
# 구분 없이 한 방향(무접촉)으로만 받던 그 판정은, 두 번째 회차(사람 결정 (c))가
# `sweep_decide` 자체를 다시 그 모양으로 되돌렸기 때문에 지금의 `sweep_decide` 와
# **값이 같다**(우연이 아니다 — (c) 는 "held 를 특별 취급하지 않는다"로 되돌아간
# 결정이다). attempt-1 전용 뮤테이션 대조는 그래서 더 이상 새 정보를 안 준다 —
# 아래 뮤테이션 방증 4(`sweep_decide_pre_c` 대조)가 지금 실제로 의미 있는 비교다.

# ── 구 규칙(pre-#218) — CONFLICTING 갈래 **안**에만 게이트가 있던 형상.
#   MERGEABLE 은 bounce-state 를 아예 보지 않고 곧장 finish-classify 로 간다.
#   이 함수는 뮤테이션 방증(아래)에만 쓰인다 — 프로덕션에 남지 않는다.
sweep_decide_pre218() {
  local mergeable="$1" bounce_file="$2" fc_json="$3" fc_now="$4" fc_head_at="$5"
  local bstate rc=0
  if [ "$mergeable" = "CONFLICTING" ]; then
    bstate=$(BOUNCE_COMMENTS_FILE="$bounce_file" bash "$DIR/bounce-state.sh" owner/repo 9 2>/dev/null) || rc=$?
    if [ "$rc" != 0 ] || [ "$bstate" != "ok" ]; then
      echo "active"
    else
      echo "adopt_conflict"
    fi
    return
  fi
  FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
    FC_CLAIMED_AT=none \
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}

run() {
  local name="$1" fn="$2" mergeable="$3" bounce_file="$4" fc_json="$5" fc_now="$6" fc_head_at="$7" expect="$8"
  local out
  out=$("$fn" "$mergeable" "$bounce_file" "$fc_json" "$fc_now" "$fc_head_at")
  if [ "$out" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$expect 실제=$out"
  fi
}

# ── 픽스처 시계·형상 ──────────────────────────────────────────────────────
# STALE_FINISH_MIN 기본 30분을 넉넉히 넘긴 2시간 뒤로 FC_NOW 를 고정한다.
now_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-09-11T03:00:00Z" +%s 2>/dev/null \
  || date -u -d "2026-09-11T03:00:00Z" +%s)
head_at="2026-09-11T00:50:00Z"   # head 커밋도 오래돼 stale — attempt N+1 오분류 방지 갈래를 안 탄다

# (a)(c) 공용: 🔄 + 검증자 BLOCKER 미해결 → finish-classify 단독으로는 stale_reverify.
# 실측 재현: bodat PR #5050 / 이슈 #5036.
stale_reverify_comments='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:10:00Z"},
  {"body":"재검증 실패: #5036 — codex BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-11T01:20:00Z"}
]'
printf '%s' "$stale_reverify_comments" > "$tmp/bounced.json"

# (b): 반송 마커 없음(ok) — 같은 stale_reverify 형상, 워커가 그냥 죽은 경우.
no_bounce_comments='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"}
]'
printf '%s' "$no_bounce_comments" > "$tmp/ok.json"

# (e)(f) 공용: 워커가 `⚠ 보류` 를 찍은 뒤 verify 가 반송한 순서(이슈 본문이 명시
# 검토를 요청한 held 갈래 겹침) — finish-classify 단독으로는 최신 `머지 판정:` 이
# ⚠ 이므로 즉시 held 다(🔄 갈래처럼 버퍼·검증자 판정을 보지 않는다).
held_bounced_comments='[
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"},
  {"body":"재검증 실패: #5036 — codex BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-11T01:20:00Z"}
]'
printf '%s' "$held_bounced_comments" > "$tmp/held_bounced.json"

# (e): 반송 마커 없음(ok) — 워커가 정말로 보류를 찍고 끝난 정상 held 형상.
held_ok_comments='[
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"}
]'
printf '%s' "$held_ok_comments" > "$tmp/held_ok.json"

# ── #218 Test plan 픽스처 4종 (신규 규칙 sweep_decide 로 판정) ─────────────

# (a) stale_reverify 형상 + bounced → 무접촉(active). #218 이 고치는 바로 그 사고.
run "(a) MERGEABLE·stale_reverify 형상+bounced→무접촉" sweep_decide \
  MERGEABLE "$tmp/bounced.json" "$stale_reverify_comments" "$now_epoch" "$head_at" active

# (b) stale_reverify 형상 + ok(반송된 적 없음) → 재디스패치(stale_reverify, 무회귀).
run "(b) MERGEABLE·stale_reverify 형상+ok→재디스패치" sweep_decide \
  MERGEABLE "$tmp/ok.json" "$no_bounce_comments" "$now_epoch" "$head_at" stale_reverify

# (c) bounce-state 판정 실패(exit 1 — 코멘트 조회 실패 시뮬레이션: 존재하지 않는
#     주입 파일) → 무접촉(active). fail-closed — 판정 실패는 bounced 와 같은 방향.
run "(c) MERGEABLE·판정 실패(exit 1)→무접촉" sweep_decide \
  MERGEABLE "$tmp/does-not-exist.json" "$stale_reverify_comments" "$now_epoch" "$head_at" active

# (d) CONFLICTING + ok → 입양(무회귀). 종전 #196 CONFLICTING 입양 레인이 그대로다.
run "(d) CONFLICTING+ok→입양(무회귀)" sweep_decide \
  CONFLICTING "$tmp/ok.json" "$no_bounce_comments" "$now_epoch" "$head_at" adopt_conflict

# ── held 갈래 겹침 (이슈 본문 요청: "held 갈래도 함께 검토하라") ────────────

# (e) held 형상 + ok(정말 보류) → held(needs-human, 무회귀). 정상 보류는 그대로 선다.
run "(e) MERGEABLE·held 형상+ok→held(무회귀)" sweep_decide \
  MERGEABLE "$tmp/held_ok.json" "$held_ok_comments" "$now_epoch" "$head_at" held

# (f) held 형상 + bounced(워커 ⚠ 뒤 verify 반송) → 무접촉(active). 게이트가 없으면
#     finish-classify 가 여전히 `held` 를 내(최신 `머지 판정:` 만 보므로 반송 마커를
#     못 봄) needs-human 으로 잘못 승격한다 — 아래 뮤테이션 대조에서 실증.
run "(f) MERGEABLE·held 형상+bounced→무접촉" sweep_decide \
  MERGEABLE "$tmp/held_bounced.json" "$held_bounced_comments" "$now_epoch" "$head_at" active

# ── #218 attempt 2 픽스처, 두 번째 회차에서 기대값이 뒤집힌다(사람 결정 (c)) ──
# (g): **반송 마커 → 그 뒤 ⚠ 보류**(순서가 (f) 의 역방향). attempt 2 는 이 코멘트
#     배열을 "재검증 실패로 반송된 PR 에 교체 워커가 새로 붙어 사람 판단을 요청한
#     경우"로 읽어 `held`(needs-human)로 승격했다. 그런데 **이 코멘트 배열은 그
#     시나리오뿐 아니라, "이미 이 held 로 needs-human 이 붙었다가 사람이 라벨만
#     떼고 아직 교체 워커가 🔄 를 안 찍은 창"도 똑같이 표현한다** — 코멘트가 그때와
#     한 글자도 다르지 않으므로 bounce-state.sh 로는 둘을 가를 수 없다(위 (c) 논거
#     참조). 사람 결정 (c)는 그 모호함을 스윕이 아예 손대지 않는 쪽으로 정리했다 —
#     그래서 이 픽스처의 기대값은 attempt 1 시절로 되돌아간다(`active`). **되살아나는
#     회귀를 알고 받아들인 것**이지 버그가 아니다(SKILL.md "왜 held 를 스윕이 더
#     이상 승격하지 않는가" 절). 실측 재현: PR #225 검증자 리뷰(2026-09-11 00:50 UTC).
marker_then_held_comments='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:30:00Z"},
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 반송 게이트 갈래 확정 필요\n<!-- bodat:worker -->","createdAt":"2026-09-11T02:00:00Z"}
]'
printf '%s' "$marker_then_held_comments" > "$tmp/marker_then_held.json"

run "(g) MERGEABLE·반송 마커 뒤 ⚠ 보류→무접촉(#218 두 번째 회차, 사람 결정 (c))" sweep_decide \
  MERGEABLE "$tmp/marker_then_held.json" "$marker_then_held_comments" "$now_epoch" "$head_at" active

# ── #218 attempt 4 픽스처 — 새 종결 상태 `held` 의 **해제 경로** ─────────────
# (h): 마감 검증 BLOCKER 의 5단계를 그대로 재현한다.
#   ⑴ 반송 마커 ⑵ 워커 `⚠ 보류` → closeout 이 (g) 대로 `held` → `closeout-blocked` 로
#   `needs-human`+`hold:policy` 부착 ⑶ **사람이 그 보류를 풀어 라벨을 뗀다**
#   ⑷ 교체 워커가 `머지 판정: 🔄` 를 찍고 일을 재개한다 ⑸ **다음 closeout 틱** —
#   `needs-human` 이 없으니 PR 이 다시 스윕 대상이 된다. 여기서 판정이 또 `held` 면
#   `closeout-blocked` 가 **다시** 걸려 사람이 방금 푼 보류가 되살아나고, 단계 라벨이
#   정리되면서 **살아있는 교체 워커가 끊긴다**(그리고 `✅` 에 도달해야만 풀리는데
#   끊기니까 도달할 수 없다 — 매 틱 반복되는 영구 정체).
#   그래서 ⑸ 의 옳은 조치는 **무접촉(active)** 이다 — 워커 레인이 소유한 상태다.
human_released_then_resumed='[
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 반송 게이트 갈래 확정 필요\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"},
  {"body":"머지 판정: 🔄 진행 중 — attempt 2, 사람 판단 반영해 재개\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:30:00Z"}
]'
printf '%s' "$human_released_then_resumed" > "$tmp/human_released.json"

run "(h) 사람이 held 를 풀고 교체 워커가 🔄 로 재개→무접촉(보류가 되살아나지 않는다)" sweep_decide \
  MERGEABLE "$tmp/human_released.json" "$human_released_then_resumed" "$now_epoch" "$head_at" active

# ── #206 예외 갈래 — 반송 뒤 ✅ 직전 사망 + CONFLICTING ──────────────────────
# (i) CONFLICTING + bounced + stale_reverify 형상 → **재디스패치**. (a) 와 코멘트가 같고
#     mergeable 만 다르다 — 즉 이 한 칸만 무접촉에서 열린다는 것의 직접 대조다.
run "(i) CONFLICTING·stale_reverify 형상+bounced→재디스패치(#206 예외)" sweep_decide \
  CONFLICTING "$tmp/bounced.json" "$stale_reverify_comments" "$now_epoch" "$head_at" redispatch

# (j) 같은 CONFLICTING 이라도 `held`(반송 뒤 워커 ⚠) 면 예외가 열리지 않는다 — 무접촉.
run "(j) CONFLICTING·held 형상+bounced→무접촉(예외는 held 에 안 열린다)" sweep_decide \
  CONFLICTING "$tmp/held_bounced.json" "$held_bounced_comments" "$now_epoch" "$head_at" active

# (k) CONFLICTING + 판정 실패(exit 1) → 무접촉(fail-closed 무회귀 — 예외가 여기도 안 연다).
run "(k) CONFLICTING·판정 실패(exit 1)→무접촉" sweep_decide \
  CONFLICTING "$tmp/does-not-exist.json" "$stale_reverify_comments" "$now_epoch" "$head_at" active

# ── 뮤테이션 방증 3 — `$p_after` 를 후보에서 빼면 (h) 가 held 로 되살아난다 ──
# bounce-state.sh 사본에서 해제 경로 후보 한 줄(MUT-P)만 지워 attempt 3 상태로 되돌리고,
# 같은 ①-b 규칙(`sweep_decide`)을 그 사본으로 돌린다. 기대: (h) 만 `held` 로 뒤집히고
# (g)·(f)·(e) 대조군은 그대로 — 이게 마감 검증 BLOCKER 의 실물 재현이다.
mut3_sut="$tmp/mut3-bounce-state.sh"
sed '/MUT-P: 해제 경로 후보(#218 attempt 4)/d' "$DIR/bounce-state.sh" > "$mut3_sut"
if cmp -s "$DIR/bounce-state.sh" "$mut3_sut"; then
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 앵커(MUT-P) 를 못 찾았다 — 방증3 이 아무것도 안 바꾼다"
else
  pass=$((pass + 1))
fi
sweep_decide_attempt3() {
  local mergeable="$1" bounce_file="$2" fc_json="$3" fc_now="$4" fc_head_at="$5"
  local bstate rc=0
  bstate=$(BOUNCE_COMMENTS_FILE="$bounce_file" bash "$mut3_sut" owner/repo 9 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ "$bstate" = "held" ]; then echo "held"; return; fi
  if [ "$rc" != 0 ] || [ "$bstate" != "ok" ]; then echo "active"; return; fi
  if [ "$mergeable" = "CONFLICTING" ]; then echo "adopt_conflict"; return; fi
  FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
    FC_CLAIMED_AT=none \
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}
mut3_pass=0
mut3_fail=0
check_mutation3() {
  local name="$1" mergeable="$2" bounce_file="$3" fc_json="$4" expect_old="$5"
  local out
  out=$(sweep_decide_attempt3 "$mergeable" "$bounce_file" "$fc_json" "$now_epoch" "$head_at")
  if [ "$out" = "$expect_old" ]; then
    mut3_pass=$((mut3_pass + 1))
  else
    mut3_fail=$((mut3_fail + 1))
    echo "  ✗ 뮤테이션 대조3 $name — attempt-3 규칙 기대=$expect_old 실제=$out"
  fi
}
check_mutation3 "(h)→attempt-3 규칙에서 사람이 푼 보류가 되살아난다(held)" \
  MERGEABLE "$tmp/human_released.json" "$human_released_then_resumed" held
# 대조군 — 후보를 하나 더한 것 말고는 attempt 3 과 다르지 않다.
check_mutation3 "(g)→attempt-3 규칙에서도 무회귀(held)" \
  MERGEABLE "$tmp/marker_then_held.json" "$marker_then_held_comments" held
check_mutation3 "(f)→attempt-3 규칙에서도 무회귀(active)" \
  MERGEABLE "$tmp/held_bounced.json" "$held_bounced_comments" active
check_mutation3 "(e)→attempt-3 규칙에서도 무회귀(held)" \
  MERGEABLE "$tmp/held_ok.json" "$held_ok_comments" held
check_mutation3 "(a)→attempt-3 규칙에서도 무회귀(active)" \
  MERGEABLE "$tmp/bounced.json" "$stale_reverify_comments" active
check_mutation3 "(b)→attempt-3 규칙에서도 무회귀(stale_reverify)" \
  MERGEABLE "$tmp/ok.json" "$no_bounce_comments" stale_reverify
check_mutation3 "(d)→attempt-3 규칙에서도 무회귀(adopt_conflict)" \
  CONFLICTING "$tmp/ok.json" "$no_bounce_comments" adopt_conflict

if [ "$mut3_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증3: 해제 경로 후보를 빼면 (h) 가 실제로 held 로 되살아난다(mut3_pass=$mut3_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증3 실패 — 대조군이 어긋났다(mut3_pass=$mut3_pass mut3_fail=$mut3_fail)"
fi

# ── 뮤테이션 방증 — 게이트를 갈래 안으로 되돌리면 (a)·(c)·(f) 가 빨개진다 ──
# `sweep_decide_pre218` (게이트가 CONFLICTING 갈래 안에만 있던 구형상)로 같은
# 입력을 판정하면: (a)·(c)·(f) 는 MERGEABLE 이라 bounce-state 를 아예 안 보고
# 곧장 finish-classify 로 가 잘못된 조치를 낸다 — (a)·(c) 는 `stale_reverify`
# (무접촉이어야 할 것이 재디스패치), (f) 는 `held`(무접촉이어야 할 것이
# needs-human 으로 잘못 승격). (b)·(d)·(e) 는 게이트 위치 이동의 영향을 받지 않는
# 형상이라 그대로 통과해야 한다(이 비교가 전부 실패로 뒤집히는 게 아니라는 대조군).
mut_pass=0
mut_fail=0
check_mutation() {
  local name="$1" fn="$2" mergeable="$3" bounce_file="$4" fc_json="$5" expect_old="$6"
  local out
  out=$("$fn" "$mergeable" "$bounce_file" "$fc_json" "$now_epoch" "$head_at")
  if [ "$out" = "$expect_old" ]; then
    mut_pass=$((mut_pass + 1))
  else
    mut_fail=$((mut_fail + 1))
    echo "  ✗ 뮤테이션 대조 $name — 구형상 기대=$expect_old 실제=$out"
  fi
}
# 구형상에서 (a)·(c) 는 잘못된 값(stale_reverify)을, (f) 는 잘못된 값(held)을 낸다
# — 즉 새 규칙이 없으면 이 세 픽스처가 빨개진다는 것의 증명.
check_mutation "(a)→구형상에서 오분류(stale_reverify)" sweep_decide_pre218 \
  MERGEABLE "$tmp/bounced.json" "$stale_reverify_comments" stale_reverify
check_mutation "(c)→구형상에서 오분류(stale_reverify)" sweep_decide_pre218 \
  MERGEABLE "$tmp/does-not-exist.json" "$stale_reverify_comments" stale_reverify
check_mutation "(f)→구형상에서 오분류(held)" sweep_decide_pre218 \
  MERGEABLE "$tmp/held_bounced.json" "$held_bounced_comments" held
# 대조군 — (b)·(d)·(e) 는 게이트 위치 이동과 무관해 구형상에서도 그대로다.
check_mutation "(b)→구형상에서도 무회귀(stale_reverify)" sweep_decide_pre218 \
  MERGEABLE "$tmp/ok.json" "$no_bounce_comments" stale_reverify
check_mutation "(d)→구형상에서도 무회귀(adopt_conflict)" sweep_decide_pre218 \
  CONFLICTING "$tmp/ok.json" "$no_bounce_comments" adopt_conflict
check_mutation "(e)→구형상에서도 무회귀(held)" sweep_decide_pre218 \
  MERGEABLE "$tmp/held_ok.json" "$held_ok_comments" held

if [ "$mut_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증: 게이트를 CONFLICTING 갈래 안으로 되돌리면 (a)·(c)·(f) 가 실제로 오분류된다(mut_pass=$mut_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증 실패 — 대조군이 어긋났다(mut_pass=$mut_pass mut_fail=$mut_fail)"
fi

# ── 뮤테이션 방증 4 — (c) 를 되돌리면 "사람이 푼 홀드를 되붙이는" (g) 가 실제로
#    빨개진다, 그리고 반대편("새 판정" 경로, (e))은 여전히 초록이다 (#218 두 번째 회차) ──
# `sweep_decide_pre_c` 는 이번 회차 **이전**(PR #225 attempt 4 상태 그대로) 규칙이다
# — `held` 를 만나면 즉시 needs-human 으로 승격한다. (g) 의 코멘트 배열은 "brand-new
# ⚠" 와 "이미 붙였다 사람이 뗀 ⚠" 를 동시에 표현하므로(위 (g) 주석 참조), (c) 이전
# 규칙은 후자의 경우에도 무조건 승격해 **사람이 방금 푼 홀드를 되붙인다** — 이게 이번
# 이슈가 닫는 실제 사고다. (c) 이후 규칙(`sweep_decide`)은 (g) 를 무접촉으로 돌려
# 그 되붙임을 막는다. 대조군 (e) 는 반송 마커가 없어 애초에 이 게이트를 거치지
# 않고 finish-classify 자신의 held 행으로 승격되므로 — "새 판정이 서면 그때 붙는
# 경로" — (c) 전후로 **똑같이 `held`** 여야 한다(그 경로는 이번 변경의 영향 밖이다).
# 나머지 (a)(b)(c)(d)(f)(h) 도 held 갈래를 만지지 않은 것과 무관해 전후 동일해야 한다.
mut4_pass=0
mut4_fail=0
check_mutation4() {
  local name="$1" mergeable="$2" bounce_file="$3" fc_json="$4" expect_pre="$5" expect_post="$6"
  local pre post ok=1
  pre=$(sweep_decide_pre_c "$mergeable" "$bounce_file" "$fc_json" "$now_epoch" "$head_at")
  post=$(sweep_decide "$mergeable" "$bounce_file" "$fc_json" "$now_epoch" "$head_at")
  [ "$pre" = "$expect_pre" ] || { ok=0; echo "  ✗ 뮤테이션 대조4 $name — (c) 이전 기대=$expect_pre 실제=$pre"; }
  [ "$post" = "$expect_post" ] || { ok=0; echo "  ✗ 뮤테이션 대조4 $name — (c) 이후 기대=$expect_post 실제=$post"; }
  if [ "$ok" = 1 ]; then mut4_pass=$((mut4_pass + 1)); else mut4_fail=$((mut4_fail + 1)); fi
}
# 되돌리면 빨개지는 쪽: (g) 만 (c) 이전=held(되붙임) / (c) 이후=active(무접촉)로 갈린다.
check_mutation4 "(g)→(c) 를 되돌리면 사람이 푼 홀드가 되붙는다(held→active)" \
  MERGEABLE "$tmp/marker_then_held.json" "$marker_then_held_comments" held active
# 반대편(새 판정 경로)은 여전히 초록: (e) 는 반송 마커가 없어 이 게이트 밖 —
# finish-classify 자신의 held 승격이 (c) 전후로 그대로 산다.
check_mutation4 "(e)→새 판정(반송 마커 없는 ⚠) 은 (c) 전후 그대로 held" \
  MERGEABLE "$tmp/held_ok.json" "$held_ok_comments" held held
# 대조군 — held 갈래를 만지지 않은 나머지는 (c) 전후 동일해야 한다.
check_mutation4 "(a)→(c) 전후 무회귀(active)" \
  MERGEABLE "$tmp/bounced.json" "$stale_reverify_comments" active active
check_mutation4 "(b)→(c) 전후 무회귀(stale_reverify)" \
  MERGEABLE "$tmp/ok.json" "$no_bounce_comments" stale_reverify stale_reverify
check_mutation4 "(c)→(c) 전후 무회귀(active)" \
  MERGEABLE "$tmp/does-not-exist.json" "$stale_reverify_comments" active active
check_mutation4 "(d)→(c) 전후 무회귀(adopt_conflict)" \
  CONFLICTING "$tmp/ok.json" "$no_bounce_comments" adopt_conflict adopt_conflict
check_mutation4 "(f)→(c) 전후 무회귀(active)" \
  MERGEABLE "$tmp/held_bounced.json" "$held_bounced_comments" active active
check_mutation4 "(h)→(c) 전후 무회귀(active, 🔄 해제 경로는 그대로)" \
  MERGEABLE "$tmp/human_released.json" "$human_released_then_resumed" active active

if [ "$mut4_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증4: (c) 를 되돌리면 (g) 만 실제로 되붙고(mut4_pass=$mut4_pass), 새 판정 경로 (e) 는 그대로 초록이다"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증4 실패 — 대조군이 어긋났다(mut4_pass=$mut4_pass mut4_fail=$mut4_fail)"
fi

echo "closeout-sweep-gate.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
