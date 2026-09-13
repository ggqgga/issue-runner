#!/usr/bin/env bash
# hold-resolve.sh 픽스처 격자 테스트 — 네트워크 무접속(모든 입력을 env 로 주입, finish-classify 관행).
#
# closeout ①-c(#334)의 결정론 부분을 **형상 격자**로 못박는다. 옛 회차(PR #203·#337) 가 SKILL 산문의
# 정의식을 파싱해 평가하던 두 테스트(closeout-hold-resolve·closeout-lane-predicate)의 격자를 스크립트
# 위로 옮긴 것이다 — 이제 산문이 아니라 이 스크립트가 판정하므로 문구를 세지 않는다.
#
# 코멘트 배열 표기: 토큰을 콤마로 이은 문자열(인덱스 0 부터). `-` 는 빈 배열.
#   H 보류 경계 · R 반송 마커 · F 완결 판정 · G `마감 검증: ✅ 기각 승계` · P 진행 중(🔄, 완결 아님) ·
#   D 결정문(policy-review: resumed) · U 마커 없는 사람 코멘트(= D) · K policy-review: kept(= 결정 아님) · X 그 밖
# 라벨: 콤마 목록. head: `late` = max(h,r) 코멘트보다 늦음(착수) · `early` = 이름 · `none` = 조회 실패.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/hold-resolve.sh"
command -v jq >/dev/null 2>&1 || { echo "  ✗ jq 미설치"; exit 1; }

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

# 토큰열 → 코멘트 JSON (createdAt 은 인덱스 순 1분 간격, 11:00 부터)
mkjson() {
  local arr="$1" i=0 t body out='['
  [ "$arr" = '-' ] && { echo '[]'; return; }
  IFS=',' read -r -a toks <<<"$arr"
  for t in "${toks[@]}"; do
    case "$t" in
      H) body='마감 검증: ⚠ 보류 — 셋째 갈래가 귀속 미상을 못 잡는다\n<!-- hold-note: policy -->\n<!-- bodat:worker -->' ;;
      R) body='재디스패치: #1 — 사람 재심이 시정 방향(재심: 좁힌다) <!-- bodat:worker -->' ;;
      F) body='머지 판정: ✅ 머지 가능 — CI pass\n<!-- bodat:worker -->' ;;
      G) body='마감 검증: ✅ 기각 승계 — 사람이 판정을 기각(원안 그대로), ③-1 재실행 안 함\n<!-- bodat:worker -->' ;;
      P) body='머지 판정: 🔄 진행 중\n<!-- bodat:worker -->' ;;
      D) body='재심: 좁힌다 — 귀속 미상 표시 자리를 이렇게 고쳐라 <!-- policy-review: resumed --><!-- bodat:worker -->' ;;
      U) body='판정 기각 — 원안 그대로 머지, 코드 변경 없음' ;;
      K) body='재심: 사람 몫 유지 — 스펙 결정 필요 <!-- policy-review: kept --><!-- bodat:worker -->' ;;
      *) body='검증자 리뷰: CLEAN\n<!-- bodat:worker -->' ;;
    esac
    [ "$i" -gt 0 ] && out="$out,"
    out="$out{\"body\":\"$body\",\"createdAt\":\"2026-07-05T11:$(printf '%02d' "$i"):00Z\"}"
    i=$((i + 1))
  done
  echo "$out]"
}

# run <PR열> <이슈열|-> <이슈#|-> <PR 라벨> <이슈 라벨> <head: late|early|none>
GOT=""
run() {
  local head
  case "$6" in late) head='2026-07-05T11:59:00Z' ;; early) head='2026-07-05T10:00:00Z' ;; *) head='' ;; esac
  GOT=$(HR_PR_COMMENTS_JSON="$(mkjson "$1")" HR_ISSUE_COMMENTS_JSON="$(mkjson "$2")" \
        HR_PR_LABELS="$4" HR_ISSUE_LABELS="$5" HR_HEAD_AT="$head" \
        bash "$SUT" owner/repo 42 "$3" 2>&1)
}
first() { printf '%s\n' "$GOT" | head -1; }
ck() { [ "$(first)" = "$2" ] && ok || bad "$1 — 기대=$2 실제=[$(first)]"; }
has() { printf '%s\n' "$GOT" | grep -qF -- "$2" && ok || bad "$1 — '$2' 없음: $GOT"; }

echo "── 격자 (SKILL ①-c 행 번호는 #334 옛 격자 기준) ─────────────────────────"
# id | PR열 | 이슈열 | 이슈# | PR라벨 | 이슈라벨 | head | want | 행
GRID='
no_hold_no_H|X,F|X|1|flow:ready|agent-ready|early|pick|1
no_hold_H|X,F|X|1|hold:policy|agent-ready|early|keep|2
resolved|H,F|H|1|-|agent-ready|early|pick|3
resolved_H_left|H,F|H|1|-|agent-ready,hold:policy|early|keep|4
stale_f_bounced_lane|H,F,R|H|1|-|agent:claimed|early|active|5
progress_not_done|H,P|H|1|-|agent-ready|early|ambiguous|6
new_commit_after_bounce|H,R|H|1|-|agent:claimed|late|active|7
new_commit_bounce_noone|H,R|H|1|-|-|late|active|8
new_commit_lane|H|H|1|-|flow:verify|late|active|9
new_commit_noone|H|H|1|-|agent-ready|late|ambiguous|10
head_lookup_fail|H|H|1|-|flow:verify|none|blocked|11
idem_new_worker|H,R|H|1|-|agent:claimed|early|active|12
idem_transition_failed|H,R|H|1|-|hold:policy|early|recall|13
idem_verify_lane|H,R|H|1|-|flow:verify|early|active|14
marker_before_hold|R,H|H,D|1|-|agent-ready|early|direction|15
both_decided|H|H,D|1|-|agent-ready|early|direction|17
decided_labels_stay|H|H,D|1|-|agent-ready,hold:policy|early|keep|18
released_no_decision|H|H|1|-|agent-ready|early|ambiguous|19
decision_on_pr_only|H,U|H|1|-|agent-ready|early|direction|20
worker_hold_released|H|-|1|-|agent-ready|early|ambiguous|23
idem_target_state|H,R|H|1|-|agent-ready|early|active|26
idem_agent_ready_removed|H,R|H|1|-|-|early|recall|27
issue_only|X,X,X,X,X,F|X,X,H,D|1|-|agent-ready|early|restore|28
issue_only_H|F|H,D|1|-|agent-ready,hold:policy|early|keep|29
issue_only_r_f|R,F|H,H|1|-|agent-ready|early|restore|30
restored_then_d|H|H,H,D|1|-|agent-ready|early|direction|32
restored_d_before|H|D,H|1|-|agent-ready|early|ambiguous|33
kept_is_not_decision|H|H,K|1|-|agent-ready|early|ambiguous|-
inherit_marker_step2|H,G|H|1|-|agent-ready|early|pick|-
no_issue_idem|H,R|-|-|-|-|early|ambiguous|24
'
printf '%s\n' "$GRID" | while IFS='|' read -r id pr is num prl isl head want row; do
  [ -z "$id" ] && continue
  run "$pr" "$is" "$num" "$prl" "$isl" "$head"
  if [ "$(first)" = "$want" ]; then echo "  ok   $id (행 $row) → $want"; else echo "  FAIL $id (행 $row) — 기대=$want 실제=[$(first)]"; fi
done > "${TMPDIR:-/tmp}/hold-resolve-grid.$$"
n=$(grep -c '^  ok ' "${TMPDIR:-/tmp}/hold-resolve-grid.$$" || true); pass=$((pass + n))
grep '^  FAIL' "${TMPDIR:-/tmp}/hold-resolve-grid.$$" | sed 's/^  FAIL/  ✗/' || true
nf=$(grep -c '^  FAIL' "${TMPDIR:-/tmp}/hold-resolve-grid.$$" || true); fail=$((fail + nf))
[ "$n" -ge 30 ] || { fail=$((fail + 1)); echo "  ✗ 격자가 통째로 안 돌았다(ok ${n}행 < 30)"; }
rm -f "${TMPDIR:-/tmp}/hold-resolve-grid.$$"

echo "── 출력 계약 ────────────────────────────────────────────────────────────"
run 'H' 'H,D' 1 '-' 'agent-ready' early
has "direction 은 이슈 결정문 본문을 한 줄로 낸다" 'issue_decision: 재심: 좁힌다 — 귀속 미상 표시 자리를 이렇게 고쳐라'
run 'H,U' 'H' 1 '-' 'agent-ready' early
has "direction 은 PR 결정문도 낸다" 'pr_decision: 판정 기각 — 원안 그대로 머지, 코드 변경 없음'
run 'H,G' 'H' 1 '-' 'agent-ready' early
has "기각 승계 ✅ 는 resume: step2 를 덧붙인다" 'resume: step2'
run 'H' 'H' 1 '-' 'agent-ready' early
has "ambiguous 사유" 'reason: no_decision'
run 'H' 'H' 1 '-' 'flow:verify' none
has "blocked 사유" 'reason: head_lookup'
GOT=$(HR_PR_COMMENTS_JSON=none HR_ISSUE_COMMENTS_JSON='[]' HR_PR_LABELS='-' HR_ISSUE_LABELS='-' HR_HEAD_AT='' bash "$SUT" owner/repo 42 1 2>&1)
ck "코멘트 조회 실패 → blocked" blocked; has "코멘트 조회 실패 사유" 'reason: comments_lookup'
GOT=$(HR_PR_COMMENTS_JSON='[]' HR_ISSUE_COMMENTS_JSON='[]' HR_PR_LABELS=none HR_ISSUE_LABELS='-' HR_HEAD_AT='' bash "$SUT" owner/repo 42 1 2>&1)
ck "라벨 조회 실패 → blocked" blocked
bash "$SUT" owner/repo >/dev/null 2>&1; rc=$?; [ "$rc" = 64 ] && ok || bad "인자 부족 exit $rc (기대 64)"
[ -x "$SUT" ] && ok || bad "hold-resolve.sh 실행 비트 없음"

echo "── 형상 불변식 ──────────────────────────────────────────────────────────"
# ⑴ 이슈측 단독 경계: 결론은 r·f·D 어느 것에도 의존하지 않고 H 로만 갈린다.
for pr in '-' 'F' 'R' 'R,F' 'X,X,X,X,X,F'; do
  run "$pr" 'H,D' 1 '-' 'agent-ready' early; [ "$(first)" = restore ] || bad "불변식⑴ PR=$pr H=0 → restore 아님: $(first)"
  run "$pr" 'H,D' 1 '-' 'agent-ready,hold:policy' early; [ "$(first)" = keep ] || bad "불변식⑴ PR=$pr H=1 → keep 아님: $(first)"
done; ok
# ⑵ 양측 경계 정상에서 낡은 F(경계 앞)는 어떤 r 형상에서도 해소가 아니다.
for pr in 'F,H' 'F,H,R' 'F,R,H'; do
  run "$pr" 'H' 1 '-' 'agent-ready' early; [ "$(first)" != pick ] || bad "불변식⑵ PR=$pr 낡은 F 가 해소로 새었다"
done; ok
# ⑶ 하류 활성 레인 다섯 중 무엇이든 A 를 참으로 만들어 멱등 분기가 active 다(agent-ready 는 아니다).
for l in agent:claimed flow:verify verifying flow:ready harvesting; do
  run 'H,R' 'H' 1 '-' "$l" early; [ "$(first)" = active ] || bad "불변식⑶ 라벨 $l → active 아님: $(first)"
done; ok
run 'H,R' 'H' 1 '-' '' early; [ "$(first)" = recall ] || bad "불변식⑶ 라벨 0 → recall 아님: $(first)"
ok

echo "hold-resolve.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
