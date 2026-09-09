#!/usr/bin/env bash
# loop-status.sh 픽스처 테스트 (#144) — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# 가드하는 것:
#   ① 버킷 7개가 정확히 나뉜다 — 한 이슈는 한 버킷, 우선순위(배포대기 > 사람대기 > 사다리).
#   ② 실패·파생의 `--since` 창 필터 — 창 밖 1건씩은 빠진다.
#   ③ warn 5종 검출(미러 불일치는 양방향 — 이슈에만 단계 / PR 에만 단계)과,
#      깨끗한 픽스처면 `warn 0`.
#   ④ 레포 짧은 이름 — issue-runner → runner 특례.
#   ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1.
#   ⑥ `--json` 의 모든 항목·warn 에 `repo_short`.
#   ⑦ `.loop/repos` 의 `#` 주석·빈 줄 무시 + 형식 아닌 줄은 stderr 로 알린다.
#   ⑧ 조용한 실패 6종(보조 리뷰) — 깨진 JSON 집계 실패 · compare 실패 degrade ·
#      목록 상한 warn · 제목 폴백의 사다리 게이트 · `--since 0h` · repos 파일 부재 메시지.
#
# 기대 줄은 **손으로 적는다** — SUT 의 jq 를 베껴 기대값을 만들면 공허하게 통과한다
# (transition.test.sh 의 관행).
# 스텁은 픽스처 파일을 돌려주며, 예기치 않은 호출 형태는 조용한 빈 JSON 대신 exit 1 로
# 드러낸다(빠뜨린 호출이 버킷을 0으로 만드는 걸 막는다).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/loop-status.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fx"

pass=0
fail=0
check() {
  if [ "$2" = "ok" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; fi
}
ck() { check "$1" "$([ "$2" = "$3" ] && echo ok || echo no)"; }
# has_line <이름> <파일> <정확히 일치할 줄>
has_line() {
  if grep -qxF -- "$3" "$2"; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; echo "      기대: [$3]"; fi
}
has_sub() {
  if grep -qF -- "$3" "$2"; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; echo "      기대(부분): [$3]"; fi
}
no_sub() {
  if grep -qF -- "$3" "$2"; then fail=$((fail + 1)); echo "  ✗ $1"; echo "      나오면 안 됨: [$3]"
  else pass=$((pass + 1)); fi
}

# ── gh PATH 스텁 ───────────────────────────────────────────────────────────
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
slug() { printf '%s' "$1" | tr '/' '_'; }

repo=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then repo="$a"; fi
  prev="$a"
done

if [ "${1:-}" = "api" ]; then
  path="${2:-}"
  repo=$(printf '%s' "$path" | sed -n 's|^repos/\([^/]*/[^/]*\)/.*|\1|p')
  f="$STUB_DIR/$(slug "$repo")"
  if [ -f "$f.fail" ]; then echo "gh: connection refused" >&2; exit 1; fi
  case "$path" in
    */branches/release)
      if [ ! -f "$f.release" ]; then echo "gh: Branch not found (HTTP 404)" >&2; exit 1; fi
      echo '{"name":"release"}'; exit 0 ;;
    */compare/*)
      if [ ! -f "$f.ahead" ]; then echo "gh: compare 실패" >&2; exit 1; fi
      cat "$f.ahead"; exit 0 ;;
  esac
  echo "gh stub: 미지원 api 경로: $path" >&2; exit 1
fi

if [ "${1:-} ${2:-}" = "repo view" ]; then
  repo="${3:-}"
  f="$STUB_DIR/$(slug "$repo")"
  if [ -f "$f.fail" ]; then echo "gh: connection refused" >&2; exit 1; fi
  echo main; exit 0
fi

f="$STUB_DIR/$(slug "$repo")"
if [ -f "$f.fail" ]; then echo "gh: connection refused" >&2; exit 1; fi

case "${1:-} ${2:-}" in
  "issue list") cat "$f.issues.json"; exit 0 ;;
  "pr list")
    case "$args" in
      *"--state closed"*) cat "$f.pr_closed.json"; exit 0 ;;
      *"--state open"*)   cat "$f.pr_open.json"; exit 0 ;;
    esac
    echo "gh stub: pr list 의 --state 를 못 읽음: $args" >&2; exit 1 ;;
esac
echo "gh stub: 예기치 않은 호출: $args" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

# ── 시각 — 창(24h) 안/밖 ───────────────────────────────────────────────────
tsm() {  # tsm <분 전> → RFC3339 UTC
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
NOW=$(tsm 60)     # 창 안
OLD=$(tsm 4320)   # 3일 전 — 창 밖

# ── 픽스처: ggqgga/BodaT (bodat) — 버킷 7종 + warn 5종(미러는 양방향 2건) + 창 밖 대조군 ─
sed "s/@NOW@/$NOW/g; s/@OLD@/$OLD/g" > "$tmp/fx/ggqgga_BodaT.issues.json" <<'FX'
[
 {"number":4832,"title":"파생건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"spinoff"}]},
 {"number":4831,"title":"보통건","createdAt":"@NOW@","labels":[{"name":"agent-ready"}]},
 {"number":4600,"title":"이슈만 단계 없는 건","createdAt":"@NOW@","labels":[{"name":"agent-ready"}]},
 {"number":4901,"title":"옛 파생건","createdAt":"@OLD@","labels":[{"name":"agent-ready"},{"name":"spinoff"}]},
 {"number":4803,"title":"구현중건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":4701,"title":"좌초건","createdAt":"@NOW@","labels":[{"name":"agent:claimed"}]},
 {"number":4810,"title":"검증중건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":4500,"title":"배포 대기 (승격만) — 사다리가 이긴다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":4811,"title":"마감대기건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:ready"}]},
 {"number":4818,"title":"마감중건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"harvesting"}]},
 {"number":4700,"title":"중복단계건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"harvesting"}]},
 {"number":4825,"title":"사람대기 대기자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"}]},
 {"number":4770,"title":"사람대기 구현중자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"agent:claimed"}]},
 {"number":4838,"title":"라벨로 배포대기","createdAt":"@NOW@","labels":[{"name":"deploy-wait"}]},
 {"number":4796,"title":"배포 대기: PR #4700 — 제목 폴백","createdAt":"@NOW@","labels":[]},
 {"number":4848,"title":"배포 검증: 화력 작전 — 제목 폴백 2형식","createdAt":"@NOW@","labels":[{"name":"needs-human"}]},
 {"number":4900,"title":"루프 밖 이슈","createdAt":"@NOW@","labels":[{"name":"enhancement"}]}
]
FX

sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_BodaT.pr_open.json" <<'FX'
[
 {"number":4837,"headRefName":"agent/issue-4818","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4818}],"labels":[{"name":"harvesting"}]},
 {"number":4840,"headRefName":"agent/issue-4810","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4810}],"labels":[{"name":"flow:verify"}]},
 {"number":4841,"headRefName":"agent/issue-4811","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4811}],"labels":[{"name":"flow:ci"}]},
 {"number":4835,"headRefName":"agent/issue-4825","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4825}],"labels":[]},
 {"number":4850,"headRefName":"agent/issue-4832","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4832}],"labels":[]},
 {"number":4852,"headRefName":"agent/issue-4832","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4832}],"labels":[{"name":"needs-human"}]},
 {"number":4851,"headRefName":"agent/issue-4899","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4899}],"labels":[{"name":"flow:verify"}]},
 {"number":4860,"headRefName":"agent/issue-4600","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4600}],"labels":[{"name":"flow:ready"}]}
]
FX

sed "s/@NOW@/$NOW/g; s/@OLD@/$OLD/g" > "$tmp/fx/ggqgga_BodaT.pr_closed.json" <<'FX'
[
 {"number":4792,"headRefName":"agent/issue-4753","state":"CLOSED","mergedAt":null,"closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4753}],"labels":[]},
 {"number":4793,"headRefName":"agent/issue-4754","state":"MERGED","mergedAt":"@NOW@","closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4754}],"labels":[]},
 {"number":4794,"headRefName":"agent/issue-4755","state":"CLOSED","mergedAt":null,"closedAt":"@OLD@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4755}],"labels":[]},
 {"number":4795,"headRefName":"fix/사람이-연-브랜치","state":"CLOSED","mergedAt":null,"closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[],"labels":[]}
]
FX

# ── 픽스처: ggqgga/issue-runner (runner) — 깨끗함 + release 있음 ─────────────
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_issue-runner.issues.json" <<'FX'
[
 {"number":140,"title":"깨끗한 대기건","createdAt":"@NOW@","labels":[{"name":"agent-ready"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_issue-runner.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_issue-runner.pr_closed.json"
: > "$tmp/fx/ggqgga_issue-runner.release"
echo '7' > "$tmp/fx/ggqgga_issue-runner.ahead"

# ── 픽스처: ggqgga/BoDAC (bodac) — 조회 실패 ───────────────────────────────
: > "$tmp/fx/ggqgga_BoDAC.fail"

# ── 픽스처: ggqgga/Broken (broken) — gh 는 exit 0 인데 JSON 이 깨졌다 ────────
# gh 가 성공했다고 조용히 빈 스냅샷을 찍으면 "그 레포엔 아무것도 없다" 로 읽힌다.
printf '%s' '{이건 JSON 이 아니다' > "$tmp/fx/ggqgga_Broken.issues.json"
echo '[]' > "$tmp/fx/ggqgga_Broken.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_Broken.pr_closed.json"

# ── 픽스처: ggqgga/NoCompare (nocompare) — release 는 있는데 compare 가 실패 ──
echo '[]' > "$tmp/fx/ggqgga_NoCompare.issues.json"
echo '[]' > "$tmp/fx/ggqgga_NoCompare.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_NoCompare.pr_closed.json"
: > "$tmp/fx/ggqgga_NoCompare.release"   # .ahead 없음 → 스텁의 compare 가 실패

# ── 픽스처: ggqgga/Big (big) — 목록이 --limit 200 상한에 닿았다 ─────────────
jq -n --arg t "$NOW" '[range(1;201) | {number: ., title:"채움", createdAt:$t, labels:[]}]' \
  > "$tmp/fx/ggqgga_Big.issues.json"
echo '[]' > "$tmp/fx/ggqgga_Big.pr_open.json"
jq -n --arg t "$NOW" \
  '[range(1;201) | {number: ., headRefName:"fix/채움", state:"CLOSED", mergedAt:$t,
                    closedAt:$t, createdAt:$t, closingIssuesReferences:[], labels:[]}]' \
  > "$tmp/fx/ggqgga_Big.pr_closed.json"

run() {  # run <인자...> — 출력은 $tmp/out, exit 는 RC
  STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" "$SUT" "$@" >"$tmp/out" 2>"$tmp/err"
  RC=$?
}

# ── ①②③④ 두 레포 정상 스코프 ─────────────────────────────────────────────
run --repo ggqgga/BodaT --repo ggqgga/issue-runner --since 24h
ck "정상 스코프: exit 0" "$RC" 0

has_line "헤더: 열림=버킷합(13) · 스코프 · 창" "$tmp/out" \
  "파이프라인 bodat — 열림 16 · 스코프 bodat·runner · 창 24h"
has_line "대기 3(창 밖 파생건도 대기에는 남는다)" "$tmp/out" \
  "  대기      4  #4901 #4832 #4831 #4600"
has_line "구현중 2(좌초건 포함)" "$tmp/out" \
  "  구현중    2  #4803 #4701"
has_line "검증대기 2 — 제목이 배포 대기… 여도 사다리 라벨이 이긴다" "$tmp/out" \
  "  검증대기  2  #4810 ← PR #4840 #4500"
has_line "마감대기 1 + 연결 PR" "$tmp/out" \
  "  마감대기  1  #4811 ← PR #4841"
has_line "마감중 2(중복단계건은 가장 뒤 단계로)" "$tmp/out" \
  "  마감중    2  #4818 ← PR #4837 #4700"
has_line "사람대기 2 — 사다리 위치 + 열린 연결 PR" "$tmp/out" \
  "  사람대기  2  #4825(대기, PR #4835) #4770(구현중)"
has_line "배포대기 3 — 라벨 + 제목 폴백 2형식(배포 대기 / 배포 검증)" "$tmp/out" \
  "  배포대기  3  #4848 #4838 #4796"
# 배포대기가 사람대기보다 앞선다 — needs-human 을 단 `배포 검증:` 이슈가 사람대기로 새면 안 된다
no_sub "제목 폴백건은 사람대기에 안 샌다" "$tmp/out" "#4848("
# ② 창 필터: 머지된 PR·창 밖 PR·사람 브랜치는 실패 아님
has_line "실패 1 — 창 안 미머지 agent PR 만" "$tmp/out" \
  "  실패      1  PR #4792(#4753, 머지 없이 닫힘)"
no_sub "실패: 창 밖 PR #4794 제외" "$tmp/out" "#4794"
no_sub "실패: 머지된 PR #4793 제외" "$tmp/out" "#4793"
no_sub "실패: 사람 브랜치 PR #4795 제외" "$tmp/out" "#4795"
has_line "파생 1 — 창 안 spinoff 만(#4901 은 창 밖)" "$tmp/out" \
  "  파생      1  #4832"
has_line "승격 대기 — release 없는 레포" "$tmp/out" \
  "  승격 대기 —"
# 루프 밖 이슈는 어디에도 안 센다
no_sub "루프 밖 이슈 #4900 미집계" "$tmp/out" "#4900"

# ③ warn 5종
has_line "warn 6건" "$tmp/out" "  warn      6"
has_sub "warn 무소속 PR" "$tmp/out" \
  "    - 무소속 PR #4850(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4832 는 needs-human 아님"
has_sub "warn 단계 라벨 중복" "$tmp/out" \
  "    - 단계 라벨 중복 #4700(bodat) — flow:verify + harvesting"
has_sub "warn 미러 불일치(이슈에만 단계)" "$tmp/out" \
  "    - 미러 불일치 #4811(bodat) ↔ PR #4841(bodat) — 이슈 flow:ready · PR 단계 없음"
has_sub "warn 미러 불일치(PR 에만 단계 — 반대 방향)" "$tmp/out" \
  "    - 미러 불일치 #4600(bodat) ↔ PR #4860(bodat) — 이슈 단계 없음 · PR flow:ready"
has_sub "warn 좌초형" "$tmp/out" \
  "    - 좌초형 #4701(bodat) — 사다리 라벨(agent:claimed) 인데 agent-ready 없음"
has_sub "warn 연결 이슈 종료" "$tmp/out" \
  "    - 연결 이슈 종료 PR #4851(bodat) — 연결 이슈 #4899 가 CLOSED"
# needs-human 이슈에 걸린 라벨 없는 PR(#4835)은 무소속이 아니다
no_sub "무소속: needs-human 연결 PR #4835 은 warn 아님" "$tmp/out" "무소속 PR #4835"
# PR 자체에 needs-human 이 붙은 held PR(#4852 — verify-held/closeout-blocked 가 issue=- 로 남긴 형태)도 무소속이 아니다
no_sub "무소속: PR 자체 needs-human(#4852) 은 warn 아님" "$tmp/out" "무소속 PR #4852"

# ③ 깨끗한 픽스처 + ④ 짧은 이름 특례
has_line "runner 블록 헤더(issue-runner → runner)" "$tmp/out" \
  "파이프라인 runner — 열림 1 · 스코프 bodat·runner · 창 24h"
has_line "runner 승격 대기 7커밋" "$tmp/out" "  승격 대기 7커밋"
has_line "깨끗한 레포는 warn 0" "$tmp/out" "  warn      0"

# ── ② 창을 넓히면 창 밖이던 것이 들어온다(창 필터가 실제로 동작한다는 대조군) ──
run --repo ggqgga/BodaT --since 7d
has_line "창 7d: 파생 2(옛 spinoff 포함)" "$tmp/out" "  파생      2  #4901 #4832"
has_line "창 7d: 실패 2(창 밖이던 #4794 포함)" "$tmp/out" \
  "  실패      2  PR #4794(#4755, 머지 없이 닫힘) PR #4792(#4753, 머지 없이 닫힘)"

# ── ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1 ──────────
run --repo ggqgga/BodaT --repo ggqgga/BoDAC --repo ggqgga/issue-runner --since 24h
ck "부분 실패: exit 1" "$RC" 1
has_sub "부분 실패: bodac 만 실패 줄" "$tmp/out" "파이프라인 bodac — 조회 실패: 이슈 목록 — "
has_sub "부분 실패: bodat 블록은 정상" "$tmp/out" "파이프라인 bodat — 열림 16"
has_sub "부분 실패: runner 블록은 정상" "$tmp/out" "파이프라인 runner — 열림 1"

# ── ⑥ --json: 모든 항목·warn 에 repo_short ──────────────────────────────────
run --repo ggqgga/BodaT --repo ggqgga/issue-runner --since 24h --json
ck "--json: exit 0" "$RC" 0
ck "--json: 유효 JSON" "$(jq -e 'type' < "$tmp/out" 2>/dev/null)" '"object"'
ck "--json: 항목 수 > 0" \
  "$(jq '[.repos[] | select(.ok) | .buckets[][]] | length > 0' < "$tmp/out")" true
ck "--json: repo_short 없는 항목 0" \
  "$(jq '[.repos[] | select(.ok) | .buckets[][] | select(has("repo_short") | not)] | length' < "$tmp/out")" 0
ck "--json: repo_short 없는 warn 0" \
  "$(jq '[.repos[] | select(.ok) | .warns[] | select(has("repo_short") | not)] | length' < "$tmp/out")" 0
ck "--json: 여러 레포의 repo_short 가 섞여 구분된다" \
  "$(jq -c '[.repos[].repo_short] | sort' < "$tmp/out")" '["bodat","runner"]'
ck "--json: bodat 열림 16" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .open_total' < "$tmp/out")" 16
ck "--json: runner 승격 대기 7" \
  "$(jq '.repos[] | select(.repo_short=="runner") | .promotion_ahead' < "$tmp/out")" 7
ck "--json: bodat 승격 대기 null(release 없음)" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .promotion_ahead' < "$tmp/out")" null

# ── ⑦ .loop/repos — 주석·빈 줄 무시 ────────────────────────────────────────
cat > "$tmp/repos" <<'FX'
# 이 줄은 주석
ggqgga/BodaT

  ggqgga/issue-runner
# ggqgga/BoDAC  ← 주석 처리라 스코프 밖
FX
run --repos-file "$tmp/repos" --since 24h
ck "repos-file: exit 0(주석의 실패 레포는 안 읽힘)" "$RC" 0
has_sub "repos-file: 스코프에 두 레포만" "$tmp/out" "· 스코프 bodat·runner ·"
no_sub "repos-file: 주석 레포 미포함" "$tmp/out" "bodac"

# ── ⑧-a gh 가 exit 0 인데 JSON 이 깨졌다 → 집계 실패 + exit 1 ──────────────
run --repo ggqgga/Broken --repo ggqgga/issue-runner --since 24h
ck "깨진 JSON: exit 1" "$RC" 1
has_line "깨진 JSON: 조용한 빈 스냅샷이 아니라 실패 줄" "$tmp/out" \
  "파이프라인 broken — 조회 실패: 집계 실패(jq)"
has_sub "깨진 JSON: 나머지 레포는 정상" "$tmp/out" "파이프라인 runner — 열림 1"

# ── ⑧-b release 는 있는데 compare 실패 → 승격 대기 — 로 degrade, exit 0 ────
run --repo ggqgga/NoCompare --since 24h
ck "compare 실패: 레포를 실패시키지 않는다(exit 0)" "$RC" 0
has_sub "compare 실패: 블록은 정상 렌더" "$tmp/out" "파이프라인 nocompare — 열림 0"
has_line "compare 실패: 승격 대기 —" "$tmp/out" "  승격 대기 —"

# ── ⑧-c 목록 상한 200 도달 → 절단 warn ────────────────────────────────────
run --repo ggqgga/Big --since 24h
ck "목록 절단: exit 0" "$RC" 0
has_line "목록 절단: warn 2건" "$tmp/out" "  warn      2"
has_sub "목록 절단: 이슈 목록" "$tmp/out" "    - 목록 상한 200 도달 — 창 절단 가능(이슈)"
has_sub "목록 절단: 닫힌 PR 목록" "$tmp/out" "    - 목록 상한 200 도달 — 창 절단 가능(닫힌 PR)"
no_sub "목록 절단: 상한 안 닿은 열린 PR 은 조용하다" "$tmp/out" "창 절단 가능(열린 PR)"

# ── ⑦ repos 파일 — 형식 아닌 줄은 stderr 로 알린다(조용히 버리지 않는다) ────
cat > "$tmp/repos-bad" <<'FX'
ggqgga/BodaT
오타로슬래시가없는줄
FX
run --repos-file "$tmp/repos-bad" --since 24h
ck "무시된 줄: exit 0" "$RC" 0
has_sub "무시된 줄: stderr 로 알린다" "$tmp/err" "무시된 줄: 오타로슬래시가없는줄"
has_sub "무시된 줄: 나머지 레포는 정상" "$tmp/out" "파이프라인 bodat — 열림 16"

# ── usage — 스코프 없음 / --since 형식 오류 ────────────────────────────────
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" \
  "$SUT" --repos-file "$tmp/없는파일" >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "repos 파일 부재: exit 64" "$RC" 64
has_sub "repos 파일 부재: usage 로 뭉개지 말고 그 사실을 말한다" "$tmp/err" \
  "repos 파일 없음: $tmp/없는파일"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" \
  "$SUT" --repo ggqgga/BodaT --since 24 >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "--since 형식 오류: exit 64(조용한 창 0 금지)" "$RC" 64
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" \
  "$SUT" --repo ggqgga/BodaT --since xh >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "--since 숫자 아님: exit 64" "$RC" 64
# ⑧-e 창 0 은 실패·파생을 늘 0 으로 만드는 거짓 "깨끗함" — 형식 오류로 막는다
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" \
  "$SUT" --repo ggqgga/BodaT --since 0h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "--since 0h: exit 64" "$RC" 64
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" \
  "$SUT" --repo ggqgga/BodaT --since 0d >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "--since 0d: exit 64" "$RC" 64

echo "loop-status: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
