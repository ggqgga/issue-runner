#!/usr/bin/env bash
# pr-hold-released-at.sh <repo> <pr>
#
# 사람이 이 PR 의 **사람 몫 보류 사유를 뗀 가장 최근 시각**을 ISO8601(`...Z`) 로 stdout 에
# 낸다 = 타임라인의 `unlabeled` 이벤트 중 라벨이 `hold:policy`·`hold:conflict` 인 것의 최대
# `created_at`(단, `hold:policy` 는 **기계 재심으로 뗀 것을 제외**한다 — 아래 참조).
#
#   exit 0 + 시각   해제 이벤트를 찾았다
#   exit 0 + 무출력  조회는 성공했고 **해제 이벤트가 없다**(정상 — 아직 안 풀렸다, 또는
#                    있던 해제 전부가 기계 재심이라 사람 해제로 못 세는 경우도 같다)
#   exit 1 + 무출력  조회·파싱 실패 = **모른다**
#
# 빈 결과와 실패를 종료코드로 **구분**한다(PR#168 교훈 — 센티널 하나로 사유를 단정하면
# 원격 장애가 로컬 사실로 둔갑한다). 상류는 둘 다 fail-closed(보류 유지)로 받지만,
# 사유가 종료코드에 남아 있어야 나중에 갈래를 나눌 수 있다.
#
# 왜 필요한가 (#174):
#   closeout 이 `마감 검증: ⚠ 보류` 를 찍고 `closeout-blocked` 전이가 `needs-human`+`hold:*`
#   를 붙이면 그 PR 은 사람 손에 넘어간다. 사람이 판정을 내리고 **라벨을 떼는 행위 자체가
#   신호**인데, 코멘트만 읽는 스크립트는 그걸 못 본다 — 라벨은 풀렸는데 낡은 `⚠ 보류` 가
#   최신 판정 형식 코멘트로 남아 PR 이 closeout 큐에서 사라진다(실측 2026-09-10, BodaT
#   PR #4922·#4917·#4921 세 건 동시 정체). 그 해제 시각을 여기서 읽어 상류가 "이 보류는
#   해소됐다" 를 **증명**할 수 있게 한다.
#
# **`--paginate` 는 필수다.** 타임라인도 기본 30건이라 반송을 여러 번 도는 PR 은 라벨
# 이벤트만으로도 첫 페이지 밖으로 밀린다 — 그러면 해제 이벤트를 못 봐 사람이 푼 보류가
# 영영 안 풀린 것으로 읽힌다(코멘트 100건·커밋 100건 상한과 같은 함정의 세 번째 자리,
# pr-comments.sh·pr-head-at.sh 주석 참조).
#
# 실패를 빈 결과로 둔갑시키지 않는다: `--paginate` 중간 페이지가 실패하면 gh 는 부분
# 출력을 낸 채 비정상 종료한다. 그 부분 출력을 채택하면 "해제 이벤트가 그게 전부" 로
# 읽혀 **더 이른 해제 시각**이 답이 되고, 그 뒤에 달린 보류가 해소된 것처럼 보일 수
# 있다. 그래서 비정상 종료면 출력을 통째로 버리고 exit 1 이다(PR#139 교훈).
#
# ★왜 `needs-human` 도 `hold:*` 전체도 아니고 이 **두 라벨만** 인가★ — 이 값은 "사람이
# 결정을 내렸다" 의 **증명**으로 쓰인다. 그러니 **루프가 스스로 뗄 수 있는 라벨은 셀 수
# 없다**(기계가 뗀 것이 사람 결정으로 둔갑하면 #174 「걸러선 안 되는 것」 1항의 거울상
# fail-open 이다). 실측:
#   · `resume-sweep.sh:159,299` 는 `needs-human` **과** `hold:ladder` 를 **자동으로 뗀다**
#     (사다리 자동 재개). 그래서 그 둘은 사람 신호가 아니다 — `needs-human` 제거만 보면
#     사다리 재개가 곧 "사람이 풀었다" 가 된다.
#   · 같은 스크립트는 사람 몫으로 넘길 때 오히려 `hold:policy` 를 **붙인다**(:173,:260).
#
# ★`hold:policy` 는 또 하나의 기계 경로가 있다 — `policy_review_due` 재심★ (#174 재작업,
# 반송 P1. **이전 주석은 여기서 틀렸다** — "이 두 라벨을 떼는 자동 경로는 반송 전이뿐"
# 이라 적었지만 사실이 아니다.) 루프 SKILL.md `policy_review_due` 절: 디스패처가
# `hold:policy` 로 멈춘 지 오래된 이슈의 질문을 1회 재심해, 답이 플랜·이슈 본문·검증
# 사다리에서 나오면 **루프 스스로** `재심: <답> <!-- policy-review: resumed -->` 코멘트를
# 남기고 `transition.sh verify-redispatch` 로 `needs-human`+`hold:*` 를 뗀다(PR·이슈
# 양쪽 — `verify-redispatch` 의 PR remove 칸에도 `$HOLD_ALL` 이 있다, transition.sh:146).
# **이 경로는 "반송" 이 아니다** — 최신 판정을 `🔄` 로 되돌리는 재검증 절차를 거치지
# 않는다. 그러니 낡은 `머지 판정: ✅`(그 뒤 closeout 이 `마감 검증: ⚠ 보류` 로 가린 것)가
# 그대로 살아 있는 채 `hold:policy` 만 떨어진다 — 이 헬퍼가 그 해제를 사람 해제로 읽으면
# 가려진 ✅ 가 검증 없이 되살아난다(정확히 이 PR 이 없애려던 fail-open).
#
# 그래서 `hold:policy` 의 `unlabeled` 이벤트마다 **기계 재심 여부**를 코멘트로 대조한다
# (`resume-sweep.sh:396-417` 이 이미 쓰는 관용구 — 에피소드 경계는 마지막
# `<!-- hold-note: policy -->` 코멘트). 이 이벤트 이전(이하)의 가장 최근 hold-note 를
# 찾고, 그 hold-note 이후·이 이벤트 이전(이하)에 `<!-- policy-review: resumed -->` 또는
# `<!-- policy-review: kept -->` 마커 코멘트가 있으면 — 기계가 이미 답했다는 뜻이므로 —
# 그 해제는 **후보에서 뺀다**(사람 해제로 세지 않는다). hold-note 를 못 찾으면(레거시·
# 손으로 붙인 홀드) 종전대로 후보로 남긴다 — 증거가 없을 때 과잉 배제하지 않는다.
# `hold:conflict` 는 이런 자동 재심 경로가 없으므로(SKILL.md 어디에도 없다) 거르지
# 않는다 — 과잉 억제 방지.
#
# 마커 코멘트는 이슈·PR **양쪽에 미러**되는 것을 전제로 한다(issue-runner SKILL.md
# `policy_review_due` 절이 그렇게 적혀 있다 — hold-note 가 이미 `transition.sh` 로
# PR·이슈 양쪽에 미러되는 것과 같은 결). 이 헬퍼는 PR 코멘트만 본다(`pr-comments.sh`
# 재사용 — 로직 두 벌 금지, #171 개발계획 2항과 같은 원칙). 마커가 PR 에 없으면(미러
# 누락) 이 가드는 못 걸고 종전대로 새는데, 그건 SKILL 절차 위반이지 이 헬퍼의 계약
# 위반이 아니다.
#
# 반대로 이 좁힘은 **닫는 쪽 오차만** 낸다: 사람이 `needs-human` 만 떼고 사유 라벨을
# 남겨 두면 해제를 못 읽어 종전대로 정체한다(fail-closed). 그리고 `needs-human` 이 아직
# 붙어 있는 PR 은 `closeout-eligible.sh`·①-b 스윕의 **라벨 필터**가 이미 제외한다 —
# "사람 대기 중인가" 는 그 필터가 소유하고, 이 헬퍼는 "사람 몫 사유가 언제 풀렸나(그리고
# 그게 사람이 푼 것인가) 만 답한다(두 신호를 한 값에 겹쳐 담지 않는다).
#
# 범위 메모: 여기서 하는 것은 "언제, 누가 풀렸나" 까지다. **루프가 스스로 `hold:*` 를
# 떼는 경로는 이 스크립트가 만들지 않는다** — 이 헬퍼는 이미 일어난 해제를 *읽고 분류*
# 만 한다(#174 「걸러선 안 되는 것」). 사람 결정문의 *내용* 판정은 스크립트가 아니라
# closeout SKILL ③-1 의 몫이다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

repo=${1:?repo}
pr=${2:?pr_num}

# `issues/<pr>/timeline` 은 PR 에도 그대로 쓴다(GitHub 은 PR 을 이슈로도 노출한다).
raw=$(gh api "repos/$repo/issues/$pr/timeline?per_page=100" --paginate \
  --jq '.[] | select(.event == "unlabeled")
        | select(((.label.name // "") == "hold:policy")
                 or ((.label.name // "") == "hold:conflict"))
        | {label: (.label.name // ""), at: (.created_at // "")}' 2>/dev/null) || exit 1

# 해제 이벤트 0건 = 정상적인 "아직 안 풀렸다". 실패(위 exit 1)와 **구분**해서 exit 0.
[ -n "$raw" ] || exit 0

# ISO8601(`...Z`) 형식만 후보로 남긴다 — 형식이 깨진 값이 그대로 상류의 date 파싱으로
# 새면 GNU date 가 그럴듯한 epoch 를 만들어 낸다(finish-classify 의 iso_to_epoch 형식검사와
# 같은 취지: 입구에서 막는다).
events=$(printf '%s\n' "$raw" | jq -s -c '
  [ .[] | select(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) ]
' 2>/dev/null)
# 해제 이벤트는 있는데(raw 비어있지 않음) 유효 형식이 하나도 없다 = 응답 형상을
# **모른다** → exit 1(파싱 실패도, 유효 항목 0건도 여기서 같이 걸러진다).
{ [ -n "$events" ] && [ "$events" != "null" ] \
  && [ "$(printf '%s' "$events" | jq 'length' 2>/dev/null)" -gt 0 ] ; } 2>/dev/null \
  || exit 1

# PR 코멘트(전량) — 기계 재심 마커 대조용. 조회 실패는 "마커를 못 봤다" 로 떨어뜨려
# **더 보수적인 쪽**(빈 코멘트라 필터링이 아무것도 못 걷어낸다)이 아니라, 코멘트를
# 못 읽었다는 사실 자체가 "기계 재심 여부를 모른다" 는 뜻이므로 이 조회 실패는
# 전체 실패로 승격한다 — 모르는 것을 사람 해제로 통과시키지 않는다(fail-closed).
comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || exit 1

at=$(printf '%s' "$events" | jq -r --argjson comments "$comments" '
  def notes: [$comments[] | select(.body | test("<!--\\s*hold-note:\\s*policy\\s*-->")) | .createdAt];
  def marks: [$comments[] | select(.body | test("<!--\\s*policy-review:\\s*(resumed|kept)\\s*-->")) | .createdAt];
  (notes) as $n | (marks) as $m
  | [ .[] | . as $e | $e.at as $t
      | if $e.label != "hold:policy" then $t
        else
          ( [$n[] | select(. <= $t)] | max ) as $last_note
          | if $last_note == null then $t
            else
              ( [$m[] | select(. >= $last_note and . <= $t)] | length ) as $mc
              | if $mc > 0 then empty else $t end
            end
        end
    ]
  | sort | last // empty
' 2>/dev/null)
# 해제 이벤트가 전부 기계 재심으로 걸러졌다 = 사람 해제를 증명 못 함 → rc0·무출력
# (h3b·사다리 자동재개와 같은 모양 — "조회는 성공했고 사람 해제가 없다").
[ -n "$at" ] || exit 0

printf '%s\n' "$at"
