#!/usr/bin/env bash
# finish-classify.sh 픽스처 테스트 — 네트워크 무접속(모든 입력을 env 로 주입).
# 5개 분류(done_verdict·held·stale_inline·stale_reverify·active) + 시간버퍼 경계
# + 재리뷰(마지막 매칭) 케이스를 결정적으로 검증한다. bats 미도입 레포라
# bin/ci 인라인 스모크(repo-dir.sh)와 동일한 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/finish-classify.sh"

# 고정 NOW = 2026-07-05T12:00:00Z (BSD/GNU date 양쪽 파싱).
NOW=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-05T12:00:00Z" +%s 2>/dev/null \
  || date -u -d "2026-07-05T12:00:00Z" +%s)

pass=0
fail=0
# assert <name> <expected> <comments-json> [head_at] [hold_released_at]
# head_at 미지정 시 FC_HEAD_AT="" 로 명시 고정 — 실호출(gh) 경로로 새지 않게(네트워크 무접속 유지).
# hold_released_at 도 같은 이유로 항상 명시한다(미지정 = 해제 이벤트 못 얻음, #174).
assert() {
  local name="$1" expect="$2" comments="$3" head_at="${4:-}" hold_at="${5:-}"
  local got
  got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
    FC_COMMENTS_JSON="$comments" FC_HEAD_AT="$head_at" \
    FC_HOLD_RELEASED_AT="$hold_at" "$SUT" owner/repo 1 2>/dev/null)
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$expect 실제=$got"
  fi
}

# 1) done_verdict — 최신 머지 판정이 ✅ (+ head 커밋 시각을 얻어 판정이 그 뒤임을 증명)
assert "done_verdict" done_verdict '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "2026-07-05T10:55:00Z"

# ── #171: ✅ 를 head SHA 와 묶는다 ──────────────────────────────────────

# 1b) ✅ 가 head 커밋보다 **이름** — 반송 뒤 재디스패치된 새 커밋(11:10)이 아직
#     검증 안 된 채 그 이전(11:02)에 찍힌 ✅ 가 남아있는 형상 → active(무접촉,
#     워커가 새 판정을 찍을 때까지 done_verdict 를 내지 않는다).
assert "✅가head보다이름→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "2026-07-05T11:10:00Z"

# 1c) ✅ 가 head 커밋보다 **늦음** — 정상 형상(커밋 뒤 판정) → done_verdict(무회귀).
assert "✅가head보다늦음→done_verdict(무회귀)" done_verdict '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "2026-07-05T11:00:00Z"

# 1d) 초인 경계 — 커밋 시각과 판정 시각이 정확히 같음 → "이르다"가 아니므로 done_verdict.
assert "✅와head동일초→done_verdict(경계)" done_verdict '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "2026-07-05T11:02:00Z"

# ── #171(반송 회차): 증명되지 않으면 게이트를 열지 않는다 ────────────────
# 아래 셋은 전부 "두 시각 중 하나를 못 얻은" 형상이다. 옛 구현은 못 얻은 값을 epoch 0
# 으로 뭉개 `0 -gt ve` 가 거짓 → done_verdict 를 냈다(= 머지 게이트를 증명 없이 열었다).

# 1e) head 커밋 시각 조회 실패(빈 commits·gh 실패) → active.
assert "head시각못얻음→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' ""

# 1f) head 커밋 시각 파싱 실패(쓰레기 값) → active.
assert "head시각파싱실패→active" active '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "not-a-real-timestamp"

# 1g) 판정 시각 파싱 실패(코멘트 createdAt 이 깨짐) → active. head 는 유효한데도
#     "판정이 head 이후" 를 증명 못 하므로 통과시키지 않는다.
assert "판정시각파싱실패→active" active '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"garbage"}
]' "2026-07-05T10:55:00Z"

# 2) held — 최신 머지 판정이 ⚠ 보류
assert "held" held '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 미해결 남음\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:05:00Z"}
]'

# 3) stale_inline — 🔄 + 검증자 CLEAN + 30분 초과(검증자 59.5분 전)
assert "stale_inline" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# 3b) stale_inline — 워커 실제 표기 "BLOCKER 없음(게이트 통과)" = 블로커 0 = CLEAN
#     (회귀 가드 #970: "없음"의 BLOCKER 부분매칭으로 검증된 PR 을 stale_reverify 로 오판하던 버그)
assert "BLOCKER없음→stale_inline" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 없음(게이트 통과) · WARN 1 · NIT 3.\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# 4) stale_reverify — 🔄 + 검증자 부재 + 30분 초과(판정 60분 전)
assert "stale_reverify(부재)" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}
]'

# 5) active — 🔄 + 검증자 CLEAN + 30분 미만(검증자 9.5분 전)
assert "active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:50:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:50:30Z"}
]'

# 6a) 시간버퍼 경계 — 검증자 CLEAN·29분 전 → active(무접촉)
assert "boundary<30→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:31:00Z"}
]'

# 6b) 시간버퍼 경계 — 검증자 CLEAN·31분 전 → stale_inline
assert "boundary>30→stale_inline" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:29:00Z"}
]'

# 7) 재리뷰 — 검증자 리뷰(BLOCKER) 뒤에 검증자 리뷰(재리뷰): CLEAN.
#    마지막 매칭(재리뷰 CLEAN)으로 판정 → stale_inline (첫 BLOCKER 로 보면 stale_reverify)
assert "재리뷰-마지막매칭" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건 발견\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:10Z"},
  {"body":"검증자 리뷰(재리뷰): CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:20Z"}
]'

# 8) 재리뷰 역케이스 — CLEAN 뒤에 재리뷰 BLOCKER(미해소) → stale_reverify(마지막이 non-CLEAN)
assert "재리뷰-BLOCKER복귀" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:10Z"},
  {"body":"검증자 리뷰(재리뷰): BLOCKER 2건 미해소\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:20Z"}
]'

# 9) 영문 코멘트 어휘도 인식 (한/영 병행 워커)
assert "english-done" done_verdict '[
  {"body":"Merge verdict: 🔄 in progress","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"Merge verdict: ✅ mergeable\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]' "2026-07-05T10:55:00Z"

# 10) 판정 코멘트 자체가 없음(너무 이른 단계) → active(우리 형상 아님, 무접촉)
assert "no-verdict→active" active '[
  {"body":"그냥 사람 코멘트","createdAt":"2026-07-05T11:00:00Z"}
]'

# 11) 부정문 오탐 방지 — "아직 CLEAN 아님"은 *CLEAN* 부분매칭이지만 non-clean 이어야
#     한다 → 30분 초과라도 stale_inline(인라인 ✅) 아니라 stale_reverify(재디스패치).
assert "CLEAN아님→non-clean" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: 아직 CLEAN 아님 — BLOCKER 1건 남음\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# 12) 스테일 클록 = 최신 워커 활동 — 검증자 CLEAN(60분 전) 뒤 재-🔄(5분 전)면
#     살아있는 워커다 → verdict_at(최신)로 age 재어 active(무접촉).
assert "재-🔄후→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"},
  {"body":"머지 판정: 🔄 다시 수정 중","createdAt":"2026-07-05T11:55:00Z"}
]'

# 13) CI 실패 방어 가드 — 🔄 + 검증자 CLEAN + 30분 초과라도 failing>0 이면 active
#     (규칙1 대상, 완결 판별 안 함).
got_ci=$(FC_NOW="$NOW" FC_FAILING=2 STALE_FINISH_MIN=30 FC_HEAD_AT="" \
  FC_COMMENTS_JSON='[
    {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
    {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
  ]' "$SUT" owner/repo 1 2>/dev/null)
if [ "$got_ci" = active ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  ✗ failing>0→active — 기대=active 실제=$got_ci"; fi

# 14) 검증자 non-CLEAN·버퍼 미만(9.5분 전) → active(아직-수정중, 무접촉)
assert "non-clean·recent→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:50:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건 미해소\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:50:30Z"}
]'

# 15) 영문 검증자 접두(Verifier review:)도 CLEAN 인식 → stale_inline
assert "english-verifier-clean" stale_inline '[
  {"body":"Merge verdict: 🔄 in progress","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"Verifier review: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# 16) 혼합대소문자 부정문 + BLOCKER 언급 → BLOCKER 게이트가 non-clean 으로 잡는다
#     ("not CLEAN yet, BLOCKER remains" 는 부정 denylist 를 못 걸러도 BLOCKER 게이트가 방어).
assert "mixedcase-not-clean→reverify" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: this is not CLEAN yet, BLOCKER remains\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# 17) 정상 해소 표기(BLOCKER 0)는 BLOCKER 게이트를 통과해 clean → stale_inline
assert "blocker0-resolved→clean" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 0 / WARN 2건 해소\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:00:30Z"}
]'

# ── #110 커밋 신선도 합류 ──────────────────────────────────────────────

# 18) 실증 회귀 — 판정 🔄(36분 전) + 검증자 부재 + FC_HEAD_AT(2분 전) → active
#     (현행/미구현 시 stale_reverify — 실증 BodaT PR #2237 재현).
assert "실증회귀·커밋신선→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:24:00Z"}
]' "2026-07-05T11:58:00Z"

# 19) 같은 입력에서 FC_HEAD_AT(40분 전) → stale_reverify (진짜 사망은 여전히 잡힌다).
assert "커밋도스테일→stale_reverify" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:24:00Z"}
]' "2026-07-05T11:20:00Z"

# 20) 검증자 CLEAN(40분 전) + FC_HEAD_AT(2분 전) → active (stale_inline 억제 — 살아있는
#     워커를 인라인 대리 판정이 덮치면 안 된다).
assert "CLEAN후커밋신선→active(억제)" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:20:00Z"}
]' "2026-07-05T11:58:00Z"

# 21) 검증자 CLEAN(40분 전) + FC_HEAD_AT(40분 전, 역시 스테일) → stale_inline (무회귀).
assert "CLEAN+커밋둘다스테일→stale_inline" stale_inline '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:20:00Z"}
]' "2026-07-05T11:20:00Z"

# 22) FC_HEAD_AT 파싱 불가 쓰레기 값 → 크래시 없이 빈 epoch 취급, 기존 판정(stale_reverify) 유지.
assert "커밋쓰레기값→기존판정유지" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}
]' "not-a-real-timestamp"

# 23a) 검증자 부재 분기의 커밋 신호 버퍼 경계 — 정확히 30분 전 → active(무접촉).
assert "커밋경계=30→active" active '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}
]' "2026-07-05T11:30:00Z"

# 23b) 31분 전(초과) → stale_reverify.
assert "커밋경계>30→stale_reverify" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}
]' "2026-07-05T11:29:00Z"

# 24) FC_HEAD_AT 미설정(기존 6개 케이스 대표 재확인) — 판정 4~17 은 이미 head_at 없이
#     돌아 불변을 증명하지만, 검증자 부재 분기(4)를 명시적으로 한 번 더 고정한다.
assert "head미설정·검증자부재분기·불변" stale_reverify '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}
]'

# 25) 실 수집 경로 — FC_HEAD_AT 미설정 시 head 시각을 어떤 호출로 얻는지 고정한다.
#     위 18~24 는 전부 FC_HEAD_AT 주입 경로라, 수집 호출이 깨져도 head_at 이 조용히 빈
#     값으로 degrade 되며 통과한다 — 이번 PR 핵심 수정이 실환경에서만 죽는 사각지대.
#     스텁 gh 로 인자를 캡처해 그 계약을 검증한다(네트워크 무접속 유지 — PATH 에 스텁을
#     앞세울 뿐 실제 gh 는 안 부른다).
#     계약은 반송 4회차 [P1-1] 로 바뀌었다: 커밋 목록(`--json commits`, 상한 100)이 아니라
#     **head SHA 직접 조회 + 그 커밋 하나 조회**다(scripts/pr-head-at.sh).
stub=$(mktemp -d)
cat > "$stub/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_CAPTURE"
# 실제 gh 와 같은 계약: headRefOid 로 head SHA 를, 그 SHA 의 커밋 조회로 시각을 준다.
case "$*" in
  *"pr view"*"--json headRefOid"*) echo '{"headRefOid":"abc123def0"}' ;;
  *"repos/owner/repo/commits/abc123def0"*)
    [ -n "${STUB_HEAD_AT:-}" ] || exit 1
    printf '{"commit":{"committer":{"date":"%s"}}}\n' "$STUB_HEAD_AT" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$stub/gh"
capture="$stub/capture"

# (a) head 커밋이 신선하면(2분 전) 판정 코멘트가 스테일(60분 전)이어도 active —
#     실 수집 경로로 커밋 신선도가 실제로 합류하는지 end-to-end 로 본다.
got=$(PATH="$stub:$PATH" STUB_CAPTURE="$capture" STUB_HEAD_AT="2026-07-05T11:58:00Z" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_JSON='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}]' \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = active ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 실수집경로·커밋신선→active — 기대=active 실제=$got"
fi
# (b) 그 호출이 실제로 headRefOid + 그 SHA 커밋 조회였는지 (인자 계약 — [P1-1]).
#     `--json commits` 로 되돌리면 여기서 곧바로 빨개진다.
if grep -q -- '--json headRefOid' "$capture" && grep -q 'commits/abc123def0' "$capture"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 실수집경로 인자 계약 — gh 호출에 '--json headRefOid'/commits/<sha> 없음:"
  sed 's/^/      /' "$capture"
fi
# (c) 같은 실 경로에서 head 커밋도 스테일(40분 전)이면 stale_reverify (가드가 게이트를
#     무력화하지 않는다 — 신선도 합류가 항상-active 로 새지 않음).
: > "$capture"
got=$(PATH="$stub:$PATH" STUB_CAPTURE="$capture" STUB_HEAD_AT="2026-07-05T11:20:00Z" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_JSON='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}]' \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = stale_reverify ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 실수집경로·커밋스테일→stale_reverify — 기대=stale_reverify 실제=$got"
fi
# (d) gh 가 빈 값을 주는 경우(권한·네트워크 실패 등) → 기존 판정으로 degrade, 크래시 없음.
: > "$capture"
got=$(PATH="$stub:$PATH" STUB_CAPTURE="$capture" STUB_HEAD_AT="" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_JSON='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}]' \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = stale_reverify ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 실수집경로·gh빈값→기존판정 — 기대=stale_reverify 실제=$got"
fi
rm -rf "$stub"

# ── #171(반송 3회차) [P1-1]: 날짜 파싱이 BSD·GNU 두 구현에서 같아야 한다 ──────
# `iso_to_epoch` 는 BSD(`date -j -f`) 실패 시 GNU(`date -d`) 로 폴백한다. 그 폴백이
# 있다는 것 자체가 GNU 박스를 지원 대상으로 삼았다는 뜻인데, 두 구현은 **잘못된
# 입력**에서 갈린다:
#   BSD: `date -u -j -f ... "" +%s` → illegal time format, 실패(빈 값) → active
#   GNU: `date -u -d "" +%s`        → **실패하지 않고 오늘 자정 epoch**
# 형식 검사가 없으면 GNU 박스에서 head 조회가 비었는데도 head_epoch 가 비지 않고,
# 자정 이후 찍힌 정상 ✅ 이면 `head <= verdict` 가 참이 돼 done_verdict — 이 PR 이
# 없애려던 fail-open 이 GNU 에서만 되살아난다. 실 GNU 박스가 없으므로 스텁 date 로
# 그 동작을 재현한다.
gnu=$(mktemp -d)
cat > "$gnu/date" <<'STUB'
#!/bin/sh
# GNU coreutils date 흉내 (BSD 맥에서 GNU 박스 동작 재현):
#   · `-j -f` 는 GNU 에 없는 옵션 → 실패(= BSD 우선 시도가 떨어져 폴백을 탄다)
#   · `-d ""` 는 실패하지 않고 **오늘 자정**(고정: $GNU_MIDNIGHT)
#   · `-d yesterday` 같은 느슨한 표현도 파싱한다(ISO 아닌 값이 통과하는 실증)
#   · 정상 ISO8601 은 그대로 epoch (실 date 에 위임 — BSD/GNU 어느 쪽이든)
case "$*" in
  *" -j "*) echo "date: invalid option -- 'j'" >&2; exit 1 ;;
esac
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "-d" ]; then
  case "${3:-}" in
    "")        echo "$GNU_MIDNIGHT"; exit 0 ;;
    yesterday) echo $((GNU_MIDNIGHT - 86400)); exit 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      /bin/date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$3" +%s 2>/dev/null && exit 0
      /bin/date -u -d "$3" +%s 2>/dev/null && exit 0
      exit 1 ;;
    *) echo "date: invalid date '${3:-}'" >&2; exit 1 ;;
  esac
fi
exec /bin/date "$@"
STUB
chmod +x "$gnu/date"
GNU_MIDNIGHT=$((NOW - 12 * 3600))   # NOW=12:00Z 이므로 같은 날 00:00Z

# assert_gnu <name> <expected> <comments-json> <head_at> — GNU 스텁 date 로 같은 판정.
assert_gnu() {
  local name="$1" expect="$2" comments="$3" head_at="$4" got
  got=$(PATH="$gnu:$PATH" GNU_MIDNIGHT="$GNU_MIDNIGHT" \
    FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
    FC_COMMENTS_JSON="$comments" FC_HEAD_AT="$head_at" "$SUT" owner/repo 1 2>/dev/null)
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [GNU] $name — 기대=$expect 실제=$got"
  fi
}

verdict_after_midnight='[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]'

# G1) 스텁 자체가 GNU 를 재현하는지 먼저 고정한다 — `-d ""` 가 **실패하지 않고** 자정을
#     준다는 전제가 깨지면 아래 G2 는 아무것도 안 재는 빈 테스트가 된다.
got=$(PATH="$gnu:$PATH" GNU_MIDNIGHT="$GNU_MIDNIGHT" date -u -d "" +%s 2>/dev/null)
if [ "$got" = "$GNU_MIDNIGHT" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [GNU] 스텁 전제(-d \"\" → 오늘 자정) — 실제='$got'"
fi

# G2) **핵심 회귀** — head 시각을 못 얻었는데(빈 문자열) ✅ 는 자정 이후(11:02).
#     형식 검사가 없으면 head_epoch=자정 ≤ verdict → done_verdict 로 게이트가 열린다.
#     뮤테이션: iso_to_epoch 의 case 형식 검사를 지우면 이 줄이 빨개진다.
assert_gnu "head시각못얻음(빈문자열)→active" active "$verdict_after_midnight" ""

# G3) GNU 가 파싱하지만 ISO8601 이 아닌 값(`yesterday`) → active.
#     빈 문자열만의 문제가 아니다 — GNU 는 느슨한 표현을 다 받는다.
assert_gnu "ISO아닌GNU표현(yesterday)→active" active "$verdict_after_midnight" "yesterday"

# G4) 두 구현 모두에서 실패하는 쓰레기 문자열 → active(동작 일치 확인).
assert_gnu "쓰레기문자열→active" active "$verdict_after_midnight" "not-a-real-timestamp"

# G5) 무회귀 — 정상 ISO8601 은 GNU 에서도 그대로 파싱돼 done_verdict.
#     (형식 검사가 정상 경로를 막지 않는다.)
assert_gnu "정상ISO→done_verdict(무회귀)" done_verdict "$verdict_after_midnight" "2026-07-05T10:55:00Z"

# G6) 대칭 확인 — 같은 입력을 **BSD(이 박스 실 date)** 로 돌려도 판정이 같다.
#     이 네 줄이 위 G2~G5 와 짝을 이뤄 "두 구현에서 같게 동작한다" 를 실증한다.
assert "BSD·head시각못얻음→active" active "$verdict_after_midnight" ""
assert "BSD·ISO아닌표현(yesterday)→active" active "$verdict_after_midnight" "yesterday"
assert "BSD·쓰레기문자열→active" active "$verdict_after_midnight" "not-a-real-timestamp"
assert "BSD·정상ISO→done_verdict" done_verdict "$verdict_after_midnight" "2026-07-05T10:55:00Z"

rm -rf "$gnu"

# ── #171(반송 3회차) [P1-2]: 코멘트 100건 상한을 넘겨 읽는다 ─────────────────
# `gh pr view --json comments` 는 페이지네이션 없이 첫 100건만 준다 — 이 레포가 이미
# 아는 함정(scripts/tests/loop-status.test.sh:267 이 `range(0;100)` 픽스처로 같은 경계를
# 잰다). 반송을 여러 번 도는 PR 은 코멘트가 100건을 쉽게 넘고, 그때 **새 커밋 + 새 ✅**
# 가 101번째 이후면 분류기는 첫 100건의 낡은 ✅ 만 보고 active 를 유지한다 →
# 머지 가능한 PR 이 영영 후보에 안 뜬다(조용한 큐 사망). 스텁 gh 는 실 gh 처럼 두
# 경로를 **다르게** 응답한다: `pr view --json comments` 는 첫 100건만,
# `api .../issues/N/comments --paginate` 는 전량(+ 넘겨받은 --jq 를 그대로 적용).
pg=$(mktemp -d)
# 122건: [0]=낡은 ✅(09:00) · [1..120]=잡담 · [121]=새 ✅(11:30). head 커밋은 11:00.
#   전량 조회 → 최신 ✅=11:30 ≥ head=11:00 → done_verdict
#   첫 100건만  → 최신 ✅=09:00 <  head=11:00 → active (증명 실패)
jq -n '
  [ {body:"머지 판정: ✅ 머지 가능(구판정)\n<!-- bodat:worker -->", created_at:"2026-07-05T09:00:00Z"} ]
  + [ range(0;120) | {body:("검증자 리뷰: 진행 메모 \(.)\n<!-- bodat:worker -->"), created_at:"2026-07-05T10:00:00Z"} ]
  + [ {body:"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->", created_at:"2026-07-05T11:30:00Z"} ]' \
  > "$pg/all.json"
cat > "$pg/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CAPTURE"
paginate=0; jqf='.'; prev=''
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf="$a"
  [ "$a" = "--paginate" ] && paginate=1
  prev="$a"
done
if [ "$paginate" = 1 ]; then
  # 실 gh: --jq 를 페이지마다 적용해 오브젝트를 줄줄이 낸다(상한 없음).
  jq -c "$jqf" < "$STUB_ALL"
  exit 0
fi
case "$*" in
  # 실 gh 의 100건 상한 재현 — 옛 경로로 되돌리면 여기 걸려 판정이 뒤집힌다.
  *"pr view"*"--json comments"*)
    jq -c '[.[0:100][] | {body: .body, createdAt: .created_at}]' < "$STUB_ALL" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$pg/gh"
pgcap="$pg/capture"; : > "$pgcap"

# (a) 전량을 읽어야 최신 ✅(101번째 이후)를 본다 → done_verdict.
#     뮤테이션: 조회를 `gh pr view --json comments` 로 되돌리면 active 로 빨개진다.
got=$(PATH="$pg:$PATH" STUB_CAPTURE="$pgcap" STUB_ALL="$pg/all.json" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 FC_HEAD_AT="2026-07-05T11:00:00Z" \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = done_verdict ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 코멘트100건초과·새✅가101번째이후 — 기대=done_verdict 실제=$got"
fi
# (b) 그 조회가 실제로 페이지네이션 경로였는지 (인자 계약 — 25(b) 와 같은 취지).
if grep -q -- '--paginate' "$pgcap" && grep -q 'issues/1/comments' "$pgcap"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 코멘트 조회 인자 계약 — '--paginate'/issues/1/comments 없음:"
  sed 's/^/      /' "$pgcap"
fi
# (c) 조회 실패(gh 비정상 종료)는 빈 결과와 구분해 fail-closed → active.
#     부분 출력을 정상값으로 채택하면 "뒤쪽 코멘트가 없다" 로 읽혀 가드가 우회된다.
cat > "$pg/gh" <<'STUB'
#!/usr/bin/env bash
# --paginate 중간 페이지 실패: 부분 출력을 내고 비정상 종료(실 gh 동작).
printf '%s\n' '{"body":"머지 판정: ✅ 머지 가능","createdAt":"2026-07-05T11:30:00Z"}'
exit 1
STUB
chmod +x "$pg/gh"
got=$(PATH="$pg:$PATH" STUB_CAPTURE="$pgcap" STUB_ALL="$pg/all.json" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 FC_HEAD_AT="2026-07-05T11:00:00Z" \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = active ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 코멘트 조회 부분실패→fail-closed — 기대=active 실제=$got"
fi
rm -rf "$pg"

# ── #171(반송 4회차) [P1-1]: 커밋도 100건 상한을 넘겨 읽는다 ────────────────────
# `gh pr view --json commits` 는 GraphQL `commits(first: 100)` 이라 **첫 100건만** 준다.
# 그때 `.commits | last` 는 head 가 아니라 **100번째 커밋**이고 그 시각은 head 보다 이르다
# → 낡은 ✅ 가 그보다 늦어 보여 `head <= verdict` 가 참이 되고 done_verdict 가 난다.
# 코멘트 100건 상한(위 절)과 **완전히 같은 함정**이 커밋 쪽에 남아 있던 것이다.
# 스텁 gh 는 실 gh 처럼 세 경로를 **다르게** 응답한다:
#   `pr view --json commits -q committedDate` → 100번째 커밋 시각(상한에 갇힌 옛 경로)
#   `pr view --json headRefOid`               → 진짜 head SHA
#   `api repos/o/r/commits/<sha>`             → 그 head 커밋의 진짜 시각
hc=$(mktemp -d)
cat > "$hc/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CAPTURE"
case "$*" in
  # 옛 경로(상한 100) — 커밋이 101건 이상이면 head 가 아니라 100번째를 준다.
  *"--json commits"*) printf '%s\n' "$STUB_CAPPED_AT" ;;
  *"pr view"*"--json headRefOid"*)
    [ -n "${STUB_HEAD_SHA:-}" ] || exit 1
    printf '{"headRefOid":"%s"}\n' "$STUB_HEAD_SHA" ;;
  *"commits/"*)
    [ -n "${STUB_HEAD_AT:-}" ] || exit 1
    printf '{"commit":{"committer":{"date":"%s"}}}\n' "$STUB_HEAD_AT" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$hc/gh"
hccap="$hc/capture"

verdict_1102='[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]'

# run_hc <capped_at> <head_sha> <head_at> → FC_HEAD_AT 미주입(실 수집 경로) 판정
run_hc() {
  : > "$hccap"
  PATH="$hc:$PATH" STUB_CAPTURE="$hccap" \
    STUB_CAPPED_AT="$1" STUB_HEAD_SHA="$2" STUB_HEAD_AT="$3" \
    FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 FC_COMMENTS_JSON="$verdict_1102" \
    "$SUT" owner/repo 1 2>/dev/null
}
check_hc() {  # <name> <expected> <got>
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ $1 — 기대=$2 실제=$3"
  fi
}

# H1) **핵심 뮤테이션 대상** — 커밋 101건 이상: 100번째(10:00)는 ✅(11:02)보다 이르지만
#     진짜 head(11:10)는 ✅ 보다 늦다 → 증명 실패이므로 active.
#     뮤테이션: head 조회를 `gh pr view --json commits | last` 로 되돌리면 head=10:00 이
#     되어 `head <= verdict` 가 참 → done_verdict 로 빨개진다(= fail-open 재현).
check_hc "커밋100건상한·진짜head가✅보다늦음→active" active \
  "$(run_hc "2026-07-05T10:00:00Z" "abc123def0" "2026-07-05T11:10:00Z")"

# H2) 무회귀 — 진짜 head(10:55)가 ✅(11:02)보다 이르면 종전대로 done_verdict.
check_hc "진짜head가✅보다이름→done_verdict(무회귀)" done_verdict \
  "$(run_hc "2026-07-05T10:00:00Z" "abc123def0" "2026-07-05T10:55:00Z")"

# H3) head SHA 조회 실패 → active(fail-closed). 상한에 갇힌 커밋 목록(10:00)이 살아 있어도
#     그걸 대체값으로 주워 쓰지 않는다.
check_hc "headSHA조회실패→active" active \
  "$(run_hc "2026-07-05T10:00:00Z" "" "2026-07-05T11:10:00Z")"

# H4) head SHA 는 얻었는데 커밋 조회가 실패 → active(fail-closed).
check_hc "head커밋조회실패→active" active \
  "$(run_hc "2026-07-05T10:00:00Z" "abc123def0" "")"

# H5) 인자 계약 — 실제로 headRefOid + 그 SHA 커밋을 물었는지(상한 경로가 아니라).
run_hc "2026-07-05T10:00:00Z" "abc123def0" "2026-07-05T11:10:00Z" >/dev/null
if grep -q -- '--json headRefOid' "$hccap" && grep -q 'commits/abc123def0' "$hccap"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ [P1-1] head 수집 인자 계약 — headRefOid/commits/<sha> 호출 없음:"
  sed 's/^/      /' "$hccap"
fi
rm -rf "$hc"

# ── #171(반송 4회차) [P2]: 코멘트를 파일로 넘기는 계약 ──────────────────────────
# 코멘트 전량을 환경변수 하나(FC_COMMENTS_JSON)로 넘기면 exec 한계(리눅스
# MAX_ARG_STRLEN 128KB)를 넘는 순간 finish-classify 가 **시작조차 못 하고** 판정이 비어
# 그 PR 이 매 스윕에서 조용히 빠진다. 파일 경로로 넘기는 길을 둔다(FC_COMMENTS_FILE).
cf=$(mktemp -d)
printf '%s' "$verdict_1102" > "$cf/comments.json"
got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_FILE="$cf/comments.json" FC_HEAD_AT="2026-07-05T10:55:00Z" \
  "$SUT" owner/repo 1 2>/dev/null)
check_hc "FC_COMMENTS_FILE→done_verdict" done_verdict "$got"

# 파일이 없으면(경로 오류·삭제 경합) 실 조회로 새지 않고 fail-closed → active.
got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_FILE="$cf/does-not-exist.json" FC_HEAD_AT="2026-07-05T10:55:00Z" \
  "$SUT" owner/repo 1 2>/dev/null)
check_hc "FC_COMMENTS_FILE부재→active(fail-closed)" active "$got"

# 대용량(≈256KB)도 파일 경로로는 문제없이 판정된다 — env 로는 exec 한계에 걸리는 크기.
jq -n '
  [ range(0;600) | {body:("검증자 리뷰: 진행 메모 \(.) " + ("x" * 400) + "\n<!-- bodat:worker -->"),
                    createdAt:"2026-07-05T10:00:00Z"} ]
  + [ {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-07-05T11:02:00Z"} ]' \
  > "$cf/big.json"
got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_FILE="$cf/big.json" FC_HEAD_AT="2026-07-05T10:55:00Z" \
  "$SUT" owner/repo 1 2>/dev/null)
check_hc "FC_COMMENTS_FILE대용량→done_verdict" done_verdict "$got"
rm -rf "$cf"

# ── #174: 사람이 보류를 풀면 낡은 `마감 검증: ⚠ 보류` 를 최신 판정으로 세지 않는다 ──
#
# 형상(실측 BodaT PR #4922): `머지 판정: ✅` → `마감 검증: ⚠ 보류` → 사람이
# `needs-human`·`hold:*` 를 뗌. 그 해제 시각이 보류 코멘트보다 **뒤**면 보류는 해소된
# 것이고, 그 앞의 ✅ 가 살아나 종전 경로(#171 head SHA 대조)로 이어진다.
#
# 두 규칙의 **순서**가 계약이다: (1) 보류 해소 판정 → (2) #171 head 대조.
# 1 이 통과해도 2 가 막으면 active 다(아래 174c).
held_shape='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:10:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:11:00Z"},
  {"body":"마감 검증: ⚠ 보류 — 계획 부합 게이트 BLOCKER(P1 1건)\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:00:00Z"}
]'

# 174a) 해제 > 보류 — 사람이 판정을 내리고 라벨을 뗐다 → 보류 해소, ✅ 가 살아난다.
assert "해제>보류→done_verdict" done_verdict "$held_shape" "2026-07-05T09:05:00Z" "2026-07-05T10:30:00Z"

# 174b) 해제 < 보류 — 사람이 풀었다가 **다시 걸었다**(해제가 보류보다 이르다) → active.
#       (닫힌 게이트를 여는 방향은 "해제가 보류 뒤"임이 증명될 때뿐이다.)
#       판정이 `held` 가 아닌 이유: `held` 는 스윕에 closeout-blocked(= needs-human 부착)를
#       시켜, 사람이 방금 뗀 보류를 루프가 다시 붙이는 경로가 된다(#151). `active` 는
#       같은 방향(머지 안 함)이면서 부작용이 없다.
assert "해제<보류→active" active "$held_shape" "2026-07-05T09:05:00Z" "2026-07-05T08:00:00Z"

# 174c) 해제 뒤 **새 커밋** — 사람이 방향을 정해 주고 워커가 고치는 중(반송 레인).
#       보류는 해소됐지만 #171 규칙이 이어 걸려 active 다(closeout 이 집지 않고
#       워커의 새 판정을 기다린다). 두 규칙의 순서를 고정하는 케이스.
assert "해제후새커밋→active(#171우선)" active "$held_shape" "2026-07-05T10:40:00Z" "2026-07-05T10:30:00Z"

# 174d) **타임라인 조회 실패**(해제 시각을 못 얻음) → 종전 동작(보류 유지) 폴백 = active.
#       조회 실패를 "해제됨" 으로 읽으면 머지 게이트가 증명 없이 열린다(fail-closed).
assert "해제시각못얻음→active(fail-closed)" active "$held_shape" "2026-07-05T09:05:00Z" ""

# 174e) 해제 시각 **파싱 실패**(쓰레기 값) → 역시 통과 없음(active). 빈 값만의 문제가 아니다
#       (GNU date 는 느슨한 표현을 받아 그럴듯한 epoch 를 만든다 — iso_to_epoch 형식검사).
assert "해제시각파싱실패→active" active "$held_shape" "2026-07-05T09:05:00Z" "not-a-real-timestamp"

# 174f) 동초 경계 — 해제와 보류가 **같은 초**면 "뒤" 가 아니다 → active(fail-closed).
assert "해제와보류동초→active(경계)" active "$held_shape" "2026-07-05T09:05:00Z" "2026-07-05T10:00:00Z"

# 174g) **무회귀** — `마감 검증: ⚠ 보류` 가 최신 ✅ 보다 **앞**이면 그건 이미 지나간
#       보류다(반송 후 재완결 형상). 해제 이벤트가 없어도 done_verdict 여야 한다.
#       이 케이스가 없으면 "⚠ 가 있기만 하면 보류" 로 과잉 억제해 정상 재완결이 막힌다.
assert "보류가✅보다앞→done_verdict(무회귀)" done_verdict '[
  {"body":"마감 검증: ⚠ 보류 — BLOCKER 2건\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:34:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:50:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:55:00Z"}
]' "2026-07-05T07:45:00Z"

# 174h) **무회귀** — 최신 `마감 검증` 이 ✅ 면 보류가 아니다(해제 이벤트 없이 done_verdict).
assert "마감검증✅→done_verdict(무회귀)" done_verdict '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:11:00Z"},
  {"body":"마감 검증: ✅ CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:00:00Z"}
]' "2026-07-05T09:05:00Z"

# 174i) 영문 접두(Closeout verification) 도 같은 규칙 — 한/영 병행 루프 대비.
assert "english-closeout-hold→active" active '[
  {"body":"Merge verdict: ✅ mergeable\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:11:00Z"},
  {"body":"Closeout verification: ⚠ hold — BLOCKER 1\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:00:00Z"}
]' "2026-07-05T09:05:00Z" ""

# ── pr-hold-released-at.sh 계약 — 빈 결과와 실패를 구분한다 ──────────────────
# 이 헬퍼가 "실패했는데 빈 값" 을 내면 상류(finish-classify)가 그걸 '해제 이벤트 없음'
# 과 구분 못 한다. 둘 다 fail-closed(보류 유지)로 수렴하지만, 종료코드가 사유를 담아야
# 상류가 나중에 갈래를 나눌 수 있다(PR#168 교훈: 센티널 하나로 사유를 단정하지 마라).
HELPER="$DIR/pr-hold-released-at.sh"
hb=$(mktemp -d)
mk_gh() { cat > "$hb/gh"; chmod +x "$hb/gh"; }
run_helper() { PATH="$hb:$PATH" "$HELPER" owner/repo 1 2>/dev/null; }
check_h() {
  local name="$1" want_rc="$2" want_out="$3" got_rc=0 got_out
  got_out=$(run_helper) || got_rc=$?
  if [ "$got_rc" = "$want_rc" ] && [ "$got_out" = "$want_out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대 rc=$want_rc out='$want_out' / 실제 rc=$got_rc out='$got_out'"
  fi
}

# h1) gh 실패 → 아무것도 안 내고 exit 1 (부분 출력을 정상값으로 채택하지 않는다).
mk_gh <<'STUB'
#!/bin/sh
exit 1
STUB
check_h "helper: gh실패→rc1·무출력" 1 ""

# h2) 해제 이벤트 없음 → **정상**(exit 0) + 빈 출력. 실패와 구분된다.
mk_gh <<'STUB'
#!/bin/sh
exit 0
STUB
check_h "helper: 해제이벤트없음→rc0·무출력" 0 ""

# h3) `hold:policy`·`hold:conflict` 의 `unlabeled` 중 **가장 최근** 시각을 낸다.
#     (라벨 이벤트는 페이지네이션 대상이라 --paginate 로 전량을 읽어야 한다.)
mk_gh <<'STUB'
#!/bin/sh
jqf='.'; prev=''
for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
printf '%s' '[
  {"event":"labeled","label":{"name":"hold:policy"},"created_at":"2026-07-05T07:00:00Z"},
  {"event":"unlabeled","label":{"name":"hold:conflict"},"created_at":"2026-07-05T10:29:00Z"},
  {"event":"unlabeled","label":{"name":"hold:policy"},"created_at":"2026-07-05T10:30:00Z"},
  {"event":"unlabeled","label":{"name":"flow:verify"},"created_at":"2026-07-05T23:00:00Z"},
  {"event":"closed","created_at":"2026-07-05T23:30:00Z"}
]' | jq -r "$jqf"
STUB
check_h "helper: 최신 해제 시각(사람 몫 사유 라벨만)" 0 "2026-07-05T10:30:00Z"

# h3b) **핵심 회귀 가드** — `needs-human`·`hold:ladder` 의 제거는 **사람 신호가 아니다**.
#      `resume-sweep.sh:159,299` 가 사다리 자동 재개로 그 둘을 **기계가** 뗀다. 이걸 세면
#      기계 동작이 "사람이 결정했다" 는 증명으로 둔갑해 가려진 ✅ 가 되살아난다
#      (#174 「걸러선 안 되는 것」 1항의 거울상 fail-open). → 해제 이벤트 없음(rc0·무출력).
mk_gh <<'STUB'
#!/bin/sh
jqf='.'; prev=''
for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
printf '%s' '[
  {"event":"unlabeled","label":{"name":"needs-human"},"created_at":"2026-07-05T10:30:00Z"},
  {"event":"unlabeled","label":{"name":"hold:ladder"},"created_at":"2026-07-05T10:30:00Z"}
]' | jq -r "$jqf"
STUB
check_h "helper: 사다리 자동재개(needs-human·hold:ladder)는 해제 아님" 0 ""

# h4) 형식이 깨진 시각만 온다 → 유효한 해제 시각을 못 얻은 것 = exit 1(빈 출력).
mk_gh <<'STUB'
#!/bin/sh
jqf='.'; prev=''
for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
printf '%s' '[{"event":"unlabeled","label":{"name":"hold:policy"},"created_at":"garbage"}]' | jq -r "$jqf"
STUB
check_h "helper: 시각형식깨짐→rc1·무출력" 1 ""

# ── 실조회 배선 — FC_HOLD_RELEASED_AT 미지정 시 finish-classify 가 헬퍼를 실제로 부른다 ──
# 위 h1~h4 는 헬퍼 **단독** 계약이고, 아래 둘은 finish-classify → 헬퍼 **배선**을 문다.
# 이 배선이 끊기면(경로 오타·실행 비트 누락 → exit 126) 프로덕션에선 해제 시각이 항상
# 빈 값이라 사람이 푼 보류가 **영영** 안 풀리는데, env 를 항상 주입하는 다른 픽스처는
# 그걸 하나도 못 잰다. gh 를 PATH 스텁으로 갈아 네트워크 없이 끝까지 돌린다.
wired_shape='[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T09:11:00Z"},
  {"body":"마감 검증: ⚠ 보류 — P1 1건\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:00:00Z"}
]'
run_wired() {  # FC_HOLD_RELEASED_AT 를 **안** 넘긴다(실조회 갈래).
  PATH="$hb:$PATH" FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
    FC_COMMENTS_JSON="$wired_shape" FC_HEAD_AT="2026-07-05T09:05:00Z" \
    "$SUT" owner/repo 1 2>/dev/null
}
check_wired() {
  local name="$1" expect="$2" got
  got=$(run_wired)
  if [ "$got" = "$expect" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ $name — 기대=$expect 실제=$got"; fi
}

# w1) 헬퍼가 보류보다 늦은 해제 시각을 내면 → done_verdict (배선이 살아 있다).
mk_gh <<'STUB'
#!/bin/sh
jqf='.'; prev=''
for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
printf '%s' '[{"event":"unlabeled","label":{"name":"hold:policy"},"created_at":"2026-07-05T10:30:00Z"}]' | jq -r "$jqf"
STUB
check_wired "실조회 배선: 해제 읽힘→done_verdict" done_verdict

# w2) 같은 배선에서 gh 가 실패하면 → active (조회 실패가 게이트를 열지 않는다).
mk_gh <<'STUB'
#!/bin/sh
exit 1
STUB
check_wired "실조회 배선: gh실패→active(fail-closed)" active
rm -rf "$hb"

echo "finish-classify.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
