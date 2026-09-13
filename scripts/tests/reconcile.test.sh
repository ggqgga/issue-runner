#!/usr/bin/env bash
# reconcile.sh 재claim 필터 픽스처 테스트 (#131) — 네트워크 무접속.
#
# 가드하는 결함 셋:
#   ① fail-open  — 타임라인 조회가 실패하면 필터가 통째로 건너뛰어져 **이전 attempt 의
#                  머지 PR** 이 현재 claim 의 PR 로 취급되고, 살아있는 워커의 worktree·
#                  agent:claimed 가 지워졌다 (#3447 재발 경로).
#   ② 스윕 미적용 — 같은 실행 뒤쪽의 "최근 머지 agent PR 스윕"이 필터를 안 거쳐,
#                  ① 에서 걸러낸 그 PR 을 다시 주워 같은 파괴를 했다.
#   ③ 같은 초 경계 — mergedAt 과 claim 시각이 같은 초면 `<` 비교가 옛 머지를 남겼다.
#
# 그리고 gh-login.sh 의 순차 폴백(REST 성공 시 GraphQL 미호출)도 여기서 실증한다.
# bats 미도입 레포라 release-labels.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name"
  fi
}

ts() {  # ts <분 전> → RFC3339 UTC
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── 픽스처 SCRIPT_DIR — SUT 사본 + 파괴 동작을 대신 기록하는 스텁 헬퍼들 ──────
sut_dir="$tmp/scripts"
mkdir -p "$sut_dir"
cp "$DIR/reconcile.sh" "$sut_dir/reconcile.sh"
# SUT 는 `$SCRIPT_DIR/lib/` 를 source·include 한다 — 사본 옆에 라이브러리도 나란히 둔다 (#427·#426).
cp -R "$DIR/lib" "$sut_dir/lib"
cat > "$sut_dir/gh-login.sh" <<'STUB'
#!/bin/sh
echo tester
STUB
cat > "$sut_dir/repo-dir.sh" <<STUB
#!/bin/sh
echo "$tmp/proj/repo"
STUB
# 이 둘이 호출되면 = 실제 정리(파괴)가 일어났다는 뜻 — 로그로 잡는다.
cat > "$sut_dir/cleanup-worktree.sh" <<'STUB'
#!/bin/sh
printf 'cleanup %s\n' "$*" >> "$STUB_DESTROY_LOG"
STUB
cat > "$sut_dir/release-labels.sh" <<'STUB'
#!/bin/sh
printf 'release %s\n' "$*" >> "$STUB_DESTROY_LOG"
STUB
# (#394) 반쯤 이동 판별이 부르는 세 조회 — 값은 env 픽스처로 준다. **빈 값 = 조회 실패**
# (비0 종료)라, 그 방향이 `pr_open`(종전 동작)으로 떨어지는지까지 아래 격자가 문다.
cat > "$sut_dir/pr-comments.sh" <<'STUB'
#!/bin/sh
[ -n "$STUB_PR_COMMENTS" ] || exit 1
printf '%s' "$STUB_PR_COMMENTS"
STUB
cat > "$sut_dir/pr-head-at.sh" <<'STUB'
#!/bin/sh
[ -n "$STUB_HEAD_RAW" ] || exit 1
printf '%s' "$STUB_HEAD_RAW"
STUB
cat > "$sut_dir/claim-at.sh" <<'STUB'
#!/bin/sh
[ -n "$STUB_CLAIM_AT" ] || exit 2
printf '%s' "$STUB_CLAIM_AT"
STUB
# 진행 증거 판정은 **진짜 헬퍼**를 쓴다(#200·#206 의 술어 한 자리). 스텁으로 바꾸면
# 이 격자가 "reconcile 이 그 술어를 제대로 부르는가" 를 못 본다 — 큐 로그만 빈 파일로 준다.
cp "$DIR/progress-evidence.sh" "$sut_dir/progress-evidence.sh"
chmod +x "$sut_dir"/*.sh
: > "$tmp/queue.log"

# ── gh 스텁 — 호출 형태별 응답. 타임라인은 STUB_CLAIMED_AT 이 비면 실패 모사 ────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
case "$*" in
  "api user"*)                  # SUT 가 헬퍼 대신 직접 물어보는 경우도 답한다
    echo tester ;;
  "search issues label:agent:claimed"*)
    printf '%s\n' "$STUB_CLAIMED" ;;
  "search issues label:agent-ready"*)   # 스윕 레포 목록(.loop/repos 없을 때 경로)
    echo '[{"repository":{"nameWithOwner":"owner/repo"}}]' ;;
  *"--state all"*)              # 브랜치의 PR 전수 (main 루프 입력)
    printf '%s\n' "$STUB_BRANCH_PRS" ;;
  *"--state merged"*)           # ②-보강 스윕 입력
    printf '%s\n' "$STUB_SWEEP_PRS" ;;
  *timeline*)
    [ -n "$STUB_CLAIMED_AT" ] || exit 1
    printf '%s\n' "$STUB_CLAIMED_AT"
    exit "${STUB_TIMELINE_RC:-0}" ;;   # 0 이 아니면 "앞 페이지는 나왔지만 중단" 모사
  "issue edit"*) : ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

default_claimed='[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]'

# run — 픽스처 한 케이스 실행. stdout(이벤트) 은 $tmp/events, stderr 는 $tmp/err,
# 파괴 호출은 $tmp/destroy.log, gh 호출은 $tmp/gh.log 에 남는다.
run() {  # run <branch_prs_json> <claimed_at|""> <sweep_prs_json>
  rm -rf "$tmp/run"; mkdir -p "$tmp/run/.loop"
  echo owner/repo > "$tmp/run/.loop/repos"   # 스윕 대상 레포 — 이게 없으면 스윕이 안 돈다
  : > "$tmp/destroy.log"; : > "$tmp/gh.log"
  ( cd "$tmp/run" && \
    STUB_BRANCH_PRS="$1" STUB_CLAIMED_AT="$2" STUB_SWEEP_PRS="$3" \
    STUB_CLAIMED="${4:-$default_claimed}" \
    STUB_PR_COMMENTS="${STUB_PR_COMMENTS:-}" STUB_HEAD_RAW="${STUB_HEAD_RAW:-}" \
    STUB_CLAIM_AT="${STUB_CLAIM_AT:-}" PE_QUEUE_LOG="$tmp/queue.log" \
    STUB_DESTROY_LOG="$tmp/destroy.log" STUB_GH_LOG="$tmp/gh.log" \
    PATH="$tmp/bin:$PATH" bash "$sut_dir/reconcile.sh" ) \
    > "$tmp/events" 2> "$tmp/err"
}
rerun() {  # rerun <branch_prs> <claimed_at|""> <sweep_prs> [claimed_json] — .loop 상태 유지
  : > "$tmp/destroy.log"; : > "$tmp/gh.log"
  ( cd "$tmp/run" && \
    STUB_BRANCH_PRS="$1" STUB_CLAIMED_AT="$2" STUB_SWEEP_PRS="$3" \
    STUB_CLAIMED="${4:-$default_claimed}" STUB_TIMELINE_RC="${STUB_TIMELINE_RC:-0}" \
    STUB_DESTROY_LOG="$tmp/destroy.log" STUB_GH_LOG="$tmp/gh.log" \
    PATH="$tmp/bin:$PATH" bash "$sut_dir/reconcile.sh" ) \
    > "$tmp/events" 2> "$tmp/err"
}
destroyed() { [ -s "$tmp/destroy.log" ] && echo yes || echo no; }
seen()      { grep -qxF "$1" "$tmp/run/.loop/seen-merges" 2>/dev/null && echo yes || echo no; }
event_has() { grep -q "\"event\":\"$1\"" "$tmp/events" && echo yes || echo no; }
swept()     { grep -q -- '--state merged' "$tmp/gh.log" && echo yes || echo no; }
# agent:claimed 를 실제로 뗐는지 — 스텁 gh 는 인자를 그대로 로그에 남긴다.
# "라벨 제거 + 스윕 차단" 조합이 머지 유실의 원인이라 두 방향 모두 물어야 한다 (#141).
claim_removed() {
  grep -q -- 'issue edit 42 .*--remove-label agent:claimed' "$tmp/gh.log" && echo yes || echo no
}

merged_recent=$(ts 2)     # 스윕 cutoff(30분) 안 = 스윕이 발행 대상으로 삼는 최신 머지
now=$(ts 0)
old_claim=$(ts 10)

# 브랜치에 옛 attempt 의 머지 PR #7 하나. 스윕도 같은 PR 을 본다.
branch_prs='[{"number":7,"state":"MERGED","mergedAt":"'$merged_recent'","statusCheckRollup":[],"labels":[]}]'
sweep_prs='[{"number":7,"headRefName":"agent/issue-42","mergedAt":"'$merged_recent'"}]'

# ── ① 타임라인 조회 실패 → 정리 없음 + stderr 사유 (fail-closed) ─────────────
run "$branch_prs" "" "$sweep_prs"
check "① 타임라인 실패: 정리(worktree·라벨) 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "① 타임라인 실패: stderr 에 사유(fail-closed)" \
  "$(grep -q 'fail-closed' "$tmp/err" && echo ok || echo no)"
check "① 타임라인 실패: merged 이벤트 미발행" \
  "$([ "$(event_has merged)" = no ] && echo ok || echo no)"

# ── ② 같은 실행의 보강 스윕도 그 PR 을 다시 줍지 않는다 ──────────────────────
check "② 스윕이 실제로 돌았다(공회전 아님)" \
  "$([ "$(swept)" = yes ] && echo ok || echo no)"
check "② 스윕: 최근 머지인데도 정리 미실행(보류 목록으로 차단)" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "② 보류분은 영속 레저(seen-merges)에 굳지 않는다 — 다음 실행이 재판정" \
  "$([ "$(seen 'owner/repo#7')" = no ] && echo ok || echo no)"

# ── ③ 정상 타임라인 + 옛 머지 → 필터됨 (현재 claim 의 PR 아님) ───────────────
run "$branch_prs" "$now" "$sweep_prs"
check "③ 옛 머지 PR: merged 이벤트 미발행" \
  "$([ "$(event_has merged)" = no ] && echo ok || echo no)"
check "③ 옛 머지 PR: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "③ 옛 머지 PR: stale 로 claim 만 해제" \
  "$([ "$(event_has stale)" = yes ] && echo ok || echo no)"
check "③ 옛 머지 PR: 스윕 차단용 레저 기록" \
  "$([ "$(seen 'owner/repo#7')" = yes ] && echo ok || echo no)"
# 과교정 반대편 가드 (#141): 동률이 아닌 **확실히 이전**인 머지는 지금처럼 stale 로
# agent:claimed 를 뗀다 — 축 2 를 고치느라 라벨 해제를 통째로 멈추면 죽은 claim 이 쌓인다.
check "③ 옛 머지 PR: agent:claimed 는 여전히 제거(죽은 claim 해제 유지)" \
  "$([ "$(claim_removed)" = yes ] && echo ok || echo no)"

# ── ④ 같은 초 경계 — mergedAt == claim 시각은 이전 attempt (`<=`) ────────────
same_second='[{"number":7,"state":"MERGED","mergedAt":"'$now'","statusCheckRollup":[],"labels":[]}]'
run "$same_second" "$now" '[]'
check "④ 같은 초: merged 이벤트 미발행(<= 로 이전 attempt 처리)" \
  "$([ "$(event_has merged)" = no ] && echo ok || echo no)"
check "④ 같은 초: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"

# ── ⑤ 회귀 가드 — **이번 claim** 의 머지는 여전히 정리된다(과차단 아님) ──────
current='[{"number":9,"state":"MERGED","mergedAt":"'$now'","statusCheckRollup":[],"labels":[]}]'
run "$current" "$old_claim" '[]'
check "⑤ 현재 claim 머지: merged 이벤트 발행" \
  "$([ "$(event_has merged)" = yes ] && echo ok || echo no)"
check "⑤ 현재 claim 머지: 정리 실행" \
  "$([ "$(destroyed)" = yes ] && echo ok || echo no)"

# ── ⑤-b 더티 worktree — 정리가 보류되면 merged 가 아니라 warn 한 줄 (#62) ──────
# 위 ⑤ 는 파괴 호출을 스텁으로 가로채 "불렸는가" 만 본다. 헬퍼가 **보류**를 돌려줬을 때
# reconcile 이 그걸 성공으로 삼키지 않는지는 진짜 헬퍼라야 보인다 — 더티 worktree 를
# merged 로 찍으면 사람이 손댄 변경이 있는 채로 이슈가 닫히고 아무도 안 본다.
# 이 케이스만 진짜 cleanup-worktree.sh 를 끼우고 곧바로 스텁으로 되돌린다(다른 케이스는
# 파괴 호출을 로그로만 재야 하므로). repo-dir.sh 스텁이 픽스처 밖으로 못 나가게 가둔다.
cp "$DIR/cleanup-worktree.sh" "$sut_dir/cleanup-worktree.sh"
dirty_wt="$tmp/proj/repo/.claude/worktrees/issue-42"
mkdir -p "$dirty_wt"
git -C "$dirty_wt" init -q 2>/dev/null
printf 'dirty\n' > "$dirty_wt/uncommitted.txt"
run "$current" "$old_claim" '[]'
warn_n=$(grep -c '"event":"warn"' "$tmp/events" || true)
merged_n=$(grep -c '"event":"merged"' "$tmp/events" || true)
check "⑤-b 더티 worktree: warn 정확히 한 줄" "$([ "$warn_n" = 1 ] && echo ok || echo no)"
check "⑤-b 더티 worktree: merged 미발행(보류를 성공으로 안 삼킨다)" \
  "$([ "$merged_n" = 0 ] && echo ok || echo no)"
check "⑤-b 더티 worktree: warn 사유가 dirty" \
  "$(grep -q 'dirty' "$tmp/events" && echo ok || echo no)"
rm -rf "$tmp/proj/repo/.claude"
cat > "$sut_dir/cleanup-worktree.sh" <<'STUB'
#!/bin/sh
printf 'cleanup %s\n' "$*" >> "$STUB_DESTROY_LOG"
STUB
chmod +x "$sut_dir/cleanup-worktree.sh"

# ── ⑥ 비공허 실증 — 스텁이 실제로 소비됐는지(테스트 공회전 방지) ─────────────
check "⑥ 스텁 경유 실증: 타임라인 조회가 실제로 일어난다" \
  "$(grep -q 'timeline' "$tmp/gh.log" && echo ok || echo no)"
check "⑥ 스텁 경유 실증: 브랜치 PR 조회가 실제로 일어난다" \
  "$(grep -q -- '--state all' "$tmp/gh.log" && echo ok || echo no)"

# ── ⑨ 부분 페이지네이션 — 앞 페이지 값이 나왔어도 완주 못 했으면 버린다 ────
# 타임라인이 100건을 넘고 뒤쪽 페이지가 실패하면 마지막 성공 페이지의 **옛 claim
# 시각**이 남는다. 그걸 신뢰하면 옛 머지가 "현재 claim 완료" 로 오인돼 정리가 돈다.
old_claim_from_partial=$(ts 20)   # 옛 claim (머지 2분 전보다 이르다)
STUB_TIMELINE_RC=1 run "$branch_prs" "$old_claim_from_partial" "$sweep_prs"
unset STUB_TIMELINE_RC
check "⑨ 부분 페이지네이션: 그 값을 안 쓰고 fail-closed" \
  "$(grep -q 'fail-closed' "$tmp/err" && echo ok || echo no)"
check "⑨ 부분 페이지네이션: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"

# ── ⑩ 보류 목록 임시파일을 못 만들면 아예 중단한다(스윕 차단 무력화 방지) ────
rm -rf "$tmp/run"; mkdir -p "$tmp/run/.loop"; echo owner/repo > "$tmp/run/.loop/repos"
: > "$tmp/destroy.log"; : > "$tmp/gh.log"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mktemp"; chmod +x "$tmp/bin/mktemp"
rc=0
( cd "$tmp/run" && \
  STUB_BRANCH_PRS="$branch_prs" STUB_CLAIMED_AT="$now" STUB_SWEEP_PRS="$sweep_prs" \
  STUB_CLAIMED="$default_claimed" \
  STUB_DESTROY_LOG="$tmp/destroy.log" STUB_GH_LOG="$tmp/gh.log" \
  PATH="$tmp/bin:$PATH" bash "$sut_dir/reconcile.sh" ) > "$tmp/events" 2> "$tmp/err" || rc=$?
check "⑩ mktemp 실패: 비0 종료" "$([ "$rc" != 0 ] && echo ok || echo no)"
check "⑩ mktemp 실패: 정리 미실행" "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "⑩ mktemp 실패: stderr 에 사유" \
  "$(grep -q '보류 목록 임시파일' "$tmp/err" && echo ok || echo no)"
rm -f "$tmp/bin/mktemp"

# ── ⑪ 같은 초 + worktree 생존 → 조용한 working 이 아니라 warn(사람 확인) ────
# 매 실행 같은 판정이 반복돼 주 루프도 스윕도 못 건드리는 상태다. 묻히면 안 된다.
mkdir -p "$tmp/proj/repo/.claude/worktrees/issue-42"
run "$same_second" "$now" '[]'
check "⑪ 같은 초 + worktree 생존: warn 발행" \
  "$([ "$(event_has warn)" = yes ] && echo ok || echo no)"
check "⑪ 같은 초 + worktree 생존: 조용한 working 아님" \
  "$([ "$(event_has working)" = no ] && echo ok || echo no)"
check "⑪ 같은 초 + worktree 생존: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
rm -rf "$tmp/proj/repo/.claude"

# ── ⑫ 축 1 — fail-closed 는 **머지 후보만** 삼킨다, 이슈 전체가 아니다 (#141) ──
# 브랜치 재사용이면 옛 MERGED PR 과 현재 OPEN PR 이 함께 잡힌다. 타임라인 조회가
# 지속 실패할 때 `continue` 로 이슈를 통째로 버리면 안전한 pr_open·harvesting 분류까지
# 안 나와 현재 PR 이 Maintain 에 못 들어가고 무기한 정체한다.
# 전제: worktree 부재. 앞 블록의 정리에 기대지 않고 여기서 명시한다 — 사이에 케이스가
# 끼면 조용히 전제가 뒤집혀 다른 세계를 재는 테스트가 된다(사전 리뷰 NIT).
rm -rf "$tmp/proj/repo/.claude"
mixed_prs='[{"number":7,"state":"MERGED","mergedAt":"'$merged_recent'","statusCheckRollup":[],"labels":[]},
            {"number":8,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"labels":[]}]'
run "$mixed_prs" "" "$sweep_prs"
check "⑫ 타임라인 실패 + 옛 머지 + 현재 OPEN: pr_open 발행(분류는 계속된다)" \
  "$([ "$(event_has pr_open)" = yes ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + 옛 머지 + 현재 OPEN: merged 미발행" \
  "$([ "$(event_has merged)" = no ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + 옛 머지 + 현재 OPEN: 정리 미실행(주 루프·스윕 모두)" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "⑫ 타임라인 실패: 그 머지 PR 은 보류일 뿐 영속 레저에 안 굳는다" \
  "$([ "$(seen 'owner/repo#7')" = no ] && echo ok || echo no)"
# harvesting(closeout 점유)도 같은 안전 분류다 — 이것도 살아나야 한다.
mixed_harvest='[{"number":7,"state":"MERGED","mergedAt":"'$merged_recent'","statusCheckRollup":[],"labels":[]},
                {"number":8,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"labels":[{"name":"harvesting"}]}]'
run "$mixed_harvest" "" "$sweep_prs"
check "⑫ 타임라인 실패 + harvesting OPEN: harvesting 발행" \
  "$([ "$(event_has harvesting)" = yes ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + harvesting OPEN: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
# 과교정 반대편 가드 (#141): 머지 아닌 PR 이 **하나도 없으면** 예전처럼 이슈를 통째로
# 건너뛴다. 여기서 stale 로 흘려 agent:claimed 를 떼면, 그 머지는 이번 실행 보류(스윕
# 차단)와 겹쳐 "라벨 제거 + 스윕 차단" = 영구 유실 조합이 된다.
run "$branch_prs" "" "$sweep_prs"
check "⑫ 타임라인 실패 + 머지 PR 뿐: stale 미발행" \
  "$([ "$(event_has stale)" = no ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + 머지 PR 뿐: agent:claimed 미제거(유실 조합 금지)" \
  "$([ "$(claim_removed)" = no ] && echo ok || echo no)"

# fail-closed 에서 남기는 건 **OPEN 뿐**이다 — CLOSED 분기는 pr_open 과 달리 worktree
# 제거 + agent-ready 해제라는 정리를 하는데, 브랜치 재사용이면 그 CLOSED 도 옛 attempt 의
# 것일 수 있고 claim 시각을 모르면 가를 수 없다(#139 가 막은 파괴의 CLOSED 판, 사전 리뷰 WARN).
mixed_closed='[{"number":7,"state":"MERGED","mergedAt":"'$merged_recent'","statusCheckRollup":[],"labels":[]},
               {"number":8,"state":"CLOSED","mergedAt":null,"statusCheckRollup":[],"labels":[]}]'
run "$mixed_closed" "" "$sweep_prs"
check "⑫ 타임라인 실패 + 옛 CLOSED PR: rejected 미발행" \
  "$([ "$(event_has rejected)" = no ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + 옛 CLOSED PR: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"
check "⑫ 타임라인 실패 + 옛 CLOSED PR: agent:claimed 미제거" \
  "$([ "$(claim_removed)" = no ] && echo ok || echo no)"

# ── ⑬ 축 2 — 동률 머지 + worktree 부재도 warn (라벨 유지) (#141) ─────────────
# 전제: worktree 부재(위 ⑫ 에서 명시 제거했고 그 사이 다시 만들지 않는다).
# 종전엔 동률 경고가 `[ -d "$wt" ]` **안**에만 있어, worktree 가 이미 없으면 else 로 빠져
# agent:claimed 를 stale 로 떼면서 그 머지는 보류 목록이 스윕을 막았다 → 다음 실행엔
# 라벨이 없어 주 루프도 못 보고, cutoff 30분을 넘기면 스윕은 씨딩만 하고 지나간다(영구 유실).
run "$same_second" "$now" '[]'
check "⑬ 동률 + worktree 부재: warn 발행" \
  "$([ "$(event_has warn)" = yes ] && echo ok || echo no)"
check "⑬ 동률 + worktree 부재: stale 미발행" \
  "$([ "$(event_has stale)" = no ] && echo ok || echo no)"
check "⑬ 동률 + worktree 부재: agent:claimed 미제거(다음 실행이 재판정)" \
  "$([ "$(claim_removed)" = no ] && echo ok || echo no)"
check "⑬ 동률 + worktree 부재: 정리 미실행" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"

# ── ⑧ 회수 경로 — 미룬 판단이 영구 유실되지 않는다 (리뷰 BLOCKER 가드) ──────
# ① 과 같은 상태(타임라인 실패로 보류)에서, 다음 실행에 agent:claimed 가 이미 떨어져
# 주 루프가 그 이슈를 못 보는 상황을 만든다. 보류를 영속 레저에 굳혔다면 스윕도 건너뛰어
# 정상 머지가 영영 유실된다 — 여기서는 스윕이 회수해야 한다.
run "$branch_prs" "" "$sweep_prs"                    # 1회차: 보류
rerun '[]' "" "$sweep_prs" '[]'                      # 2회차: 라벨 소멸(claimed 없음)
check "⑧ 회수: 다음 실행의 스윕이 머지를 발행" \
  "$([ "$(event_has merged)" = yes ] && echo ok || echo no)"
check "⑧ 회수: 정리도 수행" \
  "$([ "$(destroyed)" = yes ] && echo ok || echo no)"

# ── ⑭ 반쯤 이동한 verify-redispatch 회수 (#394) ──────────────────────────────
# `transition.sh verify-redispatch` 의 이슈 편집이 실패하면 PR 은 단계 라벨을 잃고 이슈는
# `agent:claimed` 를 유지한다 — 세 게이트 전부 제외라 아무도 안 집는다. 형상이 확정될 때만
# `half_moved_redispatch` 를 내고(전이는 SKILL ① 이 건다), 확정 못 하면 **종전대로**
# `pr_open` 이다. 축을 하나씩 움직여 각 술어가 실제로 물리는지 본다.
rm -rf "$tmp/proj/repo/.claude"
hm_old=$(ts 120)      # 진행 증거 없음(커밋 120분·claim 타임박스 밖)
hm_new=$(ts 5)        # claim 5분 전 = 살아 있는 회차
hm_open='[{"number":8,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"labels":[]}]'
hm_open_verify='[{"number":8,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"labels":[{"name":"flow:verify"}]}]'
hm_open_ready='[{"number":8,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"labels":[{"name":"flow:agent-ready"}]}]'
hm_bounced='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-01-01T00:00:00Z"},
             {"body":"재검증 실패: #42 — E2E 3건 빨강 <!-- bodat:worker -->","createdAt":"2026-01-02T00:00:00Z"}]'
hm_verdict='[{"body":"재검증 실패: #42 — E2E 3건 빨강","createdAt":"2026-01-01T00:00:00Z"},
             {"body":"머지 판정: ✅ 통과","createdAt":"2026-01-02T00:00:00Z"}]'
hm_run() {  # hm_run <코멘트JSON> <head_raw> <claim_at> <branch_prs>
  STUB_PR_COMMENTS="$1" STUB_HEAD_RAW="$2" STUB_CLAIM_AT="$3" run "$4" "" '[]'
}

hm_run "$hm_bounced" "abc123 $hm_old" "$hm_old" "$hm_open"
check "⑭ 반쯤 이동 형상: half_moved_redispatch 발행" \
  "$([ "$(event_has half_moved_redispatch)" = yes ] && echo ok || echo no)"
check "⑭ 반쯤 이동 형상: 이슈·PR 번호가 실린다" \
  "$(jq -e 'select(.event=="half_moved_redispatch") | .number == 42 and .pr == 8' < "$tmp/events" >/dev/null 2>&1 && echo ok || echo no)"
check "⑭ 반쯤 이동 형상: pr_open 은 안 낸다(② Maintain 제외)" \
  "$([ "$(event_has pr_open)" = no ] && echo ok || echo no)"
check "⑭ 반쯤 이동 형상: 정리(worktree·라벨) 미실행 — 이벤트만" \
  "$([ "$(destroyed)" = no ] && echo ok || echo no)"

hm_run "$hm_bounced" "abc123 $hm_old" "$hm_old" "$hm_open_ready"
check "⑭ PR 에 flow:agent-ready 만 남음(#281 뒤 반송 전이의 실제 잔여 형상): 이벤트 발행" \
  "$([ "$(event_has half_moved_redispatch)" = yes ] && echo ok || echo no)"

hm_run "$hm_bounced" "abc123 $hm_old" "$hm_old" "$hm_open_verify"
check "⑭ 단계 라벨(flow:verify) 있음: 이벤트 없음 · pr_open(종전 동작)" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && [ "$(event_has pr_open)" = yes ] && echo ok || echo no)"

hm_run "$hm_bounced" "abc123 $hm_old" "$hm_new" "$hm_open"
check "⑭ 진행 증거 있음(claim 5분 전): 이벤트 없음 — 살아있는 워커 무접촉" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && [ "$(event_has pr_open)" = yes ] && echo ok || echo no)"

hm_run "$hm_verdict" "abc123 $hm_old" "$hm_old" "$hm_open"
check "⑭ 마지막 판정이 ✅: 반송 형상이 아니다 — 이벤트 없음" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && echo ok || echo no)"

hm_run "" "abc123 $hm_old" "$hm_old" "$hm_open"
check "⑭ 코멘트 조회 실패: 증명 못 하면 종전 동작(pr_open)" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && [ "$(event_has pr_open)" = yes ] && echo ok || echo no)"

hm_run "$hm_bounced" "" "$hm_old" "$hm_open"
check "⑭ head 조회 실패: 증명 못 하면 종전 동작(pr_open)" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && [ "$(event_has pr_open)" = yes ] && echo ok || echo no)"

hm_run "$hm_bounced" "abc123 $hm_old" "" "$hm_open"
check "⑭ claim 조회 실패: 증명 못 하면 종전 동작(pr_open)" \
  "$([ "$(event_has half_moved_redispatch)" = no ] && [ "$(event_has pr_open)" = yes ] && echo ok || echo no)"

# ── ⑦ gh-login.sh 순차 폴백 — REST 성공이면 GraphQL 을 호출하지 않는다 ───────
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
case "$*" in
  "api user"*)    [ -n "$STUB_REST_OK" ] || exit 1; echo tester ;;
  "api graphql"*) echo tester ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
out=$(STUB_REST_OK=1 STUB_GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" bash "$DIR/gh-login.sh")
check "⑦ REST 성공: 로그인명 반환" "$([ "$out" = tester ] && echo ok || echo no)"
check "⑦ REST 성공: GraphQL 미호출" \
  "$(grep -q 'api graphql' "$tmp/gh.log" && echo no || echo ok)"
: > "$tmp/gh.log"
out=$(STUB_REST_OK="" STUB_GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" bash "$DIR/gh-login.sh")
check "⑦ REST 실패: GraphQL 폴백으로 로그인명 반환" \
  "$([ "$out" = tester ] && grep -q 'api graphql' "$tmp/gh.log" && echo ok || echo no)"
# 둘 다 실패 → 출력 없이 exit 1 (호출자가 fail-loud 로 종료)
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$tmp/bin/gh"
rc=0
out=$(PATH="$tmp/bin:$PATH" bash "$DIR/gh-login.sh" 2>/dev/null) || rc=$?
check "⑦ 둘 다 실패: exit 1 · 빈 출력" \
  "$([ "$rc" = 1 ] && [ -z "$out" ] && echo ok || echo no)"

echo "reconcile: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
