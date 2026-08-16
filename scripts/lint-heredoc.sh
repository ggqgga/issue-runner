#!/usr/bin/env bash
# 인용 안 한 heredoc 본문의 **미이스케이프** 백틱·`$(` 를 잡는다 (#119).
#
# `cat > f <<DELIM` 처럼 구분자를 인용하지 않으면 본문의 `…`·$(…) 도 **바깥 셸이 전개**한다.
# 스텁 생성 블록은 본문에서 $tmp 를 써야 해서 의도적으로 인용을 안 하는데, 그 본문 주석에
# 백틱을 쓰면 그 안이 명령으로 실행되고 그 자리엔 실행 결과(대개 빈 문자열)가 들어간다 —
# 즉 **주석 내용이 조용히 지워지고** stderr 에 command not found 가 쌓인다.
# 실측(#119, main ad25eec): bin/ci 의 #108 스텁 주석 두 줄이 그렇게 지워져 있었고,
# CI 는 초록인 채로 매 실행 3줄씩 에러를 냈다.
#
# 통과시키는 것:
#   · 인용된 heredoc(<<'DELIM' · <<"DELIM") — 거기선 전개가 안 일어난다
#   · 이스케이프된 \$( · \` — 스텁 **런타임**에 전개돼야 하는 정상 용법
# 잡는 것:
#   · 인용 안 한 heredoc 본문의 맨 백틱 · 맨 $(
#
# 사용: lint-heredoc.sh <파일...>   (위반 있으면 exit 1 + 줄 출력)
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: lint-heredoc.sh <file...>" >&2; exit 2; }

awk '
  FNR == 1 { delim = "" }

  # heredoc 시작 — <<DELIM / <<-DELIM (인용형 <<'"'"'D'"'"' · <<"D" 는 안 잡는다).
  delim == "" {
    line = $0
    # 이스케이프 쌍(\X)을 지운 사본에서 판정 — \<< 같은 표기에 안 속게.
    if (match(line, /<<-?[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
      tok = substr(line, RSTART, RLENGTH)
      sub(/^<<-?/, "", tok); sub(/[ \t]*$/, "", tok)
      delim = tok; start = FNR
    }
    next
  }

  # 본문 — 구분자 줄에서 종료(<<- 는 선행 탭 허용).
  {
    t = $0; sub(/^[ \t]+/, "", t)
    if (t == delim) { delim = ""; next }
    s = $0
    gsub(/\\./, "", s)                       # 이스케이프된 문자는 없는 셈 치고 본다
    if (index(s, "`") > 0 || index(s, "$(") > 0) {
      printf "  ✗ %s:%d — 인용 안 한 heredoc(<<%s, %d행 시작) 본문에 미이스케이프 백틱/$( : %s\n",
             FILENAME, FNR, delim, start, substr($0, 1, 100)
      bad = 1
    }
  }

  END { exit bad ? 1 : 0 }
' "$@"
