#!/usr/bin/env bash
# usage:
#   lessons-trim.sh <file> <cap>
#   lessons-trim.sh append <file> <cap> <line>
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
# 캡 이하 파일은 **완전히 안 건드린다**(멱등 — mtime·바이트 하나 안 바뀐다). append
# 서브커맨드로 넣은 줄이 캡을 넘기지 않으면 마찬가지로 트림 없이 그대로 남는다.
#
# 지웠으면, 지운 각 항목의 **첫 줄(식별자 — `- [YYYY-MM-DD PR#n] …` 또는
# `## [YYYY-MM-DD PR#n] 제목` 형태라 날짜·PR 번호가 보통 그 줄에 있다)을 stdout 에
# 한 줄씩 출력한다 — 호출자가 PR 본문 등에 "무엇을 지웠는지" 남길 수 있게(#208 3항:
# 공유 상태를 줄이는 변경은 되돌릴 수 있어야 한다).
#
# `append` 서브커맨드: 넘긴 <line> 을 파일 끝에 append 한 뒤 같은 자리에서 캡까지
# 정리한다(파일이 없으면 새로 만든다). closeout SKILL 1단계·6단계 모두 "append 하고
# 캡 정리" 를 **이 서브커맨드 한 자리**로 부른다 — append 를 이 호출 밖에서 손으로
# 하지 마라(#208 재검증 BLOCKER②, 아래 잠금 절 참고).
#
# 두 모드 모두, 파일이 없으면(= 항목 0개, 캡 이하와 동치) no-op·exit 0·무출력
# (trim 모드 한정 — append 모드는 그 자리에서 파일을 만들므로 이 조기 종료를 타지
# 않는다).
#
# 잠금: closeout 1단계와 verify-runner ③-3 이 같은 파일에 append 직후 정리를 부르는
# 계약이라, 두 루프가 같은 레포에 동시에 걸리면 read(awk)→write(mv) 사이의 창에서
# 서로의 append 를 밟을 수 있다(#208 사전 리뷰 지적). 첫 라운드는 `mkdir` 잠금을
# **트림에만** 씌웠는데, 문서가 지시하는 append 는 그 잠금 진입 **전에** 별도로
# 일어나는 구조였다 — 그래서: A 가 잠금을 쥐고 파일을 읽어 out 을 만드는 사이 B 가
# (잠금 없이) append 하면, A 의 뒤이은 mv 가 읽은 시점의 스냅샷으로 파일을 덮어써
# B 의 항목이 유실됐다(#208 재검증 BLOCKER②로 실증). 이번 라운드는 append 도 같은
# `mkdir` 임계구역 **안**에서 수행해 그 창을 없앤다 — append 든 trim-only 든 항상
# 잠금을 쥔 채로만 파일을 건드리므로, 두 프로세스는 완전히 직렬화되고 어느 쪽도
# 상대의 쓰기를 밟지 않는다. `mkdir` 원자성으로 그 직렬화를 만든다(ci-queue.sh 의
# `.running` mkdir 토큰과 같은 관용구). 짧은 유한 대기 후 실패하면 fail-closed
# (exit 3) — 조용히 잠금 없이 진행하지 않는다. 이 스크립트는 수백 ms 안에 끝나므로
# 장기 보유·스테일 잠금 회수 로직은 두지 않는다(죽은 보유자가 남기면
# `rmdir <파일>.lock` 로 사람이 푼다 — claim-issue.sh 의 스테일 잠금 절충과 같은
# 방향).
#
# 테스트 전용 훅: `LESSONS_TRIM_TEST_HOLD_BEFORE_WRITE`(초) 를 설정하면 awk 계산이
# 끝난 뒤(out 확정) mv 직전에 그만큼 sleep 한다 — 잠금이 read→write 창 전체를 실제로
# 덮는지 동시성 테스트로 입증하기 위한 것으로, 프로덕션 호출은 이 변수를 쓰지 않는다
# (scripts/tests/lessons-trim.test.sh 의 "동시성" 픽스처 참고).
set -euo pipefail

mode="trim"
if [ "${1:-}" = "append" ]; then
  mode="append"
  shift
fi

if [ "$mode" = "append" ]; then
  file="${1:?usage: lessons-trim.sh append <file> <cap> <line>}"
  cap="${2:?usage: lessons-trim.sh append <file> <cap> <line>}"
  entry="${3:?usage: lessons-trim.sh append <file> <cap> <line>}"
else
  file="${1:?usage: lessons-trim.sh <file> <cap>}"
  cap="${2:?usage: lessons-trim.sh <file> <cap>}"
fi

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

if [ "$mode" = "trim" ]; then
  [ -f "$file" ] || exit 0
fi

lockdir="$file.lock"
lock_wait=${LESSONS_TRIM_LOCK_WAIT:-10}
got_lock=0
tries=0
while [ "$tries" -le "$lock_wait" ]; do
  if mkdir "$lockdir" 2>/dev/null; then
    got_lock=1
    break
  fi
  tries=$((tries + 1))
  sleep 0.5
done
if [ "$got_lock" != 1 ]; then
  echo "lessons-trim.sh: 잠금 획득 실패 — 다른 프로세스가 $file 를 정리 중이거나 죽은 채 $lockdir 를 쥐고 있다(수동 rmdir 필요할 수 있음)" >&2
  exit 3
fi

out=$(mktemp)
removed=$(mktemp)
flag=$(mktemp)
trap 'rm -f "$out" "$removed" "$flag"; rmdir "$lockdir" 2>/dev/null' EXIT

# append 는 잠금을 쥔 **뒤에** 한다 — 이게 이번 라운드의 핵심 수정이다. 잠금 밖에서
# append 하면(#208 재검증 BLOCKER②) 다른 프로세스의 read→write 창에 끼어들어
# 유실될 수 있지만, 잠금 안에서 하면 그 프로세스는 우리가 끝날 때까지 자기 read 조차
# 시작 못 하므로 유실 창이 없다.
if [ "$mode" = "append" ]; then
  printf '%s\n' "$entry" >> "$file"
fi

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

if [ -n "${LESSONS_TRIM_TEST_HOLD_BEFORE_WRITE:-}" ]; then
  sleep "$LESSONS_TRIM_TEST_HOLD_BEFORE_WRITE"
fi

if [ -s "$flag" ]; then
  mv "$out" "$file"
  cat "$removed"
fi
