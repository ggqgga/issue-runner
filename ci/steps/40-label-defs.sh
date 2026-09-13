#!/usr/bin/env bash
# 단계 4 — 전이·PR 미러가 쓰는 라벨 다섯의 **정의 존재** 검사(setup-labels.sh).
# 정의가 없으면 transition.sh 의 반송 add 와 claim-issue.sh 의 미러 edit 이 레포에서
# `not found` 로 실패한다 — 라벨 이름은 기계 계약이다.
#
# 실패 시: `  ✗ setup-labels.sh 에 <라벨> 라벨 정의 누락` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 55–62행 · 분류표 행 7 「ⓓ 기계 계약」 · #281):
#   • [closeout] setup-labels.sh 에 harvesting·epic·verifying·flow:agent-ready·flow:claimed 정의
#
# 만료 조건: 이 라벨 목록이 단계 90(분류표 행 84-a)의 목록과 한 자리로 합쳐지고
# scripts/tests/setup-labels.test.sh 가 「세트 전량 생성」 을 행동으로 물면 지운다.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[closeout] setup-labels.sh 에 harvesting·epic·verifying·flow:agent-ready·flow:claimed 라벨 정의 존재 검사"
# flow:agent-ready·flow:claimed(#281) — PR 미러 앞 두 칸. 정의가 없으면 transition.sh 의 반송 add 와
# claim-issue.sh 의 미러 edit 이 레포에서 `not found` 로 실패한다.
for lbl in harvesting epic verifying flow:agent-ready flow:claimed; do
  grep -qF "gh label create $lbl " scripts/setup-labels.sh || {
    echo "  ✗ setup-labels.sh 에 $lbl 라벨 정의 누락"; exit 1; }
done

