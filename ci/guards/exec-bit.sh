#!/usr/bin/env bash
# 실행비트 가드 — bin/ci 안에 흩어져 있던 인라인 `[ -x <스크립트> ]` 검사 12자리를
# 이 목록 하나로 모은다 (분류표 Plans/ci-guard-classification.md L5 절, #537).
#
# 왜 한 자리인가 — 이 스크립트들은 전부 소비자(다른 스크립트·SKILL 프롬프트)가
# `"$SCRIPT_DIR/<이름>.sh"` 로 **직접 exec** 한다. 실행비트가 빠지면 조용히
# exit 126 으로 죽고, 그 실패가 각 소비자에서 "값이 항상 빈/기본값으로 degrade"
# 라는 서로 다른 모습으로 새어나가(PR#173 교훈) 한곳에서 안 잡히면 12군데를
# 따로 뒤져야 한다. 무는 대상은 파일 하나당 한 줄 — bash 3.2 호환을 위해
# 배열 대신 아래처럼 줄 단위 목록을 쓴다.
#
# 만료 조건: 스크립트 실행비트를 git attributes 나 설치 스크립트(예: 체크아웃
# 훅에서 chmod +x 일괄 적용)가 강제하게 되면 이 가드는 지운다.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0

# scripts/pr-head-at.sh — #171 (bin/ci L5 이전 9-a)
check() {
  [ -x "$1" ] || { echo "  ✗ $1: 실행비트 없음 ($2)"; fail=1; }
}

check scripts/pr-head-at.sh "#171"
check scripts/bounce-state.sh "#196 · #308"
check scripts/attempt-counter.sh "#444"
check scripts/pr-state.sh "#449"
check scripts/bounce-comment.sh "#212 · #221"
check scripts/spinoff-inherit.sh "#261"
check scripts/epic-sweep.sh "#258"
check scripts/progress-evidence.sh "#200 · #206 · #427"
check scripts/claim-at.sh "#206 · #427"
check scripts/timebox-check.sh "#200"
check scripts/lessons-trim.sh "#208"

[ "$fail" = 0 ] || exit 1
