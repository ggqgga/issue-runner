#!/usr/bin/env bash
# 단계 1 — bash 문법 검사(bash -n). 모든 셸 소스가 파싱되는지만 본다.
#
# 실패 시: 파싱 실패한 파일마다 `  ✗ <파일>` 한 줄(그 앞에 bash 자신의 문법 진단)을
# 찍고 루프 끝에서 exit 1 — 한 파일이 깨져도 나머지를 다 훑고 목록으로 보여준다.
#
# 담은 블록 (원 bin/ci 13–22행 · 분류표 행 1 「ⓓ 도구 단계」):
#   • [1/12] bash 문법 검사 (bash -n) — 원 이슈 없음(도구 단계)
#
# glob 에 `ci/steps/*.sh ci/lib.sh` 가 들어 있다 — 단계 파일 자신도 검사 대상이다(#524).
# 만료 조건: 없음(문법 검사는 대체물이 없다).
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[1/12] bash 문법 검사 (bash -n)"
fail=0
for f in scripts/*.sh scripts/manual/*.sh scripts/lib/*.sh ci/guards/*.sh ci/steps/*.sh ci/lib.sh hooks/*.sh bin/ci; do
  if ! bash -n "$f"; then
    echo "  ✗ $f"
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1

