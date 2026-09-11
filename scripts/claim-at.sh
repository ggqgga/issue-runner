#!/usr/bin/env bash
# claim-at.sh <repo> <issue>
#
# **현재 회차의 시작 증거** 조회 한 자리 (#206). `agent:claimed` 가 *지금 붙어 있는지* 와
# *마지막으로 붙은 시각* 을 stdout 한 줄로 낸다.
#
#   <ISO8601>   지금 붙어 있음 — 그 라벨이 **마지막으로 부착된** 시각   exit 0
#   none        붙어 있지 않음(뗐거나 부착 이력 없음)                   exit 0
#   (무출력)    조회 실패                                               exit 2
#
# ── 왜 "존재" 가 아니라 "부착 시각" 인가 ─────────────────────────────────────
# `agent:claimed` 의 **존재**만으로는 아무것도 못 가른다(#196 3항, 실측): `reconcile.sh` 는
# 열린 PR 이 있는 이슈에서 그 라벨을 떼지 않으므로 진짜 좌초한 PR 도 라벨을 달고 있다.
# 가르는 것은 **언제 붙었나**다 — 반송 직후 디스패처가 붙인 claim 은 몇 분 전이고, 좌초한
# 회차의 claim 은 몇 시간 전이다.
#
# 이 신호가 필요한 이유(#206 attempt 2 codex BLOCKER): 커밋 신선도·CI 큐 티켓은 워커가
# **이미 뭔가 남긴 뒤에만** 존재하는 증거라, 반송 직후 교체 워커가 디스패치됐지만 **첫 푸시
# 전**인 창을 덮지 못한다. 그 창에서 `finish-classify.sh` 가 보는 값은 전부 이전 attempt 의
# 것(옛 판정 시각·옛 head 시각)이고 `STALE_FINISH_MIN` 을 넘겨 `stale_reverify` 가 나면
# `closeout-redispatch` 가 **지금 일하고 있는 워커의 `agent:claimed` 를 떼어낸다.**
#
# ── 부착 여부는 타임라인 한 번으로 판정한다 ───────────────────────────────────
# 라벨 목록을 따로 묻지 않는다. 그 라벨의 `labeled`/`unlabeled` 이벤트 중 **마지막**이
# `labeled` 면 지금 붙어 있는 것이다. 선후는 `created_at` 정렬이 아니라 **배열의 마지막
# 매칭 인덱스**로 잰다(`bounce-state.sh` 와 같은 규율 — #212·#221).
#
# 조회 실패(exit 2)를 `none` 과 섞지 않는 이유는 `progress-evidence.sh` 머리 주석과 같다:
# 조회 실패로 살아있는 워커를 죽이는 것은 되돌릴 수 없다(PR#139 — 빈 결과와 실패를 구분하라).
#
# 테스트/재현용 env 오버라이드 (없으면 gh 실조회):
#   CA_TIMELINE_FILE  타임라인 이벤트 배열 JSON 이 담긴 파일 경로(대용량 안전 경로)
#   CA_TIMELINE_JSON  같은 배열 JSON — 파일 경로보다 뒤
#                     (읽기 실패는 실조회로 **새지 않고** 조회 실패 exit 2 다)
# macOS bash 3.2 대상.
set -uo pipefail

repo=${1:?repo}
issue=${2:?issue}

# 필터는 **한 곳에만** 둔다 — 실조회와 픽스처 두 경로가 같은 문자열을 쓴다(PR#191 교훈).
CLAIM_FILTER='[ .[] | select((.event? == "labeled" or .event? == "unlabeled")
  and (.label?.name? == "agent:claimed")) ]
  | last
  | if . == null then "none" else ((.event // "") + " " + (.created_at // "")) end'

raw=""
if [ -n "${CA_TIMELINE_FILE:-}" ]; then
  raw=$(cat "$CA_TIMELINE_FILE" 2>/dev/null) || exit 2
elif [ -n "${CA_TIMELINE_JSON:-}" ]; then
  raw="$CA_TIMELINE_JSON"
else
  # `--paginate` 필수 — 반송을 여러 번 도는 이슈는 타임라인 이벤트가 100건을 쉽게 넘고,
  # 그때 첫 페이지만 보면 **최신 claim 부착이 안 보여** 살아있는 워커가 `none` 으로 읽힌다
  # (코멘트 100건 상한과 같은 함정 — #171·#173).
  raw=$(gh api "repos/$repo/issues/$issue/timeline" --paginate 2>/dev/null) || exit 2
fi
[ -n "$raw" ] || exit 2

out=$(printf '%s' "$raw" | jq -r "$CLAIM_FILTER" 2>/dev/null) || exit 2
[ -n "$out" ] || exit 2

case "$out" in
  none)          printf 'none\n' ;;
  "unlabeled "*) printf 'none\n' ;;   # 마지막 이벤트가 해제 = 지금은 안 붙어 있다
  "labeled "*)
    ts="${out#labeled }"
    # 이벤트는 있는데 시각이 비었다 = 응답 계약 위반. "부착 안 됨" 으로 읽을 수 없다.
    [ -n "$ts" ] || exit 2
    printf '%s\n' "$ts" ;;
  *) exit 2 ;;
esac
exit 0
