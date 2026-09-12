#!/usr/bin/env bash
# spinoff-inherit.sh 픽스처 테스트 — 네트워크 무접속(gh 는 PATH 스텁), 기대값은 손으로.
#
# #261: closeout 6단계 파생 발행이 부모의 `Epic #N` 줄·우선순위를 **기계적으로** 상속하도록
# 만든 결정론 헬퍼의 SSOT 테스트다. 무는 것:
#   ⑴ `epic=<N|->` 판정이 `loop-status.sh` 의 `epic_of`(#260) 와 **같은 줄 앵커 규칙**인가
#      — 산문 속 `… epic #N …`·백틱 인용·공백 없는 `Epic#N` 은 신호가 아니다(전용 줄만).
#   ⑵ `priority=<P0|P1>` 가 `eligible-issues.sh` 와 같은 축(P0 아니면 전부 P1, #401)인가
#   ⑶ 조회 실패가 **출력 0줄 + exit 1** 로 fail-closed 하는가(상속 없이 발행하지 않는다)
#   ⑷ 부모를 **한 번만** 읽는가(gh 호출 1회)
#   ⑸ 출력이 `eval "$(...)"` 로 그대로 쉘 변수가 되는가(6단계 발행 명령의 계약)
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
# 런타임 의존은 `jq` 뿐 — 이 레포가 이미 광범위하게 쓰는 도구다(python3·perl 안 쓴다).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/spinoff-inherit.sh"

command -v jq >/dev/null 2>&1 || { echo "  ✗ jq 미설치 — 이 테스트는 jq 를 요구한다"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"

# gh 스텁 — 호출을 기록하고, 기대한 형태의 호출이 아니면 exit 3 으로 드러낸다.
# (헬퍼가 `--json body,labels` 한 번 대신 여러 번 묻는 회귀를 여기서 잡는다.)
cat > "$tmp/stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SI_CALLS"
case "$*" in
  *"issue view"*"--json body,labels"*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 3 ;;
esac
if [ "${SI_RC:-0}" != 0 ]; then
  # SI_PARTIAL=1 이면 **stdout 에 부분 출력을 흘리면서** 실패한다 — PR#139 의 형상
  # (부분 실패의 부분 출력이 정상값으로 채택돼 fail-closed 분기를 우회하는 경로).
  if [ "${SI_PARTIAL:-0}" = 1 ]; then printf '%s' '{"body":"","labels":[]}'; fi
  echo "gh: could not resolve to an Issue with the number of 4979" >&2
  exit "${SI_RC}"
fi
cat "$SI_FIXTURE"
EOF
chmod +x "$tmp/stub/gh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

PARENT=4979

# mkfx <body> <label-csv> — gh issue view --json body,labels 의 응답 JSON 을 만든다.
mkfx() {
  labels=$(printf '%s' "$2" | jq -Rs 'split(",") | map(select(. != "")) | map({name: .})')
  jq -n --arg b "$1" --argjson l "$labels" '{body: $b, labels: $l}'
}

# run <fixture-json> [gh-rc] [parent] — OUT/RC/CALLS/LINES 를 채운다.
run() {
  printf '%s' "$1" > "$tmp/fx.json"
  : > "$tmp/calls.log"
  OUT=$(SI_FIXTURE="$tmp/fx.json" SI_CALLS="$tmp/calls.log" SI_RC="${2:-0}" \
        PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT "${3:-$PARENT}" 2>/dev/null)
  RC=$?
  CALLS=$(wc -l < "$tmp/calls.log" | tr -d ' ')
  if [ -z "$OUT" ]; then LINES=0; else LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' '); fi
}

# check <desc> <body> <label-csv> <want-epic> <want-prio>
check() {
  run "$(mkfx "$2" "$3")" 0
  want="epic=$4
priority=$5"
  if [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; then ok; else
    bad "$1 — rc=$RC out=[$OUT] want=[$want]"
  fi
  if [ "$LINES" = 2 ]; then ok; else bad "$1 — stdout ${LINES}줄 (기대 정확히 2줄)"; fi
  if [ "$CALLS" = 1 ]; then ok; else bad "$1 — gh 호출 ${CALLS}회 (기대 1회: 본문·라벨 한 번에)"; fi
}

echo "── 수용 기준 5케이스 ①~⑤ ───────────────────────────────────────────"

# ① 부모에 `Epic #4962` + P1 → epic=4962 · priority=P1
check "① Epic 줄 + P1" \
  $'Epic #4962\n\n## 배경\n어쩌고.' 'P1,difficulty:easy' 4962 P1

# ② 부모 단발(에픽 줄 없음)·P 라벨 없음 → epic=- · priority=P1
check "② 단발 + P 없음" \
  $'## 배경\n에픽 줄이 없는 단발 이슈.' 'difficulty:medium,frontend' - P1

# ③ 부모가 `epic` 라벨 이슈 자체 → epic=<부모번호>
check "③ epic 라벨 부모" \
  $'## 배경\n이 이슈가 에픽 본체다.' 'epic' "$PARENT" P1

# ④ 산문 속 `epic #N` 만 → epic=- (전용 줄만 신호)
check "④ 산문 속 epic #N" \
  $'## 배경\n이건 epic #4962 의 하위처럼 보이지만 전용 줄이 아니다.' 'P2' - P1

# ⑤ 조회 실패 → 출력 0줄, exit 1 (fail-closed — 상속 없이 발행하지 않는다)
run "$(mkfx 'Epic #4962' 'P1')" 1
if [ "$RC" = 1 ] && [ -z "$OUT" ]; then ok; else bad "⑤ 조회 실패 fail-closed — rc=$RC out=[$OUT] (기대 rc=1·무출력)"; fi

echo '── epic= 판정 격자 — 전용 줄만 신호(loop-status.sh epic_of 와 동일 규칙) ──'

# want 열을 가진 전수 격자 — 리뷰가 짚은 개별 반례만 막지 말고 규칙 자체를 단언한다(PR#202).
check "격자: 대문자 Epic, 본문 첫 줄"      $'Epic #4962\n본문' ''        4962 P1
check "격자: 소문자 epic, 줄 시작"          $'epic #4962\n본문' ''        4962 P1
check "격자: 전대문자 EPIC"                 $'EPIC #4962\n본문' ''        4962 P1
check "격자: 대소문자 혼합 EpIc"            $'EpIc #4962\n본문' ''        4962 P1
check "격자: 앞 공백 2칸"                   $'  Epic #4962\n본문' ''      4962 P1
check "격자: 앞 탭"                         $'\tEpic #4962\n본문' ''      4962 P1
check '격자: Epic 과 # 사이 공백 2칸'       $'Epic  #4962\n본문' ''       4962 P1
check "격자: 첫 줄 아닌 셋째 줄"            $'머리말\n\nEpic #4962\n본문' '' 4962 P1
check "격자: CRLF 본문"                     $'Epic #4962\r\n본문\r\n' ''  4962 P1
check "격자: 백틱 인용 줄(전용 줄 아님)"    $'`Epic #4962`\n본문' ''      -    P1
check "격자: 공백 없는 Epic#4962"           $'Epic#4962\n본문' ''         -    P1
check "격자: 산문 중간 등장"                $'부모는 Epic #4962 이다\n본문' '' - P1
check "격자: 줄 앞 불릿(- Epic #N)"         $'- Epic #4962\n본문' ''      -    P1
check "격자: 숫자 아닌 #abc"                $'Epic #abc\n본문' ''         -    P1
check "격자: 빈 본문"                       ''                       ''       -    P1
check "격자: Epic 줄 2개 — 첫 매치만"       $'Epic #4962\nEpic #5001\n본문' '' 4962 P1
check "격자: Epics #N(접미 s)은 신호 아님"  $'Epics #4962\n본문' ''       -    P1

echo '── priority= 판정 — eligible-issues.sh 와 같은 축(P0 아니면 전부 P1, #401) ──'

check "P0 단독"                  $'## 배경' 'P0'          - P0
check "P1 단독"                  $'## 배경' 'P1'          - P1
# 재라벨 전 과도기의 `P2` 부모는 `P1` 을 물려준다 — 디스패치가 이미 한 칸으로 보므로
# 파생만 사라질 등급을 물고 다닐 이유가 없다.
check "P2 단독 → P1(과도기)"     $'## 배경' 'P2'          - P1
check "P0+P1 혼재 → P0"          $'## 배경' 'P1,P0'       - P0
check "P0+P2 혼재 → P0"          $'## 배경' 'P2,P0'       - P0
check "P1+P2 혼재 → P1"          $'## 배경' 'P2,P1'       - P1
check "P 없음 → P1 기본값"       $'## 배경' 'spinoff'     - P1
check "라벨 0개 → P1 기본값"     $'## 배경' ''            - P1
# 유사 라벨이 P 라벨로 오독되면 안 된다(`P0` 와 `P0-blocked` 는 다른 라벨).
check "유사 라벨 P0-blocked"     $'## 배경' 'P0-blocked'  - P1

echo "── epic 라벨 × Epic 줄 동시 — 라벨이 이긴다(부모 자신이 에픽이다) ──"
check "epic 라벨 + Epic 줄"  $'Epic #4962\n본문' 'epic,P1' "$PARENT" P1

echo "── fail-closed 갈래 ────────────────────────────────────────────────"

# gh 가 다른 비-0 코드로 죽어도 같은 계약(무출력·exit 1).
run "$(mkfx 'Epic #4962' 'P1')" 2
if [ "$RC" = 1 ] && [ -z "$OUT" ]; then ok; else bad "gh rc=2 → 무출력·exit 1 — rc=$RC out=[$OUT]"; fi

# **부분 출력을 흘리며** 실패해도 fail-closed — 부분 출력이 정상값으로 채택되면 안 된다(PR#139).
printf '%s' "$(mkfx $'Epic #4962\n본문' 'P1')" > "$tmp/fx.json"
: > "$tmp/calls.log"
OUT=$(SI_FIXTURE="$tmp/fx.json" SI_CALLS="$tmp/calls.log" SI_RC=1 SI_PARTIAL=1 \
      PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT "$PARENT" 2>/dev/null); RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ]; then ok; else bad "부분 출력 + 실패 → 무출력·exit 1 — rc=$RC out=[$OUT]"; fi

# 빈 응답(성공했지만 본문 없음)도 조회 실패와 같이 fail-closed.
run '' 0
if [ "$RC" = 1 ] && [ -z "$OUT" ]; then ok; else bad "빈 응답 → 무출력·exit 1 — rc=$RC out=[$OUT]"; fi

# JSON 이 아닌 응답(프록시 HTML 등)도 fail-closed — 빈 값이 정상값으로 채택되면 안 된다.
run 'not json at all' 0
if [ "$RC" = 1 ] && [ -z "$OUT" ]; then ok; else bad "비-JSON 응답 → 무출력·exit 1 — rc=$RC out=[$OUT]"; fi

# 부모 번호가 숫자가 아니면 조회조차 하지 않고 fail-closed (호출자가 부모를 못 구한 경우).
run "$(mkfx 'Epic #4962' 'P1')" 0 'agent/issue-109'
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$CALLS" = 0 ]; then ok; else
  bad "비숫자 부모 → gh 호출 0·무출력·exit 1 — rc=$RC out=[$OUT] calls=$CALLS"
fi

# 인자 부족도 fail-closed.
out=$(PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok; else bad "인자 1개 → 무출력·exit 1 — rc=$rc out=[$out]"; fi
out=$(PATH="$tmp/stub:$PATH" bash "$SUT" 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok; else bad "인자 0개 → 무출력·exit 1 — rc=$rc out=[$out]"; fi

echo '── eval "$(...)" 계약 — 6단계 발행 명령이 쓰는 형태 그대로 ──'

# 출력이 그대로 쉘 변수가 되어야 한다(발행 명령이 `--label "\$priority"` 로 쓴다).
printf '%s' "$(mkfx $'Epic #4968\n본문' 'P1')" > "$tmp/fx.json"
: > "$tmp/calls.log"
evalout=$(SI_FIXTURE="$tmp/fx.json" SI_CALLS="$tmp/calls.log" SI_RC=0 PATH="$tmp/stub:$PATH" \
  bash -c 'eval "$(bash "$0" ggqgga/BodaT 4979)"; printf "%s|%s\n" "$epic" "$priority"' "$SUT" 2>/dev/null)
if [ "$evalout" = "4968|P1" ]; then ok; else bad "eval 계약 — out=[$evalout] want=[4968|P1]"; fi

# epic=- 도 eval 에서 깨지지 않아야 한다(`-` 는 리다이렉션·옵션으로 오해되기 쉽다).
printf '%s' "$(mkfx $'## 배경' '')" > "$tmp/fx.json"
: > "$tmp/calls.log"
evalout=$(SI_FIXTURE="$tmp/fx.json" SI_CALLS="$tmp/calls.log" SI_RC=0 PATH="$tmp/stub:$PATH" \
  bash -c 'eval "$(bash "$0" ggqgga/BodaT 4979)"; printf "%s|%s\n" "$epic" "$priority"' "$SUT" 2>/dev/null)
if [ "$evalout" = "-|P1" ]; then ok; else bad "eval 계약(epic=-) — out=[$evalout] want=[-|P1]"; fi

echo "── 읽기 전용 — 부모를 편집하지 않는다 ──────────────────────────────"
# 스텁은 `issue view --json body,labels` 외의 호출을 exit 3 으로 거부한다. 위 전 케이스가
# 그 스텁으로 통과했다는 것 자체가 편집 호출(`issue edit` 등)이 없었다는 증거지만,
# 소스에도 쓰기 동사가 없는지 한 번 더 문다(되돌리지 마라 2번).
if grep -nE 'issue (edit|create|close|comment)|--add-label|--remove-label' "$SUT" >/dev/null; then
  bad "헬퍼 소스에 쓰기 동사가 있다 — spinoff-inherit.sh 는 읽기 전용이다"
else
  ok
fi

echo
echo "spinoff-inherit.test.sh: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
