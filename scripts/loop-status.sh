#!/usr/bin/env bash
# 파이프라인 스냅샷 — "지금 무엇이 걸려 있는가" 를 레포별 블록으로 찍는다 (#144).
#
# 세 루프(issue-runner·verify-runner·closeout)의 ④ Report 는 "이 틱에 한 일" 카운터뿐이라
# 파이프라인에 무엇이 쌓여 있는지는 아무도 안 본다. 이 스크립트는 **GitHub 라벨·PR 상태만
# 읽어**(로컬 상태 파일 없음 · 쓰기 0 — 순수 읽기) 그 재고를 찍는다. 세 루프가 ④ Report 끝에
# 이 출력을 그대로 붙이고, 사람도 손으로 친다.
#
# 사용: loop-status.sh [--repos-file <경로>] [--repo <owner/repo>]... [--since <N>h|<N>d] [--json]
#   스코프: --repo 가 있으면 그것들, 없으면 --repos-file (기본 `$PWD/.loop/repos` —
#           형식은 eligible-issues.sh 와 같다: 줄당 owner/repo, `#` 주석·빈 줄 허용).
#           둘 다 없으면 usage exit 64.
#   --since: "실패"·"파생" 창 (기본 24h). `<N>h` 또는 `<N>d` 만 — 그 외는 usage exit 64
#            (조용히 창 0 이 되는 걸 막는다).
#   --json : 사람용 블록 대신 같은 내용의 JSON 한 덩어리(테스트·후속 도구용).
#
# ★버킷 정의 — 이 주석이 SSOT★ (스킬 문서가 산문 대신 여기를 가리킨다)
#
#   `agent-ready` 는 사다리 전체에서 유지되는 **자격** 라벨이고, 사다리(단계) 라벨은
#   `agent:claimed` → `flow:verify` → `flow:ready` → `harvesting` 중 **정확히 하나 이하**다
#   (전이 표 SSOT = transition.sh 상단). `needs-human` 은 직교하는 일시정지 플래그 —
#   붙어 있으면 eligible-issues.sh 가 서버 쿼리에서 빼므로 루프가 안 집는다.
#   PR 쪽 라벨은 이슈 단계의 미러이고, `flow:ci`·`flow:codex` 는 PR 에만 있는 워커 내부
#   단계라 이슈 미러가 없다(=미러 불일치 판정에 참여하지 않는다).
#
#   이슈는 OPEN 기준. **한 이슈는 한 버킷** — 위에서 아래로 첫 매칭:
#     1. 배포대기 — `deploy-wait` 라벨, 또는 **사다리 라벨이 0개일 때만** 제목이
#                  `배포 대기`/`배포 검증` 으로 시작(라벨 도입 전 폴백).
#                  실측 BoDAT 은 두 형식이 섞여 있고 콜론 앞 공백도 들쭉날쭉이라
#                  `^배포 (대기|검증)` 로 본다 — 콜론을 앵커로 걸지 않는다
#                  (`배포 대기 (승격만) — …` 형태가 실존). `배포 검증:` 을 놓치면 그
#                  이슈가 needs-human 을 달고 있어 사람대기로 오분류된다.
#                  사다리 게이트가 필요한 이유: 제목만 보면 아직 구현·검증이 도는
#                  이슈(`flow:verify` 등)가 배포대기로 새어 "배포만 기다린다"로 읽힌다.
#     2. 사람대기 — `needs-human` (괄호는 `<사다리 위치>, <사유>[, PR #n]` — 사유는
#                  `hold:*` 라벨의 접미(`conflict`·`policy`·`ladder`; 플랜 §2). 여러 개면
#                  정렬해 `, ` 로 잇는다. `hold:*` 가 하나도 없으면 `사유 없음` 을 적고
#                  warn `needs-human 사유 없음` 을 올린다.)
#     3. 마감중   — `harvesting`
#     4. 마감대기 — `flow:ready`
#     5. 검증대기 — `flow:verify`
#     6. 구현중   — `agent:claimed`
#     7. 대기     — `agent-ready` 만
#   사다리 라벨이 2개 이상이면 **가장 뒤 단계**로 분류하고 warn "단계 라벨 중복".
#   위 어느 라벨도 없는 열린 이슈는 루프 밖 — 세지 않는다(무소속 PR 의 연결 이슈일 때만
#   warn 문구에 등장). `열림 N` = 1~7 버킷의 합이지 레포의 열린 이슈 총수가 아니다.
#
#   창(`--since`) 안에서만 세는 세 줄 — 버킷이 아니라 교차 집계다(같은 이슈가 위 버킷과
#   중복 등장할 수 있다):
#     실패     — head 가 `agent/issue-*` 인 PR 이 `closedAt` 창 안 + `mergedAt` null +
#                PR 라벨에 `dup` 없음
#     중복종료 — 같은 조건인데 PR 라벨에 `dup` 이 있는 것(closeout 이 "이미 main 에
#                고쳐진 중복" 으로 닫은 건 — 플랜 §3). 판정은 **PR 라벨**이지 코멘트
#                마커가 아니다. 실패에서 **빼고** 이 줄로 옮긴다 — 두 줄에 겹쳐 세지
#                않는다("실패 N" 이 중복 종료로 부풀면 루프가 망가진 것처럼 읽힌다).
#     파생     — `createdAt` 창 안 + `spinoff` 라벨인 열린 이슈
#                (라벨 도입 전 이슈는 못 잡는다 — 제목 휴리스틱을 쓰지 않는다)
#
#   승격 대기 — `repos/<repo>/branches/release` 가 있으면
#     `compare/release...<기본브랜치>` 의 `ahead_by`. release 가 없으면 `승격 대기 —`.
#     (closeout ④ Report 는 같은 수를 `git rev-list` 로 세지만, 이 스크립트는 로컬
#      체크아웃에 의존하지 않는다.)
#
# ★warn 정의 — 불변식 위반. **보고만 하고 교정하지 않는다**★
#   · 무소속 PR      — 열린 PR + (head `agent/issue-*` 또는 연결 이슈 있음) + PR 라벨에
#                      flow:ci·flow:codex·flow:verify·flow:ready·harvesting 이 하나도 없고
#                      연결 이슈가 needs-human 이 아님 → 어느 루프도 안 문다.
#                      **인계 전 창(플랜 §5)**: 그 후보 중 연결 이슈가 `agent:claimed` 이고
#                      PR `createdAt` 이 지금으로부터 `HANDOFF_GRACE_MIN`(기본 90) 분 미만인
#                      것은 warn 이 아니라 **구현중 줄**에 `← PR #n(인계 전)` 으로 붙는다 —
#                      디스패치 직후 워커가 PR 을 열고 아직 단계 라벨을 못 찍은 정상 구간이
#                      매 틱 warn 으로 울리는 걸 막는다. 창을 넘기면 같은 후보가 무소속 warn
#                      으로 나오되 `(agent:claimed 인데 <N>분 경과 — 워커 사망 의심)` 이
#                      덧붙는다. 후보 집합 하나를 둘로 **분할**하므로 표시와 warn 은 항상
#                      서로 배타다(두 조건을 따로 쓰면 드리프트한다).
#   · needs-human 사유 없음
#                    — **사람대기 버킷** 이슈에 `hold:*` 라벨이 하나도 없음. 사유 없는
#                      needs-human 은 사람이 무엇을 판단해야 하는지 아무도 모르는 쓰레기통이
#                      된다(플랜 §2). 버킷 기준인 이유: `deploy-wait` 가 이겨 배포대기로 가는
#                      needs-human 이슈는 루프 전이가 만든 게 아니라 사람이 손으로 붙인 것이라
#                      이 불변식 밖이다.
#   · 단계 라벨 중복 — 이슈에 사다리 라벨 2개 이상.
#   · 미러 불일치    — 이슈와 **열린** 연결 PR 의 {flow:verify, flow:ready, harvesting}
#                      집합이 다름. 연결 PR 이 없으면 대조할 상대가 없으니 warn 아님.
#   · 좌초형(#117)   — 이슈에 사다리 라벨은 있는데 `agent-ready` 가 없음(디스패치 자격 상실).
#   · 목록 절단      — 이슈·열린 PR·닫힌 PR 중 어느 목록이 `--limit 200` 상한에 닿음.
#                      창 안의 실패·파생이 조용히 잘렸을 수 있다는 신호(수를 믿지 말 것).
#   · 연결 이슈 종료 — 열린 PR 인데 연결 이슈가 CLOSED. `Refs` 부분착지면 정상 — 사실만 한 줄.
#                      (연결 이슈의 OPEN 여부는 이미 받은 열린 이슈 목록의 멤버십으로 본다 —
#                       이슈마다 `gh issue view` 를 치지 않는다. 목록 상한 200 밖의 열린
#                       이슈는 CLOSED 로 오인될 수 있다.)
#
# ★조회 실패 처리★ 이슈/PR 목록 조회가 실패한 레포는 블록 대신
#   `파이프라인 <short> — 조회 실패: <사유>` 한 줄만 찍고 다음 레포로 계속하며, 최종 exit 는
#   1(부분 실패). release/compare 조회 실패는 레포를 실패로 만들지 않고 `승격 대기 —` 로
#   degrade 한다(release 미존재와 같은 표기 — 둘 다 "셀 수 없음").
#
# ★환경 변수★ `HANDOFF_GRACE_MIN` — 인계 전 창(분, 기본 90, 0 이상 정수). 형식이 틀리면
#   환경 실패로 죽는다(jq 에 그대로 넘겨 레포별 "집계 실패" 로 위장되지 않게). `0` 은 허용 —
#   창이 없으면 warn 이 **늘어나지** `--since 0h` 처럼 거짓 "깨끗함" 이 되지 않는다.
#
# ★환경 실패 처리★ 레포와 무관한 실패(창 시각 계산 불가·jq 부재·집계/렌더/직렬화 jq 실패)는
#   **stdout 에도** `파이프라인 — 스냅샷 실패: <사유>` 한 줄을 남기고 exit 1 한다. 세 루프는
#   이 출력을 ④ Report 에 그대로 붙이므로, stderr 로만 말하면 사유가 사라지고 exit 1 이
#   "레포 하나 조회 실패"(부분 실패)와 구분되지 않는다.
#
# gh 호출 예산: 레포당 이슈 목록 1 + PR 목록(open/closed) 2 + release 확인 1 + 기본 브랜치 1
# + compare 1 = 최대 6. 이슈·PR **개별** `gh view` 는 금지(N+1). `gh search` / `gh issue list
# --search` 도 금지 — 인덱스 지연 + 부정 라벨 오파싱(#21, eligible-issues.sh 주석 참조).
# 라벨 필터는 전부 jq 로 한다. 목록은 `--limit 200` 상한 — `--since` 를 크게 잡으면
# (예 30d) 닫힌 PR 이 상한에 잘려 "실패" 가 조용히 누락될 수 있다.
set -uo pipefail

SELF=$(basename "$0")

usage() {
  {
    echo "usage: $SELF [--repos-file <경로>] [--repo <owner/repo>]... [--since <N>h|<N>d] [--json]"
    echo "  스코프: --repo 가 있으면 그것들, 없으면 --repos-file (기본 \$PWD/.loop/repos)."
    echo "          둘 다 없으면 이 도움말(exit 64)."
    echo "  --since: 실패·파생 창. <N>h 또는 <N>d 만 (기본 24h)."
    echo "  --json : 사람용 블록 대신 JSON 한 덩어리."
    echo "  env HANDOFF_GRACE_MIN: 인계 전 창(분, 기본 90). 그 안의 agent:claimed PR 은"
    echo "          무소속 warn 대신 구현중 줄에 '← PR #n(인계 전)'."
  } >&2
  exit 64
}

# 환경 실패(레포 무관)는 stdout 에도 남긴다 — 루프가 붙이는 건 stdout 이라, stderr 로만
# 말하면 exit 1 이 "부분 실패"와 구분되지 않고 사유가 통째로 사라진다.
snapshot_fail_line() {
  echo "파이프라인 — 스냅샷 실패: $1"
  echo "$SELF: $1" >&2
}
snapshot_abort() { snapshot_fail_line "$1"; exit 1; }

repos=()
repos_file=""
repos_file_given=0
since="24h"
json_mode=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      shift; [ $# -gt 0 ] || usage
      case "$1" in */*) ;; *) usage ;; esac
      repos+=("$1") ;;
    --repos-file)
      shift; [ $# -gt 0 ] || usage
      repos_file="$1"; repos_file_given=1 ;;
    --since)
      shift; [ $# -gt 0 ] || usage
      since="$1" ;;
    --json) json_mode=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

# ── --since → 창 시작 epoch ────────────────────────────────────────────────
# `<N>h`·`<N>d` 만 받는다. 느슨하게 받으면 오타가 창 0(= 실패·파생 항상 0)으로 조용히
# 흘러 "깨끗하다" 는 거짓 신호가 된다.
since_n=""
since_hours=""
case "$since" in
  *h) since_n=${since%h}; ;;
  *d) since_n=${since%d}; ;;
  *) usage ;;
esac
# 0h·0d 는 창이 없다 — 실패·파생이 항상 0 이 되는 거짓 "깨끗함" 이라 형식 오류로 본다.
case "$since_n" in ""|0|*[!0-9]*) usage ;; esac
case "$since" in
  *h) since_hours=$since_n ;;
  *d) since_hours=$((since_n * 24)) ;;
esac

cutoff=$(date -u -v-"${since_hours}"H +%s 2>/dev/null)
if [ -z "$cutoff" ]; then
  cutoff=$(date -u -d "$since_hours hours ago" +%s 2>/dev/null)
fi
if [ -z "$cutoff" ]; then
  snapshot_abort "창 시작 시각 계산 실패 (date -v / date -d 둘 다 불가)"
fi

# ── 인계 전 창 — HANDOFF_GRACE_MIN(분) ─────────────────────────────────────
# 여기서 검사한다: 값을 그대로 jq 에 넘기면 형식 오류가 레포별 "집계 실패(jq)" 로 위장돼
# 환경 문제인지 GitHub 문제인지 구분이 안 된다. 0 은 허용(창 없음 = warn 이 늘어난다).
grace_min=${HANDOFF_GRACE_MIN:-90}
case "$grace_min" in
  ""|*[!0-9]*) snapshot_abort "HANDOFF_GRACE_MIN 형식 오류: $grace_min (0 이상 정수 분만)" ;;
esac

now_epoch=$(date -u +%s 2>/dev/null)
case "$now_epoch" in
  ""|*[!0-9]*) snapshot_abort "현재 시각 계산 실패 (date -u +%s)" ;;
esac

# ── 스코프 확정 ────────────────────────────────────────────────────────────
if [ "${#repos[@]}" -eq 0 ]; then
  if [ "$repos_file_given" = 1 ]; then
    # 사람이 경로를 콕 집었는데 없으면 usage 로 뭉개지 말고 그 사실만 말한다
    # (오타·잘못된 cwd 를 "인자를 몰라서" 로 오해하게 만들지 않는다).
    if [ ! -f "$repos_file" ]; then
      echo "$SELF: repos 파일 없음: $repos_file" >&2
      exit 64
    fi
  else
    repos_file="$PWD/.loop/repos"
    [ -f "$repos_file" ] || usage
  fi
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d ' \t')
    case "$line" in ""|"#"*) continue ;; esac
    # owner/repo 형식이 아닌 줄은 조용히 버리지 않는다 — 오타 한 글자가 레포 하나를
    # 스코프에서 통째로 지우고도 아무 흔적이 없으면 "그 레포엔 아무것도 없다" 로 읽힌다.
    case "$line" in
      */*) ;;
      *) echo "$SELF: $repos_file 무시된 줄: $line" >&2; continue ;;
    esac
    repos+=("$line")
  done < "$repos_file"
fi
[ "${#repos[@]}" -gt 0 ] || usage

command -v jq >/dev/null 2>&1 || snapshot_abort "jq 없음 — 집계 불가"

tmpdir=$(mktemp -d) && [ -n "$tmpdir" ] && [ -d "$tmpdir" ] || snapshot_abort "임시 디렉터리 생성 실패(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# short_name <owner/repo> — repo 부분을 소문자로. issue-runner 만 `runner` 특례.
short_name() {
  local r=${1##*/}
  case "$r" in
    issue-runner|Issue-Runner) echo runner ;;
    *) printf '%s\n' "$r" | tr 'A-Z' 'a-z' ;;
  esac
}

# run_gh <gh 인자...> — 성공하면 GH_OUT, 실패하면 GH_ERR(한 줄 요약).
# set -e 를 안 쓰는 레포 관행이라 호출마다 상태를 명시적으로 본다.
GH_OUT=""
GH_ERR=""
run_gh() {
  local rc
  GH_OUT=$("$@" 2>"$tmpdir/gh.err")
  rc=$?
  GH_ERR=$(tr '\n' ' ' < "$tmpdir/gh.err" | sed 's/  */ /g; s/^ //; s/ *$//' | cut -c1-200)
  [ -n "$GH_ERR" ] || GH_ERR="exit $rc"
  return $rc
}

scope_shorts=""
for r in "${repos[@]}"; do
  s=$(short_name "$r")
  if [ -z "$scope_shorts" ]; then scope_shorts="$s"; else scope_shorts="${scope_shorts}·${s}"; fi
done

# ── 레포 스냅샷 jq — 이슈/PR 목록 → 버킷·warn·표시문구가 든 JSON 한 덩어리 ──
BUILD_JQ=$(cat <<'JQ'
def lad: ["agent:claimed","flow:verify","flow:ready","harvesting"];
def mirror_labels: ["flow:verify","flow:ready","harvesting"];
def pr_stage_labels: ["flow:ci","flow:codex","flow:verify","flow:ready","harvesting"];
def has($l; $x): ($l | index($x)) != null;
def ladder_of($l): lad | map(select(. as $x | has($l; $x)));
def key_of($s):
  if $s == "harvesting" then "harvesting"
  elif $s == "flow:ready" then "ready"
  elif $s == "flow:verify" then "verify"
  elif $s == "agent:claimed" then "claimed"
  else "none" end;
def ko_of($k):
  {"none":"대기","claimed":"구현중","verify":"검증대기","ready":"마감대기","harvesting":"마감중"}[$k];
def linked($p):
  if ($p.closingIssuesReferences | length) > 0 then $p.closingIssuesReferences[0].number
  elif ($p.headRefName | test("^agent/issue-[0-9]+")) then
    ($p.headRefName | capture("^agent/issue-(?<n>[0-9]+)").n | tonumber)
  else null end;
def epoch($t): if $t == null then null else ($t | fromdateiso8601) end;
def mins_since($t): (($now - epoch($t)) / 60 | floor);
def stage_labels_of($l): $l | map(select(. as $x | pr_stage_labels | index($x) != null));
# `hold:*` 접미만 뽑는다 — 허용 목록(conflict·policy·ladder)으로 거르지 않는다.
# 금지 사유(`hold:dup`·`hold:hardware`)는 라벨을 아예 안 만드는 것으로 막는 게 SSOT
# (setup-labels.sh) 이고, 여기서 또 걸러 내면 실수로 붙은 라벨이 화면에서 사라진다.
def holds_of($l): $l | map(select(startswith("hold:")) | ltrimstr("hold:")) | sort;

($issues | map({
    number, title, createdAt,
    ln: [.labels[].name]
  })
  | map(. + {ladder: ladder_of(.ln), holds: holds_of(.ln)})
  | map(. + {stage: (if (.ladder | length) == 0 then "none" else key_of(.ladder[-1]) end)})
  | map(. + {bucket:
      (if has(.ln; "deploy-wait")
          or ((.ladder | length) == 0 and (.title | test("^배포 (대기|검증)"))) then "deploy_wait"
       elif has(.ln; "needs-human") then "human_wait"
       elif .stage == "harvesting" then "harvesting"
       elif .stage == "ready" then "ready"
       elif .stage == "verify" then "verify"
       elif .stage == "claimed" then "claimed"
       elif has(.ln; "agent-ready") then "waiting"
       else "outside" end)})) as $iss
| ($iss | map(.number)) as $onums
| ($prs_open | map({number, headRefName, createdAt, ln: [.labels[].name], issue: linked(.)})) as $po
| ($prs_closed | map({number, headRefName, mergedAt, closedAt, ln: [.labels[].name], issue: linked(.)})) as $pc
# 무소속 PR **후보** — 여기서 한 번만 정하고 아래에서 둘로 쪼갠다(인계 전 / warn).
# 표시와 warn 을 각각 별도 조건으로 쓰면 언젠가 둘 다에 나오거나 둘 다에서 사라진다.
| ($po | map(select(
      ((.headRefName | test("^agent/issue-")) or (.issue != null))
      and ((stage_labels_of(.ln) | length) == 0)
      and (has(.ln; "needs-human") | not)
      and ((.issue as $n | $iss | map(select(.number == $n and has(.ln; "needs-human"))) | length) == 0)))) as $ocand
| ($ocand | map(. as $p | select(
      $p.issue != null
      and (($iss | map(select(.number == $p.issue and has(.ln; "agent:claimed"))) | length) > 0)
      and ($p.createdAt != null)
      and (($now - epoch($p.createdAt)) < ($grace * 60))))) as $handoff
| ($handoff | map(.number)) as $hnums
| def pr_of($n): ($po | map(select(.issue == $n)) | if length > 0 then .[0] else null end);
  def handoff_pr_of($n): ($handoff | map(select(.issue == $n)) | .[0]);
  def issue_claimed($n): (($iss | map(select(.number == $n and has(.ln; "agent:claimed"))) | length) > 0);
  def closed_agent_in_window: ($pc
    | map(select((.headRefName | test("^agent/issue-"))
                 and .mergedAt == null
                 and .closedAt != null
                 and (epoch(.closedAt) >= $cutoff)))
    | sort_by(-.number));
  def closed_pr_item($tail): {number: .number, repo_short: $rs, issue: .issue,
    label: ("PR #\(.number)(" + (if .issue then "#\(.issue), " else "" end) + $tail + ")")};
  def item($i; $label): {number: $i.number, repo_short: $rs, label: $label};
  def bucket($k; f): ($iss | map(select(.bucket == $k)) | sort_by(-.number) | map(f));

  {
    repo: $repo,
    repo_short: $rs,
    ok: true,
    since: $since,
    buckets: {
      waiting:     bucket("waiting";     item(.; "#\(.number)")),
      claimed:     bucket("claimed";     . as $i | handoff_pr_of($i.number) as $p
                     | (item($i; "#\($i.number)" + (if $p == null then "" else " ← PR #\($p.number)(인계 전)" end))
                        + {pr: (if $p == null then null else $p.number end),
                           handoff_pending: ($p != null)})),
      verify:      bucket("verify";      . as $i | pr_of($i.number) as $p | (item($i; "#\($i.number)" + (if $p then " ← PR #\($p.number)" else "" end)) + {pr: (if $p then $p.number else null end)})),
      ready:       bucket("ready";       . as $i | pr_of($i.number) as $p | (item($i; "#\($i.number)" + (if $p then " ← PR #\($p.number)" else "" end)) + {pr: (if $p then $p.number else null end)})),
      harvesting:  bucket("harvesting";  . as $i | pr_of($i.number) as $p | (item($i; "#\($i.number)" + (if $p then " ← PR #\($p.number)" else "" end)) + {pr: (if $p then $p.number else null end)})),
      human_wait:  bucket("human_wait";  . as $i | pr_of($i.number) as $p
                     | (item($i; "#\($i.number)(" + ko_of($i.stage)
                                 + ", " + (if ($i.holds | length) == 0 then "사유 없음"
                                           else ($i.holds | join(", ")) end)
                                 + (if $p then ", PR #\($p.number)" else "" end) + ")")
                        + {stage: $i.stage, holds: $i.holds,
                           pr: (if $p then $p.number else null end)})),
      deploy_wait: bucket("deploy_wait"; item(.; "#\(.number)")),
      # 실패 ⊎ 중복종료 = 창 안의 미머지 agent PR. `dup` 라벨이 둘을 가른다(겹치지 않는다).
      failed: (closed_agent_in_window
        | map(select(has(.ln; "dup") | not))
        | map(closed_pr_item("머지 없이 닫힘"))),
      dup_closed: (closed_agent_in_window
        | map(select(has(.ln; "dup")))
        | map(closed_pr_item("중복 종료"))),
      spinoff: ($iss
        | map(select(has(.ln; "spinoff") and (epoch(.createdAt) >= $cutoff)))
        | sort_by(.createdAt, .number)
        | map(item(.; "#\(.number)")))
    },
    promotion_ahead: $ahead,
    warns: (
      # 무소속 PR — 후보($ocand)에서 인계 전 창($handoff)을 뺀 나머지.
      # `index/1` 의 인자는 **파이프 좌변(배열)** 을 입력으로 평가된다 — `.number` 를 그대로
      # 쓰면 배열을 문자열로 인덱싱해 죽는다. PR 을 먼저 $p 로 묶는다.
      ($ocand | map(. as $p | select(($hnums | index($p.number)) == null))
        | map(. as $p | issue_claimed($p.issue) as $claimed
              | {kind: "orphan_pr", repo_short: $rs, pr: $p.number, issue: $p.issue,
                 handoff_overdue: ($claimed and $p.createdAt != null),
                 text: ("무소속 PR #\($p.number)(\($rs)) — 열린 agent PR 인데 단계 라벨 0 · "
                        + (if $p.issue == null then "연결 이슈 없음"
                           else "연결 이슈 #\($p.issue) 는 needs-human 아님" end)
                        + (if $claimed and $p.createdAt != null
                           then "(agent:claimed 인데 \(mins_since($p.createdAt))분 경과 — 워커 사망 의심)"
                           else "" end))}))
      # needs-human 인데 사유(hold:*)가 없다
      + ($iss | map(select(.bucket == "human_wait" and (.holds | length) == 0))
        | map({kind: "hold_no_reason", repo_short: $rs, issue: .number,
               text: "needs-human 사유 없음 #\(.number)(\($rs)) — hold:* 라벨 없음"}))
      # 단계 라벨 중복
      + ($iss | map(select((.ladder | length) > 1))
        | map({kind: "dup_stage", repo_short: $rs, issue: .number,
               text: "단계 라벨 중복 #\(.number)(\($rs)) — \(.ladder | join(" + "))"}))
      # 미러 불일치 — 열린 연결 PR 이 있을 때만(대조 상대가 없으면 warn 아님)
      + ($iss | map(. as $i | pr_of($i.number) as $p
          | if $p == null then empty
            else
              ($i.ln | map(select(. as $x | mirror_labels | index($x) != null)) | sort) as $a
              | ($p.ln | map(select(. as $x | mirror_labels | index($x) != null)) | sort) as $b
              | if $a == $b then empty
                else {kind: "mirror_mismatch", repo_short: $rs, issue: $i.number, pr: $p.number,
                      text: ("미러 불일치 #\($i.number)(\($rs)) ↔ PR #\($p.number)(\($rs)) — 이슈 "
                             + (if ($a | length) == 0 then "단계 없음" else ($a | join(" ")) end)
                             + " · PR "
                             + (if ($b | length) == 0 then "단계 없음" else ($b | join(" ")) end))}
                end
            end))
      # 좌초형 (#117)
      + ($iss | map(select((.ladder | length) > 0 and (has(.ln; "agent-ready") | not)))
        | map({kind: "stranded", repo_short: $rs, issue: .number,
               text: "좌초형 #\(.number)(\($rs)) — 사다리 라벨(\(.ladder | join(" "))) 인데 agent-ready 없음"}))
      # 목록 상한 도달 — 창 안의 실패·파생이 잘렸을 수 있다
      + ([{n: ($issues | length), what: "이슈"},
          {n: ($prs_open | length), what: "열린 PR"},
          {n: ($prs_closed | length), what: "닫힌 PR"}]
         | map(select(.n >= 200))
         | map({kind: "list_truncated", repo_short: $rs, list: .what,
                text: "목록 상한 200 도달 — 창 절단 가능(\(.what))"}))
      # 열린 PR 인데 연결 이슈가 CLOSED
      + ($po | map(select(. as $p | $p.issue != null and (($onums | index($p.issue)) == null)))
        | map({kind: "closed_issue_open_pr", repo_short: $rs, pr: .number, issue: .issue,
               text: "연결 이슈 종료 PR #\(.number)(\($rs)) — 연결 이슈 #\(.issue) 가 CLOSED(Refs 부분착지면 정상)"}))
    )
  }
| . + {open_total: ([.buckets.waiting, .buckets.claimed, .buckets.verify, .buckets.ready,
                     .buckets.harvesting, .buckets.human_wait, .buckets.deploy_wait]
                    | map(length) | add)}
JQ
)

# ── 사람용 렌더 jq — 레포 JSON 하나 → 블록 문자열 ─────────────────────────
# 라벨 자리는 표시폭 10칸으로 맞춘 리터럴(한글 = 2칸). 계산 대신 적어 둔다.
RENDER_JQ=$(cat <<'JQ'
def padded($k):
  {"waiting":"대기      ","claimed":"구현중    ","verify":"검증대기  ",
   "ready":"마감대기  ","harvesting":"마감중    ","human_wait":"사람대기  ",
   "deploy_wait":"배포대기  ","failed":"실패      ","dup_closed":"중복종료  ",
   "spinoff":"파생      "}[$k];
def row($k):
  (.buckets[$k]) as $b
  | "  " + padded($k) + "\($b | length)"
    + (if ($b | length) == 0 then "" else "  " + ($b | map(.label) | join(" ")) end);
if .ok == false then
  "파이프라인 \(.repo_short) — 조회 실패: \(.error)"
else
  ([ "파이프라인 \(.repo_short) — 열림 \(.open_total) · 스코프 \($scope) · 창 \(.since)",
     row("waiting"), row("claimed"), row("verify"), row("ready"), row("harvesting"),
     row("human_wait"), row("deploy_wait"), row("failed"), row("dup_closed"), row("spinoff"),
     "  승격 대기 " + (if .promotion_ahead == null then "—" else "\(.promotion_ahead)커밋" end),
     "  warn      \(.warns | length)" ]
   + (.warns | map("    - " + .text)))
  | join("\n")
end
JQ
)

exit_code=0
: > "$tmpdir/repos.jsonl"

for repo in "${repos[@]}"; do
  short=$(short_name "$repo")

  fail_reason=""
  issues_json=""
  prs_open_json=""
  prs_closed_json=""

  if run_gh gh issue list --repo "$repo" --state open --limit 200 \
      --json number,title,labels,createdAt; then
    issues_json=$GH_OUT
  else
    fail_reason="이슈 목록 — $GH_ERR"
  fi

  if [ -z "$fail_reason" ]; then
    if run_gh gh pr list --repo "$repo" --state open --limit 200 \
        --json number,headRefName,closingIssuesReferences,labels,state,mergedAt,closedAt,createdAt; then
      prs_open_json=$GH_OUT
    else
      fail_reason="열린 PR 목록 — $GH_ERR"
    fi
  fi

  if [ -z "$fail_reason" ]; then
    if run_gh gh pr list --repo "$repo" --state closed --limit 200 \
        --json number,headRefName,closingIssuesReferences,labels,state,mergedAt,closedAt,createdAt; then
      prs_closed_json=$GH_OUT
    else
      fail_reason="닫힌 PR 목록 — $GH_ERR"
    fi
  fi

  if [ -n "$fail_reason" ]; then
    exit_code=1
    jq -nc --arg repo "$repo" --arg rs "$short" --arg err "$fail_reason" \
      '{repo:$repo, repo_short:$rs, ok:false, error:$err}' >> "$tmpdir/repos.jsonl"
    continue
  fi

  # 승격 대기 — release 없거나 조회 실패면 null(`—`). 레포를 실패로 만들지 않는다.
  ahead="null"
  if run_gh gh api "repos/$repo/branches/release"; then
    if run_gh gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name'; then
      defbranch=$GH_OUT
      if [ -n "$defbranch" ] && run_gh gh api "repos/$repo/compare/release...$defbranch" --jq '.ahead_by'; then
        case "$GH_OUT" in
          ""|*[!0-9]*) ahead="null" ;;
          *) ahead="$GH_OUT" ;;
        esac
      fi
    fi
  fi

  if ! jq -n \
      --argjson issues "$issues_json" \
      --argjson prs_open "$prs_open_json" \
      --argjson prs_closed "$prs_closed_json" \
      --argjson cutoff "$cutoff" \
      --argjson now "$now_epoch" \
      --argjson grace "$grace_min" \
      --argjson ahead "$ahead" \
      --arg repo "$repo" --arg rs "$short" --arg since "$since" \
      "$BUILD_JQ" > "$tmpdir/repo.json"; then
    exit_code=1
    jq -nc --arg repo "$repo" --arg rs "$short" --arg err "집계 실패(jq)" \
      '{repo:$repo, repo_short:$rs, ok:false, error:$err}' >> "$tmpdir/repos.jsonl"
    continue
  fi
  if ! jq -c . "$tmpdir/repo.json" >> "$tmpdir/repos.jsonl"; then
    exit_code=1
    snapshot_fail_line "$short 스냅샷 직렬화 실패(jq)"
  fi
done

if [ "$json_mode" = 1 ]; then
  if ! jq -s --arg since "$since" --arg scope "$scope_shorts" \
      '{since:$since, scope:($scope | split("·")), repos:.}' "$tmpdir/repos.jsonl"; then
    exit_code=1
    snapshot_fail_line "JSON 조립 실패(jq)"
  fi
else
  first=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" = 1 ] || echo
    first=0
    if ! printf '%s\n' "$line" | jq -r --arg scope "$scope_shorts" "$RENDER_JQ"; then
      exit_code=1
      snapshot_fail_line "블록 렌더 실패(jq)"
    fi
  done < "$tmpdir/repos.jsonl"
fi

exit "$exit_code"
