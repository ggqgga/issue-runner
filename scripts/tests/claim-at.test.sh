#!/usr/bin/env bash
# claim-at.sh 격자 테스트 (#428) — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# 무는 계약: `agent:claimed` 가 **지금 붙어 있는지**와 **마지막 부착 시각**을 한 줄로 내되
#   <ISO8601>=부착 중(exit 0) · none=안 붙음(exit 0) · 무출력=조회 실패(exit 2)
# 로 **부재와 실패를 가른다**. 선후는 created_at 정렬이 아니라 배열의 **마지막 매칭 인덱스**,
# 실조회는 `--paginate`(타임라인 100건 상한 함정), 픽스처 읽기 실패는 실조회로 새지 않는다.
# 이 헬퍼를 직접 exec 하는 소비자: scripts/finish-classify.sh · scripts/spinoff-inherit.sh.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/claim-at.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

REPO=fixture-owner/fixture-428
ISSUE=1

# gh 스텁 — 호출 인자를 기록하고 GH_MODE 로 응답을 고른다.
# `ok` 는 실 gh 처럼 **페이지네이션 유무로 다르게** 응답한다: `--paginate` 가 없으면 첫
# 100건만 준다(GitHub 타임라인 상한 재현). 그래야 100건 초과 픽스처가 실제로 무언가를 잰다.
# 그 밖의 호출은 exit 1 — 의도치 않은 네트워크 경로가 조용히 통과하지 않게.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGS:-/dev/null}"
case "$*" in
  *"/timeline"*) ;;
  *) echo "예상 못한 gh 호출: $*" >&2; exit 1 ;;
esac
case "${GH_MODE:-ok}" in
  fail)  echo "gh: could not connect" >&2; exit 1 ;;
  empty) exit 0 ;;
  *)
    case "$*" in
      *--paginate*) cat "$STUB_TIMELINE_FILE" ;;
      *) jq -c '.[0:100]' "$STUB_TIMELINE_FILE" ;;
    esac ;;
esac
STUB
chmod +x "$TMP/bin/gh"

pass=0
fail=0
OUT=""
RC=0

check() {  # check <이름> <기대 stdout> <기대 exit>
  if [ "$OUT" = "$2" ] && [ "$RC" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $1 — 기대=[$2](exit $3) 실제=[$OUT](exit $RC)"
  fi
}

case_json() {  # case_json <이름> <기대> <기대exit> <타임라인 JSON>
  OUT=$(CA_TIMELINE_JSON="$4" PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" \
    bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
  check "$1" "$2" "$3"
}

# ── 정상 판정 ───────────────────────────────────────────────────────────
case_json "마지막 매칭이 labeled → 부착 시각" "2026-09-13T11:40:00Z" 0 '[
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T09:00:00Z"},
  {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T11:00:00Z"},
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T11:40:00Z"}
]'

case_json "마지막 매칭이 unlabeled → 안 붙어 있음" none 0 '[
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T09:00:00Z"},
  {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T11:00:00Z"}
]'

# 다른 라벨·다른 이벤트는 필터에 안 걸린다 — 배열 마지막이 남의 unlabeled 여도 우리 부착이 산다.
case_json "다른 라벨의 해제는 판정에 안 섞인다" "2026-09-13T09:00:00Z" 0 '[
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T09:00:00Z"},
  {"event":"commented","created_at":"2026-09-13T10:00:00Z"},
  {"event":"unlabeled","label":{"name":"needs-human"},"created_at":"2026-09-13T11:00:00Z"}
]'

case_json "부착 이력 자체가 없음 → none" none 0 '[
  {"event":"labeled","label":{"name":"P1"},"created_at":"2026-09-13T09:00:00Z"}
]'

case_json "빈 타임라인 → none" none 0 '[]'

# **선후는 created_at 이 아니라 배열의 마지막 매칭 인덱스**로 잰다 — 아래 픽스처는 시각으로
# 정렬하면 09:00(labeled)이 이기지만, 배열 끝이 11:00 의 labeled 라 그 시각이 답이다.
# (같은 초에 붙었다 떼였다 하는 형상을 시각으로는 못 가린다 — bounce-state.sh 와 같은 규율.)
case_json "선후는 created_at 정렬이 아니라 배열 순서" "2026-09-13T11:00:00Z" 0 '[
  {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T23:00:00Z"},
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T11:00:00Z"}
]'

# ── 응답 계약 위반·조회 실패는 none 이 아니라 exit 2 ────────────────────
case_json "labeled 인데 시각이 빔 → 계약 위반(부착 안 됨이 아니다)" "" 2 '[
  {"event":"labeled","label":{"name":"agent:claimed"},"created_at":""}
]'
case_json "JSON 이 아님 → 조회 실패" "" 2 'not-json{'

# ── 픽스처 입력 경로 — 읽기 실패는 실조회로 **새지 않는다** ──────────────
: > "$TMP/gh.args"
OUT=$(CA_TIMELINE_FILE="$TMP/nonexistent.json" PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" \
  bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "타임라인 파일 부재 → 조회 실패" "" 2
if [ -s "$TMP/gh.args" ]; then
  fail=$((fail + 1)); echo "  ✗ 파일 부재인데 gh 실조회로 샜다: [$(cat "$TMP/gh.args")]"
else
  pass=$((pass + 1))
fi

printf '' > "$TMP/empty.json"
OUT=$(CA_TIMELINE_FILE="$TMP/empty.json" PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" \
  bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "타임라인 파일이 비어 있음 → 조회 실패" "" 2

# 파일 경로가 JSON 문자열보다 **앞선다**.
printf '%s' '[{"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T08:00:00Z"}]' \
  > "$TMP/file.json"
OUT=$(CA_TIMELINE_FILE="$TMP/file.json" \
  CA_TIMELINE_JSON='[{"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"2026-09-13T09:00:00Z"}]' \
  PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "파일 주입이 JSON 주입을 이긴다" "2026-09-13T08:00:00Z" 0

# ── 실조회 경로 — 100건 상한(--paginate) · 실패 · 빈 응답 ────────────────
# 첫 100건에는 agent:claimed 가 없고 101번째에 있다: `--paginate` 없이 첫 페이지만 보면
# **최신 부착이 안 보여** 살아있는 워커가 none 으로 읽힌다(#171·#173 과 같은 상한 함정).
jq -n '[range(0;100) | {event:"labeled", label:{name:"P1"}, created_at:"2026-09-13T10:00:00Z"}]
  + [{event:"labeled", label:{name:"agent:claimed"}, created_at:"2026-09-13T11:55:00Z"}]' \
  > "$TMP/timeline.json"
: > "$TMP/gh.args"
OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" GH_MODE=ok \
  STUB_TIMELINE_FILE="$TMP/timeline.json" bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "실조회 — 100건 너머의 부착도 본다" "2026-09-13T11:55:00Z" 0
if grep -qF -- "repos/$REPO/issues/$ISSUE/timeline --paginate" "$TMP/gh.args"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  ✗ 실조회 인자 — 기대=[…/timeline --paginate] 실제=[$(cat "$TMP/gh.args")]"
fi

OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" GH_MODE=fail \
  STUB_TIMELINE_FILE="$TMP/timeline.json" bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "gh 비0 → 조회 실패(none 아님)" "" 2

OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" GH_MODE=empty \
  STUB_TIMELINE_FILE="$TMP/timeline.json" bash "$SUT" "$REPO" "$ISSUE" 2>/dev/null); RC=$?
check "gh 가 빈 응답 → 조회 실패" "" 2

# ── 인자 누락 — 머리 주석엔 없는 갈래다(현재 동작을 못 박는다) ──────────
OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" bash "$SUT" 2>/dev/null); RC=$?
check "인자 누락 → 비0 종료(무출력)" "" 1

echo "claim-at.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
