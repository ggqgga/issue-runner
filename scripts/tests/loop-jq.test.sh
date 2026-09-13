#!/usr/bin/env bash
# scripts/lib/loop.jq 술어 격자 (#426, 플랜 1단계).
#
# 이 파일은 **라이브러리 자체**를 문다 — 소비처 테스트(closeout-eligible·bounce-state·
# finish-classify …)는 그 스크립트의 판정을 물지, 술어 하나하나의 경계(한/영·마커 위치·
# 빈 배열·null 본문)를 전수로 묻지 않는다. 한 자리로 모은 술어가 조용히 넓어지거나
# 좁아지면 그 순간 열한 소비처가 같은 방향으로 함께 틀어지므로 여기서 격자를 건다.
#
# 뮤테이션 1건(MUT-M): `is_machine` 에 영문 접두를 더한 **합집합** 판을 만들어, 그것이
# 실제로 판정을 바꾼다는 것을 보인다 — 그래서 loop.jq 가 한글 접두로 동결돼 있는 것이
# 취향이 아니라 게이트 방향(fail-open 금지) 문제임을 테스트가 증언한다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/lib"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# p <이름> <기대> <술어> <입력 JSON>  — 술어를 그 입력에 먹여 true/false/err 를 본다.
p() {
  local name="$1" want="$2" filter="$3" input="$4" got
  got=$(printf '%s' "$input" | jq -L "$LIB" -r "include \"loop\"; $filter" 2>/dev/null) || got=err
  [ -n "$got" ] || got=empty
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$want 실제=$got  [$filter] <<< $input"
  fi
}

echo "  [격자 ①] 판정 코멘트 — 기호까지 정확히·한영 병행"
for pair in 'is_verdict_ok:✅' 'is_verdict_pending:🔄' 'is_verdict_hold:⚠'; do
  pred=${pair%%:*}; sym=${pair#*:}
  p "$pred ko"        true  "$pred" "\"머지 판정: $sym 사유\""
  p "$pred en"        true  "$pred" "\"Merge verdict: $sym reason\""
  p "$pred 다른기호"   false "$pred" '"머지 판정: 🚧 사유"'
  p "$pred 접두만"     false "$pred" '"머지 판정 완료"'
  p "$pred 중간등장"   false "$pred" "\"보고합니다\n머지 판정: $sym\""
  p "$pred null본문"   err   "$pred" 'null'
done
p "is_verdict_any ✅"        true  is_verdict_any '"머지 판정: ✅ 가능"'
p "is_verdict_any ⚠(en)"    true  is_verdict_any '"Merge verdict: ⚠ hold"'
p "is_verdict_any 접두만"    false is_verdict_any '"머지 판정 재심 예정"'
p "is_verdict_any 사람코멘트" false is_verdict_any '"이 부분 다시 확인 부탁드립니다"'

echo "  [격자 ②] 접두 술어 — 기호 없이 '판정성 코멘트인가'"
p "has_verdict_prefix ko"   true  has_verdict_prefix '"머지 판정 재심 예정"'
p "has_verdict_prefix en"   true  has_verdict_prefix '"Merge verdict: ✅ ok"'
p "has_verdict_prefix 아님"  false has_verdict_prefix '"검증자 리뷰: CLEAN"'
p "has_verifier_prefix ko"  true  has_verifier_prefix '"검증자 리뷰: BLOCKER 1건"'
p "has_verifier_prefix en"  true  has_verifier_prefix '"Verifier review: CLEAN"'
p "has_closeout_prefix"     true  has_closeout_prefix '"마감 검증: ⚠ 보류 — 사유"'
p "is_closeout_ok ✅"        true  is_closeout_ok '"마감 검증: ✅ 통과"'
p "is_closeout_ok ⚠보류"     false is_closeout_ok '"마감 검증: ⚠ 보류 — 사유"'

echo "  [격자 ③] 머신 코멘트 — 센티널은 위치 무관·레거시 3접두는 한글 동결"
p "센티널 마지막줄"    true  is_machine '"보정했습니다\n<!-- bodat:worker -->"'
p "센티널 중간"        true  is_machine '"앞\n<!-- bodat:worker -->\n뒤"'
p "센티널 맨앞"        true  is_machine '"<!-- bodat:worker --> 노트"'
p "레거시 머지 판정"    true  is_machine '"머지 판정: ✅ 가능"'
p "레거시 검증자 리뷰"  true  is_machine '"검증자 리뷰: CLEAN"'
p "레거시 마감 검증"    true  is_machine '"마감 검증: ✅"'
# ↓ 이 두 줄이 "한글 동결" 의 실물이다 — 영문 머신 코멘트는 **마커가 있어야만** 머신이다.
p "영문 접두(마커 없음)" false is_machine '"Merge verdict: ✅ mergeable"'
p "영문 접두(마커 있음)" true  is_machine '"Merge verdict: ✅ mergeable\n<!-- bodat:worker -->"'
p "사람 코멘트"         false is_machine '"이 부분 다시 확인 부탁드립니다"'
p "빈 문자열"           false is_machine '""'

echo "  [격자 ④] 반송 접두 — 콜론을 요구하지 않는다"
p "재디스패치 콜론"     true  is_bounce '"재디스패치: #218 — 완결 유실"'
p "재디스패치 무콜론"   true  is_bounce '"재디스패치 attempt 3 — E2E 실패"'
p "재검증 실패"         true  is_bounce '"재검증 실패: #193 — 사유 (attempt 2)"'
p "중간 등장"           false is_bounce '"이 PR 은 재디스패치 대상입니다"'
p "판정 코멘트"         false is_bounce '"머지 판정: ✅ 가능"'

echo "  [격자 ⑤] last_index — 마지막 매칭·부재·빈 배열·본문 위치"
li='last_index(is_verdict_ok)'
p "마지막 매칭(둘 중 뒤)" 2 "$li" '["머지 판정: ✅ 1","반송","머지 판정: ✅ 2"]'
p "하나뿐"               0 "$li" '["머지 판정: ✅ 1","기타"]'
p "부재 → null"          null "$li" '["기타","머지 판정: ⚠ 보류"]'
p "빈 배열 → null"       null "$li" '[]'
p "부재 + // empty"      empty "$li // empty" '["기타"]'
# 객체 배열(코멘트 원형)에도 같은 술어를 본문 경로만 얹어 쓴다.
p "객체 배열 .body"      1 'last_index(.body | is_verdict_ok)' \
  '[{"body":"기타"},{"body":"머지 판정: ✅ ok"}]'
# ✅ 뒤에 더 늦은 ⚠ 가 오면 **⚠ 가 마지막**이다 — 존재 검사로 대신하면 못 보는 그 함정(#218).
p "✅ 뒤의 늦은 ⚠"       2 'last_index(is_verdict_hold)' \
  '["기타","머지 판정: ✅ ok","머지 판정: ⚠ 보류"]'
p "null 본문 섞임"       err "$li" '["머지 판정: ✅ ok",null]'

echo "  [격자 ⑥] 라벨 집합 — 접두 판별·과잉 제외 금지"
p "hold 접두"            true  'any(is_hold_label)'  '["hold:ladder"]'
p "hold 아닌 유사어"      false 'any(is_hold_label)'  '["holding","on-hold","area:hold","hold-ladder","holder:x"]'
p "needs-human"          true  'any(is_stop_label)'  '["needs-human"]'
p "정지 라벨 없음"        false 'any(is_stop_label)'  '["agent-ready","P1"]'
p "쉼표 품은 라벨명"      false 'any(is_stop_label)'  '["a,needs-human"]'
p "stop_labels 추출"     '["hold:policy","needs-human"]' 'stop_labels | sort | tojson' \
  '["P1","needs-human","hold:policy","flow:verify"]'
p "hold_labels 추출"     '["hold:policy"]' 'hold_labels | tojson' '["needs-human","hold:policy"]'
p "owner_labels — 대기칸 제외" '["flow:verify","harvesting"]' 'owner_labels | tojson' \
  '["flow:agent-ready","flow:verify","harvesting","agent-ready"]'
p "stage_labels"         '["flow:agent-ready","flow:ready"]' 'stage_labels | tojson' \
  '["flow:agent-ready","verifying","flow:ready"]'
p "downstream 4벌"       true  'any(is_downstream_label)' '["verifying"]'
p "downstream 유사어"     false 'any(is_downstream_label)' '["verified","verifying-x","flow:codex"]'

echo "  [격자 ⑦] short_repo"
p "issue-runner 특례"    runner  short_repo '"ggqgga/issue-runner"'
p "대문자 레포"          bodat   short_repo '"ggqgga/BoDAT"'
p "owner 없음"           plain   short_repo '"plain"'

echo "  [격자 ⑧] linked_issue — PR 연결 이슈 한 술어 (#495)"
# head `agent/issue-N` 이 refs 에 있으면 그것 · 없으면 refs 가 정확히 1건일 때 그것 · 그 외 null.
# 실데이터 PR #113(head agent/issue-109 · refs [108,109]) — `[0]` 이면 남의 이슈 #108 이다.
li='linked_issue(.head; .refs)'
p "head 있음·refs 다수 → head 의 N"   109  "$li" '{"head":"agent/issue-109","refs":[108,109]}'
p "head 없음·refs 1 → 그 1건"        108  "$li" '{"head":"session/issues-110-109-108","refs":[108]}'
p "head 없음·refs 다수 → null(fail-closed)" null "$li" '{"head":"session/issues-110-109-108","refs":[108,109]}'
# head 만으로는 짝을 세우지 않는다 — `Refs #N`·`(no-issue)` PR(refs 빈 배열)은 이슈 축을 포기한다.
# head 단독 폴백을 되살리는 뮤테이션이 여기서 빨개진다(§5 규약 — 결정 근거는 loop.jq 머리 주석).
p "head 있음·refs 빈 → null(head 단독 폴백 없음)" null "$li" '{"head":"agent/issue-109","refs":[]}'

# ── 뮤테이션 방증 (MUT-M) — is_machine 을 한/영 **합집합**으로 넓히면 판정이 바뀐다 ──
# 넓힌 판에서 "영문 접두(마커 없음)" 행만 뒤집히고 나머지는 그대로여야 한다: 그래야
# 이 동결이 취향이 아니라 **게이트 방향**(미해결 사람 리뷰 수가 줄어 머지가 열린다)의
# 문제라는 증언이 된다. 앵커는 술어 본문 줄 하나이고, 정확히 한 줄만 바뀌는지도 센다.
mut="$tmp/loop.jq"
sed 's@^  or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증");@  or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증")\n  or startswith("Merge verdict") or startswith("Verifier review");@' \
  "$LIB/loop.jq" > "$mut"
changed=$(diff "$LIB/loop.jq" "$mut" | grep -c '^< ' || true)
if [ "$changed" = 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 앵커(MUT-M) 가 정확히 한 줄을 바꾸지 않았다(바뀐 줄=$changed)"
fi
mut_run() {  # mut_run <이름> <기대> <입력>
  local name="$1" want="$2" input="$3" got
  got=$(printf '%s' "$input" | jq -L "$tmp" -r 'include "loop"; is_machine' 2>/dev/null) || got=err
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ [MUT-M] $name — 기대=$want 실제=$got"
  fi
}
echo "  [뮤테이션] is_machine 합집합 판 — 영문 행만 뒤집힌다"
mut_run "영문 접두(마커 없음) → true 로 뒤집힘" true  '"Merge verdict: ✅ mergeable"'
mut_run "사람 코멘트 — 대조군 불변"              false '"이 부분 다시 확인 부탁드립니다"'
mut_run "한글 레거시 — 대조군 불변"              true  '"머지 판정: ✅ 가능"'

echo "loop-jq: $pass passed, $fail failed"
[ "$fail" = 0 ]
