#!/usr/bin/env bash
# usage: lessons-trim.sh <file> <cap>
#
# `.loop/lessons-verifier.md`(검증 판정 사례집) 캡 정리를 한 자리로 뽑은 결정론
# 스크립트(#208). 항목 = `- [` 로 시작하는 한 줄, 또는 `##` 헤더부터 다음 항목
# 직전까지(skills/closeout/SKILL.md 1단계 lessons 절과 같은 정의 — 줄 단위로 자르면
# `##` 여러 줄짜리 사례의 산문이 찢어진다).
#
# 초과 시 **항목 수가 캡 이하가 될 때까지** 가장 오래된 항목부터(파일 앞쪽일수록
# 오래됐다 — append 는 파일 끝에 쌓인다) 통째로 지운다. 옛 규칙("가장 오래된 항목
# 하나만 삭제")은 append(+1)·삭제(-1) 가 순증 0 이라 한 번 캡을 넘으면 영원히 안
# 줄었다 — 이 스크립트는 그 결함을 수렴하는 규칙으로 고친다.
#
# 캡 이하 파일은 **완전히 안 건드린다**(멱등 — mtime·바이트 하나 안 바뀐다).
#
# 지웠으면, 지운 각 항목의 **첫 줄(식별자 — `- [YYYY-MM-DD PR#n] …` 또는
# `## [YYYY-MM-DD PR#n] 제목` 형태라 날짜·PR 번호가 보통 그 줄에 있다)을 stdout 에
# 한 줄씩 출력한다 — 호출자가 PR 본문 등에 "무엇을 지웠는지" 남길 수 있게(#208 3항:
# 공유 상태를 줄이는 변경은 되돌릴 수 있어야 한다).
#
# 파일이 없으면(= 항목 0개, 캡 이하와 동치) no-op, exit 0, 무출력.
set -euo pipefail

file="${1:?usage: lessons-trim.sh <file> <cap>}"
cap="${2:?usage: lessons-trim.sh <file> <cap>}"

case "$cap" in
  ''|*[!0-9]*)
    echo "lessons-trim.sh: cap 은 양의 정수여야 한다: $cap" >&2
    exit 2
    ;;
esac
[ "$cap" -gt 0 ] || {
  echo "lessons-trim.sh: cap 은 1 이상이어야 한다: $cap" >&2
  exit 2
}

[ -f "$file" ] || exit 0

out=$(mktemp)
removed=$(mktemp)
flag=$(mktemp)
trap 'rm -f "$out" "$removed" "$flag"' EXIT

# awk 한 패스: 경계선(항목 시작) 인덱스를 모은 뒤, 초과분(오래된 쪽)만 removed_file 에
# 첫 줄을 적고 본문에서는 통째로 건너뛰고, 나머지(프리앰블 + 유지 항목)는 그대로 stdout.
# nb<=cap 이면 아무것도 stdout·flag_file 에 쓰지 않는다 — 호출자가 그걸로 "무변경"을 안다.
awk -v cap="$cap" -v removed_file="$removed" -v flag_file="$flag" '
  function is_boundary(l) { return (l ~ /^- \[/) || (l ~ /^## /) }
  { lines[NR] = $0 }
  END {
    n = NR
    nb = 0
    for (i = 1; i <= n; i++) {
      if (is_boundary(lines[i])) { nb++; bstart[nb] = i }
    }
    if (nb <= cap) exit 0

    drop = nb - cap
    for (i = 1; i < bstart[1]; i++) print lines[i]
    for (b = 1; b <= nb; b++) {
      start = bstart[b]
      end = (b < nb) ? bstart[b + 1] - 1 : n
      if (b <= drop) {
        print lines[start] > removed_file
        continue
      }
      for (i = start; i <= end; i++) print lines[i]
    }
    print "1" > flag_file
  }
' "$file" > "$out"

if [ -s "$flag" ]; then
  mv "$out" "$file"
  cat "$removed"
fi
