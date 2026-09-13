#!/usr/bin/env bash
# 산문 회귀 가드 — bin/ci 안에 흩어져 있던 "문서·스크립트가 옛 형태로 되돌아가지
# 않았는가" 형 검사 일곱 자리를 이 파일 하나로 모은다 (분류표
# Plans/ci-guard-classification.md L6 절, #541 · 대상 행 12-c · 13-c(L6 재판정) ·
# 72-e · 77-b · 81-a(#539 재판정으로 편입) · 81-h(L6 재판정) · 83-c).
#
# 왜 한 자리인가 — 일곱 다 형태가 같다: **금지된 형태가 되살아났는지**(부정 grep)
# 또는 **가리켜야 할 자리를 계속 가리키는지**(포인터 grep)를 문서·스크립트 본문에서
# 본다. 되돌아간 형태는 테스트가 아니라 다음 편집자가 만든다 — 실행 결과에는
# 안 나타나고 다음 편집 때 규칙이 두 벌이 되어야 보인다. 그래서 대체물이 대개 없고
# (있으면 ⓑ 로 폐기됐다) 이 가드가 그 형태의 유일한 강제자다.
#
# 항목 순서는 원 bin/ci 블록 순서다. 검사 코드는 원 블록에서 한 글자도 바꾸지 않고
# 옮겼다 — 부행(-c/-e/-b/-a/-h)인 자리는 그 검사만 떼어 오고 남은 어서션(배선 grep ·
# 행동 스모크 · awk 문단 계약)은 bin/ci 에 그대로 뒀다.
#
# 13-c · 81-h 는 분류표에서 ⓓ(유지)였다 — 대체물이 없어 폐기 대상이 아니라는 뜻이지
# bin/ci 에 남아야 한다는 뜻이 아니다. 둘 다 형태가 12-c 와 같은 부정 grep 이고
# 이 가드가 그 형태의 유일한 강제자라, #541 에서 형태 기준으로 여기로 데려왔다.
set -euo pipefail
cd "$(dirname "$0")/../.."

# 행 12-c — 회차 카운터(`<!-- repair-count: N -->` · `<!-- verify-attempt: N -->`)를
# SKILL 산문이 손으로 읽거나(`--json body`) 손으로 쓰는(`gh pr edit … --body`) 형태
# 금지 (#444). 되살아나면 두 레인의 회차 규칙이 갈리고(한쪽만 고쳐진다) 그 차이는
# 출력에 안 보인다. 배선 grep(attempt-counter.sh 존재)은 bin/ci 에 남겼다.
# 실패 시: 파일명과 "attempt-counter.sh 를 부르라" 를 찍고 exit 1.
# 만료 조건: 두 SKILL 이 회차를 스크립트로만 읽는 형태를 유지하는 한 이 검사가 그 형태의 강제자다.
for f in SKILL.md SKILL.en.md skills/verify-runner/SKILL.md; do
  if grep -nE 'gh pr (view|edit) <pr> --repo <repo> --(json body|body )' "$f" | grep -q .; then
    echo "  ✗ $f: 회차 카운터를 산문으로 직접 읽거나 쓴다 — attempt-counter.sh 를 부르라 (#444)"; exit 1; fi
done

# 행 13-c — 규칙0 산문이 판정 기호에서 목표 `flow:<칸>` 라벨을 직접 유도하는 매핑
# 화살표 금지 (#449). 표(references/state-machine.md)와 두 벌이 되면 라벨이 어긋난
# 뒤에야 보인다(#281 미러가 갈리는 자리). 배선 grep(pr-state.sh · mismatch)과
# 표→진입점 포인터는 bin/ci 에 남겼다.
# 실패 시: 파일명과 "pr-state.sh 의 mismatch 를 쓰라" 를 찍고 exit 1.
# 만료 조건: 한/영 ② Maintain 규칙0 이 매핑을 스크립트에 위임하는 형태를 유지하는 한
# 이 검사가 그 형태의 강제자다.
for f in SKILL.md SKILL.en.md; do
  if grep -nE '(머지 판정|Merge verdict): (✅|🔄)[^\n]*→ *`?flow:' "$f" | grep -q .; then
    echo "  ✗ $f: 규칙0 의 판정→flow 라벨 매핑 산문이 되살아났다 — pr-state.sh 의 mismatch 를 쓰라 (#449)"; exit 1; fi
done

# 행 72-e — finish-classify.sh 호출부 tripwire (#206 · PR#139). head 조회의 종료코드를
# 버리면(`|| head_raw=''`) 실패가 부재로 둔갑한다 — 헬퍼가 3값을 구분해도 호출부가
# 삼키면 계약은 거기서 깨진다. 3값 보존은 head_lookup=unknown 플래그로 기억한다.
# 실패 시: 어느 축(종료코드 버림 · 플래그 부재)인지 찍고 exit 1.
# 만료 조건: pr-head-at.sh 의 3값 계약을 scripts/tests/finish-classify 뮤테이션이
# 호출부까지 덮으면 지운다.
if grep -qE 'pr-head-at\.sh[^|]*\|\|[[:space:]]*head_raw=' scripts/finish-classify.sh; then
  echo "  ✗ finish-classify.sh: pr-head-at.sh 의 종료코드를 버린다(head_rc 로 보존하라)"; exit 1
fi
grep -qF 'head_lookup=unknown' scripts/finish-classify.sh \
  || { echo "  ✗ finish-classify.sh: 조회 실패를 기억하는 head_lookup 플래그가 없다"; exit 1; }

# 행 77-b — 상수 값이 SKILL 로 되살아나지 않았는가 + 값의 자리를 가리키는가 (#427).
# 값은 scripts/lib/constants.sh 한 자리에 있고 SKILL 은 이름과 뜻만 적는다:
#   ⑴ 상수 파일에 기본값이 있는가(SSOT 가 비면 소비처가 `set -u` 로 죽는다)
#   ⑵ SKILL 이 그 이름을 부르고 상수 파일을 가리키는가(디스패처가 값을 찾아갈 경로)
#   ⑶ SKILL 에 `이름 = 숫자` 가 되살아나지 않았는가(두 벌 복원 금지)
# 배선 grep(STALL_MIN·MAX_TIMEBOX_GRACE·timebox-check.sh 존재)은 bin/ci 에 남겼다.
# 실패 시: 어느 파일의 어느 상수가 어느 축에서 어긋났는지 찍고 exit 1.
# 만료 조건: `## 상수` 절이 값을 적지 않는 형태를 유지하는 한 이 검사가 그 형태의 강제자다.
for name in STALL_MIN MAX_TIMEBOX_GRACE ISSUE_TIMEBOX_HOURS; do
  want=$(sed -n "s/^: \"\${$name:=\([0-9][0-9]*\)}\".*/\1/p" scripts/lib/constants.sh | head -1)
  [ -n "$want" ] || { echo "  ✗ scripts/lib/constants.sh 에서 $name 기본값을 읽지 못함"; exit 1; }
  for f in SKILL.md SKILL.en.md; do
    grep -qF "$name" "$f" \
      || { echo "  ✗ $f 에 $name 이름이 없다 — 디스패처가 그 경계를 모른다"; exit 1; }
    grep -qF 'scripts/lib/constants.sh' "$f" \
      || { echo "  ✗ $f 가 값의 자리(scripts/lib/constants.sh)를 가리키지 않는다 (#427)"; exit 1; }
    if grep -qE "\`$name = [0-9]" "$f"; then
      echo "  ✗ $f 가 $name 값을 다시 적었다 — 값은 scripts/lib/constants.sh 한 자리다 (#427)"; exit 1
    fi
  done
done

# 행 81-a — 다섯 운영 문서가 references/live-verification-ladder.md 를 가리킨다 (#147).
# 사다리 참조가 빠지면 워커·검증·마감이 다시 "라이브 항목은 [ ]" 로 도망간다.
# (#539 L3 재판정으로 L6 편입 — loop-conventions §9 는 칸 정의 SSOT 가 그 파일임을
# 명시할 뿐, 운영 문서가 그것을 가리키게 강제하지 않는다.)
# 실패 시: 파일이 없거나 참조가 빠진 문서명을 찍고 exit 1.
# 만료 조건: 없음 — 이 가드가 다섯 문서 → 사다리 포인터의 유일한 강제자다.
[ -f references/live-verification-ladder.md ] || { echo "  ✗ references/live-verification-ladder.md 없음"; exit 1; }
for f in references/worker-template.md references/worker-template.en.md skills/verify-runner/SKILL.md skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qF "live-verification-ladder.md" "$f" || { echo "  ✗ $f: 검증 사다리 참조 없음"; exit 1; }
done

# 행 81-h(쌍 금지 축) — 기계 정지를 `needs-human` + `hold:*` **쌍**으로 서술하는 형태
# 금지 (#244). 전이는 사유 라벨 하나만 붙이는데 문서가 쌍으로 계속 광고하면 다음
# 구현자가 없는 계약을 믿는다. 같은 행의 ①-b·규칙0 `verifying` awk 문단 계약(기계
# 계약)은 bin/ci 에 남겼다 — 형태가 문단 스코프 계약이라 산문 회귀가 아니다.
# 실패 시: 쌍 서술이 남은 파일명을 찍고 exit 1.
# 만료 조건: 없음 — #244 이후 라벨 계약의 문서 쪽 강제자가 이것뿐이다.
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md skills/verify-runner/SKILL.md; do
  if grep -nE '`needs-human` *\+ *`hold:' "$f" | grep -q .; then
    echo "  ✗ $f: 기계 정지를 \`needs-human\` + \`hold:*\` 쌍으로 서술 — #244 이후 전이는 사유 라벨 하나만 붙인다"; exit 1; fi
done

# 행 83-c — loop-status.sh 헤더 주석 계약 3토큰 + 닫힌 이슈 절단 warn 부활 금지 (#292 · #191).
# ⑴ 헤더 주석이 코드와 같은 조건을 광고하는지 — 코드만 좁히면 헤더가 옛 조건을 계속
#    가르친다. 이 루프는 **주석을 일부러 센다**(헤더 동기화가 검사 대상이라서다).
# ⑵ 닫힌 이슈(최근 200건) 절단 warn 이 되살아나면 빨강 — 렌더된 문자열이 아니라
#    후보 목록의 항목을 본다(warn 문구는 jq 보간이라 리터럴이 되돌린 트리에도 없다).
# 코드 줄 전용 조회 형태 검사(⑴ --state closed·is:closed 금지·--limit)는 bin/ci 에 남겼다.
# 실패 시: 빠진 토큰 또는 되살아난 후보 항목을 찍고 exit 1.
# 만료 조건: 없음 — 헤더 주석 계약을 읽는 스크립트가 없다.
for tok in 'EPIC_CLOSED_LIMIT' '종료 미상' '에픽 닫힌 leaf'; do
  grep -qF -- "$tok" scripts/loop-status.sh \
    || { echo "  ✗ scripts/loop-status.sh 헤더/코드에 '$tok' 계약이 없다(#292)"; exit 1; }
done
if grep -nF -- 'what: "닫힌 이슈"' scripts/loop-status.sh; then
  echo "  ✗ 최근 닫힌 200건이 절단 warn 후보 목록에 되살아났다 — bodat 에서 매 틱 뜨는 상시 소음이다(#292/#190)"
  exit 1
fi
