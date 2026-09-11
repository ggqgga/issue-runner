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

# trap 을 mktemp **앞에** 건다(#232 h2) — out/removed/flag 를 빈 값으로 먼저 초기화해
# 두면 `rm -f "$out" "$removed" "$flag"` 는 아직 안 채워진 변수라도(`rm -f ""` 는
# 무해) 안전하다. mktemp 3회 중 하나라도 실패하면(TMPDIR 가 없거나 꽉 찬 경우 등)
# `set -e` 가 즉시 스크립트를 종료시키는데, trap 이 mktemp **뒤에** 있으면 그 실패
# 시점엔 아직 trap 이 안 걸려 있어 `$lockdir` 가 안 지워지고 영구히 남는다(이후 모든
# closeout append 가 exit 3 로 막힌다). trap 을 먼저 걸면 실패 지점이 어디든 EXIT
# 훅이 잠금을 반드시 회수한다.
out=""
removed=""
flag=""
trap 'rm -f "$out" "$removed" "$flag"; rmdir "$lockdir" 2>/dev/null' EXIT

out=$(mktemp)
removed=$(mktemp)
flag=$(mktemp)

# append 는 잠금을 쥔 **뒤에** 한다 — 이게 #208 라운드의 핵심 수정이다. 잠금 밖에서
# append 하면(#208 재검증 BLOCKER②) 다른 프로세스의 read→write 창에 끼어들어
# 유실될 수 있지만, 잠금 안에서 하면 그 프로세스는 우리가 끝날 때까지 자기 read 조차
# 시작 못 하므로 유실 창이 없다.
if [ "$mode" = "append" ]; then
  # 기존 파일의 마지막 바이트가 개행이 아니면 먼저 개행을 넣는다(#232 h3) — 안 그러면
  # 새 `- [` 항목이 마지막 줄에 이어 붙어 줄 머리가 아니게 되고, awk 의 `^- \[` 경계
  # 판정에서 빠져 두 항목이 하나로 합쳐진다(캡 계산 과소). 빈 파일·없는 파일에는 앞에
  # 개행을 넣지 않는다(맨 앞에 빈 줄이 생기는 걸 막는다) — `-s` 가 이미 그 구분이다.
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$entry" >> "$file"
fi

# awk 한 패스: 경계선(항목 시작) 인덱스를 모은 뒤, 초과분(오래된 쪽)만 removed_file 에
# 첫 줄을 적고 본문에서는 통째로 건너뛰고, 나머지(프리앰블 + 유지 항목)는 그대로 stdout.
# nb<=cap 이면 아무것도 stdout·flag_file 에 쓰지 않는다 — 호출자가 그걸로 "무변경"을 안다.
#
# 항목 정의는 두 경계 타입이 다르다(#232 h1): `## ` 헤더는 다음 경계 직전까지 그 블록의
# 산문을 통째로 소유한다(그래야 여러 줄짜리 사례가 안 찢어진다). 반면 `- [` bullet 은
# **정의상 그 한 줄뿐**이라 item_end=start — 다음 경계 직전까지의 나머지 줄(빈 줄이든
# 독립 산문이든)은 그 bullet 의 소유가 아니다. 그 "소유되지 않은" 구간(item_end+1..
# gap_end)은 **유지되는 bullet 뒤에서는** 항상 그대로 stdout 에 흘린다(원본 그대로 —
# 안 그러면 bullet 을 지울 때 뒤따르는 독립 산문까지 조용히 함께 지워진다, 이 이슈의
# 재현 기전). 하지만 **드롭되는 bullet 뒤에서는** gap 에 공백 아닌 줄(산문)이 있을
# 때만 보존한다 — 사전 리뷰 BLOCKER: gap 을 드롭 여부와 무관하게 항상 흘리면, 빈 줄
# 구분자만 있는(원장의 지배적 패턴) gap 도 살아남아 `bstart[1]` 이전 프리앰블로
# 편입되고, 프리앰블은 이후 모든 실행에서 무조건 통과되는 구간이라(아래 `for (i = 1;
# i < bstart[1]; i++)`) 트림을 반복할 때마다 빈 줄이 영구 누적된다(실측:
# `- [A] a / 빈줄 / - [B] b / 빈줄 / - [C] c` 에 cap=1 을 걸면 A·B 드롭 후 파일 맨
# 앞에 빈 줄 2개가 영구 잔존 — scripts/tests/lessons-trim.test.sh 의 "h1 빈 줄
# 구분자" 격자 참고). `## ` 블록은 item_end==gap_end 라 이 구간이 애초에 없다(기존
# 동작 불변).
awk -v cap="$cap" -v removed_file="$removed" -v flag_file="$flag" '
  function is_boundary(l) { return (l ~ /^- \[/) || (l ~ /^## /) }
  function is_bullet(l)   { return (l ~ /^- \[/) }
  function gap_has_prose(from, to,    i, has) {
    has = 0
    for (i = from; i <= to; i++) {
      if (lines[i] !~ /^[ \t]*$/) { has = 1; break }
    }
    return has
  }
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
      next_start = (b < nb) ? bstart[b + 1] : n + 1
      gap_end = next_start - 1
      item_end = is_bullet(lines[start]) ? start : gap_end
      dropped = (b <= drop)
      if (dropped) {
        print lines[start] > removed_file
      } else {
        for (i = start; i <= item_end; i++) print lines[i]
      }
      if (item_end < gap_end && (!dropped || gap_has_prose(item_end + 1, gap_end))) {
        for (i = item_end + 1; i <= gap_end; i++) print lines[i]
      }
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
