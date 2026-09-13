#!/usr/bin/env bash
# deploy-wait-issue.sh <owner/repo> <pr> --sha <merge sha> --summary-file <f> --items-file <f|없음>
#                      [--title <요약>] [--lane closeout|full-cycle] [--hardware]
#                      [--verify-url <url>] [--deploy-cmd <cmd>] [--priority <P0|P1>]
#                      [--parent-issue <N>] [--template <f>]
#
# 머지된 PR 하나당 **배포 대기 이슈 하나**를 발행한다 — closeout 4단계와 full-cycle §7 이
# 같은 형식을 각자 산문으로 밟던 것을 한 자리로 접은 것이다 (#446 · 에픽 #443 2단계).
#
# ⚠️ **여기 있는 리터럴은 파싱 계약이다 — deploy-cycle · deploy-bodat 이 읽는다.**
#    바꾸면 그 두 스킬이 티켓을 **못 찾는다**. 하나라도 손대기 전에 그 소비자부터 고쳐라.
#      · 제목 정규식 : `배포 대기: PR #<M>`  ← deploy-bodat 수집은 라벨이 아니라 **제목**이다
#      · 승격만 접미 : ` (승격만)`            ← 밟을 항목이 0인 티켓(5단계 스모크 건너뜀)
#      · 절 이름     : `## 검증 URL` · `## 라이브/하드웨어 검증 항목`
#                      (closeout 5단계가 이 두 절을 파싱해 스모크 프롬프트에 채운다)
#      · 항목 없음   : `없음` 한 단어           ← "없음. 주석뿐이다" 같은 서술은 `없음` 이 아니다
#      · PR 마커     : `배포 대기: #<이슈번호>`
#      · 라벨        : `deploy-wait` (deploy-cycle 이 이 티켓을 집는 **레인 표식**이자
#                      `loop-status.sh` 의 배포대기 버킷). 이 하나가 필수다.
#    본문 골격은 `skills/closeout/references/deploy-check-issue.md`(placeholder
#    `<PR> <SHA> <SUMMARY> <DEPLOY_CMD> <LIVE_CHECKS> <VERIFY_URL>`) — `--template` 로 갈아끼울 수 있다.
#    `--deploy-cmd` 값 양끝 백틱은 벗기고 템플릿이 한 번만 감싼다 — 값에 백틱을 넣지
#    않아도 되고, 넣어도 이중으로 감싸지지 않는다.
#
# ── 하는 일 ───────────────────────────────────────────────────────────────────
# ⑴ 항목 형태 강제(발행 **전**): `--items-file` 은 `없음` 한 줄이거나 **모든 줄이** `- [ ] `
#    (또는 이미 밟힌 `- [x] `) 체크박스여야 한다. 한 줄이라도 어긋나면 **아무것도 만들지 않고
#    exit 65** (#467 P2-1 — 총수만 세면 "유효 항목 1 + 산문 1" 이 통과해 그 산문 줄이 이슈에
#    실리고 5단계 집계는 그것을 무시한다: 밟아야 할 것이 원장에서 조용히 사라진다) —
#    자유 산문이면 아래 분기(5단계 스모크 여부·⑦ 이관)가 매 틱 해석에 맡겨져 흔들린다
#    (실측 2026-08-12~13: 배포검증 이슈 186건 중 체크박스를 쓴 건 0건, 전부 산문이었다).
#    세는 일은 `smoke-tally.sh --checks` 한 자리다(#448) — 여기서 다시 세지 않는다.
#    체크박스가 0이면 제목에 ` (승격만)` 이 붙고 본문 절엔 `없음` 이 그대로 남는다.
# ⑵ 라벨: `deploy-wait` + 레인(`--lane full-cycle` 이면 `full-cycle`) + P(`--priority`,
#    없으면 `--parent-issue` 로 `spinoff-inherit.sh` 상속) + `--hardware` 이고 **레포에 그
#    라벨이 실제로 있을 때만** `needs:hardware`. `needs-human` 은 붙이지 않는다(#243) —
#    발행 시점엔 사람 몫이 없다(디스패치 게이트는 `agent-ready` 를 요구하고, deploy-bodat
#    수집은 제목 정규식이다). 그 라벨을 붙이는 주체는 deploy-cycle 이다.
# ⑶ 라벨 부재 fail-closed — 티켓을 잃지 않는다: `gh issue create` 는 레포에 없는 라벨이
#    하나라도 있으면 이슈 자체를 안 만들고 실패한다. `not found` 류면 `setup-labels.sh` 를
#    **1회** 부르고 같은 명령을 **1회만** 재시도한다. 그래도 실패하면 **`--label` 을 하나도
#    주지 않고 발행**한다(유실 방지 — `loop-status.sh` 는 제목 `배포 대기:` 폴백으로 여전히
#    배포대기로 센다) → exit 2. 그 폴백 건은 아래 ⑷ 라벨 보강에서 **제외**한다(#223: 이미
#    "이 레포에선 지금 라벨을 못 단다" 가 확정이라 또 부르면 또 실패하고, 그 실패에 걸려
#    뒤따르는 PR 마커·BLOCKED 보고가 끊긴다 — 티켓은 있는데 아무도 모르는 상태가 된다).
#    폴백 건의 복구는 사람 3단 조치가 소유한다: ⑴ `setup-labels.sh <repo>` 재실행으로 라벨
#    **정의**를 만들고 ⑵ `gh issue edit <번호> --add-label deploy-wait` 로 **그 이슈에** 붙이고
#    ⑶ `gh issue view <번호> --json labels` 로 확인한다(둘째 단을 빠뜨리면 그 티켓은 계속 무라벨이다).
# ⑷ 발행 직후 라벨 readback + 보강(`deploy-wait` 이 실제로 붙었는지 다시 읽는다).
# ⑸ 부모 PR 에 `배포 대기: #<번호>` 마커 코멘트.
#
# ── 출력·종료코드 ─────────────────────────────────────────────────────────────
#   stdout : 새 이슈 번호 한 줄
#   exit 0 : 정상 · 1 : **이슈 미생성**(발행 실패·인자 해석 실패, 무출력)
#   exit 2 : **이슈는 생성됨**(번호는 stdout) — 라벨 부착·마커가 어긋났다. 호출자는
#            `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` 로 보고한다.
#   exit 64: usage · 65: 항목 형태 위반(발행 전 — 고쳐서 **다시 부르면 된다**, 잃은 것 없음)
#
# macOS bash 3.2 대상(연관배열·mapfile·${var^^} 금지).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"

usage() {
  echo "usage: deploy-wait-issue.sh <owner/repo> <pr> --sha <sha> --summary-file <f> --items-file <f|없음> [--title <요약>] [--lane closeout|full-cycle] [--hardware] [--verify-url <url>] [--deploy-cmd <cmd>] [--priority <P0|P1>] [--parent-issue <N>] [--template <f>]" >&2
}

repo=${1:-}; pr=${2:-}
[ -n "$repo" ] && [ -n "$pr" ] || { usage; exit 64; }
shift 2
case "$pr" in ''|*[!0-9]*) echo "deploy-wait-issue: PR 번호가 숫자가 아니다: $pr" >&2; exit 64 ;; esac

sha=; summary_file=; items_arg=; title_sum=; lane=closeout; hardware=0
verify_url=; deploy_cmd=; priority=; parent=; template=
while [ $# -gt 0 ]; do
  case "$1" in
    --sha)          [ $# -ge 2 ] || { usage; exit 64; }; sha=$2; shift 2 ;;
    --summary-file) [ $# -ge 2 ] || { usage; exit 64; }; summary_file=$2; shift 2 ;;
    --items-file)   [ $# -ge 2 ] || { usage; exit 64; }; items_arg=$2; shift 2 ;;
    --title)        [ $# -ge 2 ] || { usage; exit 64; }; title_sum=$2; shift 2 ;;
    --lane)         [ $# -ge 2 ] || { usage; exit 64; }; lane=$2; shift 2 ;;
    --hardware)     hardware=1; shift ;;
    --verify-url)   [ $# -ge 2 ] || { usage; exit 64; }; verify_url=$2; shift 2 ;;
    --deploy-cmd)   [ $# -ge 2 ] || { usage; exit 64; }; deploy_cmd=$2; shift 2 ;;
    --priority)     [ $# -ge 2 ] || { usage; exit 64; }; priority=$2; shift 2 ;;
    --parent-issue) [ $# -ge 2 ] || { usage; exit 64; }; parent=$2; shift 2 ;;
    --template)     [ $# -ge 2 ] || { usage; exit 64; }; template=$2; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
[ -n "$sha" ] || { usage; exit 64; }
[ -n "$title_sum" ] || { usage; exit 64; }
[ -n "$summary_file" ] && [ -r "$summary_file" ] || { echo "deploy-wait-issue: 요약 파일을 읽을 수 없다: $summary_file" >&2; exit 64; }
[ -n "$items_arg" ] || { usage; exit 64; }
case "$lane" in
  closeout)   lane_note='closeout 4단계 → deploy-cycle 레인' ;;
  full-cycle) lane_note='사람 세션 full-cycle — 사람 게이트' ;;
  *) echo "deploy-wait-issue: --lane 은 closeout|full-cycle 뿐: $lane" >&2; exit 64 ;;
esac
[ -n "$template" ] || template="$here/../skills/closeout/references/deploy-check-issue.md"
[ -r "$template" ] || { echo "deploy-wait-issue: 본문 템플릿을 읽을 수 없다: $template" >&2; exit 64; }
[ -n "$deploy_cmd" ] || deploy_cmd="레포 배포 절차"
# 양끝 백틱은 벗긴다 — 템플릿(`<DEPLOY_CMD>`)이 이미 한 번 감싸므로, 값에 백틱을 넣어도
# 이중으로 감싸이지 않는다.
case "$deploy_cmd" in
  '`'*'`') deploy_cmd=${deploy_cmd#\`}; deploy_cmd=${deploy_cmd%\`} ;;
esac

# `--verify-url` 이 `없음`(또는 `(해당 없음`으로 시작)이면 BoDAT Tailscale 안내 산문을
# 붙이지 않고 값만 남긴다 — 그 외엔 지금 그대로. 본문은 아래 tmp 생성 이후에 채운다.
show_verify_note=1
case "$verify_url" in
  없음|'(해당 없음'*) show_verify_note=0 ;;
esac

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# ⑴ 항목 형태 강제 — 세는 일은 smoke-tally.sh --checks 한 자리
items="$tmp/items.md"
if [ "$items_arg" = "없음" ]; then
  printf '없음\n' > "$items"
else
  [ -r "$items_arg" ] || { echo "deploy-wait-issue: 항목 파일을 읽을 수 없다: $items_arg" >&2; exit 64; }
  cat "$items_arg" > "$items"
fi
# **모든 줄이 형태를 지켰는지 본다** (#467 P2-1). 총수만 세면 "유효 항목 1 + 산문 1" 이
# 통과해 그 산문 줄이 이슈에 실리고, 5단계 집계는 체크박스가 아니라 무시한다 — 밟아야 할
# 것이 원장에서 조용히 사라지는 형상이다. 빈 줄이 아닌 모든 줄은 `- [ ] `(또는 이미 밟힌
# `- [x] `) 이거나, 절 전체가 정확히 `없음` 한 줄이어야 한다.
only_none=0
if [ "$(tr -d ' \t\r' < "$items" | grep -vc '^$')" = 1 ] \
   && [ "$(tr -d ' \t\r' < "$items" | grep -v '^$')" = "없음" ]; then
  only_none=1
fi
if [ "$only_none" = 0 ]; then
  badline=$(grep -vE '^[[:space:]]*$' "$items" | grep -vE '^[[:space:]]*- \[( |x|X)\] ' | head -1)
  if [ -n "$badline" ]; then
    echo "deploy-wait-issue: 항목 형태 위반 — \`없음\` 한 줄이거나 \`- [ ] \` 목록이어야 한다(산문 금지)." >&2
    echo "  첫 위반 줄: $badline" >&2
    echo "  배경·근거·주의는 --summary-file 로 보내고, 항목 자리엔 밟을 것만 남겨 **다시 부르라**." >&2
    exit 65
  fi
fi

open=$("$here/smoke-tally.sh" --checks "$items" | sed -n 's/.*"open":\([0-9][0-9]*\).*/\1/p')
case "$open" in ''|*[!0-9]*) echo "deploy-wait-issue: 항목 집계 실패(smoke-tally.sh)" >&2; exit 1 ;; esac

promo_only=0
if [ "$open" = 0 ]; then
  # 열린 체크박스가 0 = `없음` 절이거나 전부 `- [x]` — 앞의 형태 검사를 이미 통과했다.
  if [ "$only_none" = 0 ]; then
    echo "deploy-wait-issue: 항목 형태 위반 — 밟을 열린 항목이 0인데 \`없음\` 절이 아니다." >&2
    exit 65
  fi
  promo_only=1
  printf '없음\n' > "$items"
fi

# ⑵ 라벨 — P 상속(명시 > 부모 상속 > 없음)
if [ -z "$priority" ] && [ -n "$parent" ]; then
  case "$parent" in
    ''|*[!0-9]*) echo "deploy-wait-issue: --parent-issue 가 숫자가 아니다: $parent — P 상속 생략" >&2 ;;
    *)
      inh=$("$here/spinoff-inherit.sh" "$repo" "$parent" 2>/dev/null) && eval "$inh" \
        || echo "deploy-wait-issue: P 상속 실패(부모 #$parent) — P 라벨 없이 발행한다" >&2 ;;
  esac
fi
case "${priority:-}" in P0|P1) ;; *) priority= ;; esac

labels=(--label deploy-wait)
[ "$lane" = full-cycle ] && { labels[${#labels[@]}]=--label; labels[${#labels[@]}]=full-cycle; }
[ -n "$priority" ] && { labels[${#labels[@]}]=--label; labels[${#labels[@]}]=$priority; }
if [ "$hardware" = 1 ]; then
  # **레포에 정의가 있을 때만** 붙인다 — 없는 라벨 하나가 create 를 통째로 실패시키고,
  # 그 실패가 아래 3단 사다리를 태워 `deploy-wait` 까지 잃게 만든다(필수 라벨이 아니다).
  if gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null | grep -qx 'needs:hardware'; then
    labels[${#labels[@]}]=--label; labels[${#labels[@]}]='needs:hardware'
  else
    echo "deploy-wait-issue: needs:hardware 라벨이 레포에 없어 생략한다" >&2
  fi
fi

# `<VERIFY_URL_NOTE>` 값(BoDAT Tailscale 안내 산문, 2줄) — 파일로 넘겨야 awk -v 가
# 개행을 그대로 받는다(-v 인자에 리터럴 개행을 직접 넣으면 "newline in string" 파싱 실패).
verify_note_file="$tmp/verify-note.md"
if [ "$show_verify_note" = 1 ]; then
  cat > "$verify_note_file" <<'EOF'
 (production 베이스 URL. closeout 5단계가 이 URL 로 Chrome 스모크를 몰아 아래 검증 항목을 대조한다. **자동화 크롬이 실제로 여는 주소를 적어라** — BoDAT 은 `http://100.65.53.51:3000`(Tailscale)이고 `bodat.local`·LAN IP 는 크롬에서만 안 열린다: BoDAT `deploy-bodat` 5절.)
레포가 dev 스테이지를 두는 경우 상세 검증은 그쪽에서 먼저 수행될 수 있고, 이 URL 스모크는 배포 후 마지막 안전망이다.
EOF
else
  : > "$verify_note_file"
fi

# 본문 — 템플릿 placeholder 치환(줄 전체 placeholder 는 파일 내용으로, 인라인은 문자열로)
body="$tmp/body.md"
awk -v pr="$pr" -v sha="$sha" -v url="$verify_url" -v notef="$verify_note_file" -v cmd="$deploy_cmd" \
    -v lane_note="$lane_note" -v sumf="$summary_file" -v itemf="$items" '
  function rep(s, from, to,   i) {
    while ((i = index(s, from)) > 0) s = substr(s, 1, i - 1) to substr(s, i + length(from))
    return s
  }
  function dump(f,   l) { while ((getline l < f) > 0) print l; close(f) }
  function slurp(f,   l, s) {
    while ((getline l < f) > 0) s = (s == "" ? l : s "\n" l)
    close(f); return s
  }
  BEGIN { vnote = slurp(notef) }
  {
    if ($0 == "<SUMMARY>")     { dump(sumf);  next }
    if ($0 == "<LIVE_CHECKS>") { dump(itemf); next }
    line = $0
    line = rep(line, "<PR>", pr)
    line = rep(line, "<SHA>", sha)
    line = rep(line, "<VERIFY_URL_NOTE>", vnote)
    line = rep(line, "<VERIFY_URL>", url)
    line = rep(line, "<DEPLOY_CMD>", cmd)
    line = rep(line, "<LANE_NOTE>", lane_note)
    line = rep(line, "<SUMMARY>", "")
    line = rep(line, "<LIVE_CHECKS>", "")
    print line
  }
' "$template" > "$body"

title="배포 대기: PR #$pr — $title_sum"
[ "$promo_only" = 1 ] && title="$title (승격만)"

create() {
  if [ "$1" = with-labels ]; then
    gh issue create --repo "$repo" --title "$title" --body-file "$body" "${labels[@]}" 2>"$tmp/err"
  else
    gh issue create --repo "$repo" --title "$title" --body-file "$body" 2>"$tmp/err"
  fi
}

# ⑶ 발행 + 라벨 부재 3단 사다리
labels_ok=1
out=$(create with-labels) || {
  if grep -qi 'not found' "$tmp/err"; then
    "$here/setup-labels.sh" "$repo" >/dev/null 2>&1
    out=$(create with-labels) || out=
  else
    out=
  fi
  if [ -z "$out" ]; then
    labels_ok=0
    out=$(create no-labels) || {
      echo "deploy-wait-issue: 이슈 발행 실패 — $(tail -1 "$tmp/err")" >&2
      exit 1
    }
  fi
}

num=$(printf '%s\n' "$out" | tr -d ' ' | sed -n 's#.*/issues/\([0-9][0-9]*\)$#\1#p' | tail -1)
case "$num" in
  ''|*[!0-9]*) echo "deploy-wait-issue: 발행 결과에서 이슈 번호를 못 읽었다: $out" >&2; exit 1 ;;
esac

rc=0
# ⑷ 라벨 readback — 폴백 건은 제외(#223)
if [ "$labels_ok" = 1 ]; then
  got=$(gh issue view "$num" --repo "$repo" --json labels -q '.labels[].name' 2>/dev/null)
  if ! printf '%s\n' "$got" | grep -qx 'deploy-wait'; then
    gh issue edit "$num" --repo "$repo" --add-label deploy-wait >/dev/null 2>&1 || true
    got=$(gh issue view "$num" --repo "$repo" --json labels -q '.labels[].name' 2>/dev/null)
    printf '%s\n' "$got" | grep -qx 'deploy-wait' \
      || { echo "deploy-wait-issue: deploy-wait 라벨 부착 실패 — #$num" >&2; rc=2; }
  fi
else
  echo "deploy-wait-issue: 라벨 없이 발행됨(재시도 소진) — #$num" >&2
  rc=2
fi

# ⑸ PR 마커 — 폴백 건에서도 반드시 남긴다(티켓은 있는데 아무도 모르는 상태 방지)
gh pr comment "$pr" --repo "$repo" --body "배포 대기: #$num" >/dev/null 2>&1 || {
  echo "deploy-wait-issue: PR 마커 실패 — PR #$pr (배포 대기: #$num)" >&2
  rc=2
}

printf '%s\n' "$num"
exit "$rc"
