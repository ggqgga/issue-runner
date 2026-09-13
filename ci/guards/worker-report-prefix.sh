#!/usr/bin/env bash
# 워커 반송 해소 보고 접두 가드 — bin/ci 인라인의 「[worker] 반송 해소 보고 접두가
# 마커 집합 밖인지」 블록을 통째로 옮긴 것 (분류표 Plans/ci-guard-classification.md
# L6 절 대상 행 17, #251 ②).
#
# 무엇을 무는가 — 문서(한/영 워커 템플릿)에서 접두 리터럴을 **뽑아** 판정기
# (scripts/bounce-state.sh)에 먹이는 결합 검사다. 문서와 판정기가 갈리면
# 아무도 반송하지 않은 PR 이 마감 후보에서 조용히 빠진다.
#
# 실패 시 — ⑴ 접두 지시문을 못 찾았거나 ⑵ 한/영 중 한쪽에 규정이 없거나
# ⑶ 그 접두로 시작한 보고를 판정기가 `ok` 로 안 읽으면, 어느 축인지와 판정값을
# 찍고 exit 1 (임시 디렉터리는 지우고 나간다).
#
# 만료 조건: 반송 판정이 접두가 아니라 구조 필드(보고 JSON 의 명시 필드)로 바뀌면
# 지운다 — 그때는 문서 문안이 판정에 안 쓰인다. (#541 에서 적음 — 원 블록엔 없었다.)
set -euo pipefail
cd "$(dirname "$0")/../.."

# #251 ② 는 판정기가 아니라 **문안**으로 닫혔다: 워커의 반송 해소 보고가 반송 마커로
# 시작하면 안전망이 그걸 반송으로 읽어, 아무도 반송하지 않은 PR 이 마감 후보에서 빠진다.
# 그 경계를 어휘(`완료`·`해소`)로 판정기 안에서 가르려던 판본은 조사·부정 어미·과거
# 인용에서 **진짜 반송을 `ok` 로 흘려**(main 대조 실측 7형태) 되돌렸다.
# 그래서 계약은 "보고는 마커 밖 접두로 시작한다" 한 줄이고, 여기서 두 가지를 문다:
#   ⑴ 한/영 템플릿 **둘 다** 그 접두를 규정한다(한쪽만 고치면 영문 워커가 옛 문안을 쓴다)
#   ⑵ 그 접두로 시작하는 실제 보고 한 줄이 `bounce-state.sh` 에서 **`ok`** 로 떨어진다
#      — 접두 리터럴을 이 검사에 **한 글자도 베껴 쓰지 않고** 한글 템플릿의 지시문에서
#      뽑아 먹인다(접두를 바꾸면 검사가 자동으로 따라간다). 마커 집합이 늘어 접두와
#      겹치는 날(예 마커에 `반송` 을 추가) 이 검사가 즉시 빨개진다.
wt_prefix=$(sed -n 's/.*\*\*`\([^`]*\)`\*\* *접두로 시작하라.*/\1/p' references/worker-template.md | head -1)
[ -n "$wt_prefix" ] \
  || { echo "  ✗ references/worker-template.md 에서 반송 해소 보고 접두 지시문을 못 찾았다(**\`접두\`** 접두로 시작하라 형태 필요)"; exit 1; }
for f in references/worker-template.md references/worker-template.en.md; do
  grep -qF "\`$wt_prefix\`" "$f" \
    || { echo "  ✗ $f 에 반송 해소 보고 접두('$wt_prefix') 규정이 없다 — 한/영 중 한쪽만 고치면 옛 문안이 살아남는다"; exit 1; }
done
tmp=$(mktemp -d); mkdir "$tmp/nogh"
printf '#!/bin/sh\nexit 1\n' > "$tmp/nogh/gh"; chmod +x "$tmp/nogh/gh"
jq -n --arg b "$wt_prefix: 마감 검증 BLOCKER(계획 부합) 해소 — 재푸시·로컬 CI pass" '[
  {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-01-01T00:00:00Z"},
  {body:$b, createdAt:"2026-01-01T00:00:01Z"}]' > "$tmp/report.json" \
  || { echo "  ✗ 보고 문안 판정 입력을 만들지 못했다"; rm -rf "$tmp"; exit 1; }
state=$(PATH="$tmp/nogh:$PATH" BOUNCE_COMMENTS_FILE="$tmp/report.json" \
  scripts/bounce-state.sh owner/r 1) || state=""
[ "$state" = ok ] \
  || { echo "  ✗ 반송 해소 보고 문안('$wt_prefix …')을 bounce-state.sh 가 반송으로 읽는다(판정=[$state]) — 접두가 마커 집합 안이다"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"
