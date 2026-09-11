#!/usr/bin/env bash
# loop-status.sh 픽스처 테스트 (#144) — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# 가드하는 것:
#   ① 버킷 7개가 정확히 나뉜다 — 한 이슈는 한 버킷, 우선순위(배포대기 > 사람대기 > 사다리).
#   ② 실패·파생의 `--since` 창 필터 — 창 밖 1건씩은 빠진다.
#   ③ warn 5종 검출(미러 불일치는 양방향 — 이슈에만 단계 / PR 에만 단계)과,
#      깨끗한 픽스처면 `warn 0`.
#   ③-b (#265) **정지** 라벨(needs-human·hold:*) 미러 불일치 — 단계 미러와 **별도 판정**이다
#      (단계 배열에 섞으면 정지 라벨이 단계 일치 판정을 깨뜨린다). 해제 방향만 warn:
#      이슈에 정지 라벨이 0개인데 연결된 **열린** PR 에 남은 칸. 4격자로 오탐 0 을 단언한다.
#   ④ 레포 짧은 이름 — issue-runner → runner 특례.
#   ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1.
#   ⑥ `--json` 의 모든 항목·warn 에 `repo_short`.
#   ⑦ `.loop/repos` 의 `#` 주석·빈 줄 무시 + 형식 아닌 줄은 stderr 로 알린다.
#   ⑧ 조용한 실패 6종(보조 리뷰) — 깨진 JSON 집계 실패 · compare 실패 degrade ·
#      목록 상한 warn · 제목 폴백의 사다리 게이트 · `--since 0h` · repos 파일 부재 메시지.
#   ⑨ (#147 T3) 사람대기 사유 병기 — `hold:*` 3종(ladder·policy·conflict) 표기와,
#      `hold:*` 없는 건의 `사유 없음` + warn. 배포대기가 이긴 needs-human 은 warn 밖.
#   ⑩ (#147 T3) 인계 전 창 — `HANDOFF_GRACE_MIN`(기본 90) 안의 **구현중 버킷** PR 은
#      무소속 warn 대신 구현중 줄에 `← PR #n(인계 전)`, 창 밖이면 warn + 사망 의심.
#      env 로 창을 넓히면 창 밖이던 PR 이 넘어온다(창이 실제로 동작한다는 대조군).
#      판정축이 `agent:claimed` **라벨**이면 라벨을 단 채 배포대기로 간 이슈의 PR 이
#      warn 에서만 빠져 어디에도 안 그려진다 — 그 조합(#4790/PR #4856)이 대조군.
#   ⑪ (#147 T3) 실패 ⊎ 중복종료 — PR 라벨 `dup` 이 둘을 가르고 겹쳐 세지 않는다.
#   ⑫ (#157) 질문 없는 홀드 — `hold:policy|conflict` 인데 `hold-note` 코멘트가 없으면
#      사람대기 줄에 `질문 없음`. 조회는 그 조건의 이슈에만(다른 버킷·`hold:ladder`·
#      사유 없는 건엔 gh 를 안 부른다). **모르는 것은 모른다고 말한다** — 조회 실패·
#      코멘트 100건 상한·`HOLD_NOTE_MAX` 초과는 `질문 없음` 이 아니라 warn `질문 유무
#      미확인` 이고, `--json` 의 `note_missing` 도 `false` 가 아니라 `null` 이다.
#   ⑫-d (#160) 마커 판정은 **지금 붙은 사유**를 가린다 — 홀드가 풀려도 코멘트는 남으므로,
#      `hold:conflict` 인데 마커가 옛 `hold-note: policy` 뿐이면 `질문 없음` 이다(그 반대도).
#      같은 사유의 마커는 종전대로 조용하고, 두 사유가 함께 붙은 홀드는 어느 쪽 마커든 질문이다.
#   ⑬ (#177) 사망 의심 경과시간은 **가장 최근 `agent:claimed` 시각**(이슈 타임라인) 기준.
#      PR `createdAt` 으로 재면 홀드 해제 뒤 재디스패치된 건에서 숫자가 통째로 부풀어
#      (PR 은 4시간 전 · claim 은 5분 전 → 240분) 살아 있는 워커를 사망으로 신고한다.
#      타임라인은 **`--paginate` 로 전량**을 읽고 마지막 것을 취한다 — 반송을 여러 번 돈
#      이슈는 라벨 이벤트만으로도 첫 페이지 밖으로 밀려 최근 claim 을 놓친다.
#      못 얻으면(조회 실패·claim 이벤트 부재) **숫자를 지어내지 않고** `경과 미상 — 확인
#      필요` 로 바꾸되 warn 은 유지한다. 조회는 꼬리표가 붙는 후보에만(틱 비용).
#   ⑭ (#248) 대기/막힘 — `대기` 판정을 통과한 이슈 중 **OPEN 블로커**가 있는 건은 `막힘`
#      으로 간다. 블로커 파싱 규칙은 `eligible-issues.sh` 와 같은 의미라 개별 반례가
#      아니라 **격자**(`ggqgga/Blockers` 픽스처 표)로 양방향을 전수 단언한다 — 근사가
#      '더 많이 잡는' 쪽으로 틀리면(정상 `대기` 가 `막힘` 으로) 원래 버그보다 나쁘다.
#      블로커 상태 판정에 **추가 gh 호출이 0** 이라는 것도 스텁 호출 로그로 못 박는다.
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
# 스텁이 남기는 gh 호출 로그(질문 코멘트 조회의 대상·건수를 실측한다 — #157).
export STUB_CALL_LOG="$tmp/calls.log"
: > "$STUB_CALL_LOG"

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
    */issues/*/comments*)
      if [ "${3:-}" = "-X" ] || [ "${3:-}" = "--method" ]; then :; fi
      printf 'dash-comments-get %s\n' "$repo" >> "$STUB_CALL_LOG"
      if [ -f "$f.dash.comments.json" ]; then cat "$f.dash.comments.json"; else echo '[]'; fi; exit 0 ;;
    */issues/comments/*)
      cid=$(printf '%s' "$path" | sed 's|.*/comments/||'); body=""
      prev=""; for a in "$@"; do case "$prev" in -f) body="${a#body=}";; esac; prev="$a"; done
      printf 'dash-comment-patch %s %s\n' "$repo" "$cid" >> "$STUB_CALL_LOG"
      jq --arg id "$cid" --arg b "$body" 'map(if (.id|tostring)==$id then .body=$b else . end)' "$f.dash.comments.json" > "$f.dc.tmp" && mv "$f.dc.tmp" "$f.dash.comments.json"
      echo '{}'; exit 0 ;;
    */issues/*/timeline*)
      # 사망 의심 경과시간의 출처 (#177). 스텁은 **원본 이벤트 배열**을 들고 SUT 가 넘긴
      # --jq 를 직접 적용한다 — 필터를 스텁이 대신 흉내 내면 SUT 의 필터가 틀려도 통과한다.
      # 페이지는 파일로 나뉘어 있고 **2쪽은 --paginate 가 있을 때만** 준다(실제 gh 와 같다).
      num=$(printf '%s' "$path" | sed -n 's|.*/issues/\([0-9][0-9]*\)/timeline.*|\1|p')
      printf 'timeline %s %s\n' "$repo" "$num" >> "$STUB_CALL_LOG"
      if [ -f "$f.timeline.$num.fail" ]; then echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; fi
      jqf=""; prev=""
      for a in "$@"; do case "$prev" in --jq|-q) jqf="$a";; esac; prev="$a"; done
      if [ -z "$jqf" ]; then echo "gh stub: timeline 은 --jq 로 불러야 한다: $args" >&2; exit 1; fi
      if [ ! -f "$f.timeline.$num.p1.json" ]; then echo "gh stub: timeline 픽스처 없음: $repo #$num" >&2; exit 1; fi
      jq -r "$jqf" "$f.timeline.$num.p1.json" || exit 1
      if [ -f "$f.timeline.$num.p2.json" ]; then
        case "$args" in *--paginate*) jq -r "$jqf" "$f.timeline.$num.p2.json" || exit 1 ;; esac
      fi
      exit 0 ;;
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
  # 사람대기 버킷의 hold:policy|conflict 이슈만 오는 질문(hold-note) 코멘트 조회 (#157).
  # 호출 자체를 로그에 남긴다 — "사람대기 버킷에만 묻는다" 를 실측으로 못 박기 위해서.
  "issue view")
    num="${3:-}"
    case "$args" in *"--json body"*) cat "$f.dash.body"; exit 0 ;; esac
    printf 'comments %s %s\n' "$repo" "$num" >> "$STUB_CALL_LOG"
    if [ -f "$f.comments.$num.fail" ]; then echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; fi
    if [ -f "$f.comments.$num.json" ]; then cat "$f.comments.$num.json"; else echo '{"comments":[]}'; fi
    exit 0 ;;
  "issue list")
    case "$args" in *loop-dashboard*)
      printf 'dash-list %s\n' "$repo" >> "$STUB_CALL_LOG"
      # SUT 는 -q '.[0].number // empty' 로 읽는다 — 스텁은 jq 를 안 거치므로 그 결과를 흉내 낸다
      if [ -f "$f.dash.num" ]; then cat "$f.dash.num"; fi
      exit 0 ;;
    esac
    cat "$f.issues.json"; exit 0 ;;
  "issue create")
    printf 'dash-create %s\n' "$repo" >> "$STUB_CALL_LOG"
    echo 900 > "$f.dash.num"; cp "$STUB_DIR/marker.body" "$f.dash.body" 2>/dev/null || printf '<!-- loop-dashboard -->\n' > "$f.dash.body"
    echo "https://github.com/$repo/issues/900"; exit 0 ;;
  "issue pin") printf 'dash-pin %s %s\n' "$repo" "${3:-}" >> "$STUB_CALL_LOG"; exit 0 ;;
  "issue comment")
    body=""; prev=""; for a in "$@"; do case "$prev" in --body) body="$a";; esac; prev="$a"; done
    printf 'dash-comment-create %s\n' "$repo" >> "$STUB_CALL_LOG"
    [ -f "$f.dash.comments.json" ] || echo '[]' > "$f.dash.comments.json"
    n=$(jq 'length' "$f.dash.comments.json"); jq --argjson id "$((1000+n))" --arg b "$body" '. + [{id:$id, body:$b}]' "$f.dash.comments.json" > "$f.dc.tmp" && mv "$f.dc.tmp" "$f.dash.comments.json"
    exit 0 ;;
  "issue close") printf 'dash-close %s %s\n' "$repo" "${3:-}" >> "$STUB_CALL_LOG"; exit 0 ;;
  "issue edit")
    printf 'dash-edit %s %s\n' "$repo" "${3:-}" >> "$STUB_CALL_LOG"
    bf=$(printf '%s\n' "$args" | sed -n 's/.*--body-file \([^ ]*\).*/\1/p'); cp "$bf" "$f.dash.body"; exit 0 ;;
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
NOW=$(tsm 60)     # 창 안 · 인계 전 창(기본 90분) 안
OLD=$(tsm 4320)   # 3일 전 — 창 밖
AGO200=$(tsm 200) # 인계 전 창(기본 90분) 밖 — `--since 24h` 창에는 든다
AGO240=$(tsm 240) # 재디스패치 픽스처의 PR 나이(4시간) — claim 과 갈라놓는 값 (#177)
AGO5=$(tsm 5)     # 재디스패치 픽스처의 **가장 최근** claim (#177)

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
 {"number":4825,"title":"사람대기 대기자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":4770,"title":"사람대기 구현중자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"agent:claimed"},{"name":"hold:conflict"}]},
 {"number":4780,"title":"사람대기 정책자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":4771,"title":"사람대기 코멘트 조회 실패자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"}]},
 {"number":4826,"title":"사람대기 사유 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"}]},
 {"number":4790,"title":"agent:claimed 인데 배포대기가 이긴 건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"},{"name":"deploy-wait"}]},
 {"number":4838,"title":"라벨로 배포대기","createdAt":"@NOW@","labels":[{"name":"deploy-wait"}]},
 {"number":4796,"title":"배포 대기: PR #4700 — 제목 폴백","createdAt":"@NOW@","labels":[]},
 {"number":4848,"title":"배포 검증: 화력 작전 — 제목 폴백 2형식","createdAt":"@NOW@","labels":[{"name":"needs-human"}]},
 {"number":4900,"title":"루프 밖 이슈","createdAt":"@NOW@","labels":[{"name":"enhancement"}]},
 {"number":4963,"title":"사람 세션이 직접 붙인 이슈","createdAt":"@NOW@","labels":[]},
 {"number":4964,"title":"무소속 회귀 대조 — agent 헤드는 종전대로 warn","createdAt":"@NOW@","labels":[]}
]
FX

sed "s/@NOW@/$NOW/g; s/@AGO200@/$AGO200/g" > "$tmp/fx/ggqgga_BodaT.pr_open.json" <<'FX'
[
 {"number":4854,"headRefName":"agent/issue-4803","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4803}],"labels":[]},
 {"number":4855,"headRefName":"agent/issue-4701","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":4701}],"labels":[]},
 {"number":4856,"headRefName":"agent/issue-4790","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4790}],"labels":[]},
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
  "closingIssuesReferences":[{"number":4600}],"labels":[{"name":"flow:ready"}]},
 {"number":4987,"headRefName":"feat/adspower-swr-4963","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4963}],"labels":[]},
 {"number":4991,"headRefName":"agent/issue-4964","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4964}],"labels":[]},
 {"number":4992,"headRefName":"feat/사람이-연-이슈없는-브랜치","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[],"labels":[]}
]
FX

sed "s/@NOW@/$NOW/g; s/@OLD@/$OLD/g" > "$tmp/fx/ggqgga_BodaT.pr_closed.json" <<'FX'
[
 {"number":4792,"headRefName":"agent/issue-4753","state":"CLOSED","mergedAt":null,"closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4753}],"labels":[]},
 {"number":4791,"headRefName":"agent/issue-4752","state":"CLOSED","mergedAt":null,"closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4752}],"labels":[{"name":"dup"}]},
 {"number":4793,"headRefName":"agent/issue-4754","state":"MERGED","mergedAt":"@NOW@","closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4754}],"labels":[]},
 {"number":4794,"headRefName":"agent/issue-4755","state":"CLOSED","mergedAt":null,"closedAt":"@OLD@","createdAt":"@OLD@",
  "closingIssuesReferences":[{"number":4755}],"labels":[]},
 {"number":4795,"headRefName":"fix/사람이-연-브랜치","state":"CLOSED","mergedAt":null,"closedAt":"@NOW@","createdAt":"@OLD@",
  "closingIssuesReferences":[],"labels":[]}
]
FX

# ── 질문(hold-note) 코멘트 픽스처 (#157) ────────────────────────────────────
# #4780(policy) 은 질문이 있다 → 표시 없음. #4770(conflict) 은 코멘트 파일이 없어
# 질문 없음. #4771 은 조회 자체가 실패 → 사실을 모르므로 표시하지 않는다(거짓 단정 금지).
cat > "$tmp/fx/ggqgga_BodaT.comments.4780.json" <<'FX'
{"comments":[{"body":"진행 중입니다"},
             {"body":"사람 확인(policy): A인가 B인가\n<!-- hold-note: policy --><!-- bodat:worker -->"}]}
FX
# #4770 은 코멘트가 있긴 한데 질문 마커가 없다 — "코멘트 0건" 과 "질문 없음" 이 다른
# 조건임을 실증한다(마커 없는 사람 코멘트를 질문으로 착각하면 안 된다).
cat > "$tmp/fx/ggqgga_BodaT.comments.4770.json" <<'FX'
{"comments":[{"body":"이거 어떻게 할까요"}]}
FX
: > "$tmp/fx/ggqgga_BodaT.comments.4771.fail"

# ── 타임라인 픽스처 (#177) — bodat #4701 은 정상 흐름(PR 과 claim 이 같은 시각대) ────
# 이 건은 회귀 대조군이다: claim 기준으로 재도 종전과 같은 200분이 나와야 한다.
sed "s/@AGO200@/$AGO200/g" > "$tmp/fx/ggqgga_BodaT.timeline.4701.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent-ready"},"created_at":"@AGO200@"},
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO200@"},
 {"event":"commented","created_at":"@AGO200@"}
]
FX

# ── 픽스처: ggqgga/Reclaim (reclaim) — 재디스패치·조회 실패·이벤트 부재 (#177) ──
# 셋 다 **구현중 버킷 + 인계 전 창 밖 PR**(4시간 전) 이라 사망 의심 꼬리표가 붙는 자리다.
# 갈리는 건 claim 시각을 얻는 경로뿐이다.
# PR #65 는 #61 과 **같은 이슈(#31)** 를 가리키는 두 번째 무소속 PR (#181) — 중복 제거
# 없이는 같은 이슈의 타임라인을 두 번 조회하고 CLAIM_TIME_MAX 도 두 번 깎는다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Reclaim.issues.json" <<'FX'
[
 {"number":31,"title":"홀드 해제 후 재claim — PR 은 4시간 전, claim 은 5분 전","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":32,"title":"타임라인 조회 실패","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":33,"title":"타임라인에 claim 이벤트가 없다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":34,"title":"claim 시각이 예상 밖 형식","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]}
]
FX
sed "s/@AGO240@/$AGO240/g" > "$tmp/fx/ggqgga_Reclaim.pr_open.json" <<'FX'
[
 {"number":61,"headRefName":"agent/issue-31","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":31}],"labels":[]},
 {"number":65,"headRefName":"agent/issue-31-2","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":31}],"labels":[]},
 {"number":62,"headRefName":"agent/issue-32","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":32}],"labels":[]},
 {"number":63,"headRefName":"agent/issue-33","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":33}],"labels":[]},
 {"number":64,"headRefName":"agent/issue-34","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":34}],"labels":[]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Reclaim.pr_closed.json"
# #31 — 1쪽엔 **옛** claim(200분 전), 2쪽에 지금의 claim(5분 전). `--paginate` 를 빠뜨리면
# 1쪽만 오므로 200분이 나온다 — 세 값(240/200/5)이 다 달라 무엇을 재고 있는지가 드러난다.
sed "s/@AGO240@/$AGO240/g; s/@AGO200@/$AGO200/g" > "$tmp/fx/ggqgga_Reclaim.timeline.31.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent-ready"},"created_at":"@AGO240@"},
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO200@"},
 {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"@AGO200@"},
 {"event":"labeled","label":{"name":"needs-human"},"created_at":"@AGO200@"}
]
FX
sed "s/@AGO5@/$AGO5/g" > "$tmp/fx/ggqgga_Reclaim.timeline.31.p2.json" <<'FX'
[
 {"event":"unlabeled","label":{"name":"needs-human"},"created_at":"@AGO5@"},
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO5@"}
]
FX
: > "$tmp/fx/ggqgga_Reclaim.timeline.32.fail"
# #33 — 조회는 되는데 claim 이벤트가 없다. "0분" 도 "PR 나이" 도 아닌 **모른다** 다.
sed "s/@AGO240@/$AGO240/g" > "$tmp/fx/ggqgga_Reclaim.timeline.33.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent-ready"},"created_at":"@AGO240@"},
 {"event":"commented","created_at":"@AGO240@"}
]
FX
# #34 — claim 이벤트는 있는데 시각이 jq 의 fromdateiso8601 이 못 읽는 형식(오프셋)이다.
# 그대로 넘기면 **레포 블록 전체가 집계 실패**로 죽는다 — 한 건만 미상으로 접고 나머지는 낸다.
cat > "$tmp/fx/ggqgga_Reclaim.timeline.34.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"2026-09-10T12:06:22+09:00"}
]
FX

# ── 픽스처: ggqgga/Capped (capped) — 코멘트 100건 상한 · HOLD_NOTE_MAX 전용 ──
# 큰 bodat 픽스처를 더 부풀리지 않으려고 상한 두 축만 따로 세운다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Capped.issues.json" <<'FX'
[
 {"number":12,"title":"질문 없는 홀드","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":11,"title":"코멘트 100건인데 마커 있음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"}]},
 {"number":10,"title":"코멘트 100건인데 마커 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Capped.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_Capped.pr_closed.json"
# `--json comments` 는 페이지네이션 없이 첫 100건만 준다 — 마커가 그 밖으로 밀린 홀드를
# `질문 없음` 으로 찍으면 없는 결함을 사람에게 들이민다. 상한에 닿았으면 "모른다" 다.
jq -n '{comments: [range(0;100) | {body: "잡담 \(.)"}]}' > "$tmp/fx/ggqgga_Capped.comments.10.json"
jq -n '{comments: ([range(0;99) | {body: "잡담 \(.)"}]
                   + [{body: "사람 확인(conflict): 어느 쪽? <!-- hold-note: conflict --><!-- bodat:worker -->"}])}' \
  > "$tmp/fx/ggqgga_Capped.comments.11.json"

# ── 픽스처: ggqgga/Stale (stale) — 낡은 사유의 마커 (#160) ──────────────────
# 마커는 코멘트라 홀드가 풀려도 남는다. 사유를 안 가리면 예전 홀드가 남긴
# `hold-note: policy` 가 지금의 `hold:conflict` 홀드를 "질문 있음" 으로 위장한다 —
# 이 기능이 잡으라고 만들어진 바로 그 상태(질문 없는 conflict 홀드)가 숨는다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Stale.issues.json" <<'FX'
[
 {"number":24,"title":"conflict 홀드인데 마커는 낡은 policy","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"}]},
 {"number":23,"title":"conflict 홀드 + conflict 마커","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"}]},
 {"number":22,"title":"policy 홀드 + policy 마커","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":21,"title":"두 사유 동시 홀드 + conflict 마커","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"},{"name":"hold:policy"}]},
 {"number":20,"title":"policy 홀드인데 마커는 낡은 conflict","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Stale.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_Stale.pr_closed.json"
cat > "$tmp/fx/ggqgga_Stale.comments.24.json" <<'FX'
{"comments":[{"body":"사람 확인(policy): 옛 홀드의 질문\n<!-- hold-note: policy --><!-- bodat:worker -->"}]}
FX
cat > "$tmp/fx/ggqgga_Stale.comments.23.json" <<'FX'
{"comments":[{"body":"사람 확인(conflict): 어느 쪽으로 풀까\n<!-- hold-note: conflict --><!-- bodat:worker -->"}]}
FX
cat > "$tmp/fx/ggqgga_Stale.comments.22.json" <<'FX'
{"comments":[{"body":"사람 확인(policy): A인가 B인가\n<!-- hold-note: policy --><!-- bodat:worker -->"}]}
FX
cat > "$tmp/fx/ggqgga_Stale.comments.21.json" <<'FX'
{"comments":[{"body":"사람 확인(conflict): 어느 쪽으로 풀까\n<!-- hold-note: conflict --><!-- bodat:worker -->"}]}
FX
cat > "$tmp/fx/ggqgga_Stale.comments.20.json" <<'FX'
{"comments":[{"body":"사람 확인(conflict): 옛 홀드의 질문\n<!-- hold-note: conflict --><!-- bodat:worker -->"}]}
FX

# ── 픽스처: ggqgga/Blockers (blockers) — 대기/막힘 가르기 (#248) ─────────────
# 블로커 파싱 규칙은 eligible-issues.sh 와 **같은 의미**여야 한다. 개별 반례만 막으면
# 근사가 '더 많이 잡는' 쪽으로 틀리고(정상 `대기` 가 `막힘` 으로 내려간다 — 원래 버그보다
# 나쁘다), 그래서 규칙을 통째로 옮긴 뒤 아래 격자로 **양방향**을 전수 단언한다.
#
#   번호  입력                                   want
#   ────  ─────────────────────────────────────  ────────────────────────────
#   #10   본문 2번째 줄에 `Blocked by #900`      막힘 ← #900(사람대기)  ← 줄 앞에 다른 줄이
#                                                있어도 잡힌다(줄 단위 앵커)
#   #11   라벨 `blocked-by:901`                  막힘 ← #901(구현중)
#   #12   본문 `Blocked by #999`(열린 목록 밖)   대기 (닫힘 = 자동 해제)
#   #13   본문 `Blocked by #950`(열린 PR)        막힘 ← PR #950
#   #14   본문 + 라벨 둘 다 #902                 막힘 ← #902(대기) 하나로 dedupe
#   #15   산문 속 `blocked by #900`(줄 시작 X)   대기 ← **과잉 포획 반증**
#   #16   본문 `Blocked by #900`                 막힘 ← #900 (#10 과 한 warn 으로 묶인다)
#   #17   `  blocked-by #903`(앞 공백·하이픈형)  막힘 ← #903(배포대기) → warn(사람 게이트)
#   #18   라벨 `blocked-by:abc`(숫자 아님)       대기 ← 숫자만 블로커(eligible 의 grep 과 같다)
#   #19   `Blocked by #901 — 참고 #902`          막힘 ← #901 만(뒤쪽 언급은 안 집는다, #1457)
#   #20   `BLOCKED BY #902`(대문자)              막힘 ← #902(대소문자 무시)
#   #21   `not blocked by #900`(줄 시작이지만    대기 ← **과잉 포획 반증**(앵커가 살아 있다)
#         앞에 다른 낱말)
#   #22   `blockedby #900`(구분자 없음)          대기 ← **과잉 포획 반증**
#   #23   구현중 버킷인데 본문에 블로커          구현중 그대로(막힘은 `대기` 에서만 갈린다)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Blockers.issues.json" <<'FX'
[
 {"number":900,"title":"사람이 답해야 풀리는 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":901,"title":"루프가 처리 중인 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":902,"title":"대기 중인 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"}]},
 {"number":903,"title":"배포 게이트 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"deploy-wait"}]},
 {"number":10,"title":"본문 블로커 — 줄 앞에 다른 줄이 있다","createdAt":"@NOW@","body":"배경 설명 한 줄\nBlocked by #900","labels":[{"name":"agent-ready"}]},
 {"number":11,"title":"라벨 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"blocked-by:901"}]},
 {"number":12,"title":"닫힌 블로커 — 자동 해제","createdAt":"@NOW@","body":"Blocked by #999","labels":[{"name":"agent-ready"}]},
 {"number":13,"title":"블로커가 열린 PR","createdAt":"@NOW@","body":"Blocked by #950","labels":[{"name":"agent-ready"}]},
 {"number":14,"title":"본문+라벨 중복","createdAt":"@NOW@","body":"Blocked by #902","labels":[{"name":"agent-ready"},{"name":"blocked-by:902"}]},
 {"number":15,"title":"산문 속 언급은 블로커 아님","createdAt":"@NOW@","body":"본문 첫 줄\n이 건은 blocked by #900 라고 산문에 적혀 있다","labels":[{"name":"agent-ready"}]},
 {"number":16,"title":"같은 블로커의 두 번째 하위","createdAt":"@NOW@","body":"Blocked by #900","labels":[{"name":"agent-ready"}]},
 {"number":17,"title":"앞 공백 + 하이픈형","createdAt":"@NOW@","body":"  blocked-by #903","labels":[{"name":"agent-ready"}]},
 {"number":18,"title":"숫자 아닌 라벨 접미","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"blocked-by:abc"}]},
 {"number":19,"title":"같은 줄 뒤쪽 언급은 안 집는다","createdAt":"@NOW@","body":"Blocked by #901 — 참고 #902","labels":[{"name":"agent-ready"}]},
 {"number":20,"title":"대문자","createdAt":"@NOW@","body":"BLOCKED BY #902","labels":[{"name":"agent-ready"}]},
 {"number":21,"title":"줄 시작이지만 앞에 낱말이 있다","createdAt":"@NOW@","body":"not blocked by #900","labels":[{"name":"agent-ready"}]},
 {"number":22,"title":"구분자 없음","createdAt":"@NOW@","body":"blockedby #900","labels":[{"name":"agent-ready"}]},
 {"number":23,"title":"구현중인데 블로커가 있다","createdAt":"@NOW@","body":"Blocked by #900","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]}
]
FX
# PR #950 — 블로커로 지목되는 열린 PR. head 가 agent/issue-* 가 아니고 연결 이슈도 없어
# 무소속 후보 자체가 아니다(이 레포의 warn 을 블로커 warn 둘로만 좁혀 둔다).
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Blockers.pr_open.json" <<'FX'
[
 {"number":950,"headRefName":"feat/블로커-PR","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[],"labels":[]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Blockers.pr_closed.json"

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
# 본문(#248 이 더한 `body` 필드)을 8KB × 200건 = 약 1.6MB 로 채운다 — 이 페이로드를
# `--argjson` 으로 **커맨드라인**에 실으면 ARG_MAX(macOS 1MB)에 걸려 레포 블록 전체가
# `집계 실패(jq)` 로 죽는다. 파일(`--slurpfile`) 경유라는 것을 이 픽스처가 문다.
jq -n --arg t "$NOW" \
  '[range(1;201) | {number: ., title:"채움", createdAt:$t, body: ("x" * 8000), labels:[]}]' \
  > "$tmp/fx/ggqgga_Big.issues.json"
echo '[]' > "$tmp/fx/ggqgga_Big.pr_open.json"
jq -n --arg t "$NOW" \
  '[range(1;201) | {number: ., headRefName:"fix/채움", state:"CLOSED", mergedAt:$t,
                    closedAt:$t, createdAt:$t, closingIssuesReferences:[], labels:[]}]' \
  > "$tmp/fx/ggqgga_Big.pr_closed.json"

run() {  # run <인자...> — 출력은 $tmp/out, exit 는 RC
  : > "$STUB_CALL_LOG"   # 호출 로그는 런 단위 — 앞선 런의 호출이 건수 단언에 새지 않게
  STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" "$SUT" "$@" >"$tmp/out" 2>"$tmp/err"
  RC=$?
}

# ── ①②③④ 두 레포 정상 스코프 ─────────────────────────────────────────────
run --repo ggqgga/BodaT --repo ggqgga/issue-runner --since 24h
ck "정상 스코프: exit 0" "$RC" 0

has_line "헤더: 열림=버킷합(19) · 스코프 · 창" "$tmp/out" \
  "파이프라인 bodat — 열림 20 · 스코프 bodat·runner · 창 24h"
has_line "대기 3(창 밖 파생건도 대기에는 남는다)" "$tmp/out" \
  "  대기      4  #4901 #4832 #4831 #4600"
# (#248) 블로커가 없는 픽스처에서는 `막힘 0` 한 줄이 느는 것 말고 출력이 바뀌지 않는다 —
# 위아래의 기존 기대값이 그대로 통과하는 것이 그 증거다.
has_line "(#248) 비-막힘 픽스처는 막힘 0" "$tmp/out" "  막힘      0"
# 인계 전 창(기본 90분) — #4854 는 60분 전이라 무소속 warn 이 아니라 구현중 줄에 붙는다.
# #4701 의 PR #4855 는 200분 전이라 붙지 않는다(아래 warn 에서 잡힌다).
has_line "구현중 2(좌초건 포함) — 창 안 PR 만 '인계 전' 으로 병기" "$tmp/out" \
  "  구현중    2  #4803 ← PR #4854(인계 전) #4701"
has_line "검증대기 2 — 제목이 배포 대기… 여도 사다리 라벨이 이긴다" "$tmp/out" \
  "  검증대기  2  #4810 ← PR #4840 #4500"
has_line "마감대기 1 + 연결 PR" "$tmp/out" \
  "  마감대기  1  #4811 ← PR #4841"
has_line "마감중 2(중복단계건은 가장 뒤 단계로)" "$tmp/out" \
  "  마감중    2  #4818 ← PR #4837 #4700"
# 사유 3종(ladder·policy·conflict) 전부 + hold:* 없는 건은 `사유 없음`
has_line "사람대기 5 — 사다리 위치 + hold:* 사유 + 질문 유무 + 열린 연결 PR" "$tmp/out" \
  "  사람대기  5  #4826(대기, 사유 없음) #4825(대기, ladder, PR #4835) #4780(대기, policy) #4771(대기, conflict) #4770(구현중, conflict, 질문 없음)"
has_line "배포대기 4 — 라벨 + 제목 폴백 2형식 + agent:claimed 이 붙어도 배포대기가 이긴다" "$tmp/out" \
  "  배포대기  4  #4848 #4838 #4796 #4790"
# 배포대기가 사람대기보다 앞선다 — needs-human 을 단 `배포 검증:` 이슈가 사람대기로 새면 안 된다
no_sub "제목 폴백건은 사람대기에 안 샌다" "$tmp/out" "#4848("
# ② 창 필터: 머지된 PR·창 밖 PR·사람 브랜치는 실패 아님
has_line "실패 1 — 창 안 미머지 agent PR 만(dup 라벨 건은 뺀다)" "$tmp/out" \
  "  실패      1  PR #4792(#4753, 머지 없이 닫힘)"
has_line "중복종료 1 — PR 라벨 dup 인 건은 별도 줄" "$tmp/out" \
  "  중복종료  1  PR #4791(#4752, 중복 종료)"
no_sub "중복종료: 실패 줄에 겹쳐 세지 않는다" "$tmp/out" "PR #4791(#4752, 머지 없이 닫힘)"
no_sub "실패: 창 밖 PR #4794 제외" "$tmp/out" "#4794"
no_sub "실패: 머지된 PR #4793 제외" "$tmp/out" "#4793"
no_sub "실패: 사람 브랜치 PR #4795 제외" "$tmp/out" "#4795"
has_line "파생 1 — 창 안 spinoff 만(#4901 은 창 밖)" "$tmp/out" \
  "  파생      1  #4832"
has_line "승격 대기 — release 없는 레포" "$tmp/out" \
  "  승격 대기 —"
# 루프 밖 이슈는 어디에도 안 센다
no_sub "루프 밖 이슈 #4900 미집계" "$tmp/out" "#4900"

# ③ warn 5종 + 사유 없음 + 인계 지연(+ #188 회귀 대조 PR #4991 1건 + #265 정지 미러 1건)
has_line "warn 12건(질문 유무 미확인 1 · #188 대조 #4991 · #265 정지 미러 #4852)" "$tmp/out" "  warn      12"
# (#265) PR #4852 는 `needs-human` 을 단 채 열려 있는데 연결 이슈 #4832 는 깨끗하다 —
# 종전엔 무소속 warn 에서도 빠지고(PR 자신이 needs-human) 이슈도 사람대기 칸에 안 떠
# **어느 줄에도 안 나타났다**. 네 게이트(#242·#262)는 그 PR 을 확정적으로 제외한다.
has_sub "warn 정지 미러 불일치(PR 에만 정지 라벨)" "$tmp/out" \
  "    - 정지 미러 불일치 #4832(bodat) ↔ PR #4852(bodat) — 이슈 없음 · PR needs-human"
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
# 인계 전 창 — 창 안(#4854)은 warn 이 아니고, 창 밖(#4855)은 warn + 사망 의심 꼬리표
no_sub "인계 전 창 안 PR #4854 는 warn 아님" "$tmp/out" "무소속 PR #4854"
# 정상 흐름(PR 과 claim 이 같은 시각대)은 claim 기준으로 재도 종전과 같은 숫자다 (#177 무회귀).
has_line "인계 전 창 밖 PR #4855 는 무소속 warn + 사망 의심(claim 기준 200분)" "$tmp/out" \
  "    - 무소속 PR #4855(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4701 는 needs-human 아님(agent:claimed 인데 200분 경과 — 워커 사망 의심)"
# 판정축은 `agent:claimed` **라벨**이 아니라 **구현중 버킷** — 라벨을 단 채 배포대기로 간
# 이슈(#4790)의 라벨 없는 PR 은 warn 에서 빠지면 어디에도 안 그려져 거짓 깨끗함이 된다.
# 정확히 이 줄이어야 한다(꼬리표가 붙으면 has_line 이 깨진다 — 인계 창과 무관한 건이다).
has_line "구현중 버킷 밖의 agent:claimed PR 은 무소속 warn(꼬리표 없이)" "$tmp/out" \
  "    - 무소속 PR #4856(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4790 는 needs-human 아님"
no_sub "구현중 버킷 밖 PR 은 '인계 전' 으로도 안 그려진다" "$tmp/out" "PR #4856(인계 전)"

# ── (#188) 무소속 PR warn 이 사람 세션 브랜치(head 가 agent/issue-* 아님)에도 울리던
# 문제 — warn 은 "루프가 교정 가능한 불변식 위반" 으로 좁히고, 제외된 후보는 note 로
# 강등한다(존재 자체는 남긴다). 실측 원천(bodat PR #4987/#4963)과 같은 모양으로 픽스처.
# 케이스1: head feat/* + 연결 이슈 있음 + 단계 라벨 0 → 무소속 warn 은 0, note 로 강등.
no_sub "(#188) 케이스1: 사람 세션 PR #4987 는 무소속 warn 아님" "$tmp/out" "무소속 PR #4987"
has_line "(#188) note 1건 — 사람 세션 PR 만 강등된다(에이전트 헤드·이슈 미연결은 안 섞인다)" \
  "$tmp/out" "  note      1"
has_line "(#188) 케이스1: 사람 세션 PR #4987 는 note 로 강등된다" "$tmp/out" \
  "    - 사람 세션 PR #4987(bodat) — head feat/adspower-swr-4963 (agent/issue-* 아님) · 연결 이슈 #4963 · 루프가 못 집어 warn 아님"
# 케이스2(회귀 방지): head agent/issue-* + 단계 라벨 0 + 연결 이슈 needs-human 아님
# → 종전대로 무소속 warn 1건. note 로는 내려가지 않는다.
has_line "(#188) 케이스2: agent 헤드는 종전대로 무소속 warn" "$tmp/out" \
  "    - 무소속 PR #4991(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4964 는 needs-human 아님"
no_sub "(#188) 케이스2: agent 헤드는 note 로 강등되지 않는다" "$tmp/out" "사람 세션 PR #4991"
# 케이스3: head feat/* + 연결 이슈 없음 → 애초에 후보가 아니다(종전 동작 유지) —
# 무소속 warn 에도 note 에도 나타나지 않는다(존재를 지키는 대상 자체가 아니라서).
no_sub "(#188) 케이스3: 연결 이슈 없는 사람 브랜치는 무소속 warn 에 없다" "$tmp/out" "PR #4992"
no_sub "(#188) 케이스3: 연결 이슈 없는 사람 브랜치는 note 에도 없다" "$tmp/out" "사람 세션 PR #4992"

# 사유 없는 needs-human 만 warn — hold:* 가 붙은 셋은 조용하다
has_sub "warn needs-human 사유 없음" "$tmp/out" \
  "    - needs-human 사유 없음 #4826(bodat) — hold:* 라벨 없음"
no_sub "사유 있는 건은 사유 없음 warn 아님" "$tmp/out" "사유 없음 #4825"
no_sub "사유 있는 건은 사유 없음 warn 아님(conflict)" "$tmp/out" "사유 없음 #4770"
# 배포대기가 이긴 needs-human 이슈(#4848)는 이 warn 밖 — 루프 전이가 만든 게 아니다
no_sub "배포대기로 간 needs-human 은 사유 없음 warn 밖" "$tmp/out" "사유 없음 #4848"

# ── ⑫ (#157) 질문(hold-note) 없는 policy·conflict 홀드는 `질문 없음` ─────────
# 질문이 있는 #4780(policy) 과, 마커 없는 코멘트만 있는 #4770(conflict) 이 갈린다 —
# "코멘트 0건" 이 아니라 "마커 있는 코멘트 0건" 이 기준이다.
no_sub "질문 있는 policy 홀드(#4780)엔 표시 없음" "$tmp/out" "#4780(대기, policy, 질문 없음)"
# 사유가 ladder 인 홀드는 대상 밖(질문이 선택이다) — 표시도 조회도 없다
no_sub "ladder 홀드(#4825)엔 질문 없음 표시 없음" "$tmp/out" "#4825(대기, ladder, 질문 없음"
no_sub "사유 없는 홀드(#4826)엔 질문 없음 표시 없음" "$tmp/out" "#4826(대기, 사유 없음, 질문 없음)"
# 조회 실패(#4771)는 "질문이 없다" 로 단정하지 않는다 — 모르는 것을 아는 척하지 않는다
no_sub "코멘트 조회 실패건은 질문 없음 으로 단정하지 않는다" "$tmp/out" "#4771(대기, conflict, 질문 없음)"
has_sub "코멘트 조회 실패는 stderr 한 줄로 드러난다" "$tmp/err" \
  "bodat #4771 질문(hold-note) 코멘트 조회 실패"
# stderr 로만 말하면 세 루프의 ④ Report(stdout 만 붙인다)에서 기능이 통째로 사라진다
has_sub "코멘트 조회 실패는 stdout warn 으로도 올라온다" "$tmp/out" \
  "    - 질문 유무 미확인 #4771(bodat) — 조회 실패"
# 조회는 **사람대기 버킷의 policy·conflict** 에만 — 다른 버킷·다른 사유엔 안 묻는다(N+1 억제)
ck "코멘트 조회 대상은 정확히 3건" "$(grep -c '^comments ' "$STUB_CALL_LOG")" 3
for n in 4770 4771 4780; do
  check "코멘트 조회: #$n 은 묻는다" \
    "$(grep -qxF "comments ggqgga/BodaT $n" "$STUB_CALL_LOG" && echo ok || echo no)"
done
for n in 4825 4826 4848 4832 4803 4818; do
  check "코멘트 조회: #$n 엔 안 묻는다" \
    "$(grep -qxF "comments ggqgga/BodaT $n" "$STUB_CALL_LOG" && echo no || echo ok)"
done
check "코멘트 조회: 깨끗한 레포(runner)엔 0건" \
  "$(grep -q '^comments ggqgga/issue-runner ' "$STUB_CALL_LOG" && echo no || echo ok)"

# ── ⑬ (#177) 타임라인 조회는 **꼬리표가 붙는 후보에만** — 전체 이슈에 걸면 틱이 느려진다 ──
ck "타임라인 조회 대상은 정확히 1건" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 1
check "타임라인 조회: 꼬리표가 붙는 #4701 만 묻는다" \
  "$(grep -qxF "timeline ggqgga/BodaT 4701" "$STUB_CALL_LOG" && echo ok || echo no)"
# #4790 은 구현중 버킷 밖(배포대기가 이겼다) → 꼬리표가 없으니 조회도 없다.
# #4803 은 인계 전 창 안이라 warn 자체가 아니다. 나머지는 무소속 warn 후보도 아니다.
for n in 4790 4803 4832 4818 4826 4700; do
  check "타임라인 조회: #$n 엔 안 묻는다" \
    "$(grep -qxF "timeline ggqgga/BodaT $n" "$STUB_CALL_LOG" && echo no || echo ok)"
done
check "타임라인 조회: 깨끗한 레포(runner)엔 0건" \
  "$(grep -q '^timeline ggqgga/issue-runner ' "$STUB_CALL_LOG" && echo no || echo ok)"


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
has_line "창 7d: 중복종료는 여전히 1(실패로 새지 않는다)" "$tmp/out" \
  "  중복종료  1  PR #4791(#4752, 중복 종료)"

# ── §5 인계 전 창 — HANDOFF_GRACE_MIN 으로 창을 넓히면 #4855 도 '인계 전' 이 된다 ──
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HANDOFF_GRACE_MIN=300 \
  "$SUT" --repo ggqgga/BodaT --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "HANDOFF_GRACE_MIN=300: exit 0" "$RC" 0
has_line "창 300분: #4855 도 인계 전으로 넘어온다" "$tmp/out" \
  "  구현중    2  #4803 ← PR #4854(인계 전) #4701 ← PR #4855(인계 전)"
no_sub "창 300분: #4855 무소속 warn 사라짐" "$tmp/out" "무소속 PR #4855"
# 형식 오류는 레포별 '집계 실패(jq)' 로 위장되지 않고 환경 실패로 죽는다
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HANDOFF_GRACE_MIN=90분 \
  "$SUT" --repo ggqgga/BodaT --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "HANDOFF_GRACE_MIN 형식 오류: exit 1" "$RC" 1
has_sub "HANDOFF_GRACE_MIN 형식 오류: stdout 에도 사유" "$tmp/out" \
  "파이프라인 — 스냅샷 실패: HANDOFF_GRACE_MIN 형식 오류: 90분"

# ── ⑬ (#177) 사망 의심 경과시간 = 가장 최근 agent:claimed 시각 ──────────────
run --repo ggqgga/Reclaim --since 24h
ck "reclaim: exit 0" "$RC" 0
# (a) 재디스패치 — PR 은 240분 전, 1쪽의 옛 claim 은 200분 전, 지금 claim 은 5분 전.
#     PR 나이(240)로 재면 살아 있는 워커를 사망으로 신고하고, `--paginate` 를 빠뜨리면
#     1쪽의 옛 claim(200)이 나온다. 셋이 다 다른 값이라 무엇을 쟀는지가 드러난다.
has_line "(a) 재claim 건은 claim 기준 5분" "$tmp/out" \
  "    - 무소속 PR #61(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #31 는 needs-human 아님(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
no_sub "(a) PR 나이(240분)로 재지 않는다" "$tmp/out" "240분 경과"
no_sub "(a) 첫 페이지의 옛 claim(200분)을 취하지 않는다 — 전량을 읽는다" "$tmp/out" "200분 경과"
# (a) (#181) 같은 이슈(#31)를 가리키는 두 번째 무소속 PR #65 — 값은 #61 과 같아야 한다
# (같은 타임라인을 다시 조회하지 않고 캐시된 claim 시각을 재사용한다는 뜻).
has_line "(a) 같은 이슈의 두 번째 PR #65 도 같은 claim 시각(5분)" "$tmp/out" \
  "    - 무소속 PR #65(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #31 는 needs-human 아님(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
# (b) 조회 실패·이벤트 부재는 숫자를 지어내지 않는다. warn 자체는 유지한다.
has_line "(b) 타임라인 조회 실패 → 경과 미상(warn 은 유지)" "$tmp/out" \
  "    - 무소속 PR #62(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #32 는 needs-human 아님(agent:claimed 인데 경과 미상 — 확인 필요)"
has_line "(b) claim 이벤트 부재 → 경과 미상(0분으로 접지 않는다)" "$tmp/out" \
  "    - 무소속 PR #63(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #33 는 needs-human 아님(agent:claimed 인데 경과 미상 — 확인 필요)"
# 형식 밖 시각을 jq 에 그대로 넘기면 레포 블록이 통째로 죽는다 — 한 건만 미상으로 접는다.
has_line "(b) 형식 밖 claim 시각 → 그 건만 경과 미상" "$tmp/out" \
  "    - 무소속 PR #64(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #34 는 needs-human 아님(agent:claimed 인데 경과 미상 — 확인 필요)"
no_sub "(b) 형식 밖 시각이 레포 블록을 죽이지 않는다" "$tmp/out" "reclaim — 조회 실패"
has_line "reclaim: warn 5건(#65 포함)" "$tmp/out" "  warn      5"
has_sub "(b) 조회 실패는 stderr 에도 사유가 남는다" "$tmp/err" \
  "reclaim #32 agent:claimed 시각(타임라인) 조회 실패"
has_sub "(b) 시각을 못 얻은 건도 stderr 한 줄" "$tmp/err" \
  "reclaim #33 타임라인에서 agent:claimed 시각을 못 얻음"
# (a) (#181) 이슈 #31 을 가리키는 무소속 PR 이 #61·#65 두 개인데도 타임라인 조회는 1회뿐 —
# 중복 제거 없이는 같은 이슈를 두 번(총 5회) 조회한다.
ck "reclaim: 타임라인 조회는 고유 이슈 4건뿐(PR 은 5개)" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 4
ck "reclaim: 이슈 #31 타임라인 조회는 정확히 1회" \
  "$(grep -cxF "timeline ggqgga/Reclaim 31" "$STUB_CALL_LOG")" 1

run --repo ggqgga/Reclaim --since 24h --json
ck "--json: 사망 의심 경과는 3상태(분 / null=미상)" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="orphan_pr") | {p:.pr, m:.claimed_minutes}]' < "$tmp/out")" \
  '[{"p":61,"m":5},{"p":65,"m":5},{"p":62,"m":null},{"p":63,"m":null},{"p":64,"m":null}]'

# ── (a) (#181) 상한 소모는 PR 줄 수가 아니라 고유 이슈 수다 ──────────────────
# 고유 이슈는 4건(31·32·33·34)인데 PR 줄은 5개(#31 이 #61·#65 둘). 상한을 정확히 4로
# 두면: 중복 제거가 없다면 다섯째 줄(#65, 이슈 31 의 재등장)이 상한을 넘겨 진짜 넷째 고유
# 이슈(#34)가 조회조차 못 되고 밀려난다. 중복 제거가 되면 고유 이슈 4건이 상한 안에 모두
# 들어가 #34 도 조회는 된다(그 값 자체는 형식 밖이라 여전히 "확인 필요" — 조회 시도는 했다).
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" CLAIM_TIME_MAX=4 \
  "$SUT" --repo ggqgga/Reclaim --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "CLAIM_TIME_MAX=4(고유 이슈 수): exit 0" "$RC" 0
ck "CLAIM_TIME_MAX=4: 타임라인 조회는 고유 이슈 수만큼(4건)" \
  "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 4
no_sub "CLAIM_TIME_MAX=4: 상한 초과가 발생하지 않는다(PR 줄 수로 셌다면 #34 가 밀렸을 것)" \
  "$tmp/out" "조회 상한"
no_sub "CLAIM_TIME_MAX=4: 상한 초과 stderr 도 없다" "$tmp/err" "claim 시각 조회 상한"
has_sub "CLAIM_TIME_MAX=4: 넷째 고유 이슈(#34)도 조회는 됐다(형식 밖이라 확인 필요)" \
  "$tmp/out" "연결 이슈 #34 는 needs-human 아님(agent:claimed 인데 경과 미상 — 확인 필요)"

# ── (b)(c) (#181) 상한에 걸려 안 본 것과 조회했지만 실패한 것은 다른 문구다 ──────
# 상한을 1로 좁히면 고유 이슈 중 첫째(#31)만 조회되고 둘째(#32)는 **안 본다** — 그 문구는
# `확인 필요`(조회했지만 실패)가 아니라 `조회 상한`(애초에 안 봤다) 이어야 한다.
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" CLAIM_TIME_MAX=1 \
  "$SUT" --repo ggqgga/Reclaim --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "CLAIM_TIME_MAX=1: exit 0" "$RC" 0
ck "CLAIM_TIME_MAX=1: 타임라인 조회 1건" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 1
has_sub "CLAIM_TIME_MAX=1: 상한 안의 #31 은 그대로 5분" "$tmp/out" \
  "연결 이슈 #31 는 needs-human 아님(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
has_sub "(b) CLAIM_TIME_MAX=1: 상한 밖(#32)은 '조회 상한' — '안 봤다'" "$tmp/out" \
  "연결 이슈 #32 는 needs-human 아님(agent:claimed 인데 경과 미상 — 조회 상한)"
no_sub "(b) 상한 밖 문구는 조회 실패 문구(확인 필요)와 섞이지 않는다" "$tmp/out" \
  "연결 이슈 #32 는 needs-human 아님(agent:claimed 인데 경과 미상 — 확인 필요)"
has_sub "CLAIM_TIME_MAX=1: 상한 초과 사유가 stderr 에" "$tmp/err" \
  "reclaim #32 claim 시각 조회 상한(1) 초과"
has_line "CLAIM_TIME_MAX=1: warn 은 여전히 5건" "$tmp/out" "  warn      5"
# (c) (#181) 무회귀 — 진짜 타임라인 조회 실패(#32, 기본 상한에서 실측)는 '조회 상한' 이
# 아니라 종전 문구 '확인 필요' 그대로다. 위 §(b) 블록에서 이미 확인했다(default 상한
# 20 에서 #32 는 조회는 됐지만 실패해 '확인 필요').
# 형식 오류는 조용한 기본값이 아니라 환경 실패(HANDOFF_GRACE_MIN·HOLD_NOTE_MAX 와 같은 규율)
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" CLAIM_TIME_MAX=스물 \
  "$SUT" --repo ggqgga/Reclaim --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "CLAIM_TIME_MAX 형식 오류: exit 1" "$RC" 1
has_sub "CLAIM_TIME_MAX 형식 오류: stdout 에도 사유" "$tmp/out" \
  "파이프라인 — 스냅샷 실패: CLAIM_TIME_MAX 형식 오류: 스물"

# 인계 전 창을 넓히면 셋 다 창 안 → warn 이 아니니 타임라인 조회도 0건(틱 비용).
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HANDOFF_GRACE_MIN=300 \
  "$SUT" --repo ggqgga/Reclaim --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "창 300분: exit 0" "$RC" 0
has_line "창 300분: reclaim warn 0" "$tmp/out" "  warn      0"
ck "창 300분: 타임라인 조회 0건" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 0

# ── ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1 ──────────
run --repo ggqgga/BodaT --repo ggqgga/BoDAC --repo ggqgga/issue-runner --since 24h
ck "부분 실패: exit 1" "$RC" 1
has_sub "부분 실패: bodac 만 실패 줄" "$tmp/out" "파이프라인 bodac — 조회 실패: 이슈 목록 — "
has_sub "부분 실패: bodat 블록은 정상" "$tmp/out" "파이프라인 bodat — 열림 20"
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
ck "--json: bodat 열림 20" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .open_total' < "$tmp/out")" 20
ck "--json: runner 승격 대기 7" \
  "$(jq '.repos[] | select(.repo_short=="runner") | .promotion_ahead' < "$tmp/out")" 7
ck "--json: bodat 승격 대기 null(release 없음)" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .promotion_ahead' < "$tmp/out")" null
ck "--json: dup_closed 배열에 dup PR 만" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.dup_closed[].number]' < "$tmp/out")" '[4791]'
ck "--json: failed 에는 dup PR 이 없다" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.failed[].number]' < "$tmp/out")" '[4792]'
ck "--json: 사람대기 holds + note_missing (#157)" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.human_wait[] | {n:.number, h:.holds, m:.note_missing}]' < "$tmp/out")" \
  '[{"n":4826,"h":[],"m":false},{"n":4825,"h":["ladder"],"m":false},{"n":4780,"h":["policy"],"m":false},{"n":4771,"h":["conflict"],"m":null},{"n":4770,"h":["conflict"],"m":true}]'
ck "--json: 인계 전 PR 은 구현중 항목에 handoff_pending" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.claimed[] | {n:.number, p:.pr, h:.handoff_pending}]' < "$tmp/out")" \
  '[{"n":4803,"p":4854,"h":true},{"n":4701,"p":null,"h":false}]'
ck "--json: 열림 합에 중복종료는 안 든다(창 교차 집계)" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .open_total' < "$tmp/out")" 20

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
# (#248) 큰 본문 페이로드(약 1.6MB)가 커맨드라인이 아니라 파일로 넘어간다 —
# `--argjson` 이면 ARG_MAX 에 걸려 이 레포 블록이 통째로 `집계 실패(jq)` 가 된다.
no_sub "(#248) 큰 body 페이로드가 ARG_MAX 로 집계 실패하지 않는다" "$tmp/out" \
  "파이프라인 big — 조회 실패"
has_sub "(#248) 큰 body 페이로드에서도 블록이 정상 렌더" "$tmp/out" "파이프라인 big — 열림 0"
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
has_sub "무시된 줄: 나머지 레포는 정상" "$tmp/out" "파이프라인 bodat — 열림 20"

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

# ⑫-b 코멘트 100건 상한 — 마커가 그 밖으로 밀렸을 수 있으니 `질문 없음` 으로 단정 못 한다
run --repo ggqgga/Capped --since 24h
ck "capped: exit 0" "$RC" 0
has_line "capped 사람대기 — 100건 상한은 미확인, 마커 있으면 조용, 0건이면 질문 없음" "$tmp/out" \
  "  사람대기  3  #12(대기, policy, 질문 없음) #11(대기, conflict) #10(대기, policy)"
has_sub "capped: 100건 상한은 warn 으로" "$tmp/out" \
  "    - 질문 유무 미확인 #10(capped) — 코멘트 100건 상한"
no_sub "capped: 마커가 상한 안에 있으면 미확인 아님" "$tmp/out" "질문 유무 미확인 #11"
ck "capped: warn 은 그 1건뿐" "$(grep -c '질문 유무 미확인' "$tmp/out")" 1

# ⑫-c HOLD_NOTE_MAX — 레포당 조회 상한. 넘는 후보는 묻지 않고 미확인으로 남는다.
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HOLD_NOTE_MAX=1 \
  "$SUT" --repo ggqgga/Capped --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "HOLD_NOTE_MAX=1: exit 0" "$RC" 0
ck "HOLD_NOTE_MAX=1: gh 조회는 1건뿐" "$(grep -c '^comments ' "$STUB_CALL_LOG")" 1
has_sub "HOLD_NOTE_MAX=1: 넘는 후보는 상한 초과 warn" "$tmp/out" \
  "    - 질문 유무 미확인 #11(capped) — 조회 상한(1) 초과"
has_sub "HOLD_NOTE_MAX=1: 상한 초과 warn 2건째" "$tmp/out" \
  "    - 질문 유무 미확인 #10(capped) — 조회 상한(1) 초과"
# 상한을 넘긴 건은 `질문 없음` 으로 찍히지 않는다 — 안 물어본 걸 단정하지 않는다
no_sub "HOLD_NOTE_MAX=1: 안 물어본 건을 질문 없음 으로 찍지 않는다" "$tmp/out" "#11(대기, conflict, 질문 없음)"
# 형식 오류는 조용한 기본값이 아니라 환경 실패(HANDOFF_GRACE_MIN 과 같은 규율)
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HOLD_NOTE_MAX=50건 \
  "$SUT" --repo ggqgga/Capped --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "HOLD_NOTE_MAX 형식 오류: exit 1" "$RC" 1
has_sub "HOLD_NOTE_MAX 형식 오류: stdout 에도 사유" "$tmp/out" "HOLD_NOTE_MAX 형식 오류"

# ⑫-d (#160) 마커 판정은 **지금 붙은 사유**를 가린다 — 낡은 사유의 마커는 질문이 아니다
# 홀드가 풀려도 코멘트는 남으므로(라벨만 떨어진다) 사유를 안 가리면 예전 `policy` 질문이
# 지금의 `conflict` 홀드를 가려, 질문 없는 홀드가 조용히 방치된다.
run --repo ggqgga/Stale --since 24h
ck "stale marker: exit 0" "$RC" 0
has_line "낡은 사유의 마커는 질문으로 세지 않는다(양방향) · 같은 사유는 종전대로" "$tmp/out" \
  "  사람대기  5  #24(대기, conflict, 질문 없음) #23(대기, conflict) #22(대기, policy) #21(대기, conflict, policy) #20(대기, policy, 질문 없음)"
# 사유가 갈리는 자리를 부분 문자열로도 못 박는다 — 줄 전체 비교가 다른 이유로 깨져도
# 무엇이 틀렸는지 보이게.
has_sub "conflict 홀드 + 낡은 policy 마커 → 질문 없음" "$tmp/out" "#24(대기, conflict, 질문 없음)"
has_sub "policy 홀드 + 낡은 conflict 마커 → 질문 없음" "$tmp/out" "#20(대기, policy, 질문 없음)"
no_sub "회귀: conflict 홀드 + conflict 마커는 종전대로 조용" "$tmp/out" "#23(대기, conflict, 질문 없음)"
no_sub "회귀: policy 홀드 + policy 마커는 종전대로 조용" "$tmp/out" "#22(대기, policy, 질문 없음)"
no_sub "두 사유 홀드는 어느 쪽 마커든 질문 있음" "$tmp/out" "#21(대기, conflict, policy, 질문 없음)"
ck "stale marker: 후보 5건에 각 1회씩만 묻는다" "$(grep -c '^comments ' "$STUB_CALL_LOG")" 5
ck "stale marker: --json note_missing 도 사유를 가린다" \
  "$(STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" "$SUT" --repo ggqgga/Stale --since 24h --json \
     | jq -c '[.repos[0].buckets.human_wait[] | {n:.number, h:.holds, m:.note_missing}]')" \
  '[{"n":24,"h":["conflict"],"m":true},{"n":23,"h":["conflict"],"m":false},{"n":22,"h":["policy"],"m":false},{"n":21,"h":["conflict","policy"],"m":false},{"n":20,"h":["policy"],"m":true}]'
ck "stale marker: warn 0(사유 있는 홀드뿐)" "$(grep -c '질문 유무 미확인' "$tmp/out")" 0

# ── ⑭ (#248) 대기/막힘 — 블로커가 열려 있으면 `대기` 가 아니라 `막힘` ────────
run --repo ggqgga/Blockers --since 24h
ck "blockers: exit 0" "$RC" 0
has_line "blockers 헤더 — 열림 18(막힘은 대기에서 옮겨 온 것이라 총합 불변)" "$tmp/out" \
  "파이프라인 blockers — 열림 18 · 스코프 blockers · 창 24h"
# ③⑥ 과잉 포획 반증이 사는 자리 — 닫힌 블로커(#12)·산문(#15)·라벨 접미가 숫자 아님(#18)
# ·앵커 앞 낱말(#21)·구분자 없음(#22)은 전부 `대기` 로 남는다.
has_line "① 대기 6 — 블로커가 없거나 이미 해제된 것만" "$tmp/out" \
  "  대기      6  #902 #22 #21 #18 #15 #12"
has_line "② 막힘 8 — 항목마다 블로커와 그 버킷(PR 이면 PR #n)" "$tmp/out" \
  "  막힘      8  #20 ← #902(대기) #19 ← #901(구현중) #17 ← #903(배포대기) #16 ← #900(사람대기) #14 ← #902(대기) #13 ← PR #950 #11 ← #901(구현중) #10 ← #900(사람대기)"
# 다른 버킷은 블로커와 무관하게 그대로 — 막힘은 `대기` 판정을 통과한 것에서만 갈린다
has_line "⑨ 구현중 이슈는 블로커가 있어도 구현중 그대로" "$tmp/out" "  구현중    2  #901 #23"
has_line "blockers 사람대기 1" "$tmp/out" "  사람대기  1  #900(대기, ladder)"
has_line "blockers 배포대기 1" "$tmp/out" "  배포대기  1  #903"
# 개별 반례를 부분 문자열로도 못 박는다 — 줄 전체 비교가 다른 이유로 깨져도 무엇이
# 틀렸는지 보이게(과잉 포획은 `막힘` 줄에 그 번호가 나타나는 것으로 드러난다).
no_sub "③ 닫힌 블로커(#999)는 대기 유지 — 막힘으로 안 내려간다" "$tmp/out" "#12 ← "
no_sub "⑥ 산문 속 blocked by 는 블로커 아님" "$tmp/out" "#15 ← "
no_sub "숫자 아닌 라벨 접미(blocked-by:abc)는 블로커 아님" "$tmp/out" "#18 ← "
no_sub "앵커: 앞에 낱말이 있는 줄은 블로커 아님" "$tmp/out" "#21 ← "
no_sub "구분자 없는 blockedby 는 블로커 아님" "$tmp/out" "#22 ← "
no_sub "같은 줄 뒤쪽 언급(#902)은 #19 의 블로커가 아니다" "$tmp/out" "#19 ← #901(구현중) #902"
# ⑧ warn 은 **블로커 기준으로 묶는다** — 하위가 둘이어도 한 줄, 하위 번호는 내림차순.
has_line "blockers warn 2건(사람 게이트 블로커만)" "$tmp/out" "  warn      2"
has_sub "⑧ 블로커 사람대기 — 하위 둘이 한 줄로 묶이고 내림차순" "$tmp/out" \
  "    - 블로커 사람대기 #900(blockers) — 하위 #16 #10 정체"
has_sub "배포대기 블로커도 같은 규칙(사람 게이트)" "$tmp/out" \
  "    - 블로커 배포대기 #903(blockers) — 하위 #17 정체"
# 구현중·검증대기 블로커는 루프가 처리 중이라 warn 이 아니다
no_sub "구현중 블로커(#901)는 warn 아님" "$tmp/out" "블로커 구현중"
no_sub "대기 블로커(#902)는 warn 아님" "$tmp/out" "블로커 대기"
no_sub "PR 블로커는 warn 아님" "$tmp/out" "블로커 #950"
# 구현중 버킷의 #23 은 막힘이 아니므로 #900 warn 의 하위에도 안 들어간다
no_sub "막힘이 아닌 이슈는 warn 하위에 안 섞인다" "$tmp/out" "하위 #23"
# 추가 gh 호출 0 — 블로커 상태는 이미 받은 목록 안에서만 판정한다(개별 view 금지)
ck "(#248) 블로커 판정에 개별 issue view 를 쓰지 않는다" \
  "$(grep -c '^comments ' "$STUB_CALL_LOG")" 0
ck "(#248) 타임라인 조회도 없다" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 0

# ⑦ --json — blocked[] 항목은 기존 item 필드 + blockers[{n,state,bucket}]
run --repo ggqgga/Blockers --since 24h --json
ck "⑦ --json: blocked[].blockers 형태" \
  "$(jq -c '[.repos[0].buckets.blocked[] | {n:.number, b:.blockers}]' < "$tmp/out")" \
  '[{"n":20,"b":[{"n":902,"state":"OPEN","bucket":"대기"}]},{"n":19,"b":[{"n":901,"state":"OPEN","bucket":"구현중"}]},{"n":17,"b":[{"n":903,"state":"OPEN","bucket":"배포대기"}]},{"n":16,"b":[{"n":900,"state":"OPEN","bucket":"사람대기"}]},{"n":14,"b":[{"n":902,"state":"OPEN","bucket":"대기"}]},{"n":13,"b":[{"n":950,"state":"OPEN PR","bucket":null}]},{"n":11,"b":[{"n":901,"state":"OPEN","bucket":"구현중"}]},{"n":10,"b":[{"n":900,"state":"OPEN","bucket":"사람대기"}]}]'
ck "⑦ --json: blocked 항목에도 repo_short·label" \
  "$(jq -c '[.repos[0].buckets.blocked[] | select(.repo_short=="blockers")] | length' < "$tmp/out")" 8
ck "⑦ --json: open_total 에 blocked 가 든다" \
  "$(jq '.repos[0].open_total' < "$tmp/out")" 18
ck "⑦ --json: waiting 에는 막힘이 안 남는다" \
  "$(jq -c '[.repos[0].buckets.waiting[].number]' < "$tmp/out")" '[902,22,21,18,15,12]'
ck "⑦ --json: warn kind 는 blocker_human_wait" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="blocker_human_wait") | {b:.blocker, k:.bucket, i:.issues}]' < "$tmp/out")" \
  '[{"b":903,"k":"배포대기","i":[17]},{"b":900,"k":"사람대기","i":[16,10]}]'

# ── ③-b (#265) 정지 라벨 미러 불일치 — 4격자 ───────────────────────────────
# 픽스처는 **단계 라벨(flow:verify)을 이슈·PR 양쪽에 깔아** 단계 미러·무소속·좌초형 warn 을
# 전부 끈 상태다 — 그래서 `warn 2` 가 곧 "새 판정이 낸 줄이 정확히 둘" 이라는 실측이고,
# 나머지 두 칸이 조용하다는 것이 오탐 0 의 증거다(격자를 딴 warn 이 가리지 않는다).
#
#   이슈 정지 / PR 정지   want
#   ───────────────────   ───────────────────────────────────────────────
#   #10 無 / PR #110 無   warn 없음 (둘 다 없음 = 일치)
#   #20 無 / PR #120 有   **warn** — 사람이 이슈에서만 뗀 잔재(이 이슈가 잡으려는 상태)
#   #30 有 / PR #130 有   warn 없음 (둘 다 있음 = 일치, 살아 있는 사람 게이트)
#   #40 有 / PR #140 無   warn 없음 — **부착 방향**은 이 축 밖(#244)이고 루프에 교정
#                          수단이 없다(#190: warn 은 루프가 교정 가능한 위반일 때만)
#   #50 無 / PR #150 有   **warn** — `hold:*` 만 남아도(needs-human 없이) 성립해야 한다
#                          (#244 가 needs-human 을 기계 정지에서 빼는 날의 대비)
#   (이슈 미연결) PR #160 warn 없음 — 대조할 이슈가 없다(transition.sh 의 `issue=-` 홀드)
#   #70 無 / PR #170 有   warn 없음 — head 가 `feat/*`(사람 세션 PR). 사람이 직접 붙였을 수
#                          있어 루프가 뗄 것이 아니다 → 교정 못 하니 warn 도 아니다(#188)
#   #80 無 / PR #180 有   warn 없음 — head 는 `agent/issue-80` 인데 `closingIssuesReferences`
#                          가 비었다(`Refs #N` 전용). 짝이 **증명되지 않았으므로** 대상 밖 —
#                          그 PR 의 홀드는 `issue=-` 로 붙은 정상 상태일 수 있다
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Mirror.issues.json" <<'FX'
[
 {"number":10,"title":"둘 다 정지 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":20,"title":"PR 에만 정지 라벨이 남았다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":30,"title":"양쪽 다 정지","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":40,"title":"이슈에만 정지","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":50,"title":"PR 에 hold 만 남았다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":70,"title":"사람 세션 PR 이 달린 이슈","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":80,"title":"Refs 전용 PR 이 달린 이슈","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Mirror.pr_open.json" <<'FX'
[
 {"number":110,"headRefName":"agent/issue-10","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":10}],"labels":[{"name":"flow:verify"}]},
 {"number":120,"headRefName":"agent/issue-20","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":20}],"labels":[{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":130,"headRefName":"agent/issue-30","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":30}],"labels":[{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":140,"headRefName":"agent/issue-40","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":40}],"labels":[{"name":"flow:verify"}]},
 {"number":150,"headRefName":"agent/issue-50","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":50}],"labels":[{"name":"flow:verify"},{"name":"hold:conflict"}]},
 {"number":160,"headRefName":"feat/이슈-없는-정지","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[],"labels":[{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":170,"headRefName":"feat/사람이-연-정지","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":70}],"labels":[{"name":"flow:verify"},{"name":"needs-human"}]},
 {"number":180,"headRefName":"agent/issue-80","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Mirror.pr_closed.json"

run --repo ggqgga/Mirror --since 24h
ck "(#265) 격자: exit 0" "$RC" 0
has_line "(#265) 새 판정이 낸 줄은 정확히 2건(오탐 0)" "$tmp/out" "  warn      2"
has_line "(#265) PR 에만 정지 라벨 → warn" "$tmp/out" \
  "    - 정지 미러 불일치 #20(mirror) ↔ PR #120(mirror) — 이슈 없음 · PR hold:policy needs-human"
has_line "(#265) needs-human 없이 hold:* 만 남아도 warn (#244 대비)" "$tmp/out" \
  "    - 정지 미러 불일치 #50(mirror) ↔ PR #150(mirror) — 이슈 없음 · PR hold:conflict"
no_sub "(#265) 둘 다 없음(#10)은 조용하다" "$tmp/out" "정지 미러 불일치 #10"
no_sub "(#265) 둘 다 있음(#30)은 조용하다 — 살아 있는 사람 게이트" "$tmp/out" "정지 미러 불일치 #30"
no_sub "(#265) 이슈에만 있음(#40)은 이 축 밖(#244)" "$tmp/out" "정지 미러 불일치 #40"
no_sub "(#265) 연결 이슈 없는 held PR #160 은 대조 상대가 없다" "$tmp/out" "PR #160"
# 짝짓기는 교정 갈래(resume-sweep ④)와 같은 규칙으로 좁힌다 — 경보가 교정보다 넓으면
# "고쳐 준다" 고 말해 놓고 안 고치는 줄이 상시로 남는다.
no_sub "(#265) 사람 세션 PR #170 은 루프가 뗄 것이 아니라 warn 도 아니다" "$tmp/out" "↔ PR #170"
no_sub "(#265) Refs 전용(closes 링크 없음) PR #180 은 짝이 증명 안 됐다" "$tmp/out" "↔ PR #180"
# 단계 미러 판정은 정지 라벨에 오염되지 않는다 — 정지 라벨을 mirror_labels 에 밀어 넣었다면
# #20·#50 이 **단계** 미러 불일치로도 울렸을 자리다(별도 판정이라는 것의 실측).
no_sub "(#265) 정지 라벨이 단계 미러 판정을 깨뜨리지 않는다" "$tmp/out" "- 미러 불일치 #20"
no_sub "(#265) 정지 라벨이 단계 미러 판정을 깨뜨리지 않는다(#50)" "$tmp/out" "- 미러 불일치 #50"
# `--json` 면에도 같은 사실이 실린다(후속 도구가 문자열 파싱을 안 하게)
run --repo ggqgga/Mirror --since 24h --json
ck "(#265) --json: kind·issue·pr·labels" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="hold_mirror_mismatch") | {i:.issue, p:.pr, l:.labels}]' < "$tmp/out")" \
  '[{"i":20,"p":120,"l":["hold:policy","needs-human"]},{"i":50,"p":150,"l":["hold:conflict"]}]'

# ── --post 대시보드(#163) ──────────────────────────────────────────────────
fx="$tmp/fx/ggqgga_issue-runner"
rm -f "$fx.dash.num" "$fx.dash.body" "$fx.dash.comments.json"
run --repo ggqgga/issue-runner --post issue-runner --delta "정리 1 · 보수 0 · 신규 2 · 대기(사람 리뷰) 0 · warn 1"
check "post: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "post: 없으면 생성+pin" "$(grep -q 'dash-create' "$STUB_CALL_LOG" && grep -q 'dash-pin ggqgga/issue-runner 900' "$STUB_CALL_LOG" && echo ok || echo no)"
check "post: 본문 마커 첫 줄" "$(head -1 "$fx.dash.body" | grep -q '<!-- loop-dashboard -->' && echo ok || echo no)"
check "post: 본문엔 루프별 틱 줄 없음(코멘트로 이동)" "$(grep -q '^- issue-runner:' "$fx.dash.body" && echo no || echo ok)"
check "post: 스냅샷 블록 포함" "$(grep -q '^파이프라인 runner' "$fx.dash.body" && echo ok || echo no)"
check "post: 틱 코멘트 생성(마커+델타)" "$(jq -e '.[] | select(.body | contains("<!-- loop-tick: issue-runner -->") and contains("정리 1 · 보수 0"))' "$fx.dash.comments.json" >/dev/null && echo ok || echo no)"
check "post: stdout 에도 블록" "$(grep -q '^파이프라인 runner' "$tmp/out" && grep -q '^대시보드: runner #900' "$tmp/out" && echo ok || echo no)"
# 같은 루프 2회차 → 자기 코멘트 PATCH(새 코멘트 없음)
run --repo ggqgga/issue-runner --post issue-runner --delta "정리 0 · 보수 1"
check "post 2회차: 생성 안 함" "$(grep -q 'dash-create' "$STUB_CALL_LOG" && echo no || echo ok)"
check "post 2회차: 코멘트 PATCH" "$(grep -q 'dash-comment-patch ggqgga/issue-runner 1000' "$STUB_CALL_LOG" && ! grep -q 'dash-comment-create' "$STUB_CALL_LOG" && echo ok || echo no)"
check "post 2회차: 코멘트 1개 유지·델타 갱신" "$([ "$(jq 'length' "$fx.dash.comments.json")" = 1 ] && jq -e '.[0].body | contains("정리 0 · 보수 1")' "$fx.dash.comments.json" >/dev/null && echo ok || echo no)"
# 다른 루프 → 자기 코멘트 새로 생성, issue-runner 코멘트는 그대로
run --repo ggqgga/issue-runner --post verify-runner --delta "검증통과 1 · 재디스패치 0"
check "post 타 루프: 코멘트 2개" "$([ "$(jq 'length' "$fx.dash.comments.json")" = 2 ] && echo ok || echo no)"
check "post 타 루프: issue-runner 코멘트 보존" "$(jq -e '.[0].body | contains("loop-tick: issue-runner") and contains("정리 0 · 보수 1")' "$fx.dash.comments.json" >/dev/null && echo ok || echo no)"
# 마커 없는 본문은 덮어쓰지 않는다(사람 이슈 보호)
printf '사람이 쓴 이슈\n' > "$fx.dash.body"
run --repo ggqgga/issue-runner --post closeout
check "post 마커 없음: exit 1" "$([ "$RC" = 1 ] && echo ok || echo no)"
check "post 마커 없음: edit 안 함" "$(grep -q 'dash-edit' "$STUB_CALL_LOG" && echo no || echo ok)"
check "post 마커 없음: 본문 그대로" "$(grep -q '^사람이 쓴 이슈' "$fx.dash.body" && echo ok || echo no)"
# 인자 검증
run --repo ggqgga/issue-runner --post bogus;            check "post 잘못된 루프명: 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
run --repo ggqgga/issue-runner --post closeout --json;  check "post+json: 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
run --repo ggqgga/issue-runner --delta "x";             check "delta 만: 64" "$([ "$RC" = 64 ] && echo ok || echo no)"
rm -f "$fx.dash.num" "$fx.dash.body" "$fx.dash.comments.json"

echo "loop-status: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
