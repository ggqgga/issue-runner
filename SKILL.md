---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

## 상수

- `MAX_AGENTS = 5` — 동시 in-flight 이슈 상한 (in-flight 정의는 ③-1 —
  사람 리뷰 대기 PR 은 점유하지 않는다)
- `MAX_OPEN_PRS = 10` — 열린 PR 총수 적체 상한. 도달 시 신규 디스패치만 멈춘다
  (보수는 계속) — 사람 머지가 밀릴 때 PR 끼리 rebase conflict 가 폭증하는 것을 막는
  배압(backpressure)
- `MAX_REPAIRS_PER_PR = 3` — PR 1개당 보수 디스패치 상한 (② Maintain 서킷 브레이커)
- `ISSUE_TIMEBOX_HOURS = 1` — PR 없는 `working` 이슈에 허용하는 claim 경과 시간
  (① Reconcile timebox)
- `STALE_FINISH_MIN = 30` — 완결 유실 판별 시간버퍼(분). `finish-classify.sh` 의
  버퍼이며, 이제 이 헬퍼는 **closeout ①-b 정체 스윕**이 소비한다(issue-runner 는 규칙4
  원복 후 직접 쓰지 않음). 살아있는 워커는 `검증자 리뷰:` 직후 수초 내 최종 판정을
  찍으므로, 최신 검증자가 CLEAN 인데 이 버퍼를 넘도록 최종 판정이 없으면 워커 사망으로
  간주. 진행 중 fix 루프는 최신 검증자 코멘트가 recent 이거나 non-CLEAN 이라 자동 제외.
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — 이슈당 소프트 토큰 예산. 하드 캡이
  아니라 ④ Report 의 관측 기준 (Agent 호출에 예산 API 가 없어 강제는 불가).
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — 리뷰·교훈 추출용 검증자 서브에이전트 타입.
  **출력 계약 (SSOT — 다른 모든 곳은 이 항목을 참조한다)**: 리뷰 호출은
  read-only(코드 변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·발견 없으면 'CLEAN'·
  BLOCKER 는 게이트(해결 전 종료 금지), 교훈 추출 호출(① Reconcile)은
  '교훈 1줄 또는 NONE'. 검증자는 SKILL.md 를 읽지 않으므로 호출 프롬프트
  문자열에는 이 계약이 그대로 담겨야 한다 — 프롬프트가 유일한 전달 경로다.
  **폴백**: codex 플러그인 미설치 환경(Agent 툴의 subagent_type 목록에 위 타입이
  없거나, 호출이 unknown subagent type 오류로 실패)에서는 `general-purpose` 를
  검증자로 쓴다 — 같은 프롬프트로 호출하므로 계약도 동일하게 적용된다.
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착,
  완결 유실 PR 에 최종 `머지 판정: ✅` 대리 append(그 회수는 closeout ①-b 스윕 소유).
  **허용**: ② Maintain 규칙0 의 단계 라벨 `flow:*` 보정(워커가 각 단계에서 직접 다는
  자가설명 라벨이라 스캔 안전망으로 실제 상태에 맞추는 것은 조작이 아니다).

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — 성공 종료. **고아 워커 정리(선행)**: 이 이슈의 워커가 아직 살아있으면
  (TaskList 로 `<repo>#<num> 구현` 백그라운드 에이전트 확인) `TaskStop` 으로 중단하라 —
  PR 이 머지됐으니 워커 작업은 무의미하고, 방치하면 이미 종료된 PR 을 붙들고 무한
  스핀한다(관측된 고아 유령의 회수 경로). 그다음 **lessons 단계**: 아래 실패 신호가 하나라도 잡히면 (전부
  `gh pr view <pr> --repo <repo>` 로 확인) `VERIFIER` 서브에이전트(## 상수의 VERIFIER
  계약·폴백을 따른다)를 동기 호출하라. 신호가 하나도 안 잡히면 호출하지 말고 NONE 으로
  둔다(lessons 미기록): (1) CHANGES_REQUESTED 리뷰(`--json reviews`) · (2) `gh run list`
  CI 실패(GitHub Actions 레포) · (3) **local-ci commit status 실패 이력** — PR 의 커밋
  중 하나라도 local-ci 컨텍스트가 FAILURE 였으면(`--json commits` 로 커밋 SHA 를 열거하고
  각 SHA 를 `gh api repos/<repo>/commits/<sha>/statuses` 로 조회한다 — HEAD 의 `--json
  statusCheckRollup` 은 컨텍스트당 최신 1개만 남아 실패 이력을 못 본다. 도중 실패 후 새
  SHA 로 고쳐 최종 SUCCESS 라도 실패 이력이면 교훈 후보. local-ci 체제 레포는 gh run
  list 가 항상 빈값이라 이 신호가 실질 트리거다) · (4) **검증자 리뷰 코멘트의 BLOCKER**
  — PR 의 `마감 검증:`·`검증자 리뷰:` 코멘트에 BLOCKER 가 있었던 경우(`--json comments`).

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
  (= `<repo-dir>/.loop/lessons.md` — repos.conf 매핑 머신에서도 기록·읽기가 같은 파일을
  가리키게 하는 유일한 해석)에 `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append.
  **20줄 초과 시 가장 오래된 줄 삭제** (context rot 방어). lessons를 CLAUDE.md로 옮기는
  것은 사람만 한다.
- `rejected` — 사람이 PR을 거부함. **살아있는 워커가 있으면 `merged` 와 동일하게
  `TaskStop` 으로 먼저 중단**(고아 방지). lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. 죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로. 커밋이 전혀 없으면
  claim 해제 **전에** 이슈 최신 코멘트를 확인하라 —
  `gh issue view <num> --repo <repo> --json comments --jq '.comments | last.body'`
  가 `BLOCKED:` 로 시작하면 워커가 사람 개입이 필요해서 멈춘 것이다 (모호 스펙 /
  계획-현실 불일치 / 동일 실패 반복): 재디스패치 복귀 대신
  `gh issue edit <num> --repo <repo> --add-label needs-human` 으로 `needs-human`
  을 부착하고, worktree 제거 + claim 해제 후 warn 으로 ④ Report 에 BLOCKED 사유를
  올려라 (사람이 원인을 해소하고 needs-human 을 떼면 다시 흐른다 — README
  '가드레일' 규약). BLOCKED 코멘트가 아니면 worktree 제거 후 claim 해제
  (재디스패치 가능 상태로 복귀).
  **timebox (무진전 감지)**: 살아있어도 claim 경과 시간을 확인하라 —
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  로 claim 시각을 구하고 (빈 응답이면 worktree 디렉토리 생성 시각으로 대체),
  현재 시각과의 차가 `ISSUE_TIMEBOX_HOURS` 를 초과하면 (`working` 은 정의상 PR 없음):
  ⓐ TaskStop 으로 워커를 중단하고 (push 된 커밋은 원격 브랜치에 보존된다),
  ⓑ worktree 를 제거하라 — `git -C <repo-dir> worktree remove --force <wt>` 후
  `git -C <repo-dir> branch -D agent/issue-<num>`. 미push 잔여물은 timebox 초과의
  대가로 **의도적으로 폐기**한다 — 남겨두면 다음 디스패치의 make-worktree 가 중단된
  워커의 중간 상태를 그대로 물려줘 worktree 격리가 깨진다 (dirty-warn 보류 규율은
  원인 불명의 잔여물용이므로 이 의도적 중단에는 적용하지 않는다).
  ⓒ `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"` 로 claim 을
  해제한 뒤, ⓓ warn 으로 ④ Report 에 올려라 (agent-ready 가 남아 있으므로 다음 틱이
  원격 브랜치 위 새 worktree 에서 재디스패치한다).

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

**0. 단계 라벨 보정 (best-effort, 스캔할 때 붙인다).** 이 PR 의 마지막 판정 코멘트를
읽어(`gh pr view <pr> --repo <repo> --json comments`) 단계 라벨 `flow:*` 를 실제 상태에
맞춘다 — 워커·verify-runner 가 각 단계에서 직접 붙이지만 크래시·놓침이 있을 수 있어
스캔이 안전망이다. **단, `flow:verify` 또는 `harvesting` 라벨이 붙은 PR 은 이 보정을
건너뛴다**(각각 verify-runner·closeout 소유 — 아래 소유 규칙과 동일). 그 외 PR 만 보정:
마지막 코멘트가 `머지 판정: ✅` → `flow:ready`(closeout 이 집는다), `머지 판정: 🔄`(✅ 전)
→ `flow:verify`(verify-runner 에 넘김 — 워커가 라벨을 못 붙이고 죽은 경우 안전망),
`머지 판정: ⚠ 보류` → flow:* 제거(needs-human 경로). 목표 라벨과 현재가 다를 때만
`gh issue edit <pr> --repo <repo> --add-label <목표> --remove-label <나머지 flow:*>` 로
교체한다(멱등 — 같으면 skip, `--remove-label` 은 없는 라벨에 무해). 최초 CI·구현 단계는
PR 이 아직 없어 이슈 `agent:claimed` 로만 보인다(`flow:ci` 는 재-CI 도는 PR 에만 뜬다).

**서킷 브레이커 — 아래 1~3 의 모든 보수 디스패치 전 공통**:
PR 본문에서 `<!-- repair-count: N -->` HTML 주석을 읽어라
(`gh pr view <pr> --repo <repo> --json body`; 주석이 없으면 N = 0).
N ≥ `MAX_REPAIRS_PER_PR` 이면 **보수를 디스패치하지 않는다** — 이슈에
`gh issue edit <num> --repo <repo> --add-label needs-human` 으로 `needs-human`
라벨을 부착하고 warn 으로 ④ Report 에 올려라. N 이 상한 미만이면 보수 에이전트를
디스패치하면서 PR 본문의 주석을 `<!-- repair-count: N+1 -->` 로 갱신하라
(`gh pr edit <pr> --repo <repo> --body ...` — 주석이 없었으면 본문 끝에 새로 추가,
나머지 본문은 그대로 유지). 같은 PR 에 1~3 의 사유가 여러 개 겹쳐도 **틱당 같은 PR
의 보수 에이전트는 1개** — 모든 수리 지시를 그 한 에이전트의 프롬프트에 합치고,
N 도 디스패치당 1만 올린다.

1. `failing > 0` → 실패 로그를 확인하고 (gh run view --log-failed), 플레이크로 보이면
   re-run (gh run rerun), 진짜 실패면 워커 템플릿 파일
   `~/.claude/skills/issue-runner/references/worker-template.md` (③-4d 와 같은
   방식으로 읽어 채운다)로 **보수 에이전트**를 백그라운드 디스패치 (worktree 가
   없으면 `$SCRIPTS/make-worktree.sh` 가 원격 브랜치 위에 재생성해 준다). 보수
   지시는 템플릿의 "절차" 대신 구체적 수리 내용으로 교체하되 나머지(복합 명령,
   push 규율, 금지 사항)는 유지.
2. 미해결 리뷰 코멘트 → 같은 방식으로 보수 에이전트에 코멘트 해결을 지시.
   단, 워커 자신이 남긴 상태 코멘트(`머지 판정:`·`검증자 리뷰:` 로 시작)는
   리뷰 코멘트가 아니다 — 보수 사유로 세지 마라.
3. base 와 conflict → **더 이상 여기서 rebase 하지 않는다** — conflict-rebase 소유는
   closeout 으로 이관됐다(closeout ③ 2단계가 `harvesting` 점유 후 직접 rebase·머지).
   issue-runner 는 conflict PR 을 건드리지 않고 다음 closeout 틱에 맡긴다. 미완이므로
   in-flight 로는 계속 계수한다(③ 배압 유지).
4. CI green + 미해결 리뷰 코멘트 없음 → **손대지 않는다.** 사람 리뷰 대기이거나,
   워커가 최종 `머지 판정: ✅` 를 못 찍고 죽은 **완결 유실** 상태다. 완결 유실 회수
   (검증까지 도달한 PR 마감 / 검증 전 죽은 PR 재디스패치)는 **closeout ①-b 정체 스윕**이
   소유한다(`finish-classify.sh` 로 결정적 분류). issue-runner 는 완결 유실 PR 에
   최종 판정을 대리 append 하거나 완결 에이전트를 재디스패치하지 **않는다** — 완결
   로직을 이 루프에 얹지 않고 마감 담당(closeout)에 일원화한다(역할 분리). 단계 라벨
   `flow:*` 보정(규칙0)만 유지해 PR 리스트 자가설명·closeout 스윕 보조신호를 남긴다.

`harvesting` 이벤트 = closeout 마감 진행 중 → **건드리지 않는다**(보수·rebase·리뷰 코멘트 해결 제외). closeout 가 머지/정리한다.

`flow:verify` PR = verify-runner 검증 진행 중(워커가 구현+결정적CI+PR 까지 마치고 넘김)
→ **건드리지 않는다**(위 1~4 보수·규칙0 보정 모두 제외 — harvesting 과 동형). verify-runner
가 E2E·codex 검증 후 통과면 `머지 판정: ✅`+`flow:ready` 로 closeout 에 넘기고, 실패면
연결 이슈에 `agent-ready` 를 재부착해 반송한다(그때 이 루프의 Dispatch 가 같은 브랜치서
워커를 다시 붙인다 — 정상 재디스패치). 결정적 CI 실패조차 verify-runner 가 반송으로
처리하므로 issue-runner 는 flow:verify PR 의 CI 도 손대지 않는다(사각지대 방지).

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + 이번 틱에 ②로 투입한 보수 + **빨간 PR**
   (`pr_open` 중 CI 실패·미해결 리뷰 코멘트 = ② 1~2 의 보수 대상, 그리고 conflict =
   closeout 이관분이나 미완이라 배압으로 함께 계수)의 수.
   **CI green + 코멘트 없음 PR(② 4, 사람 리뷰 대기)은 슬롯을 점유하지 않는다** —
   에이전트가 손댈 일이 없는 휴면 상태이므로 새 일을 막지 않는다.
   **`flow:verify` PR 도 슬롯을 점유하지 않는다** — verify-runner 소유(이 루프 워커의
   일이 아님)이므로 in-flight 에서 제외한다. 이것이 검증을 별도 레인으로 뺀 throughput
   이득의 실체다: 워커가 PR 을 열고 `flow:verify` 로 넘기는 즉시 슬롯이 반납돼, 느린
   E2E·codex 대기가 더 이상 이 루프의 5슬롯을 붙잡지 않는다.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
   **적체 배압**: 상태 무관 열린 PR 총수가 `MAX_OPEN_PRS` 이상이면 신규 디스패치를
   건너뛰고 ④ Report 에 "머지 대기 적체 N개" warn 을 올린다 (보수는 ② 에서 계속 돈다).
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로
   보이는 이슈가 둘 이상이면 이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다
   (충돌은 다음 틱 rebase 가 풀어준다).
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim 등)하면 다음 후보로.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로.
   c. `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
      (= `<repo-dir>/.loop/lessons.md`, 기록 경로와 동일 해석)가 있으면 내용을 읽어 둔다.
   d. 디스패치 직전 `~/.claude/skills/issue-runner/references/worker-template.md` 를
      읽고 placeholder(`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>`
      `<REPO_DIR>` `<LESSONS_OR_"없음">`)를 채워 투입하라 (Agent 툴 백그라운드 디스패치
      — 호출 시그니처는 템플릿 파일 상단에 있다).
      `<DEFAULT_BRANCH>` 는
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name` 으로 채운다.
      `<REPO_DIR>` 는 `$SCRIPTS/repo-dir.sh <repo>` 출력(메인 체크아웃 절대경로)으로
      채운다 — 워커의 codegraph 탐색(`-p`)이 이 경로의 인덱스를 읽는다.
      (워커는 더 이상 codex 검증자를 스폰하지 않는다 — 검증은 verify-runner 소유라
      `<VERIFIER>` placeholder 가 필요 없다. VERIFIER 상수는 ① Reconcile 의 교훈 추출에만 쓰인다.)

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 대기(사람 리뷰) N · warn N`.
warn 이 있으면 경로와 사유를 그 아래 나열.
**토큰 관측 (소프트 예산)**: 완료 보고를 낸 워커가 있으면 이슈별 한 줄
`토큰: <repo>#<num> <이번 보고치> (누적 <합>)` 을 추가하라. 이번 보고치는 완료
알림의 subagent_tokens (없으면 `?` — 누적에선 0 취급), 누적은 컨텍스트에 보이는
이전 틱 Report 의 같은 이슈 `토큰:` 수치 + 이번 보고치 (안 보이면 이번 보고치 그대로).
누적이 `SOFT_TOKEN_BUDGET_PER_ISSUE` 초과면 그 줄에 **"소프트 예산 초과 —
needs-human 승격 권고"** 를 명시하라 (보고만 — 라벨 부착·워커 중단 등 자동 조치 금지).
모든 카운트가 0이면 "조용함" 한 줄만.
조용한 틱이라도 **③ Dispatch 의 eligible 스캔(eligible-issues.sh)은 매 틱 실행하라** —
새 agent-ready 이슈는 reconcile 이벤트를 만들지 않으므로 eligible 스캔을 거르면 절전
모드가 신규 후보에 영구히 맹목이 된다(빈 큐에서는 search/issues 1콜이라 비용 무시 가능).
eligible 이 비고 reconcile 도 조용하면 "조용함" 한 줄만 보고하고 끝내라.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 전제: 이 루프는 **GitHub 위에서만** 동작한다 — 이슈·라벨·assignee·PR이 상태의
  단일 진실 원천이며 GitHub Actions 는 불필요(local-ci 설계). 필요 권한 등 상세는
  README §전제 조건.
- 설치 모델: 계정 전체 디스패처이므로 스킬은 사용자 레벨(`~/.claude/skills`)에
  전역 설치하고, 레포별 참여는 라벨 옵트인(`setup-labels.sh`)으로 분리한다 —
  README §설치.
- 병행 운용: 세션 cwd 에 `.loop/repos` 허용목록이 있으면 수집(eligible)·점검
  (reconcile)이 그 레포들로 제한된다 — 프로젝트별 루프 세션 분리용, 없으면 계정
  전체. 스크립트가 자동 적용하므로 틱에서 따로 할 일은 없다 (README §사용법).
- 병용 권장: [codegraph](https://github.com/colbymchenry/codegraph) — 레포에
  `.codegraph/` 인덱스가 있으면 워커가 반복 grep/Read 대신 인덱스 조회로 탐색해
  토큰·툴콜을 줄인다. 레포별 `codegraph init` 옵트인 — 없어도 루프는 동작한다
  (README §전제 조건).
- 설계에 참고한 문헌: [Claude Code goal 공식 문서](https://code.claude.com/docs/en/goal) ·
  [루프 엔지니어링 담론 (YouTube)](https://www.youtube.com/watch?v=EH2MMQTaPEA) ·
  [Reddit 토론](https://www.reddit.com/r/myclaw/comments/1u047p8/so_is_loop_engineering_the_next_ai_dev_buzzword/) ·
  [agent loop internals 분석](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) ·
  [Rails 8.1 release notes — `bin/ci` 원형](https://guides.rubyonrails.org/8_1_release_notes.html)
