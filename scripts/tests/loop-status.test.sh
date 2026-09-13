#!/usr/bin/env bash
# loop-status.sh 픽스처 테스트 (#144) — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# 가드하는 것:
#   ① 버킷 9개(#276: 대기·issue-runner·검증대기·verify-runner·마감대기·closeout·보류·
#      needs-human·배포대기 — "누가 들고 있나" 로 이름 짓는다)가 정확히 나뉜다 — 한 이슈는
#      한 버킷, 우선순위(needs-human > 테스트 > 배포대기 > 보류 > 사다리 가장 뒤 단계 > 막힘 > 대기 —
#      BoDAT #5197: 테스트 버킷 신설 · needs-human 최우선).
#   ② 실패·파생의 `--since` 창 필터 — 창 밖 1건씩은 빠진다.
#   ③ warn 5종 검출(미러 불일치는 양방향 — 이슈에만 단계 / PR 에만 단계)과,
#      깨끗한 픽스처면 `warn 0`. 무소속 PR warn 은 **단계 라벨이 정말 하나도 없는** 열린 agent
#      PR 만이다(#282 — 반송 PR 의 `flow:agent-ready`·issue-runner 칸 PR 의 `flow:claimed` 도 단계
#      라벨). 미러 불일치는 **6쌍**(이슈 `agent-ready` 만 ↔ PR `flow:agent-ready` · `agent:claimed` ↔
#      `flow:claimed` · 뒤 네 칸은 같은 이름)으로 대조하되 워커 칸 두 쌍은 PR 이 그 라벨을 달고
#      이슈가 정지 중이 아닐 때만 — 그 격자는 ⑰.
#   ③-b (#265) **정지** 라벨(needs-human·hold:*) 미러 불일치 — 단계 미러와 **별도 판정**이다
#      (단계 배열에 섞으면 정지 라벨이 단계 일치 판정을 깨뜨린다). 해제 방향만 warn:
#      이슈에 정지 라벨이 0개인데 연결된 **열린** PR 에 남은 칸. 4격자로 오탐 0 을 단언한다.
#   ④ 레포 짧은 이름 — issue-runner → runner 특례.
#   ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1.
#   ⑥ `--json` 의 모든 항목·warn 에 `repo_short`.
#   ⑦ `.loop/repos` 의 `#` 주석·빈 줄 무시 + 형식 아닌 줄은 stderr 로 알린다.
#   ⑧ 조용한 실패 6종(보조 리뷰) — 깨진 JSON 집계 실패 · compare 실패 degrade ·
#      목록 상한 warn · 제목 폴백의 사다리 게이트 · `--since 0h` · repos 파일 부재 메시지.
#   ⑨ (#147 T3) needs-human 사유 병기 — `hold:*` 3종(ladder·policy·conflict) 표기와,
#      `hold:*` 없는 건의 `사유 없음` + warn. 배포대기가 이긴 needs-human 은 warn 밖.
#   ⑩ (#147 T3) 인계 전 창 — `HANDOFF_GRACE_MIN`(기본 90) 안의 **issue-runner 버킷** PR 은
#      무소속 warn 대신 issue-runner 줄에 `← PR #n(인계 전)`, 창 밖이면 warn + 사망 의심.
#      env 로 창을 넓히면 창 밖이던 PR 이 넘어온다(창이 실제로 동작한다는 대조군).
#      판정축이 `agent:claimed` **라벨**이면 라벨을 단 채 배포대기로 간 이슈의 PR 이
#      warn 에서만 빠져 어디에도 안 그려진다 — 그 조합(#4790/PR #4856)이 대조군.
#   ⑪ (#147 T3) 실패 ⊎ 중복종료 — PR 라벨 `dup` 이 둘을 가르고 겹쳐 세지 않는다.
#   ⑫ (#157) 질문 없는 홀드 — `hold:policy|conflict` 인데 `hold-note` 코멘트가 없으면
#      needs-human 줄에 `질문 없음`. 조회는 그 조건의 이슈에만(다른 버킷·`hold:ladder`·
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
#   ⑮ (#292) 에픽 닫힌 leaf 의 **창** — "최근 닫힌 200건" 이 아니라 검색 스코프 조회
#      (`--state closed --search '"Epic #" in:body'`)에서 온다. 창 밖 leaf 픽스처
#      (EpicWindow)가 `#100 2/3`·`#200 2/2`+`전부 종료` warn 을 문다 — 옛 경로로 되돌리면
#      각각 `0/1`·`leaf 없음(Epic 줄 미부착)`+warn 0 이 되어 빨개진다(뮤테이션).
#      **조회 실패는 빈 결과가 아니다** — ⑴ 종료코드 실패 ⑵ 빈 출력+exit 0(검색 2차 제한의
#      실제 모양, core API 목록과 교차확인) ⑶ 배열 아닌 응답, 세 갈래 모두 `종료 미상` +
#      warn 이고 `0/N` 으로 접히지 않는다. 상한 도달(EPIC_CLOSED_LIMIT)은 실패가 아니라
#      절단 warn 이고, 열린 에픽이 0건인 레포는 이 조회를 **아예 안 한다**(호출 로그로 단언).
#   ⑯ (#276) verify-runner 칸 — `verifying`(#275) 이 사다리의 `flow:verify` 와 `flow:ready` 사이에
#      끼어 버킷·중복·미러·무소속·에픽 접기 전부에 그 자리로 참여한다. 정상·중복·미러 불일치
#      3건 + 뒤 단계 우선·대조군·leaf 접기. `--json` 키는 종전 그대로 + `verifying` 하나.
#   ⑰ (#282) PR 미러 6쌍 · 대기/issue-runner 줄 PR 첨부 — `flow:agent-ready` PR 은 대기 줄에,
#      `flow:claimed` PR 은 창과 무관하게 issue-runner 줄에 `← PR #n`(이슈 칸과 일치할 때만 ·
#      `--json` 의 `waiting[].pr`·`claimed[].pr`). 불일치는 양방향 `미러 불일치`(이슈 대기 칸 + PR `flow:claimed` 는 재claim 대기
#      모양이라 예외 — 대기 줄에 붙는다). 라벨 0 PR 은 종전 인계 전 창 규칙 그대로(대조군). 정지 중(runner-held·verify-held 모양)은 조용.
#      `flow:claimed` PR 의 사망 의심은 **경과 기준의 별도 warn**(`워커 사망 의심`) — PR 나이로
#      후보를 고르고 claim 경과로 판정하므로 재디스패치(PR 240분·claim 5분)는 뜨지 않고, 창 안
#      PR 은 타임라인을 조회하지 않는다(호출 로그로 단언).
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
      # 에픽 스윕 마커 조회 (#441) — `pr-comments.sh` 는 `--paginate` + `--jq` 로 온다(대시보드
      # 코멘트 조회는 둘 다 없다). 스텁은 **원본 코멘트 배열**을 들고 SUT 가 넘긴 --jq 를 그대로
      # 적용한다 — 필터를 흉내 내면 헬퍼 계약이 틀려도 통과한다(timeline 스텁과 같은 규율).
      case "$args" in *--paginate*)
        num=$(printf '%s' "$path" | sed -n 's|.*/issues/\([0-9][0-9]*\)/comments.*|\1|p')
        printf 'epic-marker %s %s\n' "$repo" "$num" >> "$STUB_CALL_LOG"
        if [ -f "$f.epic_comments.$num.fail" ]; then echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; fi
        jqf=""; prev=""
        for a in "$@"; do case "$prev" in --jq|-q) jqf="$a";; esac; prev="$a"; done
        if [ -z "$jqf" ]; then echo "gh stub: 코멘트 전량 조회는 --jq 로 불러야 한다: $args" >&2; exit 1; fi
        if [ -f "$f.epic_comments.$num.json" ]; then jq -c "$jqf" "$f.epic_comments.$num.json" || exit 1; fi
        exit 0 ;;
      esac
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
  # needs-human 버킷의 hold:policy|conflict 이슈만 오는 질문(hold-note) 코멘트 조회 (#157).
  # 호출 자체를 로그에 남긴다 — "needs-human 버킷에만 묻는다" 를 실측으로 못 박기 위해서.
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
    # 에픽 닫힌 leaf 조회(#292) — 검색 스코프. 닫힌 이슈 목록보다 **먼저** 가른다
    # (둘 다 `--state closed` 라 순서가 바뀌면 검색 호출이 최근-200 픽스처를 받는다).
    # 호출을 로그에 남긴다 — "열린 에픽이 없으면 안 부른다" 를 실측으로 못 박기 위해서.
    case "$args" in *"--search"*)
      printf 'epic-closed %s\n' "$repo" >> "$STUB_CALL_LOG"
      case "$args" in
        *'--search "Epic #" in:body'*) ;;
        *) echo "gh stub: 에픽 닫힌 leaf 조회의 쿼리가 예상 밖: $args" >&2; exit 1 ;;
      esac
      case "$args" in
        *"--state closed"*) ;;
        *) echo "gh stub: 에픽 닫힌 leaf 조회는 --state closed 플래그로 와야 한다(#236): $args" >&2; exit 1 ;;
      esac
      # `--limit` 이 `EPIC_CLOSED_LIMIT` 로 실제로 전달되는지 (#292 사전 리뷰 WARN).
      # 안 재면 `--limit 200`(PR 이전 창)으로 되돌려도 스위트가 전건 초록이다 — 게다가
      # 200 은 기본 상한 1000 에 못 미쳐 `capped` 도 아니라서 **절단 warn 조차 안 뜬다**
      # (보이는 절단보다 나쁜 조용한 절단). 상한 판정은 env 를 그대로 읽어 이 회귀를 못 본다.
      # 양옆 공백을 함께 물어야 한다 — `--limit 2` 는 `--limit 200` 의 부분문자열이다.
      exp_limit="${EPIC_CLOSED_LIMIT:-1000}"
      case " $args " in
        *" --limit $exp_limit "*) ;;
        *) echo "gh stub: 에픽 닫힌 leaf 조회의 --limit 이 EPIC_CLOSED_LIMIT($exp_limit) 과 다르다: $args" >&2; exit 1 ;;
      esac
      if [ -f "$f.epic_closed.fail" ]; then echo "gh: HTTP 403 rate limit" >&2; exit 1; fi
      # 조용한 실패(빈 출력 + exit 0) 재현 — `gh` 검색 2차 제한의 실제 모양이다.
      if [ -f "$f.epic_closed.silent" ]; then echo '[]'; exit 0; fi
      if [ -f "$f.epic_closed.notarray" ]; then echo '{"message":"rate limited"}'; exit 0; fi
      if [ -f "$f.epic_closed.json" ]; then cat "$f.epic_closed.json"; else echo '[]'; fi
      exit 0 ;;
    esac
    # 닫힌 이슈 목록(#260, 색인 지연 보완·교차확인용) — 열린 이슈 호출과 파일을 가른다.
    case "$args" in *"--state closed"*) cat "$f.issues_closed.json"; exit 0 ;; esac
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
 {"number":4803,"title":"issue-runner 건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":4701,"title":"좌초건","createdAt":"@NOW@","labels":[{"name":"agent:claimed"}]},
 {"number":4810,"title":"검증대기건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":4500,"title":"배포 대기 (승격만) — 사다리가 이긴다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":4811,"title":"마감대기건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:ready"}]},
 {"number":4818,"title":"closeout 건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"harvesting"}]},
 {"number":4700,"title":"중복단계건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"harvesting"}]},
 {"number":4825,"title":"needs-human 대기자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":4770,"title":"needs-human issue-runner자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"agent:claimed"},{"name":"hold:conflict"}]},
 {"number":4780,"title":"needs-human 정책자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":4771,"title":"needs-human 코멘트 조회 실패자리","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:conflict"}]},
 {"number":4826,"title":"needs-human 사유 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"}]},
 {"number":4790,"title":"agent:claimed 인데 배포대기가 이긴 건","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"agent:claimed"},{"name":"deploy-wait"}]},
 {"number":4838,"title":"라벨로 배포대기","createdAt":"@NOW@","labels":[{"name":"deploy-wait"}]},
 {"number":4839,"title":"테스트: PR #4700 — 배포 뒤 검증 항목","createdAt":"@NOW@","labels":[{"name":"테스트"}]},
 {"number":4849,"title":"테스트인데 사람 조작도 남은 건","createdAt":"@NOW@","labels":[{"name":"테스트"},{"name":"needs-human"}]},
 {"number":4796,"title":"배포 대기: PR #4700 — 제목 폴백","createdAt":"@NOW@","labels":[]},
 {"number":4848,"title":"배포 검증: 화력 작전 — 제목 폴백 2형식","createdAt":"@NOW@","labels":[{"name":"needs-human"}]},
 {"number":4900,"title":"루프 밖 이슈","createdAt":"@NOW@","labels":[{"name":"enhancement"}]},
 {"number":4963,"title":"사람 세션이 직접 붙인 이슈","createdAt":"@NOW@","labels":[]},
 {"number":4964,"title":"무소속 회귀 대조 — agent 헤드는 종전대로 warn","createdAt":"@NOW@","labels":[]},
 {"number":4965,"title":"사람 세션 사이클 구현 이슈(full-cycle 부착)","createdAt":"@NOW@","labels":[{"name":"full-cycle"}]},
 {"number":4966,"title":"사람 세션 사이클 구현 이슈(이슈엔 라벨 없음)","createdAt":"@NOW@","labels":[]}
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
  "closingIssuesReferences":[],"labels":[]},
 {"number":4993,"headRefName":"agent/issue-4965","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4965}],"labels":[{"name":"full-cycle"}]},
 {"number":4994,"headRefName":"feat/full-cycle-4966","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":4966}],"labels":[{"name":"full-cycle"}]}
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
# 닫힌 이슈 목록(#260) — bodat 은 에픽을 쓰지 않는다(무회귀 픽스처, `Epic #N` 이 하나도
# 없다). `epic` 라벨 이슈가 없으니 파생 줄 병기도 트리거되지 않아야 한다(§무회귀).
echo '[]' > "$tmp/fx/ggqgga_BodaT.issues_closed.json"

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
# 셋 다 **issue-runner 버킷 + 인계 전 창 밖 PR**(4시간 전) 이라 사망 의심 꼬리표가 붙는 자리다.
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
echo '[]' > "$tmp/fx/ggqgga_Reclaim.issues_closed.json"
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
echo '[]' > "$tmp/fx/ggqgga_Capped.issues_closed.json"
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
echo '[]' > "$tmp/fx/ggqgga_Stale.issues_closed.json"
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

# ── 픽스처: ggqgga/Holds (holds) — 보류 칸 가르기 (#244) ────────────────────
# 기계 정지에서 `needs-human` 이 떨어진 뒤, `hold:*` 만 붙은 이슈가 `대기`(= 집을 수 있는
# 이슈)로 새면 needs-human 칸이 "손댈 게 없는 것" 으로 찼던 오류의 **반대 방향**이 된다.
#
#   번호  입력                                  want
#   ────  ───────────────────────────────────   ────────────────────────────────
#   #40   hold:ladder + agent-ready             보류 `#40(ladder)`  (재개 대기)
#   #41   hold:policy 단독                      보류 `#41(policy)`  (재심 전)
#   #42   hold:policy + needs-human             needs-human (재심이 "사람 몫 유지" 로 끝난 꼴)
#   #43   hold:conflict 단독                    보류 `#43(conflict, 0/1)` (#345 — 창 뒤 스윕이 1회 재개하는 기계 정지;
#                                               #346 — 재개 횟수/상한 병기 = `conflict-resume` 마커 수 / CONFLICT_RESUME_LIMIT)
#   #39   hold:conflict 단독 + 마커 1(+인용 1)  보류 `#39(conflict, 1/1)` (코드 인용 속 마커는 안 센다 — resume-sweep 의 JQ_UNQUOTE 와 같은 규율)
#   #38   hold:conflict 단독 + 코멘트 조회 실패  보류 `#38(conflict)` — 횟수 미상은 `0/1` 로 접지 않고 warn `재개 횟수 미확인`
#   #36   hold:conflict 단독 + 코멘트 100건      보류 `#36(conflict)` — 첫 100건 상한에 닿았으면 "적게 센 값" 이 아니라 모름
#   #35   hold:conflict + hold:policy            보류 `#35(conflict, policy)` — 횟수/상한 **없음**·코멘트 조회 **없음**(#346 반송:
#                                               resume-sweep 은 policy·ladder 동존이면 충돌 재개를 거부하므로 `0/1` 은 거짓 진행률)
#   #37   hold:conflict + needs-human           needs-human `#37(대기, conflict, 질문 없음)` (종전대로 — 횟수 아닌 질문 조회)
#   #49   hold:conflict + full-cycle            needs-human (사람이 인수한 충돌 — 스윕이 절대 재개 안 함)
#   #44   needs-human 단독                      needs-human `사유 없음` + note(정상 상태)
#   #45   agent-ready 만                        대기
#   #46   hold:ladder + flow:verify             보류 (우선순위: 보류 > 단계 라벨)
#   #47   agent-ready + Blocked by #45          막힘 (보류가 막힘으로 안 샌다는 대조군)
#   #48   hold:ladder + Blocked by #45          보류 (우선순위: 보류 > 막힘)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Holds.issues.json" <<'FX'
[
 {"number":40,"title":"사다리 재개 대기","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:ladder"}]},
 {"number":41,"title":"정책 재심 전","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:policy"}]},
 {"number":42,"title":"재심 유지 — 사람 몫 확정","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:policy"},{"name":"needs-human"}]},
 {"number":43,"title":"충돌 — 스윕이 재개하는 기계 정지","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"}]},
 {"number":39,"title":"충돌 — 이미 1회 재개됨(상한 도달)","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"}]},
 {"number":38,"title":"충돌 — 코멘트 조회 실패","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"}]},
 {"number":36,"title":"충돌 — 코멘트 100건 상한","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"}]},
 {"number":35,"title":"충돌 + 정책 동존 — 스윕이 재개 안 함","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"},{"name":"hold:policy"}]},
 {"number":37,"title":"충돌 + 사람이 세운 정지","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"},{"name":"needs-human"}]},
 {"number":49,"title":"충돌 — 사람이 full-cycle 로 인수","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"},{"name":"full-cycle"}]},
 {"number":44,"title":"사람이 직접 세운 정지","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"needs-human"}]},
 {"number":45,"title":"집을 수 있는 이슈","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"}]},
 {"number":46,"title":"단계 라벨보다 보류가 앞","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"hold:ladder"}]},
 {"number":47,"title":"막힘 대조군","createdAt":"@NOW@","body":"Blocked by #45","labels":[{"name":"agent-ready"}]},
 {"number":48,"title":"막힘보다 보류가 앞","createdAt":"@NOW@","body":"Blocked by #45","labels":[{"name":"agent-ready"},{"name":"hold:ladder"}]}
]
FX
# 무소속 PR warn 은 **정지 라벨**(needs-human ∪ hold:*)을 본다 (#244) — `needs-human` 만
# 보던 옛 술어에서는 홀드된 PR 과 홀드된 이슈의 PR 이 통째로 warn 으로 쏟아진다.
#   PR #70  연결 이슈가 보류(#40)          → warn 아님 (이슈 쪽 hold:*)
#   PR #71  연결 이슈가 대기(#45)          → 종전대로 warn (**과잉 제외 반증**)
#   PR #72  PR 자체에 hold:policy(#41)     → warn 아님 (PR 쪽 hold:*)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Holds.pr_open.json" <<'FX'
[
 {"number":70,"headRefName":"agent/issue-40","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":40}],"labels":[]},
 {"number":71,"headRefName":"agent/issue-45","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":45}],"labels":[]},
 {"number":72,"headRefName":"agent/issue-41","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":41}],"labels":[{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Holds.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_Holds.issues_closed.json"
# needs-human 버킷의 policy·conflict 에는 질문(hold-note)이 있어야 `질문 없음` 이 안 붙는다.
cat > "$tmp/fx/ggqgga_Holds.comments.42.json" <<'FX'
{"comments":[{"body":"사람 확인(policy): A인가 B인가\n<!-- hold-note: policy --><!-- bodat:worker -->"}]}
FX
cat > "$tmp/fx/ggqgga_Holds.comments.49.json" <<'FX'
{"comments":[{"body":"사람 확인(conflict): 충돌 #5114·client.rb — 워커 재개 범위: origin/main 위로 rebase\n<!-- hold-note: conflict --><!-- bodat:worker -->"}]}
FX
# 보류 칸의 conflict 는 **재개 횟수**를 같은 코멘트 조회로 센다(#346) — `<!-- conflict-resume: N -->`
# 마커를 품은 코멘트 수. 코드 인용(백틱·펜스) 속 마커는 마커가 아니다(resume-sweep 과 같은 unquoted).
cat > "$tmp/fx/ggqgga_Holds.comments.39.json" <<'FX'
{"comments":[{"body":"재개 안내: 마커는 `<!-- conflict-resume: 1 -->` 형식이다\n<!-- bodat:worker -->"},
             {"body":"충돌 재개 1/1 — 워커 한 회차 더\n<!-- conflict-resume: 1 -->\n<!-- bodat:worker -->"}]}
FX
: > "$tmp/fx/ggqgga_Holds.comments.38.fail"
# `--json comments` 는 첫 100건만 준다 — 100건이면 뒤가 잘렸을 수 있어 마커가 있어도 횟수는 모름.
jq -n '{comments: [range(100) | {body: "충돌 재개 — 워커 한 회차 더\n<!-- conflict-resume: 1 -->\n<!-- bodat:worker -->"}]}' \
  > "$tmp/fx/ggqgga_Holds.comments.36.json"

# ── 픽스처: ggqgga/Verifying (verifying) — verify-runner 점유 칸 (#276 · 라벨은 #275) ──
# `verifying` 은 verify-runner 가 **지금 들고 있는** 이슈다(집는 순간 flow:verify 를 떼고
# 붙인다). 사다리에서 `flow:verify` 와 `flow:ready` 사이라 우선순위·미러·중복 판정 전부에
# 그 자리로 끼어야 한다 — 어느 하나라도 빠지면 검증 중인 건이 `대기`(집을 수 있는 이슈)로
# 새거나 그 PR 이 무소속 warn 으로 울린다.
#
#   번호  입력                                       want
#   ────  ─────────────────────────────────────────  ────────────────────────────
#   #60   verifying + PR #160 verifying              verify-runner `#60 ← PR #160` · warn 없음(정상)
#   #61   flow:verify + verifying (+PR #161 verifying) verify-runner(가장 뒤 단계) + warn `단계 라벨 중복`
#   #62   verifying + PR #162 flow:verify            verify-runner + warn `미러 불일치 — 이슈 verifying · PR flow:verify`
#   #63   verifying + flow:ready (+PR #163 flow:ready) 마감대기(verifying 보다 flow:ready 가 뒤) + warn 중복
#   #64   flow:verify (+PR #164 flow:verify)         검증대기 — 회귀 대조군(verifying 없으면 종전 그대로)
#   #65   epic leaf(verifying)                       에픽 절 `진행` 로 접힌다(verifying 도 진행)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Verifying.issues.json" <<'FX'
[
 {"number":66,"title":"에픽 V","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":65,"title":"leaf — 검증 중","createdAt":"@NOW@","body":"Epic #66","labels":[{"name":"agent-ready"},{"name":"verifying"}]},
 {"number":64,"title":"검증대기 대조군","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":63,"title":"verifying + flow:ready — 뒤 단계가 이긴다","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"verifying"},{"name":"flow:ready"}]},
 {"number":62,"title":"미러 불일치 — PR 은 아직 flow:verify","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"verifying"}]},
 {"number":61,"title":"중복 — flow:verify 를 안 뗐다","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"verifying"}]},
 {"number":60,"title":"정상 — verify-runner 가 들고 있다","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"verifying"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Verifying.pr_open.json" <<'FX'
[
 {"number":160,"headRefName":"agent/issue-60","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":60}],"labels":[{"name":"verifying"}]},
 {"number":161,"headRefName":"agent/issue-61","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":61}],"labels":[{"name":"verifying"}]},
 {"number":162,"headRefName":"agent/issue-62","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":62}],"labels":[{"name":"flow:verify"}]},
 {"number":163,"headRefName":"agent/issue-63","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":63}],"labels":[{"name":"flow:ready"}]},
 {"number":164,"headRefName":"agent/issue-64","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":64}],"labels":[{"name":"flow:verify"}]},
 {"number":165,"headRefName":"agent/issue-65","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":65}],"labels":[{"name":"verifying"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Verifying.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_Verifying.issues_closed.json"

# ── 픽스처: ggqgga/Mirror6 (mirror6) — PR 미러 6쌍 · 대기/issue-runner 줄 PR 첨부 (#282) ──
# #281 이 PR 미러를 사다리 **전 칸**으로 넓혔다 — 이슈 `agent-ready` 만 ↔ PR `flow:agent-ready`,
# 이슈 `agent:claimed` ↔ PR `flow:claimed`. 대시보드는 그 두 쌍을 대조에 넣고, 대기·issue-runner
# 줄에도 연결 PR 을 그리며, 무소속 warn 은 **라벨이 정말 하나도 없는** PR 로 좁힌다.
#
#   번호  이슈 / PR                                        want
#   ────  ───────────────────────────────────────────────  ─────────────────────────────────────
#   #10   agent-ready 만 / PR #110 flow:agent-ready         대기 `#10 ← PR #110` · warn 0
#   #20   agent:claimed / PR #120 flow:claimed+flow:ci      issue-runner `#20 ← PR #120` · 무소속 warn 없음
#         (PR 200분 전 · claim 200분 전)                     · **사망 의심 warn 은 경과 기준으로 별도**(200분)
#   #21   agent:claimed / PR #121 flow:claimed              issue-runner `#21 ← PR #121` · warn 없음 —
#         (PR 240분 전 · claim 5분 전 = 재디스패치)           PR 나이가 아니라 claim 경과(#177)로 재니 살아 있다
#   #22   agent:claimed / PR #122 flow:claimed (PR 방금)    issue-runner `#22 ← PR #122` · 창 안 = 타임라인 조회 0
#   #30   flow:verify / PR #130 flow:claimed                warn `미러 불일치 — 이슈 flow:verify · PR flow:claimed`
#   #31   agent:claimed / PR #131 flow:verify               warn `미러 불일치 — 이슈 agent:claimed · PR flow:verify`(반대 방향)
#   #32   agent-ready 만 / PR #132 flow:claimed             대기 `#32 ← PR #132` · warn 0 — **재claim 대기** 모양(홀드 해제·claim
#                                                            회수 뒤 PR 의 flow:claimed 는 다음 claim 이 수렴시킨다, #281)
#   #60   agent:claimed / PR #160 flow:agent-ready          warn `미러 불일치 — 이슈 agent:claimed · PR flow:agent-ready` · 무소속 아님
#   #40   agent:claimed / PR #140 라벨 0 (PR 방금)          issue-runner `#40 ← PR #140(인계 전)` — 종전 창 규칙 그대로(대조군)
#   #41   agent:claimed / PR #141 라벨 0 (PR 200분 전)      무소속 warn + 사망 의심(200분) — 종전 그대로
#   #50   agent-ready+hold:ladder / PR #150 flow:claimed    warn 0 — runner-held 는 이슈 agent:claimed 만 떼고 PR 의
#                                                            flow:claimed 는 둔다(transition.sh) → 정지 중엔 워커 칸 대조 안 함
#   #51   agent-ready+hold:policy / PR #151 hold:policy     warn 0 — verify-held 뒤 모양(PR 단계 0 · 이슈 agent-ready 만)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Mirror6.issues.json" <<'FX'
[
 {"number":10,"title":"반송 뒤 대기 — PR 은 flow:agent-ready","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"}]},
 {"number":20,"title":"issue-runner 칸 — PR 은 flow:claimed, 창 밖","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":21,"title":"재디스패치 — PR 은 오래됐고 claim 은 방금","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":22,"title":"issue-runner 칸 — PR 방금","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":30,"title":"검증대기인데 PR 은 flow:claimed","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":31,"title":"issue-runner 칸인데 PR 은 flow:verify","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":32,"title":"대기인데 PR 은 flow:claimed","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"}]},
 {"number":60,"title":"issue-runner 칸인데 PR 은 아직 flow:agent-ready(claim 미러 실패)","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":40,"title":"라벨 0 PR — 인계 전 창 안(대조군)","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":41,"title":"라벨 0 PR — 인계 전 창 밖(대조군)","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":50,"title":"runner-held — PR 의 flow:claimed 는 남는다","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:ladder"}]},
 {"number":51,"title":"verify-held — PR 단계 0","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:policy"}]}
]
FX
sed "s/@NOW@/$NOW/g; s/@AGO200@/$AGO200/g; s/@AGO240@/$AGO240/g" > "$tmp/fx/ggqgga_Mirror6.pr_open.json" <<'FX'
[
 {"number":110,"headRefName":"agent/issue-10","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":10}],"labels":[{"name":"flow:agent-ready"}]},
 {"number":120,"headRefName":"agent/issue-20","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":20}],"labels":[{"name":"flow:claimed"},{"name":"flow:ci"}]},
 {"number":121,"headRefName":"agent/issue-21","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO240@",
  "closingIssuesReferences":[{"number":21}],"labels":[{"name":"flow:claimed"}]},
 {"number":122,"headRefName":"agent/issue-22","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":22}],"labels":[{"name":"flow:claimed"}]},
 {"number":130,"headRefName":"agent/issue-30","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":30}],"labels":[{"name":"flow:claimed"}]},
 {"number":131,"headRefName":"agent/issue-31","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":31}],"labels":[{"name":"flow:verify"}]},
 {"number":132,"headRefName":"agent/issue-32","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":32}],"labels":[{"name":"flow:claimed"}]},
 {"number":160,"headRefName":"agent/issue-60","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":60}],"labels":[{"name":"flow:agent-ready"}]},
 {"number":140,"headRefName":"agent/issue-40","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":40}],"labels":[]},
 {"number":141,"headRefName":"agent/issue-41","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":41}],"labels":[]},
 {"number":150,"headRefName":"agent/issue-50","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":50}],"labels":[{"name":"flow:claimed"},{"name":"hold:ladder"}]},
 {"number":151,"headRefName":"agent/issue-51","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@AGO200@",
  "closingIssuesReferences":[{"number":51}],"labels":[{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Mirror6.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_Mirror6.issues_closed.json"
# 타임라인 — #20·#41 은 claim 200분 전(정상 흐름), #21 은 PR 240분 전인데 claim 은 5분 전(재디스패치).
# #22 는 픽스처를 **두지 않는다** — 창 안 PR 은 조회 대상이 아니어야 하고, 조회하면 스텁이 exit 1 로 드러낸다.
for n in 20 41; do
  sed "s/@AGO200@/$AGO200/g" > "$tmp/fx/ggqgga_Mirror6.timeline.$n.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent-ready"},"created_at":"@AGO200@"},
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO200@"}
]
FX
done
sed "s/@AGO240@/$AGO240/g; s/@AGO5@/$AGO5/g" > "$tmp/fx/ggqgga_Mirror6.timeline.21.p1.json" <<'FX'
[
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO240@"},
 {"event":"unlabeled","label":{"name":"agent:claimed"},"created_at":"@AGO240@"},
 {"event":"labeled","label":{"name":"agent:claimed"},"created_at":"@AGO5@"}
]
FX

# ── 픽스처: ggqgga/Blockers (blockers) — 대기/막힘 가르기 (#248) ─────────────
# 블로커 파싱 규칙은 eligible-issues.sh 와 **같은 의미**여야 한다. 개별 반례만 막으면
# 근사가 '더 많이 잡는' 쪽으로 틀리고(정상 `대기` 가 `막힘` 으로 내려간다 — 원래 버그보다
# 나쁘다), 그래서 규칙을 통째로 옮긴 뒤 아래 격자로 **양방향**을 전수 단언한다.
#
#   번호  입력                                   want
#   ────  ─────────────────────────────────────  ────────────────────────────
#   #10   본문 2번째 줄에 `Blocked by #900`      막힘 ← #900(needs-human)  ← 줄 앞에 다른 줄이
#                                                있어도 잡힌다(줄 단위 앵커)
#   #11   라벨 `blocked-by:901`                  막힘 ← #901(issue-runner)
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
#   #23   issue-runner 버킷인데 본문에 블로커          issue-runner 그대로(막힘은 `대기` 에서만 갈린다)
#   #24   `Blocked by #904`(hold:conflict 단독)  막힘 ← #904(보류) → warn **없음**(#346 — 보류는 루프가 풀 것,
#                                                사람 게이트가 아니다; 블로커 warn 은 needs-human·테스트·배포대기만)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Blockers.issues.json" <<'FX'
[
 {"number":900,"title":"사람이 답해야 풀리는 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":901,"title":"루프가 처리 중인 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":902,"title":"대기 중인 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"}]},
 {"number":903,"title":"배포 게이트 블로커","createdAt":"@NOW@","body":"","labels":[{"name":"deploy-wait"}]},
 {"number":904,"title":"보류 블로커 — 충돌 재개 대기","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"hold:conflict"}]},
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
 {"number":23,"title":"issue-runner인데 블로커가 있다","createdAt":"@NOW@","body":"Blocked by #900","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":24,"title":"보류 블로커의 하위","createdAt":"@NOW@","body":"Blocked by #904","labels":[{"name":"agent-ready"}]}
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
echo '[]' > "$tmp/fx/ggqgga_Blockers.issues_closed.json"

# ── 픽스처: ggqgga/Epics (epics) — 에픽 절 (#260) ───────────────────────────
#   번호  구성                                        want
#   ────  ──────────────────────────────────────────  ────────────────────────
#   #100  leaf 열림 2(issue-runner·대기)+닫힘 1              `1/3 · 진행 1 · 대기 1`
#   #200  leaf 전부 닫힘(2/2)                          `2/2`, warn `닫아라`
#   #300  열린 leaf P1+P0+P2 · 닫힌 leaf 는 P0(무시)   `1/4 · 대기 3 · P0 1 P1 2`,
#                                                       warn `P 혼재 — P0 1 · P1 2`
#         (#401: 과도기의 `P2` 라벨은 `P1` 칸으로 접힌다 — 혼재는 P0 × P1 일 때만이다)
#   #400  leaf 참조 없음                               `leaf 없음(Epic 줄 미부착)`, warn 없음
#   #500  산문 속 `epic #100`(줄 시작 아님)             leaf 아님 — #100 총합에 안 낀다
#   #600  파생 + `Epic #999`(에픽 목록에 없어도 병기)  파생 줄 `(Epic #999)`
#   #601  파생 + 에픽 줄 없음                           파생 줄 `(에픽 없음)`
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Epics.issues.json" <<'FX'
[
 {"number":100,"title":"에픽 A","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":200,"title":"에픽 B — leaf 전부 종료","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":300,"title":"에픽 C — P 혼재","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":400,"title":"에픽 D — leaf 없음","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":101,"title":"leaf issue-runner","createdAt":"@NOW@","body":"Epic #100","labels":[{"name":"agent-ready"},{"name":"agent:claimed"}]},
 {"number":102,"title":"leaf 대기","createdAt":"@NOW@","body":"Epic #100","labels":[{"name":"agent-ready"}]},
 {"number":301,"title":"leaf P1","createdAt":"@NOW@","body":"Epic #300","labels":[{"name":"agent-ready"},{"name":"P1"}]},
 {"number":302,"title":"leaf P0","createdAt":"@NOW@","body":"Epic #300","labels":[{"name":"agent-ready"},{"name":"P0"}]},
 {"number":304,"title":"leaf P2(과도기 — P1 칸으로 접힌다)","createdAt":"@NOW@","body":"Epic #300","labels":[{"name":"agent-ready"},{"name":"P2"}]},
 {"number":500,"title":"산문 속 언급 — leaf 아님","createdAt":"@NOW@","body":"본문 첫 줄\n이 문서는 epic #100 이야기를 지나가며 한다","labels":[]},
 {"number":600,"title":"파생 + 에픽 있음","createdAt":"@NOW@","body":"Epic #999","labels":[{"name":"agent-ready"},{"name":"spinoff"}]},
 {"number":601,"title":"파생 + 에픽 없음","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"spinoff"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Epics.issues_closed.json" <<'FX'
[
 {"number":103,"body":"Epic #100","closedAt":"@NOW@","labels":[]},
 {"number":201,"body":"Epic #200","closedAt":"@NOW@","labels":[]},
 {"number":202,"body":"Epic #200","closedAt":"@NOW@","labels":[]},
 {"number":303,"body":"Epic #300","closedAt":"@NOW@","labels":[{"name":"P0"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Epics.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_Epics.pr_closed.json"

# ── 픽스처: ggqgga/EpicNoRefs (epicnorefs) — 에픽 라벨은 있지만 `Epic #N` 은 0건(사전 리뷰) ──
# `$has_epic_refs` 게이트가 "열린 에픽 라벨 이슈 존재" 가 아니라 "실제 `Epic #N` 텍스트
# 존재" 로 재는지 — leaf 0 인 에픽(#700)만 있고 그 무엇의 본문에도 `Epic #N` 이 없는
# 레포에서, 무관한 파생(#701)까지 `(에픽 없음)` 이 붙으면 안 된다(무회귀 기준 위반).
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicNoRefs.issues.json" <<'FX'
[
 {"number":700,"title":"에픽 E — leaf 없음","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":701,"title":"무관한 파생","createdAt":"@NOW@","body":"","labels":[{"name":"agent-ready"},{"name":"spinoff"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicNoRefs.issues_closed.json"
echo '[]' > "$tmp/fx/ggqgga_EpicNoRefs.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicNoRefs.pr_closed.json"

# ── (#292) 에픽 닫힌 leaf 는 "최근 200건" 이 아니라 **검색 스코프 조회**에서 온다 ──────
# Epics 레포는 회귀 대조군이다 — 검색 결과가 최근-200 목록과 같으면(합집합이 같은 집합)
# 출력이 #260 때와 **한 글자도** 달라지지 않아야 한다.
cp "$tmp/fx/ggqgga_Epics.issues_closed.json" "$tmp/fx/ggqgga_Epics.epic_closed.json"

# ── 픽스처: ggqgga/EpicWindow (epicwindow) — **창 밖 leaf** (#292 의 본체) ──────────
#   최근 닫힌 200건에는 무관한 #900 만 있다(에픽 줄 없음). 에픽 #100 의 닫힌 leaf 2건과
#   에픽 #200 의 닫힌 leaf 2건은 **검색 스코프 조회로만** 잡힌다.
#   want: `#100 2/3 · 대기 1` · `#200 2/2` + warn `에픽 leaf 전부 종료 #200`
#   옛 경로(최근 200건)로 되돌리면: `#100 0/1` · `#200 leaf 없음(Epic 줄 미부착)` + warn 0
#   — 그게 이 이슈가 신고한 두 실패 시나리오의 재현이다(뮤테이션 대상).
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicWindow.issues.json" <<'FX'
[
 {"number":100,"title":"오래 산 에픽 A","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":200,"title":"오래 산 에픽 B — leaf 전부 창 밖에서 종료","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":101,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #100","labels":[{"name":"agent-ready"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicWindow.issues_closed.json" <<'FX'
[
 {"number":900,"body":"에픽과 무관","closedAt":"@NOW@","labels":[]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicWindow.epic_closed.json" <<'FX'
[
 {"number":103,"body":"Epic #100","closedAt":"@NOW@","labels":[]},
 {"number":104,"body":"Epic #100","closedAt":"@NOW@","labels":[]},
 {"number":201,"body":"Epic #200","closedAt":"@NOW@","labels":[]},
 {"number":202,"body":"Epic #200","closedAt":"@NOW@","labels":[]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicWindow.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicWindow.pr_closed.json"

# ── 픽스처: ggqgga/EpicFail (epicfail) — 조회 **실패**는 "닫힌 leaf 0건" 이 아니다 ────
# PR#239 의 세 갈래 중 ⑴ 조회 실패. 에픽 #300 은 최근-200 에 닫힌 leaf(#302)가 있어
# 합집합 덕에 수치가 종전으로 degrade 하지만, 그래도 비율을 찍지 않는다(못 셌으므로).
# 에픽 #310 은 `전부 종료` warn 이 **실패 중에도 그대로 뜨는지**를 문다 — 그 판정은
# "열린 leaf 0 + 닫힌 leaf ≥1" 이고 조회 실패는 닫힌 leaf 를 적게만 셀 수 있어 거짓 음성
# 방향이다(뜨면 참). 헤더 ★에픽 절★ 이 이 조합을 명시한다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicFail.issues.json" <<'FX'
[
 {"number":300,"title":"에픽 F","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":310,"title":"에픽 G — 최근창 기준 전부 종료","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":301,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #300","labels":[{"name":"agent-ready"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicFail.issues_closed.json" <<'FX'
[
 {"number":302,"body":"Epic #300","closedAt":"@NOW@","labels":[]},
 {"number":311,"body":"Epic #310","closedAt":"@NOW@","labels":[]}
]
FX
: > "$tmp/fx/ggqgga_EpicFail.epic_closed.fail"
echo '[]' > "$tmp/fx/ggqgga_EpicFail.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicFail.pr_closed.json"

# ── 픽스처: ggqgga/EpicSilent (epicsilent) — **빈 출력 + exit 0** (조용한 실패) ───────
# PR#239 의 갈래 ⑵. `gh` 의 검색 2차 레이트리밋이 실제로 이 모양이고 `rate_limit` 은 그때도
# 초록이라 종료코드로는 안 걸린다. 교차확인은 **core API 목록**으로 한다 — 최근 닫힌 목록에
# `Epic #N` 줄(#402)이 있는데 검색이 0행이면 "닫힌 leaf 가 없다" 가 아니라 검색이 접힌 것이다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicSilent.issues.json" <<'FX'
[
 {"number":400,"title":"에픽 H","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":401,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #400","labels":[{"name":"agent-ready"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicSilent.issues_closed.json" <<'FX'
[
 {"number":402,"body":"Epic #400","closedAt":"@NOW@","labels":[]}
]
FX
: > "$tmp/fx/ggqgga_EpicSilent.epic_closed.silent"
echo '[]' > "$tmp/fx/ggqgga_EpicSilent.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicSilent.pr_closed.json"

# ── 픽스처: ggqgga/EpicBadJson (epicbadjson) — 배열이 아닌 응답 ────────────────────
# PR#239 의 갈래 ⑶ 조회 대상 오식별/형식 밖. `gh` 는 에러 JSON 을 stdout 으로 흘리는
# 전례가 있다(claim-issue.sh 와 같은 함정) — 그걸 `[]` 로 접으면 또 `0/N` 이다.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicBadJson.issues.json" <<'FX'
[
 {"number":450,"title":"에픽 I","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":451,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #450","labels":[{"name":"agent-ready"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicBadJson.issues_closed.json"
: > "$tmp/fx/ggqgga_EpicBadJson.epic_closed.notarray"
echo '[]' > "$tmp/fx/ggqgga_EpicBadJson.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicBadJson.pr_closed.json"

# ── 픽스처: ggqgga/EpicMark (epicmark) — 전부 종료 에픽의 **스윕 마커** 유무 (#441) ──────
# `<!-- epic-sweep -->` 마커가 있는데 열려 있는 에픽은 스윕이 한 번 닫았다가 되돌려진 것이라
# 스윕 대상이 아니다(epic-sweep.sh 마커 게이트 — note · 쓰기 0). 종전 문구 "닫아라(에픽 스윕
# 대상)" 는 그 에픽엔 거짓이었다 — 사람 몫이다. 셋을 한 픽스처에 둔다:
#   #10 마커 있음 → `사람 몫(스윕 되돌림)` · #11 마커 없음 → 종전 문구 그대로 ·
#   #12 코멘트 조회 실패 → 어느 쪽이라고 단정하지 않는다(미확인).
# 마커 조회는 **전부 종료 warn 후보에만** 건다 — #13 은 열린 leaf 가 있어 조회 0.
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicMark.issues.json" <<'FX'
[
 {"number":10,"title":"되돌려진 에픽","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":11,"title":"스윕이 닫을 에픽","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":12,"title":"마커 미확인 에픽","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":13,"title":"진행 중 에픽","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":14,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #13","labels":[{"name":"agent-ready"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicMark.issues_closed.json" <<'FX'
[
 {"number":101,"body":"Epic #10","closedAt":"@NOW@","labels":[]},
 {"number":111,"body":"Epic #11","closedAt":"@NOW@","labels":[]},
 {"number":121,"body":"Epic #12","closedAt":"@NOW@","labels":[]}
]
FX
cp "$tmp/fx/ggqgga_EpicMark.issues_closed.json" "$tmp/fx/ggqgga_EpicMark.epic_closed.json"
echo '[]' > "$tmp/fx/ggqgga_EpicMark.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicMark.pr_closed.json"
# REST `issues/{n}/comments` 원본 모양(body·created_at) — pr-comments.sh 의 --jq 가 이걸 먹는다.
cat > "$tmp/fx/ggqgga_EpicMark.epic_comments.10.json" <<'FX'
[{"body":"잡담","created_at":"2026-09-12T00:00:00Z"},
 {"body":"leaf 전부 종료로 자동 종료 — leaf #101 <!-- epic-sweep --><!-- bodat:worker -->","created_at":"2026-09-12T01:00:00Z"}]
FX
cat > "$tmp/fx/ggqgga_EpicMark.epic_comments.11.json" <<'FX'
[{"body":"잡담 — 마커 없음","created_at":"2026-09-12T00:00:00Z"}]
FX
: > "$tmp/fx/ggqgga_EpicMark.epic_comments.12.fail"

# ── 픽스처: ggqgga/EpicCap (epiccap) — 새 조회가 **자기 상한**에 닿는다 ─────────────
# `EPIC_CLOSED_LIMIT` 를 낮춰 1000행짜리 픽스처 없이 상한 경로를 재현한다
# (epic-sweep.sh 의 `EPIC_SEARCH_PER_PAGE` 와 같은 관행).
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicCap.issues.json" <<'FX'
[
 {"number":500,"title":"에픽 J","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":501,"title":"열린 leaf","createdAt":"@NOW@","body":"Epic #500","labels":[{"name":"agent-ready"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicCap.issues_closed.json"
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicCap.epic_closed.json" <<'FX'
[
 {"number":502,"body":"Epic #500","closedAt":"@NOW@","labels":[]},
 {"number":503,"body":"Epic #500","closedAt":"@NOW@","labels":[]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicCap.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicCap.pr_closed.json"

# ── 픽스처: ggqgga/EpicAnchor (epicanchor) — 전용 줄 끝 앵커 격자 (#327) ────
# leaf 는 `Epic #N` **전용 줄**이다. 줄 시작은 전용 줄 모양이어도 뒤에 산문이 이어지면
# leaf 가 아니다 — 끝 앵커가 없던 옛 정규식은 이것들을 leaf 로 셌고, 그런 언급만 달린 옛
# 에픽(#800)이 leaf ≥1·전부 종료로 읽혀 `에픽 leaf 전부 종료` warn(=스윕이 닫을 대상)을
# 받았다. 걸러야 할 것과 걸러선 안 될 것을 **한 레포에 나란히** 둔다.
#   에픽  구성                                           want
#   ────  ─────────────────────────────────────────────  ────────────────────────
#   #800  닫힌 이슈 3건이 전부 **문장형** `Epic #800 …`   leaf 0 → `leaf 없음(Epic 줄 미부착)`
#                                                        warn 없음(앵커 없으면 `3/3` + 전부 종료 warn)
#   #810  열린 이슈 3건이 전부 **전용 줄** 3형태          `0/3 · 대기 3`
#   #1    한 자리 에픽 — `Epic #1` 은 leaf, `Epic #1 #2`  `0/1 · 대기 1`
#         (뒤에 다른 번호)·`Epic #10`(접두)은 leaf 아님
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicAnchor.issues.json" <<'FX'
[
 {"number":800,"title":"에픽 — 문장형 언급만","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":810,"title":"에픽 — 전용 줄 3형태","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":1,"title":"에픽 — 한 자리 번호","createdAt":"@NOW@","body":"","labels":[{"name":"epic"}]},
 {"number":811,"title":"전용 줄","createdAt":"@NOW@","body":"Epic #810","labels":[{"name":"agent-ready"}]},
 {"number":812,"title":"앞뒤 공백 + 소문자","createdAt":"@NOW@","body":"  epic #810  ","labels":[{"name":"agent-ready"}]},
 {"number":813,"title":"대문자","createdAt":"@NOW@","body":"EPIC #810","labels":[{"name":"agent-ready"}]},
 {"number":814,"title":"한 자리 에픽의 전용 줄","createdAt":"@NOW@","body":"Epic #1","labels":[{"name":"agent-ready"}]},
 {"number":815,"title":"뒤에 다른 번호 — leaf 아님","createdAt":"@NOW@","body":"Epic #1 #2","labels":[{"name":"agent-ready"}]},
 {"number":816,"title":"접두 오매치 — leaf 아님","createdAt":"@NOW@","body":"Epic #10","labels":[{"name":"agent-ready"}]}
]
FX
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_EpicAnchor.issues_closed.json" <<'FX'
[
 {"number":801,"body":"Epic #800 설명","closedAt":"@NOW@","labels":[]},
 {"number":802,"body":"Epic #800 (부모)","closedAt":"@NOW@","labels":[]},
 {"number":803,"body":"Epic #800:","closedAt":"@NOW@","labels":[]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_EpicAnchor.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_EpicAnchor.pr_closed.json"

# ── 픽스처: ggqgga/issue-runner (runner) — 깨끗함 + release 있음 ─────────────
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_issue-runner.issues.json" <<'FX'
[
 {"number":140,"title":"깨끗한 대기건","createdAt":"@NOW@","labels":[{"name":"agent-ready"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_issue-runner.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_issue-runner.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_issue-runner.issues_closed.json"
: > "$tmp/fx/ggqgga_issue-runner.release"
echo '7' > "$tmp/fx/ggqgga_issue-runner.ahead"

# ── 픽스처: ggqgga/BoDAC (bodac) — 조회 실패 ───────────────────────────────
: > "$tmp/fx/ggqgga_BoDAC.fail"

# ── 픽스처: ggqgga/Broken (broken) — gh 는 exit 0 인데 JSON 이 깨졌다 ────────
# gh 가 성공했다고 조용히 빈 스냅샷을 찍으면 "그 레포엔 아무것도 없다" 로 읽힌다.
printf '%s' '{이건 JSON 이 아니다' > "$tmp/fx/ggqgga_Broken.issues.json"
echo '[]' > "$tmp/fx/ggqgga_Broken.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_Broken.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_Broken.issues_closed.json"

# ── 픽스처: ggqgga/NoCompare (nocompare) — release 는 있는데 compare 가 실패 ──
echo '[]' > "$tmp/fx/ggqgga_NoCompare.issues.json"
echo '[]' > "$tmp/fx/ggqgga_NoCompare.pr_open.json"
echo '[]' > "$tmp/fx/ggqgga_NoCompare.pr_closed.json"
echo '[]' > "$tmp/fx/ggqgga_NoCompare.issues_closed.json"
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
# 닫힌 이슈 목록도 200건(#260) — 이 상한도 `body` 가 있으니 같은 ARG_MAX 근거로 파일 경유.
jq -n --arg t "$NOW" \
  '[range(1;201) | {number: ., body: ("x" * 8000), closedAt: $t, labels: []}]' \
  > "$tmp/fx/ggqgga_Big.issues_closed.json"

run() {  # run <인자...> — 출력은 $tmp/out, exit 는 RC
  : > "$STUB_CALL_LOG"   # 호출 로그는 런 단위 — 앞선 런의 호출이 건수 단언에 새지 않게
  STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" "$SUT" "$@" >"$tmp/out" 2>"$tmp/err"
  RC=$?
}

# ── ①②③④ 두 레포 정상 스코프 ─────────────────────────────────────────────
run --repo ggqgga/BodaT --repo ggqgga/issue-runner --since 24h
ck "정상 스코프: exit 0" "$RC" 0

has_line "헤더: 열림=버킷합(19) · 스코프 · 창" "$tmp/out" \
  "파이프라인 bodat — 열림 22 · 스코프 bodat·runner · 창 24h"
# (#276) 줄 **순서** — 사다리 9줄(대기 → issue-runner → 검증대기 → verify-runner → 마감대기 →
# closeout → 보류 → needs-human → 배포대기; 막힘은 대기의 갈래라 바로 아래)과 그 아래 창 3줄.
# has_line 은 순서를 못 보므로 라벨 열만 뽑아 한 줄로 대조한다.
ck "10줄 순서 — 누가 들고 있나 순(보류는 needs-human 앞 · 테스트는 needs-human 뒤·배포대기 앞)" \
  "$(awk 'NR>=2 && NR<=15 {print $1}' "$tmp/out" | paste -sd' ' -)" \
  "대기 막힘 issue-runner 검증대기 verify-runner 마감대기 closeout 보류 needs-human 테스트 배포대기 실패 중복종료 파생"
has_line "대기 3(창 밖 파생건도 대기에는 남는다)" "$tmp/out" \
  "  대기           4  #4901 #4832 #4831 #4600"
# (#248) 블로커가 없는 픽스처에서는 `막힘 0` 한 줄이 느는 것 말고 출력이 바뀌지 않는다 —
# 위아래의 기존 기대값이 그대로 통과하는 것이 그 증거다.
has_line "(#248) 비-막힘 픽스처는 막힘 0" "$tmp/out" "  막힘           0"
# (#244) 이 픽스처의 정지는 전부 needs-human 을 달고 있어 needs-human 이 이긴다 → 보류 0.
has_line "(#244) needs-human 이 이긴 픽스처는 보류 0" "$tmp/out" "  보류           0"
# 인계 전 창(기본 90분) — #4854 는 60분 전이라 무소속 warn 이 아니라 issue-runner 줄에 붙는다.
# #4701 의 PR #4855 는 200분 전이라 붙지 않는다(아래 warn 에서 잡힌다).
has_line "issue-runner 2(좌초건 포함) — 창 안 PR 만 '인계 전' 으로 병기" "$tmp/out" \
  "  issue-runner   2  #4803 ← PR #4854(인계 전) #4701"
has_line "검증대기 2 — 제목이 배포 대기… 여도 사다리 라벨이 이긴다" "$tmp/out" \
  "  검증대기       2  #4810 ← PR #4840 #4500"
has_line "마감대기 1 + 연결 PR" "$tmp/out" \
  "  마감대기       1  #4811 ← PR #4841"
has_line "closeout 2(중복단계건은 가장 뒤 단계로)" "$tmp/out" \
  "  closeout       2  #4818 ← PR #4837 #4700"
# 사유 3종(ladder·policy·conflict) 전부 + hold:* 없는 건은 `사유 없음`
# needs-human 이 **가장 앞**이다(2026-09-13, BoDAT #5197) — 사용자는 그 라벨 하나만 보기로 했다.
# deploy-cycle 이 승격·배포 실패에 붙이는 needs-human(#4848 꼴)이 배포대기 칸에 숨으면 안 되고,
# 테스트 이슈에 사람 조작이 남은 건(#4849)도 마찬가지다.
has_line "needs-human 7 — 사다리 위치 + hold:* 사유 + 질문 유무 + 열린 연결 PR · 배포대기·테스트에 붙은 것 포함" "$tmp/out" \
  "  needs-human    7  #4849(대기, 사유 없음) #4848(대기, 사유 없음) #4826(대기, 사유 없음) #4825(대기, ladder, PR #4835) #4780(대기, policy) #4771(대기, conflict) #4770(issue-runner, conflict, 질문 없음)"
has_line "배포대기 3 — 라벨 + 제목 폴백 + agent:claimed 이 붙어도 배포대기가 이긴다 · needs-human 건은 그쪽으로" "$tmp/out" \
  "  배포대기       3  #4838 #4796 #4790"
has_line "테스트 1 — 테스트 라벨(needs-human 뒤·배포대기 앞)" "$tmp/out" \
  "  테스트         1  #4839"
no_sub "needs-human 이 붙은 테스트 건은 테스트 칸에 없다" "$tmp/out" "  테스트         1  #4849"
# 렌더 순서도 판별 순서와 같다 — 테스트 줄이 배포대기 줄보다 위(Codex P2, PR #429).
ck "렌더 순서: 테스트 줄이 배포대기 줄 위" \
  "$(grep -E '^  (테스트|배포대기) ' "$tmp/out" | head -2 | awk '{print $1}' | tr '\n' ' ')" "테스트 배포대기 "
# ② 창 필터: 머지된 PR·창 밖 PR·사람 브랜치는 실패 아님
has_line "실패 1 — 창 안 미머지 agent PR 만(dup 라벨 건은 뺀다)" "$tmp/out" \
  "  실패           1  PR #4792(#4753, 머지 없이 닫힘)"
has_line "중복종료 1 — PR 라벨 dup 인 건은 별도 줄" "$tmp/out" \
  "  중복종료       1  PR #4791(#4752, 중복 종료)"
no_sub "중복종료: 실패 줄에 겹쳐 세지 않는다" "$tmp/out" "PR #4791(#4752, 머지 없이 닫힘)"
no_sub "실패: 창 밖 PR #4794 제외" "$tmp/out" "#4794"
no_sub "실패: 머지된 PR #4793 제외" "$tmp/out" "#4793"
no_sub "실패: 사람 브랜치 PR #4795 제외" "$tmp/out" "#4795"
has_line "파생 1 — 창 안 spinoff 만(#4901 은 창 밖)" "$tmp/out" \
  "  파생           1  #4832"
has_line "승격 대기 — release 없는 레포" "$tmp/out" \
  "  승격 대기      —"
# 루프 밖 이슈는 어디에도 안 센다
no_sub "루프 밖 이슈 #4900 미집계" "$tmp/out" "#4900"

# ③ warn 5종 + 사유 없음 + 인계 지연(+ #188 회귀 대조 PR #4991 1건 + #265 정지 미러 1건)
# (#244) `needs-human 사유 없음` warn 이 note 로 내려가 11 → 10.
has_line "warn 10건(질문 유무 미확인 1 · #188 대조 #4991 · #265 정지 미러 포함)" "$tmp/out" "  warn           10"
# (#265) PR #4852 는 `needs-human` 을 **맨몸으로**(= `hold:` 접두 0개) 단 채 열려 있고 연결
# 이슈 #4832 는 깨끗하다. 기계는 이 모양을 만들 수 없다 — `needs-human` 을 붙이는 자리는
# `transition.sh` 하나뿐이고 기계 정지 세 전이는 `--reason` 이 필수라 언제나 `hold:<사유>`
# 와 쌍으로 붙인다. 그러니 사람이 손으로 세운 브레이크이고, 교정 갈래(resume-sweep ④)도
# 떼지 않는다 → 교정 못 하는 후보를 경보에 얹으면 상시 잡음이다(#190 의 warn 정의).
# 기계 미러(=`hold:*` 동반) 쪽 양성 커버리지는 아래 `ggqgga/Mirror` 격자가 전담한다.
no_sub "(#265) 맨몸 needs-human PR #4852 는 정지 미러 warn 이 아니다" "$tmp/out" \
  "정지 미러 불일치 #4832"
has_sub "warn 무소속 PR" "$tmp/out" \
  "    - 무소속 PR #4850(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4832 도 정지 라벨 없음"
has_sub "warn 단계 라벨 중복" "$tmp/out" \
  "    - 단계 라벨 중복 #4700(bodat) — flow:verify + harvesting"
has_sub "warn 미러 불일치(이슈에만 단계)" "$tmp/out" \
  "    - 미러 불일치 #4811(bodat) ↔ PR #4841(bodat) — 이슈 flow:ready · PR 단계 없음"
# (#282) 이슈 `agent-ready` 만은 이제 대기 **칸**이라 문구가 `단계 없음` 이 아니라 `agent-ready 만` 이다.
has_sub "warn 미러 불일치(PR 에만 단계 — 반대 방향)" "$tmp/out" \
  "    - 미러 불일치 #4600(bodat) ↔ PR #4860(bodat) — 이슈 agent-ready 만 · PR flow:ready"
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
  "    - 무소속 PR #4855(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4701 도 정지 라벨 없음(agent:claimed 인데 200분 경과 — 워커 사망 의심)"
# 판정축은 `agent:claimed` **라벨**이 아니라 **issue-runner 버킷** — 라벨을 단 채 배포대기로 간
# 이슈(#4790)의 라벨 없는 PR 은 warn 에서 빠지면 어디에도 안 그려져 거짓 깨끗함이 된다.
# 정확히 이 줄이어야 한다(꼬리표가 붙으면 has_line 이 깨진다 — 인계 창과 무관한 건이다).
has_line "issue-runner 버킷 밖의 agent:claimed PR 은 무소속 warn(꼬리표 없이)" "$tmp/out" \
  "    - 무소속 PR #4856(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4790 도 정지 라벨 없음"
no_sub "issue-runner 버킷 밖 PR 은 '인계 전' 으로도 안 그려진다" "$tmp/out" "PR #4856(인계 전)"

# ── (#188) 무소속 PR warn 이 사람 세션 브랜치(head 가 agent/issue-* 아님)에도 울리던
# 문제 — warn 은 "루프가 교정 가능한 불변식 위반" 으로 좁히고, 제외된 후보는 note 로
# 강등한다(존재 자체는 남긴다). 실측 원천(bodat PR #4987/#4963)과 같은 모양으로 픽스처.
# 케이스1: head feat/* + 연결 이슈 있음 + 단계 라벨 0 → 무소속 warn 은 0, note 로 강등.
no_sub "(#188) 케이스1: 사람 세션 PR #4987 는 무소속 warn 아님" "$tmp/out" "무소속 PR #4987"
has_line "(#188) note 6건 — 사람 세션 PR + (#244) 사유 없는 needs-human 3 + (#246) full-cycle PR 2" \
  "$tmp/out" "  note           6"
has_line "(#188) 케이스1: 사람 세션 PR #4987 는 note 로 강등된다" "$tmp/out" \
  "    - 사람 세션 PR #4987(bodat) — head feat/adspower-swr-4963 (agent/issue-* 아님) · 연결 이슈 #4963 · 루프가 못 집어 warn 아님"
# 케이스2(회귀 방지): head agent/issue-* + 단계 라벨 0 + 연결 이슈 needs-human 아님
# → 종전대로 무소속 warn 1건. note 로는 내려가지 않는다.
has_line "(#188) 케이스2: agent 헤드는 종전대로 무소속 warn" "$tmp/out" \
  "    - 무소속 PR #4991(bodat) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #4964 도 정지 라벨 없음"
no_sub "(#188) 케이스2: agent 헤드는 note 로 강등되지 않는다" "$tmp/out" "사람 세션 PR #4991"
# 케이스3: head feat/* + 연결 이슈 없음 → 애초에 후보가 아니다(종전 동작 유지) —
# 무소속 warn 에도 note 에도 나타나지 않는다(존재를 지키는 대상 자체가 아니라서).
no_sub "(#188) 케이스3: 연결 이슈 없는 사람 브랜치는 무소속 warn 에 없다" "$tmp/out" "PR #4992"
no_sub "(#188) 케이스3: 연결 이슈 없는 사람 브랜치는 note 에도 없다" "$tmp/out" "사람 세션 PR #4992"

# ── (#246) 레인 판별 두 번째 축 — `full-cycle` 라벨. head 이름은 관례라 그것만으로는
# 부족하다: 사람 세션이 `agent/issue-*` 접두를 쓴 PR #4993 은 head 만 보면 #4991 과 똑같이
# 무소속 warn 으로 떨어져 루프가 집을 수 없는 후보가 warn 을 오염시킨다(#188 이 막은 그
# 잡음). 라벨이 붙었으면 head 와 무관하게 note(사람 세션 PR)다 — #188 의 경계·문구는 그대로,
# 괄호 안 사유만 축에 맞춘다. 격자: 라벨 있음 → note · 라벨 없음+agent 헤드 → warn(#4991 —
# 위 케이스2가 그 회귀 칸) · 둘 다 아님 → note(#4987 — 위 케이스1이 그 회귀 칸).
no_sub "(#246) agent 헤드 + full-cycle PR #4993 은 무소속 warn 아님" "$tmp/out" "무소속 PR #4993"
has_line "(#246) agent 헤드 + full-cycle PR #4993 은 note 로 — 사유는 라벨" "$tmp/out" \
  "    - 사람 세션 PR #4993(bodat) — head agent/issue-4965 (full-cycle 라벨) · 연결 이슈 #4965 · 루프가 못 집어 warn 아님"
no_sub "(#246) 사람 헤드 + full-cycle PR #4994 는 무소속 warn 아님" "$tmp/out" "무소속 PR #4994"
has_line "(#246) 사람 헤드 + full-cycle PR #4994 는 note 로 — 두 축 사유를 모두 적는다" "$tmp/out" \
  "    - 사람 세션 PR #4994(bodat) — head feat/full-cycle-4966 (full-cycle 라벨 · agent/issue-* 아님) · 연결 이슈 #4966 · 루프가 못 집어 warn 아님"

# (#244) 사유 라벨 없는 needs-human 은 **정상 상태**(사람이 직접 세운 정지)라 warn 이
# 아니라 note 다 — 기계 정지가 hold:* 하나만 붙게 된 뒤로 교정할 불변식 위반이 없다.
no_sub "사유 없음은 더 이상 warn 이 아니다" "$tmp/out" "needs-human 사유 없음"
has_sub "(#244) 사람이 직접 세운 정지는 note" "$tmp/out" \
  "    - 사람이 직접 세운 정지 #4826(bodat) — hold:* 라벨 없음(정상)"
no_sub "사유 있는 건은 이 note 대상 아님" "$tmp/out" "직접 세운 정지 #4825"
no_sub "사유 있는 건은 이 note 대상 아님(conflict)" "$tmp/out" "직접 세운 정지 #4770"
# 배포대기·테스트에 붙은 사유 없는 needs-human 도 그 버킷이라 같은 note 를 낸다(정상 — 사람이 볼 것)
has_sub "배포 검증 제목 + needs-human 도 이 note" "$tmp/out" "직접 세운 정지 #4848"
has_sub "테스트 + needs-human 도 이 note" "$tmp/out" "직접 세운 정지 #4849"

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
# 조회는 **needs-human 버킷의 policy·conflict** 에만 — 다른 버킷·다른 사유엔 안 묻는다(N+1 억제)
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
# #4790 은 issue-runner 버킷 밖(배포대기가 이겼다) → 꼬리표가 없으니 조회도 없다.
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
has_line "runner 승격 대기 7커밋" "$tmp/out" "  승격 대기      7커밋"
has_line "깨끗한 레포는 warn 0" "$tmp/out" "  warn           0"

# ── ② 창을 넓히면 창 밖이던 것이 들어온다(창 필터가 실제로 동작한다는 대조군) ──
run --repo ggqgga/BodaT --since 7d
has_line "창 7d: 파생 2(옛 spinoff 포함)" "$tmp/out" "  파생           2  #4901 #4832"
has_line "창 7d: 실패 2(창 밖이던 #4794 포함)" "$tmp/out" \
  "  실패           2  PR #4794(#4755, 머지 없이 닫힘) PR #4792(#4753, 머지 없이 닫힘)"
has_line "창 7d: 중복종료는 여전히 1(실패로 새지 않는다)" "$tmp/out" \
  "  중복종료       1  PR #4791(#4752, 중복 종료)"

# ── §5 인계 전 창 — HANDOFF_GRACE_MIN 으로 창을 넓히면 #4855 도 '인계 전' 이 된다 ──
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" HANDOFF_GRACE_MIN=300 \
  "$SUT" --repo ggqgga/BodaT --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "HANDOFF_GRACE_MIN=300: exit 0" "$RC" 0
has_line "창 300분: #4855 도 인계 전으로 넘어온다" "$tmp/out" \
  "  issue-runner   2  #4803 ← PR #4854(인계 전) #4701 ← PR #4855(인계 전)"
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
  "    - 무소속 PR #61(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #31 도 정지 라벨 없음(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
no_sub "(a) PR 나이(240분)로 재지 않는다" "$tmp/out" "240분 경과"
no_sub "(a) 첫 페이지의 옛 claim(200분)을 취하지 않는다 — 전량을 읽는다" "$tmp/out" "200분 경과"
# (a) (#181) 같은 이슈(#31)를 가리키는 두 번째 무소속 PR #65 — 값은 #61 과 같아야 한다
# (같은 타임라인을 다시 조회하지 않고 캐시된 claim 시각을 재사용한다는 뜻).
has_line "(a) 같은 이슈의 두 번째 PR #65 도 같은 claim 시각(5분)" "$tmp/out" \
  "    - 무소속 PR #65(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #31 도 정지 라벨 없음(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
# (b) 조회 실패·이벤트 부재는 숫자를 지어내지 않는다. warn 자체는 유지한다.
has_line "(b) 타임라인 조회 실패 → 경과 미상(warn 은 유지)" "$tmp/out" \
  "    - 무소속 PR #62(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #32 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 확인 필요)"
has_line "(b) claim 이벤트 부재 → 경과 미상(0분으로 접지 않는다)" "$tmp/out" \
  "    - 무소속 PR #63(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #33 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 확인 필요)"
# 형식 밖 시각을 jq 에 그대로 넘기면 레포 블록이 통째로 죽는다 — 한 건만 미상으로 접는다.
has_line "(b) 형식 밖 claim 시각 → 그 건만 경과 미상" "$tmp/out" \
  "    - 무소속 PR #64(reclaim) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #34 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 확인 필요)"
no_sub "(b) 형식 밖 시각이 레포 블록을 죽이지 않는다" "$tmp/out" "reclaim — 조회 실패"
has_line "reclaim: warn 5건(#65 포함)" "$tmp/out" "  warn           5"
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
  "$tmp/out" "연결 이슈 #34 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 확인 필요)"

# ── (b)(c) (#181) 상한에 걸려 안 본 것과 조회했지만 실패한 것은 다른 문구다 ──────
# 상한을 1로 좁히면 고유 이슈 중 첫째(#31)만 조회되고 둘째(#32)는 **안 본다** — 그 문구는
# `확인 필요`(조회했지만 실패)가 아니라 `조회 상한`(애초에 안 봤다) 이어야 한다.
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" CLAIM_TIME_MAX=1 \
  "$SUT" --repo ggqgga/Reclaim --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "CLAIM_TIME_MAX=1: exit 0" "$RC" 0
ck "CLAIM_TIME_MAX=1: 타임라인 조회 1건" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 1
has_sub "CLAIM_TIME_MAX=1: 상한 안의 #31 은 그대로 5분" "$tmp/out" \
  "연결 이슈 #31 도 정지 라벨 없음(agent:claimed 인데 5분 경과 — 워커 사망 의심)"
has_sub "(b) CLAIM_TIME_MAX=1: 상한 밖(#32)은 '조회 상한' — '안 봤다'" "$tmp/out" \
  "연결 이슈 #32 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 조회 상한)"
no_sub "(b) 상한 밖 문구는 조회 실패 문구(확인 필요)와 섞이지 않는다" "$tmp/out" \
  "연결 이슈 #32 도 정지 라벨 없음(agent:claimed 인데 경과 미상 — 확인 필요)"
has_sub "CLAIM_TIME_MAX=1: 상한 초과 사유가 stderr 에" "$tmp/err" \
  "reclaim #32 claim 시각 조회 상한(1) 초과"
has_line "CLAIM_TIME_MAX=1: warn 은 여전히 5건" "$tmp/out" "  warn           5"
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
has_line "창 300분: reclaim warn 0" "$tmp/out" "  warn           0"
ck "창 300분: 타임라인 조회 0건" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 0

# ── ⑤ 레포 하나 조회 실패 → 그 블록만 실패 줄, 나머지 정상, exit 1 ──────────
run --repo ggqgga/BodaT --repo ggqgga/BoDAC --repo ggqgga/issue-runner --since 24h
ck "부분 실패: exit 1" "$RC" 1
has_sub "부분 실패: bodac 만 실패 줄" "$tmp/out" "파이프라인 bodac — 조회 실패: 이슈 목록 — "
has_sub "부분 실패: bodat 블록은 정상" "$tmp/out" "파이프라인 bodat — 열림 22"
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
ck "--json: bodat 열림 22" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .open_total' < "$tmp/out")" 22
ck "--json: runner 승격 대기 7" \
  "$(jq '.repos[] | select(.repo_short=="runner") | .promotion_ahead' < "$tmp/out")" 7
ck "--json: bodat 승격 대기 null(release 없음)" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .promotion_ahead' < "$tmp/out")" null
ck "--json: dup_closed 배열에 dup PR 만" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.dup_closed[].number]' < "$tmp/out")" '[4791]'
ck "--json: failed 에는 dup PR 이 없다" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.failed[].number]' < "$tmp/out")" '[4792]'
ck "--json: needs-human holds + note_missing (#157)" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.human_wait[] | {n:.number, h:.holds, m:.note_missing}]' < "$tmp/out")" \
  '[{"n":4849,"h":[],"m":false},{"n":4848,"h":[],"m":false},{"n":4826,"h":[],"m":false},{"n":4825,"h":["ladder"],"m":false},{"n":4780,"h":["policy"],"m":false},{"n":4771,"h":["conflict"],"m":null},{"n":4770,"h":["conflict"],"m":true}]'
ck "--json: 인계 전 PR 은 issue-runner 항목에 handoff_pending" \
  "$(jq -c '.repos[] | select(.repo_short=="bodat") | [.buckets.claimed[] | {n:.number, p:.pr, h:.handoff_pending}]' < "$tmp/out")" \
  '[{"n":4803,"p":4854,"h":true},{"n":4701,"p":null,"h":false}]'
ck "--json: 열림 합에 중복종료는 안 든다(창 교차 집계)" \
  "$(jq '.repos[] | select(.repo_short=="bodat") | .open_total' < "$tmp/out")" 22

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
has_line "compare 실패: 승격 대기 —" "$tmp/out" "  승격 대기      —"

# ── ⑧-c 목록 상한 200 도달 → 절단 warn ────────────────────────────────────
run --repo ggqgga/Big --since 24h
ck "목록 절단: exit 0" "$RC" 0
# (#248) 큰 본문 페이로드(약 1.6MB)가 커맨드라인이 아니라 파일로 넘어간다 —
# `--argjson` 이면 ARG_MAX 에 걸려 이 레포 블록이 통째로 `집계 실패(jq)` 가 된다.
no_sub "(#248) 큰 body 페이로드가 ARG_MAX 로 집계 실패하지 않는다" "$tmp/out" \
  "파이프라인 big — 조회 실패"
has_sub "(#248) 큰 body 페이로드에서도 블록이 정상 렌더" "$tmp/out" "파이프라인 big — 열림 0"
has_line "목록 절단: warn 2건(#292 로 닫힌 이슈 목록이 빠졌다)" "$tmp/out" "  warn           2"
has_sub "목록 절단: 이슈 목록" "$tmp/out" "    - 목록 상한 200 도달 — 창 절단 가능(이슈)"
# (#292) 최근 닫힌 200건의 절단 warn 은 **없앴다**. 그 목록의 유일한 소비자였던 에픽 leaf
# 카운트가 검색 스코프 조회로 옮겨 갔고, 남은 쓰임(색인 지연 보완·조용한 실패 교차확인)은
# 최근 것만 있으면 되는 성질이라 상한 도달이 정상이다 — bodat 은 매 틱 닿아 교정 불가능한
# 상시 소음이었다(#190 의 warn 정의 위반). 절단 신호는 새 조회의 상한으로 옮겼다.
no_sub "(#292) 최근 닫힌 200건의 절단 warn 은 사라졌다" "$tmp/out" \
  "목록 상한 200 도달 — 창 절단 가능(닫힌 이슈)"
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
has_sub "무시된 줄: 나머지 레포는 정상" "$tmp/out" "파이프라인 bodat — 열림 22"

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
has_line "capped needs-human — 100건 상한은 미확인, 마커 있으면 조용, 0건이면 질문 없음" "$tmp/out" \
  "  needs-human    3  #12(대기, policy, 질문 없음) #11(대기, conflict) #10(대기, policy)"
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
  "  needs-human    5  #24(대기, conflict, 질문 없음) #23(대기, conflict) #22(대기, policy) #21(대기, conflict, policy) #20(대기, policy, 질문 없음)"
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
has_line "blockers 헤더 — 열림 20(막힘은 대기에서 옮겨 온 것이라 총합 불변)" "$tmp/out" \
  "파이프라인 blockers — 열림 20 · 스코프 blockers · 창 24h"
# ③⑥ 과잉 포획 반증이 사는 자리 — 닫힌 블로커(#12)·산문(#15)·라벨 접미가 숫자 아님(#18)
# ·앵커 앞 낱말(#21)·구분자 없음(#22)은 전부 `대기` 로 남는다.
has_line "① 대기 6 — 블로커가 없거나 이미 해제된 것만" "$tmp/out" \
  "  대기           6  #902 #22 #21 #18 #15 #12"
has_line "② 막힘 9 — 항목마다 블로커와 그 버킷(PR 이면 PR #n) · 보류 블로커는 (보류)(#346)" "$tmp/out" \
  "  막힘           9  #24 ← #904(보류) #20 ← #902(대기) #19 ← #901(issue-runner) #17 ← #903(배포대기) #16 ← #900(needs-human) #14 ← #902(대기) #13 ← PR #950 #11 ← #901(issue-runner) #10 ← #900(needs-human)"
# 다른 버킷은 블로커와 무관하게 그대로 — 막힘은 `대기` 판정을 통과한 것에서만 갈린다
has_line "⑨ issue-runner 이슈는 블로커가 있어도 issue-runner 그대로" "$tmp/out" "  issue-runner   2  #901 #23"
has_line "blockers needs-human 1" "$tmp/out" "  needs-human    1  #900(대기, ladder)"
has_line "blockers 배포대기 1" "$tmp/out" "  배포대기       1  #903"
has_line "blockers 보류 1 — 단독 hold:conflict 블로커(횟수 병기)" "$tmp/out" "  보류           1  #904(conflict, 0/1)"
# 개별 반례를 부분 문자열로도 못 박는다 — 줄 전체 비교가 다른 이유로 깨져도 무엇이
# 틀렸는지 보이게(과잉 포획은 `막힘` 줄에 그 번호가 나타나는 것으로 드러난다).
no_sub "③ 닫힌 블로커(#999)는 대기 유지 — 막힘으로 안 내려간다" "$tmp/out" "#12 ← "
no_sub "⑥ 산문 속 blocked by 는 블로커 아님" "$tmp/out" "#15 ← "
no_sub "숫자 아닌 라벨 접미(blocked-by:abc)는 블로커 아님" "$tmp/out" "#18 ← "
no_sub "앵커: 앞에 낱말이 있는 줄은 블로커 아님" "$tmp/out" "#21 ← "
no_sub "구분자 없는 blockedby 는 블로커 아님" "$tmp/out" "#22 ← "
no_sub "같은 줄 뒤쪽 언급(#902)은 #19 의 블로커가 아니다" "$tmp/out" "#19 ← #901(issue-runner) #902"
# ⑧ warn 은 **블로커 기준으로 묶는다** — 하위가 둘이어도 한 줄, 하위 번호는 내림차순.
has_line "blockers warn 2건(사람 게이트 블로커만)" "$tmp/out" "  warn           2"
has_sub "⑧ 블로커 needs-human — 하위 둘이 한 줄로 묶이고 내림차순" "$tmp/out" \
  "    - 블로커 needs-human #900(blockers) — 하위 #16 #10 정체"
has_sub "배포대기 블로커도 같은 규칙(사람 게이트)" "$tmp/out" \
  "    - 블로커 배포대기 #903(blockers) — 하위 #17 정체"
# issue-runner·검증대기 블로커는 루프가 처리 중이라 warn 이 아니다
no_sub "issue-runner 블로커(#901)는 warn 아님" "$tmp/out" "블로커 issue-runner"
no_sub "대기 블로커(#902)는 warn 아님" "$tmp/out" "블로커 대기"
no_sub "PR 블로커는 warn 아님" "$tmp/out" "블로커 #950"
# (#346) 보류 블로커는 루프(재개 스윕)가 풀 것 — 사람 게이트 warn 대상이 아니다
no_sub "(#346) 보류 블로커(#904)는 warn 아님" "$tmp/out" "블로커 보류"
# issue-runner 버킷의 #23 은 막힘이 아니므로 #900 warn 의 하위에도 안 들어간다
no_sub "막힘이 아닌 이슈는 warn 하위에 안 섞인다" "$tmp/out" "하위 #23"
# 추가 gh 호출 0 — 블로커 상태는 이미 받은 목록 안에서만 판정한다(개별 view 금지).
# 코멘트 조회는 보류 conflict #904 의 **재개 횟수**(#346) 한 건뿐 — 하위(#24)·다른 블로커엔 없다.
ck "(#248) 블로커 판정에 개별 issue view 를 쓰지 않는다 — 코멘트 조회는 #904 횟수 1건뿐" \
  "$(grep -c '^comments ' "$STUB_CALL_LOG")" 1
check "(#248) 그 1건은 보류 conflict 블로커 #904 의 횟수 조회다" \
  "$(grep -qxF "comments ggqgga/Blockers 904" "$STUB_CALL_LOG" && echo ok || echo no)"
ck "(#248) 타임라인 조회도 없다" "$(grep -c '^timeline ' "$STUB_CALL_LOG")" 0

# ⑦ --json — blocked[] 항목은 기존 item 필드 + blockers[{n,state,bucket}]
run --repo ggqgga/Blockers --since 24h --json
ck "⑦ --json: blocked[].blockers 형태" \
  "$(jq -c '[.repos[0].buckets.blocked[] | {n:.number, b:.blockers}]' < "$tmp/out")" \
  '[{"n":24,"b":[{"n":904,"state":"OPEN","bucket":"보류"}]},{"n":20,"b":[{"n":902,"state":"OPEN","bucket":"대기"}]},{"n":19,"b":[{"n":901,"state":"OPEN","bucket":"issue-runner"}]},{"n":17,"b":[{"n":903,"state":"OPEN","bucket":"배포대기"}]},{"n":16,"b":[{"n":900,"state":"OPEN","bucket":"needs-human"}]},{"n":14,"b":[{"n":902,"state":"OPEN","bucket":"대기"}]},{"n":13,"b":[{"n":950,"state":"OPEN PR","bucket":null}]},{"n":11,"b":[{"n":901,"state":"OPEN","bucket":"issue-runner"}]},{"n":10,"b":[{"n":900,"state":"OPEN","bucket":"needs-human"}]}]'
ck "⑦ --json: blocked 항목에도 repo_short·label" \
  "$(jq -c '[.repos[0].buckets.blocked[] | select(.repo_short=="blockers")] | length' < "$tmp/out")" 9
ck "⑦ --json: open_total 에 blocked 가 든다" \
  "$(jq '.repos[0].open_total' < "$tmp/out")" 20
ck "⑦ --json: waiting 에는 막힘이 안 남는다" \
  "$(jq -c '[.repos[0].buckets.waiting[].number]' < "$tmp/out")" '[902,22,21,18,15,12]'
ck "⑦ --json: warn kind 는 blocker_human_wait" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="blocker_human_wait") | {b:.blocker, k:.bucket, i:.issues}]' < "$tmp/out")" \
  '[{"b":903,"k":"배포대기","i":[17]},{"b":900,"k":"needs-human","i":[16,10]}]'

# ── ⑯ (#276) verify-runner 칸 — `verifying`(#275) 이 사다리에 끼어 있다 ─────────
run --repo ggqgga/Verifying --since 24h
ck "verifying: exit 0" "$RC" 0
has_line "verifying 헤더 — 열림 6(에픽 이슈 자신은 루프 밖)" "$tmp/out" \
  "파이프라인 verifying — 열림 6 · 스코프 verifying · 창 24h"
has_line "verify-runner 4 — 정상·중복·미러 불일치·leaf, 번호 내림차순, 열린 연결 PR 병기" "$tmp/out" \
  "  verify-runner  4  #65 ← PR #165 #62 ← PR #162 #61 ← PR #161 #60 ← PR #160"
has_line "검증대기 1 — 대조군 #64 는 종전 그대로" "$tmp/out" "  검증대기       1  #64 ← PR #164"
has_line "마감대기 1 — verifying + flow:ready 는 뒤 단계(flow:ready)가 이긴다" "$tmp/out" \
  "  마감대기       1  #63 ← PR #163"
has_line "대기 0 — verifying 이슈는 대기로 새지 않는다" "$tmp/out" "  대기           0"
# 한 이슈 = 한 버킷 — verifying 건이 검증대기 줄에 겹쳐 세지지 않는다
no_sub "verifying: #60 은 검증대기 줄에 없다" "$tmp/out" "  검증대기       1  #64 ← PR #164 #60"
# 중복 건(#61·#63)은 이슈 쪽 미러 집합이 2개라 PR(1개)과도 어긋난다 — 중복 + 미러 불일치
# 두 줄이 같이 뜨는 것이 맞다(두 사실). 정상 #60·대조군 #64 는 조용.
has_line "verifying: warn 5(중복 2 · 미러 불일치 3) — 정상 #60·대조군 #64 는 조용" "$tmp/out" \
  "  warn           5"
has_sub "verifying: flow:verify+verifying 동시 부착은 warn 단계 라벨 중복" "$tmp/out" \
  "    - 단계 라벨 중복 #61(verifying) — flow:verify + verifying"
has_sub "verifying: verifying+flow:ready 도 중복(사다리 순서대로)" "$tmp/out" \
  "    - 단계 라벨 중복 #63(verifying) — verifying + flow:ready"
has_sub "verifying: 이슈 verifying ↔ PR flow:verify 는 warn 미러 불일치" "$tmp/out" \
  "    - 미러 불일치 #62(verifying) ↔ PR #162(verifying) — 이슈 verifying · PR flow:verify"
has_sub "verifying: 중복 건의 미러도 어긋난다(#61) — 사다리 순서대로 적힌다" "$tmp/out" \
  "    - 미러 불일치 #61(verifying) ↔ PR #161(verifying) — 이슈 flow:verify verifying · PR verifying"
no_sub "verifying: 양쪽 verifying(#60) 은 미러 불일치가 아니다" "$tmp/out" "미러 불일치 #60"
no_sub "verifying: 양쪽 flow:verify(#64) 는 종전대로 조용" "$tmp/out" "미러 불일치 #64"
# PR 라벨 `verifying` 은 단계 라벨이다 — pr_stage_labels 에서 빠지면 #160 이 무소속 warn 으로 운다
no_sub "verifying: PR 에 verifying 이 붙은 #160 은 무소속이 아니다" "$tmp/out" "무소속 PR #160"
no_sub "verifying: PR 에 verifying 이 붙은 #165 도 무소속이 아니다" "$tmp/out" "무소속 PR #165"
has_line "verifying: 에픽 leaf 의 verifying 은 진행 으로 접힌다" "$tmp/out" "    - #66 0/1 · 진행 1"

run --repo ggqgga/Verifying --since 24h --json
ck "--json: buckets.verifying 항목(번호·pr)" \
  "$(jq -c '.repos[0] | [.buckets.verifying[] | {n:.number, p:.pr}]' < "$tmp/out")" \
  '[{"n":65,"p":165},{"n":62,"p":162},{"n":61,"p":161},{"n":60,"p":160}]'
ck "--json: open_total 에 verify-runner 칸이 합산된다" "$(jq '.repos[0].open_total' < "$tmp/out")" 6
ck "--json: verifying 항목에도 repo_short" \
  "$(jq '[.repos[0].buckets.verifying[] | select(has("repo_short") | not)] | length' < "$tmp/out")" 0
# 스키마 — 기존 키 이름은 그대로고 `verifying` 만 늘었다(표시 이름을 바꿨지 키를 바꾼 게 아니다).
ck "--json: buckets 키 = 종전 12개 + verifying + test_wait" \
  "$(jq -c '.repos[0].buckets | keys' < "$tmp/out")" \
  '["blocked","claimed","deploy_wait","dup_closed","failed","harvesting","held","human_wait","ready","spinoff","test_wait","verify","verifying","waiting"]'

# ── ★에픽 절★ (#260) — 종료/전체·leaf 버킷·P 분포, warn 2종, 파생 병기 ─────────
# ── ⑮ (#244) 보류 칸 — hold:* 만 붙은(needs-human 없는) 이슈는 대기가 아니다 ───
run --repo ggqgga/Holds --since 24h
ck "holds: exit 0" "$RC" 0
has_line "holds 헤더 — 열림 15(보류 9 + needs-human 4 + 대기 1 + 막힘 1)" "$tmp/out" \
  "파이프라인 holds — 열림 15 · 스코프 holds · 창 24h"
# (#346) 단독 hold:conflict 는 ladder 와 같은 꼴로 사유 뒤에 **재개 횟수/상한**을 병기한다 —
# `#43(conflict, 0/1)`. 횟수 = `<!-- conflict-resume: N -->` 마커 코멘트 수, 상한 = CONFLICT_RESUME_LIMIT.
# 못 센 건(#38, 조회 실패)은 `0/1` 로 접지 않고 사유만 찍는다(횟수 미상 ≠ 0회).
has_line "보류 9 — 사유 병기, 번호 내림차순, 열린 연결 PR 병기 · 단독 hold:conflict 는 재개 횟수/상한 병기(#346)" "$tmp/out" \
  "  보류           9  #48(ladder) #46(ladder) #43(conflict, 0/1) #41(policy, PR #72) #40(ladder, PR #70) #39(conflict, 1/1) #38(conflict) #36(conflict) #35(conflict, policy)"
# 동존 conflict(#35) 는 resume-sweep 이 재개를 거부하는 건이라 상한을 그리면 거짓 진행률이다 —
# 사유만 찍고 코멘트 조회도 걸지 않는다(단독 conflict 에만 횟수/상한·조회, #346 반송 P2).
no_sub "(#346) policy 동존 conflict 엔 횟수/상한을 안 붙인다" "$tmp/out" "#35(conflict, policy, 0/1)"
has_sub "(#346) conflict 재개 0회 → 0/1" "$tmp/out" "#43(conflict, 0/1)"
has_sub "(#346) conflict 재개 1회 — 코드 인용 속 마커는 안 센다(2/1 아님)" "$tmp/out" "#39(conflict, 1/1)"
no_sub "(#346) 조회 실패건은 0/1 로 접지 않는다" "$tmp/out" "#38(conflict, 0/1)"
has_sub "(#346) 횟수 미상은 warn 으로 드러난다" "$tmp/out" \
  "    - 재개 횟수 미확인 #38(holds) — 조회 실패"
no_sub "(#346) 코멘트 100건 상한에 닿은 건은 적게 센 값을 찍지 않는다" "$tmp/out" "#36(conflict, 100/1)"
has_sub "(#346) 코멘트 100건 상한도 모름이다" "$tmp/out" \
  "    - 재개 횟수 미확인 #36(holds) — 코멘트 100건 상한"
has_line "needs-human 4 — needs-human ∪ (hold:conflict ∧ full-cycle) ∪ 재심 끝난 hold:policy · conflict+needs-human 은 종전대로(질문 판정)" "$tmp/out" \
  "  needs-human    4  #49(대기, conflict) #44(대기, 사유 없음) #42(대기, policy) #37(대기, conflict, 질문 없음)"
no_sub "(#346) needs-human 줄의 conflict 엔 횟수를 안 붙인다" "$tmp/out" "#37(대기, conflict, 0/1"
has_line "대기 1 — 보류가 대기로 새지 않는다" "$tmp/out" "  대기           1  #45"
has_line "막힘 1 — 보류는 막힘으로도 안 샌다(우선순위: 보류 > 막힘)" "$tmp/out" \
  "  막힘           1  #47 ← #45(대기)"
has_line "검증대기 0 — 단계 라벨보다 보류가 앞(#46)" "$tmp/out" "  검증대기       0"
# 보류 이슈가 다른 줄에 겹쳐 세지지 않는다(한 이슈 = 한 버킷)
no_sub "보류: #40 은 대기 줄에 없다" "$tmp/out" "  대기           1  #45 #40"
no_sub "보류: #46 은 검증대기 줄에 없다" "$tmp/out" "  검증대기       1"
no_sub "보류: #48 은 막힘 줄에 없다" "$tmp/out" "#48 ←"
# 코멘트 조회는 한 자리다 — needs-human 버킷의 policy·conflict(질문 유무) + **보류 버킷의 conflict**
# (재개 횟수, #346). 보류로 간 ladder·policy(#40·#41·#46·#48)엔 여전히 안 묻는다(새 조회를 열지 않는다).
ck "holds: 코멘트 조회 7건(#42·#49·#37 질문 + #43·#39·#38·#36 횟수 — 동존 #35 는 없음)" "$(grep -c '^comments ' "$STUB_CALL_LOG")" 7
for n in 42 49 37 43 39 38 36; do
  check "holds: 코멘트 조회 #$n" "$(grep -qxF "comments ggqgga/Holds $n" "$STUB_CALL_LOG" && echo ok || echo no)"
done
for n in 40 41 46 48 35; do
  check "holds: 보류 ladder·policy·동존 conflict 이슈 #$n 엔 안 묻는다" \
    "$(grep -qxF "comments ggqgga/Holds $n" "$STUB_CALL_LOG" && echo no || echo ok)"
done
# 사람이 직접 세운 정지(#44)는 note 1건, warn 은 무소속 PR #71 + 횟수 미확인 #38
# 무소속 PR warn — 정지 라벨이 있는 쪽 둘은 빠지고, 없는 쪽 하나만 남는다
has_line "holds: warn 3(무소속 PR #71 + 재개 횟수 미확인 #38·#36)" "$tmp/out" "  warn           3"
has_sub "holds: #71 은 종전대로 무소속 warn" "$tmp/out" \
  "    - 무소속 PR #71(holds) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #45 도 정지 라벨 없음"
no_sub "holds: 연결 이슈가 보류인 PR #70 은 warn 아님" "$tmp/out" "무소속 PR #70"
no_sub "holds: PR 자체가 hold:* 인 #72 는 warn 아님" "$tmp/out" "무소속 PR #72"
has_sub "holds: #44 는 note" "$tmp/out" \
  "    - 사람이 직접 세운 정지 #44(holds) — hold:* 라벨 없음(정상)"

run --repo ggqgga/Holds --since 24h --json
# (#346) conflict 항목엔 `resume_count`(마커 수 · 못 셌으면 null)·`resume_limit` 가 붙고, 다른 사유엔 둘 다 null.
ck "--json: held 버킷 항목(번호·holds·재개 횟수/상한)" \
  "$(jq -c '.repos[0] | [.buckets.held[] | {n:.number, h:.holds, p:.pr, c:.resume_count, l:.resume_limit}]' < "$tmp/out")" \
  '[{"n":48,"h":["ladder"],"p":null,"c":null,"l":null},{"n":46,"h":["ladder"],"p":null,"c":null,"l":null},{"n":43,"h":["conflict"],"p":null,"c":0,"l":1},{"n":41,"h":["policy"],"p":72,"c":null,"l":null},{"n":40,"h":["ladder"],"p":70,"c":null,"l":null},{"n":39,"h":["conflict"],"p":null,"c":1,"l":1},{"n":38,"h":["conflict"],"p":null,"c":null,"l":1},{"n":36,"h":["conflict"],"p":null,"c":null,"l":1},{"n":35,"h":["conflict","policy"],"p":null,"c":null,"l":null}]'
ck "--json: open_total 에 보류가 합산된다" \
  "$(jq '.repos[0].open_total' < "$tmp/out")" 15
ck "--json: held 항목에도 repo_short" \
  "$(jq '[.repos[0].buckets.held[] | select(has("repo_short") | not)] | length' < "$tmp/out")" 0
# 상한은 scripts/lib/constants.sh 의 CONFLICT_RESUME_LIMIT 한 자리 — env 로 올리면 분모가 따라온다
CONFLICT_RESUME_LIMIT=3 run --repo ggqgga/Holds --since 24h
has_sub "(#346) 상한은 CONFLICT_RESUME_LIMIT 를 읽는다(0/3)" "$tmp/out" "#43(conflict, 0/3)"
# 조회 상한(HOLD_NOTE_MAX)은 질문 후보(needs-human)부터 채운다 — 넘치면 횟수 후보가 먼저 탈락하고,
# 탈락한 건은 `0/1` 이 아니라 횟수 생략 + warn `조회 상한 초과`. 질문 판정(#37)은 그대로 산다.
HOLD_NOTE_MAX=3 run --repo ggqgga/Holds --since 24h
ck "HOLD_NOTE_MAX=3: 조회는 질문 후보 3건뿐" "$(grep -c '^comments ' "$STUB_CALL_LOG")" 3
has_sub "HOLD_NOTE_MAX=3: 질문 후보는 상한 안에서 판정된다" "$tmp/out" "#37(대기, conflict, 질문 없음)"
no_sub "HOLD_NOTE_MAX=3: 안 물어본 횟수를 0/1 로 찍지 않는다" "$tmp/out" "#43(conflict, 0/1)"
has_sub "HOLD_NOTE_MAX=3: 횟수 후보 탈락은 warn 으로" "$tmp/out" \
  "    - 재개 횟수 미확인 #43(holds) — 조회 상한(3) 초과"

run --repo ggqgga/Epics --since 24h
ck "epics: exit 0" "$RC" 0
has_line "epics 헤더 — 열림 7(에픽 이슈 자신은 루프 밖이라 안 낀다)" "$tmp/out" \
  "파이프라인 epics — 열림 7 · 스코프 epics · 창 24h"
has_line "epics 대기 6(파생건도 대기엔 남는다)" "$tmp/out" \
  "  대기           6  #601 #600 #304 #302 #301 #102"
has_line "epics issue-runner 1" "$tmp/out" "  issue-runner   1  #101"
# 파생 병기 — 이 레포는 열린 epic 라벨 이슈가 있어 `(Epic #N)`/`(에픽 없음)` 이 붙는다.
# #999 는 실존하는 에픽 목록에 없어도(참조만 있으면) 그대로 병기된다.
has_line "① 파생 2 — 에픽 병기(있으면 Epic #N, 없으면 에픽 없음)" "$tmp/out" \
  "  파생           2  #600(Epic #999) #601(에픽 없음)"
has_line "에픽 4건" "$tmp/out" "  에픽           4"
has_sub "① #100 — leaf 열림 2(issue-runner·대기)+닫힘 1 → 1/3, 버킷 분포(P 없음)" "$tmp/out" \
  "    - #100 1/3 · 진행 1 · 대기 1"
has_sub "② #200 — leaf 전부 닫힘 → 2/2, 버킷·P 분포 없음" "$tmp/out" \
  "    - #200 2/2"
has_sub "③ #300 — 열린 leaf P0+P1+과도기 P2(P1 로 접힘), 닫힌 leaf 는 무시" "$tmp/out" \
  "    - #300 1/4 · 대기 3 · P0 1 P1 2"
has_sub "④ #400 — leaf 0 → leaf 없음(Epic 줄 미부착), 비율 없음" "$tmp/out" \
  "    - #400 leaf 없음(Epic 줄 미부착)"
# ⑤ 산문 속 `epic #100`(줄 시작 아님)은 leaf 가 아니다 — #500 이 잡혔다면 #100 이 1/4 로 나온다
no_sub "⑤ 산문 속 언급이 leaf 로 잡히면 #100 총합이 1/4 가 된다(반증)" "$tmp/out" "#100 1/4"
no_sub "⑤ #500 자신도 에픽 절 어디에도 안 나온다" "$tmp/out" "#500"
has_line "warn 2건(전부 종료·P 혼재)" "$tmp/out" "  warn           2"
has_sub "② warn 에픽 leaf 전부 종료" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #200(epics) — 닫아라(에픽 스윕 대상)"
has_sub "③ warn 에픽 내 P 혼재(닫힌 leaf 의 P0 는 안 낀다)" "$tmp/out" \
  "    - 에픽 내 P 혼재 #300(epics) — P0 1 · P1 2"
no_sub "④ leaf 없는 에픽은 warn 없음" "$tmp/out" "전부 종료 #400"
no_sub "① 정상 진행 에픽은 warn 없음" "$tmp/out" "전부 종료 #100"
ck "epics: leaf 판정에 개별 이슈 조회 0(닫힌 이슈 목록에서 이미 받은 본문으로만 판정)" \
  "$(grep -c '^comments \|^timeline ' "$STUB_CALL_LOG")" 0
# 예외 ④(#441) — 전부 종료 warn 후보(#200)에만 스윕 마커 조회 1건이 나간다(leaf 판정과 무관).
ck "epics: 스윕 마커 조회는 전부 종료 후보 #200 의 1건뿐" "$(grep -c '^epic-marker ' "$STUB_CALL_LOG")" 1

run --repo ggqgga/Epics --since 24h --json
ck "⑦ --json: epics[] 형태 — #100(진행 중)" \
  "$(jq -c '.repos[0].epics[] | select(.number==100) | {n:.number,ti:.title,t:.total,c:.closed,b:.buckets,p:.priorities}' < "$tmp/out")" \
  '{"n":100,"ti":"에픽 A","t":3,"c":1,"b":{"progress":1,"waiting":1},"p":{}}'
ck "⑦ --json: epics[] 형태 — #300(P 혼재)" \
  "$(jq -c '.repos[0].epics[] | select(.number==300) | {n:.number,t:.total,c:.closed,b:.buckets,p:.priorities}' < "$tmp/out")" \
  '{"n":300,"t":4,"c":1,"b":{"waiting":3},"p":{"P1":2,"P0":1}}'
ck "⑦ --json: epics[] 형태 — #400(leaf 없음)" \
  "$(jq -c '.repos[0].epics[] | select(.number==400) | {n:.number,t:.total,c:.closed,b:.buckets,p:.priorities}' < "$tmp/out")" \
  '{"n":400,"t":0,"c":0,"b":{},"p":{}}'
ck "⑦ --json: 항목마다 repo_short" \
  "$(jq '[.repos[0].epics[] | select(.repo_short=="epics")] | length' < "$tmp/out")" 4

# ── (사전 리뷰 WARN) 에픽 라벨은 있지만 `Epic #N` 텍스트가 0건인 레포 — 파생 무병기 ──
run --repo ggqgga/EpicNoRefs --since 24h
ck "epicnorefs: exit 0" "$RC" 0
has_line "leaf 0 인 에픽 자신은 1줄 그려진다" "$tmp/out" "  에픽           1"
has_sub "leaf 없음 줄은 그대로" "$tmp/out" "    - #700 leaf 없음(Epic 줄 미부착)"
has_line "무관한 파생은 에픽 병기 없이 그대로(실제 Epic #N 텍스트가 0건)" "$tmp/out"   "  파생           1  #701"
no_sub "무관한 파생에 '(에픽 없음)' 이 잘못 붙지 않는다" "$tmp/out" "#701(에픽 없음)"

# ── ★창 밖 leaf★ (#292) — 닫힌 leaf 는 "최근 200건" 이 아니라 검색 스코프 조회에서 온다 ──
run --repo ggqgga/EpicWindow --since 24h
ck "epicwindow: exit 0" "$RC" 0
has_line "(#292) 에픽 2건" "$tmp/out" "  에픽           2"
# 본체 — leaf 3건 중 2건이 최근 200건 **밖**이고 새 조회로만 잡힌다.
has_sub "(#292) #100 — 창 밖 닫힌 leaf 2건이 세어진다(옛 경로면 0/1)" "$tmp/out" \
  "    - #100 2/3 · 대기 1"
# leaf 가 **전부** 창 밖인 에픽 — 옛 경로에서는 `leaf 없음(Epic 줄 미부착)` 이라는 사실과
# 다른 줄이 나오고 `전부 종료` warn 이 **안 떴다**. 그 warn 이 존재하는 이유가 이 상태다.
has_sub "(#292) #200 — leaf 전부 창 밖 종료: 2/2(옛 경로면 leaf 없음)" "$tmp/out" \
  "    - #200 2/2"
no_sub "(#292) #200 이 'leaf 없음' 으로 위장하지 않는다" "$tmp/out" "#200 leaf 없음"
has_sub "(#292) #200 — 전부 종료 warn 이 뜬다(옛 경로면 안 떴다)" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #200(epicwindow) — 닫아라(에픽 스윕 대상)"
no_sub "(#292) 상한에 안 닿았으니 절단 warn 없음" "$tmp/out" "창 절단 가능(에픽 닫힌 leaf)"
ck "(#292) 에픽이 있는 레포는 새 조회 1회(레포당 1회 — 에픽 수와 무관)" \
  "$(grep -c '^epic-closed ' "$STUB_CALL_LOG")" 1

# ── (#292) 조회 실패 3갈래 — 어느 것도 "닫힌 leaf 0건" 으로 접히지 않는다 ─────────
run --repo ggqgga/EpicFail --since 24h
ck "epicfail: 레포를 실패시키지 않는다(exit 0)" "$RC" 0
has_sub "(#292)⑴ 조회 실패: 비율 대신 종료 미상" "$tmp/out" \
  "    - #300 종료 미상(닫힌 leaf 조회 실패) · 대기 1"
no_sub "(#292)⑴ 조회 실패를 0/N 으로 위장하지 않는다" "$tmp/out" "#300 0/"
has_sub "(#292)⑴ 실패는 warn 으로 드러난다(사유 포함)" "$tmp/out" \
  "    - 에픽 닫힌 leaf 조회 실패(epicfail) — 종료/전체 미상: gh: HTTP 403 rate limit"
has_sub "(#292)⑴ 실패 중에도 전부 종료 warn 은 그대로(거짓 음성 방향이라 뜨면 참)" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #310(epicfail) — 닫아라(에픽 스윕 대상)"
has_sub "(#292)⑴ 실패 사유는 stderr 에도" "$tmp/err" "에픽 닫힌 leaf 조회 실패"

run --repo ggqgga/EpicSilent --since 24h
ck "epicsilent: exit 0" "$RC" 0
has_sub "(#292)⑵ 빈 출력+exit 0 을 core API 대조로 실패로 가른다" "$tmp/out" \
  "    - #400 종료 미상(닫힌 leaf 조회 실패) · 대기 1"
has_sub "(#292)⑵ 조용한 실패 사유가 warn 에 적힌다" "$tmp/out" \
  "검색 0행인데 최근 닫힌 목록엔 Epic 줄이 있다(조용한 실패)"

run --repo ggqgga/EpicBadJson --since 24h
ck "epicbadjson: exit 0" "$RC" 0
has_sub "(#292)⑶ 배열이 아닌 응답도 실패다" "$tmp/out" \
  "    - #450 종료 미상(닫힌 leaf 조회 실패) · 대기 1"
has_sub "(#292)⑶ 사유: 응답이 배열이 아님" "$tmp/out" \
  "    - 에픽 닫힌 leaf 조회 실패(epicbadjson) — 종료/전체 미상: 응답이 배열이 아님"

# ── (#292) 새 조회가 자기 상한에 닿으면 절단 warn — 종전 `닫힌 이슈` warn 의 새 자리 ──
: > "$STUB_CALL_LOG"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" EPIC_CLOSED_LIMIT=2 \
  "$SUT" --repo ggqgga/EpicCap --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "EPIC_CLOSED_LIMIT=2: exit 0" "$RC" 0
has_sub "(#292) 새 조회 상한 도달 → 절단 warn(상한 수치를 문구에 싣는다)" "$tmp/out" \
  "    - 목록 상한 2 도달 — 창 절단 가능(에픽 닫힌 leaf)"
has_sub "(#292) 상한에 닿아도 받은 행은 그대로 센다" "$tmp/out" "    - #500 2/3 · 대기 1"
no_sub "(#292) 상한 도달은 실패가 아니다(종료 미상 아님)" "$tmp/out" "#500 종료 미상"
# 형식 오류는 조용한 기본값이 아니라 환경 실패(HANDOFF_GRACE_MIN 과 같은 규율).
# `0` 은 "안 본다" 가 아니라 **0행을 돌려받는** 값이라 금지한다 — 이 이슈가 고친 증상을
# 환경변수 하나로 되살리는 경로다.
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" EPIC_CLOSED_LIMIT=0 \
  "$SUT" --repo ggqgga/EpicCap --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "EPIC_CLOSED_LIMIT=0: exit 1" "$RC" 1
has_sub "EPIC_CLOSED_LIMIT=0: stdout 에도 사유" "$tmp/out" \
  "파이프라인 — 스냅샷 실패: EPIC_CLOSED_LIMIT 형식 오류: 0"
STUB_DIR="$tmp/fx" PATH="$tmp/bin:$PATH" EPIC_CLOSED_LIMIT=천 \
  "$SUT" --repo ggqgga/EpicCap --since 24h >"$tmp/out" 2>"$tmp/err"; RC=$?
ck "EPIC_CLOSED_LIMIT 형식 오류: exit 1" "$RC" 1
has_sub "EPIC_CLOSED_LIMIT 형식 오류: stdout 에도 사유" "$tmp/out" "EPIC_CLOSED_LIMIT 형식 오류: 천"

# ── (#441) 전부 종료 warn 문구 — 스윕 마커 있음(되돌림)은 사람 몫, 없음은 스윕 대상 ────
run --repo ggqgga/EpicMark --since 24h
ck "epicmark: exit 0" "$RC" 0
has_sub "(#441) 마커 있음 + 열림 → 사람 몫(스윕 되돌림) — 종전 문구면 스윕이 닫을 것처럼 읽혔다" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #10(epicmark) — 사람 몫(스윕 되돌림: 마커 있음 — 직접 닫거나 마커 코멘트를 지워라)"
no_sub "(#441) 마커 있는 에픽에 '닫아라(에픽 스윕 대상)' 가 붙지 않는다(반증)" "$tmp/out" \
  "#10(epicmark) — 닫아라"
has_sub "(#441) 마커 없음 → 종전 문구 그대로(스윕이 닫는다)" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #11(epicmark) — 닫아라(에픽 스윕 대상)"
has_sub "(#441) 코멘트 조회 실패 → 어느 쪽이라고 단정하지 않는다" "$tmp/out" \
  "    - 에픽 leaf 전부 종료 #12(epicmark) — 스윕 대상 여부 미확인(코멘트 조회 실패)"
ck "(#441) 마커 조회는 전부 종료 후보 3건에만(열린 leaf 가 있는 #13 은 안 묻는다)" \
  "$(grep -c '^epic-marker ' "$STUB_CALL_LOG")" 3
check "(#441) #13 마커 조회 없음" \
  "$(grep -qxF "epic-marker ggqgga/EpicMark 13" "$STUB_CALL_LOG" && echo no || echo ok)"
has_sub "(#441) 조회 실패 사유는 stderr 에도" "$tmp/err" "#12 스윕 마커 코멘트 조회 실패"
# 상한 — 넘는 후보는 조회하지 않고 미확인으로 남긴다(거짓 `스윕 대상` 을 만들지 않는다).
EPIC_MARK_MAX=1 run --repo ggqgga/EpicMark --since 24h
ck "(#441) EPIC_MARK_MAX=1: 마커 조회는 1건뿐" "$(grep -c '^epic-marker ' "$STUB_CALL_LOG")" 1
has_sub "(#441) EPIC_MARK_MAX=1: 상한 밖 후보는 미확인(조회 상한)" "$tmp/out" \
  "(epicmark) — 스윕 대상 여부 미확인(조회 상한(1) 초과)"

# ── (#327) 전용 줄 끝 앵커 — 문장형 `Epic #N …` 은 leaf 가 아니다 ──────────
run --repo ggqgga/EpicAnchor --since 24h
ck "epicanchor: exit 0" "$RC" 0
has_line "에픽 3건(#810 · #800 · #1)" "$tmp/out" "  에픽           3"
# 걸러야 할 것 — 닫힌 이슈 3건이 전부 문장형이라 leaf 0. 앵커가 없으면 `#800 3/3` 이 되고
# `에픽 leaf 전부 종료 #800` warn(스윕이 닫을 대상)이 붙는다 = 이 이슈가 지목한 오종료.
has_sub "① #800 문장형 언급만 → leaf 0" "$tmp/out" "    - #800 leaf 없음(Epic 줄 미부착)"
no_sub "①-a 『Epic #800 설명』·『(부모)』·『:』 이 leaf 로 새면 3/3 이 된다(반증)" "$tmp/out" "#800 3/3"
no_sub "①-b 문장형만 달린 에픽에 '전부 종료' warn 이 붙으면 안 된다(반증)" "$tmp/out" \
  "에픽 leaf 전부 종료 #800"
# 걸러선 안 될 것 — 전용 줄 3형태(그대로·앞뒤 공백+소문자·대문자)는 전부 leaf
has_sub "② #810 전용 줄 3형태는 전부 leaf" "$tmp/out" "    - #810 0/3 · 대기 3"
# 숫자 경계 — 한 자리 에픽은 세고, 뒤에 다른 번호가 붙은 줄과 접두 오매치는 안 센다
has_sub "③ #1 한 자리 에픽 — leaf 1" "$tmp/out" "    - #1 0/1 · 대기 1"
no_sub "③-a 『Epic #1 #2』 가 leaf 로 새면 #1 이 0/2 가 된다(끝 앵커 반증)" "$tmp/out" "#1 0/2"
# 접두 오매치(#816 `Epic #10`)는 여기서 **단언하지 않는다** — 번호를 수로 뽑아 비교하는 한
# `Epic #10` 은 에픽 #10 이라 #1 의 총합에 닿는 경로 자체가 없다(끝 앵커·자릿수 어느 쪽을
# 되돌려도 안 뒤집힌다). 무는 게 없는 단언을 "반증" 이라 적으면 다음 사람이 그 자리를
# 안 의심한다 — 픽스처는 남겨 두되(에픽 목록에 없는 번호가 조용히 무시되는 것까지가 정상),
# 반증은 실제로 뒤집히는 ③-a 하나로 둔다.

# ── 무회귀 — bodat(`Epic #N` 이 하나도 없는 픽스처)은 에픽 절(0줄) 추가 외엔 그대로 ──
run --repo ggqgga/BodaT --since 24h
has_line "무회귀: bodat 에픽 0줄" "$tmp/out" "  에픽           0"
# (#292) 열린 에픽이 0건인 레포는 새 조회를 **아예 안 한다** — 에픽 절이 없는 레포의 틱
# 비용을 늘리지 않는다(방식 (가)의 "N=0 이면 0회" 성질을 O(1) 로 유지한 것).
ck "(#292) 에픽 0건 레포: 추가 gh 호출 0회" \
  "$(grep -c '^epic-closed ' "$STUB_CALL_LOG")" 0
has_line "무회귀: 파생 줄은 에픽 병기 없이 종전 그대로(레포에 열린 에픽이 없다)" \
  "$tmp/out" "  파생           1  #4832"
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
#   #108 無 / PR #1108 有 **warn** — head 는 `agent/issue-109` 인데 closes 는 `[108]`(head 의 N
#                          이 목록 밖 · closes 1건). 짝은 `lib/loop.jq` `linked_issue` 규칙⑵ 로
#                          #108 — pr-state 의 `stop:` 축·resume-sweep ④ 와 같은 답(#517)
#
# 짝짓기는 `closingIssuesReferences[0]` 이 아니라 **head 의 `agent/issue-N` ∩ closes** 다
# (이 레포 실데이터: PR #113 head=`agent/issue-109` refs=`[108,109]` — `[0]` 은 #108 이다).
# 그리고 경보는 **closes 전건이 깨끗할 때만** 낸다 — 교정(resume-sweep ④)이 그 조건에서만
# 편집하므로, 여기서 더 울리면 조치 불가능한 잡음이고 덜 울리면 교정이 몰래 돈다.
#   #90 無 / PR #190 有   **warn** — closes 가 `[99, 90]`(순서 역전). 짝은 `[0]`(#99)이
#                          아니라 브랜치의 이슈 #90 이다
#   #91 無 / PR #191 有   warn 없음 — 같은 PR 이 닫는 #98 에 `hold:policy` 가 살아 있다
#                          (묶음 디스패치 — 전이는 이슈 인자를 하나만 받는다)
#
# 맨몸 `needs-human`(= `hold:` 접두가 **하나도 없음**)은 짝짓기·전건 게이트를 다 통과해도
# 대상 밖이다. 기계는 그 모양을 만들 수 없다 — `needs-human` 을 붙이는 자리는
# `transition.sh` 하나뿐이고 기계 정지 세 전이는 `--reason` 이 **필수**라 언제나
# `hold:<사유>` 와 쌍으로 붙인다. 그러니 PR 에만 맨몸으로 있다 = 사람이 머지 직전에 손으로
# 세운 브레이크이고, 교정 갈래(resume-sweep ④)는 그것을 떼지 않는다. 여기서만 울리면
# "고쳐 준다" 고 말해 놓고 안 고치는 줄이 상시로 남는다(#190).
#   #92 無 / PR #192 有   warn 없음 — 짝도 서고 closes 전건도 깨끗한데 PR 정지가 맨몸
#                          `needs-human` 뿐이다. 위 #170 과 달리 head 는 `agent/issue-92` 라
#                          **이 관문 하나만** 이 칸을 조용하게 만든다(짝짓기로는 안 걸린다)
#
# (#331 쌍둥이 정합) ⑶ 전건 게이트의 판정 집합은 **열린 이슈 ∪ 닫힌 이슈**다. 교정 갈래
# (`resume-sweep.sh` 의 `read_labels_state`)는 닫는 이슈를 번호로 실제 조회해 CLOSED 도
# 판정하므로, 여기가 열린 목록만 보면 두 술어가 갈린다 — 경보는 "안 고친다" 고 말하는데
# 교정은 몰래 도는 상태다(#293 마감 검증 WARN 의 실측 픽스처가 바로 아래 #93 이다).
#   #93 無 / PR #193 有   **warn** — closes `[93 OPEN 깨끗, 97 CLOSED 깨끗]`. 닫힌 쪽도
#                          깨끗하므로 스윕은 편집한다 → 경보도 울려야 한다
#   #94 無 / PR #194 有   warn 없음 — closes `[94 OPEN 깨끗, 96 CLOSED hold:policy]`.
#                          닫힌 이슈에 사람 게이트가 살아 있어 스윕도 무편집이다
#                          (`read_labels_state` 는 상태를 판정에 쓰지 않는다)
#   #95 無 / PR #195 有   warn 없음 — closes `[95 OPEN 깨끗, 9999 어느 목록에도 없음]`.
#                          남는 비대칭(각 200건 상한 절단 — 둘 중 어느 목록에도 없는 번호)을
#                          못 박는 칸이다: "못 봤다" 는 조용한 쪽으로 틀린다. 타 레포 참조는
#                          비대칭이 **아니다** — 부재가 아니라 동번호 로컬 이슈와의 충돌로
#                          나타나고 교정 갈래도 같은 레포 같은 번호를 묻는다(`loop-status.sh`
#                          ⑶ 주석과 같은 문장)
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Mirror.issues.json" <<'FX'
[
 {"number":10,"title":"둘 다 정지 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":20,"title":"PR 에만 정지 라벨이 남았다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":30,"title":"양쪽 다 정지","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":40,"title":"이슈에만 정지","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"},{"name":"needs-human"},{"name":"hold:ladder"}]},
 {"number":50,"title":"PR 에 hold 만 남았다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":70,"title":"사람 세션 PR 이 달린 이슈","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":80,"title":"Refs 전용 PR 이 달린 이슈","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":90,"title":"closes 순서 역전 PR 의 브랜치 이슈","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":99,"title":"같은 PR 이 닫는 딴 이슈 — 정지 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"}]},
 {"number":91,"title":"묶음 디스패치의 브랜치 이슈 — 정지 없음","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":98,"title":"묶음 디스패치의 딴 이슈 — 사람 게이트가 살아 있다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"hold:policy"}]},
 {"number":92,"title":"맨몸 needs-human 이 PR 에만 — 사람이 손으로 세운 브레이크","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:ready"}]},
 {"number":93,"title":"닫힌 짝 이슈가 깨끗하다 — 스윕이 고치는 칸","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":94,"title":"닫힌 짝 이슈에 사람 게이트가 살아 있다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":95,"title":"닫는 이슈 하나가 어느 목록에도 없다","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]},
 {"number":108,"title":"head 의 N 이 closes 밖인 PR 의 유일한 closes","createdAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"flow:verify"}]}
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
  "closingIssuesReferences":[],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]},
 {"number":190,"headRefName":"agent/issue-90","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":99},{"number":90}],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]},
 {"number":191,"headRefName":"agent/issue-91","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":91},{"number":98}],"labels":[{"name":"flow:verify"},{"name":"needs-human"}]},
 {"number":192,"headRefName":"agent/issue-92","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":92}],"labels":[{"name":"flow:ready"},{"name":"needs-human"}]},
 {"number":193,"headRefName":"agent/issue-93","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":93},{"number":97}],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]},
 {"number":194,"headRefName":"agent/issue-94","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":94},{"number":96}],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]},
 {"number":195,"headRefName":"agent/issue-95","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":95},{"number":9999}],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]},
 {"number":1108,"headRefName":"agent/issue-109","state":"OPEN","mergedAt":null,"closedAt":null,"createdAt":"@NOW@",
  "closingIssuesReferences":[{"number":108}],"labels":[{"name":"flow:verify"},{"name":"hold:policy"}]}
]
FX
echo '[]' > "$tmp/fx/ggqgga_Mirror.pr_closed.json"
# (#331) 닫힌 이슈 — ⑶ 전건 게이트가 **실제로** 이 목록을 본다는 것의 실측 입력.
# #97 은 깨끗(→ PR #193 이 warn) · #96 엔 사람 게이트가 살아 있다(→ PR #194 는 조용).
sed "s/@NOW@/$NOW/g" > "$tmp/fx/ggqgga_Mirror.issues_closed.json" <<'FX'
[
 {"number":96,"body":"","closedAt":"@NOW@","labels":[{"name":"agent-ready"},{"name":"needs-human"},{"name":"hold:policy"}]},
 {"number":97,"body":"","closedAt":"@NOW@","labels":[{"name":"agent-ready"}]}
]
FX

run --repo ggqgga/Mirror --since 24h
ck "(#265) 격자: exit 0" "$RC" 0
has_line "(#265·#331·#517) 새 판정이 낸 줄은 정확히 5건(오탐 0)" "$tmp/out" "  warn           5"
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
# 짝은 `closes[0]` 이 아니라 **head 의 N** 이다 — 순서가 역전된 PR 에서 갈린다.
has_line "(#265) closes 순서 역전 — 짝은 브랜치의 이슈(#90)" "$tmp/out" \
  "    - 정지 미러 불일치 #90(mirror) ↔ PR #190(mirror) — 이슈 없음 · PR hold:policy"
no_sub "(#265) [0] 쪽(#99)을 짝으로 고르지 않는다" "$tmp/out" "불일치 #99"
# 묶음 디스패치 — 짝(#91)이 깨끗해도 같은 PR 이 닫는 #98 의 사람 게이트가 살아 있다.
# 여기서 울리면 교정(resume-sweep ④)이 안 하는 일을 경보가 하라고 말하는 꼴이다.
no_sub "(#265) 묶음 디스패치의 딴 이슈에 정지가 있으면 조용하다" "$tmp/out" "불일치 #91"
no_sub "(#265) 정지가 남은 #98 자신도 후보가 아니다" "$tmp/out" "불일치 #98"
# 맨몸 `needs-human` — 짝짓기(⑴⑵)·전건 게이트(⑶)를 다 통과하는 칸이라 **이 관문만**이
# 조용하게 만든다. 교정 갈래가 안 떼는 것을 경보만 울리면 상시 잡음이다(#190).
no_sub "(#265) 맨몸 needs-human(PR #192)은 warn 이 아니다 — 기계가 못 만드는 모양" \
  "$tmp/out" "불일치 #92"
# (#331 쌍둥이 정합) ⑶ 전건 게이트는 **닫힌 이슈도** 본다 — 교정 갈래(resume-sweep ④)의
# `read_labels_state` 가 번호로 실제 조회해 CLOSED 를 판정하므로, 여기가 열린 목록만 보면
# 경보는 "안 고친다" 고 말하는데 교정이 몰래 도는 상태가 된다(#293 마감 검증 WARN 의 실측).
has_line "(#331) 닫힌 짝 이슈가 깨끗하면 경보도 울린다(교정 갈래와 같은 판정)" "$tmp/out" \
  "    - 정지 미러 불일치 #93(mirror) ↔ PR #193(mirror) — 이슈 없음 · PR hold:policy"
no_sub "(#331) 닫힌 이슈에 사람 게이트가 살아 있으면 조용하다 — 스윕도 무편집" \
  "$tmp/out" "불일치 #94"
no_sub "(#331) 닫는 이슈가 어느 목록에도 없으면 조용하다 — '못 봤다' 는 조용한 쪽으로" \
  "$tmp/out" "불일치 #95"
# (#517 정지 미러 술어 정합) 짝은 `lib/loop.jq` `linked_issue` 다 — head 의 N 이 closes 에 없어도
# closes 가 1건이면 그것(규칙⑵). pr-state 의 `stop:` 축이 #108 을 보고 warn 을 내고 교정 갈래
# (resume-sweep ④)도 #108 을 짝으로 편집하므로, 여기가 짝 없음으로 조용하면 셋이 갈린다.
has_line "(#517) head 의 N ∉ closes · closes 1건 — 짝은 closes 의 #108" "$tmp/out" \
  "    - 정지 미러 불일치 #108(mirror) ↔ PR #1108(mirror) — 이슈 없음 · PR hold:policy"
# 단계 미러 판정은 정지 라벨에 오염되지 않는다 — 정지 라벨을 mirror_labels 에 밀어 넣었다면
# #20·#50 이 **단계** 미러 불일치로도 울렸을 자리다(별도 판정이라는 것의 실측).
no_sub "(#265) 정지 라벨이 단계 미러 판정을 깨뜨리지 않는다" "$tmp/out" "- 미러 불일치 #20"
no_sub "(#265) 정지 라벨이 단계 미러 판정을 깨뜨리지 않는다(#50)" "$tmp/out" "- 미러 불일치 #50"
# `--json` 면에도 같은 사실이 실린다(후속 도구가 문자열 파싱을 안 하게)
run --repo ggqgga/Mirror --since 24h --json
ck "(#265) --json: kind·issue·pr·labels" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="hold_mirror_mismatch") | {i:.issue, p:.pr, l:.labels}]' < "$tmp/out")" \
  '[{"i":20,"p":120,"l":["hold:policy","needs-human"]},{"i":50,"p":150,"l":["hold:conflict"]},{"i":90,"p":190,"l":["hold:policy"]},{"i":93,"p":193,"l":["hold:policy"]},{"i":108,"p":1108,"l":["hold:policy"]}]'

# ── ⑰ (#282) PR 미러 6쌍 · 대기/issue-runner 줄 PR 첨부 · 무소속 warn 은 라벨 0 PR 만 ──
run --repo ggqgga/Mirror6 --since 24h
ck "mirror6: exit 0" "$RC" 0
has_line "mirror6 헤더 — 열림 12" "$tmp/out" \
  "파이프라인 mirror6 — 열림 12 · 스코프 mirror6 · 창 24h"
# 수용 기준 1 — flow:agent-ready PR + 이슈 agent-ready 만 → 대기 줄에 PR 이 붙는다. #32(PR 은 아직
# flow:claimed)는 재claim 대기 모양 — 같은 줄에 붙고 warn 이 아니다(resume-sweep 은 PR 에서 hold 만 뗀다).
has_line "(#282) 대기 줄 — flow:agent-ready PR 과 재claim 대기(flow:claimed) PR 이 ← PR #n 으로" "$tmp/out" \
  "  대기           2  #32 ← PR #132 #10 ← PR #110"
# 수용 기준 2·4 — flow:claimed PR 은 창과 무관하게 issue-runner 줄, 라벨 0 PR 은 종전 창 규칙(인계 전).
has_line "(#282) issue-runner 줄 — flow:claimed PR 은 창 밖(#20)·재디스패치(#21)·방금(#22) 다 붙고, 라벨 0 은 창 안만 인계 전" "$tmp/out" \
  "  issue-runner   7  #60 #41 #40 ← PR #140(인계 전) #31 #22 ← PR #122 #21 ← PR #121 #20 ← PR #120"
has_line "(#282) 검증대기 줄은 종전대로 연결 PR 병기(라벨 무관)" "$tmp/out" "  검증대기       1  #30 ← PR #130"
has_line "(#282) 보류 2 — 정지 중인 두 모양(runner-held·verify-held)" "$tmp/out" \
  "  보류           2  #51(policy, PR #151) #50(ladder, PR #150)"
# warn — 미러 불일치 3(양방향 + 워커 칸) · 사망 의심 1(#20, 경과 기준) · 무소속 1(#41, 라벨 0 대조군)
has_line "(#282) warn 5 — 그 밖(#10·#21·#22·#32·#40·#50·#51)은 조용" "$tmp/out" "  warn           5"
has_sub "(#282) 수용 기준 3 — flow:claimed PR 인데 이슈 flow:verify" "$tmp/out" \
  "    - 미러 불일치 #30(mirror6) ↔ PR #130(mirror6) — 이슈 flow:verify · PR flow:claimed"
has_sub "(#282) 수용 기준 3 반대 방향 — 이슈 agent:claimed 인데 PR flow:verify" "$tmp/out" \
  "    - 미러 불일치 #31(mirror6) ↔ PR #131(mirror6) — 이슈 agent:claimed · PR flow:verify"
# 이슈 대기 칸 + PR flow:claimed 는 재claim 대기(홀드 해제·죽은 워커 claim 회수 뒤) — 다음 claim 이 수렴시키는
# 설계된 모양이라 warn 이 아니다. 디스패치가 밀리는 몇 시간 동안 상시 warn 이 되면 #282 가 걷어내려던 잡음이다.
no_sub "(#282) 재claim 대기 모양(#32: 이슈 agent-ready 만 · PR flow:claimed)은 미러 불일치가 아니다" "$tmp/out" "미러 불일치 #32"
has_sub "(#282) claim 미러 실패(이슈 agent:claimed · PR flow:agent-ready) 도 불일치" "$tmp/out" \
  "    - 미러 불일치 #60(mirror6) ↔ PR #160(mirror6) — 이슈 agent:claimed · PR flow:agent-ready"
# 수용 기준 2 — 창 밖이어도 무소속 warn 은 없고, 사망 의심은 claim 경과 기준의 **별도** warn.
no_sub "(#282) flow:claimed PR #120 은 창 밖이어도 무소속이 아니다" "$tmp/out" "무소속 PR #120"
has_line "(#282) 사망 의심 warn — 경과 기준(claim 200분)" "$tmp/out" \
  "    - 워커 사망 의심 #20(mirror6) ← PR #120(mirror6) — agent:claimed 인데 200분 경과"
# 재디스패치(#21) — PR 은 240분 전이지만 claim 은 5분 전. PR 나이로 울리면 #177 의 오탐이 되살아난다.
no_sub "(#282) 재디스패치 #21 은 사망 의심이 아니다(claim 5분)" "$tmp/out" "사망 의심 #21"
no_sub "(#282) #21 PR 나이(240분)로 재지 않는다" "$tmp/out" "240분 경과"
# 수용 기준 3 — 무소속 warn 은 라벨 0 PR 만: flow:claimed·flow:agent-ready PR 은 후보가 아니다.
no_sub "(#282) flow:claimed PR 은 무소속 후보가 아니다(#130)" "$tmp/out" "무소속 PR #130"
no_sub "(#282) flow:claimed PR 은 무소속 후보가 아니다(#132)" "$tmp/out" "무소속 PR #132"
no_sub "(#282) flow:agent-ready PR 은 무소속 후보가 아니다(#160)" "$tmp/out" "무소속 PR #160"
no_sub "(#282) flow:agent-ready PR 은 무소속 후보가 아니다(#110)" "$tmp/out" "무소속 PR #110"
# 수용 기준 4 — 라벨 0 PR 은 종전 그대로: 창 안은 인계 전(warn 아님), 창 밖은 무소속 warn + 사망 의심.
no_sub "(#282) 라벨 0 창 안 PR #140 은 warn 아님" "$tmp/out" "무소속 PR #140"
has_line "(#282) 라벨 0 창 밖 PR #141 은 종전 무소속 warn + 사망 의심" "$tmp/out" \
  "    - 무소속 PR #141(mirror6) — 열린 agent PR 인데 단계 라벨 0 · 연결 이슈 #41 도 정지 라벨 없음(agent:claimed 인데 200분 경과 — 워커 사망 의심)"
# 정지는 직교 — 홀드 전이는 이슈의 agent:claimed 만 떼고 PR 의 flow:claimed 는 둔다(runner-held).
# 정지 중인 이슈에 워커 칸 두 쌍을 대조하면 홀드된 건마다 상시 warn 이 된다.
no_sub "(#282) runner-held 모양(#50: 이슈 hold · PR flow:claimed)은 미러 불일치가 아니다" "$tmp/out" "미러 불일치 #50"
no_sub "(#282) verify-held 모양(#51: 이슈 agent-ready 만 · PR 단계 0)은 미러 불일치가 아니다" "$tmp/out" "미러 불일치 #51"
no_sub "(#282) 정지 중인 PR 은 무소속도 아니다(#151)" "$tmp/out" "무소속 PR #151"
# 타임라인 조회는 창 밖 후보에만 — #22(PR 방금)는 픽스처가 없어 조회하면 스텁이 exit 1 로 드러난다.
ck "(#282) 타임라인 조회는 #20·#21·#41 셋뿐(창 안 #22 는 안 본다)" \
  "$(grep '^timeline ' "$STUB_CALL_LOG" | sort | tr '\n' ' ')" \
  "timeline ggqgga/Mirror6 20 timeline ggqgga/Mirror6 21 timeline ggqgga/Mirror6 41 "

# 수용 기준 5 — `--json` 의 buckets.waiting[].pr · buckets.claimed[].pr 에 PR 번호.
run --repo ggqgga/Mirror6 --since 24h --json
ck "(#282) --json: waiting[].pr — 일치하는 PR 만 번호, 아니면 null" \
  "$(jq -c '[.repos[0].buckets.waiting[] | {n:.number, p:.pr}]' < "$tmp/out")" \
  '[{"n":32,"p":132},{"n":10,"p":110}]'
ck "(#282) --json: claimed[].pr — flow:claimed 는 번호(handoff_pending false), 인계 전은 번호+true, 나머지 null" \
  "$(jq -c '[.repos[0].buckets.claimed[] | {n:.number, p:.pr, h:.handoff_pending}]' < "$tmp/out")" \
  '[{"n":60,"p":null,"h":false},{"n":41,"p":null,"h":false},{"n":40,"p":140,"h":true},{"n":31,"p":null,"h":false},{"n":22,"p":122,"h":false},{"n":21,"p":121,"h":false},{"n":20,"p":120,"h":false}]'
ck "(#282) --json: 사망 의심 warn 은 별도 kind 에 분(정수)" \
  "$(jq -c '[.repos[0].warns[] | select(.kind=="worker_stale") | {i:.issue, p:.pr, m:.claimed_minutes}]' < "$tmp/out")" \
  '[{"i":20,"p":120,"m":200}]'

# ── --post 대시보드(#163) ──────────────────────────────────────────────────
fx="$tmp/fx/ggqgga_issue-runner"
rm -f "$fx.dash.num" "$fx.dash.body" "$fx.dash.comments.json"
run --repo ggqgga/issue-runner --post issue-runner --delta "정리 1 · 보수 0 · 신규 2 · 대기(사람 리뷰) 0 · warn 1"
check "post: exit 0" "$([ "$RC" = 0 ] && echo ok || echo no)"
check "post: 없으면 생성+pin" "$(grep -q 'dash-create' "$STUB_CALL_LOG" && grep -q 'dash-pin ggqgga/issue-runner 900' "$STUB_CALL_LOG" && echo ok || echo no)"
check "post: 본문 마커 첫 줄" "$(head -1 "$fx.dash.body" | grep -q '<!-- loop-dashboard -->' && echo ok || echo no)"
check "post: 본문엔 루프별 틱 줄 없음(코멘트로 이동)" "$(grep -q '^- issue-runner:' "$fx.dash.body" && echo no || echo ok)"
check "post: 스냅샷 블록 포함" "$(grep -q '^파이프라인 runner' "$fx.dash.body" && echo ok || echo no)"
# (#276) 읽는 법 — 사다리에 `verifying` 이 들어가고, 9줄이 무슨 라벨인지 한 줄 요약이 있다.
check "post: 읽는 법의 사다리에 verifying" "$(grep -qF -- '`flow:verify`→`verifying`→`flow:ready`' "$fx.dash.body" && echo ok || echo no)"
check "post: 9줄 라벨 요약 한 줄" "$(grep -qF -- 'issue-runner(`agent:claimed`) · 검증대기(`flow:verify`) · verify-runner(`verifying`) · 마감대기(`flow:ready`) · closeout(`harvesting`) · 보류(' "$fx.dash.body" && echo ok || echo no)"
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
