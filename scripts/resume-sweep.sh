#!/usr/bin/env bash
# resume-sweep.sh — 사다리 검증에서 멈춘 이슈(hold:ladder)를 창이 지나면
# 자동으로 재개한다. "사람이 '진행해' 를 치던 것을 틱이 대신 친다" (플랜 §4 · 원칙 4).
#
# 사용: resume-sweep.sh          (인자 없음)
#   스코프: 실행 cwd 의 `.loop/repos` 목록. 없으면 계정 전체(reconcile.sh 와 같은 규약 #40)
#     — 계정 전체 모드의 레포 열거는 **이슈 축 ∪ PR 축**이다(#331): `needs-human` 이 이슈에만
#       있는 레포도, **PR 에만** 있는 레포(④ 정지 미러의 표적)도 순회 대상이다. 전수 근거와
#       각 축이 놓치는 상태는 스코프 블록 주석 참조.
#   환경변수: RESUME_AFTER_MIN · LADDER_RESUME_LIMIT (값은 `scripts/lib/constants.sh`)
#
# 출력(JSON lines):
#   mirror_cleared — 사람이 이슈에서만 푼 홀드의 **PR 사본**을 뗐다(#265, ④ 갈래). 이슈는
#               건드리지 않는다(이미 깨끗하다). number=짝 이슈 · pr=고친 PR ·
#               issue_state=그 이슈의 OPEN/CLOSED · removed=뗀 라벨(정렬·콤마 구분).
#   mirror_retry_exhausted — ④ 정지 미러 정리가 **양성 증거를 못 얻은 채** `MIRROR_RETRY_LIMIT`
#               회를 채웠다(#397). number=짝 이슈 · pr=그 PR · attempts/limit=회차/상한.
#               전이는 SKILL 이 건다(`runner-held … --reason policy`) — 스크립트는 이벤트만.
#   resumed   — 라벨을 되돌려 재디스패치 가능 상태로. attempt = 이번이 몇 번째 재개인가.
#   escalated — 재개 상한 초과 → hold:policy 로 승격. 사람 호출(needs-human)이 되는 것은
#               그 뒤 재심(③)이 "사람 몫 유지" 로 끝났을 때뿐이다(#244 — 디스패처가 판정).
#   policy_review_due — `hold:policy` 재심 1회 대상(#155). **두 축**이 낸다(#395):
#               **열린** 연결 이슈가 있으면 종전대로 **이슈 축**(`number`=이슈 · `pr`=null),
#               참조가 없거나 **전부 닫힌** PR 단독 홀드면 PR 축(`number`=null · `pr`=그 PR).
#               같은 건을 두 번 내지 않는다 — 열린 연결 이슈가 있는 PR 은 이슈 축만(닫힌
#               참조만 남은 PR 은 이슈 축이 열린 이슈 목록이라 못 본다 — #421).
#               PR 축의 처분은 재개가 아니라 `policy-kept` 하나다(#421 — 소비자 없는
#               `flow:agent-ready` 를 만들지 않는다. 전문은 SKILL ① 의 같은 이벤트 불릿).
#   waiting   — 아직 창(RESUME_AFTER_MIN) 안. minutes = 마지막 갱신 후 경과 분.
#   warn      — **아무것도 안 건드린** 채 넘긴 사유(사유 라벨 부재 · 경합 · 첫 쓰기 실패).
#   warn_after_edit — 쓰기가 **이미 반영된 뒤** 후속 단계가 실패했다(라벨·PR 미러·readback).
#               warn 과 섞으면 "손대지 않았다" 가 거짓이 되어, 보고를 읽는 쪽이 GitHub 상태를
#               되짚어야 할 때(사람 확인)와 그냥 다음 틱을 기다리면 될 때를 못 가른다.
#   note      — **아무것도 안 건드린** 정보 줄. warn 과 달리 조치할 것이 **없는** 정상 상태다
#               (#244: 사유 라벨 없는 needs-human — 사람이 직접 세운 정지 · 배포 대기 이슈의
#               needs-human · #201: 배포 대기 이슈의 질문 없는 hold:policy · #217: 배포 대기
#               이슈의 hold:ladder — 창이 지나도 재개·승격 대상이 아니다).
#               버리지 않고 남기는 이유는 emit_note 주석.
#
# 상태 파일 없음 — 재개 횟수는 **이슈 코멘트에 붙은 마커**(`<!-- ladder-resume: N -->`)의
# 개수가 SSOT 다. 재개 코멘트가 자기 마커를 품으므로 카운터와 알림이 한 번의 append 로 끝나고,
# 본문은 **읽지도 쓰지도 않는다** — `--body-file` 은 본문 전체를 다시 올리는 일이라, 그 사이
# 사람이 쓴 글을 통째로 덮어쓸 수 있었다(마커 한 줄 때문에 남의 글이 사라지는 경로).
# append-only 라 경합에 안전하고, 상태 = 값의 존재라는 레포 규약과도 같은 모양이다.
#
# 왜 `hold:ladder` 만 자동 재개하나 (플랜 갈림길 3): `hold:conflict` 는 사람이 결정해야
# 하는 것이고, `hold:policy` 는 재심 1회를 루프가 맡는다(#155 — ③ 이 이벤트만 낸다).
# `needs-human` 은 **사람이 직접 세운 정지**다(#244) — 루프가 사람의 손을 떼는 일은 없어야
# 하므로, 맨 `needs-human` 은 물론이고 `hold:ladder` 옆에 함께 붙은 것도 무편집이다.
#
# PR 미러: `transition.sh verify-held`·`closeout-blocked` 는 사유 라벨을 이슈와 **PR 양쪽**에
# 붙인다. 이슈만 되돌리면 PR 은 영구 needs-human 으로 남고, 뒤 전이(handoff-verify·verify-pass·
# closeout-pick)는 그 라벨을 떼지 않아 사람이 손으로 지워야 흐른다. 그래서 재개·승격은
# 연결된 열린 PR 의 같은 라벨까지 **같은 단계에서** 함께 되돌린다.
#
# 그런데 그 되돌림은 **이 스윕이 스스로 재개·승격할 때**뿐이었다 — 즉 `hold:ladder` 자동
# 재개 한 경로. `hold:conflict` 는 정의상, `hold:policy` 는 재심(#155) 유지 판정 뒤에
# **사람이 푸는데**, 사람이 푸는 경로에는 PR 사본을 되돌리는 자리가 어디에도 없었다(#265). 그래서 ④ 갈래를 둔다:
# 이슈에 정지 라벨이 하나도 없는데 짝이 되는 **열린** PR 에 남아 있으면 **PR 쪽만** 뗀다
# (이슈는 이미 깨끗하니 건드릴 것이 없다 — 이 갈래는 재개가 아니라 미러 정리다). 짝으로
# 인정하는 것은 head 가 `agent/issue-*` 이고 `closingIssuesReferences` 로 링크가 증명된
# PR 뿐이다 — 사람이 연 PR 의 표식과 `Refs` 전용 PR 의 정상 홀드를 벗기지 않기 위해서다
# (규칙 전문은 mirror_row 주석, `loop-status.sh` 의 warn 과 같은 규칙이어야 한다).
# 부착 방향(이슈엔 있는데 PR 엔 없음)은 이 갈래의 축이 아니다 — 라벨을 **붙이는** 쪽은
# `transition.sh` 의 몫이고, 여기서 붙이면 사람 게이트를 스윕이 만들어 내는 셈이 된다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/scope.sh
. "$SCRIPT_DIR/lib/scope.sh"   # scope_lines · scope_file 기본값 — 판정은 한 자리 (#427)
# shellcheck source=scripts/lib/constants.sh
. "$SCRIPT_DIR/lib/constants.sh"   # 상수는 한 자리 (#427)

# 창·상한 세 상수(RESUME_AFTER_MIN · LADDER_RESUME_LIMIT · MIRROR_RETRY_LIMIT)의 값과
# 근거는 `scripts/lib/constants.sh` 다 — SKILL.md 의 `## 상수` 절과 두 벌로 두던 것을
# 한 자리로 모았다(#427). 아래 `_nonneg_int` 검사는 **env 로 들어온 값**을 무는 관문이라
# 그대로 남는다(상수가 어디서 오든 형식이 어긋나면 여기서 exit 64).
# 목록·탐색 조회 상한. 기본 200 — 기본 limit(30)은 조용히 잘라 그 이슈들이 영영 안 보인다.
# 테스트가 상한 도달 경로를 200건짜리 픽스처 없이 재현하도록 env 로 낮출 수 있게 열어 뒀다
# (운영에서 내리는 값이 아니다 — 내리면 그만큼 잘린다. 잘림 자체는 warn 으로 드러난다).
LIST_LIMIT="${RESUME_LIST_LIMIT:-1000}"   # gh issue list 가 내부 페이지네이션(100/페이지)으로 채운다 — #151

# 값 검증은 **모든 GitHub 호출 앞**에 둔다. `[ "$x" -lt "$y" ]` 는 정수가 아니면 bash 가
# 에러를 내고 거짓으로 떨어지는데, set -e 가 아니라 그대로 흘러 "창이 지났다"·"상한을
# 안 넘었다" 로 오판한다 — 오타 하나(RESUME_AFTER_MIN=120m)가 전 이슈 즉시 재개가 된다.
_nonneg_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ! _nonneg_int "$RESUME_AFTER_MIN"; then
  echo "resume-sweep: RESUME_AFTER_MIN 은 음이 아닌 정수여야 한다 (받은 값: '$RESUME_AFTER_MIN')" >&2
  exit 64
fi
if ! _nonneg_int "$LADDER_RESUME_LIMIT"; then
  echo "resume-sweep: LADDER_RESUME_LIMIT 은 음이 아닌 정수여야 한다 (받은 값: '$LADDER_RESUME_LIMIT')" >&2
  exit 64
fi
if ! _nonneg_int "$MIRROR_RETRY_LIMIT"; then
  echo "resume-sweep: MIRROR_RETRY_LIMIT 은 음이 아닌 정수여야 한다 (받은 값: '$MIRROR_RETRY_LIMIT')" >&2
  exit 64
fi
if ! _nonneg_int "$LIST_LIMIT" || [ "$LIST_LIMIT" -lt 1 ]; then
  echo "resume-sweep: RESUME_LIST_LIMIT 은 1 이상의 정수여야 한다 (받은 값: '$LIST_LIMIT')" >&2
  exit 64
fi

# ── 인용된 마커는 제어 신호가 아니다 (#197) ───────────────────────────────
# 마커(`<!-- hold-note: … -->`·`<!-- policy-review: … -->`·`<!-- ladder-resume: N -->`)는
# 루프끼리 주고받는 **제어 신호**다. 그런데 substring 매칭은 그 신호를 *설명하는 글*까지
# 신호로 읽는다 — 실측(#174): 재심 코멘트가 본문에 hold-note 을 인용해 **자기 자신을**
# 이번 홀드의 질문(에피소드 경계)으로 만들었고, 경계 뒤에는 재심 마커가 없어 판정이 매 틱
# `due` 로 되돌아왔다(사람이 라벨을 뗄 때까지 영구 반복). 같은 취약점이 재개 횟수에도 있어
# `<!-- ladder-resume: 1 -->` 를 인용만 해도 소진 횟수가 부풀고 조기 승격(사람 대기)됐다.
#
# 그래서 매칭 **전에** 인용 구간을 걷어낸다. 걷어내는 것: 코드펜스(``` … ```)와 백틱 인라인
# 코드. 걷어내지 **않는** 것: 코멘트 끝에 맨몸으로 붙는 정상 마커와, 블록쿼트(`>`)·따옴표
# 안의 맨몸 마커(블록쿼트로 남의 코멘트를 통째 인용하는 일은 이 루프에 없고, 걸러 버리면
# 진짜 마커를 잃는다).
#
# 순서가 계약이다 — 펜스를 **먼저** 지운 뒤 인라인을 지운다. 인라인을 먼저 돌리면 펜스
# 안쪽의 백틱이 인라인 스팬으로 소진돼, 남은 펜스 구분자가 짝을 잃는다.
#
# 두 패스 모두 **범위를 좁혀** 과다 필터를 막는다 — 지우는 쪽으로 틀리면 맨몸 마커가 통째로
# 사라져(재개 횟수 과소집계 → 상한이 안 걸리는 무한 재개) 원래 버그보다 나쁘다. 규칙은
# CommonMark 의 코드펜스·코드스팬 규칙을 **그대로** 따른다(한 사례가 아니라 규칙 전체 —
# #197 마감 검증 attempt3: 이전 두 회차가 매번 지적된 한 형태만 닫아 같은 축에서 반복됐다):
#   · 펜스는 CommonMark 대로 **줄 머리**(들여쓰기 ≤3칸)에서만 연다/닫는다. 백틱 펜스와
#     물결 펜스는 **한 gsub 안의 두 대안(`|`)**으로 원문 순서대로 함께 처리한다(#230:
#     예전엔 두 개의 gsub 로 분리했었다 — #197 마감 검증 attempt4 가 "하나로 합치면
#     백틱 펜스의 info string 이 물결과 같은 `[^\n]*` 를 물려받는다" 며 분리로 고쳤지만,
#     그 이유는 **info string 정규식을 공유할 때만** 참이다. 두 대안을 각자 온전한
#     `(여는 ~ 닫는)` 식으로 완전히 따로 쓰면 info string 은 안 섞이고, 대신 **원문에
#     실제로 먼저 나오는 펜스가 먼저 매칭**된다 — 분리된 두 패스는 이 순서를 몰라, 물결
#     펜스 **안**에 있는 단독 ``` 줄(또는 그 대칭)을 별개 패스가 독립된 여는 펜스로 오인해
#     `$` 대안으로 문서 끝까지 지웠다(#230 h2 실측). 여는 펜스의 **길이**를 이름있는 그룹
#     (`(?<f>```+)`/`(?<t>~~~+)`)으로 기억해 두고,
#     닫는 줄은 같은 문자로 **그 길이 이상**(`\k<f>`/`\k<t>`)이며 뒤에 **공백만** 올
#     때만(`[ \t]*`, 그 뒤 줄끝/문자열끝) 닫힌 것으로 본다 — 다른 텍스트가 붙은 줄
#     (`` ``` not-a-close ``)이나 더 짧은 런(사중 펜스 안의 삼중 줄)은 닫지 못하고
#     지나친다. 닫는 펜스가 없으면 **문서 끝까지**가 코드다(`$` 대안 — 덜 지우는 쪽이
#     아니라 CommonMark 자체가 그렇다). **백틱 펜스의 info string 은 백틱을 금지**한다
#     (`[^`\n]*` — CommonMark 규칙, 물결 펜스에는 이 제약이 없어 물결 쪽만 `[^\n]*`).
#     이 제약이 없으면 줄 머리의 인라인 3-백틱 스팬(` ```example``` `)이 "안 닫힌 펜스"로
#     읽혀 `$` 대안이 문서 끝까지 삼킨다 — 뒤따르는 맨몸 마커가 함께 사라져 수용 기준
#     2번(맨몸 마커는 계속 세어진다)이 깨졌다(#197 마감 검증 attempt4 실측 — g18).
#     jq(Oniguruma)의 `^` 는 줄 머리가 아니라 **문자열 머리**라 `(^|\n)` 로 직접 쓴다
#     (실측 — `test("^```")` 는 2행의 펜스에 거짓이다).
#   · 인라인은 CommonMark 의 코드 스팬 규칙대로 **구분자 길이를 정확히 맞추고, 양쪽 다
#     최대런**(maximal run)이어야 한다 — 여는 런 `(?<!`)(?<r>`+)(?!`)` 은 앞뒤 모두
#     백틱이 없어야 하고(런의 시작·끝 둘 다), 닫는 런 `(?<!`)\k<r>(?!`)` 도 앞뒤 모두
#     백틱이 없어야 한다(런의 끝). 앞쪽만 안 물고 뒤쪽만 확인하면(첫 회차가 그랬다) 더 긴
#     런의 **접미부**가 짧은 런의 닫기로 오인된다 — 길이 3 런은 길이 2 스팬을 닫지 못하는데도
#     뒤 두 글자가 닫기로 읽힌다(#197 마감 검증 attempt3 실측). **여는 런 뒤의 `(?!`)`
#     은 그와는 별개 결함을 막는다(#230 h1)**: 이게 없으면 정규식 엔진이 그리디하게 잡은
#     여는 런을 **축소 백트래킹**해 더 짧은 닫는 런과 짝지을 수 있다 — 여는 3런 + 닫는
#     2런은 CommonMark 상 코드 스팬이 아닌데(길이 불일치), 백트래킹이 여는 런을 2로 줄여
#     억지로 짝지어 마커를 지웠다. `(?!`)` 는 여는 런의 길이를 그 위치의 **최대련으로
#     고정**해 축소 자체를 막는다 — 줄여도 다음 문자가 백틱이라 실패하므로, 엔진은 그
#     시작 위치를 포기하고 다음 위치로 넘어간다(뒤 어딘가에 우연히 같은 길이의 독립된 런이
#     없는 한 매칭 실패 = 인용 아님 = 마커를 센다, 원하는 답). 반대 방향(여는 2런 + 닫는
#     3런)은 원래도 깨지지 않았다 — 짧은 여는 런에서 긴 닫는 런 **안**의 부분 문자열을
#     찾으려 해도 그 부분 문자열의 앞뒤 중 한쪽은 항상 백틱과 붙어 있어 `(?<!`)…(?!`)`
#     양쪽 경계를 통과 못 한다(회귀 방어 픽스처로 고정). 백틱을 하나씩 짝지으면(더 이전
#     회차) 짝수 길이 구분자가 "빈 스팬 두 개"로 갈려 알맹이(마커)만 맨몸으로 남는다.
#     알맹이에 백틱이 있을 때 쓰는 이중 백틱은 CommonMark 의 정식 코드 스팬이다.
#   · 인라인도 **한 줄 안**으로 제한한다(`[^\n]`). 줄을 넘게 두면 앞줄의 홀백틱이 뒷줄
#     백틱과 짝지어 그 사이의 진짜 마커를 삼킨다. 한 줄 안에서도 코드가 아닌 백틱 두 개가
#     마커를 사이에 두면 같은 일이 나지만, 그건 마커를 감싼 인용과 형태가 같아 구분할 수
#     없다 — 한 줄로 좁히는 것이 이 대칭 위험을 실질적으로 줄이는 선까지다.
#   · 알려진 느슨함(그대로 남긴다 — 숨기지 않는다): **여러 줄에 걸친 코드 스팬**은 여전히
#     신호로 샌다(#197 마감 검증 attempt4 WARN — 실측: `` `<!-- ladder-resume: 1\n--> ` ``
#     에서 `ladder-resume` 가 살아남는다). 인라인을 한 줄로 제한한 선택(위 항목)의 직접적
#     결과다 — 줄을 넘게 두면 앞줄의 홀백틱이 뒷줄 백틱과 짝지어 진짜 마커를 삼키는 쪽이
#     더 나쁘다고 판단해 **의도적으로 남겨 둔다**. (구 버전은 백틱 펜스를 물결로 닫는 혼용
#     `` `*~* `` 를 허용했으나, 두 gsub 분리로 자연히 사라졌다 — 더 이상 유효한 느슨함이
#     아니다.)
# 매칭 **전에** `\r\n`→`\n` 정규화를 한 번 돈다(#230 h3): CommonMark 의 "줄"은 개행
# 관례에 무관하고, 닫는 펜스 뒤에 허용되는 건 그 줄의 **끝**까지인데 정규식의
# `[ \t]*(?=\n|$)` 는 `\r` 을 그 공백으로도 줄끝으로도 안 봐서 CRLF 본문에서는 **제대로
# 닫힌 펜스**도 미닫힘으로 읽혀 `$` 대안이 EOF 까지 지운다. 세 패스(펜스 두 대안 + 인라인)
# 모두 이 정규화 뒤의 텍스트를 보므로 한 번으로 셋 다에 듣는다 — 경계마다 `\r?` 를 끼워
# 넣는 대안은 패스 수만큼 반복해야 하고 빠뜨리기 쉽다.
# 두 패스 모두 Oniguruma 의 **이름있는 그룹**(`(?<name>…)`)과 **lookbehind**(`(?<!…)`)에
# 의존한다 — 이 저장소가 요구하는 macOS bash 3.2 는 셸 문법 얘기고, jq 엔진(Oniguruma)이
# 이 구문을 지원하는지가 별개다. jq-1.6/1.7 양쪽에서 실측했다(`jq --version`).
# 이 정의는 SKILL.md·SKILL.en.md ③-4d 의 재개 횟수 jq 와 **같은 문자열**이어야 한다
# (프롬프트와 스크립트가 다른 수를 세면 안 된다 — 동기화는 테스트가 grep -F 로 문다).
JQ_UNQUOTE='def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " ");'

# 사용자 확인은 공유 헬퍼(gh-login.sh) — REST /user 503 폴백·형식 검증·재시도는 그 안.
# 오염된 me 로 빈 스코프를 위장하지 않는다(fail-loud).
me=$("$SCRIPT_DIR/gh-login.sh") || me=""
if [ -z "$me" ]; then
  echo "resume-sweep: GitHub 사용자 확인 실패 (REST /user·GraphQL viewer 모두 응답 없음)" >&2
  exit 1
fi

tmp=$(mktemp -d) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  echo "resume-sweep: 임시 디렉터리 생성 실패 — 조회 결과를 못 받으므로 중단" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT

now_epoch=$(date -u +%s)

# RFC3339(UTC) → epoch. BSD(date -j -f) 우선, 실패하면 GNU(date -d).
to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

has_label() {  # has_label <콤마목록> <라벨>
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}

# 정지 라벨이 하나라도 있나 — 기계 정지(transition.sh 의 verify-held·closeout-blocked·
# runner-held)가 이슈와 PR **양쪽**에 붙이는 `hold:<사유>`(#244 로 기계 정지가 다는 것은
# 이것뿐이다)와, 사람이 손으로 세우는 `needs-human` 을 **둘 다** 센다 — 이 갈래가 묻는 것은
# "사람 게이트가 살아 있나" 이고, 그 답은 두 쪽 중 하나만 있어도 참이기 때문이다.
# 열거가 아니라 **접두** 판별인 이유: 네 게이트(eligible-issues·claim-issue·verify-eligible·
# closeout-eligible)가 전부 `hold:` 접두로 보므로(#242), 사유가 하나 늘면(`hold:<새사유>`)
# 게이트는 그 PR 을 제외하는데 이 갈래만 못 봐서 **이 이슈가 고치려는 조용한 좌초가 그대로
# 재현된다**. `needs-human` 이 #244 로 기계 정지에서 빠져도 나머지 절반이 판정을 이어받는다.
# 라벨 경계는 콤마다 — `,hold:` 로 물어야 `hold:` 로 **시작하지 않는** 라벨(`my-hold:x`)이
# 안 걸린다(eligible-issues.sh:75 와 같은 형태).
# 쌍둥이: `loop-status.sh` 의 `stops_of`(jq). 한쪽을 고치면 다른 쪽도 같이 고쳐라 —
# 경보와 교정이 다른 집합을 보면 한쪽이 거짓말을 한다.
has_stop() {  # has_stop <콤마목록>
  case ",$1," in *,needs-human,*) return 0 ;; esac
  case ",$1," in *,hold:*) return 0 ;; esac
  return 1
}

# `number` 는 따옴표 **밖**의 %s 라, 값이 비거나 정수가 아니면 `{…,"number":,…}` 가 나가
# 줄 전체가 JSON 이 아니게 된다(#193). 그 줄은 관대한 파서에선 통째로 유실되고 엄격한
# 파서에선 읽기를 멈춘다 — 어느 쪽이든 **경보가 조용히 사라지는** 방향이다. 그래서:
#   · 줄은 **반드시 나간다** — 번호를 못 구했다고 경보를 버리면 고치려던 것을 그대로 재현한다.
#   · 번호는 `0` 으로 낮춘다 — "특정 이슈가 아니다" 라는 뜻으로 레포 단위 경보가 이미 쓰는 값.
#   · `0` 만으로는 그 레포 단위 경보와 구분이 안 되니, **원본 토큰을 인용해** msg 앞머리에
#     붙인다 — 무엇이 들어왔는지가 파싱이 어디서 어긋났는지를 짚는 유일한 단서다.
#     기존 문구는 그 뒤에 한 바이트도 안 바뀐 채 붙는다 — 디스패처 SKILL.md 가 문구로 분기한다.
# 세 헬퍼가 **같은 규칙**을 따르도록 방출을 한 곳(_emit)으로 모은다 — 한 헬퍼만 고치면
# 나머지 둘이 같은 모양으로 남는다.

# 방출용 번호 술어 — 값이 **정규 JSON 정수 리터럴**인가(`0` | `[1-9][0-9]*`).
# `_nonneg_int()`(:47) 와 일부러 **다른 이름·다른 규칙**이다:
#   · 저쪽은 사람이 손으로 쓰는 env(RESUME_AFTER_MIN 등)의 exit 64 게이트다. 뒤에서 산술로만
#     쓰이므로 `060` 이 들어와도 60 으로 멀쩡히 돈다 — 거기까지 좁히면 그렇게 써 온 환경이
#     갑자기 죽는다(이 이슈의 범위 밖).
#   · 이쪽은 **JSON 리터럴 자리**다. RFC 8259 는 선행 0 을 금지하고, 관대한 파서(jq)는
#     `{"number":01}` 을 조용히 **`1`** 로 읽는다 — 즉 통과시키면 엄격한 쪽은 줄을 버리고
#     관대한 쪽은 **없는 이슈 #1** 을 가리킨다.
# 그래서 `01 → 1` 정규화는 채택하지 않는다: `num` 의 출처는 `jq -r '.number|tostring'`
# 하나뿐이고 jq 는 `1` 을 `"1"` 로 낸다 — `01` 을 낼 경로가 없으니 선행 0 은 "특이 표기" 가
# 아니라 **파싱이 어긋났다는 증거**다. 정규화하면 출처가 말하지 않은 번호를 지어내는 것이고,
# 경보의 뜻이 "어느 이슈인지 모르겠다" 에서 "이슈 #1 이다" 로 바뀐다 — 틀린 번호를 단 경보는
# 번호 없는 경보보다 나쁘다(읽는 사람이 무고한 이슈를 열고 진짜 대상은 영영 안 보인다).
_json_int() {  # 통과: 0·1·42·1234 / 거절: ''·01·007·+1·1.0·1e3·공백 포함 토큰
  case "$1" in
    ''|*[!0-9]*) return 1 ;;   # 빈 값 · 숫자 아닌 문자(부호·소수점·지수·공백)가 섞였다
    0)  return 0 ;;            # `0` 단독은 정규 — "특정 이슈가 아니다"
    0*) return 1 ;;            # 두 자리 이상인데 선행 0 → 비정규
    *)  return 0 ;;
  esac
}

# 인용할 원본 토큰을 JSON **문자열 안**에 안전하게 넣는다. 맨몸으로 박으면 따옴표·역슬래시·
# 제어문자가 섞여 들어온 순간 이 이슈가 고치려는 것(깨진 줄)을 msg 자리에서 그대로 재현한다.
# 토큰은 파싱이 어긋났을 때의 값이라 **무엇이든 될 수 있다** — 모양을 가정하지 않는다.
_json_token() {  # _json_token <원본 토큰>
  local t="$1"
  t=${t//\\/\\\\}
  t=${t//\"/\\\"}
  # 개행·탭 등 제어문자는 JSON 문자열에 맨몸으로 못 들어간다 — 눈에 보이는 기호로 접는다.
  case "$t" in *[[:cntrl:]]*) t=$(printf '%s' "$t" | tr '[:cntrl:]' '?') ;; esac
  printf '%s' "$t"
}

_emit() {  # _emit <event> <repo> <num> <msg>
  local num="$3" msg="$4"
  if ! _json_int "$num"; then
    msg="번호 파싱 실패('$(_json_token "$num")') — $msg"
    num=0
  fi
  printf '{"event":"%s","repo":"%s","number":%s,"msg":"%s"}\n' "$1" "$2" "$num" "$msg"
}

# `msg` 가 없는 이벤트(waiting·escalated·resumed·policy_review_due)도 같은 자리에 같은
# 위험을 안는다 — 그쪽은 `printf` 가 인라인이고 필드 구성이 제각각이라 `_emit` 을 못 쓴다.
# 사실을 적을 `msg` 칸이 없으니 **형식 안전만** 취한다: 정규 정수가 아니면 0. 방출 조건은
# 손대지 않는다(특히 `waiting` 은 원래 조용히 넘기는 이벤트라 줄 수가 늘면 안 된다).
_emit_num() { if _json_int "$1"; then printf '%s' "$1"; else printf 0; fi; }

emit_warn() {  # emit_warn <repo> <num> <msg> — msg 는 이 파일이 쓰는 고정 문구(따옴표 없음)
  _emit warn "$1" "$2" "$3"
}

# 쓰기가 이미 GitHub 에 반영된 뒤의 실패. warn 과 나누는 이유는 대응이 다르기 때문이다 —
# warn 은 "그대로 두면 다음 틱이 다시 본다", 이건 "상태가 반쯤 바뀌었으니 사람이 본다".
emit_warn_after_edit() {  # emit_warn_after_edit <repo> <num> <msg>
  _emit warn_after_edit "$1" "$2" "$3"
}

# 조치할 것이 **없는** 정보 줄. warn 의 정의를 "루프가 교정 가능한 불변식 위반" 으로 좁히고
# (형제 이슈 #188 이 loop-status.sh 에서 정한 정의) 거기서 빠지는 건을 여기로 내린다.
# 그냥 빼지 않는 이유: 관측에서 통째로 사라지면 그 자체가 다른 사각지대가 된다.
# msg 는 이 파일이 쓰는 고정 문구다 — 라벨 이름을 끼워 넣지만 그 값은 아래 deploy_wait_row 가
# 고르는 **jq 문자열 리터럴 두 개("deploy-wait"·"full-cycle") 중 하나**이지 GitHub 에서 온
# 텍스트가 아니다. 따옴표·개행이 못 들어오므로 printf JSON 포맷 계약이 깨질 경로가 없다.
emit_note() {  # emit_note <repo> <num> <msg>
  _emit note "$1" "$2" "$3"
}

# 배포 대기 축 판정 — ①(재개·승격, #217)·②(사유 없는 needs-human)·③(policy 재심 no-note,
# #201) 이 공유하는 **한 벌** 술어다. 복제하면 세 벌이 나중에 갈라진다(#201·#217 이 막으려는
# 것 자체 — 같은 질문에 갈래마다 다른 답이 나오는 사고).
# 라벨만 본다 — 제목은 사람이 자유롭게 쓰므로 판별 축이 될 수 없다(그래서 이 스크립트는
# title 을 조회조차 하지 않는다). `deploy-wait` 가 정본 축이다(closeout 이 배포 대기 이슈에
# 붙인다) — 그래서 둘 다 있으면 이쪽을 문구에 남긴다. `full-cycle` 은 **과도기 축**이다:
# 사람 세션 스킬 full-cycle §7 이 배포 대기 이슈에 `needs-human`+`full-cycle` 만 붙이고
# `deploy-wait` 를 빠뜨려서 생긴 구멍인데, 그 스킬은 이 레포 밖이라 여기서 못 고친다.
# **그쪽이 `deploy-wait` 를 붙이는 날 이 갈래(full-cycle)는 뗀다** — 원칙적 축으로 오해하지
# 마라. 번호와 축을 **한 번의 jq 로 함께** 뽑는다 — 호출부(② 는 needs-human 이슈 수만큼,
# ③ 은 hold:policy 이슈 수만큼) 마다 필드별 프로세스를 띄우면 조회보다 파싱이 더 비싸진다.
deploy_wait_row() {  # deploy_wait_row <row-json> — stdout: "<number>\t<axis>"(axis: deploy-wait|full-cycle|""). jq 실패 시 둘 다 빈 값 — 빈 축은 호출부에서 "해당 없음" 으로 떨어진다(강등이 조회 실패를 타고 번지지 않는 방향).
  printf '%s' "$1" | jq -r '
    [.labels[].name] as $n
    | [(.number|tostring),
       (if ($n | index("deploy-wait") != null) then "deploy-wait"
        elif ($n | index("full-cycle") != null) then "full-cycle"
        else "" end)] | @tsv' 2>/dev/null
}

# 위 술어를 **`read_state` 가 내는 모양**에 먹이기 위한 얇은 어댑터(#229). 술어를 고치지도
# 복제하지도 않는다 — 모양만 맞추고 판정은 통째로 `deploy_wait_row` 에 넘긴다(#201·#217 이
# 한 자리로 모은 것을 다시 가르면 같은 질문에 갈래마다 다른 답이 나온다).
# 왜 모양이 다른가: 목록 조회는 row-json(`.labels[].name`)을 주는데 `read_state` 는 라벨을
# **콤마 목록**으로 낸다(그 모양을 쓰는 `has_label` 이 이미 여럿 있다). 보는 것은 같은 라벨
# 집합이므로 여기서 row-json 으로 되돌려 준다. `number` 는 이 호출부가 축(axis)만 읽으므로
# `0`(= "특정 이슈가 아니다", `_emit` 이 쓰는 값)으로 채운다.
# jq 실패는 **rc 로** 나간다 — 빈 값을 "배포 대기 아님" 으로 돌려주면 호출부의 fail-closed
# 분기에 아예 들어가지 못한다(PR#139 계열: 부분 실패의 부분 출력을 정상값으로 채택하는 사고).
# 필터 첫 줄의 `# deploy-wait-adapter` 는 스위트가 **이 한 호출만** 실패시켜 fail-closed 를
# 실증하기 위한 표식이다 — 어댑터가 JSON 을 스스로 만드는 이상 데이터로는 이 경로에 못 닿는다.
deploy_wait_labels() {  # deploy_wait_labels <라벨 콤마목록> — stdout·rc 계약은 deploy_wait_row 와 같다
  local rowjson
  rowjson=$(printf '%s' "$1" | jq -Rsc '# deploy-wait-adapter (#229)
    {number: 0, labels: (split(",") | map(select(length > 0) | {name: .}))}' 2>/dev/null) || return 1
  [ -n "$rowjson" ] || return 1
  deploy_wait_row "$rowjson"
}

# ── GitHub 읽기 헬퍼 — 전부 **조회 실패는 rc 1** ──────────────────────────
# 빈 값을 실패로 치면 "라벨이 0개인 이슈"·"코멘트가 0개인 이슈" 같은 정상 결과가
# 영영 조회 실패로 오분류된다. 값이 아니라 rc 로 가른다.
read_labels() {  # read_labels <repo> <num> — 이슈 라벨 콤마목록
  local out
  out=$(gh issue view "$2" --repo "$1" --json labels 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# 편집 직전 재조회 — 라벨과 updatedAt 을 한 번에. 본문은 더 이상 읽지 않는다(마커=코멘트).
read_state() {  # read_state <repo> <num> <updatedAt 저장파일> — 라벨 콤마목록을 stdout
  local out
  out=$(gh issue view "$2" --repo "$1" --json labels,updatedAt 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.updatedAt // ""' > "$3" || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# 재개 횟수 = 마커를 품은 코멘트의 **개수**. 창을 넘긴 후보에만 부른다(코멘트 조회는
# 이슈당 한 번의 왕복이라, 대기 중인 건까지 훑으면 틱마다 큰 레포를 헛돈다).
# 세 번째 인자로 **마커 정규식**을 받는다(#397) — 기본값은 재개 마커라 기존 호출은 그대로다.
# 조회는 `fetch_comments`(페이지네이션 전량) 한 자리다 — 첫 100건 상한을 쓰면 코멘트가 많은
# 이슈에서 회차가 늘 0으로 보여 상한이 안 걸린다(그 함수 주석).
count_markers() {  # count_markers <repo> <num> [마커 정규식]
  local out re="${3:-}"
  [ -n "$re" ] || re='<!--\s*ladder-resume:\s*[0-9]+\s*-->'
  out=$(fetch_comments "$1" "$2") || return 1
  printf '%s' "$out" \
    | jq --arg re "$re" "$JQ_UNQUOTE"'[.[]? | select(.body | unquoted | test($re))] | length'
}

# ── 코멘트 전량 조회 한 자리 (#397) ────────────────────────────────────────────
# 마커를 세는 자리도 재심 마커를 읽는 자리도 **페이지네이션**된 전량을 봐야 한다.
# `gh issue view --json comments` 는 **첫 100건**만 준다 — 코멘트가 100건을 넘는 이슈에서는
# 마커가 늘 0으로 보여 ⑴ 재개/재시도 상한이 영영 안 걸리고(무한 재시도) ⑵ 재심 마커가 안
# 보여 같은 건이 매 틱 `due` 로 되돌아온다. `finish-classify`·`closeout-eligible` 이 이미
# 같은 함정을 `pr-comments.sh` 로 없앴고(#171), 그 헬퍼는 REST `issues/{n}/comments` 를 쓰므로
# **이슈 번호를 그대로 넘기면 된다**(PR 은 이슈의 부분집합 — 그 파일 주석 참조).
# 출력은 `[{body,createdAt},...]` 배열이고 순서는 created 오름차순(에피소드 경계 계산의 전제).
fetch_comments() {  # fetch_comments <repo> <이슈|PR 번호> → 코멘트 배열 JSON / 조회 실패 return 1
  local out
  out=$("$SCRIPT_DIR/pr-comments.sh" "$1" "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# ── ③ 재심의 두 판정 — **이슈 축과 PR 축이 같은 자리를 쓴다** (#395) ──────────────
# PR 단독 홀드(`verify-held`·`closeout-blocked` 를 `<issue>=-` 로 부른 경우)도 재심 대상이라
# 축이 둘이 됐다. 창 판정과 마커 판정을 두 벌로 적으면 한쪽만 고쳐질 때 같은 형상이 축에
# 따라 다르게 판정된다 — 이 파일이 `read_state`·`deploy_wait_row` 로 이미 세운 규율 그대로
# 함수 한 자리에 둔다.
policy_window_min() {  # policy_window_min <updatedAt> → 경과 분 / 해석 불가면 return 1
  local ep
  ep=$(jq -n --arg u "$1" '($u | try fromdateiso8601 catch -1)' 2>/dev/null || echo -1)
  [ "${ep:--1}" -ge 0 ] 2>/dev/null || return 1
  echo $(( ( $(date -u +%s) - ep ) / 60 ))
}

# 에피소드 단위 재심 판정. 마지막 `hold-note: policy` 코멘트(=이번 홀드의 질문) **이후**에
# 재심 마커가 있어야 "이번 홀드는 재심됨" 이다. 옛 홀드의 마커가 새 홀드의 재심을 막지 않게.
# 질문(hold-note) 자체가 없으면 재심할 대상이 없다(`no-note`).
# 입력은 `fetch_comments` 의 배열이다(#397) — 두 축이 같은 페이지네이션 소스를 쓰므로 한
# 판정이 그대로 선다(`transition.sh` 는 질문 코멘트를 이슈와 PR **양쪽**에 남긴다 — 그래서
# PR 단독 홀드에도 마커가 PR 에 있다). 첫 100건 상한을 쓰면 옛 홀드의 마커만 보여 재심이
# 영원히 `due` 로 되돌아온다.
policy_review_state() {  # policy_review_state <코멘트 배열 JSON> → reviewed|due|no-note|parse-fail
  printf '%s' "$1" | jq -r "$JQ_UNQUOTE"'
    [.[]? | .body | unquoted] as $b
    | ([range(0; $b|length)] | map(select($b[.] | test("<!--\\s*hold-note:\\s*policy"))) | last) as $q
    | if $q == null then "no-note"
      else ([range($q+1; $b|length)] | map(select($b[.] | test("<!--\\s*policy-review:"))) | length) as $r
           | if $r > 0 then "reviewed" else "due" end end' 2>/dev/null || echo "parse-fail"
}

# 연결된 **열린** PR 들 — "<번호><TAB><라벨 콤마목록>" 줄. 없으면 빈 출력(정상).
list_mirror_prs() {  # list_mirror_prs <repo> <num>
  local out
  out=$(gh pr list --repo "$1" --state open --head "agent/issue-$2" \
    --json number,labels --limit 20 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.[] | [(.number|tostring), ([.labels[].name] | join(","))] | @tsv'
}

# 이슈의 **상태와 라벨**을 한 번에 — "<state><TAB><라벨 콤마목록>". 정지 미러 정리(④)가
# 쓴다. `read_labels` 와 나눠 둔 이유: 저쪽은 재개·승격의 readback 전용이라 열린 이슈만
# 보는데, ④ 는 **닫힌 이슈**도 대상이라(머지 없이 이슈만 닫는 경로) 상태를 함께 읽는다.
# 상태는 **판정에 쓰지 않는다** — CLOSED 라고 건너뛰면 그 PR 이 영영 안 정리된다. 이벤트에
# 실어 보고를 읽는 쪽이 "왜 이 PR 만 남아 있었나" 를 알게 하는 용도다.
read_labels_state() {  # read_labels_state <repo> <num>
  local out
  out=$(gh issue view "$2" --repo "$1" --json labels,state 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[(.state // ""), ([.labels[].name] | join(","))] | @tsv'
}

read_pr_labels() {  # read_pr_labels <repo> <pr>
  local out
  out=$(gh pr view "$2" --repo "$1" --json labels 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# ── PR 의 참조 이슈가 **열려 있나** — ③-b 의 축 판정 (#421) ──────────────────
# `closingIssuesReferences` 는 **닫힌 이슈도 계속 들고 있다**. 그래서 "참조가 있으면 이슈 축"
# 이라는 옛 판정은, 참조가 전부 닫힌 PR 을 **두 축 모두에서 빠뜨렸다** — 이슈 축은
# `gh issue list --state open` 이라 닫힌 이슈를 애초에 안 보고, PR 축은 참조가 있다고 접었다.
# 그래서 열림 여부를 직접 묻는다. 참조 하나라도 OPEN 이면 그 건은 이슈 축 소관(중복 금지)이고,
# 전부 CLOSED 면 사실상 PR 단독이다.
# 왜 목록 재사용이 아니라 건별 조회인가: 이 함수를 부르는 건 `hold:policy` 가 붙은 열린 PR
# 뿐이고(④ 가 같은 PR 들에 이미 `read_labels_state` 를 건별로 쓴다), 이슈 목록(③)은
# `--label hold:policy` 로 좁혀 있어 "열려 있지만 라벨이 없는 참조" 를 못 가른다.
# 조회 실패·미열거 상태는 `none` 으로 접지 않는다(이 파일의 규율) — return 1 로 호출부가 warn.
linked_open_state() {  # linked_open_state <repo> <참조 번호 공백목록> → open|closed / 조회 실패 1
  local repo="$1" nums="$2" n out st
  for n in $nums; do
    out=$(gh issue view "$n" --repo "$repo" --json state 2>/dev/null) || return 1
    st=$(printf '%s' "$out" | jq -r '.state // ""' 2>/dev/null) || return 1
    case "$st" in
      OPEN|open)     printf 'open'; return 0 ;;   # 하나라도 열려 있으면 더 볼 것 없다
      CLOSED|closed) ;;
      *)             return 1 ;;                  # 빈 값·미열거 상태 = 조회 실패와 같은 처분
    esac
  done
  printf 'closed'
}

# ── 라벨 **이력** — "붙은 적이 있나" 를 묻는 유일한 출처 (④ 의 양성 증거) ────────
# 현재 라벨(`read_labels_state`)은 *부재*만 말한다. 부재는 ⓐ 사람이 뗐다 ⓑ 기계가 뗐다
# ⓒ **애초에 못 붙었다** 를 구분하지 못하는데, ④ 가 편집해도 되는 것은 ⓐ·ⓑ 뿐이다.
# 이벤트 API 는 `labeled`/`unlabeled` 를 시각과 함께 주므로 그 셋이 갈린다.
# PR 의 라벨 이벤트도 **issues 엔드포인트**에 실린다(PR 은 이슈의 부분집합) — 그래서 한
# 함수가 양쪽을 본다.
# `--paginate` 와 `--jq` 를 함께 쓰면 페이지마다 필터가 돌고 줄이 누적된다. 파이프로
# 받지 않는 이유는 #139 — 파이프 중간 실패는 종료코드에 안 잡혀 **부분 출력이 정상값으로
# 채택**된다. 여기서 그러면 "이벤트가 없다"(=붙은 적 없음)로 오독해 fail-open 이 된다.
fetch_label_events() {  # fetch_label_events <repo> <번호> <출력파일> — 성공 0 / 조회 실패 1
  gh api "repos/$1/issues/$2/events" --paginate \
     --jq '.[] | select(.event == "labeled" or .event == "unlabeled")
           | [.event, (.label.name // ""), (.created_at // "")] | @tsv' \
     > "$3" 2>/dev/null || return 1
  return 0
}

# 가장 **늦은** 이벤트 시각(없으면 빈 값). 존재가 아니라 시각을 돌려주는 이유는 #225 —
# "존재 여부" 로 갈래를 세우면 같은 라벨이 두 번 붙었다 떨어진 이슈에서 옛 에피소드가
# 새 에피소드를 덮어 판정을 뒤집는다. 시각 비교는 "가장 늦은 것이 이긴다" 를 그대로 쓴다.
# 문자열 비교로 충분하다 — GitHub 의 시각은 `2026-09-11T12:00:00Z` 형태(UTC·고정 폭)라
# 사전순 = 시간순이다. 목록 순서에 기대지 않고 최대값을 고른다(API 순서는 계약이 아니다).
last_label_event_at() {  # last_label_event_at <파일> <labeled|unlabeled> <라벨>
  awk -F'\t' -v e="$2" -v l="$3" '$1 == e && $2 == l && $3 > t { t = $3 } END { if (t != "") print t }' "$1"
}

# ── PR 미러 해제 — 이슈 편집과 **같은 단계**에서 ──────────────────────────
# 이미 이슈 라벨을 고친 뒤에 부르므로 여기서의 실패는 전부 warn_after_edit 이다.
# 라벨을 하나도 안 달고 있는 PR 은 건드리지 않는다 — 레포에 없는 라벨을 remove 하면
# gh 가 편집 **전체**를 실패시키므로(실측), 불필요한 편집은 애초에 안 낸다.
mirror_labels() {  # mirror_labels <repo> <num> <resume|escalate>
  local repo="$1" num="$2" mode="$3" prs prnum prlabels back
  if ! prs=$(list_mirror_prs "$repo" "$num"); then
    emit_warn_after_edit "$repo" "$num" "연결 PR 조회 실패 — 이슈는 반영됐지만 PR 미러 라벨이 남았을 수 있다"
    return 0
  fi
  [ -n "$prs" ] || return 0   # 연결된 열린 PR 없음 = 정상(이슈만 고치면 된다)
  printf '%s\n' "$prs" | while IFS=$'\t' read -r prnum prlabels; do
    [ -n "$prnum" ] || continue
    if [ "$mode" = resume ]; then
      # `needs-human` 은 떼지 않는다(#244) — 사람이 PR 에 직접 세운 정지다.
      has_label "$prlabels" "hold:ladder" || continue
      if ! gh pr edit "$prnum" --repo "$repo" \
           --remove-label "hold:ladder" >/dev/null 2>&1; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 라벨 해제 실패 — PR 이 needs-human 으로 남는다"
        continue
      fi
      if ! back=$(read_pr_labels "$repo" "$prnum"); then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 조회 실패 — 반영 여부 미상"
        continue
      fi
      if has_label "$back" "hold:ladder"; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 불일치(정지 라벨이 남아 있다)"
      fi
    else
      has_label "$prlabels" "hold:ladder" || continue
      if ! gh pr edit "$prnum" --repo "$repo" \
           --add-label "hold:policy" --remove-label "hold:ladder" >/dev/null 2>&1; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 승격 실패 — PR 사유 라벨이 이슈와 어긋난다"
        continue
      fi
      if ! back=$(read_pr_labels "$repo" "$prnum"); then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 조회 실패 — 반영 여부 미상"
        continue
      fi
      if ! has_label "$back" "hold:policy" || has_label "$back" "hold:ladder"; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 불일치(hold:policy 부착·hold:ladder 해제 기대)"
      fi
    fi
  done
}

# ── 정지 미러 정리 (#265) — 사람이 이슈에서만 푼 홀드의 PR 사본을 뗀다 ──────
# 위 mirror_labels() 는 **이 스윕이 재개·승격할 때** 자기가 고친 이슈의 PR 을 함께 되돌린다
# — `hold:ladder` 자동 재개 경로 하나뿐이다. `hold:policy`·`hold:conflict` 는 정의상 사람이
# 푸는데, 그 경로에는 PR 사본을 되돌리는 자리가 어디에도 없었다. 남은 사본은 네 게이트
# (verify-eligible·closeout-eligible·claim-issue·eligible-issues)가 `hold:` 접두를 직접
# 보므로(#242·#262) 그 PR 을 확정적으로 제외하고, 이슈는 이미 깨끗해 needs-human 칸에도 안 뜬다.
#
# 전파 자리를 **여기 하나**로 정한 이유(이슈 #265 의 두 후보 중 (a)):
#   · 사람이 README 대로 이슈에서만 뗐을 때 **아무도 명령을 치지 않아도** 풀려야 한다.
#     `transition.sh human-resume`(후보 b)는 사람이 그 명령을 안다는 전제가 필요한데,
#     지금 관측된 실패가 바로 "사람이 README 만 보고 이슈만 건드린다" 이다.
#   · 이슈가 CLOSED 인 경로(머지 없이 이슈만 닫음)도 같은 한 자리에서 걷힌다.
#   · 재개·승격이 이미 PR 미러를 되돌리는 코드를 이 파일이 갖고 있어 규율(warn vs
#     warn_after_edit, readback)이 그대로 재사용된다.
#
# fail-safe 방향: 판정에 실패하면 **떼지 않는다**. 사람 게이트를 벗겨내는 쪽으로 틀리면
# #151 재현이다. 편집 **전** 실패는 warn(그대로 두면 다음 틱이 다시 본다), 편집 **후**
# 실패는 warn_after_edit(상태가 반쯤 바뀌었으니 사람이 본다) — 이 파일의 기존 구분 그대로.
#
# ★쌍둥이(`loop-status.sh` 의 정지 미러 warn)와 **같은 것**과 **다른 것**★
#   같다(후보 집합): 짝짓기 ⑴⑵ · 전건 게이트 ⑶ · 맨몸 `needs-human` 배제 ⑵-b.
#     — 경보가 교정보다 넓으면 "고쳐 준다" 고 말해 놓고 안 고치는 줄이 상시로 남고,
#       좁으면 교정이 몰래 돈다.
#   다르다(편집 전용): 양성 증거 ⑷(라벨 이벤트 이력). 경보는 **부재만으로도 참인 사실**
#     ("이슈는 깨끗한데 PR 에 정지가 남았다")을 말하고, 그 사실은 원인이 사람 해제든
#     전이 부분 실패든 **어느 쪽이어도 사람이 봐야 하는 좌초**다 — 부분 실패라면 그 줄이
#     곧 "멈춘 전이가 있다" 는 신고다. 반면 **떼는 것**은 원인이 사람 해제일 때만 옳으므로
#     증명을 요구한다. 그래서 이 비대칭은 의도다(경보 = 사실, 교정 = 증명). 이력 조회를
#     경보 쪽에 넣지 않는 실무적 이유도 있다: `loop-status.sh` 는 추가 `gh` 호출 0을
#     규율로 삼는 스냅샷이고, 여기 ⑷ 는 후보 PR 당 2회를 쓴다.
#
# ★짝짓기 규칙 — `loop-status.sh` 의 정지 미러 warn 과 **한 글자도 다르지 않아야 한다**★
# (경보와 교정의 대상 집합이 갈리면 한쪽이 거짓말을 한다). 짝으로 인정하는 조건 둘:
#   ⑴ head 가 `agent/issue-*` — 루프가 판 브랜치만. 사람이 연 `feat/*` PR 에 사람이 직접
#      붙인 `needs-human`·`hold:*` 를 루프가 떼면, 이 파일 ②갈래가 세운 규율("사유 없는
#      needs-human 은 사람이 붙였을 수 있으니 손대지 않는다")을 정면으로 어긴다.
#      `loop-status.sh` 의 무소속 warn 도 같은 경계로 좁혀 둔다(#188).
#   ⑵ `closingIssuesReferences` 로 **증명된** 링크 **이면서** head 의 `agent/issue-N` 의 그
#      `N` 이 그 목록 안에 있을 때만. head 를 *단독 출처*로 쓰지는 않는다(브랜치 이름은
#      "이 홀드가 이슈 #N 과 한 쌍으로 붙었다" 를 증명하지 못한다 — `Refs #N`(Closes 아님)
#      PR 은 전이가 `issue=-` 로 걸려 **PR 에만** 정지가 남는 것이 정상인데, head 로 이으면
#      그 정상 상태가 불일치로 둔갑해 사람 게이트를 벗겨낸다). 하지만 **교차 검증**에는
#      쓴다: `closingIssuesReferences[0]` 을 무조건 짝으로 쓰면 닫는 이슈가 둘 이상일 때
#      브랜치의 이슈가 아닌 쪽을 본다 — 이 레포 실데이터에 그 모양이 있다(PR #113
#      head=`agent/issue-109` refs=`[108,109]` — `[0]` 은 #108 이다). 둘의 교집합이라
#      `Refs` 전용 PR(refs 가 빔)은 종전대로 짝이 빈 값으로 떨어진다.
#      ①의 `list_mirror_prs`(head 기준)와 규칙이 다른 것은 의도다: 저쪽은 **이 스윕이 방금
#      되돌린 이슈**의 PR 이라 짝이 스윕 자신의 행동으로 정해져 있다.
#   ⑶ 편집은 **`closes` 전건이 정지 라벨 0개일 때만**. 짝 인정만으로는 묶음 디스패치가
#      안 닫힌다 — `Closes #A`·`Closes #B` 를 단 PR 에 전이는 이슈 인자를 하나만 받으므로
#      (`transition.sh`) 정지가 #B 에만 붙을 수 있고, 짝이 #B 로 잡혀도 #A 만 보면 샌다.
#      짝(⑵)은 그래서 "무엇을 볼까" 가 아니라 메시지·이벤트의 **대표 번호**다.
#   ⑵-b PR 의 정지 라벨에 `hold:` 접두가 **하나도 없으면**(맨몸 `needs-human`) 떼지 않는다 —
#      기계가 만들 수 없는 모양이라 사람이 붙인 것이다. 근거는 `sweep_hold_mirror` 안의 주석.
#   ⑷ 그리고 **양성 증거**: 이슈의 마지막 `unlabeled L` 이 PR 의 마지막 `labeled L` 보다
#      늦어야 한다. 부재(라벨이 없다)는 "사람이 뗐다" 와 "전이가 부분 실패해 애초에 못
#      붙었다" 를 구분하지 못한다 — 상세는 같은 함수 안의 ⑷ 주석.
# ⑴⑵ 중 하나라도 아니면 이슈 칸이 빈 값으로 나가고, 호출부가 그대로 넘긴다(무편집·무이벤트).
mirror_row() {  # mirror_row <PR row-json> — "<PR><TAB><짝 이슈|빈값><TAB><closes 공백목록><TAB><정지라벨 공백목록>"
  printf '%s' "$1" | jq -r '
    [.labels[]?.name] as $ln
    | [((.closingIssuesReferences // [])[].number)] as $closes
    | (if ((.headRefName // "") | test("^agent/issue-[0-9]+"))
       then ((.headRefName | capture("^agent/issue-(?<n>[0-9]+)").n | tonumber)) else null end) as $hn
    | (if $hn != null and (($closes | index($hn)) != null) then ($hn | tostring) else "" end) as $issue
    | [(.number|tostring), $issue, ($closes | map(tostring) | join(" ")),
       ($ln | map(select(. == "needs-human" or startswith("hold:"))) | sort | join(" "))]
    | @tsv' 2>/dev/null
}

# ── ④-r 증거 부재의 **재시도 주체** (#397) ─────────────────────────────────────
# ④ 의 양성 증거 게이트(⑷)는 증거를 못 얻으면 떼지 않고 warn 만 냈다. 그 warn 을 다음 틱에
# 다시 시도하는 주체가 없어 불일치가 영구히 남고 **매 틱 같은 줄**이 반복됐다(#397 배경).
# 여기서 회차를 세어 ⑴ 진행이 보이게 하고(`N/상한`) ⑵ 상한에 닿으면 사람 몫으로 올린다.
#
# 회차의 SSOT 는 **이슈 코멘트에 붙은 마커**(`<!-- mirror-retry: <사유> pr=<n> -->`)의 개수다 —
# `ladder-resume` 과 같은 규약이고 같은 이유다: 상태 파일을 만들지 않고, 본문을 쓰지 않으며
# (남의 글을 덮어쓰지 않는다), append-only 라 경합에 안전하다. 본문 카운터는 산문 전용이라
# 쓰지 않는다.
#
# 상한 도달은 **이벤트만** 낸다(`mirror_retry_exhausted`) — 전이(`runner-held`)는 SKILL 이
# 건다. 이 파일의 규율 그대로다: 스크립트는 판정하지 않고 이벤트/계급만 낸다.
# 상한 뒤에는 마커를 더 쌓지 않으므로 그 전이가 걸릴 때까지 같은 이벤트가 반복되고, 걸리면
# 이슈에 정지 라벨이 생겨 ⑶ 가 먼저 막는다(자연 종료).
#
# 조회·게시 실패는 회차를 올리지 않는다 — 회차를 못 기록한 채 올리면 상한이 조용히 앞당겨진다.
# 회차 카운트 — **이 PR 의, 이번 에피소드의** 마커만 센다(#397 리뷰 P2-2).
# 마커에 번호가 없고 경계도 없으면 ⑴ 한 이슈에 걸린 **다른 PR** 의 회차가 섞이고 ⑵ 한 번
# 3회를 채워 사람이 풀어 준 뒤 같은 이슈에 **새 불일치**가 생기면 첫 틱에 바로 상한이 난다
# (옛 마커를 물려받는다). 그래서 마커에 `pr=<n>` 을 싣고, **사람이 개입한 경계**
# (마지막 `<!-- policy-review: … -->` 또는 `<!-- hold-note: … -->` 코멘트) **이후**의 것만 센다 —
# 그 두 마커는 정지/재심이 한 번 돌았다는 뜻이라 그 앞은 지난 에피소드다.
# 판별선은 `bounce-state.sh`·`policy_review_state` 와 같은 **마지막 매칭 인덱스** 규율이다
# (존재가 아니라 위치 — 같은 축이 두 번 도는 이슈에서 옛 에피소드가 새 판정을 덮지 않게).
count_mirror_retry() {  # count_mirror_retry <repo> <이슈> <PR> → 개수 / 조회 실패 return 1
  local out
  out=$(fetch_comments "$1" "$2") || return 1
  printf '%s' "$out" | jq -r --arg pr "$3" "$JQ_UNQUOTE"'
    [.[]? | .body | unquoted] as $b
    | ([range(0; $b|length)]
       | map(select($b[.] | test("<!--\\s*(policy-review|hold-note):"))) | last) as $q
    | (if $q == null then 0 else $q + 1 end) as $from
    | [range($from; $b|length)]
      | map(select($b[.] | test("<!--\\s*mirror-retry:[^>]*pr=" + $pr + "\\s*-->")))
      | length'
}

mirror_retry() {  # mirror_retry <repo> <이슈> <PR> <사유 한 줄>
  local repo="$1" issue="$2" prnum="$3" reason="$4" n body
  if ! n=$(count_mirror_retry "$repo" "$issue" "$prnum"); then
    emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — $reason · 재시도 회차 조회 실패, 이번 틱은 넘긴다"
    return 0
  fi
  _json_int "${n:-}" || n=0
  if [ "$n" -ge "$MIRROR_RETRY_LIMIT" ]; then
    printf '{"event":"mirror_retry_exhausted","repo":"%s","number":%s,"pr":%s,"attempts":%s,"limit":%s}\n' \
      "$repo" "$(_emit_num "$issue")" "$(_emit_num "$prnum")" "$(_emit_num "$n")" "$(_emit_num "$MIRROR_RETRY_LIMIT")"
    return 0
  fi
  # 마커는 코멘트가 **스스로 품는다** — 카운터와 알림이 한 번의 append 로 끝난다(재개 코멘트 동형).
  # 마커에 **PR 번호**가 든다(위 count_mirror_retry 주석) — 세는 자리와 쓰는 자리가 한 짝이다.
  body=$(printf '정지 미러 재시도 %s/%s: PR #%s — %s\n<!-- mirror-retry: %s pr=%s --><!-- bodat:worker -->' \
    "$((n + 1))" "$MIRROR_RETRY_LIMIT" "$prnum" "$reason" "$reason" "$prnum")
  if ! gh issue comment "$issue" --repo "$repo" --body "$body" >/dev/null 2>&1; then
    emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — $reason · 재시도 마커 코멘트 실패(회차 미기록)"
    return 0
  fi
  emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — $reason (재시도 $((n + 1))/$MIRROR_RETRY_LIMIT)"
}

# ── ③-b PR 단독 `hold:policy` 재심 (#395) ──────────────────────────────────────
# `verify-held`·`closeout-blocked` 는 `<issue>` 자리에 `-` 를 받아 **연결 이슈가 없어도** PR 에
# `hold:policy` 를 붙인다. 그런데 ③ 은 **이슈 목록**에서 출발하므로 그 홀드는 재심(#155)에
# 영영 안 오르고 사람이 눈으로 찾을 때까지 남는다(`references/state-machine.md` 회수 열).
# 그래서 ④ 와 같은 **열린 PR 축**에서 한 번 더 본다 — 목록은 `fetch_open_prs` 한 조회를 공유한다.
#
# 판정은 이슈 축과 **같은 자리**를 쓴다(`policy_window_min`·`policy_review_state`) — 축마다
# 다른 판정을 두면 같은 형상이 어느 축에 걸리느냐로 갈린다. 다른 것은 두 가지뿐이다:
#   ⑴ **열린 연결 이슈가 있으면 내지 않는다** — 그 건은 이슈 축이 이미 낸다(중복 이벤트 금지).
#      참조가 **전부 닫힌** PR 은 이슈 축(열린 이슈 목록)이 못 보므로 여기서 본다(#421 — 옛
#      판정은 참조 **개수**만 봐서 그 형상을 두 축 모두에서 빠뜨렸다). 판정은 `linked_open_state`.
#   ⑵ 마커·라벨을 PR 에서 읽는다(`transition.sh` 가 질문 코멘트를 PR 에도 남기므로 가능하다).
# 배포 대기(deploy-wait) 갈래는 여기 없다 — 그 라벨은 이슈 축의 것이고, PR 단독 홀드에는
# 붙는 자리가 없다(붙으면 그때 이슈 축이 본다).
# 무편집 갈래다 — 이벤트만 낸다(재심 코멘트·해제는 디스패처 ①).
sweep_pr_policy() {  # sweep_pr_policy <repo> <열린 PR row-json>
  local repo="$1" row="$2" tsv prnum pupd labels closes lstate pmin pout pstate pcur
  # 넷째 칸은 참조 **번호 목록**이다(옛 개수 대신) — 열림 여부를 물어야 축이 갈린다(#421).
  tsv=$(printf '%s' "$row" | jq -r '
    [(.number|tostring), (.updatedAt // ""),
     ([.labels[]?.name] | join(",")),
     ([((.closingIssuesReferences // [])[].number | tostring)] | join(" "))] | @tsv' 2>/dev/null) || tsv=""
  if [ -z "$tsv" ]; then
    emit_warn "$repo" 0 "열린 PR 행 파싱 실패 — PR 단독 재심 판정 못 해 건드리지 않는다"
    return 0
  fi
  prnum=$(printf '%s' "$tsv" | cut -f1)
  pupd=$(printf '%s' "$tsv" | cut -f2)
  labels=$(printf '%s' "$tsv" | cut -f3)
  closes=$(printf '%s' "$tsv" | cut -f4)

  has_label "$labels" "hold:policy" || return 0   # 대다수 PR — 조회도 하지 않는다
  # ⑴ 참조가 있으면 **열려 있는 것이 하나라도 있는지** 를 묻고 그때만 이슈 축에 넘긴다(#421).
  #    참조 0개는 조회 없이 PR 단독이다(종전 경로 — 왕복 증가 없음).
  if [ -n "$closes" ]; then
    if ! lstate=$(linked_open_state "$repo" "$closes"); then
      emit_warn "$repo" 0 "PR #$prnum 연결 이슈 상태 조회 실패 — 어느 축 소관인지 확정 못 해 재심을 내지 않는다"
      return 0
    fi
    [ "$lstate" = closed ] || return 0            # 열린 참조가 있다 → 이슈 축만(중복 금지)
  fi
  # `needs-human` 동존은 **사람이 직접 세운 정지**다(#244) — 이슈 축과 같은 낱말, 같은 처분.
  if has_label "$labels" "needs-human"; then
    emit_note "$repo" 0 "PR #$prnum 사람이 세운 needs-human 동존 — 재심 안 함, 정상 상태라 warn 아님"
    return 0
  fi
  pmin=$(policy_window_min "$pupd") \
    || { emit_warn "$repo" 0 "PR #$prnum updatedAt 해석 불가($pupd) — 재심 창 판정 못 함"; return 0; }
  [ "$pmin" -ge "$RESUME_AFTER_MIN" ] || return 0
  pout=$(fetch_comments "$repo" "$prnum") \
    || { emit_warn "$repo" 0 "PR #$prnum 재심 마커 조회 실패 — 이번 틱은 건너뛴다"; return 0; }
  pstate=$(policy_review_state "$pout")
  case "$pstate" in
    reviewed) return 0 ;;
    no-note)
      emit_warn "$repo" 0 "PR #$prnum hold:policy 인데 질문(hold-note) 코멘트가 없다 — 재심 불가, --note 로 다시 걸거나 사람이 처리"
      return 0 ;;
    due) ;;
    *) emit_warn "$repo" 0 "PR #$prnum 재심 마커 해석 실패 — 이번 틱은 건너뛴다"; return 0 ;;
  esac
  # due 직전 **재조회**로 최종 판정(#351 과 같은 규율) — 목록 스냅샷은 그 뒤에 사람이 붙인
  # 정지도, 사람이 방금 푼 홀드도 모른다. 재조회 실패는 "없음" 으로 폴백하지 않는다.
  if ! pcur=$(read_pr_labels "$repo" "$prnum"); then
    emit_warn "$repo" 0 "PR #$prnum 재조회 실패(라벨) — needs-human 동존 여부를 확정 못 해 재심을 내지 않는다"
    return 0
  fi
  if has_label "$pcur" "needs-human"; then
    emit_note "$repo" 0 "PR #$prnum 사람이 세운 needs-human 동존 — 재심 안 함, 정상 상태라 warn 아님"
    return 0
  fi
  has_label "$pcur" "hold:policy" || return 0   # 사람이 방금 풀었다 — 재심 대상이 아니다
  # PR 단독은 사람 몫으로 귀결(#395) — 디스패처 ① 은 이 축에서 재개(`verify-redispatch <repo> - <pr>`)를
  # 부르지 않는다. 그 전이는 PR 에 `flow:agent-ready` 만 남기는데 `eligible-issues.sh` 는 이슈만,
  # `verify-eligible.sh` 는 `flow:verify`·`verifying` 만 집어 **소비자가 없다**(#421). verify-runner ④ 도
  # "연결 이슈 부재" 를 사람 칸으로 못박았다 — 그래서 이 이벤트의 처분은 `policy-kept` 뿐이다.
  # (스크립트는 여전히 판정하지 않는다 — 이벤트만 낸다. 처분 전문은 SKILL ① 의 `policy_review_due`.)
  printf '{"event":"policy_review_due","repo":"%s","number":null,"pr":%s,"minutes":%s}\n' \
    "$repo" "$(_emit_num "$prnum")" "$pmin"
}

sweep_hold_mirror() {  # sweep_hold_mirror <repo> <PR row-json>
  local repo="$1" row="$2" tsv prnum issue closes stops cn st st2 istate ilabels lab removed back
  local at_off at_on
  local args=()

  tsv=$(mirror_row "$row") || tsv=""
  if [ -z "$tsv" ]; then
    emit_warn "$repo" 0 "열린 PR 행 파싱 실패 — 정지 미러 판정 못 해 건드리지 않는다"
    return 0
  fi
  prnum=$(printf '%s' "$tsv" | cut -f1)
  issue=$(printf '%s' "$tsv" | cut -f2)
  closes=$(printf '%s' "$tsv" | cut -f3)
  stops=$(printf '%s' "$tsv" | cut -f4)

  [ -n "$stops" ] || return 0   # 정지 라벨이 없는 PR = 정상(대다수) — 조회도 하지 않는다
  # 짝이 없다(사람 세션 PR · Closes 링크 없는 PR · 브랜치의 N 이 닫는 목록에 없는 PR).
  # 근거는 위 짝짓기 규칙 주석 — 셋 다 "PR 에만 정지가 남는 것이 정상일 수 있는" 상태라
  # 대조가 성립하지 않는다.
  [ -n "$issue" ] || return 0

  # ── ⑵-b 맨몸 `needs-human` 은 **기계가 만들 수 없는 모양**이다 → 떼지 않는다 ──────
  # `needs-human` 을 붙이는 자리는 `transition.sh` 하나뿐이고(레포 전수: 다른 스크립트의
  # `--add-label needs-human` 은 0건), 기계 정지 세 전이(verify-held·closeout-blocked·
  # runner-held)는 `--reason` 이 **필수**라 언제나 `hold:<사유>` 와 **쌍으로만** 붙인다
  # (사유 없는 `needs-human` 은 usage 로 거절 — `transition.sh` 의 사유 검증 블록).
  # 그러므로 **PR 에 `hold:*` 없이 `needs-human` 만 있다 = 사람이 손으로 붙였다**.
  # 이 파일 ②갈래가 이슈에 대해 세운 규율("사유 없는 needs-human 은 사람이 붙였을 수
  # 있으니 손대지 않는다")을 PR 쪽에도 **같은 이유로** 적용한다. 안 그러면 사람이 머지
  # 직전에 PR 에만 세운 브레이크(`closeout-eligible.sh` 의 유일한 제동)를 루프가 떼고,
  # SKILL 이 `mirror_cleared` 를 "이번 틱부터 후보로 돌아온다" 로 읽어 **적극적으로**
  # 머지로 민다. #244 이후에도 성립한다 — 그 PR 의 `policy-kept` 는 `hold:policy` 를
  # 남긴 채 `needs-human` 을 더하므로 맨몸 모양을 만들지 않는다.
  # 정상 정리 경로는 한 칸도 안 잃는다: 기계 미러는 전부 `hold:*` 를 동반한다.
  case " $stops " in
    *" hold:"*) ;;
    *)
      emit_warn "$repo" "$issue" \
        "PR #$prnum 정지 미러 — needs-human 사유 없음(hold:* 부재), 사람이 붙였을 수 있어 떼지 않는다"
      return 0 ;;
  esac

  # ⑶ `closes` **전건**을 읽어 하나라도 정지가 살아 있으면 무편집. 대다수 PR 은 closes 가
  # 한 건이라 조회 수는 종전과 같다(묶음 디스패치일 때만 늘어난다).
  istate=""
  for cn in $closes; do
    if ! st=$(read_labels_state "$repo" "$cn"); then
      emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — 연결 이슈 #$cn 라벨 조회 실패, 판정 못 해 떼지 않는다"
      return 0
    fi
    ilabels=${st#*$'\t'}
    # 이슈에 정지 라벨이 **하나라도** 남아 있으면 사람 게이트가 살아 있다 — 무편집.
    has_stop "$ilabels" && return 0
    # 이벤트에 싣는 상태는 **짝**의 것이다(대표 번호와 짝이 맞아야 한다).
    [ "$cn" = "$issue" ] && istate=${st%%$'\t'*}
  done

  # ── ⑷ **양성 증거** — "사람이 풀었다" 를 부재가 아니라 이력으로 증명한다 ──────────
  # 여기까지의 판정(⑶)은 전부 *부재*다: 이슈에 정지 라벨이 없다. 그런데 부재는 ⓐ 사람이
  # 뗐다 ⓑ 기계가 뗐다 ⓒ **애초에 못 붙었다** 를 구분하지 못하고, ⓒ 는 가설이 아니라
  # `transition.sh` 의 적용 순서가 **만들어 내는 실재 상태**다 — 그 파일은 PR 을 먼저,
  # 이슈를 나중에 편집하므로(`run_edit pr` → `run_edit issue`, 그 사이 실패는 exit 2),
  # 이슈 편집이 502·레이트리밋으로 실패하면 남는 상태가 **PR 에만 정지, 이슈엔 없음** 이다.
  # 그 칸은 ⓐ 와 라벨만 보면 글자 하나까지 같고, 그대로 떼면 **살아 있는 홀드를 기계가
  # 벗긴다** — 이 갈래가 막으려던 것의 정반대 방향이다. 게다가 `verify-held`·
  # `closeout-blocked` 는 그 시점에 PR 의 **단계 라벨까지 이미 뗀** 뒤라(전이표 `pr_rm`),
  # 정지마저 빠지면 PR 에 라벨이 하나도 안 남아 `verify-eligible`(flow:verify)도
  # `closeout-eligible`(harvesting·✅)도 그 PR 을 못 집는 **좌초**가 된다. 호출부의 복구는
  # "다음 틱에 같은 전이를 다시 건다" 인데, 그 재시도의 전제인 '반쯤 이동한 라벨' 을
  # 스윕이 지워 복구 경로 자체가 사라진다.
  #
  # 갈리는 신호는 **라벨 이벤트 이력**이다. PR 에 남은 정지 라벨 L 각각에 대해:
  #   · 이슈의 마지막 `unlabeled L` 이 PR 의 마지막 `labeled L` **보다 늦다** → 이 사본이
  #     붙은 뒤에 누군가 이슈에서 L 을 뗐다(ⓐ·ⓑ) = 교정 대상.
  #   · `unlabeled L` 이 아예 없다 → 이슈는 L 을 **한 번도 받은 적이 없다**(ⓒ).
  #   · 있지만 더 이르다 → **옛 에피소드**의 해제다. 같은 PR 이 두 번 홀드되면 이 모양이
  #     ⓒ 를 ⓐ 로 위장한다 — 그래서 존재가 아니라 시각을 비교한다(#225: 가장 늦은 것이 이긴다).
  # 조회 실패·증거 없음·시각 역전은 전부 **무편집 + warn**(이 갈래 전체와 같은 fail-safe
  # 방향). 부분 실패의 재시도가 이슈에 라벨을 마저 붙이면 ⑶ 가 먼저 막으므로 이 warn 은
  # 그 틱으로 끝난다 — 상시 잡음이 아니다.
  # 대조 대상은 **짝**의 이력이다(정지를 붙인 전이가 이슈 인자로 받는 것이 그 번호다).
  if ! fetch_label_events "$repo" "$issue" "$tmp/mirror.issue.events"; then
    emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — 이슈 #$issue 라벨 이력 조회 실패, 해제를 증명 못 해 떼지 않는다"
    return 0
  fi
  if ! fetch_label_events "$repo" "$prnum" "$tmp/mirror.pr.events"; then
    emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 — PR 라벨 이력 조회 실패, 해제를 증명 못 해 떼지 않는다"
    return 0
  fi
  for lab in $stops; do
    at_off=$(last_label_event_at "$tmp/mirror.issue.events" unlabeled "$lab")
    at_on=$(last_label_event_at "$tmp/mirror.pr.events" labeled "$lab")
    # 증거를 못 얻은 세 갈래는 **상한 있는 재시도**로 간다(#397) — 떼지 않는 것은 그대로고,
    # 회차가 warn 문구에 실리며 상한에 닿으면 `mirror_retry_exhausted` 로 사람 몫이 된다.
    # (위 두 `fetch_label_events` 실패는 여기 들지 않는다 — 그건 일시적 조회 실패라 다음 틱이
    #  저절로 다시 묻는 축이고, 회차를 세면 gh 가 흔들린 날에 사람 정지가 만들어진다.)
    if [ -z "$at_off" ]; then
      mirror_retry "$repo" "$issue" "$prnum" \
        "이슈 #$issue 의 $lab: 붙었다 떨어진 이력이 없다(전이 부분 실패 의심) — 떼지 않는다"
      return 0
    fi
    if [ -z "$at_on" ]; then
      mirror_retry "$repo" "$issue" "$prnum" \
        "PR 의 $lab: 붙은 이력이 없다(이력 미상) — 떼지 않는다"
      return 0
    fi
    if [[ ! "$at_off" > "$at_on" ]]; then
      mirror_retry "$repo" "$issue" "$prnum" \
        "이슈 #$issue 의 $lab 해제($at_off)가 PR 부착($at_on)보다 이르다(옛 에피소드) — 떼지 않는다"
      return 0
    fi
  done

  # 레포에 없는 라벨은 `--remove-label` 도 편집 **전체**를 실패시킨다(transition.sh:67) —
  # PR 이 실제로 달고 있는 것만 싣는다.
  for lab in $stops; do
    args+=(--remove-label "$lab")
    removed="${removed:+$removed,}$lab"
  done
  if ! gh pr edit "$prnum" --repo "$repo" ${args[@]+"${args[@]}"} >/dev/null 2>&1; then
    emit_warn "$repo" "$issue" "PR #$prnum 정지 미러 해제 실패 — 다음 틱 재시도"
    return 0
  fi
  if ! back=$(read_pr_labels "$repo" "$prnum"); then
    emit_warn_after_edit "$repo" "$issue" "PR #$prnum 정지 미러 readback 조회 실패 — 반영 여부 미상"
    return 0
  fi
  if has_stop "$back"; then
    emit_warn_after_edit "$repo" "$issue" "PR #$prnum 정지 미러 readback 불일치(정지 라벨이 남아 있다)"
    return 0
  fi
  # ── 경합 가드 — **편집 뒤** 이슈를 한 번 더 읽는다 ─────────────────────────
  # `transition.sh` 는 **PR 을 먼저, 이슈를 나중에** 편집한다(그 파일의 전이 순서). 그래서
  # 기계 정지가 막 걸리는 중이면 "PR 엔 이미 붙었고 이슈엔 아직" 인 창이 존재하고, 그 창에
  # 들어오면 이 갈래가 **방금 붙은 정지를** PR 에서 도로 떼어 낸다. 편집 **전** 재조회로는
  # 이 창을 못 닫는다 — 그 시점엔 이슈가 정말로 깨끗하기 때문이다(sweep_issue 의 경합
  # 가드가 반대 방향의 경합만 잡는 것과 같은 한계). 그래서 뒤에서 한 번 더 읽어, 정지가
  # 생겼으면 `mirror_cleared` 로 위장하지 않고 사람이 보게 한다.
  # 되붙이지는 않는다: 라벨을 **붙이는** 것은 transition.sh 의 몫이고(이 갈래는 해제 방향
  # 전용), 그쪽은 자기 readback 으로 이미 실패를 외친다.
  # 편집 전(⑶)과 **같은 집합**을 다시 읽는다 — 짝만 다시 읽으면 묶음 디스패치에서 경합이
  # 딴 closes 이슈에 걸렸을 때 그대로 성공으로 접힌다.
  for cn in $closes; do
    if ! st2=$(read_labels_state "$repo" "$cn"); then
      emit_warn_after_edit "$repo" "$issue" "PR #$prnum 정지 미러 해제 후 이슈 #$cn 재조회 실패 — 경합 여부 미상"
      return 0
    fi
    if has_stop "${st2#*$'\t'}"; then
      emit_warn_after_edit "$repo" "$issue" "PR #$prnum 정지 미러 해제 뒤 이슈 #$cn 에 정지 라벨이 생겼다(기계 정지와 경합) — 사람 확인 필요"
      return 0
    fi
  done
  # 상태는 GitHub 에서 온 문자열이라 그대로 JSON 에 박지 않는다 — 아는 값만 싣는다
  # (모르는 값이면 빈 문자열. 이 파일의 _json_int·_json_token 과 같은 규율).
  case "$istate" in OPEN|CLOSED) ;; *) istate="" ;; esac
  printf '{"event":"mirror_cleared","repo":"%s","number":%s,"pr":%s,"issue_state":"%s","removed":"%s"}\n' \
    "$repo" "$(_emit_num "$issue")" "$(_emit_num "$prnum")" "$istate" "$removed"
}

rc=0

# ── 이슈 1건 처리 (재개 대상 = hold:ladder ∧ ¬needs-human ∧ ¬deploy-wait, #217·#244) ──
# 세 조건 모두 **편집 직전 재조회(read_state)** 결과로 판정한다 — 목록 스냅샷(row)은 그 뒤에
# 붙은 라벨을 모른다(#229). row 는 창 판정(updatedAt)과 파싱 가능성 검사에만 쓴다.
sweep_issue() {  # sweep_issue <repo> <이슈 JSON 한 줄>
  local repo="$1" row="$2"
  local num updated row_tsv then_epoch elapsed attempts next cur back live_updated dw_tsv dwlabel

  # 한 번의 jq 로 둘 다 뽑는다 — 큰 레포에선 이 함수가 이슈 수만큼 돌아, 필드마다
  # 프로세스를 띄우면 조회보다 파싱이 더 비싸진다.
  row_tsv=$(printf '%s' "$row" | jq -r '[(.number|tostring), (.updatedAt // "")] | @tsv')
  num=${row_tsv%%$'\t'*}
  updated=${row_tsv#*$'\t'}

  then_epoch=$(to_epoch "$updated")
  if [ -z "$then_epoch" ]; then
    emit_warn "$repo" "$num" "updatedAt 해석 불가($updated) — 창 판정 못 해 건드리지 않는다"
    return 0
  fi
  elapsed=$(( (now_epoch - then_epoch) / 60 ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  if [ "$elapsed" -lt "$RESUME_AFTER_MIN" ]; then
    # SKILL 은 이 이벤트를 보고하지 않지만(조용히 넘긴다) **내보내는 것 자체가 계약**이다 —
    # "창 안이라 안 건드렸다" 와 "대상이 아예 없었다" 를 구분하는 유일한 신호라, 사람이
    # 스윕을 손으로 돌려 디버깅할 때·앞으로 loop-status 가 세게 될 때 이 줄이 근거다.
    printf '{"event":"waiting","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$(_emit_num "$num")" "$elapsed"
    return 0
  fi

  # ── 배포 대기 축 — 창이 지나도 재개·승격 대상이 아니다(#217) ──────────────
  # #5040 실측: 같은 실행에서 이 이슈가 `resumed`(여기)와 배포 대기 `note`(②)를 동시에
  # 냈다 — 판정(②)은 배포 대기임을 알고 쓰기(여기)는 몰랐던 것이 근본 원인이다. ②·③ 과
  # **같은 술어**(deploy_wait_row, 위 정의)를 **같은 row**(이미 들고 있다 — 추가 조회 없음)
  # 에 적용해 답을 하나로 모은다. hold:ladder 만 보고 있으니 이 이슈는 애초에 ② 의 "hold:*
  # 없음" 가드를 안 타 note 가 안 나왔다 — 그 note 를 여기서 대신 낸다(중복 없이, 갈래를
  # 옮길 뿐). 상한 소진 여부와 무관하게 여기서 먼저 걸러지므로 승격(escalate) 갈래도
  # 같은 제외를 받는다(요청 ③) — 아래로 내려가는 코드 경로 자체가 없다.
  # 판정 자체가 실패(row 가 예상 모양이 아님 등)하면 "배포 대기 아님" 으로 폴백하지
  # 않는다 — 그건 이 함수가 fail-open 이 되어 정확히 이 이슈가 막으려는 사고(사람 게이트를
  # 조용히 벗겨내는 것)를 판정 실패 경로에서 재현한다(사전 리뷰 지적). rc 로 조회 실패와
  # 빈 결과(배포 대기 아님)를 가른다 — 이 파일이 read_state 등에서 이미 쓰는 규율과 같다.
  #
  # **축의 답은 여기서 내지 않는다(#229).** row 는 목록을 뜬 시점의 스냅샷이라 그 뒤에 붙은
  # `deploy-wait` 을 모른다 — 기본 창(RESUME_AFTER_MIN=120)에선 라벨이 붙는 순간 updatedAt 이
  # 갱신돼 위 창 게이트가 **우연히** 경합을 막아 줬지만, 창을 0 으로 두고 돌리면(디버깅·강제
  # 재개; `_nonneg_int` 가 0 을 정상값으로 받는다) 그 우연이 사라져 낡은 row 만 보는 제외가
  # 사람 게이트를 그대로 벗겨낸다. 반대로 row 에는 있었지만 사람이 티켓을 닫고 방금 뗀 경우를
  # row 를 이유로 막으면 반대 방향의 영구 정체다. 그래서 답은 **편집 직전 재조회(cur)** 가
  # 낸다(아래). 여기서는 row 가 **파싱 가능한 모양인지만** rc 로 본다 — 같은 row 에서
  # number·updatedAt 을 이미 뽑아 쓴 터라, 이 row 가 깨졌다는 것은 이 이슈에 대한 스냅샷
  # 전체를 믿을 수 없다는 뜻이고 그때는 아무것도 쓰지 않는다(fail-closed 유지).
  if ! deploy_wait_row "$row" >/dev/null; then
    emit_warn "$repo" "$num" "배포 대기 판정 실패(라벨 파싱) — 재개 대상인지 확정 못 해 건드리지 않는다"
    return 0
  fi

  # ── 편집 직전 재조회(경합 가드) ───────────────────────────────────────
  # 목록 조회와 편집 사이에 사람이 hold:ladder 를 뗐을 수 있다. 그 경우 편집은 **성공**
  # 하고(없는 라벨 제거는 no-op) 편집 후 readback 도 기대와 똑같아 보인다 — 사후
  # readback 만으로는 이 경합을 절대 구분 못 한다. 그래서 편집 **전에** 한 번 더 읽는다.
  if ! cur=$(read_state "$repo" "$num" "$tmp/updated.live"); then
    emit_warn "$repo" "$num" "재조회 실패(라벨·updatedAt) — 경합 판별 불가라 건드리지 않는다"
    return 0
  fi
  if ! has_label "$cur" "hold:ladder"; then
    emit_warn "$repo" "$num" "재조회 시 hold:ladder 가 이미 없다(사람 조작 경합) — 자동 재개 안 함"
    return 0
  fi
  # ── 배포 대기 축 판정 — **재조회 결과**에 같은 술어를 적용한다(#229) ───────
  # ②·③·위 row 게이트와 같은 한 벌 술어(deploy_wait_row)를 쓰되, `read_state` 가 내는
  # 콤마 목록 모양만 어댑터(deploy_wait_labels, 위 정의)로 맞춘다. 재조회 술어(hold:ladder)
  # 뒤에 두는 이유: 배포 대기 여부는 "이 건을 건드릴 것인가" 의 마지막 갈림길이고, 그 앞에서
  # 이미 떨어진 건(사람이 라벨을 뗀 경합)에 note 를 내면 "손대지 않았다" 의 이유가 어긋난다.
  # 판정 실패는 "배포 대기 아님" 으로 폴백하지 않는다 — row 쪽(위)과 같은 방향, 같은 이유.
  if ! dw_tsv=$(deploy_wait_labels "$cur"); then
    emit_warn "$repo" "$num" "배포 대기 재판정 실패(재조회 라벨 파싱) — 재개 대상인지 확정 못 해 건드리지 않는다"
    return 0
  fi
  dwlabel=${dw_tsv#*$'\t'}
  if [ -n "$dwlabel" ]; then
    # 문구는 ②·③ 과 **한 글자도 다르지 않게** 재사용한다 — 디스패처 SKILL 이 문구로 분기한다.
    emit_note "$repo" "$num" "배포 대기(라벨 $dwlabel) — 배포 레인의 정상 상태라 warn 아님"
    return 0
  fi
  # `hold:ladder` 옆에 사람 몫 사유가 함께 붙어 있으면 자동 재개 대상이 아니다 — 사다리는
  # 재시도로 풀려도 conflict·policy 는 안 풀리는데, 라벨을 떼면 그 사람 몫이 조용히 사라진다.
  if has_label "$cur" "hold:policy" || has_label "$cur" "hold:conflict"; then
    emit_warn "$repo" "$num" "hold:ladder 외 사람 몫 hold:* 동존 — 자동 재개 안 함"
    return 0
  fi
  # `needs-human` 은 **사람이 직접 세운 정지**다(#244). 창이 지나도 루프가 풀지 않는다 —
  # 그리고 라벨을 떼지도 않으므로, 재개하면 hold:ladder 만 치우고 needs-human 이 남아
  # 게이트(#242)는 계속 막는데 재개 횟수만 소진되는 "재개했는데 안 풀리는" 상태가 된다.
  if has_label "$cur" "needs-human"; then
    emit_warn "$repo" "$num" "사람이 세운 needs-human 동존 — 자동 재개 안 함"
    return 0
  fi
  # 창 재판정 — 스냅샷 이후 사람이 이슈를 건드렸으면 그 시각이 새 기준이다(스펙의 시계는
  # "마지막 갱신" 이지 "우리가 목록을 뜬 시각" 이 아니다).
  live_updated=$(cat "$tmp/updated.live" 2>/dev/null)
  if [ -n "$live_updated" ] && [ "$live_updated" != "$updated" ]; then
    then_epoch=$(to_epoch "$live_updated")
    if [ -n "$then_epoch" ]; then
      elapsed=$(( (now_epoch - then_epoch) / 60 ))
      [ "$elapsed" -lt 0 ] && elapsed=0
      if [ "$elapsed" -lt "$RESUME_AFTER_MIN" ]; then
        printf '{"event":"waiting","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$(_emit_num "$num")" "$elapsed"
        return 0
      fi
    fi
  fi

  # ── 재개 횟수 = 마커 코멘트 개수 ──────────────────────────────────────
  if ! attempts=$(count_markers "$repo" "$num"); then
    emit_warn "$repo" "$num" "코멘트 조회 실패 — 재개 횟수를 못 세 상한을 지킬 수 없어 건드리지 않는다"
    return 0
  fi
  _nonneg_int "$attempts" || attempts=0
  next=$((attempts + 1))

  # ── 상한 초과 → hold:policy 승격 (재심 ③ 의 대상이 된다, #244) ────────
  if [ "$next" -gt "$LADDER_RESUME_LIMIT" ]; then
    if ! gh issue edit "$num" --repo "$repo" \
         --add-label "hold:policy" --remove-label "hold:ladder" >/dev/null 2>&1; then
      emit_warn "$repo" "$num" "상한 초과 승격 실패(라벨 편집) — 다음 틱 재시도"
      return 0
    fi
    mirror_labels "$repo" "$num" escalate
    # 승격 코멘트에는 마커를 넣지 않는다 — 넣으면 재개 횟수가 스스로 부풀어 오른다.
    gh issue comment "$num" --repo "$repo" \
      --body "사람 확인(policy): 사다리 재개 상한($LADDER_RESUME_LIMIT) 초과 — 마지막 재개 코멘트의 실패 출력을 읽고, 사다리 밖 통로(직접 조작·스펙 변경)가 필요한지 답하라 <!-- hold-note: policy --><!-- bodat:worker -->" >/dev/null 2>&1 \
      || emit_warn_after_edit "$repo" "$num" "승격 코멘트 실패(라벨은 이미 반영됨)"
    if ! back=$(read_labels "$repo" "$num"); then
      emit_warn_after_edit "$repo" "$num" "승격 readback 조회 실패 — 라벨 반영 여부 미상, 사람 확인 필요"
      return 0
    fi
    if ! has_label "$back" "hold:policy" || has_label "$back" "hold:ladder"; then
      emit_warn_after_edit "$repo" "$num" "승격 readback 불일치(hold:policy 부착·hold:ladder 해제 기대) — 사람 확인 필요"
      return 0
    fi
    # attempt 는 **마커가 실제로 기록한 값**(소진한 재개 횟수)이다 — 거절된 next 가 아니다.
    # 승격에선 마커를 안 남기므로 next 를 실으면 GitHub 어디에도 대응하는 숫자가 없는 값이
    # 이벤트에만 떠돈다(합산하는 소비자는 승격마다 1씩 과다 계수한다).
    printf '{"event":"escalated","repo":"%s","number":%s,"attempt":%s,"limit":%s}\n' \
      "$repo" "$(_emit_num "$num")" "$attempts" "$LADDER_RESUME_LIMIT"
    return 0
  fi

  # ── 재개 ───────────────────────────────────────────────────────────────
  # 마커 코멘트를 **먼저** 남기고 그다음 라벨을 뗀다. 라벨을 먼저 떼면 그 뒤 코멘트가
  # 실패했을 때 "재개는 됐는데 횟수는 안 셌다" 가 되어 상한이 영영 안 걸린다(무한 재시도).
  # 반대 순서의 실패(마커만 남고 라벨은 그대로)는 재개 한 번을 낭비할 뿐 폭주가 없다.
  if ! gh issue comment "$num" --repo "$repo" \
       --body "재개 $next/$LADDER_RESUME_LIMIT: 사다리 재시도 — <!-- ladder-resume: $next --><!-- bodat:worker -->" \
       >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "재개 마커 코멘트 실패 — 카운터 없이 재개하면 무한 재시도라 라벨을 그대로 둔다"
    return 0
  fi
  # agent-ready 는 건드리지 않는다 — 그게 재디스패치 자격이고, 재개는 그 앞을 막던
  # hold:ladder 를 치우는 일이다. `needs-human` 은 애초에 여기 올 수 없고(위 가드) 목록에
  # 넣지도 않는다(#244 — 사람의 손은 루프가 떼지 않는다).
  if ! gh issue edit "$num" --repo "$repo" \
       --remove-label "hold:ladder" >/dev/null 2>&1; then
    emit_warn_after_edit "$repo" "$num" "라벨 해제 실패 — 마커는 이미 남았다(다음 틱이 남은 횟수로 재시도)"
    return 0
  fi
  mirror_labels "$repo" "$num" resume

  # 라벨이 0개로 돌아오는 것은 **성공**이다(둘 다 떨어진 이슈). rc 로만 실패를 가른다.
  if ! back=$(read_labels "$repo" "$num"); then
    emit_warn_after_edit "$repo" "$num" "재개 readback 조회 실패 — 라벨 반영 여부 미상, 사람 확인 필요"
    return 0
  fi
  if has_label "$back" "hold:ladder"; then
    emit_warn_after_edit "$repo" "$num" "재개 readback 불일치(hold:ladder 가 남아 있다) — 사람 확인 필요"
    return 0
  fi
  printf '{"event":"resumed","repo":"%s","number":%s,"attempt":%s}\n' "$repo" "$(_emit_num "$num")" "$next"
}

# ── 스코프 레포 목록 ───────────────────────────────────────────────────────
# 파이프 대신 파일로 받는다 — `cmd | while` 은 서브셸이라 루프 안에서 올린 exit 상태가
# 밖으로 안 나온다(조회 실패의 fail-loud 가 조용히 삼켜진다).
repos_file="$tmp/repos"
if [ -f "$scope_file" ]; then
  scope_lines "$scope_file" > "$repos_file"   # 줄 필터는 lib/scope.sh 한 자리 (#427)
else
  # ── 계정 전체 모드의 레포 탐색 = 이슈 축 ∪ PR 축 (#331) ────────────────────
  # **순회 대상을 정하는 입력 전수** — 각 입력이 어떤 상태를 놓치는지 함께 적는다.
  # 한 겹만 고치면 다음 겹이 다음 회차에 그대로 돌아온다(#293 의 자기 진술).
  #
  #   입력 ⓐ `gh search issues "label:needs-human"` — **이슈**에 `needs-human` 이 붙은 레포.
  #      ①(needs-human ∧ hold:ladder) ②(사유 없는 needs-human) ③(needs-human ∧ hold:policy)
  #      **세 갈래 전부**가 이슈 목록에서 출발하므로 이 축 하나면 족하다.
  #      놓치는 것: ④ 정지 미러 정리가 겨누는 상태는 정의상 **이슈는 깨끗하고 PR 에만**
  #      정지 라벨이 남은 모양이다. `gh search issues` 는 `is:issue` 유무와 무관하게 이슈만
  #      돌려주므로(실측: PR #293 자신이 두 라벨을 달고 있었는데 결과에 안 나왔다) 그 레포에
  #      다른 `needs-human` **이슈**가 하나도 없으면 목록에 안 들어가고 `fetch_open_prs` 가
  #      한 번도 안 불린다 — 좌초된 PR 사본이 영구히 남는다. 실측 조건 성립: `ggqgga/BoDAC`
  #      은 `needs-human` 이슈 0건이다.
  #   입력 ⓑ `gh search prs "label:needs-human"` — **열린 PR** 에 `needs-human` 이 붙은 레포.
  #      ⓐ 가 못 보는 ④ 의 표적을 이 축이 덮는다 — 단 `needs-human` 축 **하나로는** 부족하다.
  #      #244 이후 기계 정지 미러는 `hold:<사유>` **단독**이고(정지 세 전이 verify-held·
  #      closeout-blocked·runner-held 는 `--reason` 필수 → `hold:<사유>` 만 붙인다), `needs-human`
  #      은 사람 정지·`policy-kept` 만 붙인다. 그래서 아래 루프가 네 라벨을 **두 축 모두**에 건다.
  #      놓치는 것: `needs-human` **없이** `hold:*` 만 달린 PR(격자 ⑦·⑩ 의 모양) 가운데
  #      아래 루프의 네 라벨(`needs-human`·`hold:ladder`·`hold:policy`·`hold:conflict`)
  #      어느 것도 아닌 사유(`hold:manual` 따위 — 오늘 `transition.sh` 가 모르는 사유)만 남은 것.
  #      **⑵-b 가 이 모양을 막아 주지 않는다** — 그 관문은 `hold:` 접두가 *하나도 없을* 때만
  #      거르므로 `hold:<사유>` 하나만 남은 PR 은 통과해 **실제로 뗀다**(격자 ⑦ `hold:ladder`·
  #      ⑩ `hold:manual` 이 그것을 단언한다). 그러니 이 사각은 "어차피 안 뗀다" 가 아니라
  #      **탐색이 못 찾아서 교정이 안 도는** 칸이다. 그 칸이 오늘 실제로 열려 있던 자리가
  #      `hold:conflict` 였다(#331 마감 검증 P1): `closeout-blocked --reason conflict` 등은
  #      #244 이후 `hold:conflict` **하나만** 붙이므로(`needs-human` 동반 없음), 사람이 이슈
  #      쪽만 풀고 PR 미러가 남은 레포는 — 그 레포에 다른 정지가 0건이면 — 세 라벨 어느
  #      질의로도 안 잡혀 영구 배제였다. main #244 의 이슈 축 선재 사각을 PR 축이 그대로
  #      복제한 것이고, 사람 결정으로 **이 자리에서 4번째 라벨로 같이 닫았다**(아래 루프).
  #      남는 것은 `transition.sh` 의 `HOLD_ALL` 에 없는 사유뿐이다 — 오늘 기계는 그 모양을
  #      못 만들고(정지 세 전이의 `--reason` 은 `HOLD_ALL` 의 셋 중 하나) 사람만 만들 수 있는데,
  #      그 레포에 네 정지 라벨이 이슈에도 PR 에도 0건이면 경보(`loop-status` 의 `정지 미러
  #      불일치`)는 `--repo` 로 찔렀을 때 울리는데 계정 전체 스윕은 방문조차 안 한다 —
  #      **의도된 잔여 비대칭**이고, 오늘 그 방향으로 틀리는 것은 사람이 세운 브레이크를
  #      보존하는 쪽이라 해롭지 않다.
  #      더 넓히지 않는 이유: `hold:` 는 **접두**라(사유가 열려 있다 — #242) `--label` 로 질의할
  #      수단이 없고, 열거로 흉내 내면 이 파일이 버린 그 실수를 되살린다. 아래 루프의 라벨
  #      집합은 `needs-human` + `transition.sh` 의 `HOLD_ALL`(`hold:conflict hold:policy
  #      hold:ladder`) 과 같아야 한다 — 기계가 붙일 수 있는 정지 라벨 전부를 두 축으로
  #      돌리는 것이 이 블록의 계약이다. `HOLD_ALL` 에 사유가 늘면(또는 접두 질의 수단이
  #      생기면) 아래 `for _lbl` 한 곳을 같이 늘린다(그 전까지 이 주석이 겹의 위치를 가리킨다).
  #      참고: 레포가 어느 축으로든 목록에 들면 ④ 는 그 레포의 **열린 PR 전부**를 훑으므로
  #      (`fetch_open_prs` 는 라벨로 안 좁힌다) 남는 사각은 "그 레포에 네 정지 라벨 중
  #      어느 것도 이슈에도 PR 에도 하나도 없다" 는 칸 하나뿐이다.
  #
  # 호출(라벨 × 축, 아래 루프)은 **각각** 실패를 가른다. 빈 목록 ≠ 실패 — 판정은 출력 형태가
  # 아니라 **종료 코드**다(`gh search` 는 부차 레이트리밋에서 빈 출력 + rc=0 을 내놓는다). 그
  # 경우는 rc 로 못 가른다(이 레포 전례: 「eligible 스크립트가 조회 실패에 눈먼다」) — 틱당
  # `gh search` 가 3회(#244 세 라벨 × 이슈 축)에서 8회(네 라벨 × 두 축)로 늘었으니 그 노출면도 그만큼 넓다. 다만 그때
  # 조용히 꺼지는 것은 그 한 쿼리뿐이고 나머지 축·라벨은 그대로 돌며, 다음 틱이 회복한다 —
  # 영구 좌초가 아니다. 어느 한쪽이라도
  # 실패하면 **중단**한다(exit 2): 성공한 쪽만으로 도는 부분 스코프는 "그 레포엔 멈춘 건이
  # 없다" 와 구분되지 않는 **조용한 축소**이고, 그것이 이 갈래가 막으려는 바로 그 해악이다.
  # 새 종결 상태는 만들지 않는다 — 기존 `탐색 실패 — 스코프를 못 정해 중단` 하나로 접는다.
  #
  # 부정 라벨(`-label:`)은 gh search CLI 가 오파싱하지만(#21) 단일 긍정 라벨은 정상 —
  # reconcile.sh 스윕의 레포 열거와 같은 형태다. 다만 여기선 두 가지를 더 조인다:
  #   · `--state open` — 닫힌 이슈가 창을 채우면 진짜 대상 레포가 밀려난다. 의도는 이것이되
  #     **질의 토큰 `is:open` 으로 쓰지 마라** — gh search 는 이것도 오파싱해 rc=0·빈손을
  #     돌려준다(#236 실측 2026-09-12 gh 2.95.0 `--owner ggqgga --limit 200`:
  #     `label:needs-human` 단독 3개 레포 ↔ `is:open` 을 더하면 0건).
  #     실패가 아니라 "0건" 으로 보여 "멈춘 건 없음" 과 구분되지 않는 것이 해악이었다.
  #     PR 배제용 `is:issue` 는 애초에 잉여다 — `gh search issues` 는 이슈만 찾는다.
  #     (같은 이유로 PR 축도 `is:pr` 를 안 쓴다 — `gh search prs` 는 PR 만 찾는다.)
  #   · `--limit 200` — 기본 limit(30)은 조용히 잘라내 그 레포들이 영영 안 스윕된다.
  # **네 라벨을 전부 훑는다**(#244 세 라벨 + #331 `hold:conflict`). 기계 정지에서 `needs-human`
  # 을 뗀 뒤로는 `hold:ladder`·`hold:policy`·`hold:conflict` 만 달린 레포가 생기는데,
  # `needs-human` 하나로만 탐색하면 그 레포가 통째로 스코프 밖이 되어 **영영 안 스윕된다**
  # (재개가 조용히 죽는 경로). `hold:conflict` 는 ①②③ 어느 갈래의 입력도 아니지만(사람이
  # 결정할 충돌) 그 레포의 열린 PR 정지 미러(④)는 봐야 하므로 탐색 집합에는 든다 — 집합은
  # `needs-human` + `transition.sh` 의 `HOLD_ALL` 과 같다(위 ⓑ 주석). 한 쿼리에 OR 로 합치지
  # 않는 이유는 #21 — gh search CLI 의 라벨 qualifier 파싱은 신뢰 구간이 좁다. 긍정 라벨
  # 하나짜리 쿼리(이 파일이 이미 쓰던 형태)를 네 번 돌려 합집합(sort -u)한다. 부정 라벨도
  # `is:` 질의 토큰도 쓰지 않는다 — 열림 한정은 위 주석대로 `--state open` **플래그**다(#236).
  #
  # 라벨마다 **두 축**(이슈 ⓐ · PR ⓑ, #331)을 돌린다 — 네 라벨 × 두 축 = 8 쿼리. 위 주석의
  # "`HOLD_ALL` 에 사유가 늘면 이 루프도 같이" 는 바로 여기다: 라벨 목록이 늘면 PR 축도
  # 같은 라벨로 따라가므로 겹이 어긋나지 않는다. 합집합은 `sort -u` 여야 한다 — 같은 레포가
  # 여러 쿼리에 잡히면(운영에서 가장 흔한 모양) 한 번만 순회한다.
  # 한 쿼리라도 실패하면 **중단**한다 — 부분 스코프는 "그 레포엔 멈춘 건이
  # 없다" 로 위장되기 때문이다(빈 목록과 구분한다는 이 파일의 규율). 메시지에 라벨과 축을
  # 밝혀 어느 질의가 죽었는지 가른다.
  : > "$tmp/search.raw"
  for _lbl in needs-human hold:ladder hold:policy hold:conflict; do
    if ! gh search issues "label:$_lbl" --owner "$me" --state open --limit "$LIST_LIMIT" \
         --json repository -q '.[].repository.nameWithOwner' > "$tmp/search.one" 2>/dev/null; then
      echo "resume-sweep: 계정 전체 $_lbl 탐색 실패(이슈) — 스코프를 못 정해 중단(빈 목록과 구분)" >&2
      exit 2
    fi
    issue_hits=$(grep -c . "$tmp/search.one" || true)
    cat "$tmp/search.one" >> "$tmp/search.raw"
    if ! gh search prs "label:$_lbl" --owner "$me" --state open --limit "$LIST_LIMIT" \
         --json repository -q '.[].repository.nameWithOwner' > "$tmp/search.one" 2>/dev/null; then
      echo "resume-sweep: 계정 전체 $_lbl 탐색 실패(PR) — 스코프를 못 정해 중단(빈 목록과 구분)" >&2
      exit 2
    fi
    pr_hits=$(grep -c . "$tmp/search.one" || true)
    cat "$tmp/search.one" >> "$tmp/search.raw"
    # 상한에 정확히 닿았으면 잘렸을 수 있다 — 조용히 지나가면 "그 레포엔 멈춘 건이 없다" 로
    # 위장된다. 쿼리마다 따로 본다(합친 뒤 세면 어느 쿼리가 잘렸는지 알 수 없다). 라벨과
    # 축을 문구에 밝힌다 — 여럿이 닿으면 같은 줄이 겹쳐 어느 질의가 잘렸는지(그래서 무엇이
    # 안 보이는지) 못 가른다. repo 는 특정 레포가 아니라는 뜻으로 `*`.
    if [ "${issue_hits:-0}" -ge "$LIST_LIMIT" ]; then
      printf '{"event":"warn","repo":"*","number":0,"msg":"탐색 상한 도달(%s, label:%s, 이슈) — 일부 레포가 누락됐을 수 있다. .loop/repos 로 스코프를 좁혀라"}\n' "$LIST_LIMIT" "$_lbl"
    fi
    if [ "${pr_hits:-0}" -ge "$LIST_LIMIT" ]; then
      printf '{"event":"warn","repo":"*","number":0,"msg":"탐색 상한 도달(%s, label:%s, PR) — 일부 레포가 누락됐을 수 있다. .loop/repos 로 스코프를 좁혀라"}\n' "$LIST_LIMIT" "$_lbl"
    fi
  done
  sort -u "$tmp/search.raw" > "$repos_file"
fi

# fetch_issues <repo> <출력파일> <쿼리이름> <gh 추가인자…> — 성공 0 / 조회 실패 1.
# 상한에 닿으면 warn 을 낸다(잘린 나머지가 "없음" 으로 위장되지 않게).
fetch_issues() {
  local repo="$1" out="$2" qname="$3"
  shift 3
  local body count
  body=$(gh issue list --repo "$repo" --state open "$@" \
    --limit "$LIST_LIMIT" --json number,labels,updatedAt 2>/dev/null)
  # 조회 실패를 "해당 이슈 없음" 과 구분 못 하면 멈춘 건이 조용히 영영 안 재개된다.
  printf '%s' "$body" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$body" | jq 'length')
  if [ "${count:-0}" -ge "$LIST_LIMIT" ]; then
    printf '{"event":"warn","repo":"%s","number":0,"msg":"목록 상한 도달(%s) — 잘린 이슈는 이번 틱에 안 보인다"}\n' \
      "$repo" "$qname"
  fi
  printf '%s' "$body" | jq -c '.[]' > "$out" 2>/dev/null || : > "$out"
  return 0
}

# fetch_open_prs <repo> <출력파일> — 성공 0 / 조회 실패 1 (#265).
# 정지 라벨은 4개라 `--label` AND 로는 못 좁힌다(OR 가 없다). 라벨 4개를 각각 물으면 왕복이
# 4배가 되고 부정 라벨은 gh 가 오파싱하므로(#21) **열린 PR 을 한 번에 받아 클라이언트에서**
# 거른다 — 열린 PR 수는 레포당 수십 단위라 이 편이 싸다. 상한에 닿으면 warn(잘린 나머지가
# "정리 대상 없음" 으로 위장되지 않게 — fetch_issues 와 같은 규율).
fetch_open_prs() {
  local repo="$1" out="$2" body count
  # `updatedAt` 은 ③-b(PR 단독 `hold:policy` 재심, #395)의 창 판정 입력이다 — 이슈 축이
  # `gh issue list --json … updatedAt` 으로 재는 그 값과 같은 축이다. 한 조회로 두 갈래가 쓴다.
  body=$(gh pr list --repo "$repo" --state open \
    --json number,labels,headRefName,closingIssuesReferences,updatedAt --limit "$LIST_LIMIT" 2>/dev/null)
  printf '%s' "$body" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$body" | jq 'length')
  if [ "${count:-0}" -ge "$LIST_LIMIT" ]; then
    printf '{"event":"warn","repo":"%s","number":0,"msg":"열린 PR 목록 상한 도달(%s) — 잘린 PR 의 정지 미러는 이번 틱에 안 보인다"}\n' \
      "$repo" "$LIST_LIMIT"
  fi
  printf '%s' "$body" | jq -c '.[]' > "$out" 2>/dev/null || : > "$out"
  return 0
}

# ── 레포별 스윕 ───────────────────────────────────────────────────────────
while IFS= read -r repo; do
  [ -n "$repo" ] || continue

  # ① 재개 대상 — 라벨 AND 로 **서버에서** 좁힌다. 클라이언트 필터만 쓰면 창(limit)을
  #    다른 needs-human 이슈들이 채워 진짜 대상이 밀려난다(eligible-issues.sh 와 같은 교훈).
  if fetch_issues "$repo" "$tmp/issues.ladder" "hold:ladder" --label hold:ladder; then
    # fd 3 으로 읽는다 — 안에서 부르는 gh 가 stdin 을 건드리면 목록이 통째로 먹힌다.
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      sweep_issue "$repo" "$row"
    done 3< "$tmp/issues.ladder"
  else
    echo "resume-sweep: $repo hold:ladder 목록 조회 실패 — 이 레포는 건너뛴다" >&2
    rc=2
  fi

  # ② 사유 없는 needs-human — 사람이 직접 세운 정지다(#244). **손대지 않고** 알린다.
  #    (여기서 코멘트를 달면 updatedAt 이 갱신돼 자기가 자기 창을 밀어버린다 — 무편집이 규율.)
  if fetch_issues "$repo" "$tmp/issues.human" "needs-human" --label needs-human; then
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      if ! printf '%s' "$row" \
           | jq -e '[.labels[].name | select(startswith("hold:"))] | length > 0' >/dev/null 2>&1; then
        # 사유 라벨 없는 `needs-human` 은 **정상 상태**다(#244) — 라벨 하나에 뜻 하나를 준
        # 뒤로 그것은 "사람이 직접 세운 정지" 하나만 뜻하고, 루프가 교정할 불변식 위반이
        # 아니다(warn 은 **루프가 교정 가능한 불변식 위반일 때만** — #188/#190 이 세운 정의).
        # 그래서 두 갈래 모두 note 다. 갈래를 남겨 두는 이유는 **문구**다: 배포 레인이라
        # 조용한 것과 사람이 직접 세워 조용한 것은 다음 사람이 갈라 읽어야 하는 다른 사실이다.
        # 조용히 버리지 않는 이유는 emit_note 주석 참고.
        #
        # 제외 판정도 **같은 row 에 대한 jq 테스트**로만 한다: 별도 `gh issue list --label
        # deploy-wait` 로 제외 집합을 만들면 그 조회의 실패가 "배포 대기 이슈 없음" 으로
        # 위장돼 전부 다시 warn 이 된다(조회 실패를 '해당 없음' 으로 삼키지 않는다는 이 파일의
        # 규율). 축 판정 자체는 deploy_wait_row 공유 술어(위 정의, #201) — 두 벌 금지.
        row_tsv=$(deploy_wait_row "$row") || row_tsv=""
        hnum=${row_tsv%%$'\t'*}
        dwlabel=${row_tsv#*$'\t'}
        if [ -n "$dwlabel" ]; then
          emit_note "$repo" "$hnum" "배포 대기(라벨 $dwlabel) — 배포 레인의 정상 상태라 warn 아님"
        else
          emit_note "$repo" "$hnum" \
            "사람이 직접 세운 정지(hold:* 부재) — 정상 상태라 warn 아님, 자동 재개 안 함"
        fi
      fi
    done 3< "$tmp/issues.human"
  else
    echo "resume-sweep: $repo needs-human 목록 조회 실패 — 사유 점검을 건너뛴다" >&2
    rc=2
  fi
  # ③ policy 재심 — `hold:policy` 가 창(RESUME_AFTER_MIN)을 넘겼는데 재심 마커 코멘트
  #    `<!-- policy-review: … -->` 가 없으면 **1회** 재심 대상(#155). 스크립트는 판정하지 않고
  #    이벤트만 낸다(판정은 디스패처 ① — 질문 한 줄이 루프가 답할 수 있는 것인지). 무편집.
  #    **단 `needs-human` 이 동존하면 재심 대상이 아니다**(#244) — 사람이 직접 세운 정지는
  #    루프가 풀지 않는다. 그 건은 due 대신 note 로 내려간다(아래 갈래).
  if fetch_issues "$repo" "$tmp/issues.policy" "hold:policy" --label hold:policy; then
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      pnum=$(printf '%s' "$row" | jq -r '.number')
      pupd=$(printf '%s' "$row" | jq -r '.updatedAt // ""')
      pmin=$(policy_window_min "$pupd") \
        || { emit_warn "$repo" "$pnum" "updatedAt 해석 불가($pupd) — 재심 창 판정 못 함"; continue; }
      [ "$pmin" -ge "$RESUME_AFTER_MIN" ] || continue
      # `needs-human` 은 **사람이 직접 세운 정지**다(#244). ③ 은 `--label hold:policy`
      # 단독 쿼리라 사람이 손으로 그 라벨을 더한 건도 집어 온다 — 그대로 `policy_review_due`
      # 를 내면 디스패처가 그 판정에서 `verify-redispatch` 를 부를 수 있고, 그 전이는
      # `needs-human` 과 `hold:*` 를 **둘 다** 뗀다(transition.sh 의 반송 전이). 이 이슈가
      # 방금 "루프가 치우면 안 되는 것" 으로 정의한 라벨을 루프가 치우는 것이다.
      # 여기(스냅샷)의 검사는 **사전 필터**다 — 목록에 이미 있는 건을 코멘트 조회 없이 접어
      # 왕복을 아끼고, 마커 상태(reviewed·no-note)와 무관하게 "사람 정지" 라는 이유를 note 로
      # 남긴다. 그러나 **답은 여기서 내지 않는다**: row 는 목록을 뜬 시점의 스냅샷이라 그
      # 뒤에 사람이 붙인 정지를 모른다 — 최종 판정은 due 를 내기 **직전**의 재조회(아래,
      # #351)가 같은 술어(`has_label … needs-human`)로 한 번 더 한다.
      # warn 이 아니라 note 인 이유: warn 의 정의는 "루프가 교정 가능한 불변식 위반"
      # (emit_note 주석, 위)인데 이건 사람이 이 이슈가 정의한 축을 정상적으로 행사한 것이라
      # 루프가 교정할 것이 없다 — ②가 "사람이 직접 세운 정지 … 정상 상태라 warn 아님" 을
      # note 로 내는 것과 **같은 사람 행동, 같은 낱말**이다(hold:* 유무만 다르다).
      # ① 이 warn 인 것은 **다른 질문**이라서다: 거기선 루프가 만든 기계 홀드(hold:ladder)가
      # 좌초해 영영 재개되지 않는다는 신호다(M8 이 무는 자리). 여기 ③ 은 무편집 읽기 갈래라
      # 좌초시킬 루프 상태가 없다.
      # 조용한 continue 로 두지 않는다(#247) — 왜 재심이 안 도는지가 어디에도 안 남는다.
      plab=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || plab=""
      if has_label "$plab" "needs-human"; then
        emit_note "$repo" "$pnum" "사람이 세운 needs-human 동존 — 재심 안 함, 정상 상태라 warn 아님"
        continue
      fi
      pout=$(fetch_comments "$repo" "$pnum") \
        || { emit_warn "$repo" "$pnum" "재심 마커 조회 실패 — 이번 틱은 건너뛴다"; continue; }
      # 에피소드 단위: 마지막 `hold-note: policy` 코멘트(=이번 홀드의 질문) **이후**에 재심 마커가
      # 있어야 "이번 홀드는 재심됨" 이다. 옛 홀드의 마커가 새 홀드의 재심을 막지 않게.
      # 질문(hold-note) 자체가 없으면 재심할 대상이 없다 — warn 으로만(레거시·손으로 붙인 홀드).
      # 에피소드 판정은 두 축 공용(#395) — 규칙 전문은 policy_review_state 주석.
      pstate=$(policy_review_state "$pout")
      case "$pstate" in
        reviewed) continue ;;   # 이번 홀드는 이미 1회 재심됨 — 사람이 라벨을 뗄 때까지 다시 안 묻는다
        no-note)
          # 배포 대기 이슈는 배포 레인이 transition.sh 를 거치지 않고 라벨·코멘트를 직접
          # 붙인다(실측 #201: ggqgga/BodaT#5013 — 사람이 답할 질문이 코멘트 산문에 있었는데도
          # `<!-- hold-note: policy -->` 마커가 없었다). 그 레인은 이 레포 밖이라 마커 규약을
          # 강제할 수 없으므로, 여기서는 "배포 게이트 표시"로 보고 note 로 내린다(②와 같은 축,
          # 같은 이유 — 두 벌 금지 #201). 배포 대기가 **아닌** no-note 는 여전히 규약 위반이라
          # warn 유지(회귀 없음).
          dw_row=$(deploy_wait_row "$row") || dw_row=""
          dwlabel=${dw_row#*$'\t'}
          if [ -n "$dwlabel" ]; then
            emit_note "$repo" "$pnum" "배포 대기(라벨 $dwlabel) — hold:policy 이지만 질문(hold-note) 없이 부착돼 재심 대상 아님"
          else
            emit_warn "$repo" "$pnum" "hold:policy 인데 질문(hold-note) 코멘트가 없다 — 재심 불가, --note 로 다시 걸거나 사람이 처리"
          fi
          continue ;;
        due) ;;
        *) emit_warn "$repo" "$pnum" "재심 마커 해석 실패 — 이번 틱은 건너뛴다"; continue ;;
      esac
      # ── `needs-human` 배제 — due 직전 **재조회**로 최종 판정한다(#351, #244 후속) ────
      # 위 스냅샷 사전 필터만으로는 "목록 조회 → 사람이 needs-human 부착 → 같은 틱 due →
      # 전이가 그 정지를 벗김" 창이 한 틱 안에 열린다(#351 — #151 부류). 그래서
      # ①(sweep_issue)이 편집 직전에 쓰는 **같은 함수** `read_state` 로 여기서도 다시 읽고
      # 그 결과로 판정한다(조회 로직 한 벌 — #229·#244 의 규율; 술어도 위와 같은 has_label).
      # 재조회 실패는 "needs-human 없음" 으로 폴백하지 않는다 — 폴백하면 이 갈래가 막으려는
      # 사고가 조회 실패 경로에서 그대로 재현된다(①의 재조회 실패 처리와 같은 방향, 같은 이유).
      # note 문구는 위 사전 필터와 **한 글자도 다르지 않게** — 같은 사람 행동, 같은 낱말.
      if ! pcur=$(read_state "$repo" "$pnum" "$tmp/policy.updated.live"); then
        emit_warn "$repo" "$pnum" "재조회 실패(라벨·updatedAt) — needs-human 동존 여부를 확정 못 해 재심을 내지 않는다"
        continue
      fi
      if has_label "$pcur" "needs-human"; then
        emit_note "$repo" "$pnum" "사람이 세운 needs-human 동존 — 재심 안 함, 정상 상태라 warn 아님"
        continue
      fi
      # `pr` 필드가 두 축을 가른다(#395) — 이슈 축은 PR 번호를 모른다(전이는 `<pr|->` 를 받는다).
      printf '{"event":"policy_review_due","repo":"%s","number":%s,"pr":null,"minutes":%s}\n' "$repo" "$(_emit_num "$pnum")" "$pmin"
    done 3< "$tmp/issues.policy"
  else
    echo "resume-sweep: $repo hold:policy 목록 조회 실패 — 재심 점검을 건너뛴다" >&2
    rc=2
  fi

  # ④ 정지 미러 정리 (#265) — 사람이 이슈에서만 푼 홀드의 PR 사본을 뗀다.
  #    ①~③ 과 축이 다르다: 저쪽은 **이슈** 목록에서 출발하는데, 이 갈래가 찾는 상태는
  #    이슈에 라벨이 하나도 없는 것이라 이슈 쪽 쿼리로는 애초에 안 잡힌다. 그래서 **열린
  #    PR** 에서 출발한다.
  #    같은 목록을 **③-b(PR 단독 hold:policy 재심, #395)** 도 쓴다 — 축이 같아서(열린 PR)
  #    한 조회를 나눠 쓰고, 두 갈래는 서로 배타적이다(③-b 는 연결 이슈가 **없는** PR 만,
  #    ④ 는 짝이 **증명된** PR 만 건드린다).
  if fetch_open_prs "$repo" "$tmp/prs.open"; then
    while IFS= read -r prow <&3; do
      [ -n "$prow" ] || continue
      sweep_pr_policy "$repo" "$prow"
      sweep_hold_mirror "$repo" "$prow"
    done 3< "$tmp/prs.open"
  else
    echo "resume-sweep: $repo 열린 PR 목록 조회 실패 — 정지 미러 정리·PR 단독 재심을 건너뛴다" >&2
    rc=2
  fi
done < "$repos_file"

exit "$rc"
