#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + ¬needs-human +
#       모든 블로커가 CLOSED (블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N, OR·dedupe)
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
# sort=created·order=asc — 최종 정렬(sort_by)은 아래서 하지만, 후보가 per_page=50 을
# 넘으면 "어떤 50개가 창에 담기는지"가 정렬 없인 best-match(관련도) 순 = 임의가 되어
# 오래된 이슈가 창 밖으로 밀릴 수 있다. 창 자체를 오래된 순으로 고정한다.
cands=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:issue label:agent-ready -label:needs-human" \
  -f per_page=50 -f sort=created -f order=asc \
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

  # 검증/마감 레인 이슈 제외 (진행 라벨 미러) — 원 이슈에 flow:verify/flow:ready/harvesting
  # 가 미러링돼 있으면 구현이 끝나 다운스트림(verify-runner·closeout) 소유다. agent:claimed
  # 가 스윕에 스트립돼도 이 플로우 라벨이 재디스패치를 막는다(중복 워커 방지 + 이슈 리스트
  # 진행 가시화). 반송은 verify-runner 가 flow:verify 를 떼고 agent-ready 만 남기므로 이
  # 필터에 안 걸려 정상 재디스패치된다.
  case ",$labels," in *",flow:verify,"*|*",flow:ready,"*|*",harvesting,"*) continue ;; esac

  # 블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N (OR·dedupe).
  # 라벨 방식은 이슈 목록에서 블로킹이 한눈에 보이는 게 요점(#85). 새 search 쿼리를
  # 추가하지 않고 이미 받은 labels 배열에서만 파싱한다(gh search 부정라벨 오파싱 #21).
  body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""')
  # -o 로 "blocked by #N" 매치 구간 자체만 뽑는다(매칭 라인 전체가 아니라) — 매칭
  # 라인 전체를 넘겨서 grep -oE로 다시 훑으면 같은 줄 뒤쪽에 문맥상 언급된 무관한
  # #M(예: 참조 PR)까지 블로커로 오인한다(#1457 실측: "Blocked by #1454 — ... #1446(...)"
  # 한 줄에서 #1446까지 집힘). -o 매치 자체는 "Blocked by #1454"로 끊겨 뒤쪽 무관
  # 언급을 애초에 안 본다.
  body_blockers=$(printf '%s' "$body" \
    | grep -oiE '^[[:space:]]*blocked[- ]by[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+$' || true)
  label_blockers=$(printf '%s' "$row" \
    | jq -r '[.labels[].name | select(startswith("blocked-by:")) | ltrimstr("blocked-by:")] | .[]' \
    2>/dev/null || true)
  blockers=$(printf '%s\n%s\n' "$body_blockers" "$label_blockers" \
    | grep -E '^[0-9]+$' | sort -un || true)

  # 하나라도 OPEN 이면 제외. 모두 CLOSED 면 통과(자동 해제 — 라벨을 사람이 뗄 필요 없음).
  # 블로커 조회 실패는 "진짜 미존재"와 "일시 오류(rate-limit·네트워크·auth)"를 구분한다:
  #   - 미존재(GraphQL "Could not resolve to an issue"): 영구 정체 방지 위해 게이트 무시(통과).
  #   - 그 외 오류: 아직 OPEN 인 블로커를 뚫지 않도록 이번 틱은 blocked 유지(다음 틱 재시도).
  # (2>&1 병합: 성공 시 gh_out=상태값, 실패 시 gh_out=에러문. if 조건이라 set -e 안전.)
  blocked=false
  for b in $blockers; do
    if gh_out=$(gh issue view "$b" --repo "$repo" --json state -q '.state' 2>&1); then
      # 블로커가 PR이면 gh issue view도 조회는 되지만 종료 상태가 CLOSED가 아니라
      # MERGED로 나온다(#1457 실측: #1446은 PR, state=MERGED) — MERGED도 종료로 인정.
      case "$gh_out" in
        CLOSED|MERGED) ;;
        *) blocked=true; break ;;
      esac
    elif printf '%s' "$gh_out" | grep -qi 'could not resolve to an issue'; then
      echo "warn: $repo#$num blocked-by #$b 미존재 — 영구 정체 방지 위해 게이트 무시(통과)" >&2
    else
      echo "warn: $repo#$num blocked-by #$b 조회 일시 오류 — 이번 틱 blocked 유지(재시도): $gh_out" >&2
      blocked=true; break
    fi
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
