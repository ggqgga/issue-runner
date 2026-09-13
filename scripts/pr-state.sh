#!/usr/bin/env bash
# pr-state.sh <repo> <pr>
#
# PR 하나가 `references/state-machine.md` 의 **어느 행**에 있는지, 누가 소유하는지,
# 그리고 그 행이 요구하는 미러가 어긋났는지를 한 판에 낸다 (#449 · 에픽 #443).
#
#   stdout `{"state":…,"owner":…,"mismatch":[…]}`  exit 0
#   무출력                                          exit 2  조회 실패
#   무출력                                          exit 64 호출 형태 오류
#
# **조회가 하나라도 실패하면 상태를 추측하지 않는다**(exit 2). 라벨 한 축만 못 읽고 나머지로
# 행을 고르면 "정지된 PR 이 S2 로 보이는" 류의 조용한 오판이 나오고, 그 오판은 전이를 부른다.
#
# ── 세 입력 ─────────────────────────────────────────────────────────────
# 표의 "상태" 정의 그대로 세 축이다: PR 라벨 집합 · 연결 이슈 라벨 집합 · 마지막 판정 코멘트.
#   ⑴ PR      `gh pr view --json state,labels,headRefName,closingIssuesReferences`
#   ⑵ 이슈    `lib/loop.jq` 의 `linked_issue`(#495) — head 의 `agent/issue-N` 이
#             `closingIssuesReferences` 에 있으면 N, 아니면 refs 가 정확히 1건일 때 그것, 아니면
#             `-`(이슈 축 없음. 미러 판정도 안 한다). `[0]` 을 쓰지 않는 이유는 실데이터다:
#             PR 이 이슈를 둘 이상 닫으면 첫 참조가 브랜치의 이슈가 아닐 수 있다
#             (이 레포 PR #113 — head `agent/issue-109`, refs `[108,109]`). 엉뚱한 이슈의
#             라벨을 읽으면 진짜 이슈의 홀드를 놓쳐 **승격**하거나, 무관한 홀드가 교정을 막는다.
#             `loop-status.sh` 의 `linked()`(#265)와 달리 **폴백 꼬리가 없다**: 거기는
#             대시보드라 못 찾으면 `[0]`·head 로 내려가 무엇이든 보여 주는 쪽이 맞고, 여기는
#             그 답이 라벨 편집을 부르므로 **추측하느니 이슈 축을 버린다**(`-`). finish-classify·
#             closeout-eligible·verify-eligible 도 같은 술어라 네 소비자가 다른 이슈를 볼 수 없다.
#   ⑶ 판정    `pr-comments.sh`(페이지네이션 전량) + `lib/loop.jq` 술어. 같은 코멘트 JSON 을
#             `BOUNCE_COMMENTS_FILE` 로 `bounce-state.sh` 에 그대로 먹여 반송 축도 얻는다 —
#             반송 마커 **문법**(구분자·조사·표식)은 loop.jq 의 접두 집합 밖이고 그 판정기는
#             `bounce-state.sh` 한 자리다(#171·#212·#251). 여기서 두 번째 벌을 만들지 않는다.
#             코멘트는 **한 번만** 조회해 두 소비처가 나눠 쓴다.
#
# ── 상태 선택 순서 (겹칠 때 무엇이 이기는가) ────────────────────────────
#   1. `E`        PR 이 MERGED·CLOSED — 종료 행. 라벨이 뭐가 남아 있든 끝난 PR 이다.
#   2. `H:human`  `needs-human`(PR·이슈 어느 쪽이든) — 사람이 세운 정지가 가장 세다.
#   3. `H:conflict` → `H:policy` → `H:ladder` 순. 사람 손이 필요한 정도 순서다:
#      conflict 는 사람만 푼다 · policy 는 재심 1회 뒤 사람 · ladder 는 창이 지나면 스스로
#      풀린다. 둘 이상 붙어 있으면 **덜 자동인 쪽**이 그 PR 의 실제 상태다.
#      사유를 모르는 `hold:<새 사유>` 는 `H:policy` 로 접는다 — 표에 행이 없는 정지를 자동
#      재개 칸(H:ladder)에 넣는 것보다 사람 재심이 있는 칸에 넣는 쪽이 안전하다(정지 자체는
#      어느 쪽이든 세 게이트가 `hold:` 접두로 제외한다 — 여기서 고르는 건 **이름**뿐이다).
#   4. PR 의 **소유 라벨**로 사다리 칸. 둘 이상이면 **하류(뒷칸)가 이긴다** — 뒷칸 루프가
#      이미 집었다는 뜻이고, 앞칸 라벨이 안 떨어진 것은 반쯤 이동이라 `mismatch` 로 나온다.
#      그래서 검사는 뒷칸부터다: harvesting=S5 → flow:ready=S4 → verifying=S3 →
#      flow:verify=S2 → flow:claimed=S1. 이슈 축(`issue_rung`)도 **같은 순서**를 쓴다.
#   5. 소유 라벨이 없으면: `bounce-state.sh` 가 `bounced` 면 `B`, 아니면 `S0`.
#      (표의 B 행은 PR `flow:agent-ready` — 대기 칸이라 소유 라벨이 아니다, loop.jq
#      `is_owner_label`. 그래서 4 와 5 는 겹치지 않는다.)
#
# ── mismatch 네 축 ──────────────────────────────────────────────────────
# 비어 있지 않으면 **표의 소유 루프가 전이로 맞춘다** — 이 스크립트는 판정만 하고 고치지
# 않는다(결정론 스크립트는 전이를 걸지 않는다). 항목은 사람이 읽는 한 줄 문자열이다:
#   `rung: pr=<S?> issue=<S?>`      PR 칸과 이슈 칸이 다르다(#281 미러가 갈렸다)
#   `stage: pr=[a,b]`               PR 에 **칸 라벨**이 둘 이상(반쯤 이동). 칸 라벨은 다섯이다
#                                   — harvesting·verifying·flow:ready·flow:verify·flow:claimed.
#                                   `flow:ci`·`flow:codex` 는 S1 안의 워커 내부 단계라
#                                   (표: "PR 에만 있는 워커 내부 단계") 여기 안 센다 —
#                                   `flow:claimed`+`flow:ci` 는 **정상 S1** 이다.
#   `stop: pr=[…] issue=[…]`        정지 라벨(needs-human·hold:*)이 한쪽에만 있다.
#                                   표의 정지 행은 전부 "PR·이슈 양쪽" 이다
#   `verdict: pr=S0 target=<라벨>`  **issue-runner ② 규칙0 의 안전망**: 칸 라벨도
#                                   `flow:agent-ready` 도 없는 PR(=미러 없이 열린 옛 PR)의
#                                   마지막 판정이 ✅ 면 `flow:ready`, 🔄 면 `flow:verify` 를
#                                   붙이라는 뜻이다. **행 이름이 아니라 붙일 라벨을 낸다** —
#                                   소비자(SKILL 규칙0)가 S4→`flow:ready` 를 자기 벌로 다시
#                                   외우면 그 매핑이 두 벌이 된다(이 스크립트가 없애려던 것).
#                                   `⚠ 보류` 는 단계 라벨 없음이 정답이라 어긋남이 아니다.
#                                   칸 라벨이 있거나
#                                   `flow:agent-ready` 인 PR 은 **이 축을 내지 않는다** —
#                                   워커·verify·closeout 레인이 소유한 칸을 판정 코멘트만
#                                   보고 올리면 살아 있는 워커의 PR 을 뺏는다(#420·#275).
#                                   **정지(H:*) 상태에서도 안 낸다** — 규칙0 은 정상 레인의
#                                   보정이고, 멈춘 PR 의 단계 라벨을 판정만 보고 올리면
#                                   재개 주체(resume-sweep·사람)가 받을 형상이 바뀐다.
# 연결 이슈가 없으면(`-`) `rung`·`stop` 두 축은 비교 대상이 없으니 내지 않는다.
# **`E`(종료) 는 네 축을 다 안 낸다** — 머지·닫힘 뒤에 남은 미러는 아무도 고치지 않는다.
#
# ── 왜 scope.sh·constants.sh 를 안 쓰는가 ───────────────────────────────
# 이 스크립트는 후보를 **열거**하지 않는다 — 호출자가 레포와 PR 을 콕 집어 준다. 거기에
# `.loop/repos` 스코프를 끼우면 "스코프 밖이라 상태 미상" 이라는 세 번째 결과가 생기는데,
# 그건 조회 실패(exit 2)와 구분이 안 되는 잡음이다(스코프는 게이트가 쓰는 장치다).
# 시간 창 상수도 안 쓴다 — 이 파일에 시간 축이 없다(스테일 판정은 finish-classify 몫).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: pr-state.sh <repo> <pr>" >&2; exit 64; }

[ "$#" = 2 ] || usage
repo="$1"; pr="$2"
[ -n "$repo" ] || usage
case "$pr" in ''|*[!0-9]*) usage ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-state.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

# ── ⑴ PR 축 ─────────────────────────────────────────────────────────────
meta=$(gh pr view "$pr" --repo "$repo" \
  --json state,labels,headRefName,closingIssuesReferences 2>/dev/null) || exit 2
[ -n "$meta" ] || exit 2
pr_labels=$(printf '%s' "$meta" | jq -c '[.labels[].name]' 2>/dev/null) || exit 2
[ -n "$pr_labels" ] || exit 2
pr_state=$(printf '%s' "$meta" | jq -r '.state // ""' 2>/dev/null) || exit 2
# 짝 이슈 = `lib/loop.jq` 의 `linked_issue`(#495 · 위 ⑵). 짝을 증명 못 하면 `-`.
issue=$(printf '%s' "$meta" | jq -L "$SCRIPT_DIR/lib" -r 'include "loop";
  linked_issue(.headRefName; [(.closingIssuesReferences // [])[].number])
  | if . == null then "-" else tostring end
' 2>/dev/null) || exit 2
[ -n "$issue" ] || exit 2

# ── ⑵ 이슈 축 ───────────────────────────────────────────────────────────
issue_labels='[]'
if [ "$issue" != "-" ]; then
  imeta=$(gh issue view "$issue" --repo "$repo" --json labels 2>/dev/null) || exit 2
  [ -n "$imeta" ] || exit 2
  issue_labels=$(printf '%s' "$imeta" | jq -c '[.labels[].name]' 2>/dev/null) || exit 2
  [ -n "$issue_labels" ] || exit 2
fi

# ── ⑶ 판정·반송 축 (코멘트 1회 조회를 둘이 나눠 쓴다) ────────────────────
"$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" > "$tmp/comments.json" 2>/dev/null || exit 2
[ -s "$tmp/comments.json" ] || exit 2

# 마지막 **판정 코멘트**의 기호. 술어·인덱스 규율은 lib/loop.jq 한 자리 (#426) —
# 선후는 createdAt 이 아니라 배열 인덱스다(동초 선후를 시각으로는 못 가른다).
verdict=$(jq -L "$SCRIPT_DIR/lib" -r 'include "loop";
  [.[].body] as $b
  | ($b | last_index(is_verdict_any)) as $i
  | if $i == null then "-"
    elif ($b[$i] | is_verdict_ok)      then "ok"
    elif ($b[$i] | is_verdict_pending) then "pending"
    else "hold" end' < "$tmp/comments.json" 2>/dev/null) || exit 2
[ -n "$verdict" ] || exit 2

bounce=$(BOUNCE_COMMENTS_FILE="$tmp/comments.json" \
  "$SCRIPT_DIR/bounce-state.sh" "$repo" "$pr" 2>/dev/null) || exit 2
[ -n "$bounce" ] || exit 2

# ── 판정 ────────────────────────────────────────────────────────────────
out=$(jq -L "$SCRIPT_DIR/lib" -n -c \
  --argjson pl "$pr_labels" --argjson il "$issue_labels" \
  --arg pr_state "$pr_state" --arg verdict "$verdict" \
  --arg bounce "$bounce" --arg issue "$issue" '
  include "loop";

  # PR 소유 라벨 → 사다리 칸. **하류(뒷칸)가 이긴다** — 검사 순서가 곧 그 규칙이라
  # S5 → S4 → S3 → S2 → S1 순으로 내려간다. `verifying`(S3) 을 `flow:ready`(S4) 보다
  # 먼저 보면 반쯤 이동한 `verify-pass`(verifying+flow:ready)가 S3/verify-runner 로 나와
  # 산문이 광고한 규칙과 어긋난다(#465 codex 2회차 [P2-2]).
  def pr_rung:
    if   index("harvesting")   then "S5"
    elif index("flow:ready")   then "S4"
    elif index("verifying")    then "S3"
    elif index("flow:verify")  then "S2"
    elif index("flow:claimed") then "S1"
    else null end;
  # 이슈 칸 라벨 → 같은 사다리, **같은 하류 우선 순서**(두 축이 다른 순서를 쓰면 정상
  # 미러가 `rung` 불일치로 나온다). `agent-ready` 는 사다리 전체에서 유지되는 **자격**
  # 라벨이라 맨 뒤다 — 앞의 어느 칸도 아닐 때만 S0 이다.
  def issue_rung:
    if   index("harvesting")     then "S5"
    elif index("flow:ready")     then "S4"
    elif index("verifying")      then "S3"
    elif index("flow:verify")    then "S2"
    elif index("agent:claimed")  then "S1"
    elif index("agent-ready")    then "S0"
    else null end;
  def owner_of:
    { "S0":"issue-runner", "S1":"worker", "S2":"verify-runner", "S3":"verify-runner",
      "S4":"closeout", "S5":"closeout",
      "H:ladder":"resume-sweep", "H:policy":"issue-runner",
      "H:conflict":"human", "H:human":"human", "B":"worker", "E":"-" }[.] // "-";
  def fmt: "[" + join(",") + "]";

  # 칸 라벨 다섯 — `flow:ci`·`flow:codex`(S1 내부 단계)는 칸이 아니다.
  ["harvesting","verifying","flow:ready","flow:verify","flow:claimed"] as $rungs
  | ($pl + $il) as $all
  | ($pl | pr_rung) as $prr
  | (if $issue == "-" then null else ($il | issue_rung) end) as $ilr
  # 판정 → 규칙0 이 붙일 단계 라벨. 이 매핑의 **유일한 자리**다(표 SSOT 의 S4·S2 행).
  | (if   $verdict == "ok"      then "flow:ready"
     elif $verdict == "pending" then "flow:verify"
     else null end) as $vtarget
  | ([$pl[] | select(. as $x | $rungs | index($x))]) as $pr_rung_labels

  | (if   $pr_state == "MERGED" or $pr_state == "CLOSED" then "E"
     elif ($all | any(is_human_stop_label))    then "H:human"
     elif ($all | any(. == "hold:conflict"))   then "H:conflict"
     elif ($all | any(. == "hold:policy"))     then "H:policy"
     elif ($all | any(. == "hold:ladder"))     then "H:ladder"
     elif ($all | any(is_hold_label))          then "H:policy"
     elif $prr != null                         then $prr
     elif $bounce == "bounced"                 then "B"
     else "S0" end) as $state

  | (if $state == "E" then []      # 종료 행은 고칠 주체가 없다 — 네 축 다 안 낸다.
     else []
     # 미러 두 축 — 연결 이슈가 있을 때만 비교한다.
     + (if $ilr != null and (($prr // "S0") != $ilr)
        then ["rung: pr=" + ($prr // "S0") + " issue=" + $ilr] else [] end)
     + (if ($pr_rung_labels | length) > 1
        then ["stage: pr=" + ($pr_rung_labels | sort | fmt)] else [] end)
     + (if $issue != "-" and (($pl | stop_labels | sort) != ($il | stop_labels | sort))
        then ["stop: pr=" + ($pl | stop_labels | sort | fmt)
              + " issue=" + ($il | stop_labels | sort | fmt)] else [] end)
     # 규칙0 안전망 — 정상 레인(S0·B)의, 칸 라벨도 flow:agent-ready 도 없는 PR 만(#420·#275).
     + (if ($state == "S0" or $state == "B")
           and (($pl | any(. == "flow:agent-ready")) | not) and $vtarget != null
        then ["verdict: pr=" + $state + " target=" + $vtarget] else [] end)
     end) as $mismatch

  | {state: $state, owner: ($state | owner_of), mismatch: $mismatch}
' 2>/dev/null) || exit 2
[ -n "$out" ] || exit 2
printf '%s\n' "$out"
