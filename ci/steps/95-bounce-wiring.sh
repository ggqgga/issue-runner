#!/usr/bin/env bash
# 단계 12 — 반송 마커 시각이 스테일 클록의 네 번째 입력이라는 배선. finish-classify.sh
# 가 bounce-state.sh 에 마커 판별을 **되묻는** 호출이 사라지면 반송 직후 라벨 공백 창이
# 다시 열려 살아 있는 반송 회차에 `완결 유실(검증 전 사망)` 이 찍힌다.
#
# 실패 시: `  ✗ scripts/finish-classify.sh 에 bounce-state.sh 되묻기 배선 없음` + exit 1.
#
# 담은 블록 (원 bin/ci 643–650행 · 분류표 행 85 · 부행 85-a · #308):
#   • [#308] 반송 마커 시각 = 스테일 클록의 네 번째 입력 (판별 되묻기 배선)
#
# 행동 축(85-c)은 scripts/tests/finish-classify.test.sh 의 #308 픽스처, 산문 축(85-d)은
# references/closeout-rationale.md §7 이 인수했다(L3).
#
# 만료 조건: finish-classify.test.sh 가 「되묻기 호출이 사라지면 빨강」 을 뮤테이션으로
# 물면 즉시(현재 격자는 판정 결과만 보고 호출 경로의 부재는 못 본다).
set -euo pipefail
cd "$(dirname "$0")/../.."

# [#308] 반송 마커 시각이 스테일 클록에 든다 — 판별은 bounce-state.sh 한 자리
echo "[#308] 반송 마커 시각 = 스테일 클록의 네 번째 입력 (판별 되묻기 배선)"
# 배선 — `finish-classify.sh` 는 마커 판별을 **되묻는다**. 이 호출이 사라지면 반송 직후
# 라벨 공백 창이 다시 열려 살아 있는 반송 회차에 `완결 유실(검증 전 사망)` 이 찍힌다.
grep -qF 'bounce-state.sh' scripts/finish-classify.sh \
  || { echo "  ✗ scripts/finish-classify.sh 에 bounce-state.sh 되묻기 배선 없음"; exit 1; }
# 마커 집합 정의가 한 자리인지는 위 `[closeout] 반송 마커 집합은 bounce-state.sh 한 자리`
# 블록이 이미 전수로 검사한다 — 여기 두 번째 술어를 만들지 않는다(PR#216 규율).
