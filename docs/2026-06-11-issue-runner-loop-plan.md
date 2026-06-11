# Issue-Runner Loop (루프 엔지니어링 디스패처) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub 계정(`ggqgga`) 전체에서 `agent-ready` 라벨이 붙은 이슈를 자동으로 집어, worktree 격리 환경에서 구현하고 PR을 여는 자율 루프 시스템을 만든다. 머지는 항상 사람이 한다.

**Architecture:** 단일 디스패처(`/issue-runner` 스킬)가 `/loop`로 주기 실행되며 매 틱 ①Reconcile(머지/거부된 PR 발견→worktree 정리·claim 해제·lessons 기록) → ②Maintain(열린 PR의 CI 실패·리뷰 코멘트·conflict 수리) → ③Dispatch(자격 필터 통과 이슈를 claim→worktree→백그라운드 워커 투입) → ④Report 순서로 동작한다. 상태의 단일 진실 원천은 GitHub(라벨·assignee·PR 상태)이고, 루프는 매 틱 현실과 대조(reconcile)한다. 결정론적 판단(자격·claim·정리)은 bash 스크립트가, 재량 판단(겹침 회피·수리 방법)은 LLM이 맡는다. 검증자는 codex(기존 `test-plan-on-pr-create.sh` hook이 PR 생성 시 자동 스폰)이며 BLOCKER는 게이트로 승격한다.

**Tech Stack:** bash + `gh` CLI + `jq`, Claude Code 스킬(SKILL.md), 기존 글로벌 hooks(`quality-gate.sh`, `ci-gate-before-pr-merge.sh`, `require-issue-in-pr.sh`, `test-plan-on-pr-create.sh`), codex:codex-rescue 서브에이전트.

---

## 확정된 설계 결정 (리서치 근거 포함)

| 결정 | 근거 |
|---|---|
| claim = `agent:claimed` 라벨 + assignee, 디스패처 **1개만** 운영 | 단일 writer면 race 자체가 없음. 어떤 제품도 원자적 락 미제공(Kiro 문서 확인) |
| 의존성 = 이슈 본문 전용 라인 `Blocked by #N`, 블로커 전부 CLOSED여야 자격 | DAG 위상정렬. 의존 체인 속도가 사람 리뷰 속도에 자동 동기화 |
| 워커는 자주 커밋 + **매 커밋 push** → worktree는 항상 버려도 되는 상태 | worktree 무경고 삭제 사고(claude-code#46444) 방어 |
| worktree 제거 전 dirty/unpushed 검사, 걸리면 보류+경고 | 동일 |
| lessons = 객관적 실패 사실만, codex가 작성, 20줄 캡, CLAUDE.md 자동 승격 금지 | 내재적 자기교정은 신뢰 불가(Huang 2024, Kamoi TACL 2024). 외부 모델+외부 사실만 유효. context rot 방어 |
| 안전 게이트 = CI hook + codex BLOCKER + 사람 머지. 자동 머지 절대 금지 | 승인 피로 연구(93% 무비판 승인) — 클릭 승인 대신 결정론적 게이트 |
| epic(부모 이슈)에는 `agent-ready` 금지, leaf만 라벨링 | 디스패처가 추론하지 않고 구조를 따르게 |
| 거부된 PR(머지 없이 CLOSED)의 이슈는 `agent-ready`도 제거 — 자동 재시도 금지 | 사람이 거부한 일을 루프가 다시 벌이면 신뢰 붕괴 |

## 파일 구조

이 시스템 자체를 git 레포로 버전 관리한다 — `~/.claude/skills/`의 기존 symlink 컨벤션(notebooklm, obsidian-* 등)을 따른다. 루프 바디가 버전 관리되므로 나중에 이 레포에 `agent-ready` 이슈를 달아 루프가 루프를 개선할 수 있다.

```
~/Projects/refs/issue-runner/          # git 레포 (GitHub: ggqgga/issue-runner, private)
  SKILL.md                             # issue-runner 디스패처 스킬 본체
  scripts/
    setup-labels.sh                    # 레포에 라벨 세트 생성 (옵트인 부트스트랩)
    eligible-issues.sh                 # 자격 필터 → 우선순위 정렬 JSON
    claim-issue.sh                     # 직접 API 재확인 후 claim (검색 인덱스 지연 방어)
    make-worktree.sh                   # 레포 보장(clone) + worktree 생성
    reconcile.sh                       # claim 전수 점검 → 이벤트 JSON + 안전 정리
  skills/issue-prep/SKILL.md           # 기획 세션용 이슈 마감 체크리스트
  docs/2026-06-11-issue-runner-loop-plan.md  # 이 계획 문서

~/.claude/skills/issue-runner  -> ~/Projects/refs/issue-runner
~/.claude/skills/issue-prep    -> ~/Projects/refs/issue-runner/skills/issue-prep
~/Projects/loop-sandbox/               # E2E 검증용 샌드박스 레포 (Task 2에서 생성)
```

이후 Task들의 파일 경로는 `~/.claude/skills/...`로 적혀 있어도 symlink를 통해 실제로는 레포 안에 생성된다. 각 Task 끝에 `~/Projects/refs/issue-runner`에서 커밋한다.

---

### Task 0: issue-runner 레포 스캐폴드 + symlink

**Files:**
- Create: `~/Projects/refs/issue-runner/` (git 레포)
- Create: symlink 2개 (`~/.claude/skills/issue-runner`, `~/.claude/skills/issue-prep`)
- Move: 이 계획 문서 → `~/Projects/refs/issue-runner/docs/`

- [ ] **Step 1: 레포 생성 + 디렉토리 구조**

```bash
mkdir -p ~/Projects/refs/issue-runner/{scripts,skills/issue-prep,docs}
cd ~/Projects/refs/issue-runner
git init -q
gh repo create issue-runner --private --source . --description "Loop-engineering dispatcher: agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 루프"
```

- [ ] **Step 2: 계획 문서 이동**

```bash
mv ~/Projects/2026-06-11-issue-runner-loop-plan.md ~/Projects/refs/issue-runner/docs/
```

- [ ] **Step 3: symlink 생성**

```bash
ln -s ~/Projects/refs/issue-runner ~/.claude/skills/issue-runner
ln -s ~/Projects/refs/issue-runner/skills/issue-prep ~/.claude/skills/issue-prep
ls -la ~/.claude/skills/ | grep issue
```

Expected: 두 symlink가 레포를 가리킴.

- [ ] **Step 4: 첫 커밋 + push**

```bash
cd ~/Projects/refs/issue-runner
git add -A
git commit -m "chore: scaffold issue-runner repo with implementation plan"
git push -u origin main
```

---

### Task 1: 글로벌 hook이 서브에이전트의 Bash 호출에도 발동하는지 검증

루프 성패가 걸린 전제 검증. 워커(서브에이전트)의 `git commit`에 `quality-gate.sh`가 발동하지 않으면 워커 프롬프트에 lint/test 명시 실행을 추가해야 한다.

**Files:** 없음 (실험만)

- [ ] **Step 1: ruff 존재 확인**

Run: `command -v ruff || echo "MISSING"`
Expected: ruff 경로 출력. `MISSING`이면 `brew install ruff` 후 진행.

- [ ] **Step 2: 위반 코드가 staged된 프로브 레포 생성**

```bash
rm -rf /tmp/hook-probe && mkdir -p /tmp/hook-probe && cd /tmp/hook-probe
git init -q
printf 'import os\n' > probe.py   # F401: unused import — ruff가 잡는다
git add probe.py
```

- [ ] **Step 3: 서브에이전트로 커밋 시도**

Agent 툴 호출 (subagent_type: `general-purpose`):

```
prompt: """
다음을 순서대로 실행하고 결과를 그대로 보고하라. 다른 행동 금지.
1. Bash로 `cd /tmp/hook-probe` 실행 (단독 명령).
2. Bash로 정확히 `git commit -m "probe"` 실행 (단독 명령 — cd와 합치지 말 것. 합치면 hook의 if 매칭이 빠진다).
3. 커밋이 성공했는지, 차단됐는지, 차단 메시지("품질 게이트 실패" 포함 여부)를 보고.
"""
```

- [ ] **Step 4: 결과 해석 및 기록**

- 차단됨("품질 게이트 실패") → hook이 서브에이전트에도 발동. 추가 조치 불필요.
- 커밋 성공 → hook 미발동. **Task 8의 워커 프롬프트 템플릿 5번 항목에 "커밋 전 반드시 해당 스택 lint+테스트 직접 실행" 문구가 이미 포함돼 있는지 확인하고 강조 표시** (CI + codex가 백스톱).

결과를 이 plan 파일 하단 "## 검증 기록" 섹션에 한 줄 추가.

- [ ] **Step 5: 프로브 정리**

```bash
rm -rf /tmp/hook-probe
```

---

### Task 2: 샌드박스 레포 생성 (E2E 및 스크립트 테스트 베드)

**Files:**
- Create: `~/Projects/loop-sandbox/calc.py`
- Create: `~/Projects/loop-sandbox/tests/test_calc.py`
- Create: `~/Projects/loop-sandbox/CLAUDE.md`
- Create: `~/Projects/loop-sandbox/.github/workflows/test.yml`

- [ ] **Step 1: 레포 생성**

```bash
gh repo create loop-sandbox --private --clone --description "issue-runner loop E2E sandbox"
mv loop-sandbox ~/Projects/loop-sandbox 2>/dev/null || true
cd ~/Projects/loop-sandbox
```

(gh가 cwd에 clone하므로 `~/Projects`에서 실행하면 mv 불필요.)

- [ ] **Step 2: 최소 코드 + 테스트 작성**

`calc.py`:
```python
def add(a, b):
    return a + b
```

`tests/test_calc.py`:
```python
import unittest
from calc import add


class TestCalc(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)


if __name__ == "__main__":
    unittest.main()
```

`CLAUDE.md`:
```markdown
# loop-sandbox

issue-runner 루프 검증용 샌드박스.

## 테스트
python3 -m unittest discover -s tests -t .

## 규칙
- 표준 라이브러리만 사용. 외부 의존성 금지.
- 함수 하나당 테스트 하나 이상.
```

`.github/workflows/test.yml`:
```yaml
name: test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: python3 -m unittest discover -s tests -t .
```

- [ ] **Step 3: 테스트 로컬 실행**

Run: `cd ~/Projects/loop-sandbox && python3 -m unittest discover -s tests -t .`
Expected: `OK (1 test)`

- [ ] **Step 4: 커밋 + push**

```bash
git add -A
git commit -m "chore: sandbox scaffold with calc.add, unittest, CI"
git push -u origin main
```

- [ ] **Step 5: 의존성 체인이 있는 이슈 2개 생성**

```bash
gh issue create --repo ggqgga/loop-sandbox \
  --title "calc.subtract(a, b) 추가" \
  --body "$(cat <<'EOF'
## 수용 기준
- [ ] `calc.py`에 `subtract(a, b)` 함수 추가 — `a - b` 반환
- [ ] `tests/test_calc.py`에 양수/음수/0 케이스 테스트 추가
- [ ] 전체 테스트 통과

## Test plan
- python3 -m unittest discover -s tests -t .
EOF
)"

gh issue create --repo ggqgga/loop-sandbox \
  --title "calc.multiply(a, b) 추가" \
  --body "$(cat <<'EOF'
Blocked by #1

## 수용 기준
- [ ] `calc.py`에 `multiply(a, b)` 함수 추가 — 반복 덧셈으로 구현 (subtract 머지 후 진행)
- [ ] `tests/test_calc.py`에 테스트 추가
- [ ] 전체 테스트 통과

## Test plan
- python3 -m unittest discover -s tests -t .
EOF
)"
```

Expected: 이슈 #1, #2 생성. #2 본문 첫 줄이 전용 라인 `Blocked by #1`.

라벨은 아직 붙이지 않는다 — Task 3의 setup-labels 이후, Task 4 검증 시점에 붙인다.

---

### Task 3: setup-labels.sh (레포 옵트인 부트스트랩)

**Files:**
- Create: `~/.claude/skills/issue-runner/scripts/setup-labels.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# usage: setup-labels.sh <owner/repo>
# issue-runner 라벨 세트를 레포에 생성(존재 시 갱신). 이 라벨이 곧 옵트인 신호.
set -euo pipefail
repo="${1:?usage: setup-labels.sh <owner/repo>}"

gh label create "agent-ready"   --repo "$repo" --color 0E8A16 --force \
  --description "에이전트가 집어가도 되는 이슈 (스펙 완결 후 마지막에 부착)"
gh label create "agent:claimed" --repo "$repo" --color D93F0B --force \
  --description "디스패처가 점유 중 — 수동 부착/제거 금지"
gh label create "P0" --repo "$repo" --color B60205 --force --description "최우선"
gh label create "P1" --repo "$repo" --color FBCA04 --force --description "보통"
gh label create "P2" --repo "$repo" --color C2E0C6 --force --description "낮음"

echo "labels ready: $repo"
```

- [ ] **Step 2: 실행 권한 + 샌드박스 적용**

```bash
mkdir -p ~/.claude/skills/issue-runner/scripts
chmod +x ~/.claude/skills/issue-runner/scripts/setup-labels.sh
~/.claude/skills/issue-runner/scripts/setup-labels.sh ggqgga/loop-sandbox
```

Expected: `labels ready: ggqgga/loop-sandbox`

- [ ] **Step 3: 검증**

Run: `gh label list --repo ggqgga/loop-sandbox | grep -E 'agent|P[0-2]'`
Expected: 5개 라벨 모두 출력.

- [ ] **Step 4: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: setup-labels.sh — 레포 옵트인 라벨 부트스트랩"
```

---

### Task 4: eligible-issues.sh (자격 필터 + 우선순위 정렬)

**Files:**
- Create: `~/.claude/skills/issue-runner/scripts/eligible-issues.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + 모든 "Blocked by #N" 라인의 N이 CLOSED
# 정렬: P0 > P1 > P2 > 없음, 동순위는 오래된 순.
# 주의: gh search는 인덱스 지연이 있다 — 최종 재확인은 claim-issue.sh가 직접 API로 한다.
set -euo pipefail

me=$(gh api user -q .login)

cands=$(gh search issues "label:agent-ready" --owner "$me" --state open \
  --json repository,number,title,labels,createdAt --limit 50)

out="[]"
count=$(printf '%s' "$cands" | jq 'length')
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$cands" | jq -c ".[$i]")
  i=$((i + 1))
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')
  labels=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")')

  # 이미 claim 된 것 제외
  case ",$labels," in *",agent:claimed,"*) continue ;; esac

  # 본문 전용 라인 "Blocked by #N" — 모든 블로커가 CLOSED 여야 자격
  body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""')
  blockers=$(printf '%s' "$body" \
    | grep -iE '^[[:space:]]*blocked[- ]by[[:space:]]+#[0-9]+' \
    | grep -oE '#[0-9]+' | tr -d '#' || true)
  blocked=false
  for b in $blockers; do
    bstate=$(gh issue view "$b" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "OPEN")
    [ "$bstate" = "CLOSED" ] || { blocked=true; break; }
  done
  [ "$blocked" = "true" ] && continue

  prio=3
  case ",$labels," in
    *",P0,"*) prio=0 ;;
    *",P1,"*) prio=1 ;;
    *",P2,"*) prio=2 ;;
  esac

  title=$(printf '%s' "$row" | jq -r '.title')
  created=$(printf '%s' "$row" | jq -r '.createdAt')
  out=$(printf '%s' "$out" | jq -c \
    --arg repo "$repo" --argjson num "$num" --arg title "$title" \
    --argjson prio "$prio" --arg created "$created" \
    '. + [{repo:$repo, number:$num, title:$title, priority:$prio, createdAt:$created}]')
done

printf '%s' "$out" | jq 'sort_by(.priority, .createdAt)'
```

- [ ] **Step 2: 실행 권한 + 라벨 없는 상태에서 빈 결과 확인**

```bash
chmod +x ~/.claude/skills/issue-runner/scripts/eligible-issues.sh
~/.claude/skills/issue-runner/scripts/eligible-issues.sh
```

Expected: `[]` (아직 어떤 이슈에도 agent-ready가 없음). 다른 레포에 우연히 agent-ready가 있으면 그 이슈가 나올 수 있다 — 결과를 읽고 판단.

- [ ] **Step 3: 샌드박스 이슈에 라벨 부착 후 필터 검증**

```bash
gh issue edit 1 --repo ggqgga/loop-sandbox --add-label agent-ready,P1
gh issue edit 2 --repo ggqgga/loop-sandbox --add-label agent-ready,P1
sleep 30   # 검색 인덱스 반영 대기
~/.claude/skills/issue-runner/scripts/eligible-issues.sh
```

Expected: **#1만** 배열에 있음. #2는 `Blocked by #1`(OPEN)이라 제외. 30초 후에도 안 보이면 인덱스 지연 — 1~2분 후 재시도.

- [ ] **Step 4: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: eligible-issues.sh — 자격 필터 + 우선순위 정렬"
```

---

### Task 5: claim-issue.sh (직접 API 재확인 후 점유)

**Files:**
- Create: `~/.claude/skills/issue-runner/scripts/claim-issue.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# usage: claim-issue.sh <owner/repo> <issue-number>
# 검색 인덱스 지연 방어: claim 직전에 직접 API로 라벨 재확인(이중 디스패치 방지),
# claim 직후 재조회로 부착 확인.
set -euo pipefail
repo="${1:?usage: claim-issue.sh <owner/repo> <num>}"
num="${2:?usage: claim-issue.sh <owner/repo> <num>}"
me=$(gh api user -q .login)

# 사전 재확인 — 직접 API (인덱스 지연 없음)
pre=$(gh issue view "$num" --repo "$repo" --json labels,state)
state=$(printf '%s' "$pre" | jq -r '.state')
[ "$state" = "OPEN" ] || { echo "skip: $repo#$num is $state" >&2; exit 1; }
if printf '%s' "$pre" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null; then
  echo "skip: $repo#$num already claimed" >&2; exit 1
fi

gh issue edit "$num" --repo "$repo" --add-label "agent:claimed" --add-assignee "$me" >/dev/null

# 사후 확인
post=$(gh issue view "$num" --repo "$repo" --json labels)
printf '%s' "$post" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null \
  || { echo "claim 실패: 라벨 미부착 $repo#$num" >&2; exit 1; }

echo "claimed: $repo#$num"
```

- [ ] **Step 2: 실행 권한 + 샌드박스 #1 claim**

```bash
chmod +x ~/.claude/skills/issue-runner/scripts/claim-issue.sh
~/.claude/skills/issue-runner/scripts/claim-issue.sh ggqgga/loop-sandbox 1
```

Expected: `claimed: ggqgga/loop-sandbox#1`

- [ ] **Step 3: 중복 claim 거부 검증**

Run: 같은 명령 재실행.
Expected: `skip: ggqgga/loop-sandbox#1 already claimed` + exit 1.

- [ ] **Step 4: 원복 (다음 Task들을 위해 claim 해제)**

```bash
gh issue edit 1 --repo ggqgga/loop-sandbox --remove-label "agent:claimed"
```

- [ ] **Step 5: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: claim-issue.sh — 직접 API 재확인 기반 이슈 점유"
```

---

### Task 6: make-worktree.sh (레포 보장 + worktree 생성)

**Files:**
- Create: `~/.claude/skills/issue-runner/scripts/make-worktree.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# usage: make-worktree.sh <owner/repo> <issue-number>
# 레포가 ~/Projects/<name>에 없으면 clone, 있으면 fetch 후
# .claude/worktrees/issue-<N> 에 agent/issue-<N> 브랜치로 worktree 생성.
# 성공 시 worktree 절대경로를 stdout 마지막 줄에 출력.
set -euo pipefail
repo="${1:?usage: make-worktree.sh <owner/repo> <num>}"
num="${2:?usage: make-worktree.sh <owner/repo> <num>}"
name=${repo#*/}
dir="$HOME/Projects/$name"
branch="agent/issue-$num"
wt="$dir/.claude/worktrees/issue-$num"

[ -d "$dir/.git" ] || gh repo clone "$repo" "$dir"
git -C "$dir" fetch origin --prune

default=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name')

# .claude/ 를 레포 오염 없이 로컬에서만 무시
mkdir -p "$dir/.git/info"
grep -qx '.claude/' "$dir/.git/info/exclude" 2>/dev/null \
  || echo '.claude/' >> "$dir/.git/info/exclude"

if [ -d "$wt" ]; then
  echo "exists: $wt" >&2
  echo "$wt"
  exit 0
fi

mkdir -p "$dir/.claude/worktrees"
if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  # 원격에 브랜치가 이미 있음(보수 재투입 케이스) — 그 위에 worktree
  git -C "$dir" worktree add "$wt" -B "$branch" "origin/$branch" >/dev/null
else
  git -C "$dir" worktree add "$wt" -b "$branch" "origin/$default" >/dev/null
fi
echo "$wt"
```

- [ ] **Step 2: 실행 권한 + 샌드박스 worktree 생성 검증**

```bash
chmod +x ~/.claude/skills/issue-runner/scripts/make-worktree.sh
~/.claude/skills/issue-runner/scripts/make-worktree.sh ggqgga/loop-sandbox 1
```

Expected: 마지막 줄 `/Users/ggq/Projects/loop-sandbox/.claude/worktrees/issue-1`

- [ ] **Step 3: 멱등성 검증 (재실행)**

Run: 같은 명령 재실행.
Expected: stderr `exists: ...`, stdout 동일 경로, exit 0.

- [ ] **Step 4: worktree 상태 확인 후 정리 (Task 7 테스트에서 다시 만든다)**

```bash
git -C ~/Projects/loop-sandbox worktree list
git -C ~/Projects/loop-sandbox worktree remove ~/Projects/loop-sandbox/.claude/worktrees/issue-1
git -C ~/Projects/loop-sandbox branch -D agent/issue-1
```

Expected: worktree 목록에 issue-1이 보였다가 제거됨.

- [ ] **Step 5: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: make-worktree.sh — 레포 보장 + worktree 생성"
```

---

### Task 7: reconcile.sh (claim 전수 점검 + 안전 정리)

**Files:**
- Create: `~/.claude/skills/issue-runner/scripts/reconcile.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# claim 된 이슈 전수 점검. 이벤트를 JSON lines 로 출력하고 안전 정리를 수행.
# 이벤트:
#   merged   — PR 머지됨 → worktree 제거 + claim 해제 (이슈는 Closes 로 자동 닫힘)
#   rejected — PR 이 머지 없이 닫힘 → 정리 + agent-ready 도 제거 (자동 재시도 금지)
#   pr_open  — PR 열려 있음 (failing 카운트 포함 → Maintain 단계 입력)
#   working  — PR 없고 worktree 있음 → 워커 진행 중으로 간주
#   stale    — PR 없고 worktree 도 없음 → 죽은 claim 해제
#   warn     — dirty/unpushed worktree → 제거 보류, 사람 확인 필요
set -uo pipefail

me=$(gh api user -q .login)

# 주의: --state 미지정 = open+closed 모두 (merged PR 이 이슈를 자동으로 닫으므로 필수)
claimed=$(gh search issues "label:agent:claimed" --owner "$me" \
  --json repository,number --limit 100)

printf '%s' "$claimed" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')
  name=${repo#*/}
  dir="$HOME/Projects/$name"
  branch="agent/issue-$num"
  wt="$dir/.claude/worktrees/issue-$num"

  safe_remove_worktree() {
    [ -d "$wt" ] || return 0
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      printf '{"event":"warn","repo":"%s","number":%s,"msg":"worktree dirty — 제거 보류"}\n' "$repo" "$num"
      return 1
    fi
    local ahead
    ahead=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "unknown")
    if [ "$ahead" != "0" ]; then
      printf '{"event":"warn","repo":"%s","number":%s,"msg":"미push 커밋(%s) — 제거 보류"}\n' "$repo" "$num" "$ahead"
      return 1
    fi
    git -C "$dir" worktree remove "$wt" >/dev/null 2>&1 || return 1
    git -C "$dir" branch -D "$branch" >/dev/null 2>&1 || true
    return 0
  }

  pr=$(gh pr list --repo "$repo" --head "$branch" --state all \
    --json number,state,statusCheckRollup --limit 1 2>/dev/null | jq -c '.[0] // empty')

  if [ -z "$pr" ]; then
    if [ -d "$wt" ]; then
      printf '{"event":"working","repo":"%s","number":%s}\n' "$repo" "$num"
    else
      gh issue edit "$num" --repo "$repo" --remove-label "agent:claimed" >/dev/null 2>&1 || true
      printf '{"event":"stale","repo":"%s","number":%s}\n' "$repo" "$num"
    fi
    continue
  fi

  prnum=$(printf '%s' "$pr" | jq -r '.number')
  prstate=$(printf '%s' "$pr" | jq -r '.state')

  case "$prstate" in
    MERGED)
      if safe_remove_worktree; then
        gh issue edit "$num" --repo "$repo" --remove-label "agent:claimed" >/dev/null 2>&1 || true
        printf '{"event":"merged","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    CLOSED)
      if safe_remove_worktree; then
        gh issue edit "$num" --repo "$repo" \
          --remove-label "agent:claimed" --remove-label "agent-ready" >/dev/null 2>&1 || true
        printf '{"event":"rejected","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    OPEN)
      failing=$(printf '%s' "$pr" | jq '[.statusCheckRollup[]?
        | select((.conclusion // .state // "")
          | test("FAILURE|ERROR|CANCELLED|TIMED_OUT"))] | length')
      printf '{"event":"pr_open","repo":"%s","number":%s,"pr":%s,"failing":%s}\n' \
        "$repo" "$num" "$prnum" "$failing" ;;
  esac
done
```

- [ ] **Step 2: 실행 권한 + stale 시나리오 검증**

```bash
chmod +x ~/.claude/skills/issue-runner/scripts/reconcile.sh
# stale 상황 연출: claim만 하고 worktree/PR 없음
~/.claude/skills/issue-runner/scripts/claim-issue.sh ggqgga/loop-sandbox 1
sleep 30   # 검색 인덱스 반영 대기
~/.claude/skills/issue-runner/scripts/reconcile.sh
```

Expected: `{"event":"stale","repo":"ggqgga/loop-sandbox","number":1}` 출력, 이슈 #1의 `agent:claimed` 라벨이 해제됨.

- [ ] **Step 3: working 시나리오 검증**

```bash
~/.claude/skills/issue-runner/scripts/claim-issue.sh ggqgga/loop-sandbox 1
~/.claude/skills/issue-runner/scripts/make-worktree.sh ggqgga/loop-sandbox 1
sleep 30
~/.claude/skills/issue-runner/scripts/reconcile.sh
```

Expected: `{"event":"working",...}` — claim 유지, worktree 유지.

- [ ] **Step 4: 원복**

```bash
git -C ~/Projects/loop-sandbox worktree remove ~/Projects/loop-sandbox/.claude/worktrees/issue-1
git -C ~/Projects/loop-sandbox branch -D agent/issue-1
gh issue edit 1 --repo ggqgga/loop-sandbox --remove-label "agent:claimed"
```

(merged/rejected 이벤트는 Task 10 E2E에서 실제 PR로 검증한다.)

- [ ] **Step 5: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: reconcile.sh — claim 전수 점검 + 안전 정리"
```

---

### Task 8: issue-runner SKILL.md (디스패처 본체)

**Files:**
- Create: `~/.claude/skills/issue-runner/SKILL.md`

- [ ] **Step 1: SKILL.md 작성** (아래 전문 그대로)

````markdown
---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

## 상수

- `MAX_AGENTS = 2` — 동시 in-flight(claim 상태) 이슈 상한
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — 성공 종료. **lessons 단계**: 해당 PR에 CHANGES_REQUESTED 리뷰가 있었거나
  CI 실패 이력이 있으면 (gh pr view <pr> --repo <repo> --json reviews 와
  gh run list 로 확인), codex:codex-rescue 서브에이전트를 동기 호출해 교훈 한 줄을 받아라:

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `~/Projects/<repo-name>/.loop/lessons.md` 에
  `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append. **20줄 초과 시 가장 오래된 줄 삭제**
  (context rot 방어). lessons를 CLAUDE.md로 옮기는 것은 사람만 한다.
- `rejected` — 사람이 PR을 거부함. lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. 죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로, 커밋이 전혀 없으면
  worktree 제거 후 claim 해제 (재디스패치 가능 상태로 복귀).

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

1. `failing > 0` → 실패 로그를 확인하고 (gh run view --log-failed), 플레이크로 보이면
   re-run (gh run rerun), 진짜 실패면 아래 워커 템플릿으로 **보수 에이전트**를
   백그라운드 디스패치 (worktree 가 없으면 `$SCRIPTS/make-worktree.sh` 가 원격
   브랜치 위에 재생성해 준다).
2. 미해결 리뷰 코멘트 → 같은 방식으로 보수 에이전트에 코멘트 해결을 지시.
3. base 와 conflict → 보수 에이전트에 rebase (merge 금지) 를 지시.
4. CI green + 리뷰 코멘트 없음 → 손대지 않는다. 사람 리뷰 대기 상태.

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + `pr_open` + 이번 틱에 ②로 투입한 것의 수.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로
   보이는 이슈가 둘 이상이면 이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다
   (충돌은 다음 틱 rebase 가 풀어준다).
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim 등)하면 다음 후보로.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로.
   c. `~/Projects/<repo-name>/.loop/lessons.md` 가 있으면 내용을 읽어 둔다.
   d. 아래 워커 템플릿으로 Agent 툴 백그라운드 디스패치.

### 워커 프롬프트 템플릿

Agent(subagent_type: "general-purpose", run_in_background: true,
      description: "<repo>#<num> 구현", prompt: 아래)

```
당신은 무인 이슈 구현 워커다. 작업 디렉토리: <WT_PATH> (이 밖을 수정하지 마라)
대상: <REPO> 이슈 #<NUM> — <TITLE>

중요: 셸 cwd 는 Bash 호출 간 유지되지 않는다. 모든 셸 명령은
`cd <WT_PATH> && <명령>` 복합 형태로 실행하거나 절대 경로(`git -C <WT_PATH>`)를 써라.

절차:
1. <WT_PATH> 의 CLAUDE.md 를 읽고 빌드/테스트 방법을 파악하라.
2. 아래 '과거 교훈'을 읽고 같은 실수를 피하라.
3. `gh issue view <NUM> --repo <REPO>` 로 이슈 본문(수용 기준 체크박스)을 정독하라.
   본문이 모호해서 구현 방향을 정할 수 없으면 **작업하지 말고** 이슈에
   `gh issue comment` 로 질문을 남기고 "BLOCKED: <사유>" 로 종료 보고하라.
4. TDD로 구현하라: 실패 테스트 → 최소 구현 → 통과. 작은 단위마다 커밋.
5. 커밋 전 해당 스택의 lint 와 테스트를 직접 실행해 통과를 확인하라.
6. **매 커밋 직후 `git push -u origin agent/issue-<NUM>`** — 이 worktree 는 언제든
   버려질 수 있다. push 안 된 작업은 존재하지 않는 것과 같다.
7. 전체 테스트 통과를 확인한 뒤 PR 을 열어라:
   `gh pr create --repo <REPO>` — 본문에 반드시 전용 라인 `Closes #<NUM>` 과
   `## Test plan` 섹션(수용 기준 기반 체크박스)을 포함하라.
8. PR 생성 직후 주입되는 codex 리뷰 지시를 따르라. codex 가 BLOCKER 를 보고하면
   **반드시 해결 커밋 + push 후에만** 종료하라. BLOCKER 미해결 종료 금지.
9. 종료 보고: PR 번호/URL, 테스트 결과, codex 리뷰 처리 내역, 남은 사항.

금지: 머지, main/master 직접 push, 이슈 라벨 변경, 다른 이슈 작업, <WT_PATH> 밖 수정.

과거 교훈:
<LESSONS_OR_"없음">
```

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 대기(사람 리뷰) N · warn N`.
warn 이 있으면 경로와 사유를 그 아래 나열. 모든 카운트가 0이면 "조용함" 한 줄만.
3틱 연속 조용하면 다음 틱부터는 reconcile 만 하고 끝내라.
````

- [ ] **Step 2: 스킬 인식 검증**

Run: 새 Claude Code 세션에서 `/issue-runner` 입력이 자동완성에 뜨는지 확인 (또는 `ls ~/.claude/skills/issue-runner/SKILL.md`).
Expected: 파일 존재 + frontmatter 유효 (name, description).

- [ ] **Step 3: Task 1 결과 반영 확인**

Task 1에서 hook 미발동으로 판명났다면 템플릿 5번 항목이 그 보완이다 — 항목이 존재하는지 확인. (이미 포함되어 있음 — 확인만.)

- [ ] **Step 4: 커밋**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: issue-runner SKILL.md — 디스패처 틱 + 워커 템플릿"
```

---

### Task 9: issue-prep SKILL.md (기획 세션용 이슈 마감 체크리스트)

**Files:**
- Create: `~/.claude/skills/issue-prep/SKILL.md`

- [ ] **Step 1: SKILL.md 작성** (아래 전문 그대로)

````markdown
---
name: issue-prep
description: 이슈를 issue-runner 루프에 넘기기 전 마감 체크리스트. 기획 세션에서 이슈 작성을 끝낼 때, 또는 "이슈 마감", "agent-ready 붙여줘" 요청 시 사용. 체크리스트 통과 후에만 agent-ready 라벨을 부착한다.
---

# issue-prep — 이슈 마감 체크리스트

이슈를 루프에 넘기기 전 아래를 **모두** 확인하고, 통과한 이슈에만 `agent-ready` 를 붙인다.
워커는 이 세션의 맥락을 전혀 공유하지 않는다 — 이슈 본문이 유일한 스펙이다.

## 체크리스트

1. **자기완결 스펙**: 이 대화의 맥락 없이 이슈 본문만 읽고 구현할 수 있는가?
   배경·동기·제약을 본문에 다 적었는가?
2. **수용 기준**: `- [ ]` 체크박스로 구체적·검증가능하게. "잘 동작" 같은 모호어 금지.
3. **Test plan**: `## Test plan` 섹션에 실행할 검증 명령/시나리오.
4. **의존성**: 선행 이슈가 있으면 본문에 **전용 라인** `Blocked by #N` (한 줄에 하나,
   라인 시작 위치). 산문 속 언급은 디스패처가 읽지 못한다.
5. **계층**: epic(부모)이면 sub-issue 로 쪼개고 **leaf 에만** agent-ready 를 붙인다.
   epic 본체에는 절대 붙이지 않는다.
6. **우선순위**: P0/P1/P2 라벨 하나 부착 (없으면 최하순위로 처리됨).
7. **레포 준비**: 해당 레포에 (a) 라벨 세트가 있는가 —
   없으면 `~/.claude/skills/issue-runner/scripts/setup-labels.sh <owner/repo>` 실행,
   (b) CLAUDE.md 에 빌드/테스트 명령이 적혀 있는가 — 없으면 워커가 검증을 못 한다.
   먼저 보완하라.
8. **충돌 예상**: 이미 agent-ready/claimed 인 다른 이슈와 같은 모듈을 건드리는가?
   그렇다면 Blocked by 로 직렬화를 고려하라.

## 마감

전 항목 통과 → `gh issue edit <N> --repo <owner/repo> --add-label agent-ready` +
우선순위 라벨. 하나라도 미통과 → 보완할 내용을 사용자에게 보고하고 라벨을 붙이지 않는다.
````

- [ ] **Step 2: 검증**

Run: `ls ~/.claude/skills/issue-prep/SKILL.md && head -5 ~/.claude/skills/issue-prep/SKILL.md`
Expected: 파일 존재, frontmatter 유효.

- [ ] **Step 3: 커밋 + push**

```bash
cd ~/Projects/refs/issue-runner && git add -A && git commit -m "feat: issue-prep SKILL.md — 이슈 마감 체크리스트" && git push
```

---

### Task 10: E2E — 샌드박스에서 수동 1틱 실행

루프 없이 `/issue-runner` 를 직접 1회 호출해 전체 흐름을 검증한다.

- [ ] **Step 1: 사전 상태 확인**

```bash
gh issue view 1 --repo ggqgga/loop-sandbox --json labels -q '[.labels[].name]'
~/.claude/skills/issue-runner/scripts/eligible-issues.sh
```

Expected: #1에 `agent-ready`,`P1`만 (claimed 없음). eligible 결과에 #1만 포함 (#2는 blocked).

- [ ] **Step 2: 디스패처 틱 실행**

**별도의 새 Claude Code 세션**(터미널, `cd ~/Projects`)에서 `/issue-runner` 1회 실행.
Expected 동작 순서:
1. reconcile: 이벤트 없음
2. maintain: 대상 없음
3. dispatch: #1 claim → worktree 생성 → 백그라운드 워커 투입
4. report: `정리 0 · 보수 0 · 신규 1 · 대기 0 · warn 0`

- [ ] **Step 3: 워커 완료 대기 + PR 검증**

워커 완료 후 (수 분):

```bash
gh pr list --repo ggqgga/loop-sandbox --head agent/issue-1 --json number,title,body
gh pr checks $(gh pr list --repo ggqgga/loop-sandbox --head agent/issue-1 --json number -q '.[0].number') --repo ggqgga/loop-sandbox
```

Expected: PR 존재, 본문에 전용 라인 `Closes #1` + `## Test plan`, CI green. PR 본문/코멘트에 codex 리뷰 흔적.

- [ ] **Step 4: 사람 머지 (사용자가 직접)**

GitHub 웹 또는 `gh pr merge <N> --repo ggqgga/loop-sandbox --squash` (ci-gate hook이 green 확인 후 통과시킴).
Expected: 머지 성공, 이슈 #1이 `Closes #1`로 자동 클로즈.

- [ ] **Step 5: 2틱 — reconcile + 의존성 해제 검증**

같은 디스패처 세션에서 `/issue-runner` 재실행.
Expected:
1. reconcile: `merged` 이벤트 → worktree 제거, claim 해제 확인:
   `git -C ~/Projects/loop-sandbox worktree list` 에 issue-1 없음
2. dispatch: **#2가 이제 자격 획득** (#1 CLOSED) → claim → 워커 투입
3. report: `정리 1 · 보수 0 · 신규 1 · ...`

- [ ] **Step 6: #2 PR 도 동일 검증 후 머지, 최종 정리 확인**

3틱에서 `merged` 처리 후:

```bash
git -C ~/Projects/loop-sandbox worktree list   # main 만 남음
gh issue list --repo ggqgga/loop-sandbox       # 빈 목록 (둘 다 closed)
```

- [ ] **Step 7: 검증 기록 작성**

이 plan 파일 하단 "## 검증 기록"에 E2E 결과(걸린 시간, 워커가 막힌 지점, 수정한 것) 기록.

---

### Task 11: 실전 가동

- [ ] **Step 1: 실제 레포 1개 옵트인**

실제 작업 중인 레포 하나를 골라:

```bash
~/.claude/skills/issue-runner/scripts/setup-labels.sh ggqgga/<real-repo>
```

CLAUDE.md에 빌드/테스트 명령이 있는지 확인, 없으면 추가.

- [ ] **Step 2: 기획 세션에서 이슈 2~3개를 /issue-prep 으로 마감**

이 세션(또는 새 세션)에서 이슈 작성 → `/issue-prep` 체크리스트 통과 → agent-ready 부착.

- [ ] **Step 3: 루프 가동**

**별도 터미널** (인터랙티브 작업 세션과 분리):

```bash
cd ~/Projects && claude
# 세션 안에서:
/loop 15m /issue-runner
```

- [ ] **Step 4: 반나절 관찰 후 튜닝**

관찰 포인트: (a) 틱당 토큰 소모, (b) warn 이벤트 발생 여부, (c) 워커 품질(PR이 리뷰할 만한가), (d) lessons 가 쌓이는 내용의 질. 필요시 MAX_AGENTS·인터벌 조정, 워커 템플릿 보강.

---

## 리스크 & 미해결

- **gh search 인덱스 지연**: eligible/reconcile이 검색 기반이라 라벨 변경 직후 1~2분 동안 낡은 결과 가능. claim-issue.sh의 직접 API 재확인이 이중 디스패치를 막지만, reconcile의 stale 판정이 한 틱 늦을 수 있다 — 허용.
- **lessons 효과는 미검증 영역**: 연구상 가장 근거 약한 부분. 20줄 캡 + 객관 사실 한정 + codex 작성으로 시작하고, 반나절 관찰(Task 11 Step 4)에서 질이 낮으면 끈다.
- **서브에이전트 hook 발동 여부**: Task 1 결과에 따라 워커 템플릿 의존도가 달라짐. 미발동이어도 CI + codex가 백스톱.
- **Claude Code 자동 worktree 정리와의 간섭**: `.claude/worktrees/` 경로를 쓰므로 CC의 stale 정리 대상이 될 수 있음. 워커가 "매 커밋 push" 규칙을 지키면 잃을 게 없다 — 이 규칙이 깨지는 순간이 진짜 리스크이므로 warn 이벤트를 무시하지 말 것.
- **비용**: 틱당 디스패처 + 워커 N개. MAX_AGENTS=2, 15분 인터벌로 시작해 관찰 후 조정.

## 검증 기록

- **Task 1 (2026-06-11)**: 글로벌 PreToolUse hook은 **서브에이전트의 Bash 호출에도 발동한다** — require-issue-in-pr.sh가 서브에이전트의 `gh pr create`를 거부 메시지 전문과 함께 차단함 (gh 실행 전 차단 확인). 단 두 가지 부수 발견:
  1. **서브에이전트 셸 cwd는 호출 간 유지되지 않고 매번 세션 디렉토리로 리셋**된다. → 워커는 `cd` 단독 호출에 의존하면 안 되고, 복합 명령(`cd <wt> && ...`) 또는 절대 경로(`git -C`)를 써야 한다. Task 8 워커 템플릿에 반영.
  2. **quality-gate.sh는 워커 커밋을 사실상 보호하지 못한다** — cwd 기준으로 repo를 찾는데 hook 프로세스의 cwd는 세션 디렉토리(~/Projects, 비 git)라 발동해도 조용히 exit 0. 워커 템플릿 5번(커밋 전 lint/테스트 직접 실행)이 유일한 커밋 전 방어선이며, CI + codex가 백스톱. 1차 프로브(ruff F401 staged 후 커밋)는 이 cwd 문제로 교란되어 비결정적이었고, git 불필요한 require-issue hook으로 2차 프로브에서 발동을 확정했다.
