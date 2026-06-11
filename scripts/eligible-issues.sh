#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + ¬needs-human + 모든 "Blocked by #N" 라인의 N이 CLOSED
# 정렬: P0 > P1 > P2 > 없음, 동순위는 오래된 순.
# 주의: gh search는 인덱스 지연이 있다 — 최종 재확인은 claim-issue.sh가 직접 API로 한다.
set -euo pipefail

me=$(gh api user -q .login)

# needs-human 은 서버 쿼리에서도 제외 — 클라이언트 필터만 쓰면 needs-human 이슈가
# --limit 50 창을 채워 실제 eligible 이슈가 밀려날 수 있다
cands=$(gh search issues "label:agent-ready -label:needs-human" --owner "$me" --state open \
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
