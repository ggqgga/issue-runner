#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + ¬needs-human + 모든 "Blocked by #N" 라인의 N이 CLOSED
# 정렬: P0 > P1 > P2 > 없음, 동순위는 오래된 순.
# 주의: search API는 인덱스 지연이 있다 — 최종 재확인은 claim-issue.sh가 직접 API로 한다.
set -euo pipefail

me=$(gh api user -q .login)

# 세션 레포 스코프 (#40): 실행 cwd 의 .loop/repos 가 있으면 그 목록(owner/repo,
# 줄당 하나, # 주석·빈 줄 허용)의 레포만 처리한다. 없으면 계정 전체(기존 동작).
scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

# needs-human 은 서버 쿼리에서도 제외 — 클라이언트 필터만 쓰면 needs-human 이슈가
# per_page=50 창을 채워 실제 eligible 이슈가 밀려날 수 있다
# 주의: gh search CLI 사용 금지 — 쿼리 문자열 내 부정 라벨(`label:X -label:Y`)을
# 라벨명 하나("X -label:Y")로 오파싱해 항상 0건이 된다 (이슈 #21, GH_DEBUG=api 실측).
# REST search/issues 직접 호출만 정상 동작. 출력은 기존 gh search --json 형태와
# 동일하게 변환해 이후 파이프라인(repository.nameWithOwner/labels[].name/createdAt) 무수정.
cands=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:issue label:agent-ready -label:needs-human" \
  -f per_page=50 \
  -q '[.items[] | {repository: {nameWithOwner: (.repository_url | sub(".*/repos/"; ""))}, number, title, labels: [.labels[] | {name}], createdAt: .created_at}]')

out="[]"
count=$(printf '%s' "$cands" | jq 'length')
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$cands" | jq -c ".[$i]")
  i=$((i + 1))
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')
  labels=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")')

  # 세션 레포 스코프 밖이면 제외 (#40)
  in_scope "$repo" || continue

  # 이미 claim 된 것 제외
  case ",$labels," in *",agent:claimed,"*) continue ;; esac

  # 사람 개입 대기(needs-human) 제외 — 사람이 라벨을 떼기 전에는 재디스패치 금지
  case ",$labels," in *",needs-human,"*) continue ;; esac

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
