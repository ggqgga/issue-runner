#!/usr/bin/env bash
# 단계 3 — ci/guards/*.sh 일곱 가드 호출 묶음. 판정 코드는 전부 가드 파일 안에 있고
# 이 단계는 순서대로 부르기만 한다(`[guard] …` 줄 하나 + `bash ci/guards/<x>.sh`).
#
# 실패 시: 부른 가드가 자기 `  ✗ …` 진단을 찍고 비0 → `set -e` 로 그 자리에서 정지.
#
# 담은 블록 (원 bin/ci 34–54행 · 전부 L4·L5·L6 leaf 가 만든 가드의 호출부):
#   • [guard] 실행비트 목록          — ci/guards/exec-bit.sh          (분류표 L5)
#   • [guard] 단일 정의 불변식       — ci/guards/single-definition.sh (분류표 L4 · #540)
#   • [guard] heredoc 린트           — ci/guards/heredoc-lint.sh      (#119 · L6)
#   • [guard] 한/영 구조 동기화      — ci/guards/ko-en-sync.sh        (L6 · 행 5)
#   • [guard] 산문 회귀              — ci/guards/prose-regression.sh  (#541 · L6)
#   • [guard] 워커 반송 해소 보고 접두 — ci/guards/worker-report-prefix.sh (#251 ② · L6)
#   • [guard] §N 포인터 실재         — ci/guards/section-pointers.sh  (#507 · #451 · #453)
#
# 만료 조건: 가드 파일마다 자기 머리·항목 주석에 적혀 있다(이 호출부는 그 파일이
# 사라질 때 같이 지운다). retire 정책 전문은 ci/README.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[guard] 실행비트 목록 (ci/guards/exec-bit.sh)"
bash ci/guards/exec-bit.sh

echo "[guard] 단일 정의 불변식 (ci/guards/single-definition.sh)"
bash ci/guards/single-definition.sh

echo "[guard] heredoc 린트 (ci/guards/heredoc-lint.sh)"
bash ci/guards/heredoc-lint.sh

echo "[guard] 한/영 구조 동기화 (ci/guards/ko-en-sync.sh)"
bash ci/guards/ko-en-sync.sh

echo "[guard] 산문 회귀 (ci/guards/prose-regression.sh)"
bash ci/guards/prose-regression.sh

echo "[guard] 워커 반송 해소 보고 접두 (ci/guards/worker-report-prefix.sh)"
bash ci/guards/worker-report-prefix.sh

echo "[guard] §N 포인터 실재 (ci/guards/section-pointers.sh)"
bash ci/guards/section-pointers.sh

