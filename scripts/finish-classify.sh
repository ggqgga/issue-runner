#!/usr/bin/env bash
# finish-classify.sh <repo> <pr> [<issue>]
#
# 완결 유실 갭 판별자 (#88). PR 의 코멘트·타임스탬프·CI 를 읽어 종료 상태를 아래
# 여섯 중 하나로 stdout 에 분류한다 (SKILL ② Maintain 규칙4 가 이 결과로 4a/4b/4c
# 를 분기한다 — SKILL prose 를 얇게 유지하고 결정적으로 테스트 가능하게).
#
#   done_verdict   최신 `머지 판정:` 이 ✅ 이고, **두 시각(판정·head 커밋)을 모두 얻어**
#                  그 판정이 head 커밋보다 늦음(또는 같음)을 증명함
#                  → 4a 무접촉(closeout 픽업 대기)
#   held           최신 `머지 판정:` 이 ⚠            → 4a 무접촉(워커 명시 보류·needs-human)
#   stale_inline   🔄(최종 판정 없음) + 최신 검증자 CLEAN + 그 코멘트가 STALE_FINISH_MIN
#                  초과            → 4b 인라인 최종 판정 대리 append(에이전트 없음)
#   stale_reverify 🔄 + 검증자 부재 또는 미해결 BLOCKER + STALE_FINISH_MIN 초과
#                  → 4c 완결 에이전트 재디스패치(검증자 재실행)
#   no_verdict     `머지 판정:` 코멘트가 **한 건도 없음**(접두 매칭 **개수 0** 으로 확인한다 —
#                  코멘트 조회 실패는 `comments_lookup`, 못 읽는 판정 본문은 개수 ≥ 1 이라
#                  둘 다 이 계급이 아니다 · 🔄·✅·⚠ 어느 것도 없다 — 워커가
#                  10단계 전에 죽었다) + **CI 가 초록**(실패 0 **이고 미완료 0** — #421)
#                  + STALE_FINISH_MIN 초과 + **진행 증거 없음**(#396)
#                  → closeout ①-b 재디스패치(`stale_reverify` 와 같은 조치)
#   active         위 어디에도 안 걸림(진행 중·시간버퍼 미도달·우리 형상 아님) 또는
#                  최신 `머지 판정: ✅` 의 신선도를 **증명하지 못함**(head 커밋보다 이르거나,
#                  두 시각 중 하나라도 못 얻음 — 반송 뒤 재디스패치된 새 커밋이 아직
#                  검증 안 됨, #171) → 무접촉(새 판정을 기다림)
#                  또는 **진행 증거가 있음**(#206 — 아래 참조)
#
# **`no_verdict` — 판정 코멘트가 0건인 초록 PR (#396).** 워커가 `머지 판정: 🔄` 를 찍기 **전**에
# 죽으면(handoff 이전 사망) PR 은 CI 초록인데 판정 코멘트가 0건이다. 그 칸은 세 레인 어디에도
# 안 들어갔다 — issue-runner ② Maintain 은 "CI green·리뷰 없음" 을 사람 리뷰 대기로 무접촉,
# closeout ①-b 는 🔄/✅ 를 전제, 이 파일은 판정이 없으면 `active` 였다(무한 무접촉).
# 그래서 **판정 부재 + CI 초록 + 증거 없음 + 시간버퍼 초과**를 별도 계급으로 낸다.
#
# **"초록" 은 실패 0 이 아니라 실패 0 + 미완료 0 이다**(#421 [P2-2]). 이 계급의 주장은 "CI 는
# 끝났는데 판정만 없다" 이므로, 아직 도는 체크(check-run `status != COMPLETED` · local-ci 커밋
# 상태 `pending`)가 하나라도 있으면 주장할 수 없다 — 그 창에 커밋·claim 만 낡으면 **아직 초록도
# 아닌 PR** 이 재디스패치된다(CI 큐 대기 중인 PR 이 정확히 그 모양이다, #127·#200). 롤업 조회
# 실패도 같은 처분(`ci_lookup=unknown` → active) — 이 파일의 "증명 못 하면 안 연다" 규율.
#
# 스테일 클록의 기준 시각은 `agent:claimed` 부착 시각과 head 커밋 시각 중 **더 최신** 쪽이다
# (🔄 계열과 같은 max 규율 — 판정 코멘트가 없으니 그 두 축만 남는다). 반송 마커 시각도 같은
# 클록에 합류한다(#308). 두 시각을 **하나도** 못 얻거나 조회가 `unknown` 이면 `active` 다 — 이
# 파일의 규율 그대로, 되돌릴 수 없는 쪽(재디스패치)을 증명 없이 열지 않는다.
#
# 실무에서 이 계급을 여는 것은 시간버퍼(`STALE_FINISH_MIN`)가 아니라 **타임박스**인 경우가 많다:
# 살아 있는 회차는 `agent:claimed` 가 붙어 있어 진행 증거 ③(claim 이 `ISSUE_TIMEBOX_HOURS` 안)
# 가 참이므로, claim 이 그 상한을 넘길 때까지는 `active` 다. 버퍼만 보고 "왜 안 걸리나" 를
# 고치려 들지 마라 — 그 게이트가 살아 있는 워커의 브랜치를 지킨다.
#
# **진행 증거 게이트 (#206).** 🔄 계열 두 갈래(stale_inline·stale_reverify)는 "워커가 죽었다"
# 는 주장이다. 그 주장을 내기 전에 `progress-evidence.sh` 에 워커가 살아 있다는 증거가
# 있는지 묻고, 있으면 `active` 로 떨어뜨린다. 증거는 세 가지다 —
#   ① 최신 커밋이 STALL_MIN 이내   ② 그 head SHA 의 CI 티켓이 큐에 살아 있음
#   ③ **현재 회차의 `agent:claimed` 가 ISSUE_TIMEBOX_HOURS 안에 붙어 아직 붙어 있음**
# ②가 특히 중요하다: 박스 전역 직렬 CI 큐(#127) 대기는 워커가 통제할 수 없는 시간이라
# 커밋이 한 시간 넘게 멈춰 있어도 워커는 살아 있다(#200 실측 72분·64분). 술어는
# `progress-evidence.sh` **한 자리**에 있다 — `timebox-check.sh`(#200)가 부르는 그 자리다.
# 두 벌로 복제하면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다.
#
# ③은 **첫 푸시 전 창** 전용이다(#206 attempt 2 codex BLOCKER). ①②는 워커가 이미 뭔가
# 남긴 뒤에만 존재하는 증거라, 반송 직후 교체 워커가 디스패치됐지만 아직 아무것도 push
# 하지 않은 구간에서는 둘 다 없다 — 그때 이 파일이 보는 값(판정 시각·head 시각)은 전부
# **이전 attempt** 의 것이고 `STALE_FINISH_MIN` 을 넘겨 `stale_reverify` 가 난다. 그러면
# `closeout-redispatch` 가 **지금 일하고 있는 워커의 `agent:claimed` 를 떼어낸다.**
# 그 창을 덮는 유일한 신호가 "이번 회차가 언제 시작됐나" = `agent:claimed` 부착 시각이고,
# 조회는 `claim-at.sh` **한 자리**다(존재가 아니라 시각을 쓰는 이유는 그 파일 주석 참조).
#
# 판정 실패(헬퍼가 `unknown` 이거나 아예 못 돔)는 "증거 없음" 이 **아니다** — 그 방향으로
# 접으면 조회 실패 한 번에 살아 있는 워커의 브랜치를 채간다(되돌릴 수 없는 손해). 그래서
# 여기선 증명 실패를 `active`(무접촉) 로 받는다. ✅ 갈래의 fail-closed 와 방향이 반대로
# 보이지만 **같은 원리**다: 되돌릴 수 없는 쪽(머지·재디스패치)을 증명 없이 열지 않는다.
#
# 그 규율은 **판정 입력을 얻는 자리**에서 시작한다(#206 회차2). head 조회는 세 결말을
# 갖는다 — `ok`(값을 얻음) · `unknown`(조회 실패) · `none`(조회는 됐는데 커밋 증거 없음).
# 셋을 `head_sha=none` 하나에 실으면 하류가 실패를 부재로 읽어 살아 있는 워커를
# 재디스패치한다. 그래서 조회의 **종료코드를 보존**해 `head_lookup` 플래그로 기억하고,
# 진행 증거 헬퍼에도 같은 3값 어휘(`--commit-at unknown`)로 넘긴다.
#
# 판별 근거: 살아있는 워커는 `검증자 리뷰:` 코멘트 직후 수초 내 최종 판정을 찍는다.
# 최신 검증자가 CLEAN 인데 STALE_FINISH_MIN 넘게 최종 판정이 없으면 워커 사망 확실.
# 진행 중 fix 루프는 최신 검증자 코멘트가 recent 이거나 non-CLEAN 이라 자동 제외된다.
#
# 워커 활동 = 코멘트 **또는 커밋**. bounce 후 attempt N+1 워커는 같은 브랜치에서
# 이어가며 커밋은 하되 종료 직전에만 판정 코멘트를 찍는다 — 코멘트 시각만 보면
# 낡은 🔄 만 남아 살아있는 워커를 사망(stale_reverify)으로 오판한다(#110, 실증
# BodaT PR #2237). head 커밋 시각(FC_HEAD_AT)을 스테일 클록의 max 에 합류시켜 방어한다.
#
# **최신 반송 마커 시각도 같은 클록에 든다(#308).** 반송 전이는 `agent:claimed` 를 떼므로
# 반송 직후 디스패처가 다시 붙이기 전 창에서는 진행 증거 세 축이 전부 "old/none" 이다 —
# 그 창의 CONFLICTING PR 이 `stale_reverify` 로 떨어져 **사인이 틀린 멱등 마커**
# (`완결 유실(검증 전 사망)`)를 원장에 남겼다. 마커 판별은 `bounce-state.sh` 한 자리를
# 되물어 얻는다(로직 두 벌 금지) — 아래 `bounce_epoch_after` 주석 참조.
#
# 최신 `머지 판정:`/`검증자 리뷰:` 판정은 코멘트 배열의 **마지막 매칭**을 쓴다
# (재리뷰·재판정 대비). 한/영 병행 워커라 영문 접두(Merge verdict/Verifier review)도 본다.
#
# 테스트/재현용 env 오버라이드 (없으면 gh/date 로 실측):
#   FC_COMMENTS_FILE  코멘트 배열 JSON 이 담긴 **파일 경로** — 대용량 안전 경로(#171
#                      반송 4회차 [P2]). 코멘트 전량을 환경변수 하나로 넘기면 exec 한계
#                      (리눅스 MAX_ARG_STRLEN 128KB)를 넘는 순간 이 스크립트가 **시작조차
#                      못 하고** 호출자의 판정이 비어 그 PR 이 매 스윕에서 조용히 빠진다.
#                      FC_COMMENTS_JSON 보다 우선하며, 읽기 실패는 실조회로 **새지 않고**
#                      빈 코멘트(=active, fail-closed)로 떨어진다.
#   FC_COMMENTS_JSON  코멘트 배열 JSON([{body,createdAt},...]) — 실조회 대체(소용량 픽스처용).
#                      둘 다 미지정 시 pr-comments.sh 로 **페이지네이션 전량** 조회한다
#                      (`gh pr view --json comments` 의 첫 100건 상한 회피, #171).
#   FC_FAILING        실패 체크 수(정수) — statusCheckRollup 대체
#   FC_HEAD_SHA       head 커밋 SHA — pr-head-at.sh --with-sha 실조회 대체(#206 진행 증거 ②).
#                      미지정이면 `none`(큐 증거 없음)으로 본다.
#   FC_QUEUE_LOG      queue.log 경로 — progress-evidence.sh 의 PE_QUEUE_LOG 로 전달(픽스처용).
#   FC_HEAD_AT        head 커밋 시각(ISO8601) — pr-head-at.sh 실조회 대체(주입 = `ok`).
#                      주입 경로는 호출자가 값을 준 것이므로 `unknown`(조회 실패)이 아니다 —
#                      조회 실패 축은 실호출 경로에서만 나고, 테스트도 **실호출 자리를
#                      스텁으로 물려** 문다(주입만 무는 테스트는 그 자리의 회귀에 눈먼다).
#                      빈 값/파싱 불가 = **못 얻음**. 🔄 계열 갈래(#110 스테일 클록)에선
#                      종전대로 epoch 0 으로 degrade 하지만, `✅` 갈래(#171 머지 게이트)
#                      에선 증명 실패이므로 done_verdict 를 내지 않고 active 다.
#   FC_ISSUE          연결 이슈 번호 — 세 번째 위치 인자의 env 판(진행 증거 ③).
#                      둘 다 없으면 `gh pr view --json headRefName,closingIssuesReferences` 로
#                      한 번 묻고, `lib/loop.jq` 의 `linked_issue` 로 브랜치 이슈를 고른다(#495 —
#                      head 의 `agent/issue-N` ∈ refs → N, 아니면 refs 1건 → 그것, 아니면 없음.
#                      `[0]` 은 닫는 이슈가 둘 이상일 때
#                      남의 이슈를 가리킨다, #206 회차3). 조회 실패·무출력은 `unknown`.
#   FC_CLAIMED_AT     `agent:claimed` 부착 시각(ISO8601) 또는 `none`/`unknown` —
#                      claim-at.sh 실조회 대체. **설정돼 있으면 실조회로 새지 않는다**
#                      (픽스처 테스트의 네트워크 무접속을 이 변수 하나가 지킨다).
#   FC_NOW            현재 epoch(초) — date 대체
#   STALE_FINISH_MIN  시간버퍼(분) — 값은 `scripts/lib/constants.sh` (#427 로 한 자리로)
#   ISSUE_TIMEBOX_HOURS  claim 신선도 상한(시간) — progress-evidence.sh 가 같은 파일에서 읽는다
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/constants.sh
. "$SCRIPT_DIR/lib/constants.sh"   # 상수는 한 자리 (#427)

# 픽스처용 큐 로그 경로는 **있을 때만** 넘긴다 — 기본 경로는 progress-evidence.sh 가
# 이미 갖고 있고, 여기 한 벌 더 적으면 이 PR 이 세운 SSOT 규율과 반대 방향이다.
[ -n "${FC_QUEUE_LOG:-}" ] && export PE_QUEUE_LOG="$FC_QUEUE_LOG"

repo=${1:?repo}
pr=${2:?pr_num}
issue=${3:-${FC_ISSUE:-}}

stale_min="$STALE_FINISH_MIN"
stale_sec=$((stale_min * 60))
now=${FC_NOW:-$(date -u +%s)}

# ── 입력 수집 (env 오버라이드 우선) ──
# `comments_lookup` — 코멘트 **조회의 결말**을 담는 별도 플래그(#396). `head_lookup` 과 같은
# 규율이다: 아래 폴백은 실패를 `[]`(빈 코멘트)로 떨어뜨리는데, `[]` 는 기존 갈래에선 전부
# `active` 로 수렴해 안전했지만 `no_verdict` 갈래에선 **"판정 코멘트가 0건이다" 라는 적극적
# 주장**과 글자가 같아진다. 조회 실패 한 번이 재디스패치 근거가 되면 이 파일이 지켜 온
# fail-closed 가 그 칸에서만 뒤집힌다(PR#139: 빈 결과와 실패를 구분하라).
comments_lookup=ok
if [ -n "${FC_COMMENTS_FILE:-}" ]; then
  # 파일 경로 주입(#171 반송 4회차 [P2]) — 페이지네이션으로 상한이 사라진 코멘트 전량은
  # 환경변수 하나에 담기엔 크다(exec 한계 128KB). 읽기 실패는 **실조회로 새지 않는다**:
  # 호출자가 "이 파일이 곧 판정 입력" 이라고 계약한 이상, 그걸 못 읽었는데 다른 출처로
  # 조용히 갈아타면 어떤 입력으로 판정했는지 알 수 없다 → 빈 코멘트(=active) 로 떨어뜨려
  # 게이트를 닫는다.
  comments=$(cat "$FC_COMMENTS_FILE" 2>/dev/null) || { comments=''; comments_lookup=unknown; }
elif [ -n "${FC_COMMENTS_JSON:-}" ]; then
  comments="$FC_COMMENTS_JSON"
else
  # 코멘트는 **페이지네이션**해서 전량 읽는다(#171 반송 3회차 [P1-2]).
  # `gh pr view --json comments` 는 첫 100건만 준다 — 반송을 여러 번 도는 PR 은
  # 코멘트가 쉽게 그 상한을 넘고, 그러면 101번째 이후의 새 ✅ 를 못 봐 머지 가능한
  # PR 이 영영 후보에 안 뜨거나(조용한 큐 사망) 101번째 이후의 반송 마커를 놓쳐
  # 반송된 PR 이 통과한다. 조회 로직은 pr-comments.sh **한 자리**에 있다(사유·순서
  # 계약은 그 파일 주석 참조).
  #
  # 조회 실패는 `[]` 로 떨어뜨린다 — 빈 코멘트에는 판정 코멘트가 없으므로 아래 모든
  # 갈래가 active(게이트 닫힘)로 수렴한다. 부분 출력을 정상값으로 채택하지 않는 것이
  # 핵심이다(PR#139 교훈: 빈 결과와 실패를 구분하고, 실패는 가드 분기로 보내라).
  comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || { comments=''; comments_lookup=unknown; }
fi
# 빈 문자열도 조회 실패다 — 성공한 조회는 코멘트 0건이라도 `[]` 라는 **글자**를 낸다
# (pr-comments.sh 계약). 여기서 갈라 두지 않으면 위 세 경로의 실패가 다시 합쳐진다.
[ -n "$comments" ] || { comments='[]'; comments_lookup=unknown; }

# ── CI 롤업 = 실패 수 + **미완료 수**, 한 조회에서 (#421) ──────────────────────
# 미완료를 따로 세는 이유는 위 `no_verdict` 문단 참조(그 계급만 이 값을 읽는다 — 종전 갈래의
# 입력인 `failing` 의 뜻과 처분은 한 글자도 안 바뀐다).
# 미완료 술어는 `closeout-ci-pass.sh` 의 "그 외 레포" 분기와 **같은 낱말**이다(종결 상태
# allowlist 의 여집합). 그 스크립트를 직접 부르지 않는 이유: 그것은 `repo-dir.sh` + 로컬 CI
# 캐시를 타는 **통과 판정**이라, 모든 입력을 env 로 주입받는 이 파일의 무접속 테스트 계약
# (`FC_*`)을 깬다. 여기서 세는 것은 통과 모양이 아니라 미완료 개수뿐이라 두 번째 판정기가
# 되지 않는다.
# `ci_lookup` — 조회의 결말을 담는 별도 플래그(head_lookup·comments_lookup 과 같은 3값 규율의
# 2값판: ok|unknown). 조회 실패를 0 으로 접으면 "롤업을 못 읽었다" 가 "초록이다" 로 둔갑한다.
ci_lookup=ok
if [ -n "${FC_FAILING:-}" ] || [ -n "${FC_PENDING+x}" ]; then
  failing="${FC_FAILING:-0}"
  pending="${FC_PENDING:-0}"
else
  rollup=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup 2>/dev/null) || rollup=''
  failing=$(printf '%s' "$rollup" | jq '[.statusCheckRollup[]? | select((.conclusion // .state // "")
      | test("FAILURE|ERROR|CANCELLED|TIMED_OUT"))] | length' 2>/dev/null) || failing=''
  # 미완료 = check-run 이 COMPLETED 가 아니고 커밋 상태도 종결값이 아닌 것.
  pending=$(printf '%s' "$rollup" | jq '[.statusCheckRollup[]? | select(((.status // "") != "COMPLETED")
      and ((.state // "") != "SUCCESS") and ((.state // "") != "FAILURE")
      and ((.state // "") != "ERROR"))] | length' 2>/dev/null) || pending=''
fi
# 정수가 아니면(빈 값·jq 실패·주입 오타) 조회 실패와 같은 처분이다. `failing` 은 종전대로 0 으로
# 정규화해 아래 CI 실패 가드의 출력을 보존하고, 그 사실은 `ci_lookup` 이 기억해 `no_verdict`
# 만 읽는다.
case "${failing:-}" in ''|*[!0-9]*) ci_lookup=unknown; failing=0 ;; esac
case "${pending:-}" in ''|*[!0-9]*) ci_lookup=unknown; pending=0 ;; esac

# head_lookup — **조회의 결말을 담는 별도 플래그**(#206 회차2). 값 셋:
#   ok       조회(또는 주입)에 성공 — head_at·head_sha 가 그 PR 의 값이다
#   unknown  조회 **실패** — 값이 있는지조차 모른다(pr-head-at.sh 비0 종료 등)
#   none     조회는 됐는데 커밋 증거가 없음 — 아래 has_progress 의 정규화가 만든다
# 회차1 은 이 셋을 `head_sha=none` 이라는 **공유 센티널 하나**에 실었다. 그러면 하류가
# 실패를 부재로 읽어 살아 있는 워커를 재디스패치한다(PR#168 교훈: 탈출 사유를 별도
# 플래그로 기억하고 하류가 그걸 읽게 하라 · PR#139: 빈 결과와 실패를 구분하라).
# `timebox-check.sh` 가 같은 자리에서 이미 이 형상이다(`branch_lookup_failed` → unknown).
head_lookup=ok
if [ -n "${FC_HEAD_AT+x}" ]; then
  head_at="$FC_HEAD_AT"
  head_sha="${FC_HEAD_SHA:-none}"
else
  # head 시각은 **커밋 목록을 세지 않고** 얻는다(#171 반송 4회차 [P1-1]).
  # `gh pr view --json commits` 는 GraphQL commits(first:100) 이라 101번째부터 안 온다 —
  # 그때 `last` 는 head 가 아니라 100번째 커밋이고, 그 이른 시각으로 비교하면 낡은 ✅ 가
  # `head <= verdict` 를 만족해 done_verdict 가 난다(코멘트 100건 상한과 같은 함정).
  # 조회 로직은 pr-head-at.sh **한 자리**에 있다(사유·계약은 그 파일 주석 참조).
  # 조회 실패는 빈 값으로 떨어뜨린다 — 아래 ✅ 갈래가 "증명 실패 = active" 로 받는다.
  # `--with-sha` 로 **한 번의 조회에서** 시각과 SHA 를 함께 받는다(#206) — SHA 는 진행 증거
  # ②(그 SHA 의 CI 티켓이 큐에 살아 있는가)에 쓴다. 따로 한 번 더 물으면 pr-head-at.sh 가
  # 없애려던 "head 를 묻는 두 자리" 가 되살아난다.
  #
  # **종료코드를 버리지 않는다**(#206 회차2, 회차1 BLOCKER). `|| head_raw=''` 로 rc 를
  # 삼키면 일시적 gh 실패가 "이 PR 엔 커밋이 없다"로 둔갑하고, 아래 진행 증거 게이트가
  # 그 결론으로 **살아 있는 워커의 반송 회차를 재디스패치**한다. pr-head-at.sh 는 단계마다
  # 종료코드를 검사해 하나라도 못 얻으면 exit 1 로 알리도록 이미 설계돼 있다 — 그 신호를
  # 여기서 흘리면 그 설계가 무의미해진다.
  head_rc=0
  head_raw=$("$SCRIPT_DIR/pr-head-at.sh" --with-sha "$repo" "$pr" 2>/dev/null) || head_rc=$?
  if [ "$head_rc" != 0 ]; then
    head_lookup=unknown; head_sha=unknown; head_at=''
  elif [ -n "$head_raw" ]; then
    head_sha="${head_raw%% *}"
    head_at="${head_raw##* }"
  else
    # exit 0 인데 빈 출력 = 헬퍼 계약 위반(열린 PR 에는 반드시 head 커밋이 있다).
    # "커밋이 없다" 로 읽을 수 없으므로 조회 실패와 같게 받는다.
    head_lookup=unknown; head_sha=unknown; head_at=''
  fi
fi

# ISO8601(...Z) → epoch. BSD(date -j -f) 우선, GNU(date -d) 폴백.
#
# **파싱 전에 형식을 검사한다**(#171 반송 3회차 [P1-1]). GNU 폴백이 있다는 것 자체가
# GNU 박스를 지원 대상으로 삼았다는 뜻인데, 두 구현은 *잘못된 입력*에서 갈린다:
#   BSD `date -j -f "%Y-%m-%dT%H:%M:%SZ" "" +%s` → `illegal time format`, 실패(빈 값)
#   GNU `date -d "" +%s`                        → **실패하지 않고 "오늘 자정" epoch**
# 그래서 형식 검사가 없으면 GNU 박스에서 head 조회가 비었는데도 head_epoch 가 비지
# 않는다 — 자정 이후 찍힌 정상 ✅ 이면 `head <= verdict` 가 참이 돼 done_verdict 가
# 나온다. 아래 ✅ 갈래가 없애려던 fail-open 이 GNU 에서만 되살아나는 것이다.
# (GNU 는 `yesterday`·`now` 같은 느슨한 표현도 받는다 — 빈 문자열만의 문제가 아니다.)
#
# 게이트가 "빈 입력이 유효값으로 둔갑" 을 입구에서 막아야 한다는 게 PR#139 교훈의 3판:
# 저기선 실패가 부분 출력으로, 여기선 **실패조차 안 하고** 그럴듯한 값으로 새어 든다.
# 형식 검사를 앞에 두면 두 date 구현에서 결과가 같아진다(테스트는 GNU 스텁으로 재현).
iso_to_epoch() {
  local iso="${1:-}"
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  date -u -d "$iso" +%s 2>/dev/null
}

# 접두 매칭 코멘트의 마지막 것에서 필드 추출. $1=loop.jq 술어 이름 · $2=body|createdAt.
# 접두 집합은 `lib/loop.jq` 한 자리다 (#426 로 한 자리로) — 술어 **이름**만 넘긴다.
# 여기서 기호(✅/⚠/🔄)까지 무는 술어를 쓰지 않는 것은 의도다: 아래 갈래가 본문을
# `case *✅*` 로 **포함** 검사해 `머지 판정(재심): ✅` 같은 변형도 최종 판정으로 받는다.
# `is_verdict_ok`(정확 접두)로 바꾸면 그 변형이 조용히 no_verdict 로 떨어진다 — 소비처마다
# 다른 이 경계는 그대로 둔다(행동 불변).
last_matching() {
  local pred="$1" field="$2"
  printf '%s' "$comments" | jq -L "$SCRIPT_DIR/lib" -r --arg f "$field" \
    "include \"loop\";
    [ .[] | select(.body | $pred) ]
    | last | if . == null then \"\" else .[\$f] end"
}

verdict_body=$(last_matching has_verdict_prefix body)
verdict_at=$(last_matching has_verdict_prefix createdAt)
head_epoch=$(iso_to_epoch "${head_at:-}")
verdict_epoch=$(iso_to_epoch "$verdict_at")

# ── 최종 판정이 이미 있는 경우(4a) ──
case "$verdict_body" in
  *✅*)
    # #171: ✅ 를 head 커밋과 묶는다. 반송(재디스패치) 뒤 새 커밋이 올라왔는데 그
    # 커밋 **이전**에 찍힌 ✅ 를 근거로 머지 후보 삼지 않는다.
    #
    # 게이트 방향 = **증명되지 않으면 열지 않는다.** 두 시각(판정·head 커밋)을 모두
    # 얻어 `head <= verdict` 를 확인했을 때만 done_verdict 다. 하나라도 못 얻으면
    # (빈 commits·gh 조회 실패·날짜 파싱 실패) 판정이 현재 head 이후임을 *증명하지
    # 못한* 것이므로 active — 워커의 새 판정을 기다린다.
    #
    # 옛 구현은 못 얻은 시각을 `${head_epoch:-0}` 으로 뭉개 done_verdict 로 떨어뜨리고
    # 이를 "degrade, fail-open 아님" 이라 적었다. 그건 틀렸다 — **머지 게이트에서
    # 증명 실패를 통과로 처리하는 것이 곧 fail-open** 이다(PR#139 교훈: 빈 결과와
    # 실패를 구분하라). 🔄 계열 갈래의 epoch-0 degrade 는 그대로 둔다: 거긴 게이트가
    # 아니라 스테일 클록이라 0 이 "더 오래된 활동" 으로 안전하게 흡수된다.
    #
    # 정상 판정은 막지 않는다 — 판정이 head 보다 늦거나 같은 초면 종전대로
    # done_verdict 다(새 보류 상태를 만드는 게 아니다).
    if [ -n "$head_epoch" ] && [ -n "$verdict_epoch" ] \
       && [ "$head_epoch" -le "$verdict_epoch" ] 2>/dev/null; then
      echo done_verdict
    else
      echo active
    fi
    exit 0
    ;;
  *⚠*) echo held; exit 0 ;;
esac

# 여기부터: 최종 판정 없음. 🔄 판정 코멘트가 있어야 우리 형상(워커가 10단계 도달)이고,
# 🔄 가 없는 칸(판정 코멘트 0건)은 `no_verdict` 판별로 간다(#396). 그 게이트는 아래
# **헬퍼 정의부 뒤**에 있다 — 판정에 `has_progress`·`join_bounce_epoch` 가 필요해서다.
# 출력은 옮기기 전과 같다: 그 사이에 있는 CI 실패 가드도 같은 `active` 로 수렴하고,
# 검증자 코멘트 추출은 로컬 jq 라 부작용이 없다.

# CI 실패면 규칙1 대상 → 여기서 완결 판별 안 함(방어적 가드).
if [ "${failing:-0}" -gt 0 ] 2>/dev/null; then
  echo active; exit 0
fi

verifier_body=$(last_matching has_verifier_prefix body)
verifier_at=$(last_matching has_verifier_prefix createdAt)

# 검증자 CLEAN/전건해소 판정 (보수적 — 확실히 깨끗할 때만 인라인 자동 판정 허용).
# 안전 게이트라 애매하면 non-clean 으로 떨어뜨린다(→ 재디스패치=안전). 3중 방어:
#   (1) 명시적 부정문("CLEAN 아님","not clean")은 *CLEAN* 부분매칭에 걸리므로 배제.
#   (2) BLOCKER 언급이 있으면(해소 표기 "BLOCKER 0"/"BLOCKER 없음"/전건해소 제외) 무조건
#       non-clean — 혼합대소문자 부정문("not CLEAN yet, BLOCKER remains")도 이 게이트가 잡는다.
#       주의: 워커 실제 표기 "BLOCKER 없음(게이트 통과)" = 블로커 0 = CLEAN 이므로 해소
#       표기에 포함한다(안 하면 "없음"의 BLOCKER 부분매칭으로 검증된 PR 이 오판된다).
#   (3) 그 다음에야 긍정 CLEAN 토큰을 본다.
is_clean() {
  case "$1" in
    *"CLEAN 아님"*|*"not clean"*|*"NOT CLEAN"*|*"미해결 BLOCKER"*) return 1 ;;
  esac
  case "$1" in
    *"BLOCKER 0"*|*"BLOCKER 없음"*|*"BLOCKER: 없음"*|*"no BLOCKER"*|*"no blocker"*|*전건해소*|*"전건 해소"*|*"all resolved"*) : ;;  # 해소 표기 → 긍정 판정으로
    *BLOCKER*) return 1 ;;                                         # 그 외 BLOCKER 언급 = 미해결
  esac
  case "$1" in
    *CLEAN*|*"BLOCKER 0"*|*"BLOCKER 없음"*|*"BLOCKER: 없음"*|*"no BLOCKER"*|*"no blocker"*|*전건해소*|*"전건 해소"*|*"all resolved"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 진행 증거 게이트 (#206) ─────────────────────────────────────────────
# `progress-evidence.sh` **한 자리**에 묻는다(#200 이 세운 술어 — timebox-check.sh 가
# 부르는 그 자리). 여기 두 번째 계산기를 만들지 않는다.
#
# 아래 스테일 클록(max_epoch)과 역할이 다르다 — 스테일 클록은 *마지막 워커 활동 이후
# 얼마나 지났나*(#110) 이고, 이 게이트는 *워커가 지금도 진행 중이라는 증거가 있나*(#200)
# 다. 후자만 두 소비자를 갖는 술어라 한 자리로 묶었다.
#
# 반환: 0 = 진행 증거 있음(또는 **판정 불가**) → 살아 있다고 본다. 1 = 증거 없음.
# 판정 불가를 "증거 없음" 으로 접지 않는 이유는 파일 머리 주석 참조(되돌릴 수 없는 쪽을
# 증명 없이 열지 않는다).
# 진행 증거 ③ 의 입력 — 현재 회차의 `agent:claimed` 부착 시각을 헬퍼 어휘로 낸다.
# 세 값 그대로: `<ISO8601>` / `none`(붙어 있지 않음·연결 이슈 없음) / `unknown`(조회 실패).
# **여기서도 실패를 `none` 으로 접지 않는다** — 접으면 조회 실패 한 번이 "이번 회차는 시작된
# 적 없다" 로 둔갑해 살아 있는 워커의 claim 을 떼어낸다(회차1·회차2 BLOCKER 와 같은 가족).
#
# 이 조회는 **🔄 계열 갈래를 내기 직전에만** 돈다(has_progress 안에서 불린다) — 정상 PR 은
# ✅ 갈래에서 이미 빠져나가므로 스윕 한 틱의 gh 호출이 PR 수만큼 늘지 않는다.
claimed_arg() {
  # 같은 판정 안에서 **두 번 묻지 않는다**(#396). `no_verdict` 갈래는 이 값을 기준 시각(clock)과
  # 진행 증거 ③ 두 곳에서 쓰는데, 그냥 두 번 부르면 gh 왕복이 두 번이다. 명령치환 안에서의
  # 대입은 부모 셸로 나가지 않으므로 캐시는 **부모가** 채운다(`_claimed_arg_cache=`).
  if [ -n "${_claimed_arg_cache+x}" ]; then
    printf '%s' "$_claimed_arg_cache"
    return 0
  fi
  # 주입이 있으면 실조회로 **새지 않는다**. 빈 문자열 주입은 `none` 으로 본다
  # (호출자가 "claim 증거 없음" 을 뜻한 것 — 실패는 `unknown` 이라는 단어로 말한다).
  if [ -n "${FC_CLAIMED_AT+x}" ]; then
    printf '%s' "${FC_CLAIMED_AT:-none}"
    return 0
  fi
  local iss="$issue" meta out rc=0
  if [ -z "$iss" ]; then
    # 연결 이슈를 모르면 한 번 묻는다. **조회 실패와 "연결 이슈 없음" 을 가른다**:
    # 실패는 unknown(판정 불가), 빈 결과는 none(재디스패치할 이슈 자체가 없는 PR).
    #
    # 브랜치 이슈는 `lib/loop.jq` 의 `linked_issue` **한 자리**다(#495): head 의 `agent/issue-N`
    # 이 refs 에 있으면 그것, 아니면 refs 가 정확히 1건일 때 그것, 아니면 빈 값(fail-closed).
    # 여기서 필요한 것은 **"이 브랜치의 워커가 집어간 이슈"** 이고, 그것은 head 의 N 을
    # `Closes` 축(refs)으로 **확인한** 것이다 — `[0]` 은 GitHub 이 본문의 `Closes` 를 만난
    # 순서일 뿐이라 닫는 이슈가 둘 이상이면 **남의 이슈**를 가리킨다(#206 회차3 BLOCKER).
    # 이 레포 실데이터:
    #   PR #113  head=agent/issue-109  refs=[108, 109]   ← [0] 은 #108
    #   PR #112  head=session/issues-110-109-108  refs=[108, 109]   ← 짝 증명 불가 → 빈 값
    # `[0]` 을 쓰면 그 PR 의 claim 조회가 #108 로 가 `none` 이 나오고, 증거 ③ 이 조용히
    # 꺼져 **지금 일하고 있는 워커**가 `stale_reverify` → 재디스패치된다(워크트리 경합).
    # head 단독 폴백도 없다 — `Refs #N`·`(no-issue)` PR(refs 빈 배열)은 증거 ③ 을 포기한다
    # (그 PR 은 ①커밋·②판정 시각 축으로만 잰다). closeout-eligible·pr-state 가 같은 술어를
    # 부른다 — 세 소비자가 다른 이슈를 볼 수 없다.
    #
    # 조회는 여전히 **한 번**이다(head 를 같은 응답에서 받는다 — 라운드트립을 늘리지 않는다).
    # `-q` 대신 별도 `jq` 를 쓰는 것은 `claim-at.sh` 와 같은 규율이다: 스텁이 실제 응답
    # JSON 을 내고 술어 자체가 테스트에 물린다(가공된 번호를 주면 어느 술어든 초록이다).
    meta=$(gh pr view "$pr" --repo "$repo" --json headRefName,closingIssuesReferences 2>/dev/null) \
      || { printf 'unknown'; return 0; }
    # exit 0 + 무출력도 조회 실패다 — 빈 응답을 "연결 이슈 없음"(none)으로 접으면 헛돈
    # 조회 한 번이 살아있는 워커의 claim 을 떼는 근거가 된다(PR#139 — 빈 결과와 실패를 가른다).
    [ -n "$meta" ] || { printf 'unknown'; return 0; }
    iss=$(printf '%s' "$meta" | jq -L "$SCRIPT_DIR/lib" -r 'include "loop";
      linked_issue(.headRefName; [(.closingIssuesReferences // [])[].number]) // empty
      ' 2>/dev/null) || { printf 'unknown'; return 0; }
  fi
  [ -n "$iss" ] || { printf 'none'; return 0; }
  out=$("$SCRIPT_DIR/claim-at.sh" "$repo" "$iss" 2>/dev/null) || rc=$?
  # 비0 종료·무출력(실행 비트 누락 exit 126 포함) = 조회 실패. 빈 값을 `none` 으로
  # 정규화하면 헬퍼가 조용히 degrade 한 것이 증거 부재로 둔갑한다(PR#173 교훈).
  if [ "$rc" != 0 ] || [ -z "$out" ]; then printf 'unknown'; return 0; fi
  printf '%s' "$out"
}

has_progress() {
  local out rc=0
  # 커밋 시각은 **이미 파싱에 성공한 것만** 넘기고, 아니면 헬퍼의 입력 계약대로 문자열
  # `none`(= 커밋 증거 없음)을 **명시**한다. head_epoch 가 비었다는 것은 시각을 못 얻었거나
  # (빈 값) 형식이 아니라는(쓰레기 값) 뜻이고, 이 파일의 🔄 계열 갈래는 그걸 종전부터
  # "커밋 증거 없음(epoch 0 degrade)" 으로 다룬다 — 그대로 넘겨 `unknown` 으로 만들면
  # 쓰레기 값 하나가 모든 갈래를 active 로 덮어 완결 유실 회수가 통째로 멈춘다.
  # 판정 술어는 그대로 헬퍼 한 자리이고, 여기서 하는 것은 그 입력 계약으로의 정규화다.
  # (빈 문자열을 그냥 넘기지 않는 이유: 헬퍼는 빈 값을 `none` 으로 접지 않고 판정 실패로
  #  본다 — 호출자가 "증거 없음" 을 뜻했는지 "못 얻었다" 를 뜻했는지 헬퍼는 모르기 때문.)
  #
  # **조회 실패는 그 셋 중 어느 것도 아니다**(#206 회차2). 헬퍼의 입력 어휘 3값
  # (`<값>`/`none`/`unknown`)에서 `unknown` 으로 넘겨, 판정 불가가 하류까지 그대로
  # 전달되게 한다 — 여기서 `none` 으로 접으면 조회 실패가 "커밋 증거 없음" 이 되어
  # 살아 있는 워커의 반송 회차가 재디스패치된다(회차1 BLOCKER).
  local commit_arg=none sha_arg="${head_sha:-none}"
  if [ "$head_lookup" = unknown ]; then
    commit_arg=unknown; sha_arg=unknown
  elif [ -n "$head_epoch" ]; then
    commit_arg="$head_at"
  fi
  out=$("$SCRIPT_DIR/progress-evidence.sh" --now "$now" \
    --commit-at "$commit_arg" --head-sha "$sha_arg" \
    --claimed-at "$(claimed_arg)" 2>/dev/null) || rc=$?
  case "${out%% *}" in
    progress) return 0 ;;
    none)     [ "$rc" = 0 ] && return 1; return 0 ;;
    *)        return 0 ;;   # unknown·무출력·exec 실패(126/127) = 판정 불가
  esac
}

# 시간버퍼를 넘긴 갈래를 낼 때 진행 증거를 한 번 더 묻는다 — 증거가 있으면 워커는
# 살아 있으므로 `active`.
emit_stale() {  # emit_stale <stale_inline|stale_reverify>
  if has_progress; then echo active; else echo "$1"; fi
}

# 두 epoch 중 큰 값(가장 최신 워커 활동).
max_epoch() {
  local a="${1:-0}" b="${2:-0}"
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  if [ "$a" -ge "$b" ]; then echo "$a"; else echo "$b"; fi
}

# ── 반송 마커 시각 = 스테일 클록의 네 번째 입력 (#308) ────────────────────
# 왜 필요한가: `verify-redispatch`·`closeout-redispatch` 는 반송하면서 이슈의
# `agent:claimed` 를 **뗀다**. 그래서 **반송 직후 디스패처가 다시 붙이기 전 창**에서는
# 진행 증거 세 축이 전부 "old/none" 으로 읽힌다 — head 커밋은 E2E 대기 탓에 30분 이상
# 전이고, CI 큐 티켓은 이미 빠졌고, claim 은 `none` 이다. 그 창에 main 이 움직여
# CONFLICTING 이 되면 closeout ①-b 예외 갈래가 `stale_reverify` 를 내고, `재디스패치:
# #N — 완결 유실(검증 전 사망)` 이라는 **사인이 틀린 멱등 마커**가 PR 원장에 남는다
# (워커는 안 죽었다 — 방금 반송돼 교체 대기 중일 뿐). #218 이 MERGEABLE 쪽에서 막은
# 바로 그 "사실과 다른 멱등 마커" 가 CONFLICTING 쪽에서 되살아난 것이다.
#
# 반송 마커 자체가 "그 시각에 누군가 이 PR 에 손을 댔다" 는 워커 레인 활동이므로,
# head 커밋 시각을 합류시킨 #110 과 **같은 방식**으로 스테일 클록에 합류시킨다.
#
# **마커 판별은 `bounce-state.sh` 한 자리다.** 그 파일의 매칭 규칙(마커 집합 +
# 위치·꼬리 술어)은 #171·#196·#212·#221·#251 이 다섯 회차에 걸쳐 깎은 것이라 여기에
# 베끼면 두 번째 계산기가 다른 수를 센다(그 파일의 마커 집합 주석이 명시적으로 금지하고,
# `bin/ci` 가 집합 정의의 사본이 scripts/ 안에 또 있는지 매번 검사한다).
# 그래서 **코멘트 한 건짜리 배열을 그 스크립트에 먹여** 판별만 되묻는다 — 한 건 배열은
# 반송 마커면 `bounced`(뒤따르는 판정 코멘트가 없으므로), 아니면 `ok` 다. 코멘트 출처는
# 이 파일이 이미 읽어 둔 `$comments`(= `pr-comments.sh` **페이지네이션 전량**)이라
# `--json comments` 첫 100건 상한(#173)을 다시 밟지 않는다.
#
# **훑는 범위**: 배열의 **최신부터** 거꾸로 보다가 `floor`(이미 계산된 스테일 클록) 이하
# 시각에 닿으면 멈춘다. `max(floor, x)` 는 `x <= floor` 면 `floor` 이므로 결과가 바뀌지
# 않는다 — 전수 훑기와 **판정이 동일**하고, 정상 PR 의 gh 호출/프로세스만 아낀다.
#
# **못 얻는 경로는 전부 안전한 쪽(`unknown` → 호출자가 `now` 로 접어 `active`)이다**
# (#206 회차1·2 가 세운 규율, PR#139/#168: 빈 결과와 실패를 가르고 사유를 별도 값으로).
#   ⑴ 조회 실패 — `bounce-state.sh` 가 비0 종료·예상 밖 출력(부재·실행 비트 누락 126/127
#      포함)이거나 임시파일을 못 만듦 → `unknown`
#   ⑵ 반송 마커가 아예 없는 정상 PR — 훑기가 끝까지 돌고 빈 값 → **클록 불변**(기존
#      갈래 그대로). 이게 "기존 예외 갈래가 통째로 죽지 않는다" 를 지키는 자리다.
#   ⑶ 마커는 찾았는데 `createdAt` 이 비었거나 형식 불량(파싱 실패) → `unknown`
#      (마커가 언제인지 모르면 신선한지도 모른다 — 되돌릴 수 없는 재디스패치를 열지 않는다).
bounce_epoch_after() {  # bounce_epoch_after <floor_epoch> → stdout <epoch>|''|unknown
  local floor="${1:-0}" tmp out='' idx at ep bs rc listing tab
  [ -n "$floor" ] || floor=0
  tmp=$(mktemp 2>/dev/null) || { printf 'unknown'; return 0; }
  tab=$(printf '\t')
  # `<index>\t<createdAt>` 을 **최신부터** 한 줄씩. 중간 산출을 변수로 끊어 아래 루프의
  # 입력 heredoc 이 명령치환을 품지 않게 한다(`bin/ci` 의 인용 안 한 heredoc 린트 #119).
  # jq 실패는 빈 문자열 → 루프가 한 번도 안 돌고 `''`(= 클록 불변)이다. 이 경로에 오려면
  # `$comments` 가 애초에 파싱 불가여야 하는데, 그러면 위 `last_matching` 도 전부 빈 값이라
  # 판정은 이미 `active` 로 끝난다(여기까지 오지 않는다).
  listing=$(printf '%s' "$comments" \
    | jq -r 'to_entries | reverse | .[] | "\(.key)\t\(.value.createdAt // "")"' 2>/dev/null)
  while IFS="$tab" read -r idx at; do
    [ -n "$idx" ] || continue
    ep=$(iso_to_epoch "${at:-}") || ep=''
    # floor 이하로 내려왔으면 더 볼 필요가 없다(max 가 안 바뀐다). 시각을 못 읽은
    # 코멘트는 이 비교를 건너뛰고 아래 판별로 간다 — 조용히 멈추면 그 뒤의 마커를 놓친다.
    if [ -n "$ep" ] && [ "$ep" -le "$floor" ] 2>/dev/null; then break; fi
    printf '%s' "$comments" | jq --argjson i "$idx" '[.[$i]]' > "$tmp" 2>/dev/null \
      || { out=unknown; break; }
    rc=0
    bs=$(BOUNCE_COMMENTS_FILE="$tmp" "$SCRIPT_DIR/bounce-state.sh" "$repo" "$pr" 2>/dev/null) || rc=$?
    if [ "$rc" != 0 ]; then out=unknown; break; fi
    case "$bs" in
      ok) continue ;;                                  # 마커 아님 — 더 옛 코멘트로
      bounced|held) if [ -n "$ep" ]; then out="$ep"; else out=unknown; fi; break ;;
      *) out=unknown; break ;;                         # 형상 밖 출력 = 판정 불가
    esac
  done <<EOF
$listing
EOF
  rm -f "$tmp"
  printf '%s' "$out"
}

# 스테일 클록에 반송 마커 시각을 합류시킨다(#308). 판정 불가(`unknown`)는 **가장 신선한
# 활동**(=`now`)으로 접는다 → age 0 → `active`(무접촉). 이 파일의 규율 그대로다: 되돌릴
# 수 없는 쪽(재디스패치·머지)을 증명 없이 열지 않는다.
join_bounce_epoch() {  # join_bounce_epoch <ref_epoch> → stdout <epoch>
  local ref="${1:-0}" be
  [ -n "$ref" ] || ref=0
  be=$(bounce_epoch_after "$ref")
  [ "$be" = unknown ] && be="$now"
  max_epoch "$ref" "$be"
}

# ── 🔄 게이트 · `no_verdict` 판별 (#396) ──────────────────────────────────────
# ✅/⚠ 갈래를 빠져나온 PR 중 `머지 판정: 🔄` 를 가진 것만 아래 완결 유실 갈래로 간다.
# 나머지는 **판정 코멘트가 0건**(또는 `머지 판정:` 은 있는데 세 기호가 하나도 없는 형태)이고,
# 그건 워커가 10단계 전에 죽었거나 애초에 우리 형상이 아니라는 뜻이다 — 둘을 가르는 것은
# **시간과 증거**다: 기준 시각에서 `STALE_FINISH_MIN` 을 넘겼고 진행 증거가 없으면
# `no_verdict`(회수 대상), 아니면 `active`(종전 동작 그대로).
#
# 기준 시각 = `agent:claimed` 부착 시각과 head 커밋 시각 중 **더 최신** 쪽(🔄 계열의 max 규율
# 과 같다 — 판정 코멘트가 없으니 두 축만 남는다) + 반송 마커 시각 합류(#308).
# **증명 실패는 전부 `active`** 다: claim 조회 `unknown` · head 조회 실패(`head_lookup`≠ok) ·
# 두 축 모두 못 얻음. 이 파일의 규율 그대로, 되돌릴 수 없는 쪽(재디스패치)을 증명 없이 열지
# 않는다. 진행 증거 게이트(`emit_stale`)도 한 번 더 탄다 — 살아 있는 회차는 claim 이
# `ISSUE_TIMEBOX_HOURS` 안이라 증거 ③ 으로 `active` 가 된다.
case "$verdict_body" in
  *🔄*) : ;;
  *)
    # 코멘트를 **못 읽었으면** 판정 0건을 주장할 수 없다(위 comments_lookup 주석).
    [ "$comments_lookup" = ok ] || { echo active; exit 0; }
    # 이 갈래는 `verdict_body` 가 세 기호를 **안 가진** 모든 경우로 들어온다 — 그 안에는
    # ⑴ 판정 코멘트가 정말 0건 ⑵ `머지 판정:` 은 있는데 우리가 못 읽는 본문(새 문형·기호
    # 없는 판정) ⑶ `last_matching` 의 jq 가 실패해 빈 값이 나온 경우가 섞여 있다. ⑵⑶ 을
    # `no_verdict` 로 부르면 **판정이 있는 PR 을 재디스패치**한다 — `comments_lookup` 이 막는
    # 것은 조회 실패뿐이고 이 셋은 그 뒤에 온다. 그래서 주장하는 사실 그대로,
    # **매칭 코멘트 수가 정확히 0** 일 때만 이 계급을 연다(그 외는 종전대로 active).
    printf '%s' "$comments" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo active; exit 0; }
    nv_n=$(printf '%s' "$comments" | jq -L "$SCRIPT_DIR/lib" -r '
      include "loop";
      [ .[]? | (.body // "") | select(has_verdict_prefix) ] | length' 2>/dev/null) \
      || { echo active; exit 0; }
    case "$nv_n" in
      0) ;;                              # 판정 코멘트 0건 — 이 계급의 유일한 형상
      *) echo active; exit 0 ;;          # 1건 이상(못 읽는 본문) · 빈 값(jq 실패) = 주장 불가
    esac
    # CI 가 아직 도는 중이면 "초록인데 판정만 없다" 가 아니다(#421 [P2-2]) — 실패 가드(위)는
    # 실패만 세므로 **미완료**는 여기서 따로 막는다. 롤업을 못 읽은 경우도 같은 처분.
    [ "$ci_lookup" = ok ] || { echo active; exit 0; }
    if [ "$pending" -gt 0 ]; then echo active; exit 0; fi
    nv_claimed=$(claimed_arg)
    _claimed_arg_cache="$nv_claimed"   # 아래 emit_stale 의 진행 증거 조회가 같은 값을 재사용
    nv_claim_epoch=''
    case "$nv_claimed" in
      unknown) echo active; exit 0 ;;
      none)    : ;;
      *)       nv_claim_epoch=$(iso_to_epoch "$nv_claimed") || nv_claim_epoch='' ;;
    esac
    [ "$head_lookup" = ok ] || { echo active; exit 0; }
    nv_ref=$(max_epoch "$head_epoch" "$nv_claim_epoch")
    [ "${nv_ref:-0}" != 0 ] || { echo active; exit 0; }
    nv_ref=$(join_bounce_epoch "$nv_ref")
    nv_age=$((now - ${nv_ref:-$now}))
    if [ "$nv_age" -gt "$stale_sec" ]; then emit_stale no_verdict; else echo active; fi
    exit 0 ;;
esac

if [ -z "$verifier_body" ]; then
  # 검증자 부재 → 10단계 후 11단계 전 사망 가능. 🔄 판정 코멘트 vs head 커밋 중
  # 더 최신 쪽으로 경과를 잰다(#110 — attempt N+1 워커가 커밋만 하고 아직
  # 판정을 안 찍은 창을 살아있음으로 인정).
  ref_epoch_nv=$(max_epoch "$verdict_epoch" "$head_epoch")
  # 반송 마커 시각도 같은 클록에 든다(#308) — 반송 직후 라벨 공백 창은 `active`.
  ref_epoch_nv=$(join_bounce_epoch "$ref_epoch_nv")
  age=$((now - ${ref_epoch_nv:-$now}))
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_reverify; else echo active; fi
  exit 0
fi

# 스테일 클록 = 가장 최신 워커 활동(검증자 시각 vs 이후 재-🔄 판정 시각 vs head 커밋
# 시각). 검증자 CLEAN 뒤에 워커가 다시 🔄 를 찍고(재수정 루프) 새 검증자를 아직 안
# 올린 경우, 최신 판정은 여전히 🔄 라 이 분기로 오는데 검증자 시각만 보면 살아있는
# 워커를 사망으로 오판한다 → verdict_epoch 와의 max 로 방어. head 커밋도 같은 이유로
# 합류(#110) — 검증자 CLEAN 뒤 워커가 커밋만 이어가고 아직 재-🔄 를 안 찍은 창도
# 살아있음으로 인정해야 stale_inline 인라인 대리 판정이 덮치지 않는다.
verifier_epoch=$(iso_to_epoch "$verifier_at")
ref_epoch=$(max_epoch "$verifier_epoch" "$verdict_epoch")
ref_epoch=$(max_epoch "$ref_epoch" "$head_epoch")
# 반송 마커 시각도 같은 클록에 든다(#308) — 반송 직후 라벨 공백 창은 `active`.
ref_epoch=$(join_bounce_epoch "$ref_epoch")
age=$((now - ${ref_epoch:-$now}))
if is_clean "$verifier_body"; then
  # 검증자 CLEAN — 최종 판정만 유실. 시간버퍼 초과면 인라인 대리 판정.
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_inline; else echo active; fi
else
  # 검증자 미해결 BLOCKER — 코드품질 검증 미완. 시간버퍼 초과면 완결 에이전트 재디스패치.
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_reverify; else echo active; fi
fi
