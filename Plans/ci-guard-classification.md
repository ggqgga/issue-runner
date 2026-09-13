# `bin/ci` 블록 분류표 — ⓐ 행동 테스트 치환 · ⓑ SSOT 폐기 · ⓒ ci/guards 이동 · ⓓ 유지

플랜 `Plans/loop-restructure.md` 4단계 첫 leaf (이슈 #521 · `Epic #527`).
**`bin/ci` 는 이 leaf 에서 한 줄도 고치지 않는다** — 산출물은 이 표와 같은 이름의 `.html` 둘뿐이고,
행 처분(실제 삭제·이동)은 표 아래 leaf 초안이 발행될 뒤 leaf 가 한다.

## 블록 수와 재현 명령

블록 = `bin/ci` 에서 `echo "[…]"` 로 시작하는 단계 하나. 세는 명령과 행 범위를 뽑는 명령은 이렇다:

```sh
grep -c '^echo "\['  bin/ci                     # → 86
awk 'BEGIN{n=0} /^echo "\[/{if(n>0) print n"\t"s"-"NR-1; n++; s=NR} END{print n"\t"s"-"NR}' bin/ci
```

**세어 보니 86 이다** — 이슈 본문의 87 은 세션의 대략 셈이었다. 차이 나는 두 자리:

- **1–12행은 블록이 아니다** — 셔뱅 + `set -euo pipefail` + 「가드 은퇴 원칙」 머리 주석이다.
  이 주석이 곧 플랜 4단계의 「retire 정책 명문화」 자리이므로, 뒤 leaf 가 각 블록을 지울 때
  여기 적힌 기준(「이 가드가 없으면 어느 스크립트가 틀린 값을 읽는가」)을 인용한다.
- **989행은 새 블록이 아니다** — 블록 47 의 `echo` 를 이어붙인 둘째 줄(`echo "       + …"`)이라
  `^echo "\[` 에 안 걸린다.

행 범위 규약은 **`echo` 줄 → 다음 `echo` 줄 −1** 이다(위 awk 그대로). 이 규약의 약한 자리를
검증에 적었다: 블록 60·61·85 는 설명 주석이 `echo` **위**에 붙어 있어, 그 주석 줄이 앞 블록의
범위 끝에 들어간다(60 의 머리 주석 1026–1030 은 블록 59 범위 안, 61 의 1044–1048 은 60 범위 안,
85 의 1849 는 84 범위 안). 표는 규약을 그대로 따르고 이 사실만 밝힌다.

기준 커밋: `7943cc6` (`bin/ci` 1,939줄). #523(PR #530)이 `scripts/manual/` 을 만들며 bin/ci 의
glob 세 줄(15·29·38)을 바꿨지만 줄 수·블록 경계는 그대로다.

## 분류 기준

- **ⓐ 행동 테스트 치환** — 가드가 지키는 규칙이 **스크립트 동작**이라 픽스처로 옮길 수 있다.
  두 형태다: **⑴** 문구 단언을 새 픽스처로 치환 · **⑵** `bin/ci` 안의 인라인 스모크(gh 스텁·임시
  레포를 세워 SUT 를 실제로 돌리는 블록)를 기존 또는 신규 `scripts/tests/<sut>.test.sh` 로 이사.
  이 표의 ⓐ 는 전부 ⑵ 다 — 문구 단언 쪽은 ⓑ·ⓒ 로 갈렸다. ⓐ⑵ 행은 **대상 테스트 파일 이름**을
  대체물 칸에 적었고, 없으면 「신규」 라고 적었다.
- **ⓑ SSOT 폐기** — 1~3단계 SSOT(`references/state-machine.md` · `references/loop-conventions.md` ·
  `references/*-rationale.md` · `scripts/lib/loop.jq`·`constants.sh` · 스크립트 머리 주석)가 이미 그
  규칙을 한 자리에 두어 문구 단언이 무의미하다.
  **판정 규율: 대체물 칸에 절 번호나 표 이름을 못 적으면 ⓑ 가 아니다.** rationale 은 *왜* 를
  설명할 뿐 *SKILL 이 아직 그 말을 하는지* 를 강제하지 않는다 — SSOT 가 **그 문장을 인수**해
  SKILL 이 더는 규칙을 진술하지 않고 가리키기만 할 때에만 ⓑ 다. (예: `CODEX_REVIEW_LIMIT = 2` 는
  `verify-runner-rationale §2` 가 근거를 갖고 있어도 값 리터럴이 여전히 SKILL 본문에 살아 있으므로
  ⓓ. 반대로 블록 73 은 `loop-conventions §5` 가 `linked_issue` 를 통째로 인수했으므로 ⓑ.)
- **ⓒ ci/guards 이동** — SSOT 도 테스트도 못 대신하지만 남길 이유가 있다(한/영 헤더 동기 ·
  heredoc lint · 단일 정의 불변식 · 실행비트 · 문단 순서). → `ci/guards/<주제>.sh`, **만료 조건 필수**.
- **ⓓ 유지** — 기계 계약이라 문서에서 사라지면 루프가 깨진다. 두 갈래를 분류 칸에 적어 구분했다:
  **ⓓ 테스트 러너**(`bash scripts/tests/*.test.sh` 한 줄 — 자기 자신이 대체물) · **ⓓ 기계 계약**
  (코멘트 마커 · 라벨 이름 · 전이 동사 · `--post <루프>` · 런타임 치환 슬롯 같은 리터럴) ·
  **ⓓ 도구 단계**(bash -n · shellcheck). retire 조건은 「그 계약이 스크립트 인자로 옮겨질 때」.

판단이 갈린 자리는 보수적으로 **ⓓ** 로 두고 대체물·만료 칸에 「ⓑ 후보」 라고 적었다.

## 집계

| 분류 | 블록 수 | 차지하는 줄 수 | 비율(줄) |
|---|---|---|---|
| ⓐ 행동 테스트 치환 | 25 | 1136 | 59% |
| ⓑ SSOT 폐기 | 4 | 163 | 8% |
| ⓒ ci/guards 이동 | 13 | 332 | 17% |
| ⓓ 유지 | 44 | 296 | 15% |
| **합계** | **86** | **1927** | **100%** |

합계 1927 줄은 **블록이 덮는 줄**이다 — 파일 1,939줄에서 머리 주석 1–12행을 뺀 값이다.

`처분` 칸은 **비워 둔다** — 뒤 leaf 가 자기 PR 번호를 적는 자리다.

## 표

| # | 행 범위 | 대상 파일 | 무는 리터럴 | 원 이슈 | 분류 | 대체물 | 만료 조건 | 처분 |
|---|---|---|---|---|---|---|---|---|
| 1 | 13–22 | scripts/*.sh · scripts/manual/*.sh · scripts/lib/*.sh · hooks/*.sh · bin/ci | `bash -n "$f"` | — | ⓓ 도구 단계 | 자기 자신(문법 검사 — 대체물 없음) | 없음. 4단계 뒤 leaf 가 ci/steps/01-syntax.sh 로 옮기는 것뿐 |  |
| 2 | 23–33 | 같음 | `shellcheck -x -S warning …` | #427 | ⓓ 도구 단계 | 자기 자신 | 없음. ci/steps/02-shellcheck.sh |  |
| 3 | 34–40 | 같음 | `scripts/lint-heredoc.sh …` | #119 | ⓒ | ci/guards/heredoc-lint.sh | 인용 안 한 heredoc 이 0 이 되고 그 형태를 shellcheck 가 직접 물면 |  |
| 4 | 41–44 | scripts/repo-dir.sh | `ISSUE_RUNNER_PROJECTS_ROOT=/tmp … = "/tmp/some-repo"` | — | ⓐ⑵ | 신규 scripts/tests/repo-dir.test.sh (78 의 `-` 폴백과 한 벌) | 그 테스트 파일이 생기면 즉시 |  |
| 5 | 45–99 | SKILL.md↔SKILL.en.md · skills/loop-issues/* · skills/closeout/* · references/worker-template*.md | `grep -c '^## ' 개수 · ①②③ 순서 마커 · <WT_PATH> 외 placeholder 6종` | — | ⓒ (+ⓓ 86–96) | ci/guards/ko-en-sync.sh. placeholder 축(86–96)은 디스패처 런타임 치환 계약이라 대체물 없음 | 한/영 쌍이 없어지거나 번역 동기 검사기가 들어오면. placeholder 축은 워커 프롬프트 조립이 스크립트 인자로 옮겨질 때 |  |
| 6 | 100–120 | hooks/ci-gate-before-pr-merge.sh | `gh pr merge <번호\|URL\|브랜치> → exit 2` | — | ⓐ⑵ | 신규 scripts/tests/ci-gate.test.sh (33·34 와 한 벌) | 그 테스트 파일이 생기면 |  |
| 7 | 121–128 | scripts/setup-labels.sh | `gh label create $lbl  (harvesting·epic·verifying·flow:agent-ready·flow:claimed)` | #281 | ⓓ 기계 계약 | references/state-machine.md 「정상 사다리」·「정지와 반송」 표가 라벨의 뜻을 갖지만, 스크립트에 정의가 있는지는 아무도 안 본다 | 라벨 목록이 84⑵ 와 한 자리로 합쳐지고 setup-labels.test.sh 가 생기면 |  |
| 8 | 129–135 | scripts/closeout-ci-pass.sh | `gh 전부 실패 → exit 1` | — | ⓐ⑵ | scripts/tests/closeout-ci-pass.test.sh (#428, 블록 66) | 그 격자에 fail-closed 절이 있음을 확인하는 즉시 | L1 (이 PR) |
| 9 | 136–160 | scripts/pr-head-at.sh | `실행비트 + gh 실패·부분성공 → rc=1·무출력` | #171 | ⓐ⑵ (+ⓒ 141) | scripts/tests/pr-head-at.test.sh (#428, 블록 65). 실행비트는 ci/guards/exec-bit.sh | 스모크는 그 격자에 흡수되면. 실행비트는 소비자가 bash <스크립트> 로 부르게 바뀔 때 | L1 (이 PR — 9-b; 9-a 는 L5) |
| 10 | 161–167 | scripts/bounce-state.sh | `[ -x scripts/bounce-state.sh ]` | #196 | ⓒ | ci/guards/exec-bit.sh (실행비트 목록 한 자리) | 소비자가 직접 exec 를 그만두면 | L5 (이 PR) |
| 11 | 168–175 | scripts/*.sh | `grep -l 'BOUNCE_MARKERS' 이 bounce-state.sh 밖 0건` | #171 · #196 | ⓒ | ci/guards/single-definition.sh | 없음 — 이 가드가 곧 bounce-state.sh SSOT 의 강제자 |  |
| 12 | 176–189 | SKILL.md · SKILL.en.md · skills/verify-runner/SKILL.md · scripts/attempt-counter.sh | `attempt-counter.sh 배선 + gh pr (view\|edit) … --(json body\|body ) 금지` | #444 | ⓓ 기계 계약 (+ⓒ 181) | 없음 — 1~3단계 SSOT 어디에도 회차 카운터 규칙이 없다 (grep -rn attempt-counter references/ = 0건) | 회차 규칙이 loop-conventions 의 새 절로 옮겨지면 ⓑ 로 내려간다 |  |
| 13 | 190–209 | SKILL.md · SKILL.en.md · references/state-machine.md · scripts/pr-state.sh | `pr-state.sh·mismatch 배선 + 「머지 판정: ✅ … → flow:」 매핑 산문 금지` | #449 | ⓑ (202–205) · ⓓ (197–201) | references/state-machine.md 머리 6–8행 「이 표를 기계가 읽는 진입점은 scripts/pr-state.sh」 + 「정상 사다리」 표 | 매핑 산문 금지(202–205)는 지금 폐기 가능. 배선 축은 규칙0 이 스크립트 인자로 바뀔 때 | L3 (이 PR · 13-c) |
| 14 | 210–225 | scripts/*.sh · scripts/lib/loop.jq | `startswith("머지 판정\|Merge verdict\|검증자 리뷰\|…") · startswith("hold:") · == "needs-human" 인라인 0건` | #426 | ⓒ | ci/guards/single-definition.sh | 없음 — 블록 주석이 이미 「만료 조건: 없음」 이라 적었다 |  |
| 15 | 226–277 | scripts/bounce-comment.sh × scripts/bounce-state.sh | `생성 본문을 BOUNCE_COMMENTS_FILE 로 먹여 판정이 bounced` | #212 · #221 | ⓐ⑵ (+ⓒ 229) | scripts/tests/bounce-comment.test.sh (블록 50) + bounce-state.test.sh (블록 48) | 두 격자가 「헬퍼 출력 → 판정기」 교차 절을 가지면 | L1 (이 PR) |
| 16 | 278–322 | scripts/closeout-reconcile.sh · skills/closeout/SKILL{,.en}.md | `human_hold · needs-human, 런타임 4케이스(문자열 true·false·불리언 false·필드 부재)` | #271 ⑺ | ⓐ⑵ (+ⓓ 286–289) | scripts/tests/closeout-reconcile.test.sh (#428, 블록 67) | 그 격자에 human_hold 4케이스가 들어오면. SKILL 이벤트 행선지 축(286–289)은 기계 계약이라 남는다 | L1 (이 PR — ⓐ 런타임 4케이스만; SKILL 이벤트 행선지 축은 남았다) |
| 17 | 323–352 | references/worker-template{,.en}.md × scripts/bounce-state.sh | `템플릿에서 뽑아낸 접두를 먹여 판정이 ok` | #251 ② | ⓒ | ci/guards/worker-report-prefix.sh (문서에서 값을 뽑아 판정기에 먹이는 결합 검사) | 반송 판정이 접두가 아니라 구조 필드로 바뀌면 |  |
| 18 | 353–390 | scripts/closeout-ci-pass.sh | `로컬 캐시 부재·pass·fail → exit 2·0·1` | #70 | ⓐ⑵ | scripts/tests/closeout-ci-pass.test.sh 77·80·84행 — pass→0 · fail→1 · 「결과 캐시 부재 → 미실행(재검증 필요)」→2. 격자를 실제로 열어 같은 축임을 확인했다 | 즉시 — 대체 격자를 실측 확인했다(추가 작업 없이 삭제 가능) | L1 (이 PR) |
| 19 | 391–428 | scripts/closeout-ci-pass.sh | `rollup SUCCESS-only allowlist 6케이스` | #51 · #60 | ⓐ⑵ | 같은 파일 100–124행 「GitHub statusCheckRollup 폴백(SUCCESS-only allowlist)」 절 — 전부 SUCCESS→0 · FAILURE→1 · 미열거 종결값(CANCELLED)→1 · IN_PROGRESS→1 · 빈 rollup→1 · 조회 실패→1 · 레거시 state→0 | 같은 축을 덮되 대표값이 다르다(격자는 CANCELLED, 여기는 STARTUP_FAILURE·UNKNOWN_STATE) — 그 절에 두 케이스를 한 줄씩 더하면 즉시 | L1 (이 PR) |
| 20 | 429–439 | scripts/closeout-eligible.sh | `빈 스코프 → rc=0·무출력` | — | ⓐ⑵ | scripts/tests/closeout-eligible.test.sh (블록 43) | 그 격자에 빈-스코프 절이 있으면 | L1 (이 PR) |
| 21 | 440–492 | scripts/closeout-eligible.sh | `revalidate:true / 탈락 / revalidate:false 3분기` | #70 | ⓐ⑵ | 같은 격자 | 같음 | L1 (이 PR) |
| 22 | 493–557 | scripts/closeout-eligible.sh · scripts/lib/loop.jq | `센티널 위치 무관·레거시 접두 동결·영문 긍정 게이트 5케이스` | #72 | ⓐ⑵ | closeout-eligible.test.sh + loop-jq.test.sh 의 is_machine 절(블록 39) | 같음 | L1 (이 PR) |
| 23 | 558–604 | scripts/closeout-eligible.sh | `flow:verify 제외 · mergeable UNKNOWN skip` | #102 | ⓐ⑵ | closeout-eligible.test.sh + hold-gate.test.sh (#242, 블록 45) | 같음 | L1 (이 PR) |
| 24 | 605–612 | references/worker-template{,.en}.md · skills/closeout/SKILL{,.en}.md | `<!-- bodat:worker -->` | #72 | ⓓ 기계 계약 | references/loop-conventions.md §4 「머신 코멘트 센티널」 생산 축 표가 자리를 규정한다 — 그 자리에 실제로 있는지는 이 가드만 본다 | 센티널 주입이 프롬프트가 아니라 코멘트 게시 스크립트로 옮겨질 때 |  |
| 25 | 613–623 | scripts/closeout-reconcile.sh | `빈 결과 → rc=0·무출력` | — | ⓐ⑵ | scripts/tests/closeout-reconcile.test.sh (#428) | 그 격자에 빈-결과 절이 있으면 | L1 (이 PR) |
| 26 | 624–654 | skills/closeout/references/{verifier-prompt, verifier-prompt-fallback, deploy-check-issue, spinoff-issue}.md | `<PR> <REPO> <BASE> <ISSUE_BODY> <DIFF> <EPIC_LINE> 등 파일별 placeholder` | #54 · #207 · #261 | ⓓ 기계 계약 | 없음 — 런타임 치환 슬롯이라 사라지면 프롬프트가 빈 컨텍스트로 돈다 | 프롬프트 조립이 스크립트(인자)로 옮겨질 때 |  |
| 27 | 655–680 | scripts/spinoff-inherit.sh · scripts/loop-status.sh · skills/closeout/references/spinoff-issue.md | `<EPIC_LINE> 첫 줄 슬롯 앵커 + ^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+) 두 파일 축자 동일` | #261 · #260 | ⓒ (+ⓓ 661–668 · 러너 680) | ci/guards/single-definition.sh (정규식 축) · scripts/tests/spinoff-inherit.test.sh (행동 축, 이미 680 에서 호출) | Epic 전용 줄 정규식이 scripts/lib/loop.jq 한 자리로 가면 ⓑ |  |
| 28 | 681–683 | scripts/tests/spinoff-issue.test.sh | `bash scripts/tests/spinoff-issue.test.sh` | #447 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 29 | 684–701 | skills/closeout/SKILL{,.en}.md · verifier-prompt{,-fallback}.md | `verifier-prompt-fallback.md 이름 지목 · <DIFF> 는 폴백 전용 · 「이 워크트리는」 금지` | #207 attempt8 | ⓓ 기계 계약 | references/closeout-rationale.md §10 「③ 1단계 — 계획 부합 검증」 은 근거만 — 슬롯 배타성은 이 가드만 본다 | 두 프롬프트가 한 템플릿 + 인자로 합쳐질 때 |  |
| 30 | 702–727 | scripts/codex-review-gate.sh · skills/closeout/SKILL{,.en}.md · verifier-prompt{,-fallback}.md | `STATUS_KEY·STATUS_NO_BASIS 정의 1곳 · STATUS_REVIEWED 부활 금지 · 문서에 키 하드코딩 0` | #207 · #375 | ⓒ | ci/guards/single-definition.sh | 신호 키가 scripts/lib/constants.sh 로 가고 문서가 이름만 부르면 ⓑ |  |
| 31 | 728–736 | skills/closeout/SKILL{,.en}.md · skills/verify-runner/SKILL.md | `CODEX_REVIEW_LIMIT = 2 · closeout SKILL 에 codex-review-gate.sh -- 호출 금지` | #375 | ⓓ 기계 계약 | references/verify-runner-rationale.md §2 는 근거만 — 값 리터럴은 여전히 SKILL 본문에 산다 | CODEX_REVIEW_LIMIT 값이 scripts/lib/constants.sh 로 이사하면 ⓑ |  |
| 32 | 737–749 | skills/closeout/references/smoke-prompt{,.en}.md | `<VERIFY_URL> · <LIVE_CHECKS>` | #69 | ⓓ 기계 계약 | 없음(26 과 같은 성격 — 런타임 치환 슬롯) | 26 과 같음 |  |
| 33 | 750–782 | hooks/ci-gate-before-pr-merge.sh | `--repo o/r 캐시 pass → 0 · 캐시 부재 → 2` | #47 | ⓐ⑵ | 신규 scripts/tests/ci-gate.test.sh | 그 테스트 파일이 생기면 |  |
| 34 | 783–823 | hooks/ci-gate-before-pr-merge.sh | `rollup allowlist 6케이스 → exit 0/2` | #60 | ⓐ⑵ | 같음 | 같음 |  |
| 35 | 824–867 | scripts/cleanup-worktree.sh | `실제 git worktree 로 clean+--merged·dirty·미push·멱등 4케이스` | #62 | ⓐ⑵ | 신규 scripts/tests/cleanup-worktree.test.sh | 그 테스트 파일이 생기면 |  |
| 36 | 868–899 | scripts/reconcile.sh | `MERGED + dirty worktree → warn 1건·merged 0건` | #62 | ⓐ⑵ | scripts/tests/reconcile.test.sh (#131, 블록 55) | 그 격자에 dirty 절이 들어오면 | L1 (이 PR) |
| 37 | 900–948 | scripts/closeout-reconcile.sh | `cleanup-worktree.sh <repo> <n> --merged 인자 캡처 · 비매칭 브랜치 무호출` | #62 | ⓐ⑵ | scripts/tests/closeout-reconcile.test.sh (#428) | 같음 | L1 (이 PR) |
| 38 | 949–961 | verifier-prompt{,-fallback}.md · skills/closeout/SKILL{,.en}.md | `<LESSONS_OR_ ← lessons-verifier.md` | #80 | ⓓ 기계 계약 | references/issue-runner-rationale.md §5 「lessons 기록」 은 근거만 — 슬롯 존재는 이 가드만 본다 | 26 과 같음 |  |
| 39 | 962–966 | scripts/tests/loop-jq.test.sh | `bash scripts/tests/loop-jq.test.sh` | #426 | ⓓ 테스트 러너 | 자기 자신 | 없음(블록 주석이 이미 「만료 조건: 없음」) |  |
| 40 | 967–969 | scripts/tests/attempt-counter.test.sh | `bash …` | #444 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 41 | 970–972 | scripts/tests/pr-state.test.sh | `bash …` | #449 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 42 | 973–975 | scripts/tests/finish-classify.test.sh | `bash …` | #88 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 43 | 976–978 | scripts/tests/closeout-eligible.test.sh | `bash …` | #171 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 44 | 979–981 | scripts/tests/verify-eligible.test.sh | `bash …` | #275 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 45 | 982–984 | scripts/tests/hold-gate.test.sh | `bash …` | #242 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 46 | 985–987 | scripts/tests/lane-gate.test.sh | `bash …` | #246 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 47 | 988–991 | scripts/tests/eligible-issues.test.sh | `bash … (989 는 이어붙인 설명 echo — 새 블록 아님)` | #247 · #401 · #257 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 48 | 992–994 | scripts/tests/bounce-state.test.sh | `bash …` | #196 · #218 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 49 | 995–997 | scripts/tests/closeout-step1-marker.test.sh | `bash …` | #271 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 50 | 998–1000 | scripts/tests/bounce-comment.test.sh | `bash …` | #212 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 51 | 1001–1003 | scripts/tests/closeout-sweep-gate.test.sh | `bash …` | #218 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 52 | 1004–1006 | scripts/tests/release-labels.test.sh | `bash …` | #117 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 53 | 1007–1009 | scripts/tests/ci-queue.test.sh | `bash …` | #127 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 54 | 1010–1012 | scripts/tests/codex-review-gate.test.sh | `bash …` | #134 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 55 | 1013–1015 | scripts/tests/reconcile.test.sh | `bash …` | #131 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 56 | 1016–1018 | scripts/tests/transition.test.sh | `bash …` | #144 · #147 · #281 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 57 | 1019–1021 | scripts/tests/claim-issue.test.sh | `bash …` | #281 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 58 | 1022–1024 | scripts/tests/resume-sweep.test.sh | `bash …` | #147 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 59 | 1025–1030 | scripts/tests/loop-status.test.sh | `bash … (1026–1030 은 다음 블록의 머리 주석)` | #144 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 60 | 1031–1048 | scripts · README.ko.md · README.md · skills · scripts/loop-status.sh | `구현중\|마감중\|사람대기 잔존 0건 + RENDER_JQ padded 9칸 리터럴` | #276 | ⓑ (1031–1038) · ⓐ⑵ (1039–1045) | scripts/loop-status.sh 머리 주석 17–37행 「★버킷 정의 — 이 주석이 SSOT★」 + references/state-machine.md 「정상 사다리」. padded 축은 scripts/tests/loop-status.test.sh | 옛 문구 sweep 은 지금 폐기 가능(#398 이 같은 계열을 이미 걷었다). padded 축은 그 스위트가 렌더 9줄을 단언하면 |  |
| 61 | 1049–1058 | scripts/lib/loop.jq · scripts/resume-sweep.sh | `def unquoted: … ; 두 파일 축자 동일` | #346 | ⓒ | ci/guards/single-definition.sh | resume-sweep.sh 가 jq -L lib 로 loop.jq 를 include 하면 즉시 |  |
| 62 | 1059–1064 | scripts/epic-sweep.sh · scripts/tests/epic-sweep.test.sh | `실행비트 + bash scripts/tests/epic-sweep.test.sh` | #258 | ⓓ 테스트 러너 (+ⓒ 1061) | 자기 자신. 실행비트는 ci/guards/exec-bit.sh | 없음. 실행비트는 10 과 같음 |  |
| 63 | 1065–1067 | scripts/tests/progress-evidence.test.sh | `bash …` | #428 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 64 | 1068–1070 | scripts/tests/claim-at.test.sh | `bash …` | #428 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 65 | 1071–1073 | scripts/tests/pr-head-at.test.sh | `bash …` | #428 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 66 | 1074–1076 | scripts/tests/closeout-ci-pass.test.sh | `bash …` | #428 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 67 | 1077–1079 | scripts/tests/closeout-reconcile.test.sh | `bash …` | #428 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 68 | 1080–1082 | scripts/tests/smoke-tally.test.sh | `bash …` | #448 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 69 | 1083–1085 | scripts/tests/deploy-wait-issue.test.sh | `bash …` | #446 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 70 | 1086–1088 | scripts/tests/make-worktree.test.sh | `bash …` | #445 | ⓓ 테스트 러너 | 자기 자신 | 없음 |  |
| 71 | 1089–1130 | scripts/*.sh · scripts/lib/*.sh · scripts/progress-evidence.sh · timebox-check.sh · finish-classify.sh | `^STALL_MIN=\|^: "${STALL_MIN:=\|^queue_alive() 가 두 파일 밖 0건 + 3값 어휘 fail-closed 스모크 3건` | #200 → #206 · #427 | ⓐ⑵ (1107–1130) · ⓒ (1096–1099) · ⓓ (1103–1106) | scripts/tests/progress-evidence.test.sh (#428, 블록 63). 정의 축은 ci/guards/single-definition.sh | 스모크는 그 격자에 흡수되면. 정의 축은 없음(이 가드가 SSOT 강제자) |  |
| 72 | 1131–1192 | scripts/claim-at.sh · finish-classify.sh · progress-evidence.sh · timebox-check.sh · scripts/lib/constants.sh | `claim-at.sh·claimed_arg·--claimed-at 배선 · ISSUE_TIMEBOX_HOURS:[-=][0-9]* 가 1벌 · head_lookup=unknown` | #206 · #427 | ⓐ⑵ (1162–1186) · ⓑ (1148–1161) · ⓒ (1187–1192) · ⓓ (1135–1147) | scripts/lib/constants.sh 머리 주석(값 한 자리 — 「ISSUE_TIMEBOX_HOURS 는 실제로 4벌이었다」) + : "${ISSUE_TIMEBOX_HOURS:=1}". 스모크는 progress-evidence.test.sh | 기본값 1벌 축(1148–1161)은 지금 폐기 가능. tripwire 는 finish-classify.test.sh 가 종료코드 보존을 뮤테이션으로 물면 |  |
| 73 | 1193–1219 | scripts/finish-classify.sh · skills/closeout/SKILL{,.en}.md | `headRefName · agent/issue- · 「1순위」/first · 옛 계약 문장 2종 금지` | #206 | ⓑ | references/loop-conventions.md §5 「Closes #N 전용 줄」 소비 축 — 네 소비자가 scripts/lib/loop.jq 의 linked_issue(head; refs) 한 자리를 부른다(#495) + scripts/tests/finish-classify.test.sh 격자 | 지금 폐기 가능 — 코드 축 grep 은 이미 주석 줄에만 걸린다(finish-classify.sh:119–121 · 398–404, 실호출은 421 의 linked_issue) | L3 (이 PR · 블록 통째) |
| 74 | 1220–1233 | scripts/finish-classify.sh · progress-evidence.sh · timebox-check.sh | `[0-9][0-9][0-9][0-9]-[0-9][0-9]-…Z) ;; 형식 패턴이 1가지` | #206 | ⓒ | ci/guards/single-definition.sh | iso_to_epoch 이 scripts/lib/ 한 자리로 합쳐지면 즉시(현재 사본 3개) |  |
| 75 | 1234–1239 | scripts/timebox-check.sh · scripts/tests/timebox-check.test.sh | `실행비트 + bash …` | #200 | ⓓ 테스트 러너 (+ⓒ 1237) | 자기 자신. 실행비트는 ci/guards/exec-bit.sh | 없음. 실행비트는 10 과 같음 | L5 (이 PR) |
| 76 | 1240–1246 | scripts/lessons-trim.sh · scripts/tests/lessons-trim.test.sh | `실행비트 + bash …` | #208 | ⓓ 테스트 러너 (+ⓒ 1245) | 같음 | 같음 | L5 (이 PR) |
| 77 | 1247–1277 | SKILL.md · SKILL.en.md · scripts/lib/constants.sh | `STALL_MIN·MAX_TIMEBOX_GRACE·timebox-check.sh 배선 + SKILL 에 '이름 = 숫자' 부활 금지` | #200 · #427 | ⓒ (1258–1277) · ⓓ (1251–1257) | scripts/lib/constants.sh 머리 주석 「세 SKILL 의 ## 상수 절은 이제 값을 다시 적지 않고 이 파일을 가리킨다」 — 형태의 강제자는 이 가드뿐 | 블록 주석이 이미 적었다: 「## 상수 절이 값을 적지 않는 형태를 유지하는 한 이 검사가 그 형태의 강제자다」 |  |
| 78 | 1278–1303 | scripts/repo-flag.sh · scripts/repo-dir.sh | `repos.conf 3필드 이후 플래그 · 주석 줄 무시 · conf 부재 off · '-' 경로 폴백` | #109 | ⓐ⑵ | 신규 scripts/tests/repo-flag.test.sh (블록 4 와 한 벌) | 그 테스트 파일이 생기면 |  |
| 79 | 1304–1356 | scripts/make-worktree.sh | `link-secrets off/on/회수/실파일 보호/남의 심링크 보호/깨진 심링크 7케이스` | #109 | ⓐ⑵ | scripts/tests/make-worktree.test.sh (#445, 블록 70) | 그 격자에 시크릿 심링크 절이 들어오면 |  |
| 80 | 1357–1611 | scripts/claim-issue.sh | `create-only ref 잠금 · takeover D/F 충돌 · 스테일 동시 2회 · live-holder 지연 8케이스 (255줄)` | #108 | ⓐ⑵ | scripts/tests/claim-issue.test.sh (#281, 블록 57) | 그 격자로 이사하면 — bin/ci 단일 최대 이사 대상 |  |
| 81 | 1612–1709 | SKILL{,.en}.md · skills/{verify-runner,closeout}/SKILL*.md · references/worker-template*.md · scripts/transition.sh | `사다리 참조 · --reason/--note 필수 · --add-label needs-human 금지 · policy-kept 순서 · hold:/verifying 대상 필터 · loop-status.sh --post <루프>` | #147 · #151 · #155 · #163 · #244 · #275 · #344 · #375 | ⓑ 4 · ⓓ 4 · ⓒ 1 (아래 분해 표) | loop-conventions §9 · closeout-rationale §5 · issue-runner-rationale §11·§13 · state-machine.md 「정지와 반송」 | 부행마다 다르다 — 분해 표 참조 | L3 (이 PR · 81-a·81-f·81-g·81-h) |
| 82 | 1710–1755 | SKILL{,.en}.md · skills/verify-runner/SKILL.md · skills/closeout/SKILL{,.en}.md · references/worker-template{,.en}.md | `transition.sh verify-pass\|closeout-pick\|handoff-verify · loop-status.sh · BLOCKED: 전이 실패 · --add-label flow:* 금지` | #144 | ⓓ 기계 계약 (+ⓑ 후보 1735–1744) | references/state-machine.md 「전이 실패의 공통 규칙 (세 SKILL 이 각자 14회 재진술하던 것)」 | BLOCKED 문구 축(1735–1744)은 지금 폐기 가능. 전이 호출 배선은 그 계약이 스크립트 인자로 옮겨질 때 | L3 (이 PR · 82-b 세 루프 SKILL 축만) |
| 83 | 1756–1809 | scripts/loop-status.sh | `--state closed --search '"Epic #" in:body' · is:closed 금지 · --limit "$EPIC_CLOSED_LIMIT" · epic_of 1벌 · what: "닫힌 이슈" 금지` | #292 · #236 · #190 · #191 | ⓒ (+ⓐ 후보 1771–1781) | ci/guards/single-definition.sh (epic_of 축) · scripts/tests/loop-status.test.sh (쿼리 형태 축 — gh 인자 캡처) | 쿼리 형태 축은 그 스위트가 gh 인자를 캡처하면. epic_of 축은 정규식이 lib/loop.jq 로 가면 |  |
| 84 | 1810–1849 | scripts/setup-labels.sh · scripts/lib/constants.sh | `gh label create "full-cycle" · 기존 18개 라벨 정의 생존 · RESUME_AFTER_MIN 정의 · --description 100자 이하` | #245 · #364 · #346 · #401 | ⓐ⑵ (1834–1849) · ⓓ (1815–1828) · ⓒ (1829–1833) | 신규 scripts/tests/setup-labels.test.sh (100자 상한·정의 존재를 행동으로) | 그 테스트 파일이 생기면. 라벨 이름 목록은 블록 7 과 한 자리로 합친다 |  |
| 85 | 1850–1891 | scripts/finish-classify.sh · scripts/bounce-state.sh · skills/closeout/SKILL{,.en}.md | `bounce-state.sh 되묻기 배선 + 반송 마커 5분/35분 → active/stale_reverify + #308 문단 · 라벨 공백 창/label gap` | #308 | ⓐ⑵ (1862–1879) · ⓑ (1880–1891) · ⓓ (1853–1855) | scripts/tests/finish-classify.test.sh 1140–1200행 — #308 반송 마커 픽스처 11:25·11:30·11:29:59(경계) + 마커 부재(1173행)·시각 미상(1182행) 두 반례. bin/ci 주석의 「J절」 은 옛 이름이고 실제 자리는 여기다 · references/closeout-rationale.md §7 「라벨 공백 창 (#308)」(:357-366 — L3 실측 정정) | 산문 축(1880–1891)은 지금 폐기 가능. 스모크도 즉시 — 그 격자를 실측 확인했다 | L3 (이 PR · 85-d) |
| 86 | 1892–1939 | SKILL*.md · skills/*/SKILL*.md · references/worker-template*.md · references/{loop-conventions,*-rationale}.md | `(loop-conventions\|…rationale)(\.md)?'? §[0-9]+ 인용 ⊆ ^## §N 헤더 집합` | #507 · #451 · #453 | ⓒ | ci/guards/section-pointers.sh | 블록 주석이 이미 적었다: 「포인터를 앵커 링크로 바꾸고 링크 검사기가 들어오면 지운다」 |  |

## 이질 블록 분해 — 하위 가드 (부행)

한 `echo` 블록 안에 성격이 다른 가드가 섞인 자리다. 위 표는 블록 하나에 한 행이라
**대표 분류**만 적었고(그래야 행 수 = 블록 수 86 이 재현된다), 뒤 leaf 가 행 단위로 돌 때
실제로 집는 단위는 아래 부행이다. 부행 59개.

| 부행 | 행 범위 | 무는 것 | 분류 | 대체물 · 근거 |
|---|---|---|---|---|
| 5-a | 46–77 | 한/영 ## 헤더 개수·①②③ 순서 마커 일치 | ⓒ | ci/guards/ko-en-sync.sh |
| 5-b | 78–85 | worker-template 절차 번호 줄(^N.) 개수 일치 | ⓒ | 같음 |
| 5-c | 86–96 | 워커 템플릿 필수 placeholder 6종 존재 | ⓓ | 런타임 치환 계약 — 대체물 없음 |
| 9-a | 141 | pr-head-at.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 9-b | 142–159 | gh 실패·부분 성공 → rc=1·무출력 | ⓐ⑵ | scripts/tests/pr-head-at.test.sh |
| 12-a | 181 | attempt-counter.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 12-b | 182–184 | 세 SKILL 의 attempt-counter.sh 배선 | ⓓ | SSOT 없음(references/ 에 언급 0건) |
| 12-c | 185–188 | 회차를 산문으로 읽고 쓰는 형태 금지 | ⓒ | ci/guards/prose-regression.sh |
| 13-a | 196 | pr-state.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 13-b | 197–201 | 규칙0 의 pr-state.sh·mismatch 배선 | ⓓ | 기계 계약 |
| 13-c | 202–205 | 판정 기호 → flow:<칸> 매핑 산문 금지 | ⓑ | state-machine.md 「정상 사다리」 표 + pr-state.sh 진입점 선언(머리 6–8행) |
| 13-d | 206–208 | state-machine.md 가 pr-state.sh 를 가리키는가 | ⓒ | ci/guards/section-pointers.sh 와 한 몸 |
| 15-a | 229 | bounce-comment.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 15-b | 230–277 | 헬퍼 출력 → bounce-state.sh 가 bounced 로 읽는가 | ⓐ⑵ | bounce-comment.test.sh × bounce-state.test.sh |
| 16-a | 282–285 | closeout-reconcile.sh 의 needs-human·human_hold 존재 | ⓐ⑵ | closeout-reconcile.test.sh |
| 16-b | 286–289 | closeout SKILL 한/영의 human_hold 행선지 | ⓓ | 기계 계약(이벤트에 목적지가 없으면 봇이 무시) |
| 16-c | 290–322 | 런타임 4케이스(true·false·불리언·필드 부재) | ⓐ⑵ | closeout-reconcile.test.sh |
| 27-a | 660 | spinoff-inherit.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 27-b | 661–668 | spinoff-issue.md 머리 주석 뒤 첫 줄이 <EPIC_LINE> | ⓓ | 런타임 치환 슬롯 앵커 |
| 27-c | 669–679 | Epic 전용 줄 정규식이 두 파일에서 축자 동일 | ⓒ | ci/guards/single-definition.sh |
| 27-d | 680 | spinoff-inherit.test.sh 호출 | ⓓ | 테스트 러너 |
| 60-a | 1031–1038 | 옛 버킷 문구(구현중·마감중·사람대기) 잔존 0건 | ⓑ | loop-status.sh 머리 주석 「★버킷 정의 — 이 주석이 SSOT★」(17–37행) |
| 60-b | 1039–1045 | RENDER_JQ padded 9칸 리터럴 존재·폭 15칸 | ⓐ⑵ | loop-status.test.sh 가 렌더 9줄을 단언 |
| 62-a | 1061 | epic-sweep.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 62-b | 1064 | epic-sweep.test.sh 호출 | ⓓ | 테스트 러너 |
| 71-a | 1096–1099 | STALL_MIN·queue_alive 정의가 두 파일 밖 0건 | ⓒ | ci/guards/single-definition.sh |
| 71-b | 1100–1102 | progress-evidence.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 71-c | 1103–1106 | timebox-check·finish-classify 의 배선 | ⓓ | 기계 계약 |
| 71-d | 1107–1130 | 3값 어휘 fail-closed 스모크 3건 | ⓐ⑵ | progress-evidence.test.sh |
| 72-a | 1135 | claim-at.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 72-b | 1136–1147 | finish-classify 의 claim-at.sh·claimed_arg·--claimed-at 배선 | ⓓ | 기계 계약 |
| 72-c | 1148–1161 | ISSUE_TIMEBOX_HOURS 기본값이 1벌 · 두 리더가 읽는가 | ⓑ | scripts/lib/constants.sh (값 한 자리, #427) |
| 72-d | 1162–1186 | 입력 어휘 3값 스모크 4건 | ⓐ⑵ | progress-evidence.test.sh |
| 72-e | 1187–1192 | 호출부 tripwire(head_rc 보존·head_lookup=unknown) | ⓒ | ci/guards/prose-regression.sh 또는 finish-classify 뮤테이션 |
| 77-a | 1251–1257 | SKILL 한/영의 STALL_MIN·MAX_TIMEBOX_GRACE·timebox-check.sh 배선 | ⓓ | 기계 계약 |
| 77-b | 1258–1277 | 상수 값이 SKILL 로 되살아나지 않았는가 + constants.sh 를 가리키는가 | ⓒ | scripts/lib/constants.sh 머리 주석의 형태 강제자 |
| 81-a | 1612–1618 | 네 문서가 live-verification-ladder.md 를 가리킨다 | ⓑ | loop-conventions §9 「검증 사다리 칸 규율」(칸 정의 SSOT 를 명시) |
| 81-b | 1619–1633 | --reason 필수 · policy\|conflict 는 --note 필수 · 산문 --add-label needs-human 금지 | ⓓ | state-machine.md 「정지와 반송」(ⓑ 후보 — 리터럴 인자 형태라 보수적으로 ⓓ) |
| 81-c | 1634 | SKILL 한/영의 resume-sweep.sh 배선 | ⓓ | 기계 계약 |
| 81-d | 1635–1643 | policy-kept 배선 + transition.sh 에 그 전이 존재 | ⓓ | 기계 계약(전이 동사 리터럴) |
| 81-e | 1644–1663 | policy_review_due 불릿의 전이-먼저·마커-나중 순서 | ⓒ | issue-runner-rationale §11 은 근거만 — 문단 순서 검사는 대체물 없음 |
| 81-f | 1664–1676 | ①-b 대상 문단의 hold: 접두 미부착 필터 | ⓑ | closeout-rationale §5 「①-b 대상 필터」 |
| 81-g | 1677–1687 | 같은 문단의 verifying 미부착 필터 | ⓑ | closeout-rationale §5 + state-machine.md 「게이트 세 개가 공유하는 제외 집합」 |
| 81-h | 1688–1693 | 규칙0 문단이 verifying PR 을 건너뛴다 · needs-human+hold:* 쌍 서술 금지 | ⓑ | issue-runner-rationale §13 「② Maintain — 규칙0 위임」 + state-machine.md 「정지와 반송」 |
| 81-i | 1694–1705 | verify-runner ④ held 절차문(needs-human 승격 금지 · verify-held --reason 서술) | ⓓ | verify-runner-rationale §2 는 근거만 — 리터럴 인자 형태(ⓑ 후보) |
| 81-j | 1706–1709 | 다섯 문서의 loop-status.sh --post <루프> 배선 | ⓓ | loop-conventions §7 이 규약을 갖지만 --post 리터럴은 기계 계약 |
| 82-a | 1710–1734 | transition.sh 전이 동사 · loop-status.sh · --label spinoff\|deploy-wait 배선 | ⓓ | 기계 계약 |
| 82-b | 1735–1744 | BLOCKED: 전이 실패 / transition failed 보고 규약 문구 | ⓑ 후보 | state-machine.md 「전이 실패의 공통 규칙」(문구까지 그대로 SSOT 에 있다). **L3 실측**: 세 루프 SKILL 축은 인수됨(폐기) · 워커 템플릿 축(`전이 실패: handoff-verify`)은 그 절이 ④ Report 로 범위를 한정해 **미인수**(유지) |
| 82-c | 1745–1755 | 산문 --add-label flow:ready\|flow:verify\|harvesting 금지 | ⓓ | 기계 계약(라벨 이동은 transition.sh 독점) |
| 83-a | 1757–1781 | --state closed 플래그 형태 · is:closed 금지 · --limit "$EPIC_CLOSED_LIMIT" | ⓐ 후보 | loop-status.test.sh 가 gh 인자를 캡처하면 |
| 83-b | 1782–1791 | epic_of 정규식이 이 파일에 1벌 | ⓒ | ci/guards/single-definition.sh |
| 83-c | 1792–1809 | 헤더 주석 계약 3토큰 · 닫힌 이슈 절단 warn 부활 금지 | ⓒ | ci/guards/prose-regression.sh |
| 84-a | 1815–1828 | full-cycle 정의 + 기존 18개 라벨 정의 생존 | ⓓ | 기계 계약(라벨 이름). 블록 7 과 목록 중복 |
| 84-b | 1829–1833 | RESUME_AFTER_MIN 정의가 constants.sh 에 있다 | ⓒ | ci/guards/single-definition.sh |
| 84-c | 1834–1849 | --description 100자 이하 · 한 줄 정의가 20건 이상 | ⓐ⑵ | 신규 setup-labels.test.sh |
| 85-a | 1853–1855 | finish-classify 의 bounce-state.sh 되묻기 배선 | ⓓ | 기계 계약 |
| 85-b | 1856–1861 | bounce-state.sh 실행비트 | ⓒ | ci/guards/exec-bit.sh |
| 85-c | 1862–1879 | 반송 마커 5분/35분 → active/stale_reverify 행동 스모크 | ⓐ⑵ | finish-classify.test.sh 1140–1200행(#308 픽스처 + 경계 + 반례 2건) — 실측 확인 |
| 85-d | 1880–1891 | 한/영 #308 문단 · 라벨 공백 창 / label gap | ⓑ | closeout-rationale **§7** 「라벨 공백 창 (#308)」(:357-366 — L3 실측 정정: §6 「①-b 반송 게이트」 에는 #308 이 없다) |

## 행 처분 leaf 초안

발행은 세션이 한다. ⓓ 는 묶지 않는다 — 유지가 결론이라 처분할 행이 없다.
싼 것부터 도는 순서를 권한다: **L5 → L1 → L3 → L4 → L6 → L2**.
L5 가 열두 자리의 실행비트를 먼저 걷어내면 나머지 leaf 의 diff 가 작아지고, L1 의 첫 커밋
(블록 18 삭제)은 대체 격자를 실측 확인했으므로 **검증 비용이 0** 이다.

### L1 · 인라인 스모크를 기존 격자로 이사 — closeout·반송 축 (ⓐ)

- **대상 행** — 8 · 15 · 16 · 18 · 19 · 20 · 21 · 22 · 23 · 25 · 36 · 37 · 71-d · 72-d · 85-c (그리고 9-b)
- **예상 규모** — bin/ci −약 430줄. 손대는 테스트 파일 7개(closeout-ci-pass · closeout-eligible · closeout-reconcile · reconcile · bounce-comment · progress-evidence · finish-classify). 18 은 대체 격자를 실측 확인했으므로 삭제만 하면 되고(이 leaf 의 첫 커밋), 19 는 그 절에 STARTUP_FAILURE·UNKNOWN_STATE 두 케이스를 한 줄씩 더한 뒤 삭제한다. 85-c 도 실측 확인 완료.

### L2 · 격자가 없는 SUT 에 테스트 신설 + 최대 스모크 이사 (ⓐ)

- **대상 행** — 4 · 6 · 33 · 34 · 35 · 78 · 79 · 80 · 84-c
- **예상 규모** — 신규 scripts/tests/ 4파일(ci-gate · cleanup-worktree · repo-flag · setup-labels) + make-worktree·claim-issue 격자 증설. bin/ci −약 620줄(80 만 255줄). 가장 큰 leaf 라 80 은 따로 떼어도 된다.

### L3 · SSOT 가 인수한 산문 단언 폐기 (ⓑ)

- **대상 행** — 13-c · 60-a · 72-c · 73 · 81-a · 81-f · 81-g · 81-h · 82-b · 85-d
- **예상 규모** — bin/ci −약 95줄. 커밋 메시지마다 인수한 SSOT 절 번호를 적는다(loop-conventions §5·§9 · closeout-rationale §5·§6 · issue-runner-rationale §13 · state-machine.md 「정상 사다리」·「정지와 반송」·「전이 실패의 공통 규칙」 · constants.sh 머리 주석).

### L4 · 단일 정의 불변식을 ci/guards/single-definition.sh 한 파일로 (ⓒ)

- **대상 행** — 11 · 14 · 27-c · 30 · 61 · 71-a · 74 · 83-b · 84-b
- **예상 규모** — 신규 파일 1개(약 90줄) + bin/ci −약 80줄. 항목마다 만료 조건 한 줄 필수. 61·74 는 만료 조건이 이미 구체적이다(include 전환 · lib 통합).

### L5 · 실행비트 검사를 ci/guards/exec-bit.sh 목록 하나로 (ⓒ)

- **대상 행** — 9-a · 10 · 12-a · 13-a · 15-a · 27-a · 62-a · 71-b · 72-a · 75(1237) · 76(1245) · 85-b
- **예상 규모** — 12자리 → 목록 1개(약 20줄). bin/ci −약 14줄. 가장 싼 leaf — 먼저 돌려 나머지 leaf 의 diff 를 줄인다.

### L6 · 문서 형태 가드를 ci/guards/ 로 (ⓒ)

- **대상 행** — 3 · 5-a · 5-b · 17 · 77-b · 86 · 12-c · 72-e · 83-c
- **예상 규모** — 신규 파일 5개(heredoc-lint · ko-en-sync · worker-report-prefix · prose-regression · section-pointers). bin/ci −약 170줄. 만료 조건 주석이 이미 있는 것(86)과 없는 것(17·77-b)을 가른다.

## 검증

- 표 행 수 = 블록 수 = `grep -c '^echo "\['  bin/ci` = **86**. 위 재현 명령 두 줄로 다시 뽑을 수 있다.
- 무작위 대조 10행은 이 leaf 의 구현 보고에 `sed -n` 출력과 함께 적었다 — 규약이 가장 약한
  자리(블록 60·61·85, 설명 주석이 `echo` 위에 붙은 세 곳)를 일부러 포함했다.
- `bash bin/ci` 는 돌리지 않았다(푸시 훅 큐 · 이 leaf 는 `bin/ci` 무변경).
