# 세션 레포 스코프(.loop/repos) 판정 — **한 자리** (#427 · 플랜 1단계)
# shellcheck shell=bash
#
# 규약(#40): 실행 cwd 의 `.loop/repos` 가 있으면 그 목록(owner/repo, 줄당 하나,
# `#` 주석·빈 줄 허용)의 레포만 다룬다. 파일이 **없으면 계정 전체**를 허용한다
# (fail-open — 스코프 파일은 "좁히는" 장치이지 "여는" 장치가 아니므로 부재가
# 곧 무제한이다. 다른 세션 워커의 claim 에 불간섭하려면 파일을 두어라).
#
# 소비처 8곳이 이 파일을 source 한다 — 두 모양이 있고, 둘 다 같은 줄 필터를 쓴다:
#   ⒜ `in_scope <owner/repo>` — 후보를 한 건씩 거른다
#      (closeout-eligible · closeout-reconcile · eligible-issues · reconcile · verify-eligible)
#   ⒝ `scope_lines <파일>`     — 순회할 레포 **목록**을 읽는다
#      (epic-sweep · loop-status · resume-sweep)
# ⒝ 셋의 나머지 거동(형식 아닌 줄의 stderr 경고·`--repos-file` 인자·exit 64·
# 계정 전체 탐색 폴백)은 스크립트마다 다르고, 그건 **의도된 차이**라 여기서 합치지
# 않는다 — 여기 있는 것은 "어느 줄이 레포 이름인가" 하나뿐이다.

# 기본 스코프 파일. source 시점의 cwd 기준이고, 호출자가 미리 `scope_file` 을
# 정해 두었으면 그것을 존중한다(`:=` — 테스트가 경로를 갈아끼우는 통로).
: "${scope_file:=$PWD/.loop/repos}"

# scope_lines <파일> — 주석·빈 줄을 빼고 공백(스페이스·탭)을 제거한 줄만 낸다.
# 공백 제거를 필터 **뒤**에 두어도 결과가 같다: 공백만 있는 줄은 `^[[:space:]]*$`
# 로 이미 빠지고, 들여쓴 `#` 줄도 `^[[:space:]]*#` 로 이미 빠진다.
scope_lines() {
  grep -vE '^[[:space:]]*(#|$)' "$1" | tr -d ' \t'
}

# in_scope <owner/repo> — 스코프 파일이 없으면 전 레포 허용(위 fail-open).
in_scope() {
  [ -f "$scope_file" ] || return 0
  scope_lines "$scope_file" | grep -qxF "$1"
}
