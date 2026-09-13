#!/usr/bin/env bash
# spinoff-issue.sh <owner/repo> <부모 이슈#|-> <부모 PR#> --title <제목> --body-file <파일> [--label <추가라벨>]...
#
# closeout 6단계(파생 이슈)와 5단계 fail 갈래의 **발행 절차 한 자리** (#447 · 에픽 #443 2단계).
# 종전엔 SKILL 산문이 `spinoff-inherit.sh` 호출 → `gh issue create` → 라벨 부재 재시도 →
# 발행 직후 readback(라벨·`Epic #N` 첫 줄) → 부모 PR 마커를 다섯 문단에 걸쳐 지시했다.
# 산문뿐인 단계는 샌다(실증 2026-08-13: 6단계가 규약 라벨만 달고 `agent-ready` 를 빠뜨려
# 열린 이슈 17건이 루프 밖 재고로 남음 — 명령이 박힌 4단계는 186건 전건 정상) — 그래서 명령으로 묶는다.
#
# ── 하는 일 (순서 = 계약) ─────────────────────────────────────────────────────
# ⑴ 상속: `spinoff-inherit.sh <repo> <부모 이슈#>` 를 **그대로 부른다**(epic=·priority=).
#    로직을 여기 복제하지 않는다 — `Epic #N` 전용 줄 정규식의 SSOT 는 그 스크립트이고
#    `loop-status.sh` 의 `epic_of`(#260) 와 **문자 그대로 같아야** 한다(`bin/ci` 가 문다).
#    부모 미상(`-`·비숫자)이거나 상속 실패면 **발행하지 않는다** — exit 1(fail-closed).
#    "급해 보여서" P 를 올리지 마라 — 올리려면 사람이 에픽 단위로 올린다.
# ⑵ 본문: `--body-file` 의 `<EPIC_LINE>` **전용 줄**을 `Epic #N`(epic 없음이면 빈 줄)로
#    치환하고, epic 이 있는데 첫 줄이 `Epic #N` 이 아니면 **맨 앞에 끼워 넣는다**.
#    에픽은 sub-issue 링크도 라벨도 아닌 본문 **첫 줄**로 잇는다 — 그 줄이 없으면 그 파생은
#    에픽 밖 고아가 되어 `loop-status.sh` 에픽 절의 leaf 집계에서 영영 안 보인다(#260·#261).
#    `<ORIGIN_LINE>` 전용 줄은 `Spinoff of PR #<부모 PR#> (issue #<부모 이슈#>)` 로 치환하고,
#    슬롯이 없으면 **둘째 줄**에 끼워 넣는다(#411) — 어느 PR·이슈에서 왔는지가 산문이 아니라
#    전용 줄에 있어야 사람이 뒤지지 않는다(실측 2026-09-13: 최근 파생 30건 중 12건만 적혀 있었다).
# ⑶ 발행: `gh issue create --label agent-ready --label spinoff --label <P> [--label 추가]`.
#    `agent-ready` 생략 불가 — `eligible-issues.sh` 의 자격이 `open + agent-ready +
#    ¬agent:claimed` 라 없으면 이슈는 생성되고도 루프가 **영원히 안 집는다**.
#    `spinoff` 는 출처 표식 — `loop-status.sh` 의 `파생` 줄이 이 라벨로만 센다(제목
#    휴리스틱을 쓰지 않는다). P 도 생략 불가 — 없으면 정렬에서 P0 아닌 칸으로 처리된다(#401).
# ⑷ 라벨 부재 fail-closed: `gh issue create` 는 레포에 없는 라벨이 하나라도 있으면 **이슈
#    자체를 안 만들고 실패**한다. `not found` 류면 `setup-labels.sh <repo>` 를 **1회** 부른 뒤
#    같은 명령을 **1회만** 재시도하고, 그래도 실패하면 **라벨 없이 이슈만** 만든다(발행 유실
#    방지) → exit 2. 그 폴백 건은 아래 ⑸ 라벨 보강에서 **제외**한다(#223 과 같은 규율 — 이미
#    "이 레포에선 지금 라벨을 못 단다" 를 확정한 상태라 또 부르면 또 실패하고, 그 실패에
#    걸려 뒤따르는 PR 마커·BLOCKED 보고가 끊긴다). 복구는 사람 몫(setup-labels 재실행 → issue edit).
# ⑸ 발행 직후 readback: `agent-ready`·`spinoff`·P 가 붙었는지, 본문 첫 줄이 `Epic #N` 인지
#    **실제로 다시 읽어** 확인하고 빠진 것만 보강한다(`--add-label` · `--body-file`).
#    보강 뒤에도 어긋나면 exit 2 — 조용히 성공으로 넘기지 않는다.
# ⑹ 부모 PR 마커: `파생: #<새번호> (Epic #<N|없음> · <P>)` 코멘트. 중복 발행 방지 마커이자
#    ④ Report 의 `파생` 항목과 같은 꼴이다(에픽 밖으로 새는 파생을 매 틱 관측하기 위한 것).
#
# ── 출력·종료코드 ─────────────────────────────────────────────────────────────
#   stdout : 새 이슈 번호 한 줄 (그것뿐 — 호출자가 그대로 쓴다)
#   stderr : `marker: 파생: #<N> (Epic #<M|없음> · <P>)` (④ Report 에 그대로 옮겨 적는 줄)
#            + 실패 사유
#   exit 0 : 발행·라벨·본문·마커 전부 정상
#   exit 1 : **이슈가 만들어지지 않았다** — 부모 미상·상속 실패·발행 실패(무출력).
#            호출자는 ④ Report 에 `BLOCKED: 파생 부모 미상 — PR #<pr>` 또는
#            `BLOCKED: 파생 발행 실패 — PR #<pr>` 로 올린다(상속 없이 발행하지 않는다).
#   exit 2 : **이슈는 만들어졌다**(번호는 stdout) — 라벨/본문/마커 중 하나가 어긋났다.
#            호출자는 `BLOCKED: 파생 이슈 라벨 부착 실패 — #<번호>` 로 올린다.
#   exit 64: usage
#
# macOS bash 3.2 대상(연관배열·mapfile·${var^^} 금지).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"

usage() {
  echo "usage: spinoff-issue.sh <owner/repo> <부모 이슈#|-> <부모 PR#> --title <제목> --body-file <파일> [--label <라벨>]..." >&2
}

repo=${1:-}; parent=${2:-}; pr=${3:-}
[ -n "$repo" ] && [ -n "$parent" ] && [ -n "$pr" ] || { usage; exit 64; }
shift 3

title=
body_file=
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     [ $# -ge 2 ] || { usage; exit 64; }; title=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || { usage; exit 64; }; body_file=$2; shift 2 ;;
    --label)     [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 64; }; extra[${#extra[@]}]=$2; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
[ -n "$title" ] || { usage; exit 64; }
[ -n "$body_file" ] && [ -r "$body_file" ] || { echo "spinoff-issue: 본문 파일을 읽을 수 없다: $body_file" >&2; exit 64; }
case "$pr" in ''|*[!0-9]*) echo "spinoff-issue: 부모 PR 번호가 숫자가 아니다: $pr" >&2; exit 64 ;; esac

# ⑴ 상속 — 부모 미상·조회 실패는 발행 없이 exit 1 (상속 없이 발행하지 않는다)
case "$parent" in
  ''|-|*[!0-9]*)
    echo "spinoff-issue: 부모 이슈 미상($parent) — 상속 없이 발행하지 않는다 (PR #$pr)" >&2
    exit 1 ;;
esac
epic=; priority=
inh=$("$here/spinoff-inherit.sh" "$repo" "$parent") || {
  echo "spinoff-issue: 상속 조회 실패 — 부모 #$parent (PR #$pr)" >&2; exit 1; }
eval "$inh"
[ -n "${epic:-}" ] && [ -n "${priority:-}" ] || {
  echo "spinoff-issue: 상속값이 비었다 — 부모 #$parent" >&2; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
rendered="$tmp/body.md"

# ⑵ 본문 — `<EPIC_LINE>` 전용 줄 치환 + 첫 줄 보장 · `<ORIGIN_LINE>` 치환 + 둘째 줄 보장(#411)
if [ "$epic" = "-" ]; then epic_line=""; else epic_line="Epic #$epic"; fi
origin_line="Spinoff of PR #$pr (issue #$parent)"
awk -v rep="$epic_line" -v org="$origin_line" \
  '$0 == "<EPIC_LINE>" { print rep; next } $0 == "<ORIGIN_LINE>" { print org; next } { print }' \
  "$body_file" > "$rendered"
if [ -n "$epic_line" ] && [ "$(head -1 "$rendered")" != "$epic_line" ]; then
  { printf '%s\n\n' "$epic_line"; cat "$rendered"; } > "$tmp/body2.md"
  mv "$tmp/body2.md" "$rendered"
fi
if ! grep -qF -- "$origin_line" "$rendered"; then
  # 옛 본문 파일(슬롯 없음)도 출처 줄 없이 나가지 않는다 — 첫 줄(에픽 줄 또는 빈 줄) 다음에 끼운다.
  { head -1 "$rendered"; printf '%s\n' "$origin_line"; tail -n +2 "$rendered"; } > "$tmp/body2.md"
  mv "$tmp/body2.md" "$rendered"
fi

# ⑶⑷ 발행 — 라벨 부재면 setup-labels 1회 + 재시도 1회, 그래도 안 되면 무라벨 폴백
labels=(--label agent-ready --label spinoff --label "$priority")
i=0
while [ "$i" -lt "${#extra[@]}" ]; do
  labels[${#labels[@]}]=--label
  labels[${#labels[@]}]=${extra[$i]}
  i=$((i + 1))
done

create() {  # create <라벨 붙임 여부>
  if [ "$1" = with-labels ]; then
    gh issue create --repo "$repo" --title "$title" --body-file "$rendered" "${labels[@]}" 2>"$tmp/err"
  else
    gh issue create --repo "$repo" --title "$title" --body-file "$rendered" 2>"$tmp/err"
  fi
}

labels_ok=1
out=$(create with-labels) || {
  if grep -qi 'not found' "$tmp/err"; then
    "$here/setup-labels.sh" "$repo" >/dev/null 2>&1
    out=$(create with-labels) || out=
  else
    out=
  fi
  if [ -z "$out" ]; then
    labels_ok=0                       # 무라벨 폴백 — 발행 유실만은 막는다
    out=$(create no-labels) || {
      echo "spinoff-issue: 이슈 발행 실패 — $(tail -1 "$tmp/err")" >&2
      exit 1
    }
  fi
}

num=$(printf '%s\n' "$out" | tr -d ' ' | sed -n 's#.*/issues/\([0-9][0-9]*\)$#\1#p' | tail -1)
case "$num" in
  ''|*[!0-9]*)
    echo "spinoff-issue: 발행 결과에서 이슈 번호를 못 읽었다: $out" >&2
    exit 1 ;;
esac

rc=0
if [ "$epic" = "-" ]; then epic_disp="없음"; else epic_disp="$epic"; fi
marker="파생: #$num (Epic #$epic_disp · $priority)"

# ⑸ 발행 직후 readback — 폴백 건은 제외(#223: 못 다는 것이 확정된 레포에서 또 부르면
#    그 실패에 걸려 아래 PR 마커·BLOCKED 보고가 끊긴다. 복구는 사람 몫)
if [ "$labels_ok" = 1 ]; then
  view=$(gh issue view "$num" --repo "$repo" --json labels,body 2>/dev/null) || view=
  if [ -z "$view" ]; then
    echo "spinoff-issue: 발행 직후 readback 실패 — #$num" >&2
    rc=2
  else
    missing=$(printf '%s' "$view" | jq -r --arg p "$priority" \
      '[ "agent-ready", "spinoff", $p ] - [ .labels[]?.name // empty ] | join(" ")' 2>/dev/null)
    if [ -n "$missing" ]; then
      add=()
      for l in $missing; do add[${#add[@]}]=--add-label; add[${#add[@]}]=$l; done
      # **삼키지 않는다** (#467 P1-3): edit 가 실패했거나 2차 readback 이 비면 `still` 이 빈
      # 값이 되어 "붙었다" 로 읽힌다 — 확인 못 한 것을 확인된 것으로 쓰면 `agent-ready` 없는
      # 파생이 영영 안 집힌다(그게 이 readback 이 있는 이유다).
      if ! gh issue edit "$num" --repo "$repo" "${add[@]}" >/dev/null 2>&1; then
        echo "spinoff-issue: 라벨 보강 edit 실패 — #$num ($missing)" >&2
        rc=2
      fi
      view=$(gh issue view "$num" --repo "$repo" --json labels,body 2>/dev/null) || view=
      if [ -z "$view" ]; then
        echo "spinoff-issue: 라벨 보강 뒤 readback 실패 — #$num (부착 확인 불가)" >&2
        rc=2
      else
        still=$(printf '%s' "$view" | jq -r --arg p "$priority" \
          '[ "agent-ready", "spinoff", $p ] - [ .labels[]?.name // empty ] | join(" ")' 2>/dev/null)
        if [ -n "$still" ]; then
          echo "spinoff-issue: 라벨 보강 실패 — #$num ($still)" >&2
          rc=2
        fi
      fi
    fi
    if [ -n "$epic_line" ] && [ -n "$view" ]; then
      first=$(printf '%s' "$view" | jq -r '(.body // "") | split("\n")[0]' 2>/dev/null | tr -d '\r')
      if [ "$first" != "$epic_line" ]; then
        # `<EPIC_LINE>` 치환이 샌 것이다 — 즉시 고친다. 안 고치면 에픽 밖 고아로 남는다.
        gh issue edit "$num" --repo "$repo" --body-file "$rendered" >/dev/null 2>&1 \
          || { echo "spinoff-issue: Epic 첫 줄 교정 실패 — #$num" >&2; rc=2; }
      fi
    fi
  fi
else
  echo "spinoff-issue: 라벨 없이 발행됨(재시도 소진) — #$num" >&2
  rc=2
fi

# ⑹ 부모 PR 마커 — 중복 발행 방지. 폴백 건에서도 반드시 남긴다.
gh pr comment "$pr" --repo "$repo" --body "$marker" >/dev/null 2>&1 || {
  echo "spinoff-issue: 부모 PR 마커 실패 — PR #$pr ($marker)" >&2
  rc=2
}

echo "marker: $marker" >&2
printf '%s\n' "$num"
exit "$rc"
