#!/usr/bin/env bash
# finish-classify.sh 픽스처 테스트 — 네트워크 무접속(모든 입력을 env 로 주입).
# 6개 분류(done_verdict·held·stale_inline·stale_reverify·no_verdict·active) + 시간버퍼 경계
# + 재리뷰(마지막 매칭) 케이스를 결정적으로 검증한다. bats 미도입 레포라
# bin/ci 인라인 스모크(repo-dir.sh)와 동일한 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/finish-classify.sh"

# 고정 NOW = 2026-07-05T12:00:00Z (BSD/GNU date 양쪽 파싱).
NOW=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-05T12:00:00Z" +%s 2>/dev/null \
  || date -u -d "2026-07-05T12:00:00Z" +%s)

# **네트워크 무접속 기본값** — `#206` 진행 증거 ③(claim 부착 시각)은 주입이 없으면 실 gh
# (`gh pr view --json closingIssuesReferences` → `claim-at.sh`)를 부른다. 이 파일의 모든
# 호출 자리가 그 주입을 개별로 적으면 한 자리만 빠져도 조용히 네트워크를 탄다 — 그래서
# 기본값을 여기 한 번 export 하고, claim 축을 무는 행만 호출 앞에서 덮어쓴다
# (`VAR=... cmd` 접두가 export 값을 이긴다). `none` = "claim 증거 없음" 이라 이 파일의
# 기존 기대값은 전부 그대로다.
export FC_CLAIMED_AT=none

pass=0
fail=0
# assert <name> <expected> <comments-json> [head_at]
# head_at 미지정 시 FC_HEAD_AT="" 로 명시 고정 — 실호출(gh) 경로로 새지 않게(네트워크 무접속 유지).
# `FC_CLAIMED_AT=none` 도 같은 이유다(#206 진행 증거 ③) — 주지 않으면 claim 조회가 실 gh 로
# 샌다. `none` = "claim 증거 없음" 이므로 이 아래 기존 단언들의 기대값은 그대로다.
assert() {
  local name="$1" expect="$2" comments="$3" head_at="${4:-}"
  local got
  got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
    FC_COMMENTS_JSON="$comments" FC_HEAD_AT="$head_at" FC_CLAIMED_AT=none \
    "$SUT" owner/repo 1 2>/dev/null)
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
# (d) gh 가 실패하는 경우(권한·네트워크 등) → **판정 불가 = active**(무접촉), 크래시 없음.
#     #206 회차2 에서 계약이 바뀐 자리다. 옛 단언은 "기존 판정으로 degrade(stale_reverify)"
#     였다 — 즉 조회 실패 한 번이 "커밋 증거 없음" 으로 둔갑해 재디스패치까지 갔다. 되돌릴
#     수 없는 쪽(재디스패치·머지)은 증명 없이 열지 않는다는 이 파일의 규율(#171 ✅ 갈래와
#     같은 방향)로 통일한다. 회수는 조회가 성공하는 다음 틱에 그대로 일어난다 — (c) 가
#     그것을 문다(같은 실 경로·조회 성공·커밋 스테일 → stale_reverify).
: > "$capture"
got=$(PATH="$stub:$PATH" STUB_CAPTURE="$capture" STUB_HEAD_AT="" \
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 \
  FC_COMMENTS_JSON='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T11:00:00Z"}]' \
  "$SUT" owner/repo 1 2>/dev/null)
if [ "$got" = active ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ 실수집경로·gh조회실패→active(판정불가) — 기대=active 실제=$got"
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
    FC_COMMENTS_JSON="$comments" FC_HEAD_AT="$head_at" FC_CLAIMED_AT=none "$SUT" owner/repo 1 2>/dev/null)
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


# ══════════════════════════════════════════════════════════════════════════════
# #206 격자 — ①-b 라우팅 전수 단언 (mergeable × 최신 판정 × 단계 라벨 × 커밋 신선도)
#
# 왜 개별 케이스가 아니라 격자인가(PR#202 교훈): 이 축은 지적된 반례만 하나씩 닫으면
# 같은 자리가 여러 회차를 돈다. `want` 열을 가진 표로 전수 단언한다.
#
# `route_1b` 는 skills/closeout/SKILL.md ①-b 산문을 **그대로 옮긴 드라이버**다 —
# 결함이 단위(finish-classify 한 개)가 아니라 **조합**(어느 PR 이 어느 헬퍼를 지나는가)
# 에 있었으므로 조합을 재현해야 격자가 의미를 갖는다. 산문과 벌어지지 않게 bin/ci 가
# 같은 문서에 `progress-evidence.sh`·`bounced`+`finish-classify` 배선을 함께 문다.
#
# want 값(= ①-b 가 그 PR 에 취하는 조치):
#   adopt_rebase   CONFLICTING 입양(rebase 경로) — ② Pick 후보
#   adopt_merge    stale_inline 입양(머지) — ② Pick 후보
#   redispatch     closeout-redispatch 전이(issue-runner 가 같은 브랜치로 재투입)
#   needs_human    closeout-blocked 전이
#   eligible_path  done_verdict — eligible.sh 정상 경로 소유, 스윕은 skip
#   untouched      무접촉(다음 틱)
# ══════════════════════════════════════════════════════════════════════════════

GT=$(mktemp -d)

# queue.log 픽스처 — `$G_SHA` 티켓이 큐에 **살아 있는** 로그와, 아무 줄도 없는 로그.
G_SHA="7ac1f0e91234567890abcdef1234567890abcdef"   # short = 7ac1f0e9
printf '%s\n' "2026-07-05T11:30:00 pid=11111 7ac1f0e9 대기열 2번째" > "$GT/queued.log"
: > "$GT/empty.log"
printf '%s\n' "2026-07-05T11:30:00 pid=11111 7ac1f0e9 대기열 2번째" > "$GT/unreadable.log"
chmod 000 "$GT/unreadable.log"
# 소유권 필터 픽스처 — 우리 티켓이 대기열에 있고, **그 뒤에** 남의 옛 티켓이 폐기되며
# 본문에 우리 SHA 를 언급한다(새 push 가 자기 티켓을 낸 흔한 형상). 그 줄을 우리 줄로
# 세면 큐를 기다리는 살아 있는 워커가 `left` 로 읽혀 죽는다.
G_OTHER="da323b67fedcba0987654321fedcba0987654321"
printf '%s\n' \
  "2026-07-05T11:30:00 pid=11111 7ac1f0e9 대기열 2번째" \
  "2026-07-05T11:31:00 pid=22222 da323b67 폐기 — 실행 시점 HEAD 가 $G_SHA ≠ $G_OTHER" \
  > "$GT/queued_then_foreign_discard.log"
# 큐 이탈 픽스처 — 우리 SHA 의 **마지막 줄**이 pass 다(대기열 줄이 앞에 남아 있어도
# 그건 이미 끝난 티켓이다).
printf '%s\n' \
  "2026-07-05T11:30:00 pid=11111 7ac1f0e9 대기열 2번째" \
  "2026-07-05T11:40:00 pid=11111 7ac1f0e9 pass (487s) → /x/$G_SHA.result" \
  > "$GT/queued_then_pass.log"

# 시각 축 — NOW = 12:00:00Z.
G_OLD="2026-07-05T10:00:00Z"    # 120분 전 — 커밋 오래됨(STALL_MIN 25·STALE_FINISH_MIN 30 둘 다 초과)
G_FRESH="2026-07-05T11:50:00Z"  # 10분 전 — 커밋 신선
G_15M="2026-07-05T11:45:00Z"    # 15분 전 — STALL_MIN(25) 이내이지만 버퍼 10분은 넘김
G_40M="2026-07-05T11:20:00Z"    # 40분 전 — STALL_MIN 밖
# claim 축 — ISSUE_TIMEBOX_HOURS=1(run_fc 가 고정)이므로 경계는 60분이다.
G_CLAIM_5M="2026-07-05T11:55:00Z"    # 5분 전 — 방금 디스패치된 교체 워커(첫 푸시 전)
G_CLAIM_60M="2026-07-05T11:00:00Z"   # 정확히 60분 전 — 타임박스 경계(포함)
G_CLAIM_61M="2026-07-05T10:59:00Z"   # 61분 전 — 타임박스 밖
# WARN 3(회차3) 교락 해소 축 — 위 네 값은 전부 "반송 이후 = 타임박스 안 / 반송 이전 =
# 타임박스 밖" 으로 붙어 다녀서, 신선도 술어가 **반송 시각을 보는지 타임박스만 보는지**를
# 가르지 못한다. 아래 두 값은 `bounced_recent.json`(반송 11:20)과 짝지어 그 교락을 푼다.
G_CLAIM_50M="2026-07-05T11:10:00Z"   # 50분 전 — 반송(11:20) **이전**이지만 타임박스 **안**
G_CLAIM_100M="2026-07-05T10:20:00Z"  # 100분 전 — 반송 이전이고 타임박스 **밖**(대조군)

# 코멘트 픽스처 (본문은 실제 워커·verify-runner 가 찍는 접두를 그대로 쓴다).
cat > "$GT/bounced_noverifier.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: E2E 1건 실패 — 반송\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:35:00Z"}
]
J
# 반송 마커가 **최근**인 판(11:20 — STALE_FINISH_MIN 30 은 넘겼다). 위 픽스처는 반송이
# 10:35 라 "반송 이전 · 타임박스 안" 칸이 아예 도달 불가다(반송 이전 = 10:35 이전 =
# 타임박스 경계 11:00 보다 이르다). 이 픽스처가 그 칸을 연다.
cat > "$GT/bounced_recent.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: E2E 1건 실패 — 반송\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:20:00Z"}
]
J
cat > "$GT/bounced_verifier_clean.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:31:00Z"},
  {"body":"재검증 실패: E2E 1건 실패 — 반송\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:35:00Z"}
]
J
cat > "$GT/verdict_ok.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:31:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:32:00Z"}
]
J
cat > "$GT/verifier_clean.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:31:00Z"}
]
J
cat > "$GT/held.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:32:00Z"}
]
J

# run_fc <comments-file> <head_at> <head_sha> <queue.log> [STALE_FINISH_MIN] [claimed_at]
# 7번째 인자 = CI 롤업의 **미완료 수**(#421). 기본 0 = 전부 종결(종전 격자 전부 불변).
# 위치 인자로 받는 이유: `FC_PENDING=1 run_fc …` 접두는 명령치환 밖에서 쓰면 다음 행까지
# 값이 남는다(bash 는 함수 호출의 접두 대입을 셸에 남긴다) — 격자가 조용히 오염된다.
run_fc() {
  FC_NOW="$NOW" FC_FAILING=0 FC_PENDING="${7:-0}" STALE_FINISH_MIN="${5:-30}" STALL_MIN=25 \
    ISSUE_TIMEBOX_HOURS=1 \
    FC_COMMENTS_FILE="$1" FC_HEAD_AT="$2" FC_HEAD_SHA="$3" FC_QUEUE_LOG="$4" \
    FC_CLAIMED_AT="${6:-none}" \
    "$SUT" owner/repo 1 2>/dev/null
}

# map_1b <branch: bounced|plain> <finish-classify 출력> → ①-b 조치
# SKILL ①-b 산문의 **분기표 한 자리**. route_1b(주입 입력)와 아래 스텁 경로(실호출 자리)
# 가 같은 표를 쓴다 — 두 벌로 적으면 한쪽만 고쳐질 때 격자가 산문과 조용히 갈린다.
map_1b() {
  case "$1" in
    bounced)
      # `bounced` 갈래는 **재디스패치만** 연다. 입양(머지)은 어느 출력에서도 열지 않는다 —
      # 반송된 PR 에 남은 `검증자 리뷰: CLEAN` 은 반송 *이전* 회차의 것일 수 있다(#196).
      # `stale_inline` 도 여기선 입양이 아니라 재디스패치다: 교체 워커가 커밋만 하고 ✅
      # 직전에 죽은 형상이라(이 이슈가 없애려는 바로 그 좌초), 무접촉으로 두면 같은 정체가
      # 옆 칸에 그대로 남는다(회차1 검증자 WARN).
      case "$2" in
        stale_reverify|stale_inline) printf 'redispatch\n' ;;
        *)                           printf 'untouched\n' ;;
      esac ;;
    *)
      case "$2" in
        done_verdict)   printf 'eligible_path\n' ;;
        stale_inline)   printf 'adopt_merge\n' ;;
        stale_reverify) printf 'redispatch\n' ;;
        held)           printf 'needs_human\n' ;;
        *)              printf 'untouched\n' ;;
      esac ;;
  esac
}

# gate_1b <mergeable> <comments-file> — ①-b 1) 절(반송 마커 게이트)을 그대로 옮긴 드라이버.
# **#218(PR #225) 이후 게이트는 갈래를 가르기 전**이다 — mergeable 을 보기 전에 먼저 돈다.
# stdout 한 값:
#   untouched         무접촉으로 끝 (held · MERGEABLE 인 bounced · 판정 실패)
#   adopt_rebase      ok + CONFLICTING → 입양(rebase 경로)
#   classify:bounced  bounced + CONFLICTING → #206 예외 갈래(재디스패치만 연다)
#   classify:plain    ok + MERGEABLE 등 → 2) finish-classify 결과를 그대로 조치로
gate_1b() {
  local mergeable="$1" cfile="$2" bs rc=0
  bs=$(BOUNCE_COMMENTS_FILE="$cfile" "$DIR/bounce-state.sh" owner/repo 1 2>/dev/null) || rc=$?
  # 판정 실패(exit≠0·무출력)는 `bounced` 와 같은 방향 — 무접촉(fail-closed, #196·#171).
  if [ "$rc" != 0 ] || [ -z "$bs" ]; then printf 'untouched\n'; return 0; fi
  case "$bs" in
    ok)
      if [ "$mergeable" = CONFLICTING ]; then printf 'adopt_rebase\n'
      else printf 'classify:plain\n'; fi ;;
    bounced)
      # #206 예외 갈래는 **CONFLICTING 한 칸뿐**이다. MERGEABLE 인 bounced 까지 열면
      # #218 이 막은 오분류(방금 반송된 PR 을 "검증 전 사망" 으로 오진·재디스패치)가
      # 그대로 되살아난다.
      if [ "$mergeable" = CONFLICTING ]; then printf 'classify:bounced\n'
      else printf 'untouched\n'; fi ;;
    held)
      # #218 두 번째 회차(사람 결정 (c)) — 스윕은 held 를 needs-human 으로 승격하지
      # 않는다. #206 예외도 여기엔 열리지 않는다(반송 뒤 워커가 명시적으로 올린 보류다).
      printf 'untouched\n' ;;
    *) printf 'untouched\n' ;;
  esac
}

# route_1b <mergeable> <comments-file> <head_at> <head_sha> <queue.log> <labels(csv)> [STALE_FINISH_MIN] [claimed_at]
route_1b() {
  local mergeable="$1" cfile="$2" head_at="$3" head_sha="$4" qlog="$5" labels="$6"
  local sfm="${7:-30}" claim="${8:-none}"
  local fc g

  # 대상 필터 — `flow:verify`(verify-runner 소유)·`harvesting`(이미 입양)·`needs-human`
  # (사람 대기)은 ①-b 가 애초에 판정하지 않는다. 게이트보다 **앞**이다(대상 필터가 먼저).
  case ",$labels," in
    *,flow:verify,*|*,harvesting,*|*,needs-human,*) printf 'untouched\n'; return 0 ;;
  esac

  g=$(gate_1b "$mergeable" "$cfile")
  case "$g" in
    untouched|adopt_rebase) printf '%s\n' "$g"; return 0 ;;
  esac
  fc=$(run_fc "$cfile" "$head_at" "$head_sha" "$qlog" "$sfm" "$claim")
  map_1b "${g#classify:}" "$fc"
}

# row <이름> <want> <mergeable> <comments-file> <head_at> <head_sha> <queue.log> <labels>
row() {
  local name="$1" want="$2" got
  shift 2
  got=$(route_1b "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [격자] $name — want=$want got=$got"
  fi
}

echo "  [#206 격자] CONFLICTING × 반송마커 최신 × 단계 라벨 × 커밋 신선도"

# ── A. 이 이슈가 여는 칸 — 반송 뒤 워커가 ✅ 직전에 죽고 커밋이 오래됨 ──────────
row "A1 CONFLICTING·반송마커·라벨없음·커밋오래됨" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""

# ── B. 살아 있는 워커 보호(#196 무회귀) — 신선도 두 갈래 모두 무접촉 ───────────
row "B1 CONFLICTING·반송마커·커밋신선" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_FRESH" "$G_SHA" "$GT/empty.log" ""
# 커밋은 120분 전이지만 그 head SHA 의 CI 티켓이 **큐에 살아 있다** — 박스 전역 직렬 큐
# 대기는 워커가 통제 못 하는 시간이다(#200 실측 72분). 이 칸이 없으면 CI 를 기다리는
# 워커가 매번 재디스패치된다.
row "B2 CONFLICTING·반송마커·커밋오래됨·CI큐티켓살아있음" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/queued.log" ""
# 소유권 필터 — 우리 대기열 줄 **뒤에** 남의 폐기 줄이 우리 SHA 를 언급해도 그건 우리
# 줄이 아니다. 필터가 없으면 마지막 줄이 폐기 줄이 되어 `left` → 재디스패치로 뒤집힌다.
row "B3 CONFLICTING·반송마커·대기열+남의폐기줄이우리SHA언급" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/queued_then_foreign_discard.log" ""
# 마지막 줄 규칙 — 우리 SHA 의 마지막 줄이 pass 면 큐를 떠난 것이다. "어딘가에 대기열
# 줄이 있나" 로 재면 이미 끝난 티켓을 살아 있다고 읽는다.
row "B3b CONFLICTING·반송마커·우리SHA마지막줄이pass(큐이탈)" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/queued_then_pass.log" ""
# 큐에 그 SHA 줄이 아예 없으면 증거가 아니다 — A1 과 같은 결론으로 돌아온다.
row "B3c CONFLICTING·반송마커·커밋오래됨·티켓없음" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""

# 진행 증거를 **판정하지 못하면**(queue.log 를 읽을 수 없음) 그건 "증거 없음" 이 아니다 —
# 그 방향으로 접으면 파일 하나 깨진 박스가 살아 있는 워커를 전부 재디스패치한다.
row "B4 CONFLICTING·반송마커·커밋오래됨·큐로그읽기실패" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/unreadable.log" ""

# 커밋 신선도 축을 **독립적으로** 문다. 기본값에서는 시간버퍼(STALE_FINISH_MIN 30) >
# 신선도 임계(STALL_MIN 25) 라 "커밋이 신선" 한 칸이 스테일 클록에도 걸려 두 보호가
# 겹친다 — 겹치면 격자가 커밋 축을 실제로는 안 무는 것이다(뮤테이션으로 확인: 커밋
# 시각을 헬퍼에 안 넘겨도 기본값 행은 전부 초록이었다). 두 상수는 독립 knob 이므로
# 버퍼를 10분으로 좁혀 그 겹침을 풀면, 커밋 15분 전(= STALL_MIN 이내)인 워커를 살리는
# 것은 **오직 신선도 술어**다.
row "B5 CONFLICTING·반송마커·버퍼10분·커밋15분전(STALL_MIN 이내)" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_15M" "$G_SHA" "$GT/empty.log" "" 10
# 같은 버퍼에서 커밋이 STALL_MIN 밖(40분 전)이면 보호는 사라진다 — 위 칸이 "항상 untouched"
# 가 아니라 신선도 때문에 untouched 임을 고정한다.
row "B6 CONFLICTING·반송마커·버퍼10분·커밋40분전(STALL_MIN 밖)" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_40M" "$G_SHA" "$GT/empty.log" "" 10

# ── C. #196 입양 판별식 무회귀 — 최신 판정이 ✅ 면 신선도와 무관하게 입양 ───────
row "C1 CONFLICTING·✅최신·커밋오래됨" adopt_rebase \
  CONFLICTING "$GT/verdict_ok.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""
row "C2 CONFLICTING·✅최신·커밋신선" adopt_rebase \
  CONFLICTING "$GT/verdict_ok.json" "$G_FRESH" "$G_SHA" "$GT/empty.log" ""

# ── D. 반송 뒤 CLEAN 검증자 코멘트가 남아 있어도 **입양하지 않는다** ──────────
# (그 CLEAN 은 반송 *이전* 회차의 것이다 — 입양하면 반송된 코드를 머지한다.)
# 대신 재디스패치로 보낸다(회차1 검증자 WARN): 교체 워커가 고쳐 커밋까지 하고 ✅ 직전에
# 죽은 형상이 `stale_inline` 로도 나오는데, 이걸 무접촉으로 두면 이 이슈가 없애려는
# 영구 정체가 옆 칸에 그대로 남는다. want=redispatch 는 "머지 안 한다"(adopt_merge 가
# 아니다)와 "정체시키지 않는다"를 **동시에** 문다.
row "D1 CONFLICTING·반송마커+검증자CLEAN·커밋오래됨" redispatch \
  CONFLICTING "$GT/bounced_verifier_clean.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""
# 같은 칸에서 커밋이 신선하면 워커는 살아 있다 — 재디스패치 갈래도 진행 증거 게이트를
# 그대로 통과해야 한다(D1 이 "항상 redispatch" 가 아님을 고정).
row "D2 CONFLICTING·반송마커+검증자CLEAN·커밋신선" untouched \
  CONFLICTING "$GT/bounced_verifier_clean.json" "$G_FRESH" "$G_SHA" "$GT/empty.log" ""
row "D3 CONFLICTING·반송마커+검증자CLEAN·CI큐티켓살아있음" untouched \
  CONFLICTING "$GT/bounced_verifier_clean.json" "$G_OLD" "$G_SHA" "$GT/queued.log" ""

# ── E. 반송 판정 실패는 통과가 아니다(fail-closed) ─────────────────────────────
row "E1 CONFLICTING·반송판정실패(코멘트입력부재)" untouched \
  CONFLICTING "$GT/does-not-exist.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""

# 반송 마커 **뒤에 워커 `⚠ 보류`** 가 오면 bounce-state 는 `held` 다 — #206 예외 갈래는
# 그 값에는 열리지 않는다(워커가 명시적으로 올린 사람 대기 신호라 워커/사람 레인 소유).
cat > "$GT/bounced_then_held.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: E2E 1건 실패 — 반송\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:35:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:40:00Z"}
]
J
row "E2 CONFLICTING·반송마커 뒤 ⚠(held)·커밋오래됨" untouched \
  CONFLICTING "$GT/bounced_then_held.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""

# ── F. 단계 라벨이 있으면 ①-b 대상이 아니다 ───────────────────────────────────
row "F1 CONFLICTING·반송마커·flow:verify"  untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" "flow:verify"
row "F2 CONFLICTING·반송마커·harvesting"   untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" "harvesting"
row "F3 CONFLICTING·반송마커·needs-human"  untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" "needs-human"

# ── G. MERGEABLE 축 무회귀 — 같은 신선도 규칙이 2) 경로에도 그대로 적용된다 ────
# #218(PR #225)로 **want 가 뒤집힌 칸**이다 — 반송 게이트가 갈래 앞으로 올라가면서
# MERGEABLE 인 `bounced` 는 finish-classify 를 아예 안 탄다(그게 #218 이 고친 사고:
# 방금 반송된 MERGEABLE PR 이 `stale_reverify`= "검증 전 사망" 으로 오진돼 재디스패치되고
# 사실과 다른 멱등 마커가 원장에 남았다). #206 의 예외 갈래는 CONFLICTING 한 칸뿐이므로
# 이 칸은 열리지 않는다.
row "G1 MERGEABLE·반송마커·커밋오래됨(#218 게이트가 갈래 앞)" untouched \
  MERGEABLE "$GT/bounced_noverifier.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""
row "G2 MERGEABLE·반송마커·커밋신선"            untouched \
  MERGEABLE "$GT/bounced_noverifier.json" "$G_FRESH" "$G_SHA" "$GT/empty.log" ""
row "G3 MERGEABLE·✅최신(head 이후)"            eligible_path \
  MERGEABLE "$GT/verdict_ok.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""
row "G4 MERGEABLE·검증자CLEAN+🔄·커밋오래됨"    adopt_merge \
  MERGEABLE "$GT/verifier_clean.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""
row "G5 MERGEABLE·검증자CLEAN+🔄·커밋신선"      untouched \
  MERGEABLE "$GT/verifier_clean.json" "$G_FRESH" "$G_SHA" "$GT/empty.log" ""
# G4 와 같은데 CI 티켓만 살아 있음 — 자동 머지(입양)를 막아야 한다. 살아 있는 워커가
# 곧 ✅ 를 찍을 PR 을 closeout 이 먼저 가져가면 그게 #196 이 막은 사고의 머지판이다.
row "G6 MERGEABLE·검증자CLEAN+🔄·CI큐티켓살아있음" untouched \
  MERGEABLE "$GT/verifier_clean.json" "$G_OLD" "$G_SHA" "$GT/queued.log" ""
row "G7 MERGEABLE·⚠ 최신"                       needs_human \
  MERGEABLE "$GT/held.json" "$G_OLD" "$G_SHA" "$GT/empty.log" ""

# ══════════════════════════════════════════════════════════════════════════════
# #206 회차2 — head **조회 실패**(unknown) ≠ 커밋 증거 **부재**(none)
#
# 회차1 반송 사유(검증자 [P1]): `pr-head-at.sh` 가 일시적으로 실패하면 finish-classify 가
# **종료코드를 버리고** `head_sha=none`·`head_at=''` 로 정규화해, 하류(progress-evidence)
# 에 "커밋 증거가 없다"고 말했다. 반송된 CONFLICTING PR 에 오래된 코멘트만 있으면 그
# 결론으로 **살아 있는 워커가 재디스패치**된다 — `progress-evidence.sh:35` 이 못박은
# `unknown ≠ none` 계약 위반이다(PR#139: 빈 결과와 실패를 구분하라 · PR#168: 탈출 사유를
# 공유 센티널 하나에 싣지 말고 별도 플래그로 하류가 읽게 하라).
#
# 위 격자는 전부 `FC_HEAD_AT` **주입** 경로를 쓴다 — 그 경로만 무는 테스트는 실호출
# 자리(:130 부근)가 회귀해도 초록이다. 그래서 여기서는 주입을 쓰지 않고 **실제 호출
# 자리**를 스텁으로 물린다: `SCRIPT_DIR` 은 `dirname $0` 이므로 임시 디렉터리에
# finish-classify.sh·progress-evidence.sh 를 심링크하고 그 옆에 스텁 `pr-head-at.sh` 를
# 두면 head 조회만 갈아끼울 수 있다(네트워크 무접속은 그대로 — 코멘트는
# `FC_COMMENTS_FILE`, CI 는 `FC_FAILING` 으로 주입).
# ══════════════════════════════════════════════════════════════════════════════

ST=$(mktemp -d)
ln -s "$DIR/finish-classify.sh"   "$ST/finish-classify.sh"
ln -s "$DIR/progress-evidence.sh" "$ST/progress-evidence.sh"
ln -s "$DIR/pr-comments.sh"       "$ST/pr-comments.sh"
# 반송 마커 판별을 되묻는 자리(#308) — 심링크가 없으면 조회 실패(unknown)로 접혀
# 아래 행들이 전부 active 로 뒤집힌다(그 fail-closed 자체는 J 절이 따로 문다).
ln -s "$DIR/bounce-state.sh"      "$ST/bounce-state.sh"

# write_head_stub <exit코드> <stdout 한 줄(빈 문자열이면 무출력)>
write_head_stub() {
  cat > "$ST/pr-head-at.sh" <<EOF
#!/usr/bin/env bash
[ -n '$2' ] && printf '%s\n' '$2'
exit $1
EOF
  chmod +x "$ST/pr-head-at.sh"
}

# run_stub <comments-file> <queue.log> — **FC_HEAD_AT 를 주지 않는다**(실호출 경로).
run_stub() {
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 STALL_MIN=25 \
    FC_COMMENTS_FILE="$1" FC_QUEUE_LOG="$2" \
    "$ST/finish-classify.sh" owner/repo 1 2>/dev/null
}

# route_stub <mergeable> <comments-file> <stub-rc> <stub-stdout> <queue.log>
route_stub() {
  local mergeable="$1" cfile="$2" srepo_rc="$3" sout="$4" qlog="$5" g
  write_head_stub "$srepo_rc" "$sout"
  # 게이트는 route_1b 와 **같은 함수**를 쓴다 — 두 드라이버가 갈래 구조를 따로 들고
  # 있으면 한쪽만 #218/#206 을 반영해 격자가 서로 다른 산문을 재현한다.
  g=$(gate_1b "$mergeable" "$cfile")
  case "$g" in
    untouched|adopt_rebase) printf '%s\n' "$g"; return 0 ;;
  esac
  map_1b "${g#classify:}" "$(run_stub "$cfile" "$qlog")"
}

# row_stub <이름> <want> <mergeable> <comments-file> <stub-rc> <stub-stdout> <queue.log>
row_stub() {
  local name="$1" want="$2" got
  shift 2
  got=$(route_stub "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [조회실패] $name — want=$want got=$got"
  fi
}

echo "  [#206 회차2] pr-head-at.sh 종료코드 — unknown(조회 실패) vs none(부재)"

# H1 ⑴ 조회 **실패**(비0 종료) → 판정 불가 → 재디스패치 라우트로 가지 않는다(fail-closed).
#     이 행이 회차1 코드에서 빨갛다: 종료코드를 버리면 head_sha=none 이 되어 증거 없음이
#     되고, 오래된 반송 코멘트뿐인 이 형상은 곧바로 redispatch 로 떨어진다.
row_stub "H1 CONFLICTING·반송마커·head조회실패(exit 1)" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" 1 "" "$GT/empty.log"

# H2 ⑵ 조회는 **성공**했고 커밋이 오래됨 → 진짜 증거 부재 → 종전대로 재디스패치.
row_stub "H2 CONFLICTING·반송마커·head조회성공·커밋오래됨" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" 0 "$G_SHA $G_OLD" "$GT/empty.log"

# H3 ⑶ 조회 성공 + 커밋 신선 → 종전대로 무접촉.
row_stub "H3 CONFLICTING·반송마커·head조회성공·커밋신선" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" 0 "$G_SHA $G_FRESH" "$GT/empty.log"

# H3b 조회 성공 + 커밋 오래됨인데 그 SHA 의 CI 티켓이 큐에 살아 있음 → 무접촉.
#     (스텁이 낸 SHA 가 실제로 큐 판정에 쓰이는지 — SHA 축이 전달되는지 — 를 문다.)
row_stub "H3b CONFLICTING·반송마커·head조회성공·CI큐티켓살아있음" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" 0 "$G_SHA $G_OLD" "$GT/queued.log"

# H4 종료코드 0 인데 **출력이 빔** = 헬퍼 계약 위반(PR 에는 반드시 head 커밋이 있다).
#    "커밋이 없다" 로 읽을 수 없으므로 조회 실패와 같게 받는다.
row_stub "H4 CONFLICTING·반송마커·head조회 exit0 무출력" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" 0 "" "$GT/empty.log"

# H5 같은 조회 실패를 **머지 방향**에서도 문다 — 검증자 CLEAN + 🔄 형상에서 조회가 실패하면
#    회차1 코드는 `stale_inline`(=입양/머지)을 냈다. 되돌릴 수 없는 쪽은 증명 없이 안 연다.
row_stub "H5 MERGEABLE·검증자CLEAN+🔄·head조회실패(exit 1)" untouched \
  MERGEABLE "$GT/verifier_clean.json" 1 "" "$GT/empty.log"

# H6 ⑷ 과잉 보수 반증 — 조회가 성공한 같은 형상은 여전히 입양으로 간다(전부 unknown 으로
#    접지 않는다). H5 와 H6 의 차이는 오직 스텁의 종료코드다.
row_stub "H6 MERGEABLE·검증자CLEAN+🔄·head조회성공·커밋오래됨" adopt_merge \
  MERGEABLE "$GT/verifier_clean.json" 0 "$G_SHA $G_OLD" "$GT/empty.log"

# H7 ✅ 갈래 무회귀(#171) — 조회 실패면 "판정이 head 이후"를 증명 못 하므로 done_verdict 를
#    내지 않고(=eligible_path 아님) 무접촉이다. 같은 형상에서 조회가 성공하면 종전대로 통과.
row_stub "H7 MERGEABLE·✅최신·head조회실패(exit 1)" untouched \
  MERGEABLE "$GT/verdict_ok.json" 1 "" "$GT/empty.log"
row_stub "H7b MERGEABLE·✅최신·head조회성공(✅보다 이른 커밋)" eligible_path \
  MERGEABLE "$GT/verdict_ok.json" 0 "$G_SHA 2026-07-05T10:31:30Z" "$GT/empty.log"

rm -rf "$ST"

# ── I. 현재 회차 시작 증거 — `agent:claimed` 부착 시각 (#206 attempt 3) ────────
# attempt 2 의 codex BLOCKER: 반송 직후 교체 워커가 디스패치됐지만 **첫 푸시 전**이면
# 커밋도 CI 티켓도 없다. 그때 이 파일이 보는 값(옛 판정 시각·옛 head 시각)은 전부 이전
# attempt 의 것이라 `stale_reverify` 가 나고, `closeout-redispatch` 가 **지금 일하고 있는
# 워커의 `agent:claimed` 를 떼어낸다.** ①② 는 워커가 이미 뭔가 남긴 뒤에만 존재하는
# 증거라 이 창을 못 덮는다 — 덮는 것은 "이번 회차가 언제 시작됐나" 하나뿐이다.
#
# 아래 행들은 **커밋 증거를 전부 없앤 채**(head_at 빈 값 + head_sha none + 빈 queue.log)
# claim 축만 움직인다 — 그래야 격자가 claim 축을 실제로 문다(커밋 축과 겹치면 무엇이
# 살렸는지 알 수 없다, B5/B6 와 같은 규율).
echo "  [#206 격자·I] 현재 회차 시작 증거 — agent:claimed 부착 시각"

# I1 **이번 회차 핵심** — 반송 뒤 claim 이 방금(5분 전) 붙었고 커밋·CI 증거가 하나도 없다.
#    attempt 2 코드로 돌리면 `stale_reverify` → redispatch 로 빨개진다(살아있는 워커 사망).
row "I1 CONFLICTING·반송마커·증거전무·claim 5분전(첫 푸시 전)" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_5M"

# I2 과잉 보수 반증 — 같은 형상에서 claim 이 타임박스 밖(120분 전)이면 종전대로 회수한다.
#    I1↔I2 는 **claim 시각 하나만** 다르다.
row "I2 CONFLICTING·반송마커·증거전무·claim 120분전(타임박스 밖)" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 "$G_OLD"

# I3 경계 — 정확히 60분 전(= ISSUE_TIMEBOX_HOURS) 은 **안쪽**이다(`<=`).
row "I3 CONFLICTING·반송마커·claim 60분전(경계=타임박스 안)" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_60M"

# I4 경계 바깥 — 61분 전이면 회수한다(경계가 `<` 로 밀리거나 `<=` 가 사라지면 I3/I4 가 갈린다).
row "I4 CONFLICTING·반송마커·claim 61분전(경계 밖)" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_61M"

# I5 claim 이 **붙어 있지 않음**(`none` — 뗐거나 이력 없음) → 증거가 아니다. A1 과 같은 결론.
row "I5 CONFLICTING·반송마커·claim none(미부착)" redispatch \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 none

# I6 claim **조회 실패**(`unknown`) → "증거 없음" 이 아니다(unknown≠none, 회차2 와 같은 규율).
#    조회 실패 한 번으로 살아 있는 워커의 claim 을 떼는 것은 되돌릴 수 없다.
row "I6 CONFLICTING·반송마커·claim 조회실패(unknown)" untouched \
  CONFLICTING "$GT/bounced_noverifier.json" "" none "$GT/empty.log" "" 30 unknown

# I7 **머지 방향에서도** 같은 보호 — 검증자 CLEAN + 🔄 인데 claim 이 방금 붙었으면
#    `stale_inline` 입양(머지)도 열지 않는다. 되돌릴 수 없는 쪽은 증명 없이 안 연다.
row "I7 MERGEABLE·검증자CLEAN+🔄·claim 5분전" untouched \
  MERGEABLE "$GT/verifier_clean.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_5M"

# I8 그 대조군 — 같은 형상에서 claim 이 타임박스 밖이면 종전대로 입양이 열린다(G4 무회귀).
row "I8 MERGEABLE·검증자CLEAN+🔄·claim 120분전" adopt_merge \
  MERGEABLE "$GT/verifier_clean.json" "" none "$GT/empty.log" "" 30 "$G_OLD"


# ── I9·I10 (회차3 WARN 3) — claim 축의 **교락을 푼다** ────────────────────────
# I1~I8 의 claim 값 네 개는 "반송 이후 = 타임박스 안(I1·I3) / 반송 이전 = 타임박스 밖
# (I2·I5 계열)" 으로 완전히 붙어 다닌다. 그래서 신선도 술어가 ⒜ **반송보다 나중인가**를
# 보는지 ⒝ **타임박스 안인가**만 보는지 그 격자로는 못 가른다 — 나중에 ⒜ 를 넣거나 빼도
# I1~I8 은 전부 그대로 초록이다. 아래 두 행은 반송이 **최근**(11:20)인 픽스처에서
# claim 을 반송 **이전**에 두어 그 두 축을 갈라놓는다.
#
# I9 의 `want=untouched` 는 **지금 구현이 ⒝ 만 본다**는 사실을 못박은 것이다(⒜ 미구현).
# 그 선택의 근거: 반송 전이(`transition.sh:148` verify-redispatch · `:160`
# closeout-redispatch)는 이슈에서 `agent:claimed` 를 **뗀다**(`iss_rm` 에 들어 있다).
# `claim-at.sh` 는 부착 여부를 **마지막 매칭 이벤트**로 재므로 그 해제 뒤에는 `none` 을
# 낸다 — 즉 반송을 거친 이슈가 claim 시각을 되돌려 주는 유일한 경우는 디스패처가 **다시
# 붙인** 것이고, 그 부착은 정의상 반송보다 나중이다. ⒜ 는 구조적으로 함의된다.
# 남는 구멍은 **전이 스크립트를 안 거친 손 반송**뿐이고, 그 손해는 타임박스 상한
# (`ISSUE_TIMEBOX_HOURS`) 안의 **지연**이라 영구 정체가 아니다.
# 이 행이 있으면 나중에 ⒜ 를 실제로 넣는 사람은 I9 가 빨개지는 것을 보고 **의도한
# 변경인지** 판단하게 된다 — 교락된 격자에서는 그 신호가 아예 안 뜬다.
row "I9 CONFLICTING·반송최근(11:20)·claim 50분전(반송 이전·타임박스 안)" untouched \
  CONFLICTING "$GT/bounced_recent.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_50M"

# I10 대조군 — 같은 픽스처에서 claim 이 타임박스 **밖**이면 종전대로 회수한다.
#     I9↔I10 은 claim 시각 하나만 다르다(둘 다 반송 이전이라 ⒜ 축은 고정돼 있다).
row "I10 CONFLICTING·반송최근(11:20)·claim 100분전(반송 이전·타임박스 밖)" redispatch \
  CONFLICTING "$GT/bounced_recent.json" "" none "$GT/empty.log" "" 30 "$G_CLAIM_100M"


# ══════════════════════════════════════════════════════════════════════════════
# #308 — 최신 반송 마커 시각도 **스테일 클록**에 든다
#
# 창: `verify-redispatch`·`closeout-redispatch` 는 반송하면서 이슈의 `agent:claimed` 를
# **뗀다**. 그래서 반송 직후 디스패처가 다시 붙이기 전 구간에서는 진행 증거 세 축이
# 전부 old/none 이다 — head 커밋은 E2E 대기 탓에 30분 이상 전(①), 큐 티켓은 이미
# 빠졌고(②), claim 은 `none`(③). 그 창에 main 이 움직여 CONFLICTING 이 되면 ①-b
# 예외 갈래가 `stale_reverify` 를 내고 `재디스패치: #N — 완결 유실(검증 전 사망)` 이라는
# **사인이 틀린 멱등 마커**가 원장에 남는다(#218 이 MERGEABLE 쪽에서 막은 그 사고의
# CONFLICTING 판). 워커는 안 죽었다 — 방금 반송돼 교체 대기 중일 뿐이다.
#
# 아래 행들은 **커밋·CI·claim 증거를 전부 없앤 채**(head 120분 전 + 빈 queue.log +
# claim none) 반송 마커 시각 하나만 움직인다 — 그래야 격자가 이 축을 실제로 문다
# (B5/B6·I1~I8 과 같은 규율).
# ══════════════════════════════════════════════════════════════════════════════
echo "  [#308] 반송 마커 시각이 스테일 클록에 합류한다"

# fc_row <이름> <want> <comments-file> <head_at> <head_sha> <queue.log> [버퍼] [claim]
# — route_1b 를 거치지 않고 **분류기 출력 자체**를 문다(이슈 Test plan 의 두 케이스가
#   `active`/`stale_reverify` 라는 분류값으로 적혀 있다). 라우팅 축은 J-R1/J-R2 가 문다.
fc_row() {
  local name="$1" want="$2" got
  shift 2
  got=$(run_fc "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [#308] $name — want=$want got=$got"
  fi
}

# J1↔J2 는 **반송 마커 시각 하나만** 다르다(이슈 Test plan 의 두 케이스).
cat > "$GT/b308_fresh.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:55:00Z"}
]
J
cat > "$GT/b308_old.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:25:00Z"}
]
J
fc_row "J1 반송 마커 신선(5분 전)+커밋 old+큐 none+claim none→active" active \
  "$GT/b308_fresh.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none
# **기존 예외 갈래가 통째로 죽지 않는다**(PR#225 교훈 — 새 입력을 더할 때 옛 분기가
# 도달 불가가 되는 쪽이 원래 버그보다 나쁘다). 마커가 버퍼 밖이면 종전대로 회수한다.
fc_row "J2 반송 마커 old(35분 전)+같은 조건→stale_reverify(예외 갈래 유지)" stale_reverify \
  "$GT/b308_old.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# 경계 — 정확히 버퍼(30분)면 `-gt` 가 거짓이라 `active`, 1초만 더 오래되면 회수다.
# 경계를 양쪽에서 못박아야 비교 연산자가 `-ge` 로 밀리거나 사라지는 회귀가 잡힌다.
cat > "$GT/b308_edge_in.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:30:00Z"}
]
J
cat > "$GT/b308_edge_out.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:29:59Z"}
]
J
fc_row "J3 반송 마커 정확히 30분 전(경계=안쪽)→active" active \
  "$GT/b308_edge_in.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none
fc_row "J4 반송 마커 30분 1초 전(경계 밖)→stale_reverify" stale_reverify \
  "$GT/b308_edge_out.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── ⑵ 반송 마커가 **아예 없는** 정상 PR — 클록 불변(새 입력이 빈 값으로 접힌다) ──
cat > "$GT/b308_nobounce.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"}
]
J
fc_row "J5 ⑵ 반송 마커 없음(정상 PR)→stale_reverify(클록 불변)" stale_reverify \
  "$GT/b308_nobounce.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── ⑶ 마커는 찾았는데 **시각을 못 얻음** — 신선한지 모르면 열지 않는다 ──────────
# (파싱 불가 값과 빈 값 두 갈래. 둘 다 `unknown` → `now` 로 접혀 `active`.)
cat > "$GT/b308_badat.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"not-a-real-timestamp"}
]
J
cat > "$GT/b308_emptyat.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":""}
]
J
fc_row "J6 ⑶ 마커 시각 파싱 실패→active(증명 실패는 열지 않는다)" active \
  "$GT/b308_badat.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none
fc_row "J7 ⑶ 마커 시각 빈 값→active" active \
  "$GT/b308_emptyat.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── ⑴ 코멘트 입력 자체를 못 읽음 → 빈 코멘트(=판정 코멘트 없음) → active ────────
fc_row "J8 ⑴ 코멘트 입력 부재→active" active \
  "$GT/does-not-exist.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── 훑는 순서 — 최신부터 거꾸로, 마커 아닌 코멘트는 **건너뛴다** ────────────────
# J9 마커 뒤에 더 최신 비마커 코멘트가 있어도 마커를 찾아낸다(단순히 "마지막 코멘트"만
#    보는 구현이면 빨개진다).
cat > "$GT/b308_fresh_then_chat.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:55:00Z"},
  {"body":"참고: 이 PR 의 로그를 확인했습니다.\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:58:00Z"}
]
J
fc_row "J9 마커 뒤 비마커 최신 코멘트 — 거꾸로 훑어 마커를 찾는다→active" active \
  "$GT/b308_fresh_then_chat.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none
# J10 **반증** — 비마커 코멘트는 클록에 **안 든다**. 새 입력이 "아무 코멘트나 = 활동"
#     으로 넓어졌다면 이 행이 active 로 뒤집힌다(그러면 완결 유실 회수가 통째로 죽는다).
cat > "$GT/b308_old_then_chat.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:25:00Z"},
  {"body":"참고: 이 PR 의 로그를 확인했습니다.\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:58:00Z"}
]
J
fc_row "J10 비마커 최신 코멘트는 클록에 안 든다→stale_reverify" stale_reverify \
  "$GT/b308_old_then_chat.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── 머지 방향에서도 같은 보호(stale_inline 갈래) ────────────────────────────────
cat > "$GT/b308_clean_fresh.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:31:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:55:00Z"}
]
J
cat > "$GT/b308_clean_old.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:31:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:25:00Z"}
]
J
fc_row "J11 검증자 CLEAN+🔄·반송 마커 신선→active(인라인 대리 판정도 안 연다)" active \
  "$GT/b308_clean_fresh.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none
fc_row "J12 같은 형상·반송 마커 old→stale_inline(무회귀)" stale_inline \
  "$GT/b308_clean_old.json" "$G_OLD" "$G_SHA" "$GT/empty.log" 30 none

# ── 라우팅 축 — ①-b 가 실제로 사인이 틀린 마커를 안 남기는가 ────────────────────
row "J-R1 CONFLICTING·반송 마커 신선·증거 전무→무접촉(사인 틀린 멱등 마커 없음)" untouched \
  CONFLICTING "$GT/b308_fresh.json" "$G_OLD" "$G_SHA" "$GT/empty.log" "" 30 none
row "J-R2 CONFLICTING·반송 마커 old·증거 전무→재디스패치(무회귀)" redispatch \
  CONFLICTING "$GT/b308_old.json" "$G_OLD" "$G_SHA" "$GT/empty.log" "" 30 none

# ══════════════════════════════════════════════════════════════════════════════
# K. `no_verdict` — 판정 코멘트가 **0건**인 초록 PR (#396)
#
# 워커가 `머지 판정: 🔄` 를 찍기 전에 죽으면 판정 코멘트가 하나도 없다. 종전엔 그 칸이
# `active` 라 어느 레인도 안 집었다(issue-runner ② 는 사람 리뷰 대기로 무접촉, closeout ①-b
# 는 🔄/✅ 전제). 세 축을 **따로** 문다 — 시간버퍼 · 진행 증거 · 증명 실패.
# ══════════════════════════════════════════════════════════════════════════════
echo "  [#396] no_verdict — 판정 코멘트 0건 + 증거 없음 + 버퍼 초과"

cat > "$GT/no_verdict_empty.json" <<'J'
[]
J
# 판정 코멘트가 아닌 코멘트만 있는 형상(워커가 초반 보고만 남기고 죽음) — 위와 같은 칸이다.
cat > "$GT/no_verdict_other.json" <<'J'
[
  {"body":"진행 보고: 구현 시작\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:05:00Z"}
]
J
G_CLAIM_45M="2026-07-05T11:15:00Z"   # 45분 전 — 버퍼(30) 밖이지만 타임박스(60) 안

check_nv() {  # check_nv <이름> <기대> <실제>
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ [#396] $1 — 기대=$2 실제=$3"; fi
}

# K1 이 이슈가 여는 칸 — 코멘트 0건 · head 120분 전 · claim 미부착 · 큐 증거 없음.
check_nv "K1 판정 0건·증거 전무·버퍼 초과" no_verdict   "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 none)"
# K2 판정 아닌 코멘트만 있어도 같은 칸이다(`머지 판정:` 접두가 없으면 판정 0건).
check_nv "K2 판정 아닌 코멘트만·증거 전무·버퍼 초과" no_verdict   "$(run_fc "$GT/no_verdict_other.json" "$G_OLD" none "$GT/empty.log" 30 none)"
# K3 **진행 증거 ③** — claim 이 45분 전(버퍼 밖·타임박스 안)이면 워커는 살아 있다 → active.
#    K1 과 다른 것은 claim 하나뿐이다(교락 없음).
check_nv "K3 claim 45분전(타임박스 안)→active" active   "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 "$G_CLAIM_45M")"
# K4 **시간버퍼 미도달** — head 40분 전인데 버퍼가 60분이면 아직 이르다 → active.
#    (STALL_MIN 25 밖이라 커밋 증거로 살아난 것이 아니다 — 버퍼 축만 움직였다.)
check_nv "K4 버퍼 미도달(head 40분전·버퍼 60)→active" active   "$(run_fc "$GT/no_verdict_empty.json" "$G_40M" none "$GT/empty.log" 60 none)"
# K5 **증명 실패는 열지 않는다** — claim 조회 실패(unknown)는 "증거 없음" 이 아니다.
check_nv "K5 claim 조회실패(unknown)→active" active   "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 unknown)"
# K6 기준 시각 두 축을 **하나도** 못 얻으면(head 빈 값 + claim none) 회수하지 않는다.
check_nv "K6 기준 시각 전무(head 빈 값·claim none)→active" active   "$(run_fc "$GT/no_verdict_empty.json" "" none "$GT/empty.log" 30 none)"
# K7-a **못 읽는 판정 본문** — `머지 판정:` 은 있는데 세 기호가 없다(새 문형·기호 없는 판정).
#      판정이 **있는** PR 이므로 "판정 0건" 주장이 성립하지 않는다 → active(재디스패치 금지).
cat > "$GT/no_verdict_unreadable.json" <<'J'
[
  {"body":"머지 판정: 보류합니다 — 기호 없는 새 문형","createdAt":"2026-07-05T10:05:00Z"}
]
J
check_nv "K7-a 못 읽는 판정 본문(개수 1)→active" active \
  "$(run_fc "$GT/no_verdict_unreadable.json" "$G_OLD" none "$GT/empty.log" 30 none)"
# K7-b 코멘트 JSON 이 배열이 아니다(형상 밖) — 개수를 못 세므로 주장 불가 → active.
printf '%s' '{"comments":[]}' > "$GT/no_verdict_notarray.json"
check_nv "K7-b 코멘트 JSON 이 배열 아님→active" active \
  "$(run_fc "$GT/no_verdict_notarray.json" "$G_OLD" none "$GT/empty.log" 30 none)"

# K7 무회귀 대조 — 같은 증거 전무·버퍼 초과라도 🔄 가 있으면 종전 계급(stale_reverify)이다.
check_nv "K7 🔄 있음·증거 전무→stale_reverify(무회귀)" stale_reverify   "$(run_fc "$GT/bounced_noverifier.json" "$G_OLD" none "$GT/empty.log" 30 none)"

# ── K8 **CI 축**(#421 [P2-2]) — "초록" 은 실패 0 만이 아니라 미완료 0 이기도 하다 ──
# K1 과 다른 것은 미완료 수 하나뿐이다(교락 없음). 진행 증거는 여전히 전무하고 버퍼도 넘겼다 —
# 그런데도 체크가 도는 중이면 이 PR 은 아직 초록이 아니므로 재디스패치 대상이 아니다
# (박스 전역 CI 큐 대기가 정확히 이 모양이다 — #127·#200).
check_nv "K8-a CI 미완료 1건(실패 0)→active" active \
  "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 none 1)"
# K8-b 대조군 — 같은 형상에서 미완료 0 이면 종전대로 이 계급이 열린다(축이 정말 미완료뿐임).
check_nv "K8-b CI 미완료 0(대조군)→no_verdict" no_verdict \
  "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 none 0)"
# K8-c 롤업을 못 읽으면(정수 아님 = 조회 실패 경로) "초록" 을 증명 못 한다 → active.
check_nv "K8-c 롤업 조회 실패(정수 아님)→active" active \
  "$(run_fc "$GT/no_verdict_empty.json" "$G_OLD" none "$GT/empty.log" 30 none boom)"
# K8-d 무회귀 — CI 축 게이트는 `no_verdict` **한 계급에만** 걸린다. 🔄 갈래는 미완료가 있어도
#      종전 판정 그대로다(이 회차가 다른 계급의 출력을 옮기지 않았다는 증거).
check_nv "K8-d 🔄 있음·미완료 1건→stale_reverify(무회귀)" stale_reverify \
  "$(run_fc "$GT/bounced_noverifier.json" "$G_OLD" none "$GT/empty.log" 30 none 1)"

chmod 644 "$GT/unreadable.log" 2>/dev/null || true
rm -rf "$GT"

# ══════════════════════════════════════════════════════════════════════════════
# #308 ⑴ — 반송 마커 판별의 **실호출 자리**(`bounce-state.sh`)를 스텁으로 문다
#
# 위 J 절은 전부 실제 `bounce-state.sh` 를 탄다 — 그 경로만 무는 테스트는 배선이 끊기거나
# 헬퍼가 실패할 때 무슨 일이 나는지 못 본다(#206 회차2 가 `pr-head-at.sh` 에서 정확히 그
# 사각지대를 맞았다). 여기서는 `SCRIPT_DIR`(= `dirname $0`)을 임시 디렉터리로 옮기고
# 그 옆에 스텁 `bounce-state.sh` 를 둬서 **판별기의 결말만** 갈아끼운다.
#
# 무는 것 둘:
#   ⓐ 조회 실패·형상 밖 출력·헬퍼 부재 → 전부 `active`(fail-closed — 마커가 언제인지
#      증명 못 했으면 되돌릴 수 없는 재디스패치를 열지 않는다)
#   ⓑ 그 폴딩이 **일괄적이지 않다** — 스텁이 `ok`(마커 아님)를 내면 클록은 그대로고
#      종전 회수가 살아 있다. ⓐ 만 있으면 "전부 active" 구현도 초록이다.
# ══════════════════════════════════════════════════════════════════════════════
echo "  [#308 ⑴] bounce-state.sh 실호출 자리 — 스텁으로 조회 실패·형상 밖 출력"

BT=$(mktemp -d)
ln -s "$DIR/finish-classify.sh"   "$BT/finish-classify.sh"
ln -s "$DIR/progress-evidence.sh" "$BT/progress-evidence.sh"
ln -s "$DIR/pr-comments.sh"       "$BT/pr-comments.sh"
: > "$BT/empty.log"
# 반송 마커가 **신선**(11:55)한 픽스처 — 스텁이 `bounced` 를 내면 active, `ok` 를 내면
# 클록이 🔄(10:30)에 머물러 stale_reverify 다. 두 행의 차이는 오직 스텁 출력이다.
cat > "$BT/fresh.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: #308 — E2E 1건 실패\n<!-- bodat:worker -->","createdAt":"2026-07-05T11:55:00Z"}
]
J

# write_bounce_stub <exit코드> <stdout 한 줄(빈 문자열이면 무출력)>
write_bounce_stub() {
  cat > "$BT/bounce-state.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BT/args"
cat "\$BOUNCE_COMMENTS_FILE" >> "$BT/input.json"
[ -n '$2' ] && printf '%s\n' '$2'
exit $1
EOF
  chmod +x "$BT/bounce-state.sh"
}

# run_bs <stub-rc> <stub-stdout> — 커밋·CI·claim 증거는 전부 없앤다(마커 축만 남긴다).
run_bs() {
  write_bounce_stub "$1" "$2"
  FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 STALL_MIN=25 ISSUE_TIMEBOX_HOURS=1 \
    FC_COMMENTS_FILE="$BT/fresh.json" FC_HEAD_AT="2026-07-05T10:00:00Z" FC_HEAD_SHA=none \
    FC_QUEUE_LOG="$BT/empty.log" FC_CLAIMED_AT=none \
    "$BT/finish-classify.sh" owner/repo 1 2>/dev/null
}

check_bs() {  # check_bs <name> <expected> <actual>
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ [#308 ⑴] $1 — 기대=$2 실제=$3"; fi
}

: > "$BT/args"; : > "$BT/input.json"
check_bs "J13 스텁 bounced(마커 신선)→active" active "$(run_bs 0 bounced)"
# 인자 계약 — `<repo> <pr>` 로 불렀는지. 배선이 끊기면 여기서 빨개진다.
if grep -qx 'owner/repo 1' "$BT/args"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [#308 ⑴] bounce-state.sh 인자 계약 — 실제=[$(cat "$BT/args")]"; fi
# **한 자리 재사용 계약** — 판별은 로직을 베끼지 않고 `bounce-state.sh` 에 되묻는다.
# 되묻는 입력은 **코멘트 한 건짜리 배열**이어야 한다(그래야 그 한 건이 마커인지만 답한다).
if [ "$(jq -s 'map(length) | unique | .[0]' "$BT/input.json" 2>/dev/null)" = 1 ] \
   && [ "$(jq -s 'map(length) | unique | length' "$BT/input.json" 2>/dev/null)" = 1 ]; then
  pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [#308 ⑴] 되묻는 입력이 한 건짜리 배열이 아니다 — [$(cat "$BT/input.json")]"; fi

# ⓑ 폴딩이 일괄적이지 않다 — 같은 픽스처·같은 종료코드인데 스텁 출력만 `ok` 면 회수한다.
check_bs "J14 스텁 ok(마커 아님)→stale_reverify(클록 불변)" stale_reverify "$(run_bs 0 ok)"
# ⓐ 조회 실패·형상 밖 출력·무출력 → 전부 active.
check_bs "J15 스텁 exit 1(조회 실패)→active" active "$(run_bs 1 "")"
check_bs "J16 스텁 형상 밖 출력→active" active "$(run_bs 0 garbage)"
check_bs "J17 스텁 exit 0·무출력→active" active "$(run_bs 0 "")"
# 헬퍼 **부재**(exit 127)·실행 비트 누락(126)도 같은 갈래다.
rm -f "$BT/bounce-state.sh"
got=$(FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 STALL_MIN=25 ISSUE_TIMEBOX_HOURS=1 \
  FC_COMMENTS_FILE="$BT/fresh.json" FC_HEAD_AT="2026-07-05T10:00:00Z" FC_HEAD_SHA=none \
  FC_QUEUE_LOG="$BT/empty.log" FC_CLAIMED_AT=none \
  "$BT/finish-classify.sh" owner/repo 1 2>/dev/null)
check_bs "J18 bounce-state.sh 부재(exit 127)→active" active "$got"

rm -rf "$BT"


# ══════════════════════════════════════════════════════════════════════════════
# #206 attempt3 — claim 축의 **두 자리**를 따로 문다
#   (1) `claim-at.sh` 자신의 계약(타임라인 → 부착 여부·부착 시각)
#   (2) `finish-classify.sh` 의 **실호출 자리**(`claimed_arg`) — 위 격자는 전부
#       `FC_CLAIMED_AT` 주입 경로라, 주입만 무는 테스트는 그 자리가 회귀해도 초록이다
#       (회차2 가 `pr-head-at.sh` 에서 정확히 그 사각지대를 맞았다).
# ══════════════════════════════════════════════════════════════════════════════
echo "  [#206 attempt3] claim-at.sh 계약 — 부착 여부는 마지막 매칭 인덱스로"

CA="$DIR/claim-at.sh"
ca() {  # ca <name> <expected-stdout> <expected-rc> <timeline-json>
  local name="$1" want="$2" want_rc="$3" json="$4" got rc=0
  got=$(CA_TIMELINE_JSON="$json" "$CA" owner/repo 9 2>/dev/null) || rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [claim-at] $name — 기대=[$want] rc=$want_rc 실제=[$got] rc=$rc"
  fi
}

ca "부착 이력 없음→none" none 0 '[{"event":"labeled","label":{"name":"agent-ready"},"created_at":"2026-07-05T11:00:00Z"}]'
ca "부착됨→그 시각" "2026-07-05T11:55:00Z" 0 \
  '[{"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T11:55:00Z"}]'
# **핵심** — 마지막 이벤트가 해제면 지금은 안 붙어 있다. 부착 이벤트만 세면 이미 떼어진
# claim 이 "살아있는 워커" 로 읽혀 회수가 영영 안 돈다(반대 방향의 사고).
ca "부착 뒤 해제→none" none 0 \
  '[{"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T10:00:00Z"},
    {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T10:30:00Z"}]'
# 해제 뒤 **재부착**(반송 → 디스패처 재투입)이 현실의 정상 형상이다 — 마지막 매칭이 이긴다.
ca "해제 뒤 재부착→나중 시각" "2026-07-05T11:50:00Z" 0 \
  '[{"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T10:00:00Z"},
    {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T10:30:00Z"},
    {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T11:50:00Z"}]'
# 다른 라벨의 이벤트는 섞이지 않는다(`agent-ready` 해제가 claim 해제로 읽히면 안 된다).
ca "다른 라벨 이벤트는 무시" "2026-07-05T11:50:00Z" 0 \
  '[{"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-07-05T11:50:00Z"},
    {"event":"unlabeled","label":{"name":"agent-ready"},"created_at":"2026-07-05T11:55:00Z"}]'
# 조회 실패는 `none` 이 아니다 — 빈 출력 + exit 2(unknown≠none, 회차2 와 같은 규율).
# (빈 문자열 주입은 **실조회로 새므로** 쓰지 않는다 — 파싱 불가·파일 부재 두 갈래로 문다.)
ca "타임라인 JSON 파싱 불가→조회 실패(exit 2)" "" 2 'not-json'
ca_file_rc=0
CA_TIMELINE_FILE="$DIR/does-not-exist.json" "$CA" owner/repo 9 >/dev/null 2>&1 || ca_file_rc=$?
if [ "$ca_file_rc" = 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim-at] CA_TIMELINE_FILE 부재→exit 2 (실제 rc=$ca_file_rc)"; fi
# 이벤트는 있는데 시각이 빈 응답 = 계약 위반. "부착 안 됨" 으로 접지 않는다.
ca "labeled 인데 시각 없음→조회 실패(exit 2)" "" 2 \
  '[{"event":"labeled","label":{"name":"agent:claimed"}}]'

echo "  [#206 attempt3] claimed_arg 실호출 자리 — 스텁 claim-at.sh 로"

CT=$(mktemp -d)
ln -s "$DIR/finish-classify.sh"   "$CT/finish-classify.sh"
ln -s "$DIR/progress-evidence.sh" "$CT/progress-evidence.sh"
ln -s "$DIR/pr-comments.sh"       "$CT/pr-comments.sh"
ln -s "$DIR/bounce-state.sh"      "$CT/bounce-state.sh"   # 반송 마커 판별(#308)
cat > "$CT/bounced.json" <<'J'
[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:30:00Z"},
  {"body":"재검증 실패: E2E 1건 실패 — 반송\n<!-- bodat:worker -->","createdAt":"2026-07-05T10:35:00Z"}
]
J
: > "$CT/empty.log"

# write_claim_stub <exit코드> <stdout 한 줄(빈 문자열이면 무출력)>
write_claim_stub() {
  cat > "$CT/claim-at.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CT/args"
[ -n '$2' ] && printf '%s\n' '$2'
exit $1
EOF
  chmod +x "$CT/claim-at.sh"
}

# run_claim <stub-rc> <stub-stdout> — FC_CLAIMED_AT 를 **주지 않는다**(실호출 경로).
#  FC_HEAD_AT="" + FC_HEAD_SHA=none 으로 커밋·큐 증거는 전부 없앤다 → claim 축만 남는다.
run_claim() {
  write_claim_stub "$1" "$2"
  env -u FC_CLAIMED_AT FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 STALL_MIN=25 \
    ISSUE_TIMEBOX_HOURS=1 FC_ISSUE=9 \
    FC_COMMENTS_FILE="$CT/bounced.json" FC_HEAD_AT="" FC_HEAD_SHA=none \
    FC_QUEUE_LOG="$CT/empty.log" \
    "$CT/finish-classify.sh" owner/repo 1 2>/dev/null
}

check_claim() {  # check_claim <name> <expected> <actual>
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ [claim 실호출] $1 — 기대=$2 실제=$3"; fi
}

: > "$CT/args"
check_claim "claim 5분전→active(첫 푸시 전 창)" active "$(run_claim 0 "$G_CLAIM_5M")"
# 인자 계약 — `<repo> <issue>` 로 불렀는지. 배선이 끊기면(인자 순서·개수 변경) 여기서 빨개진다.
if grep -qx 'owner/repo 9' "$CT/args"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim 실호출] claim-at.sh 인자 계약 — 실제=[$(cat "$CT/args")]"; fi
check_claim "claim 120분전→stale_reverify(회수 무회귀)" stale_reverify "$(run_claim 0 "$G_OLD")"
check_claim "claim none(미부착)→stale_reverify" stale_reverify "$(run_claim 0 none)"
# 헬퍼가 비0으로 죽으면 판정 불가 → active. 실행 비트 누락(126)·부재(127)도 같은 갈래다.
check_claim "claim-at.sh exit 1→active(fail-closed)" active "$(run_claim 1 "")"
check_claim "claim-at.sh exit 0·무출력→active(fail-closed)" active "$(run_claim 0 "")"

# FC_ISSUE 도 위치 인자도 없으면 연결 이슈를 **한 번 묻는다** — 그 호출 계약을 고정한다.
# (조회 실패는 unknown, 빈 결과는 none 으로 갈라야 한다.)
#
# 스텁은 **가공된 번호가 아니라 실제 응답 JSON** 을 낸다 — SUT 가 그 JSON 에서 브랜치
# 이슈를 고르는 술어 자체를 물어야 하기 때문이다(가공된 번호를 주면 `[0]` 이든 head
# 파싱이든 똑같이 초록이라 회귀에 눈먼다).
cat > "$CT/gh" <<'STUB'
#!/bin/sh
printf '%s
' "$*" >> "$GH_CAPTURE"
case "$*" in
  *closingIssuesReferences*)
    [ -n "$STUB_ISSUE_FAIL" ] && exit 1
    [ -n "$STUB_META_EMPTY" ] && exit 0
    printf '%s
' "{\"headRefName\":\"$STUB_HEAD\",\"closingIssuesReferences\":$STUB_REFS}"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$CT/gh"

# 이슈 번호별로 다른 답을 내는 claim 스텁 — **어느 이슈를 물었는지가 판정을 가른다**.
# (109 = 이 브랜치의 이슈, 방금 claim / 108 = 같은 PR 이 닫는 남의 이슈, claim 없음)
write_claim_stub_byissue() {
  cat > "$CT/claim-at.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CT/args"
case "\$2" in
  109) printf '%s\n' '$G_CLAIM_5M' ;;
  *)   printf 'none\n' ;;
esac
exit 0
EOF
  chmod +x "$CT/claim-at.sh"
}

# run_iss <STUB_HEAD> <STUB_REFS> [추가 env 이름=값 …] — 이슈 인자를 **생략**한 실호출.
run_iss() {
  local head="$1" refs="$2"; shift 2
  env -u FC_CLAIMED_AT PATH="$CT:$PATH" GH_CAPTURE="$CT/ghargs" \
    STUB_HEAD="$head" STUB_REFS="$refs" \
    FC_NOW="$NOW" FC_FAILING=0 STALE_FINISH_MIN=30 STALL_MIN=25 ISSUE_TIMEBOX_HOURS=1 \
    FC_COMMENTS_FILE="$CT/bounced.json" FC_HEAD_AT="" FC_HEAD_SHA=none \
    FC_QUEUE_LOG="$CT/empty.log" "$@" \
    "$CT/finish-classify.sh" owner/repo 1 2>/dev/null
}

write_claim_stub 0 "$G_CLAIM_5M"
: > "$CT/ghargs"
got=$(run_iss "session/issues-110-109-108" '[{"number":9}]')
check_claim "이슈 미지정·head 가 agent/issue-* 아님→closingIssuesReferences 폴백" active "$got"
if grep -q 'closingIssuesReferences' "$CT/ghargs"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim 실호출] 연결 이슈 조회 계약 — 실제=[$(cat "$CT/ghargs")]"; fi
# 같은 한 번의 조회로 head 도 받아와야 한다 — 라운드트립을 늘리지 않는다.
if grep -q 'headRefName' "$CT/ghargs"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim 실호출] head 를 같은 조회에서 안 받는다 — 실제=[$(cat "$CT/ghargs")]"; fi
# 연결 이슈 **조회 실패** → unknown(판정 불가) → active. 빈 결과와 섞지 않는다.
got=$(run_iss "agent/issue-9" '[{"number":9}]' STUB_ISSUE_FAIL=1)
check_claim "연결 이슈 조회 실패→active(unknown≠none)" active "$got"
# gh 가 exit 0 인데 **무출력** 인 것도 조회 실패다 — 빈 응답을 "연결 이슈 없음" 으로 접으면
# 조회 한 번 헛돈 것이 살아있는 워커의 claim 을 떼는 근거가 된다(unknown≠none 같은 규율).
got=$(run_iss "agent/issue-9" '[{"number":9}]' STUB_META_EMPTY=1)
check_claim "연결 이슈 조회 무출력→active(unknown≠none)" active "$got"
# 연결 이슈가 **없는** PR(빈 결과)은 조회 실패가 아니다 — claim 증거 없음(none)으로 진행.
got=$(run_iss "fix/사람이-연-브랜치" '[]')
check_claim "연결 이슈 없음(빈 결과)→stale_reverify(증거 없음)" stale_reverify "$got"

# ── 회차3 BLOCKER — `closingIssuesReferences[0]` 은 **브랜치 이슈가 아니다** ──────
# 이 레포 실데이터: PR #113 head=`agent/issue-109` refs=`[108, 109]` — `[0]` 은 #108(남의
# 이슈)이다. 이슈를 **닫는** 것과 이 브랜치의 워커가 **집어간** 것은 다른 축인데, `[0]` 은
# 전자의 순서(GitHub 이 본문의 `Closes` 를 만난 순서)를 후자로 오독한다.
#
# 실패 경로: 이 PR 이 새로 여는 ①-b `bounced` 예외 갈래로 CONFLICTING 반송 PR 이 들어오고,
# 교체 워커는 5분 전 claim 됐지만 첫 푸시 전이다 → `[0]` 이 **#108** 을 물어 claim 이 `none`
# → 증거 ③ 이 조용히 꺼짐 → `stale_reverify` → `closeout-redispatch` 가 **지금 일하고 있는
# 워커의 `agent:claimed` 를 뗀다** → 같은 브랜치에 두 워커(워크트리 경합).
# 이 PR 이 없애려던 사고가 이 PR 이 새로 연 경로에서 재발한다.
write_claim_stub_byissue
got=$(run_iss "agent/issue-109" '[{"number":108},{"number":109}]')
check_claim "head=agent/issue-109·refs=[108,109]→109 로 묻는다(브랜치 이슈)" active "$got"
# 어느 이슈를 물었는지까지 못박는다 — 결과만 보면 우연히 맞을 수 있다.
if grep -qx 'owner/repo 109' "$CT/args"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim 실호출] 브랜치 이슈 인자 — 기대=[owner/repo 109] 실제=[$(cat "$CT/args")]"; fi
# 대조군(실데이터 PR #112) — head 가 `agent/issue-N` 이 **아니면** 폴백 그대로 `[0]`=108 이라
# claim 이 `none` 이다. 이 행이 초록이어야 위 행을 살린 것이 **head 파싱**임이 증명된다
# (둘 다 refs 는 같다 — 다른 것은 head 하나뿐).
: > "$CT/args"
got=$(run_iss "session/issues-110-109-108" '[{"number":108},{"number":109}]')
check_claim "head 가 agent/issue-* 아님·refs=[108,109]→폴백 [0]=108(claim 없음)" stale_reverify "$got"
if grep -qx 'owner/repo 108' "$CT/args"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "  ✗ [claim 실호출] 폴백 인자 — 기대=[owner/repo 108] 실제=[$(cat "$CT/args")]"; fi

rm -rf "$CT"

echo "finish-classify.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
