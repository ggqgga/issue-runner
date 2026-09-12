#!/usr/bin/env bash
# attempt-counter.sh <repo> <pr> <key> [--bump]
#
# PR 본문에 숨겨 둔 회차 카운터 `<!-- <key>: N -->` 의 **읽기·증가 한 자리** (#444 · 에픽 #443).
#
#   stdout `N`   exit 0   현재 값(마커가 없으면 `0`). `--bump` 면 **갱신 후의 값**(N+1).
#   무출력       exit 2   조회·편집 실패(fail-closed — 호출자는 "값 없음" 으로 처리하고
#                         그 틱엔 회차 판정을 하지 마라. 0 으로 읽으면 상한이 리셋된다).
#   무출력       exit 64  호출 형태 오류(인자 부족 · 키에 허용 밖 문자). 쓰기 전에 멈춘다.
#
# 왜 스크립트인가: 같은 읽기-증가-쓰기 절차를 두 SKILL 이 산문으로 두 벌 들고 있었다 —
# issue-runner ② 서킷 브레이커(`repair-count`)와 verify-runner ③/④(`verify-attempt`).
# 산문 두 벌은 한쪽만 고쳐지면 회차 상한이 레인마다 달라지는데, 그 차이가 출력에 안 보인다
# (상한 비교 자체는 LLM 노브라 SKILL 에 남는다 — `MAX_REPAIRS_PER_PR`·`CODEX_REVIEW_LIMIT`).
#
# ── 마커 문법 ────────────────────────────────────────────────────────────
# 읽기는 느슨하게(`<!--` 와 `-->` 사이 공백 허용), 쓰기는 **정규형** `<!-- <key>: N -->` 로
# 한 자리에 고정한다. 옛 본문이 손으로 쓰여 공백이 어긋나 있어도 읽히고, 한 번 bump 하면
# 정규형으로 수렴한다. 키는 `[A-Za-z0-9_-]` 만 — 콜론·정규식 메타문자가 들어오면 마커
# 문법 자체가 흔들리므로 exit 64 로 거절한다(쓰기 전에).
# 같은 키의 마커가 여러 개면 **마지막 것**이 값이고 bump 도 그 자리를 고친다(마지막이
# 가장 최근에 덧붙은 것이다). 한 줄에 둘이면 앞엣것 — 이 스크립트가 유일한 생산자인 한
# 둘 다 생기지 않는다.
#
# ── 본문 무손상 ──────────────────────────────────────────────────────────
# bump 는 마커 substring 한 조각만 갈아끼우고 **마커 밖 바이트는 하나도 안 바꾼다**. 마커가
# 없으면 본문 끝에 빈 줄 + 마커를 덧붙인다(본문이 비어 있으면 마커만).
#
# 끝 개행까지 바이트로 보존한다 — `jq -j`(레코드 종결자 없음) + 끝 개행 유무를 따로 재서
# awk 가 그대로 재현한다. `jq -r` 는 본문 끝에 개행을 **하나 더** 붙이는데, 그러면 개행으로
# 끝나는 본문은 bump 할 때마다 끝에 빈 줄이 하나씩 쌓인다(#465 codex 2회차 [P2-1]).
# 카운터는 같은 PR 에서 여러 번 도는 물건이라 그 누적이 실제로 보인다. 테스트 스텁이
# `$(cat …)` 로 끝 개행을 지워 이 결함을 가리고 있었으므로, 스텁도 `jq -Rs` 로 바꿔
# 본문을 바이트 그대로 왕복시킨다 — 그래야 이 축을 실제로 잰다.
#
# ── 알려진 한계(종전 산문과 동일) ────────────────────────────────────────
# 읽기 → 계산 → `gh pr edit --body-file` 은 원자적이지 않다. 그 사이에 다른 주체가 본문을
# 고치면 그 편집이 덮인다. 종전 산문(`gh pr edit --body ...`)도 같은 형상이었고, 두 카운터는
# 서로 다른 키를 서로 다른 루프가 만지므로(issue-runner ② `repair-count` · verify-runner
# `verify-attempt`) 실무상 경합이 없다. 재읽기-비교 루프는 일부러 넣지 않는다 —
# 이 자리의 계약은 "산문 두 벌을 한 자리로" 지 새 동시성 보증이 아니다.
set -uo pipefail

usage() { echo "usage: attempt-counter.sh <repo> <pr> <key> [--bump]" >&2; exit 64; }

bump=0
argc=0
repo=""; pr=""; key=""
for a in "$@"; do
  case "$a" in
    --bump) bump=1 ;;
    -*) usage ;;
    *)
      argc=$((argc + 1))
      case "$argc" in
        1) repo="$a" ;;
        2) pr="$a" ;;
        3) key="$a" ;;
        *) usage ;;
      esac ;;
  esac
done
[ "$argc" = 3 ] || usage
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$key" ] || usage
case "$pr" in *[!0-9]*|'') usage ;; esac
# 키 화이트리스트 — 정규식 메타문자·콜론을 막는다(위 "마커 문법").
case "$key" in *[!A-Za-z0-9_-]*) usage ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/attempt-counter.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

# ── 본문 조회 ────────────────────────────────────────────────────────────
# 실패를 빈 본문으로 둔갑시키지 않는다: gh 가 비정상 종료하거나 빈 출력을 내면 exit 2.
# (본문이 정말 빈 PR 은 `{"body":""}` 로 오므로 빈 JSON 과 구분된다.)
gh pr view "$pr" --repo "$repo" --json body > "$tmp/raw.json" 2>/dev/null || exit 2
[ -s "$tmp/raw.json" ] || exit 2
# `-j` = 레코드 종결자 없음. 본문 바이트 그대로다(위 "끝 개행까지 바이트로 보존").
jq -j '.body // ""' < "$tmp/raw.json" > "$tmp/body" 2>/dev/null || exit 2
# 끝 개행 유무 — awk 는 줄 단위라 이 정보를 잃는다. 마지막 바이트가 개행이면
# `$(tail -c1)` 이 빈 문자열이 된다(명령치환이 끝 개행을 지우므로).
trail=0
if [ -s "$tmp/body" ] && [ -z "$(tail -c1 "$tmp/body")" ]; then trail=1; fi

re="<!--[ \\t]*${key}[ \\t]*:[ \\t]*[0-9]+[ \\t]*-->"

cur=$(awk -v re="$re" '
  { lines[NR] = $0; if (match($0, re)) { last = NR; m = substr($0, RSTART, RLENGTH) } }
  END {
    if (last == 0) { print 0; exit }
    sub(/^[^:]*:[ \t]*/, "", m); sub(/[ \t]*-->$/, "", m)
    print m + 0
  }
' "$tmp/body" 2>/dev/null) || exit 2
case "$cur" in ''|*[!0-9]*) exit 2 ;; esac

if [ "$bump" = 0 ]; then
  printf '%s\n' "$cur"
  exit 0
fi

new=$((cur + 1))
# 줄을 다시 이어 붙일 때 **끝 개행은 `trail` 이 정한다**(awk 의 `print` 에 맡기면 없던
# 개행이 생긴다). `printf "%s"` 로 내보내 ORS 도 안 붙인다.
awk -v re="$re" -v marker="<!-- ${key}: ${new} -->" -v trail="$trail" '
  { lines[NR] = $0; if (match($0, re)) last = NR }
  END {
    out = ""
    for (i = 1; i <= NR; i++) {
      line = lines[i]
      if (i == last) {
        match(line, re)
        line = substr(line, 1, RSTART - 1) marker substr(line, RSTART + RLENGTH)
      }
      out = out line
      if (i < NR || trail == 1) out = out "\n"
    }
    if (last == 0) {
      # 마커 부재 → 본문 끝에 빈 줄 하나 띄우고 마커. 본문이 비었으면 마커만.
      if (out != "") {
        if (substr(out, length(out)) != "\n") out = out "\n"
        out = out "\n"
      }
      out = out marker "\n"
    }
    printf "%s", out
  }
' "$tmp/body" > "$tmp/new" 2>/dev/null || exit 2

gh pr edit "$pr" --repo "$repo" --body-file "$tmp/new" >/dev/null 2>&1 || {
  echo "attempt-counter: gh pr edit 실패 — $repo #$pr $key (본문 미갱신)" >&2
  exit 2
}
printf '%s\n' "$new"
