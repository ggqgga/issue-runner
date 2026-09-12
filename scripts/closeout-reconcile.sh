#!/usr/bin/env bash
# harvesting 라벨 항목 점검 — 크래시 재개·정리. 이벤트 JSON lines.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0
scope_file="$PWD/.loop/repos"
in_scope() { [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"; }

# `hh` = 이 PR 에 `needs-human` 이 붙어 있는가 (#271 WARN). 같은 검색 응답의 labels 를
# 쓰므로 조회 한 번 그대로다. **모양이 어긋나면 true/false 가 아니라 `unknown`** 이다 —
# 아래 OPEN 갈래가 unknown 을 `human_hold`(무접촉)로 받는 fail-closed 를 쓰려면 "라벨이
# 없다" 와 "라벨을 못 읽었다" 를 구분해야 한다(PR#139 교훈).
items=$(gh api -X GET search/issues \
  -f q="user:$me label:harvesting is:pr" -f per_page=50 \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), num:.number,
       hh:(if (.labels|type) == "array"
           then ((([.labels[].name] | index("needs-human")) != null) | tostring)
           else "unknown" end)}]' 2>/dev/null)
[ -n "$items" ] || exit 0

printf '%s' "$items" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo'); num=$(printf '%s' "$row" | jq -r '.num')
  # 필드 **부재**만 `unknown` 이다. `.hh // "unknown"` 이라는 관용구를 쓰지 않는 이유:
  # jq 의 `//` 는 null 뿐 아니라 **false 에도** 걸려, `hh` 가 불리언이면 "needs-human
  # 없음(false)" 이 `unknown` 으로 둔갑해 **모든 OPEN PR 이 무접촉**이 된다(레인이 통째로
  # 멈춘다). 위 `-q` 가 `tostring` 으로 문자열을 내므로 지금 이 순간엔 그 함정이 성립하지
  # 않지만, 읽는 쪽이 표현에 기대지 않도록 `has()` 로 가른다 — `bin/ci` 가 문자열 "false"
  # 와 불리언 false 두 형상을 모두 `resume` 으로 단언해 이 자리를 못 박는다.
  hh=$(printf '%s' "$row" | jq -r 'if has("hh") and .hh != null then .hh else "unknown" end')
  in_scope "$repo" || continue
  state=$(gh pr view "$num" --repo "$repo" --json state -q '.state' 2>/dev/null)
  case "$state" in
    MERGED)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      # 머지 확정 — worktree 도 정리한다 (#62, issue-runner reconcile 의존 제거).
      # 여기서 num 은 PR 번호이므로 worktree 키(이슈번호)는 PR head 에서 파싱한다.
      # best-effort: 더티 등으로 헬퍼가 보류해도 merged_cleanup 이벤트는 낸다.
      branch=$(gh pr view "$num" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null)
      inum="${branch#agent/issue-}"
      [ -n "$branch" ] && [ "$inum" != "$branch" ] \
        && "$SCRIPT_DIR/cleanup-worktree.sh" "$repo" "$inum" --merged || true
      printf '{"event":"merged_cleanup","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    OPEN)
      # 사람 보류 게이트 (#271 WARN · #151 과 같은 방향). `resume` 는 ① Reconcile 의
      # `bounced` 재개 절차로 이어져 `closeout-redispatch` 를 거는데, 그 전이는
      # `needs-human`·`hold:*` 를 **뗀다**. 사람이 조사하려고 방금 붙인 보류가 그렇게
      # 조용히 벗겨진다 — ①-b 가 대상 필터로 명시 배제하는 바로 그 위험이다.
      # 라벨을 **못 읽은 경우(unknown)도 같은 방향**이다: 보류가 없음을 증명하지 못한
      # 상태를 통과로 처리하면 그게 fail-open 이다.
      # 해제 경로: 사람이 `needs-human` 을 떼면 다음 틱에 `resume` 로 돌아온다
      # (`harvesting` 은 그대로 두므로 이 PR 이 레인 밖으로 새지 않는다).
      case "$hh" in
        true)
          printf '{"event":"human_hold","repo":"%s","pr":%s,"why":"needs-human"}\n' "$repo" "$num" ;;
        false)
          printf '{"event":"resume","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
        *)
          printf '{"event":"human_hold","repo":"%s","pr":%s,"why":"라벨 판정 실패"}\n' "$repo" "$num" ;;
      esac ;;
    '')
      # 상태를 **못 읽은** 것(gh 실패·빈 응답)은 CLOSED 가 아니다(#433). 종전엔 빈 값이
      # `그 외` 로 떨어져 `harvesting` 을 떼고 `stale` 을 냈다 — 일시적 API 실패로 살아 있는
      # 마감 PR 이 레인 밖으로 밀리는 fail-open. 위 `hh`(라벨 판정 실패 → human_hold)와 같은
      # 방향으로 무접촉: 다음 틱이 다시 조회한다. 조용히 넘기지 않게 stderr 한 줄.
      echo "warn: closeout-reconcile — PR #$num($repo) 상태 조회 실패, 무접촉(다음 틱 재조회)" >&2
      printf '{"event":"lookup_failed","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    *)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      printf '{"event":"stale","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
  esac
done
