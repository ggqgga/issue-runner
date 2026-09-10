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
#     2. 사람대기 — `needs-human` (괄호는 `<사다리 위치>, <사유>[, 질문 없음][, PR #n]` —
#                  사유는 `hold:*` 라벨의 접미(`conflict`·`policy`·`ladder`; 플랜 §2). 여러
#                  개면 정렬해 `, ` 로 잇는다. `hold:*` 가 하나도 없으면 `사유 없음` 을 적고
#                  warn `needs-human 사유 없음` 을 올린다.
#                  `질문 없음`(#157) — 사유가 `policy`·`conflict` 인데 `<!-- hold-note:
#                  <그 사유> -->` 마커가 붙은 코멘트가 하나도 없는 건. 마커는 **지금 붙어
#                  있는 사유**로 가린다(#160) — 코멘트는 홀드가 풀려도 남으므로, 사유를 안
#                  가리면 옛 `policy` 질문이 지금의 `conflict` 홀드를 가린다. 그 둘은
#                  `--note`(사람이 답해야 할 질문 한 줄)가 필수라 질문이 없으면 사람은
#                  무엇을 답할지 모른다. 옛 전이가
#                  라벨만 붙이고 코멘트에 실패해 남긴 잔여물이거나(#157 이전), 사람이 손으로
#                  붙인 홀드다. `ladder` 는 `--note` 가 선택이라 대상이 아니다.)
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
#                      **인계 전 창(플랜 §5)**: 그 후보 중 연결 이슈가 **구현중 버킷**이고
#                      (=`agent:claimed` 이 이긴 이슈. 라벨이 아니라 버킷으로 본다 — 라벨로
#                      걸면 `agent:claimed` 을 단 채 배포대기·flow:*·harvesting 으로 간
#                      이슈의 PR 이 warn 에서만 빠지고 구현중 줄엔 안 그려져 아무 표시도
#                      없이 사라진다) PR `createdAt` 이 지금으로부터
#                      `HANDOFF_GRACE_MIN`(기본 90) 분 미만인
#                      것은 warn 이 아니라 **구현중 줄**에 `← PR #n(인계 전)` 으로 붙는다 —
#                      디스패치 직후 워커가 PR 을 열고 아직 단계 라벨을 못 찍은 정상 구간이
#                      매 틱 warn 으로 울리는 걸 막는다. 창을 넘기면 같은 후보가 무소속 warn
#                      으로 나오되 `(agent:claimed 인데 <N>분 경과 — 워커 사망 의심)` 이
#                      덧붙는다. 후보 집합 하나를 둘로 **분할**하므로 표시와 warn 은 항상
#                      서로 배타다(두 조건을 따로 쓰면 드리프트한다).
#                      그 `<N>분` 은 **가장 최근 `agent:claimed` labeled 이벤트**(이슈
#                      타임라인) 기준이다 (#177) — PR `createdAt` 이 아니다. 창 분할은
#                      종전대로 PR 나이로 한다(둘은 다른 질문이다: 창은 "PR 을 연 뒤 얼마나
#                      됐나", 꼬리표는 "워커를 붙인 뒤 얼마나 됐나"). PR 나이로 재면 홀드
#                      해제 뒤 **재디스패치**된 건에서 숫자가 통째로 부풀어(실측 #170/PR
#                      #172: 231분 — 실제 claim 은 7분 전, 워커는 15분 뒤 인계까지 끝냈다)
#                      살아 있는 워커를 사망으로 신고하고, 반송을 돌수록 숫자가 단조 증가해
#                      신호가 죽는다. 반대로 재claim 직후 죽은 워커는 PR 이 방금 열렸으면
#                      작게 나와 안 울린다. 시각을 못 얻으면 숫자를 지어내지 않고 미상으로
#                      바꾸되(0분으로 접으면 진짜 사망이 숨는다) **warn 자체는 유지**한다.
#                      미상 안에서도 두 문구를 가른다(#181): 조회했지만 실패했거나 claim
#                      이벤트가 없으면 `(agent:claimed 인데 경과 미상 — 확인 필요)`, 상한
#                      (`CLAIM_TIME_MAX`)에 걸려 애초에 조회하지 않았으면 `(agent:claimed
#                      인데 경과 미상 — 조회 상한)` — "안 봤다" 와 "보고 실패했다" 는 다른
#                      사실이라 사람이 다르게 반응해야 한다(전자는 상한을 늘릴 문제).
#   · 질문 유무 미확인
#                    — **사람대기 버킷**의 `hold:policy|conflict` 이슈인데 질문(hold-note)
#                      코멘트의 유무를 못 봤다(조회 실패·응답 파싱 실패·코멘트 100건 상한·
#                      `HOLD_NOTE_MAX` 초과). "질문 없음" 으로 접지 않고 모른다고 말한다.
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
#   질문 코멘트 조회(#157)가 실패하면 그 이슈만 `질문 없음` 표시를 **생략**하고 warn
#   `질문 유무 미확인` 을 올린다 — 실패를 "질문 없음" 으로 접으면 없는 결함을 사람에게
#   들이민다. stderr 로만 말하지 않는 이유: 세 루프는 ④ Report 에 **stdout 만** 붙인다.
#
# ★환경 변수★ `HANDOFF_GRACE_MIN` — 인계 전 창(분, 기본 90, 0 이상 정수). 형식이 틀리면
#   환경 실패로 죽는다(jq 에 그대로 넘겨 레포별 "집계 실패" 로 위장되지 않게). `0` 은 허용 —
#   창이 없으면 warn 이 **늘어나지** `--since 0h` 처럼 거짓 "깨끗함" 이 되지 않는다.
#   `HOLD_NOTE_MAX` — 레포당 질문(hold-note) 코멘트 조회 상한(기본 50, 0 이상 정수, #157).
#   넘는 후보는 조회하지 않고 warn `질문 유무 미확인` 으로만 남는다. 형식이 틀리면 같은
#   이유로 환경 실패.
#   `CLAIM_TIME_MAX` — 레포당 `agent:claimed` 시각(타임라인) 조회 상한(기본 20, 0 이상 정수,
#   #177). **고유 이슈 수**를 센다(#181 — 한 이슈에 무소속 PR 이 여럿이어도 상한은 한 번만
#   깎인다). 넘는 후보는 조회하지 않고 `경과 미상 — 조회 상한` 으로 남는다(조회했지만
#   실패한 `경과 미상 — 확인 필요` 와는 다른 문구). 형식 오류는 같은 환경 실패.
#
# ★환경 실패 처리★ 레포와 무관한 실패(창 시각 계산 불가·jq 부재·집계/렌더/직렬화 jq 실패)는
#   **stdout 에도** `파이프라인 — 스냅샷 실패: <사유>` 한 줄을 남기고 exit 1 한다. 세 루프는
#   이 출력을 ④ Report 에 그대로 붙이므로, stderr 로만 말하면 사유가 사라지고 exit 1 이
#   "레포 하나 조회 실패"(부분 실패)와 구분되지 않는다.
#
# gh 호출 예산: 레포당 이슈 목록 1 + PR 목록(open/closed) 2 + release 확인 1 + 기본 브랜치 1
# + compare 1 = 최대 6. **예외 둘**. ①(#157) 사람대기 버킷에서 사유가 `policy`·`conflict` 인
# 이슈에 한해 질문 코멘트 조회 `gh issue view --json comments` 를 1건씩 더 쓴다 — 라벨만으론
# 질문 유무를 알 수 없고, 대상은 "지금 사람을 기다리는 건" 이라 목록 전체가 아니라 한 줌이다.
# ②(#177) 무소속 warn 중 **사망 의심 꼬리표가 붙는 후보**에 한해 이슈 타임라인
# (`gh api .../timeline --paginate`)을 1건씩 더 쓴다 — 그 시각은 목록 API 에 없다. 대상은
# "인계 창을 넘긴 무소속 PR" 이라 정상적으로는 0건이고, 상한은 `CLAIM_TIME_MAX`(기본 20).
# 그 밖의 이슈·PR **개별** `gh view` 는 여전히 금지(N+1). `gh search` / `gh issue list
# --search` 도 금지 — 인덱스 지연 + 부정 라벨 오파싱(#21, eligible-issues.sh 주석 참조).
# 라벨 필터는 전부 jq 로 한다. 목록은 `--limit 200` 상한 — `--since` 를 크게 잡으면
# (예 30d) 닫힌 PR 이 상한에 잘려 "실패" 가 조용히 누락될 수 있다.
set -uo pipefail

SELF=$(basename "$0")

usage() {
  {
    echo "usage: $SELF [--repos-file <경로>] [--repo <owner/repo>]... [--since <N>h|<N>d] [--json]"
    echo "                   [--post <issue-runner|verify-runner|closeout> [--delta \"<이 틱 한 줄 요약>\"]]"
    echo "  스코프: --repo 가 있으면 그것들, 없으면 --repos-file (기본 \$PWD/.loop/repos)."
    echo "          둘 다 없으면 이 도움말(exit 64)."
    echo "  --since: 실패·파생 창. <N>h 또는 <N>d 만 (기본 24h)."
    echo "  --json : 사람용 블록 대신 JSON 한 덩어리."
    echo "  --post : 레포마다 고정 이슈 '루프 현황'(라벨 loop-dashboard) 본문을 이 스냅샷으로 덮어쓴다 —"
    echo "           깃헙만 보고 '누가 들고 있고 루프가 마지막으로 언제 돌았나' 를 알게(#163). 자기 루프의"
    echo "           마지막 틱 시각·--delta 만 갱신하고 다른 두 루프 줄은 보존. --json 과 함께 못 쓴다."
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

# ── 루프 현황 고정 이슈 (#163) ─────────────────────────────────────────────
# 레포마다 라벨 `loop-dashboard` 가 붙은 열린 이슈 하나가 대시보드다(없으면 만들고 pin).
# 본문은 **덮어쓴다** — 단 첫 줄 마커 `<!-- loop-dashboard -->` 가 있을 때만(사람 이슈를
# 지우지 않게). 세 루프 줄(마지막 틱·델타)은 자기 것만 갱신하고 나머지는 이전 본문에서 보존.
DASH_MARK="<!-- loop-dashboard -->"
post_dashboard() {  # post_dashboard <owner/repo> <short> <블록 텍스트>
  local repo="$1" short="$2" block="$3" num mine body now tmpb ctext ids out
  now=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M KST')
  # 정본 = 라벨 붙은 열린 이슈 중 **번호가 가장 작은 것**. 두 루프가 동시에 처음 게시해 둘을
  # 만들어도 같은 정본으로 수렴하고, 내가 만든 게 정본이 아니면 내 것을 닫는다.
  dash_find() {
    gh issue list --repo "$repo" --state open --label loop-dashboard --limit 5 \
      --json number -q '[.[].number] | min // empty' 2>/dev/null
  }
  num=$(dash_find) || { echo "$SELF: $short 대시보드 이슈 조회 실패 — 게시 생략" >&2; return 1; }
  if [ -z "$num" ]; then
    tmpb="$tmpdir/dash.create"
    printf '%s\n루프 현황 이슈 — 세 루프가 매 틱 본문을 덮어쓴다. 직접 편집하지 마라.\n' "$DASH_MARK" > "$tmpb"
    dash_create() {
      gh issue create --repo "$repo" --title "루프 현황 — $short (loop dashboard)" \
        --label loop-dashboard --body-file "$tmpb" 2>&1
    }
    out=$(dash_create)
    case "$out" in
      *"' not found"*|*"could not add label"*|*[Ll]abel*"not found"*)
        # 기존 옵트인 레포엔 loop-dashboard 가 없다 — transition.sh 와 같은 규율: 보강 1회 + 재시도 1회
        "$(dirname "$0")/setup-labels.sh" "$repo" >/dev/null 2>&1 || true
        out=$(dash_create) ;;
    esac
    mine=$(printf '%s\n' "$out" | grep -oE '[0-9]+$' | tail -1)
    [ -n "$mine" ] || { echo "$SELF: $short 대시보드 이슈 생성 실패 — $out" >&2; return 1; }
    num=$(dash_find) || num=""
    [ -n "$num" ] || num=$mine
    if [ "$num" != "$mine" ]; then
      # 경합으로 둘이 생겼다 — 정본(작은 번호)만 남기고 내 것은 닫는다
      gh issue close "$mine" --repo "$repo" --comment "중복 대시보드 — 정본은 #$num" >/dev/null 2>&1 || true
    fi
    gh issue pin "$num" --repo "$repo" >/dev/null 2>&1 || true
  fi
  body=$(gh issue view "$num" --repo "$repo" --json body -q '.body' 2>/dev/null) || {
    echo "$SELF: $short 대시보드 #$num 본문 조회 실패 — 게시 생략" >&2; return 1; }
  case "$body" in "$DASH_MARK"*) ;; *)
    echo "$SELF: $short #$num 은 대시보드 마커가 없다 — 덮어쓰지 않는다(라벨 loop-dashboard 를 떼라)" >&2
    return 1 ;;
  esac
  # ① 본문 = 스냅샷만(어느 루프가 마지막에 써도 같은 GitHub 상태를 그린다 — 덮어써도 잃는 게 없다).
  #    루프별 "마지막 틱" 은 본문에 두지 않는다 — 두 루프가 같은 본문을 읽고 쓰면 상대 줄이 지워진다.
  tmpb="$tmpdir/dash.$short.md"
  {
    printf '%s\n' "$DASH_MARK"
    printf '# 루프 현황 — %s\n\n' "$short"
    printf '세 루프가 매 틱 이 본문을 덮어쓴다(직접 편집하지 마라). 읽는 법: 이슈 라벨 `agent-ready` 는 자격(사다리 내내 유지),\n'
    printf '단계 라벨(`agent:claimed`→`flow:verify`→`flow:ready`→`harvesting`)이 "지금 누가 들고 있나", `needs-human`+`hold:*` 는 사람(사유·질문은 코멘트).\n\n'
    printf '**각 루프의 마지막 틱·델타는 아래 코멘트**(루프당 1개, 자기 것만 편집)에 있다.\n\n'
    printf '## 스냅샷 (%s 가 %s 에 게시)\n\n```\n%s\n```\n' "$post_loop" "$now" "$block"
  } > "$tmpb"
  if ! gh issue edit "$num" --repo "$repo" --body-file "$tmpb" >/dev/null 2>&1; then
    echo "$SELF: $short 대시보드 #$num 본문 갱신 실패" >&2; return 1
  fi
  # ② 루프별 틱 코멘트 — 마커 `<!-- loop-tick: <loop> -->` 가 있는 자기 코멘트를 PATCH(없으면 생성).
  #    루프마다 독립 쓰기라 동시에 게시해도 서로를 지우지 않는다.
  ctext=$(printf '**%s** 마지막 틱: %s — %s\n<!-- loop-tick: %s -->' "$post_loop" "$now" "${delta_line:-(델타 없음)}" "$post_loop")
  ids=$(gh api "repos/$repo/issues/$num/comments?per_page=100" 2>/dev/null \
        | jq -r --arg m "<!-- loop-tick: $post_loop -->" '.[]? | select(.body | contains($m)) | .id' 2>/dev/null | head -1) || ids=""
  if [ -n "$ids" ]; then
    if ! gh api "repos/$repo/issues/comments/$ids" -X PATCH -f body="$ctext" >/dev/null 2>&1; then
      echo "$SELF: $short 대시보드 #$num 틱 코멘트 갱신 실패" >&2; return 1
    fi
  else
    if ! gh issue comment "$num" --repo "$repo" --body "$ctext" >/dev/null 2>&1; then
      echo "$SELF: $short 대시보드 #$num 틱 코멘트 생성 실패" >&2; return 1
    fi
  fi
  echo "대시보드: $short #$num 갱신($post_loop $now)"
}

repos=()
repos_file=""
repos_file_given=0
since="24h"
json_mode=0
post_loop=""
delta_line=""

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
    --post)
      shift; [ $# -gt 0 ] || usage
      case "$1" in issue-runner|verify-runner|closeout) post_loop="$1" ;; *) usage ;; esac ;;
    --delta)
      shift; [ $# -gt 0 ] || usage
      delta_line="$1" ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
[ "$json_mode" = 1 ] && [ -n "$post_loop" ] && usage
[ -n "$delta_line" ] && [ -z "$post_loop" ] && usage

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

# ── 질문 코멘트 조회 상한 — HOLD_NOTE_MAX (#157) ───────────────────────────
# 레포당 이 개수까지만 `gh issue view --json comments` 를 쓴다. 넘는 후보는 조회하지 않고
# `질문 유무 미확인` warn 으로만 남는다(거짓 `질문 없음` 을 만들지 않는다).
hold_note_max=${HOLD_NOTE_MAX:-50}
case "$hold_note_max" in
  ""|*[!0-9]*) snapshot_abort "HOLD_NOTE_MAX 형식 오류: $hold_note_max (0 이상 정수만)" ;;
esac
HOLD_NOTE_MAX=$hold_note_max

# ── claim 시각 조회 상한 — CLAIM_TIME_MAX (#177) ───────────────────────────
# 레포당 이 개수까지만 `gh api .../timeline` 을 쓴다. 넘는 후보는 조회하지 않고 `경과 미상`
# 으로 남는다(거짓 숫자를 만들지 않는다). 대상은 사망 의심 꼬리표가 붙는 무소속 warn 뿐이라
# 평시엔 0건이지만, 루프가 크게 어긋난 날 상한이 없으면 이 스크립트가 틱을 잡아먹는다.
claim_time_max=${CLAIM_TIME_MAX:-20}
case "$claim_time_max" in
  ""|*[!0-9]*) snapshot_abort "CLAIM_TIME_MAX 형식 오류: $claim_time_max (0 이상 정수만)" ;;
esac
CLAIM_TIME_MAX=$claim_time_max

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
# 이슈 번호 → 가장 최근 `agent:claimed` 부착 시각(ISO) 또는 null (#177).
# 셸이 후보에만 타임라인을 물어 채워 주고, **못 얻은 것은 아예 안 들어온다** — 여기서
# 없음은 "0분" 이 아니라 "모른다" 다(경과 미상 문구로 간다).
def claim_at($n):
  if $n == null then null
  else ($claimtimes | map(select(.n == $n)) | if length > 0 then .[0].at else null end) end;
# 이슈 번호 → 상한(`CLAIM_TIME_MAX`)에 걸려 **조회 자체를 안 한** 후보였는가 (#181).
# "안 봤다"(capped)와 "봤는데 못 얻었다"(claim_at 이 null — 조회 실패·이벤트 부재·형식
# 밖)는 다른 사실이라 문구를 가른다. 상한 안이었는데 조회에 실패한 건은 여기 안 걸린다.
def capped($n): if $n == null then false else ($claimcapped | index($n)) != null end;
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
# 인계 전 창의 판정축은 `agent:claimed` **라벨**이 아니라 **구현중 버킷**이다.
# 라벨로 걸면 `agent:claimed` 이 붙은 채 더 뒤 버킷으로 간 이슈(deploy-wait·flow:*·
# harvesting)의 라벨 없는 PR 이 무소속 warn 에서는 빠지는데, 렌더는 구현중 줄에서만
# 하므로 어디에도 안 그려진다 — 아무 표시도 없는 거짓 깨끗함. 버킷으로 걸면 표시와
# warn 이 같은 축을 쓰므로 진짜 배타가 된다.
| def in_claimed_bucket($n): (($iss | map(select(.number == $n and .bucket == "claimed")) | length) > 0);
# 무소속 PR **후보** — 여기서 한 번만 정하고 아래에서 둘로 쪼갠다(인계 전 / warn).
# 표시와 warn 을 각각 별도 조건으로 쓰면 언젠가 둘 다에 나오거나 둘 다에서 사라진다.
# warn 정의는 "루프가 교정 가능한 불변식 위반" 으로 좁힌다 — head 가 `agent/issue-*`
# 가 아닌 PR(사람 세션이 연 브랜치)은 closeout 스윕 대상도 아니고 루프가 애초에
# 집을 방법이 없다. 조치 불가능한 후보를 warn 에 얹으면 그 줄이 상시 잡음이 되어
# 진짜 무소속 agent PR 의 신호를 죽인다(사람 브랜치는 결국 사람이 머지·종료한다).
# 그래서 공통 판정은 `orphan_base` 하나로 적고, head 로만 갈라 $ocand(agent 후보)와
# $ohuman(사람 세션 후보)을 나눈다 — 판정을 두 번 따로 적으면 언젠가 드리프트한다.
# 제외된 $ohuman 은 조용히 버리지 않는다 — warn 대신 note 로 강등해 존재를 남긴다.
def orphan_base:
  select(((stage_labels_of(.ln) | length) == 0)
    and (has(.ln; "needs-human") | not)
    and ((.issue as $n | $iss | map(select(.number == $n and has(.ln; "needs-human"))) | length) == 0)
    and ((.headRefName | test("^agent/issue-")) or (.issue != null)));
  ($po | map(orphan_base)) as $ocand_all
| ($ocand_all | map(select(.headRefName | test("^agent/issue-")))) as $ocand
| ($ocand_all | map(select((.headRefName | test("^agent/issue-")) | not))) as $ohuman
| ($ocand | map(. as $p | select(
      $p.issue != null
      and in_claimed_bucket($p.issue)
      and ($p.createdAt != null)
      and (($now - epoch($p.createdAt)) < ($grace * 60))))) as $handoff
| ($handoff | map(.number)) as $hnums
| def pr_of($n): ($po | map(select(.issue == $n)) | if length > 0 then .[0] else null end);
  def handoff_pr_of($n): ($handoff | map(select(.issue == $n)) | .[0]);
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
                     # 3상태: true=질문 없음 · false=질문 있음 · null=미확인(조회·파싱 실패
                     # ·코멘트 상한). 미확인을 false 로 접으면 기계 판독면이 "질문 있음" 이라
                     # 거짓 단정을 하게 된다 — 텍스트가 침묵하는 것과 같은 이유로 null 이다.
                     | (if ($noteunknown | map(.n) | index($i.number)) != null then null
                        else (($noteless | index($i.number)) != null) end) as $nomiss
                     | (item($i; "#\($i.number)(" + ko_of($i.stage)
                                 + ", " + (if ($i.holds | length) == 0 then "사유 없음"
                                           else ($i.holds | join(", ")) end)
                                 + (if $nomiss == true then ", 질문 없음" else "" end)
                                 + (if $p then ", PR #\($p.number)" else "" end) + ")")
                        + {stage: $i.stage, holds: $i.holds, note_missing: $nomiss,
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
        # 사망 의심 꼬리표도 같은 축(구현중 버킷)으로 — 라벨로 걸면 인계 창과 무관한
        # 이슈(예 배포대기)의 갓 열린 PR 에 "0분 경과 · 워커 사망 의심" 이 붙는다.
        | map(. as $p | in_claimed_bucket($p.issue) as $claimed
              # 경과는 **claim 시각** 기준 (#177). 없으면 숫자를 지어내지 않고 미상으로 —
              # PR `createdAt` 으로 대신 재면(옛 동작) 재디스패치 건이 통째로 오탐이 된다.
              | (if $claimed then claim_at($p.issue) else null end) as $cat
              | {kind: "orphan_pr", repo_short: $rs, pr: $p.number, issue: $p.issue,
                 # 종전의 `$claimed and $p.createdAt != null` 에서 뒷조건을 뗐다 — 그건 PR
                 # 나이로 재던 시절 "잴 값이 있나" 였다. 이제 재는 값은 claim 시각이라
                 # PR `createdAt` 은 이 판정과 무관하고, 남겨 두면 createdAt 이 없는 PR 만
                 # 꼬리표에서 조용히 빠진다(구현중 버킷인데 아무 말도 없는 상태).
                 handoff_overdue: $claimed,
                 # 3상태: 분(정수) · null=미확인. 기계 판독면도 미상을 0 으로 접지 않는다.
                 # 미상 안에서도 "안 봤다"(상한)와 "봤는데 못 얻었다"(조회 실패·이벤트
                 # 부재·형식 밖)는 text 문구로 가른다(#181) — 둘 다 claimed_minutes 는 null.
                 claimed_minutes: (if $cat == null then null else mins_since($cat) end),
                 text: ("무소속 PR #\($p.number)(\($rs)) — 열린 agent PR 인데 단계 라벨 0 · "
                        + (if $p.issue == null then "연결 이슈 없음"
                           else "연결 이슈 #\($p.issue) 는 needs-human 아님" end)
                        + (if $claimed | not then ""
                           elif $cat != null then "(agent:claimed 인데 \(mins_since($cat))분 경과 — 워커 사망 의심)"
                           elif capped($p.issue) then "(agent:claimed 인데 경과 미상 — 조회 상한)"
                           else "(agent:claimed 인데 경과 미상 — 확인 필요)"
                           end))}))
      # needs-human 인데 사유(hold:*)가 없다
      + ($iss | map(select(.bucket == "human_wait" and (.holds | length) == 0))
        | map({kind: "hold_no_reason", repo_short: $rs, issue: .number,
               text: "needs-human 사유 없음 #\(.number)(\($rs)) — hold:* 라벨 없음"}))
      # 질문(hold-note) 유무를 못 봤다 — stderr 로만 말하면 세 루프의 ④ Report(stdout 만
      # 붙인다)에서 기능이 통째로 사라진 채 exit 0 이라 "질문 없는 홀드 0건" 으로 읽힌다.
      + ($noteunknown | sort_by(-.n)
        | map({kind: "hold_note_unknown", repo_short: $rs, issue: .n,
               text: "질문 유무 미확인 #\(.n)(\($rs)) — \(.why)"}))
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
    ),
    # 사람 세션 PR — $ohuman(무소속 후보 중 head 가 `agent/issue-*` 아닌 것). warn 이 아니라
    # note 로 강등한다: 루프가 못 집는 후보를 warn 에 얹으면 조치 불가능한 잡음이 상시화되고
    # (이 이슈의 실측 원인), 그렇다고 그냥 빼면 그 PR 의 존재 자체가 관측에서 사라진다.
    notes: (
      ($ohuman | map({kind: "human_session_pr", repo_short: $rs, pr: .number, issue: .issue,
        text: ("사람 세션 PR #\(.number)(\($rs)) — head " + .headRefName
               + " (agent/issue-* 아님) · "
               + (if .issue == null then "연결 이슈 없음" else "연결 이슈 #\(.issue)" end)
               + " · 루프가 못 집어 warn 아님")}))
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
   + (.warns | map("    - " + .text))
   + [ "  note      \((.notes // []) | length)" ]
   + ((.notes // []) | map("    - " + .text)))
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

  # build_snapshot <noteless 배열> <noteunknown 배열> <claimtimes 배열> <claimcapped 배열>
  #                 <출력 파일> — BUILD_JQ 한 패스(순수 · 부작용 없음).
  build_snapshot() {
    jq -n \
      --argjson issues "$issues_json" \
      --argjson prs_open "$prs_open_json" \
      --argjson prs_closed "$prs_closed_json" \
      --argjson cutoff "$cutoff" \
      --argjson now "$now_epoch" \
      --argjson grace "$grace_min" \
      --argjson ahead "$ahead" \
      --argjson noteless "$1" \
      --argjson noteunknown "$2" \
      --argjson claimtimes "$3" \
      --argjson claimcapped "$4" \
      --arg repo "$repo" --arg rs "$short" --arg since "$since" \
      "$BUILD_JQ" > "$5"
  }
  build_fail() {
    exit_code=1
    jq -nc --arg repo "$repo" --arg rs "$short" --arg err "집계 실패(jq)" \
      '{repo:$repo, repo_short:$rs, ok:false, error:$err}' >> "$tmpdir/repos.jsonl"
  }

  # ── 예비 패스 — 어느 이슈가 사람대기 버킷인지는 버킷 로직만이 안다 ────────
  # 버킷 조건을 여기 다시 적으면(needs-human 이면서 배포대기가 아닌 것) 언젠가 SSOT 와
  # 갈라진다. 그래서 같은 BUILD_JQ 를 `noteless=[]` 로 한 번 돌려 버킷을 얻고, 질문 조회가
  # 실제로 필요할 때만 두 번째 패스를 돈다(jq 는 로컬 · gh 호출 0).
  # 같은 이유로 사망 의심 꼬리표의 claim 시각 후보(#177)도 이 패스의 warn 목록에서 뽑는다 —
  # "꼬리표가 붙는 건" 의 정의는 BUILD_JQ 만이 안다.
  if ! build_snapshot '[]' '[]' '[]' '[]' "$tmpdir/repo.pre.json"; then
    build_fail
    continue
  fi

  # ── 질문(hold-note) 유무 — 사람대기 버킷의 hold:policy|conflict 에만 (#157) ──
  # `hold:ladder` 는 `--note` 가 선택이라 질문이 없는 게 정상이고, 사유 없는 홀드는 이미
  # 별도 warn 이 잡는다. 그 둘까지 물으면 N+1 만 늘고 화면엔 거짓 지적이 는다.
  # 결과는 3상태다 — 질문 있음 / 없음(`$noteless`) / **모름**(`$noteunknown`). 모름을
  # "없음" 으로 접으면 없는 결함을 사람에게 들이밀고, "있음" 으로 접으면 진짜 결함을
  # 감춘다. 둘 다 거짓이라 모름은 모름으로 실어 warn `질문 유무 미확인` 으로 낸다.
  noteless="[]"
  noteunknown="[]"
  nl_sep=""; nl_body=""
  nu_sep=""; nu_body=""
  # unknown <번호> <사유> — 표시는 생략하고 stdout warn 으로 사실을 남긴다.
  mark_unknown() {
    nu_body="${nu_body}${nu_sep}{\"n\":$1,\"why\":\"$2\"}"; nu_sep=","
  }
  # 후보 줄은 `<번호> <사유[|사유]>` — 사유를 함께 실어야 마커를 사유별로 가릴 수 있다
  # (#160). 사유 값은 jq **자기 리터럴 배열**에서만 나온다 — 라벨 문자열을 그대로 흘리면
  # 아래에서 정규식에 끼우는 순간 라벨이 패턴이 된다. `hold:policy`·`hold:conflict` 둘 다
  # 붙은 홀드는 어느 쪽 질문이든 질문이므로 `policy|conflict` 로 잇는다.
  cand_err=$(jq -r '.buckets.human_wait[]
                    | . as $i
                    | (["policy", "conflict"]
                       | map(. as $r | select($i.holds | index($r) != null))) as $rs
                    | select(($rs | length) > 0)
                    | "\($i.number) \($rs | join("|"))"' "$tmpdir/repo.pre.json" 2>&1 > "$tmpdir/cands")
  # shellcheck disable=SC2181  # 위 대입의 종료코드를 봐야 한다(cand_err 은 stderr 만 담는다)
  if [ $? -ne 0 ]; then
    echo "$SELF: $short 사람대기 질문 대상 추출 실패(jq) — 질문 없음 표시를 건너뛴다: $(printf '%s' "$cand_err" | tr '\n' ' ' | cut -c1-200)" >&2
    : > "$tmpdir/cands"
  fi
  if [ -s "$tmpdir/cands" ]; then
    seen=0
    # fd 3 으로 읽는다 — 루프 안에서 gh 를 부르므로 stdin 을 목록에 묶으면 안 된다.
    while IFS=' ' read -r cand creasons <&3; do
      [ -n "$cand" ] || continue
      # 정규식에 값을 끼우기 전 화이트리스트로 못 박는다 — 사유는 이 셋뿐이고(위 jq 가
      # 리터럴로만 만든다) 자유 문자열이 패턴으로 새는 경로를 코드로 막는다. 어긋나면
      # 조회를 걸지 않고 "모른다" 로 남긴다(거짓 `질문 없음` 을 만들지 않는다).
      case "$creasons" in
        policy|conflict|"policy|conflict") ;;
        *) echo "$SELF: $short #$cand 질문 사유 파싱 실패: [$creasons]" >&2
           mark_unknown "$cand" "사유 파싱 실패"; continue ;;
      esac
      seen=$((seen + 1))
      # 호출 상한 — 목록 조회에 `--limit 200` 이 있는데 여기만 무제한이면, 사람대기가
      # 쌓일수록(그게 이 기능이 있는 이유다) 매 틱 gh 호출이 선형으로 는다.
      if [ "$seen" -gt "$HOLD_NOTE_MAX" ]; then
        mark_unknown "$cand" "조회 상한($HOLD_NOTE_MAX) 초과"
        continue
      fi
      if ! run_gh gh issue view "$cand" --repo "$repo" --json comments; then
        echo "$SELF: $short #$cand 질문(hold-note) 코멘트 조회 실패: $GH_ERR" >&2
        mark_unknown "$cand" "조회 실패"
        continue
      fi
      # 세 갈래를 한 번에 가른다. `capped` 가 필요한 이유: `--json comments` 는 페이지네이션
      # 없이 첫 100건만 준다 — 오래 걸린 홀드일수록 코멘트가 길어 마커가 상한 밖으로 밀리면
      # 거짓 `질문 없음` 이 된다. 상한에 닿았는데 못 찾았으면 "없다" 가 아니라 "모른다" 다.
      # 파싱 실패의 빈 출력이 `none` 으로 읽히지 않게 종료코드도 함께 본다.
      # 마커는 **지금 붙은 사유와 같은 사유**만 센다 (#160) — 코멘트는 홀드가 풀려도 남고
      # (재디스패치·홀드 해제 어느 쪽도 지우지 않는다) 라벨만 떨어진다. 사유를 안 가리면
      # 옛 `hold-note: policy` 가 지금의 `conflict` 홀드를 "질문 있음" 으로 위장해, 이
      # 기능이 잡으라고 만들어진 상태(질문 없는 홀드)가 정확히 숨는다. `\s*` 는 생산자
      # (transition.sh)가 `hold-note: <사유>` 로 공백을 넣어 쓰기 때문에 필요하다.
      nstate=$(printf '%s' "$GH_OUT" | jq -r --arg reasons "$creasons" '
        [.comments[]? | .body // ""] as $b
        | ("<!--\\s*hold-note:\\s*(" + $reasons + ")") as $re
        | if ([$b[] | select(test($re))] | length) > 0 then "has"
          elif ($b | length) >= 100 then "capped"
          else "none" end' 2>/dev/null) || nstate=""
      case "$nstate" in
        has)    ;;
        none)   nl_body="${nl_body}${nl_sep}${cand}"; nl_sep="," ;;
        capped) echo "$SELF: $short #$cand 코멘트가 조회 상한(100)에 닿아 마커를 못 봤다" >&2
                mark_unknown "$cand" "코멘트 100건 상한" ;;
        *)      echo "$SELF: $short #$cand 코멘트 응답 파싱 실패" >&2
                mark_unknown "$cand" "응답 파싱 실패" ;;
      esac
    done 3< "$tmpdir/cands"
    [ -z "$nl_body" ] || noteless="[$nl_body]"
    [ -z "$nu_body" ] || noteunknown="[$nu_body]"
  fi

  # ── 사망 의심 경과시간의 기준 시각 — 가장 최근 `agent:claimed` 부착 (#177) ──
  # 종전엔 PR `createdAt` 으로 쟀다. 문구는 "agent:claimed 인데 N분" 인데 실제로 잰 건 PR
  # 나이라, 홀드 해제 뒤 **재디스패치**된 건에서 숫자가 통째로 부풀어 살아 있는 워커를
  # 사망으로 신고했다(실측 #170/PR #172 — 231분으로 신고, 실제 claim 은 7분 전).
  # 조회 대상은 **예비 패스가 이미 고른 꼬리표 대상**(`handoff_overdue`)뿐 — 전체 이슈에
  # 걸면 N+1 로 틱이 느려진다. 못 얻은 건은 목록에 넣지 않는다(= jq 가 `경과 미상` 으로).
  claimtimes="[]"
  claimcapped="[]"
  ct_sep=""; ct_body=""
  cc_sep=""; cc_body=""
  # 후보는 **PR 단위**로 나온다(warns[] 는 무소속 PR 마다 한 줄) — 한 이슈에 무소속 PR 이
  # 둘이면 같은 이슈 번호가 두 줄 나온다. 상한(`CLAIM_TIME_MAX`)은 **고유 이슈 수**를
  # 세야 하므로 여기서 중복을 제거한다(#181) — 안 그러면 같은 타임라인을 두 번 조회하고
  # 상한도 두 번 깎는다. `unique` 는 정렬해 순서가 바뀌므로 안 쓴다 — 상한에 걸려 누가
  # 조회되고 누가 밀리는지가 원래(PR 목록) 등장 순서를 따르게, 첫 등장 순을 그대로 둔다.
  ct_err=$(jq -r '[.warns[]
                  | select(.kind == "orphan_pr" and .handoff_overdue == true and .issue != null)
                  | .issue]
                  | reduce .[] as $n ([]; if index($n) then . else . + [$n] end)
                  | .[]' "$tmpdir/repo.pre.json" 2>&1 > "$tmpdir/ccands")
  # shellcheck disable=SC2181  # 위 대입의 종료코드를 봐야 한다(ct_err 은 stderr 만 담는다)
  if [ $? -ne 0 ]; then
    echo "$SELF: $short 사망 의심 경과시간 대상 추출 실패(jq) — 경과는 미상으로 남는다: $(printf '%s' "$ct_err" | tr '\n' ' ' | cut -c1-200)" >&2
    : > "$tmpdir/ccands"
  fi
  if [ -s "$tmpdir/ccands" ]; then
    cseen=0
    # fd 3 으로 읽는다 — 루프 안에서 gh 를 부르므로 stdin 을 목록에 묶으면 안 된다.
    while IFS= read -r cnum <&3; do
      case "$cnum" in ""|*[!0-9]*) continue ;; esac
      cseen=$((cseen + 1))
      if [ "$cseen" -gt "$CLAIM_TIME_MAX" ]; then
        echo "$SELF: $short #$cnum claim 시각 조회 상한($CLAIM_TIME_MAX) 초과 — 경과 미상" >&2
        # 조회 자체를 안 한 것 — jq 쪽에서 "봤는데 못 얻었다"(확인 필요)와 다른 문구
        # (조회 상한)로 가르려면 이 이슈 번호를 따로 기억해야 한다(#181).
        cc_body="${cc_body}${cc_sep}$cnum"; cc_sep=","
        continue
      fi
      # `--paginate` 는 선택이 아니다: 반송·재디스패치를 여러 번 돈 이슈는 라벨 이벤트만으로도
      # 첫 페이지 밖으로 밀려 **가장 최근** claim 을 놓친다 — 그러면 이 수정이 고치려던 오탐이
      # 옛 claim 이라는 다른 얼굴로 되살아난다(다른 레포 실측: 9분 전 워커를 158분으로 오판).
      # 부분 페이지네이션은 통째로 버린다(reconcile.sh:118 과 같은 규율) — `--paginate` 는
      # 페이지마다 값을 한 줄씩 내므로 뒤 페이지가 실패하면 앞 페이지의 **옛 claim** 이
      # 마지막 값이 된다. 그래서 `|| true` 로 파이프를 삼키지 않고 종료 상태를 먼저 본다.
      if ! run_gh gh api "repos/$repo/issues/$cnum/timeline?per_page=100" --paginate \
          --jq '[.[] | select(.event == "labeled" and .label.name == "agent:claimed") | .created_at] | last // empty'; then
        echo "$SELF: $short #$cnum agent:claimed 시각(타임라인) 조회 실패: $GH_ERR" >&2
        continue
      fi
      # 값을 JSON 에 끼우기 전 **형태를 화이트리스트로** 못 박는다 — `gh api -q` 는 실패
      # 응답의 에러 JSON 도 stdout 으로 흘리고(claim-issue.sh 와 같은 함정), 자유 문자열이
      # 그대로 들어가면 아래 리터럴 조립이 깨진다. 패턴이 GitHub 이 실제로 주는 형태
      # (초 단위 UTC `Z`)로 좁은 이유: jq 의 `fromdateiso8601` 은 오프셋·소수초를 못 읽어
      # **레포 블록 전체가 '집계 실패(jq)'** 로 죽는다. 어긋나면 값이 없는 것으로 본다
      # (그 한 건만 `경과 미상` 으로 degrade — 나머지는 그대로 나온다).
      claimed_at=$(printf '%s\n' "$GH_OUT" \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        | tail -n1)
      if [ -z "$claimed_at" ]; then
        echo "$SELF: $short #$cnum 타임라인에서 agent:claimed 시각을 못 얻음(이벤트 부재·형식 밖) — 경과 미상" >&2
        continue
      fi
      ct_body="${ct_body}${ct_sep}{\"n\":$cnum,\"at\":\"$claimed_at\"}"; ct_sep=","
    done 3< "$tmpdir/ccands"
    [ -z "$ct_body" ] || claimtimes="[$ct_body]"
    [ -z "$cc_body" ] || claimcapped="[$cc_body]"
  fi

  if [ "$noteless" = "[]" ] && [ "$noteunknown" = "[]" ] && [ "$claimtimes" = "[]" ] && [ "$claimcapped" = "[]" ]; then
    # 질문 없는 홀드도 미확인도 claim 시각도 상한 초과도 없으면 예비 패스의 결과가 곧
    # 최종 결과다(재집계 불필요 — 넷 다 빈 값으로 돈 패스라 결과가 같다).
    # mv 실패를 흘리면 바로 아래 jq 가 **직전 레포의** 스냅샷을 읽어 붙인다 — 부분 실패가
    # "성공(남의 데이터)" 으로 접히는 경로라 여기서 끊는다.
    if ! mv "$tmpdir/repo.pre.json" "$tmpdir/repo.json"; then
      build_fail
      continue
    fi
  elif ! build_snapshot "$noteless" "$noteunknown" "$claimtimes" "$claimcapped" "$tmpdir/repo.json"; then
    build_fail
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
    if ! block=$(printf '%s\n' "$line" | jq -r --arg scope "$scope_shorts" "$RENDER_JQ"); then
      exit_code=1
      snapshot_fail_line "블록 렌더 실패(jq)"
      continue
    fi
    printf '%s\n' "$block"
    if [ -n "$post_loop" ]; then
      rrepo=$(printf '%s' "$line" | jq -r '.repo // empty'); rshort=$(printf '%s' "$line" | jq -r '.repo_short // empty')
      if [ -n "$rrepo" ] && ! post_dashboard "$rrepo" "$rshort" "$block"; then exit_code=1; fi
    fi
  done < "$tmpdir/repos.jsonl"
fi

exit "$exit_code"
