#!/usr/bin/env bash
# spinoff-inherit.sh <owner/repo> <parent-issue#>
#
# 파생 이슈가 부모에게서 **기계적으로** 물려받을 두 값을 stdout 에 정확히 두 줄로 낸다 (#261):
#
#   epic=<N|->          부모가 속한 에픽 번호. 없으면 `-`
#   priority=<P0|P1|P2> 부모의 P 라벨. 없으면 `P2`
#
# 출력은 `eval "$(...)"` 로 그대로 쉘 변수가 되는 형태다 — closeout 6단계 발행 명령이
# `--label "$priority"` 로 쓰고, `$epic` 으로 본문 첫 줄 `Epic #N` 을 채운다.
#
#   eval "$($SCRIPTS/spinoff-inherit.sh ggqgga/BodaT 4979)"   # epic= · priority=
#
# 부모 조회 실패 → **아무것도 안 내고 exit 1**. 호출자는 fail-closed 로 발행을 멈추고
# BLOCKED 를 보고한다 — 상속 없이 발행하지 않는다. 빈 결과와 실패를 섞지 않는 규율은
# `progress-evidence.sh`·`claim-at.sh` 머리 주석과 같다(PR#139: `|| true` 로 파이프
# 전체를 삼키면 부분 실패의 부분 출력이 정상값으로 채택돼 가드 자체를 우회한다).
#
# ── 왜 파생이 상속해야 하는가 ────────────────────────────────────────────────
# 주제 축은 이슈 본문의 `Epic #N` **전용 줄**이다(#257 finish-first 정렬 · #258 에픽 스윕 ·
# #260 loop-status 에픽 절). 파생이 그 줄을 안 물려받으면 에픽 밖 고아가 쌓이고, 스윕은
# leaf 를 못 세고, 정렬은 파생을 단발로 취급한다. 산문뿐인 단계는 샌다(실증 2026-08-13:
# 6단계가 규약 라벨만 달고 `agent-ready` 를 빠뜨려 17건이 루프 밖에 남음) — 그래서 산문이
# 아니라 명령으로 묶는다.
#
# ── epic 판정 ────────────────────────────────────────────────────────────────
# ⑴ 부모가 `epic` 라벨 이슈 **자체**면 `epic=<부모번호>` — 파생은 그 에픽의 leaf 다.
#    (에픽 본체가 또 다른 에픽의 leaf 인 형상은 이 레포에 없다. 라벨이 본문 줄을 이긴다.)
# ⑵ 아니면 부모 **본문의 `Epic #N` 전용 줄** 첫 매치. 정규식은 `loop-status.sh` 의
#    `epic_of`(#260) 와 **문자 그대로 같다** — 두 곳이 갈라지면 `bin/ci` 가 빨개진다.
#    산문 속 `… epic #N …`·백틱 인용·불릿 앞머리는 신호가 아니다(전용 줄만).
# ⑶ 둘 다 없으면 `-`.
#
# ── priority 판정 ────────────────────────────────────────────────────────────
# `eligible-issues.sh` 의 정렬 판정과 **같은 순서**(P0 > P1 > P2), 라벨이 없으면 `P2`.
# P 를 "급해 보여서" 올리지 않는다 — 올리려면 사람이 에픽 단위로 올린다.
#
# 읽기 전용이다 — 부모를 편집하지 않는다.
# macOS bash 3.2 대상(연관배열·${var^^}·mapfile 금지).
set -uo pipefail

# 인자 부재도 fail-closed(무출력·exit 1) — `${1:?}` 는 stderr 에 메시지를 내고 exit 1 이지만
# 여기서는 메시지 형태를 우리가 쥐고, stdout 을 절대 오염시키지 않는다.
repo=${1:-}
parent=${2:-}
[ -n "$repo" ] || { echo "usage: spinoff-inherit.sh <owner/repo> <parent-issue#>" >&2; exit 1; }
[ -n "$parent" ] || { echo "usage: spinoff-inherit.sh <owner/repo> <parent-issue#>" >&2; exit 1; }

# 부모 번호가 숫자가 아니면 **조회조차 하지 않는다**. 호출자가 부모를 못 구한 것이고
# (head 브랜치가 `agent/issue-<N>` 형태가 아니고 연결 이슈도 못 읽은 경우), 그때 상속 없이
# 발행하면 안 된다 — 수용 기준 1번의 fail-closed 와 같은 규율.
case "$parent" in
  ''|*[!0-9]*) echo "spinoff-inherit: 부모 이슈 번호가 숫자가 아니다: $parent" >&2; exit 1 ;;
esac

# `Epic #N` 전용 줄 정규식 — `loop-status.sh` 의 `epic_of`(#260) 와 문자 그대로 같은 문자열.
# 두 곳이 갈라지면 파생의 에픽 판정과 에픽 절의 leaf 판정이 서로 다른 세계를 재게 된다.
# (`bin/ci` 의 "#261 Epic 줄 정규식 SSOT 동기화" 검사가 두 파일에서 이 문자열을 문다.)
EPIC_RE='^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)'

# 부모를 **한 번** 읽는다(본문·라벨을 한 호출로). 실패는 exit 1 — 빈 결과로 새지 않는다.
raw=$(gh issue view "$parent" --repo "$repo" --json body,labels 2>/dev/null) || exit 1
[ -n "$raw" ] || exit 1

out=$(printf '%s' "$raw" | jq -r \
  --arg parent "$parent" \
  --arg re "$EPIC_RE" '
    def names: [.labels[]?.name // empty];
    def has_label($n): (names | index($n)) != null;
    # jq 의 `^` 는 **문자열 시작**만 앵커하므로 줄 단위로 가른 뒤 capture 한다
    # (loop-status.sh epic_of 와 같은 스타일). 한 이슈 = 최대 한 에픽이라 첫 매치만.
    def epic_of:
      ([(.body // "") | split("\n")[] | capture($re; "i") | .n]
       | if length > 0 then .[0] else null end);
    def prio:
      if has_label("P0") then "P0"
      elif has_label("P1") then "P1"
      elif has_label("P2") then "P2"
      else "P2" end;                      # P 라벨 없음 = P2 (남발 방지 기본값)
    ( if has_label("epic") then $parent    # 부모가 에픽 본체면 파생은 그 에픽의 leaf
      else (epic_of // "-") end ) as $e
    | "epic=\($e)", "priority=\(prio)"
  ' 2>/dev/null) || exit 1
[ -n "$out" ] || exit 1

printf '%s\n' "$out"
exit 0
