#!/usr/bin/env bash
# resume-sweep.sh — 사다리 검증에서 멈춘 이슈(hold:ladder)를 창이 지나면
# 자동으로 재개한다. "사람이 '진행해' 를 치던 것을 틱이 대신 친다" (플랜 §4 · 원칙 4).
#
# 사용: resume-sweep.sh          (인자 없음)
#   스코프: 실행 cwd 의 `.loop/repos` 목록. 없으면 계정 전체(reconcile.sh 와 같은 규약 #40).
#   환경변수: RESUME_AFTER_MIN(기본 120) · LADDER_RESUME_LIMIT(기본 2)
#
# 출력(JSON lines):
#   resumed   — 라벨을 되돌려 재디스패치 가능 상태로. attempt = 이번이 몇 번째 재개인가.
#   escalated — 재개 상한 초과 → hold:policy 로 승격. 사람 호출(needs-human)이 되는 것은
#               그 뒤 재심(③)이 "사람 몫 유지" 로 끝났을 때뿐이다(#244 — 디스패처가 판정).
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
# 붙인다. 이슈만 되돌리면 PR 은 영구 사람대기로 남고, 뒤 전이(handoff-verify·verify-pass·
# closeout-pick)는 그 라벨을 떼지 않아 사람이 손으로 지워야 흐른다. 그래서 재개·승격은
# 연결된 열린 PR 의 같은 라벨까지 **같은 단계에서** 함께 되돌린다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RESUME_AFTER_MIN="${RESUME_AFTER_MIN:-120}"
LADDER_RESUME_LIMIT="${LADDER_RESUME_LIMIT:-2}"
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
count_markers() {  # count_markers <repo> <num>
  local out
  out=$(gh issue view "$2" --repo "$1" --json comments 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" \
    | jq "$JQ_UNQUOTE"'[.comments[]? | select(.body | unquoted | test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
}

# 연결된 **열린** PR 들 — "<번호><TAB><라벨 콤마목록>" 줄. 없으면 빈 출력(정상).
list_mirror_prs() {  # list_mirror_prs <repo> <num>
  local out
  out=$(gh pr list --repo "$1" --state open --head "agent/issue-$2" \
    --json number,labels --limit 20 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.[] | [(.number|tostring), ([.labels[].name] | join(","))] | @tsv'
}

read_pr_labels() {  # read_pr_labels <repo> <pr>
  local out
  out=$(gh pr view "$2" --repo "$1" --json labels 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
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
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 라벨 해제 실패 — PR 이 사람대기로 남는다"
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
scope_file="$PWD/.loop/repos"
repos_file="$tmp/repos"
if [ -f "$scope_file" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' > "$repos_file"
else
  # 부정 라벨(`-label:`)은 gh search CLI 가 오파싱하지만(#21) 단일 긍정 라벨은 정상 —
  # reconcile.sh 스윕의 레포 열거와 같은 형태다. 다만 여기선 두 가지를 더 조인다:
  #   · `is:open is:issue` — 닫힌 이슈·PR 이 창을 채우면 진짜 대상 레포가 밀려난다.
  #   · `--limit 200` — 기본 limit(30)은 조용히 잘라내 그 레포들이 영영 안 스윕된다.
  # **세 라벨을 전부 훑는다**(#244). 기계 정지에서 `needs-human` 을 뗀 뒤로는 `hold:ladder`·
  # `hold:policy` 만 달린 레포가 생기는데, `needs-human` 하나로만 탐색하면 그 레포가 통째로
  # 스코프 밖이 되어 **영영 안 스윕된다**(재개가 조용히 죽는 경로). 한 쿼리에 OR 로 합치지
  # 않는 이유는 #21 — gh search CLI 의 라벨 qualifier 파싱은 신뢰 구간이 좁다. 긍정 라벨
  # 하나짜리 쿼리(이 파일이 이미 쓰던 형태)를 세 번 돌려 합집합(sort -u)한다. 부정 라벨은
  # 쓰지 않는다. 한 쿼리라도 실패하면 **중단**한다 — 부분 스코프는 "그 레포엔 멈춘 건이
  # 없다" 로 위장되기 때문이다(빈 목록과 구분한다는 이 파일의 규율).
  : > "$tmp/search.raw"
  for _lbl in needs-human hold:ladder hold:policy; do
    if ! gh search issues "label:$_lbl is:open is:issue" --owner "$me" --limit "$LIST_LIMIT" \
         --json repository -q '.[].repository.nameWithOwner' > "$tmp/search.one" 2>/dev/null; then
      echo "resume-sweep: 계정 전체 $_lbl 탐색 실패 — 스코프를 못 정해 중단(빈 목록과 구분)" >&2
      exit 2
    fi
    one_hits=$(grep -c . "$tmp/search.one" || true)
    cat "$tmp/search.one" >> "$tmp/search.raw"
    # 상한에 정확히 닿았으면 잘렸을 수 있다 — 조용히 지나가면 "그 레포엔 멈춘 건이 없다" 로
    # 위장된다. 쿼리마다 따로 본다(합친 뒤 세면 어느 쿼리가 잘렸는지 알 수 없다).
    # repo 는 특정 레포가 아니라는 뜻으로 `*`.
    if [ "${one_hits:-0}" -ge "$LIST_LIMIT" ]; then
      printf '{"event":"warn","repo":"*","number":0,"msg":"탐색 상한 도달(%s, label:%s) — 일부 레포가 누락됐을 수 있다. .loop/repos 로 스코프를 좁혀라"}\n' "$LIST_LIMIT" "$_lbl"
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
      pep=$(jq -n --arg u "$pupd" '($u | try fromdateiso8601 catch -1)' 2>/dev/null || echo -1)
      [ "${pep:--1}" -ge 0 ] || { emit_warn "$repo" "$pnum" "updatedAt 해석 불가($pupd) — 재심 창 판정 못 함"; continue; }
      pmin=$(( ( $(date -u +%s) - pep ) / 60 ))
      [ "$pmin" -ge "$RESUME_AFTER_MIN" ] || continue
      # `needs-human` 은 **사람이 직접 세운 정지**다(#244). ③ 은 `--label hold:policy`
      # 단독 쿼리라 사람이 손으로 그 라벨을 더한 건도 집어 온다 — 그대로 `policy_review_due`
      # 를 내면 디스패처가 그 판정에서 `verify-redispatch` 를 부를 수 있고, 그 전이는
      # `needs-human` 과 `hold:*` 를 **둘 다** 뗀다(transition.sh 의 반송 전이). 이 이슈가
      # 방금 "루프가 치우면 안 되는 것" 으로 정의한 라벨을 루프가 치우는 것이다.
      # ①(sweep_issue, 위)이 쓰는 것과 **같은 술어**를 여기서도 쓴다.
      # warn 이 아니라 note 인 이유: warn 의 정의는 "루프가 교정 가능한 불변식 위반"
      # (emit_note 주석, 위)인데 이건 사람이 이 이슈가 정의한 축을 정상적으로 행사한 것이라
      # 루프가 교정할 것이 없다 — ②가 "사람이 직접 세운 정지 … 정상 상태라 warn 아님" 을
      # note 로 내는 것과 **같은 사람 행동, 같은 낱말**이다(hold:* 유무만 다르다).
      # ① 이 warn 인 것은 **다른 질문**이라서다: 거기선 루프가 만든 기계 홀드(hold:ladder)가
      # 좌초해 영영 재개되지 않는다는 신호다(M8 이 무는 자리). 여기 ③ 은 무편집 읽기 갈래라
      # 좌초시킬 루프 상태가 없다.
      # 조용한 continue 로 두지 않는다(#247) — 왜 재심이 안 도는지가 어디에도 안 남는다.
      if printf '%s' "$row" | jq -e '[.labels[].name] | index("needs-human") != null' >/dev/null 2>&1; then
        emit_note "$repo" "$pnum" "사람이 세운 needs-human 동존 — 재심 안 함, 정상 상태라 warn 아님"
        continue
      fi
      pout=$(gh issue view "$pnum" --repo "$repo" --json comments 2>/dev/null) \
        || { emit_warn "$repo" "$pnum" "재심 마커 조회 실패 — 이번 틱은 건너뛴다"; continue; }
      # 에피소드 단위: 마지막 `hold-note: policy` 코멘트(=이번 홀드의 질문) **이후**에 재심 마커가
      # 있어야 "이번 홀드는 재심됨" 이다. 옛 홀드의 마커가 새 홀드의 재심을 막지 않게.
      # 질문(hold-note) 자체가 없으면 재심할 대상이 없다 — warn 으로만(레거시·손으로 붙인 홀드).
      pstate=$(printf '%s' "$pout" | jq -r "$JQ_UNQUOTE"'
        [.comments[]? | .body | unquoted] as $b
        | ([range(0; $b|length)] | map(select($b[.] | test("<!--\\s*hold-note:\\s*policy"))) | last) as $q
        | if $q == null then "no-note"
          else ([range($q+1; $b|length)] | map(select($b[.] | test("<!--\\s*policy-review:"))) | length) as $r
               | if $r > 0 then "reviewed" else "due" end end' 2>/dev/null || echo "parse-fail")
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
      printf '{"event":"policy_review_due","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$(_emit_num "$pnum")" "$pmin"
    done 3< "$tmp/issues.policy"
  else
    echo "resume-sweep: $repo hold:policy 목록 조회 실패 — 재심 점검을 건너뛴다" >&2
    rc=2
  fi
done < "$repos_file"

exit "$rc"
