#!/usr/bin/env bash
# claim 된 이슈 전수 점검. 이벤트를 JSON lines 로 출력하고 안전 정리를 수행.
# 이벤트:
#   merged   — PR 머지됨 → worktree 제거 + 라벨 해제(release-labels.sh).
#              ★이슈가 자동으로 닫힌다고 가정하지 않는다★ — 일부만 착지한 PR 은 closeout
#              규약상 `Closes` 대신 `Refs` 를 써서 트래커를 살려 둔다. 그 경우 이슈는
#              OPEN 으로 남고 agent-ready 도 유지돼야 다음 틱이 남은 절반을 집는다(#117).
#   rejected — PR 이 머지 없이 닫힘 → 정리 + agent-ready 도 제거 (자동 재시도 금지)
#   pr_open  — PR 열려 있음 (failing 카운트 포함 → Maintain 단계 입력)
#   harvesting — closeout 가 점유한 OPEN PR (harvesting 라벨) → Maintain 제외, 건드리지 않음
#   working  — PR 없고 worktree 있음 → 워커 진행 중으로 간주
#   stale    — PR 없고 worktree 도 없음 → 죽은 claim 해제
#   warn     — dirty/unpushed worktree → 제거 보류, 사람 확인 필요
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 사용자 확인은 공유 헬퍼(gh-login.sh)로 일원화 (#131) — REST /user 503 부분 장애
# 폴백·형식 검증·3회 재시도는 그 안에 있고, REST 가 성공하면 GraphQL 은 호출하지
# 않는다(종전 `for _cand in "$(…)" "$(…)"` 는 단어 전개 탓에 매번 둘 다 호출했다).
# 실패는 조용히 넘기지 않고 즉시 종료한다(fail-loud) — me 오염은 빈 큐와 구분이 안 된다.
me=$("$SCRIPT_DIR/gh-login.sh") || me=""
if [ -z "$me" ]; then
  echo "reconcile: GitHub 사용자 확인 실패 (REST /user·GraphQL viewer 모두 응답 없음)" >&2
  exit 1
fi

# 세션 레포 스코프 (#40): 실행 cwd 의 .loop/repos 가 있으면 그 목록(owner/repo,
# 줄당 하나, # 주석·빈 줄 허용)의 레포만 점검한다. 없으면 계정 전체(기존 동작).
# eligible-issues.sh 와 일관 적용 — 다른 세션 워커의 claim 에 불간섭.
scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

# 머지 감지 레저 (아래 ②-보강 스윕이 소비). 아래 agent:claimed 루프는 issue 가 그
# 라벨을 유지할 때만 머지를 본다 — closeout·verify-runner·미러가 머지 시점에
# tracking 라벨(agent:claimed·flow:*)을 떼면 그 머지를 놓친다. 머지는 PR state=MERGED
# 라는 영구 사실이므로, 라벨과 무관하게 최근 머지된 agent PR 을 직접 훑어 아직 안 낸
# 것만 낸다. seen_file 로 중복 방지. cutoff(30분) 는 최초 설치 시 오래된 머지를
# 무더기로 재발행하지 않게 하는 유예창 — 그 이전 머지는 조용히 seen 으로 씨딩한다.
seen_file="$PWD/.loop/seen-merges"
[ -f "$seen_file" ] || : > "$seen_file"
cutoff=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "0000")

# 주의: --state 미지정 = open+closed 모두 (merged PR 이 이슈를 자동으로 닫으므로 필수)
# GitHub 부분 장애(간헐 503)에서 이 조회가 실패하면 빈 결과가 되어 "claim 된 이슈 없음"
# 과 구분이 안 된다 — 스테일 claim 정리·머지 감지가 조용히 통째로 스킵된다(fail-open).
# 재시도하고, 그래도 실패하면 조용히 넘기지 말고 종료한다(fail-loud).
claimed=""
for _try in 1 2 3; do
  if claimed=$(gh search issues "label:agent:claimed" --owner "$me" \
                 --json repository,number --limit 100 2>/dev/null) \
     && printf '%s' "$claimed" | jq -e 'type == "array"' >/dev/null 2>&1; then
    break
  fi
  claimed=""
  sleep 3
done
if [ -z "$claimed" ]; then
  echo "reconcile 중단: agent:claimed 조회 실패 — 빈 결과와 구분 불가라 정리를 건너뛴다" >&2
  exit 1
fi

printf '%s' "$claimed" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')

  # 세션 레포 스코프 밖이면 불간섭 (#40)
  in_scope "$repo" || continue
  dir=$("$SCRIPT_DIR/repo-dir.sh" "$repo")
  branch="agent/issue-$num"
  wt="$dir/.claude/worktrees/issue-$num"

  # 안전 제거는 공유 헬퍼(cleanup-worktree.sh)로 일원화 (#62). 동작 불변:
  # --merged 안 넘기므로 기존 더티/미push 가드·warn JSON·반환코드가 그대로다.
  safe_remove_worktree() {
    "$SCRIPT_DIR/cleanup-worktree.sh" "$repo" "$num"
  }

  prs=$(gh pr list --repo "$repo" --head "$branch" --state all \
    --json number,state,mergedAt,statusCheckRollup,labels --limit 20 2>/dev/null || true)
  printf '%s' "$prs" | jq -e 'type=="array"' >/dev/null 2>&1 || prs='[]'

  # 브랜치 이름이 이슈 번호에서 나오므로(agent/issue-<N>) 이슈를 **다시 집으면 이전
  # attempt 가 남긴 머지 PR 이 그대로 잡힌다**. 거르지 않으면 살아있는 워커의 worktree·
  # claim 이 false merged 로 지워진다 (2026-08-16 #3447 실측: 라벨 부착 → 다음 틱 파괴가
  # 3회 반복됐고 1회는 미push 작업이 유실됐다).
  # 판별선은 "이 브랜치에 머지된 PR 이 있나" 가 아니라 "**이번 claim** 이 머지로 끝났나"
  # 다 — mergedAt 이 현재 claim 시각보다 이르면 그 머지는 옛 이력이다. 브랜치 존재
  # 여부로는 못 가른다(정상 머지 후에도 브랜치가 지워져 둘이 같은 모습이 된다).
  if printf '%s' "$prs" | jq -e 'any(.[]; .state=="MERGED")' >/dev/null 2>&1; then
    # grep 으로 형태를 검증한다 — `gh api -q` 는 실패 응답의 에러 JSON 을 stdout 으로
    # 흘리고(claim-issue.sh 와 같은 함정), --paginate 는 페이지마다 값을 한 줄씩 낸다.
    claimed_at=$(gh api "repos/$repo/issues/$num/timeline?per_page=100" --paginate \
      --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed") | .created_at] | last // empty' \
      2>/dev/null | grep -E '^[0-9]{4}-' | tail -n1 || true)
    if [ -n "$claimed_at" ]; then
      # 동률(`<=`)은 **이전 attempt** 로 본다 (#131): mergedAt·timeline created_at 은 초
      # 단위라, 이전 PR 이 머지된 바로 그 초에 재claim 되면 두 값이 같아진다. `<` 면 그
      # 옛 MERGED PR 이 남아 새 claim 을 완료로 오인한다.
      keep=$(printf '%s' "$prs" | jq -c --arg c "$claimed_at" \
        '[.[] | select((.state == "MERGED" and (.mergedAt // "") <= $c) | not)]')
      # 걸러낸 옛 머지 PR 은 ②-보강 스윕이 다시 주워 같은 파괴를 하지 않도록 레저에
      # 미리 기록한다 (#131) — 스윕은 seen_file 에 있는 키를 건너뛴다.
      printf '%s' "$prs" | jq -r --arg c "$claimed_at" \
        '.[] | select(.state == "MERGED" and (.mergedAt // "") <= $c) | .number' \
        | while IFS= read -r _old; do
            [ -n "$_old" ] || continue
            grep -qxF "$repo#$_old" "$seen_file" 2>/dev/null || printf '%s\n' "$repo#$_old" >> "$seen_file"
          done
      prs="$keep"
    else
      # fail-closed (#131): 타임라인 조회 실패(rate limit·권한·일시 오류)나 라벨 이벤트
      # 부재로 claim 시각을 못 얻으면 **정리를 하지 않는다**. 종전엔 필터가 통째로
      # 건너뛰어져 이전 attempt 의 머지 PR 이 현재 claim 의 PR 로 취급됐고, 살아있는
      # 워커의 worktree·agent:claimed 가 지워졌다(#3447 재발 경로).
      echo "reconcile: $repo#$num claim 시각 확인 실패 — 재claim 필터 불가로 정리를 건너뛴다(fail-closed)" >&2
      # 스윕도 같은 PR 을 주워 정리하지 않도록 이번 실행 한정으로 레저에 기록한다.
      printf '%s' "$prs" | jq -r '.[] | select(.state == "MERGED") | .number' \
        | while IFS= read -r _old; do
            [ -n "$_old" ] || continue
            grep -qxF "$repo#$_old" "$seen_file" 2>/dev/null || printf '%s\n' "$repo#$_old" >> "$seen_file"
          done
      continue
    fi
  fi

  pr=$(printf '%s' "$prs" | jq -c '.[0] // empty')

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
        # 라벨 해제는 스윕과 **같은 규칙**을 쓴다(#117) — 이슈가 아직 OPEN(Refs 부분착지)이면
        # agent-ready 를 남긴다. 종전엔 이 분기와 스윕이 서로 다른 목록을 떼어 갈렸다.
        "$SCRIPT_DIR/release-labels.sh" "$repo" "$num"
        printf '%s\n' "$repo#$prnum" >> "$seen_file"  # 아래 스윕이 이 머지를 중복 발행하지 않게
        printf '{"event":"merged","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    CLOSED)
      if safe_remove_worktree; then
        gh issue edit "$num" --repo "$repo" \
          --remove-label "agent:claimed" --remove-label "agent-ready" >/dev/null 2>&1 || true
        printf '{"event":"rejected","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    OPEN)
      # closeout 가 점유한 PR(harvesting 라벨)은 ② Maintain 입력에서 제외 (#44).
      # 머지/닫힘 PR 은 위 MERGED/CLOSED 분기에서 정상 정리되므로 OPEN 만 가른다.
      if printf '%s' "$pr" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null; then
        printf '{"event":"harvesting","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
        continue
      fi
      failing=$(printf '%s' "$pr" | jq '[.statusCheckRollup[]?
        | select((.conclusion // .state // "")
          | test("FAILURE|ERROR|CANCELLED|TIMED_OUT"))] | length')
      printf '{"event":"pr_open","repo":"%s","number":%s,"pr":%s,"failing":%s}\n' \
        "$repo" "$num" "$prnum" "$failing" ;;
  esac
done

# ── ② 머지 감지 보강 스윕 (라벨 경합 무관) ──────────────────────────
# 스코프 레포마다 최근 머지된 agent/issue-* PR 을 훑어, seen_file 에 없고 cutoff 이후에
# 머지된 것만 merged 이벤트로 낸다(위 루프가 라벨 소멸로 놓친 머지 회수). cutoff 이전
# 머지는 조용히 씨딩(최초 설치 무더기 재발행 방지). 정리는 idempotent(closeout 가 이미
# 했을 수 있음) — best-effort.
sweep_repos() {
  if [ -f "$scope_file" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t'
  else
    gh search issues "label:agent-ready" --owner "$me" --json repository \
      -q '.[].repository.nameWithOwner' 2>/dev/null | sort -u
  fi
}
sweep_repos | while IFS= read -r srepo; do
  [ -n "$srepo" ] || continue
  gh pr list --repo "$srepo" --state merged --search "head:agent/issue" \
    --json number,headRefName,mergedAt --limit 30 2>/dev/null \
    | jq -r '.[] | [ (.number|tostring), .headRefName, .mergedAt ] | @tsv' \
    | while IFS=$'\t' read -r spr shead smerged; do
        case "$shead" in agent/issue-*) ;; *) continue ;; esac
        snum=${shead#agent/issue-}
        key="$srepo#$spr"
        grep -qxF "$key" "$seen_file" 2>/dev/null && continue
        printf '%s\n' "$key" >> "$seen_file"
        # cutoff 이전 머지는 씨딩만(재발행 금지). 이후(최근) 머지만 발행.
        [[ "$smerged" > "$cutoff" ]] || continue
        "$SCRIPT_DIR/cleanup-worktree.sh" "$srepo" "$snum" >/dev/null 2>&1 || true
        # 위 MERGED 분기와 **같은 헬퍼**(#117) — 이슈가 OPEN 이면 agent-ready 를 남긴다.
        # 종전엔 여기서 무조건 떼어, `Refs` 로 일부만 착지시킨 이슈가 조용히 좌초했다.
        "$SCRIPT_DIR/release-labels.sh" "$srepo" "$snum"
        printf '{"event":"merged","repo":"%s","number":%s,"pr":%s}\n' "$srepo" "$snum" "$spr"
      done
done

# 레저 프루닝 — 최근 500 유지 (context/파일 비대 방지)
if [ -s "$seen_file" ]; then
  tail -n 500 "$seen_file" > "$seen_file.tmp" 2>/dev/null && mv "$seen_file.tmp" "$seen_file"
fi
