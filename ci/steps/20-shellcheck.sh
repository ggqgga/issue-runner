#!/usr/bin/env bash
# 단계 2 — shellcheck(설치 시). 미설치 박스에서는 skip 한 줄만 찍고 통과한다.
#
# 실패 시: shellcheck 자신의 진단(파일:줄:열 + SC 코드)을 그대로 찍고 비0 으로 죽는다.
#
# 담은 블록 (원 bin/ci 23–33행 · 분류표 행 2 「ⓓ 도구 단계」 · #427):
#   • [2/12] shellcheck (설치 시)
#
# glob 에 `ci/steps/*.sh ci/lib.sh` 가 들어 있다 — 단계 파일 자신도 검사 대상이다(#524).
# 만료 조건: 없음(린터 단계는 대체물이 없다).
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[2/12] shellcheck (설치 시)"
if command -v shellcheck >/dev/null 2>&1; then
  # `scripts/lib/*.sh` 는 source 전용 라이브러리다 — 소비처의 `# shellcheck source=` 지시로
  # 따라 들어가지만, 라이브러리 자체의 문법·경고도 여기서 직접 문다 (#427).
  # `-x` = source 지시(`# shellcheck source=…`)를 따라 들어간다 — 없으면 라이브러리가
  # 정의하는 변수(`scope_file`)가 소비처에서 SC2154 로 뜬다 (#427).
  shellcheck -x -S warning scripts/*.sh scripts/manual/*.sh scripts/lib/*.sh ci/guards/*.sh ci/steps/*.sh ci/lib.sh hooks/*.sh bin/ci
else
  echo "  shellcheck 미설치 — skip"
fi

