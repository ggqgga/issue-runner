#!/usr/bin/env bash
# pr-hold-released-at.sh <repo> <pr> [since_at]
#
# 사람 몫 보류(`hold:policy`·`hold:conflict`)를 **사람이** 뗀 시각을 ISO8601(`...Z`) 로
# stdout 에 낸다. `since_at`(ISO8601, 선택) 을 주면 "그 시각 **이후**의 첫 사람 해제"
# (그 보류 에피소드를 닫는 해제)를 낸다 — 생략하면 종전대로 "사람 몫 해제 중 가장 최근
# 것"(호환 유지, 단일 보류 사이클에서는 둘이 같은 값이다).
#
#   exit 0 + 시각   해제 이벤트를 찾았다
#   exit 0 + 무출력  조회는 성공했고 **해제 이벤트가 없다**(아직 안 풀렸다 · 있던 해제
#                    전부가 기계 소행이거나 사유 교체라 사람 해제로 못 세는 경우도 같다 ·
#                    `since_at` 이후로 좁혔을 때 그 구간에 해제가 없는 경우도 같다)
#   exit 1 + 무출력  조회·파싱 실패 = **모른다**
#
# 빈 결과와 실패를 종료코드로 **구분**한다(PR#168 교훈). 상류는 둘 다 fail-closed(보류
# 유지)로 받지만, 사유가 종료코드에 남아야 나중에 갈래를 나눌 수 있다.
#
# ── 왜 "에피소드 키" 인가 (#174 재작업 4회차 — 사람 결정 B, #186 합류) ──────────────
#
# 3라운드가 같은 문제를 겪었다: "이 `unlabeled` 이벤트가 사람이 뗀 것인가?" 를 **라벨
# 이름별로** 판정했더니(정책은 이 규칙, 충돌은 저 규칙…) 매 라운드 새 자동 제거 경로가
# 나왔다 — attempt 1 `policy_review_due` 재심, attempt 2 `kept` 마커 방향 반전,
# attempt 3(반송) `transition.sh` 의 `hold_others()`(사유 교체 시 **다른 두 hold:\* 를
# 같은 호출에서 뗀다** — `verify-held`/`closeout-blocked`/`runner-held` 어디서든, `--reason
# policy` 로 걸면 `hold:conflict`·`hold:ladder` 가 **같은 API 호출·같은 시각에** 떨어진다).
# 라벨 이름을 하나씩 더 걸러내는 방식은 "자동 경로 전수 열거" 를 요구하는데 그 목록이
# 범위가 아니라 **코드가 늘 때마다** 는다 — 그래서 사람 결정으로 접근을 바꿨다: 라벨
# 이름이 아니라 **부착↔제거 짝(에피소드)** 을 구조로 세운다.
#
# 이 파일은 두 규칙을 **순서 없이 독립적으로** 적용한다(하나라도 걸리면 기계로 본다):
#
# ★규칙 1 — 사유 교체(구조적, 라벨명 무관)★
#   `unlabeled(hold:R)` 이벤트가 있는데, **같은 시각**에 `labeled(hold:R')`(R'≠R, 다른
#   사유의 hold:\* 어떤 것이든) 이벤트가 있으면 그건 해제가 아니라 **사유 교체**다 —
#   `hold_others()` 는 사유를 바꿀 때 새 hold:\* 를 붙이면서 나머지를 **같은
#   `gh issue edit` 호출**로 떼므로, 두 이벤트가 GitHub 타임라인에 **같은 초**로
#   찍힌다(같은 API 요청의 결과라 시각 분해능 안에서 갈라지지 않는다). 사람이 라벨
#   하나를 손으로 떼는 동작은 이 짝을 만들지 않는다. 이 규칙은 **라벨 이름을 전혀
#   모른 채** 동작한다 — `hold:ladder` 든, 앞으로 생길 `hold:<새사유>` 든, "같은 시각에
#   다른 hold:\* 가 붙었나" 만 보므로 신설 사유에도 코드 변경 없이 적용된다. 이게
#   codex 반송 4회차가 짚은 `hold:conflict` 축(그리고 그 거울상인 `hold:policy` 축)을
#   라벨 이름 없이 닫는다.
#
# ★규칙 2 — 재심 마커 에피소드(기존 로직의 사유-매개변수화)★
#   `unlabeled(hold:R)` 이벤트 직전의 마지막 `<!-- hold-note: R -->` 코멘트(이번 보류가
#   던진 질문 = 에피소드 경계, `resume-sweep.sh` 와 동형 관용구)를 찾고, 그 hold-note
#   이후·이 해제 이전에 `<!-- R-review: resumed -->` 마커 코멘트가 있으면 — 루프가
#   스스로 답하고 뗀 것이므로 — 후보에서 뺀다. 이 규칙은 **사유(R)로 매개변수화**돼
#   있어 `hold:policy`·`hold:conflict` 어느 쪽에도 같은 코드로 걸린다. 실제로 이
#   마커 관용구(`<reason>-review: resumed`)를 쓰는 자동 절차는 지금 `policy_review_due`
#   하나뿐이라(SKILL.md), `conflict` 에는 이 규칙이 사실상 항상 "증거 없음 → 통과"로
#   떨어진다 — 그게 맞다: 증거가 없는데 배제하면 과잉 배제다(#174 attempt 1 이 이미
#   확인한 원칙). `kept` 마커(라벨 안 건드림)는 여전히 걸러내는 집합에서 뺀다(attempt 3).
#
# `hold:ladder` 는 **규칙 2 로도 못 거른다** — `resume-sweep.sh` 의 사다리 자동재개는
# PR 코멘트에 아무 마커도 안 남긴다(마커는 이슈에만, `<!-- ladder-resume: N -->`, 이
# 헬퍼는 PR 코멘트만 본다). 그래서 `hold:ladder` 는 애초에 "release-candidate"(사람
# 해제 후보) 집합에 넣지 않는다 — 후보 집합은 `hold:policy`·`hold:conflict` 두 라벨만
# **명시 허용목록**으로 삼는다(코드에 `hold:ladder` 라는 문자열을 아예 안 쓴다 — 이
# 레포 `bin/ci` 가 "자동 제거 라벨을 세면 안 된다" 는 계약을 문자열 부재로 스모크
# 검사한다, 아래 참조). 규칙 1 이 참조하는 "다른 hold:\* 라벨" 풀은 `^hold:` 접두만
# 보는 **일반 패턴**이라(특정 사유 이름을 나열하지 않는다) `hold:ladder` 로의 사유
# 교체도 이름 없이 잡힌다 — 다만 `hold:ladder` **자체가 풀리는 것**은 위 허용목록에
# 없어 애초에 후보가 아니다(사다리 재개는 늘 기계다, README: "hold:conflict·hold:policy
# 는 사람 결정이라 건드리지 않는다").
#
# ── `since_at` — 에피소드 스코프 해제 (#186 합류) ──────────────────────────────
#
# #186: 이 헬퍼가 "전역에서 가장 최근 사람 해제" 를 냈을 때, PR 에 **무관한** 보류
# 사이클이 두 번 이상 있으면(보류 A 해제 → 사람이 새 질문 → 무관한 보류 B 해제) 그
# 최근 해제가 **B 의 것**으로 전진해 A 의 질문에 답한 것처럼 보이는 소급 면제가
# 생긴다. `since_at` 를 주면 "그 시각 이후 **첫** 사람 해제" 를 내 이 소급을 막는다 —
# 호출자(`finish-classify.sh`·`closeout-eligible.sh`)는 이미 판정 대상 보류의 앵커
# (`마감 검증: ⚠ 보류` 코멘트 시각)를 갖고 있으므로 그걸 넘기면 된다. 생략 시(2-인자
# 호출) 종전처럼 전역 최신을 낸다 — 단일 보류 사이클(가장 흔한 형상)에선 최신=최초
# 이후-첫-해제라 값이 같다. 앵커 이전의 해제는 무시한다(그 앵커의 보류를 닫을 수 없다
# — 시간 역행 금지).
#
# ── [P2] 코멘트를 인자가 아니라 파일로 넘긴다 (반송 4회차) ─────────────────────
#
# 반송을 여러 번 도는 PR 은 코멘트가 누적돼 `--argjson` 으로 통째로 넘기면 플랫폼
# 인자 상한(리눅스 128KiB, `execve` ARG_MAX)을 넘는 순간 **jq 가 시작도 못 하고**
# 실패한다. 그 실패를 무시하면(원래 코드처럼 `2>/dev/null` 뒤에 `|| exit 1` 이 없으면)
# 빈 `at` 이 "해제 없음"(정당한 rc0)과 구분 안 돼 정당하게 해제된 PR 이 무기한
# 제외된다 — closeout SKILL 이 대형 코멘트 케이스를 `FC_COMMENTS_FILE` 로 이미
# 피하고 있는 바로 그 함정이다. `--slurpfile` 로 파일에서 읽으면 exec 인자 상한과
# 무관해지고, jq 실패는 `|| exit 1` 로 명시 전파한다(PR#139/#168 교훈 — 실패를
# 성공으로 접으면 가드가 자기 자신을 우회한다).
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
# 마커 코멘트는 이슈·PR **양쪽에 미러**되는 것을 전제로 한다(policy_review_due 절이
# 그렇게 적혀 있다). 이 헬퍼는 PR 코멘트만 본다(`pr-comments.sh` 재사용 — 로직 두 벌
# 금지). 마커가 PR 에 없으면(미러 누락) 규칙 2 는 못 걸고 종전대로 새는데, 그건 SKILL
# 절차 위반이지 이 헬퍼의 계약 위반이 아니다.
#
# 범위 메모: 여기서 하는 것은 "언제, 누가 풀렸나" 까지다. **루프가 스스로 `hold:*` 를
# 떼는 경로는 이 스크립트가 만들지 않는다** — 이미 일어난 해제를 *읽고 분류*만 한다.
# 사람 결정문의 *내용* 판정은 closeout SKILL ③-1 의 몫이다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

repo=${1:?repo}
pr=${2:?pr_num}
since_at=${3:-}

# `issues/<pr>/timeline` 은 PR 에도 그대로 쓴다(GitHub 은 PR 을 이슈로도 노출한다).
# `^hold:` 접두만 본다 — 특정 사유 이름을 나열하지 않는다(규칙 1 이 참조할 "다른
# hold:* 라벨" 풀을 일반적으로 채우기 위해서다. 신설 사유가 생겨도 이 select 는
# 안 바뀐다). labeled 도 함께 긁는다 — 규칙 1(사유 교체) 판정에 필요하다.
raw=$(gh api "repos/$repo/issues/$pr/timeline?per_page=100" --paginate \
  --jq '.[] | select(.event == "labeled" or .event == "unlabeled")
        | select(((.label.name // "") | test("^hold:")))
        | {event: .event, label: (.label.name // ""), at: (.created_at // "")}' 2>/dev/null) || exit 1

# hold:* 라벨 이벤트 자체가 0건 = 정상적인 "아직 안 풀렸다"(또는 애초에 보류가 없었다).
[ -n "$raw" ] || exit 0

# release-candidate(사람 해제 후보) 형상 — **허용목록**(hold:policy·hold:conflict)만.
# hold:ladder 는 여기 나열하지 않는다: resume-sweep 의 사다리 자동재개는 PR 코멘트에
# 마커를 안 남겨(마커는 이슈 전용) 규칙 2 로 못 거르므로, 애초에 후보에 넣지 않는 것이
# 유일한 방어다(사다리 재개는 항상 기계 — README "hold:conflict·hold:policy 는 사람
# 결정이라 건드리지 않는다"). raw(형식검사 전) 기준으로 먼저 세어 둔다 — hold:ladder
# 만 오간 PR(후보가 애초에 0건)과 "후보는 있는데 전부 형식이 깨졌다"(exit 1 대상)를
# 가르는 데 쓴다.
raw_cand_n=$(printf '%s\n' "$raw" | jq -s '
  [ .[] | select(.event == "unlabeled" and (.label == "hold:policy" or .label == "hold:conflict")) ] | length
' 2>/dev/null)

# ISO8601(`...Z`) 형식만 남긴다 — 형식이 깨진 값이 그대로 상류의 date 파싱으로 새면
# GNU date 가 그럴듯한 epoch 를 만들어 낸다(finish-classify 의 iso_to_epoch 형식검사와
# 같은 취지: 입구에서 막는다).
events=$(printf '%s\n' "$raw" | jq -s -c '
  [ .[] | select(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) ]
' 2>/dev/null)
[ -n "$events" ] && [ "$events" != "null" ] || exit 1

# release-candidate 이벤트가 raw 에 있었는데(raw_cand_n > 0) 형식검사 뒤 하나도 안
# 남으면(전부 깨진 값) = 응답 형상을 **모른다** → exit 1. raw_cand_n 이 0(hold:ladder
# 만 오간 PR 등)이면 이 검사는 건너뛴다 — 애초에 세지 않을 값이라 형식과 무관하다.
if [ -n "$raw_cand_n" ] && [ "$raw_cand_n" -gt 0 ] 2>/dev/null; then
  valid_cand_n=$(printf '%s' "$events" | jq '
    [ .[] | select(.event == "unlabeled" and (.label == "hold:policy" or .label == "hold:conflict")) ] | length
  ' 2>/dev/null)
  { [ -n "$valid_cand_n" ] && [ "$valid_cand_n" -gt 0 ]; } 2>/dev/null || exit 1
fi

# PR 코멘트(전량) — 규칙 2(재심 마커) 대조용. 조회 실패는 "마커를 못 봤다" 로 떨어뜨려
# **더 보수적인 쪽**(빈 코멘트라 필터링이 아무것도 못 걷어낸다)이 아니라, 코멘트를
# 못 읽었다는 사실 자체가 "기계 재심 여부를 모른다" 는 뜻이므로 이 조회 실패는
# 전체 실패로 승격한다 — 모르는 것을 사람 해제로 통과시키지 않는다(fail-closed).
comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || exit 1

# [P2] --argjson 대신 파일로 넘긴다(exec 인자 상한 회피, 위 헤더 참조).
comments_file=$(mktemp "${TMPDIR:-/tmp}/pr-hold-released-at-comments.XXXXXX") || exit 1
trap 'rm -f "$comments_file"' EXIT
printf '%s' "$comments" > "$comments_file" || exit 1

# 규칙 1(사유 교체) + 규칙 2(재심 마커 에피소드) + since_at 스코프를 한 번에 적용한다.
# jq 실패(문법·입력 오류 — `--slurpfile` 는 exec 인자 상한과 무관하므로 대형 코멘트로는
# 더 이상 안 죽는다)는 **명시적으로 exit 1 로 전파**한다([P2] 핵심 — 실패를 "해제
# 이벤트 없음" 과 같은 빈 값으로 접지 않는다).
at=$(printf '%s' "$events" | jq -r \
  --slurpfile comments_raw "$comments_file" --arg since "$since_at" '
  ($comments_raw[0] // []) as $comments
  | def notes(r): [ $comments[] | select(.body | test("<!--\\s*hold-note:\\s*" + r + "\\s*-->")) | .createdAt ];
    def marks(r): [ $comments[] | select(.body | test("<!--\\s*" + r + "-review:\\s*resumed\\s*-->")) | .createdAt ];
    . as $events
    # 규칙 1 이 참조하는 풀 — 사유 이름을 나열하지 않는다(라벨명 무관, 신설 사유도 자동 커버).
    | [ $events[] | select(.event == "labeled") | {reason: (.label | sub("^hold:";"")), at} ] as $ladds
    # release-candidate — 허용목록(policy·conflict)만. hold:ladder 는 여기 안 들어간다.
    | [ $events[] | select(.event == "unlabeled" and (.label == "hold:policy" or .label == "hold:conflict")) ] as $cands
    | [ $cands[] | . as $e | $e.at as $t | ($e.label | sub("^hold:";"")) as $r
        | if ( [ $ladds[] | select(.reason != $r and .at == $t) ] | length ) > 0 then
            empty   # 규칙 1: 같은 시각에 다른 hold:* 가 붙었다 = 사유 교체, 해제 아님
          else
            ( [ notes($r)[] | select(. <= $t) ] | max ) as $last_note
            | if $last_note == null then $t   # hold-note 없음 — 과잉 배제하지 않는다
              else
                ( [ marks($r)[] | select(. >= $last_note and . <= $t) ] | length ) as $mc
                # 규칙 2: 이 에피소드 안에 재심 resumed 마커가 있으면 기계 해제
                | if $mc > 0 then empty else $t end
              end
          end
      ] as $human_releases
    # since_at 스코프 — 주어지면 "그 시각 이후" 로 좁히고 **가장 이른** 것을 낸다(그
    # 보류를 닫는 해제 = 첫 해제. 전역 최신을 쓰면 #186 처럼 무관한 후속 사이클이
    # 소급으로 끼어든다). 안 주면 종전대로 전역 최신.
    | ( if $since == "" then $human_releases
        else [ $human_releases[] | select(. > $since) ]
        end ) as $scoped
    | ( if $since == "" then ($scoped | sort | last)
        else ($scoped | sort | first)
        end ) // empty
' 2>/dev/null) || exit 1

# 해제 이벤트가 전부 규칙 1·2 로 걸러졌거나(사람 해제를 증명 못 함) since_at 이후
# 구간에 해제가 없다 = rc0·무출력(h3b·사다리 자동재개와 같은 모양).
[ -n "$at" ] || exit 0

printf '%s\n' "$at"
