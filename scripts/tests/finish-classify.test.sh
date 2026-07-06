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
# assert <name> <expected> <comments-json>
assert() {
  local name="$1" expect="$2" comments="$3"
  local got
  got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
    FC_COMMENTS_JSON="$comments" "$SUT" owner/repo 1 2>/dev/null)
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$expect 실제=$got"
  fi
}

# 1) done_verdict — 최신 머지 판정이 ✅
assert "done_verdict" done_verdict '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:01:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:02:00Z"}
]'

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
]'

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
got_ci=$(FC_NOW="$NOW" FC_FAILING=2 STALE_FINISH_MIN=30 \
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

echo "finish-classify.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
