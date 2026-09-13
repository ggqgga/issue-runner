#!/usr/bin/env bash
# 단계 8 — 진행 증거·타임박스 축의 **배선** 검사(+ 그 축의 격자 러너 둘). 판정 자체는
# progress-evidence.sh·claim-at.sh·timebox-check.sh 안에 있고, 여기서 무는 것은
# 「소비자가 그 한 자리를 실제로 부르는가」 다 — 호출이 사라지면 판정이 항상 빈 값이
# 되고 그 degrade 는 출력에 안 보인다(timebox 는 unknown, finish-classify 는 active 로 샌다).
#
# 실패 시: `  ✗ <파일> 에 <토큰> 배선 없음` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 380–444행):
#   • [#206] 진행 증거 술어는 progress-evidence.sh 한 자리 (행 71 · 부행 71-c · #200→#206)
#   • [#206] 현재 회차 시작 증거 — claim-at.sh 한 자리     (행 72 · 부행 72-b · #427)
#   • [test] timebox-check.sh 격자                          (행 75 · #200)
#   • [test] lessons-trim.sh 격자                           (행 76 · #208)
#   • [#200] timebox 진행 증거 판정 배선 — 한/영 SKILL 동기 (행 77 · 부행 77-a)
#
# 만료 조건 — 배선 축(71-c·72-b·77-a): 그 계약이 SKILL 산문이 아니라 스크립트 인자로
# 옮겨질 때. 러너 둘: 없음(격자가 자기 대체물).
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[#206] 진행 증거 술어는 progress-evidence.sh 한 자리 (#200 → #206)"
# 커밋 신선도(STALL_MIN)와 CI 큐 티켓 판정을 다른 스크립트가 자기 벌로 들고 있으면 언젠가
# 한쪽만 고쳐져 두 소비자(timebox-check · finish-classify)가 다른 수를 센다 — 반송 마커
# 집합을 bounce-state.sh 한 자리에 묶은 것과 같은 규율(PR#191 교훈).
# 판정선은 **정의**다: 산문·주석의 언급(`STALL_MIN 이내` 등)은 사본이 아니므로 안 건다.
# (#427) `STALL_MIN` 의 값 정의는 `scripts/lib/constants.sh` 로 옮겼다 — 술어(`queue_alive`)는
# 여전히 progress-evidence.sh 한 자리다. 두 파일 밖에 정의가 생기면 여기서 빨개진다.
# 소비자 둘이 `"$SCRIPT_DIR/progress-evidence.sh"` 를 실제로 부르는지(배선). 호출이
# 사라지면 판정이 항상 빈 값이 되고, 그 degrade 가 timebox 는 unknown, finish-classify 는
# active 로 조용히 새어 완결 유실 회수가 통째로 멈춘다. (실행 비트는 ci/guards/exec-bit.sh.)
for f in scripts/timebox-check.sh scripts/finish-classify.sh; do
  grep -qF 'progress-evidence.sh' "$f" || { echo "  ✗ $f 에 progress-evidence.sh 배선 없음"; exit 1; }
done

echo "[#206] 현재 회차 시작 증거 — claim-at.sh 한 자리·ISSUE_TIMEBOX_HOURS 드리프트"
# `agent:claimed` 의 **부착 시각**은 첫 푸시 전 창을 덮는 유일한 신호다(#206 attempt 3
# codex BLOCKER). 조회가 한 자리(claim-at.sh)에 있어야 "존재로 판정하지 않는다"(#196 3항)와
# "부착 시각으로 판정한다"(#206)가 한 문서에서 갈리지 않는다.
# finish-classify 가 실제로 그 자리를 부르는지(배선). `claimed_arg` 가 사라지면 진행 증거
# ③ 이 조용히 꺼지고 격자 I 절만 빨개지는 게 아니라 **실호출 경로가 통째로 없어진다**.
# 패턴은 `-e` 로 넘긴다 — 맨몸으로 넘기면 `--claimed-at` 이 grep 옵션으로 먹혀 가드가
# 통과가 아니라 **usage 로 죽는다**(progress-evidence.sh:queue_alive 가 같은 함정을 주석에
# 적어 뒀다 — PR#202 교훈의 재판).
for token in 'claim-at.sh' 'claimed_arg' '--claimed-at'; do
  grep -qF -e "$token" -- scripts/finish-classify.sh \
    || { echo "  ✗ scripts/finish-classify.sh 에 $token 배선 없음"; exit 1; }
done
grep -qF -e '--claimed-at' -- scripts/progress-evidence.sh \
  || { echo "  ✗ scripts/progress-evidence.sh 에 --claimed-at 입력 없음"; exit 1; }
# claim 신선도 상한은 timebox 와 **같은 상수**다(두 자리가 같은 경계를 쓴다는 계약).
# 기본값이 갈리면 스윕과 ① Reconcile 이 서로 다른 창에서 같은 워커를 살리고 죽인다.
# (#427) 기본값의 한 자리는 `scripts/lib/constants.sh` 의 `: "${ISSUE_TIMEBOX_HOURS:=1}"` 다.
# 두 리더(timebox-check·progress-evidence)가 자기 기본값을 되살리면 이 검사가 2건을 본다.
# 호출부 tripwire — head 조회의 **종료코드를 버리면**(`|| head_raw=''`) 실패가 부재로
# 둔갑한다(PR#139). 헬퍼가 아무리 3값을 구분해도 호출부가 삼키면 계약은 거기서 깨진다.

echo "[test] timebox-check.sh 진행 증거 판정·queue.log 마지막 줄·유예 상한 (#200)"
# 디스패처가 `"$SCRIPTS/timebox-check.sh"` 로 직접 exec 하므로 실행 비트도 여기서 문다
# (비트가 빠지면 조용히 exit 126 → 판정 줄이 빈 값이 되고 그 이슈의 timebox 가 무판정으로 샌다).
bash scripts/tests/timebox-check.test.sh

echo "[test] lessons-trim.sh lessons-verifier.md 캡 수렴 정리 — 항목 정의·오래된 순 삭제·멱등·append 잠금 (#208)"
# closeout 1·6단계가 append 직후 `$SCRIPTS/lessons-trim.sh append <파일> 20 "<줄>"`
# 한 자리로 부르는 계약이므로 실행 비트도 여기서 문다(비트가 빠지면 exit 126 → 캡
# 정리가 조용히 no-op 으로 degrade, PR#173 교훈과 동일 함정).
bash scripts/tests/lessons-trim.test.sh

echo "[#200] timebox 진행 증거 판정 배선 검사 — 한/영 SKILL 동기"
# 상수(STALL_MIN·MAX_TIMEBOX_GRACE) + 판정자 호출이 한/영 양쪽에 있어야 한다. 스크립트만
# 고치고 프롬프트에 옛 규칙("경과가 넘으면 중단")이 남으면 **디스패처는 옛 규칙을 따른다** —
# 이 루프에서 실제로 판정하는 것은 프롬프트다.
for f in SKILL.md SKILL.en.md; do
  for token in 'STALL_MIN' 'MAX_TIMEBOX_GRACE' 'timebox-check.sh'; do
    grep -qF "$token" "$f" \
      || { echo "  ✗ $f 에 $token 배선 없음"; exit 1; }
  done
done
# 값 드리프트 검사 — 종전엔 "스크립트 기본값 == SKILL 이 적은 값" 을 대조했다. (#427) 이제
# 값은 `scripts/lib/constants.sh` **한 자리**에만 있고 SKILL 은 이름과 뜻만 적으므로, 대조 대신
# **값이 문서로 되살아나지 않았는지**를 문다 — 두 벌이 없으면 드리프트도 없다.
#   ⑴ 상수 파일에 기본값이 있는가(SSOT 가 비면 소비처가 `set -u` 로 죽는다)
#   ⑵ SKILL 이 그 이름을 부르고 상수 파일을 가리키는가(디스패처가 값을 찾아갈 경로)
#   ⑶ SKILL 에 `이름 = 숫자` 가 되살아나지 않았는가(두 벌 복원 금지)
# 만료 조건: `## 상수` 절이 값을 적지 않는 형태를 유지하는 한 이 검사가 그 형태의 강제자다.

