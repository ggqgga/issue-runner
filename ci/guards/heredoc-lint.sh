#!/usr/bin/env bash
# heredoc 린트 가드 — 인용 안 한 heredoc 본문의 미이스케이프 백틱·$( 검사를
# bin/ci 인라인에서 이 자리로 옮긴 것 (분류표 Plans/ci-guard-classification.md
# L6 절 대상 행 3, #119). 검사 로직은 scripts/lint-heredoc.sh 가 갖고 있고
# 이 파일은 그 호출과 실패 시 안내 한 줄을 감싼다.
#
# 무엇을 무는가 — 구분자를 인용하지 않은 heredoc 은 본문의 백틱·$( 를
# **바깥 셸이 전개**한다. 스텁 주석에 백틱을 쓰면 그 안이 실행되고 그 자리가
# 빈 문자열로 치환돼 주석이 조용히 지워진다. bin/ci 자신도 검사 대상이다
# (그 결함이 실제로 거기 있었다).
#
# 실패 시 — lint-heredoc.sh 가 파일:줄과 문제 형태를 찍고, 이 파일이 그 뒤에
# 이스케이프 방법 한 줄을 덧붙인 뒤 exit 1.
#
# 만료 조건: 인용 안 한 heredoc 이 0 이 되고 그 형태를 shellcheck 가 직접 물면 지운다.
set -euo pipefail
cd "$(dirname "$0")/../.."

scripts/lint-heredoc.sh scripts/*.sh scripts/manual/*.sh scripts/lib/*.sh ci/guards/*.sh ci/steps/*.sh ci/lib.sh hooks/*.sh bin/ci \
  || { echo "  ↑ 백틱은 \\\` 로, 명령치환은 \\\$( 로 이스케이프하거나 <<'DELIM' 로 인용하라"; exit 1; }
