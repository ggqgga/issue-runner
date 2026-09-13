#!/usr/bin/env bash
# ci/steps/*.sh 가 함께 쓰는 헬퍼 한 자리 (#524 · Plans/loop-restructure.md 4단계).
#
# source 전용이다 — 직접 실행하지 않는다. 각 단계가
#   # shellcheck source=ci/lib.sh
#   . "$(dirname "$0")/../lib.sh"
# 로 읽어 들인다(단계는 레포 루트로 cd 한 뒤라 `$(dirname "$0")` 는 ci/steps 다).
#
# 여기 두는 기준: **둘 이상의 단계가 같은 판정 모양을 쓸 때**. 한 단계 안에서만 쓰는
# 헬퍼는 그 단계 파일에 남긴다 — 여기로 올리면 그 단계를 지울 때 죽은 코드가 남는다.

# check_phrase <파일> <문구> — 파일에 규약 문구가 그대로 있는지. 없으면 진단 한 줄 + exit 1.
# (원 bin/ci 561–563행에서 옮겼다 — 판정·메시지 한 글자 불변.)
check_phrase() {
  grep -qF -- "$2" "$1" || { echo "  ✗ $1 에 전이 실패 보고 규약('$2') 없음"; exit 1; }
}
