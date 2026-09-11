#!/usr/bin/env bash
# closeout-sweep-gate.test.sh — ①-b 스윕 판정 픽스처 6종 (#218).
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

# ── 새 규칙(#218 attempt 2) — SKILL.md ①-b 1)·2) 절을 그대로 거울 재현 ───────
#   bounce == held           → held(needs-human, mergeable·finish-classify 안 본다)
#   bounce != ok(그 외)        → active(무접촉), mergeable 도 finish-classify 도 안 본다
#   bounce == ok, CONFLICTING → adopt_conflict(입양)
#   bounce == ok, 그 외        → finish-classify 결과를 그대로 조치로 사용
sweep_decide() {
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
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}

# ── attempt-1 규칙(#218 첫 회차 — 이번 회차가 고치는 codex BLOCKER) ──────────
# bounce-state.sh 는 이제 held 를 3치로 내지만, attempt-1 코드는 그걸 몰랐다 —
# `bounced`/`held` 를 구분 없이 한 방향(무접촉)으로만 받았다. 여기서는 bounce-state.sh
# 를 되돌리지 않고, **호출자가 held 를 bounced 로 접어 읽던** 그 시절 판정 분기를
# 그대로 재현해 뮤테이션 대조에 쓴다(아래).
sweep_decide_attempt1() {
  local mergeable="$1" bounce_file="$2" fc_json="$3" fc_now="$4" fc_head_at="$5"
  local bstate rc=0
  bstate=$(BOUNCE_COMMENTS_FILE="$bounce_file" bash "$DIR/bounce-state.sh" owner/repo 9 2>/dev/null) || rc=$?
  [ "$bstate" = "held" ] && bstate="bounced"   # attempt-1 은 held 를 모른다
  if [ "$rc" != 0 ] || [ "$bstate" != "ok" ]; then
    echo "active"
    return
  fi
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "adopt_conflict"
    return
  fi
  FC_COMMENTS_JSON="$fc_json" FC_NOW="$fc_now" FC_HEAD_AT="$fc_head_at" \
    bash "$DIR/finish-classify.sh" owner/repo 9 2>/dev/null
}

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

# ── #218 attempt 2 픽스처 — codex BLOCKER 가 지적한 진짜 구멍 ──────────────
# (g): **반송 마커 → 그 뒤 ⚠ 보류**(순서가 (f) 의 역방향). 재검증 실패로 반송된
#     PR 에 교체 워커가 새로 붙어 "사람이 판단해야 한다" 고 명시적으로 올린 경우 —
#     이게 이번 회차가 닫는 진짜 구멍(ⓑ)이다. attempt 1 은 bounced 에서 무조건
#     조기 종료해 이 held 신호를 영원히 놓쳤다(codex: "a later ⚠ verdict never
#     becomes held"). 실측 재현: PR #225 검증자 리뷰(2026-09-11 00:50 UTC).
marker_then_held_comments='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:30:00Z"},
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 반송 게이트 갈래 확정 필요\n<!-- bodat:worker -->","createdAt":"2026-09-11T02:00:00Z"}
]'
printf '%s' "$marker_then_held_comments" > "$tmp/marker_then_held.json"

run "(g) MERGEABLE·반송 마커 뒤 새 ⚠ 보류→held(needs-human, #218 attempt 2)" sweep_decide \
  MERGEABLE "$tmp/marker_then_held.json" "$marker_then_held_comments" "$now_epoch" "$head_at" held

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

# ── 뮤테이션 방증 2 — (g) 를 attempt-1 규칙으로 되돌리면 빨개진다 (#218 attempt 2) ──
# `sweep_decide_attempt1` 은 bounce-state.sh 가 3치(ok/bounced/held)를 내도 held 를
# bounced 로 접어 무조건 무접촉 처리하던 이번 회차 이전 판정이다. (g) 를 그 규칙으로
# 재면 needs-human 승격이 빠져 `active` 로 나와야 한다 — 이게 이번 회차가 고친
# codex BLOCKER 의 실측 재현이다. (a)·(b)·(c)·(d)·(e)·(f) 는 attempt-1 규칙과 새
# 규칙이 같은 값을 내야 한다(held 갈래를 새로 여는 것 말고는 손대지 않았다는 대조군).
mut2_pass=0
mut2_fail=0
check_mutation2() {
  local name="$1" mergeable="$2" bounce_file="$3" fc_json="$4" expect_old="$5"
  local out
  out=$(sweep_decide_attempt1 "$mergeable" "$bounce_file" "$fc_json" "$now_epoch" "$head_at")
  if [ "$out" = "$expect_old" ]; then
    mut2_pass=$((mut2_pass + 1))
  else
    mut2_fail=$((mut2_fail + 1))
    echo "  ✗ 뮤테이션 대조2 $name — attempt-1 규칙 기대=$expect_old 실제=$out"
  fi
}
check_mutation2 "(g)→attempt-1 규칙에서 오분류(active, held 를 놓침)" \
  MERGEABLE "$tmp/marker_then_held.json" "$marker_then_held_comments" active
# 대조군 — held 갈래를 새로 연 것 말고는 attempt-1 과 다르지 않다.
check_mutation2 "(a)→attempt-1 규칙에서도 무회귀(active)" \
  MERGEABLE "$tmp/bounced.json" "$stale_reverify_comments" active
check_mutation2 "(b)→attempt-1 규칙에서도 무회귀(stale_reverify)" \
  MERGEABLE "$tmp/ok.json" "$no_bounce_comments" stale_reverify
check_mutation2 "(c)→attempt-1 규칙에서도 무회귀(active)" \
  MERGEABLE "$tmp/does-not-exist.json" "$stale_reverify_comments" active
check_mutation2 "(d)→attempt-1 규칙에서도 무회귀(adopt_conflict)" \
  CONFLICTING "$tmp/ok.json" "$no_bounce_comments" adopt_conflict
check_mutation2 "(e)→attempt-1 규칙에서도 무회귀(held)" \
  MERGEABLE "$tmp/held_ok.json" "$held_ok_comments" held
check_mutation2 "(f)→attempt-1 규칙에서도 무회귀(active)" \
  MERGEABLE "$tmp/held_bounced.json" "$held_bounced_comments" active

if [ "$mut2_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증2: attempt-1 규칙으로 되돌리면 (g) 가 실제로 오분류된다(mut2_pass=$mut2_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증2 실패 — 대조군이 어긋났다(mut2_pass=$mut2_pass mut2_fail=$mut2_fail)"
fi

echo "closeout-sweep-gate.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
