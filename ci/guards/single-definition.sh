#!/usr/bin/env bash
# 단일 정의 불변식 가드 — bin/ci 안에 흩어져 있던 "이 상수/함수/마커 집합·정규식은 한
# 자리에만 정의된다" 인라인 검사 10자리를 이 목록 하나로 모은다 (분류표
# Plans/ci-guard-classification.md L4 절, #540 · 대상 행 11 · 14 · 27-c · 30 · 61 · 71-a ·
# 72-c(#539 재판정으로 편입) · 74 · 83-b · 84-b).
#
# 왜 한 자리인가 — 정의가 두 벌이 되면 소비자 중 한쪽만 고쳐진 값을 읽어도 출력에
# 안 보이는 드리프트가 생긴다(각 항목 주석에 실제로 갈렸던 사례를 적었다). 열 항목의
# 검사 모양은 원래 서로 달랐다(파일 나열 vs 줄 나열, exclude vs 정확히-N-회, 두 파일
# 축자 동일 vs 단일 파일 존재) — 동작을 그대로 옮기는 것이 최우선이라, 모양이 정확히
# 같은 두 자리(11 · 71-a: "패턴이 glob 안 허용 파일 밖에 없다")만 assert_single_def 로
# 접었고 나머지 여덟은 원 블록의 grep 을 한 글자도 안 바꾸고 그대로 옮겼다. 억지로
# 한 함수에 밀어 넣으면 "같은 결함에 같은 판정"이 깨진다(예: 행 14 는 -n 줄 나열 +
# 주석 줄 제외라 -l 파일 나열과 다른 판정을 낸다).
#
# 항목마다 원 이슈 번호와 만료 조건 한 줄을 적었다 — 만료 조건이 없으면 이 가드가
# 그 SSOT 의 유일한 강제자라는 뜻이다.
set -euo pipefail
cd "$(dirname "$0")/../.."

# 패턴이 glob 에서 찾은 파일 중 허용 파일(들) 밖에도 있으면 실패. $3 은 grep -vE 패턴이라
# 파일이 여럿이면 '^a$|^b$' 형태로 넘긴다. glob·허용 패턴은 공백 구분 다중 인자를
# 그대로 셸에 넘기는 것이 의도다.
assert_single_def() {
  # shellcheck disable=SC2086
  local pattern="$1" glob="$2" allowed_re="$3" msg="$4"
  local dup
  dup=$(grep -lE "$pattern" $glob 2>/dev/null | grep -vE "$allowed_re" || true)
  [ -z "$dup" ] || { echo "  ✗ $msg: $dup"; exit 1; }
}

# 행 11 — 반송 마커 집합(BOUNCE_MARKERS)은 bounce-state.sh 한 자리 (#171 · #196).
# 마커 문자열 자체는 다른 파일의 설명 주석에도 나오고(그건 사본이 아니다), 정의만
# 한 자리면 계약이 지켜진다. 만료 조건: 없음 — 이 가드가 곧 bounce-state.sh SSOT 의 강제자.
assert_single_def 'BOUNCE_MARKERS' 'scripts/*.sh' '^scripts/bounce-state\.sh$' \
  '반송 마커 집합 정의가 bounce-state.sh 밖에도 있다'

# 행 14 — 판정 술어(머지 판정/Merge verdict/검증자 리뷰/마감 검증/재디스패치/재검증 실패/
# bodat:worker 센티널/hold:/needs-human)는 scripts/lib/loop.jq 한 자리 — 인라인 사본 0 (#426).
# 판정선은 코드에 있는 술어 표현이다: 산문·주석의 언급은 사본이 아니므로 `#` 로 시작하는
# 줄은 뺀다(그래서 -n 줄 나열 + 주석 제외 모양이라 위 assert_single_def 의 -l 파일 나열과
# 다르다 — 억지로 접지 않는다). 예외: `gh api -q` 안의 필터는 gh 내장 jq 라 -L 모듈을 못
# 쓴다 — closeout-reconcile.sh 의 index("needs-human") 하나가 그 경우이고 .labels 형상
# 검사와 한 몸이라 아래 패턴 어디에도 안 걸린다. 만료 조건: 없음 — 이 가드가 곧
# scripts/lib/loop.jq SSOT 의 강제자다.
dup=$(grep -nE 'startswith\("머지 판정|startswith\("Merge verdict|startswith\("검증자 리뷰|startswith\("마감 검증|startswith\("재디스패치|startswith\("재검증 실패|contains\("<!-- bodat:worker|startswith\("hold:"\)|== "needs-human"' \
  scripts/*.sh | grep -vE '^[^:]+:[0-9]+: *#' || true)
[ -z "$dup" ] || { echo "  ✗ 인라인 판정 술어가 남아 있다 — scripts/lib/loop.jq 를 include 하라 (#426):"; printf '%s\n' "$dup"; exit 1; }
grep -qF 'def is_verdict_ok' scripts/lib/loop.jq \
  || { echo "  ✗ scripts/lib/loop.jq 에 판정 술어 정의가 없다 — 위 검사가 의미를 잃었다"; exit 1; }

# 행 27-c — `Epic #N` 전용 줄 정규식의 SSOT 는 loop-status.sh 의 epic_of(#260) 다. 파생의
# 에픽 판정(spinoff-inherit.sh)과 leaf 판정(loop-status.sh)이 갈라지면 두 경로가 서로 다른
# 세계를 잰다(#216 교훈 — "같은 X 를 쓴다"는 단언은 갈래마다 실제로 참인지 확인하라).
# 두 파일에 문자 그대로 같은 문자열이 있는지 문다(한쪽만 고치면 여기서 빨개진다).
# 만료 조건: Epic 전용 줄 정규식이 scripts/lib/loop.jq 한 자리로 가면 ⓑ (#261 · #260).
epic_re_ssot='^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)'
for f in scripts/loop-status.sh scripts/spinoff-inherit.sh; do
  grep -qF -- "$epic_re_ssot" "$f" \
    || { echo "  ✗ $f 에 Epic 전용 줄 정규식 SSOT 없음(두 판정이 갈라졌다): $epic_re_ssot"; exit 1; }
done

# 행 30 — no-basis 신호 형식(STATUS_KEY·STATUS_NO_BASIS)은 codex-review-gate.sh 의 상수
# 한 자리에서만 정의한다 — 문서·템플릿이 리터럴을 적으면 힌트 문구와 파서가 갈라진다
# (#207 의 뿌리). STATUS_REVIEWED(모델이 내지 않는 계약 값) 부활도 금지한다 (#375).
# 만료 조건: 신호 키가 scripts/lib/constants.sh 로 가고 문서가 이름만 부르면 ⓑ.
gate=scripts/codex-review-gate.sh
for v in STATUS_KEY STATUS_NO_BASIS; do
  if ! grep -qE "^$v=" "$gate"; then
    echo "  ✗ $gate 에 $v 정의 없음 — no-basis 신호 형식의 단일 정의 자리"; exit 1
  fi
done
key=$(sed -n "s/^STATUS_KEY='\\(.*\\)'\$/\\1/p" "$gate")
[ -n "$key" ] || { echo "  ✗ $gate 의 STATUS_KEY 값을 못 읽었다"; exit 1; }
n=$(grep -c "$key" "$gate")
if [ "$n" != 1 ]; then
  echo "  ✗ $gate 에 신호 키('$key') 리터럴이 ${n}곳 — 정의 1곳만 허용(나머지는 \$STATUS_KEY 참조)"; exit 1
fi
if grep -qE '^ *STATUS_REVIEWED=' "$gate"; then
  echo "  ✗ $gate 에 'reviewed' 계약 값이 되살아났다 — 모델이 내지 않는 줄을 요구하면 판정을 버린다(#375, 실호출 0/8)"; exit 1
fi
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md skills/closeout/references/verifier-prompt.md \
         skills/closeout/references/verifier-prompt-fallback.md; do
  if grep -q "$key" "$f"; then
    echo "  ✗ $f 에 신호 형식('$key')이 하드코딩됨 — 정의 자리는 $gate 뿐(#207)"; exit 1
  fi
done

# 행 61 — 보류 conflict 재개 횟수의 인용 제거(def unquoted)는 lib/loop.jq 와
# resume-sweep.sh 의 JQ_UNQUOTE 에서 축자 동일해야 한다(#346) — 재개 스윕과 대시보드가
# 같은 수를 봐야 하기 때문. 만료 조건: resume-sweep.sh 가 jq -L lib 로 loop.jq 를
# include 하면 즉시.
unq_lib=$(grep -o 'def unquoted:.*;' scripts/lib/loop.jq | head -1)
unq_sweep=$(grep -o 'def unquoted:.*;' scripts/resume-sweep.sh | head -1)
[ -n "$unq_lib" ] || { echo "  ✗ scripts/lib/loop.jq 에 def unquoted 가 없다 (#346)"; exit 1; }
[ -n "$unq_sweep" ] || { echo "  ✗ scripts/resume-sweep.sh 에 def unquoted(JQ_UNQUOTE) 가 없다 (#346)"; exit 1; }
[ "$unq_lib" = "$unq_sweep" ] \
  || { echo "  ✗ def unquoted 정의가 lib/loop.jq 와 resume-sweep.sh 에서 다르다 — 한 벌로 맞춰라 (#346)"; exit 1; }
# 소비 배선(loop-status 가 실제로 unquoted 로 걸러 세는가)은 문구 grep 이 아니라 동작으로
# 문다 — loop-status.test.sh 의 Holds #39(인용 마커 1 + 실제 마커 1 → `1/1`, `2/1` 아님).

# 행 71-a — 커밋 신선도 판정(STALL_MIN 값·queue_alive 술어)은 progress-evidence.sh ·
# scripts/lib/constants.sh 두 자리 밖에 없어야 한다(#200 → #206 · #427). 판정선은
# 정의다: 산문·주석의 언급(`STALL_MIN 이내` 등)은 사본이 아니므로 안 건다.
# 만료 조건: 없음 — 이 가드가 SSOT 강제자다.
assert_single_def '^STALL_MIN=|^: "\$\{STALL_MIN:=|^queue_alive\(\)' \
  'scripts/*.sh scripts/lib/*.sh' \
  '^scripts/progress-evidence\.sh$|^scripts/lib/constants\.sh$' \
  '진행 증거 술어 정의가 progress-evidence.sh 밖에도 있다'

# 행 72-c — ISSUE_TIMEBOX_HOURS 기본값은 scripts/lib/constants.sh 의
# `: "${ISSUE_TIMEBOX_HOURS:=1}"` 한 자리(1벌)여야 하고, timebox-check.sh ·
# progress-evidence.sh 두 리더가 그 상수를 읽어야 한다(#206 · #427 — #539 codex 1회차 P2
# 재판정으로 L4 편입: constants.sh 머리 주석은 값 자리를 설명할 뿐 밖의 새 정의를
# 거부하지 못한다). claim 신선도 상한이 timebox 와 다른 기본값을 쓰면 스윕과
# ① Reconcile 이 서로 다른 창에서 같은 워커를 살리고 죽인다. 만료 조건: 없음.
tb_defaults=$(grep -ho 'ISSUE_TIMEBOX_HOURS:[-=][0-9]*' scripts/*.sh scripts/lib/*.sh | sort -u)
tb_n=$(printf '%s\n' "$tb_defaults" | grep -c . || true)
[ "$tb_n" -ge 1 ] \
  || { echo "  ✗ ISSUE_TIMEBOX_HOURS 기본값을 읽는 자리가 없다 — 가드가 의미를 잃었다"; exit 1; }
[ "$tb_n" = 1 ] \
  || { echo "  ✗ ISSUE_TIMEBOX_HOURS 기본값이 파일마다 다르다: $(printf '%s ' $tb_defaults)"; exit 1; }
for f in scripts/timebox-check.sh scripts/progress-evidence.sh; do
  grep -qF 'ISSUE_TIMEBOX_HOURS' "$f" \
    || { echo "  ✗ $f 가 ISSUE_TIMEBOX_HOURS 를 읽지 않는다 — 두 자리가 같은 상수를 써야 한다"; exit 1; }
done

# 행 74 — iso_to_epoch 형식 패턴은 모든 사본(finish-classify.sh · progress-evidence.sh 등
# 현재 3개)에서 동일해야 한다(#206). 한쪽만 느슨해지면 조용히 갈린다 — 한쪽은 판정을
# 내고 한쪽은 항상 active 가 된다. 만료 조건: iso_to_epoch 이 scripts/lib/ 한 자리로
# 합쳐지면 즉시.
pat_count=$(grep -h -o '\[0-9\]\[0-9\]\[0-9\]\[0-9\]-\[0-9\]\[0-9\]-.*Z) ;;' scripts/*.sh | sort -u | wc -l | tr -d ' ')
[ "$pat_count" = 1 ] || {
  echo "  ✗ iso_to_epoch 형식 패턴이 ${pat_count}가지다 — 한 문장으로 통일하라:"
  grep -hn -o '\[0-9\]\[0-9\]\[0-9\]\[0-9\]-\[0-9\]\[0-9\]-.*Z) ;;' scripts/*.sh | sort -u | sed 's/^/      /'
  exit 1; }
for f in $(grep -l '^iso_to_epoch()' scripts/*.sh); do
  grep -qF '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;' "$f" \
    || { echo "  ✗ $f: iso_to_epoch 에 형식 검사가 없다(GNU date 가 빈 값을 통과시킨다)"; exit 1; }
done

# 행 83-b — epic_of 정규식은 scripts/loop-status.sh 에 한 벌뿐이어야 한다(#292 개발 계획
# 3항). 복제본이 생기면 두 계산기가 서로 다른 leaf 를 세고, 그 차이는 출력에 안 보인다.
# -F 로 고정 문자열 비교한다 — 이 패턴 자체가 정규식 메타문자 덩어리라 BRE 로 적으면
# 이스케이프 하나가 어긋나도 0벌이 되어 가드가 조용히 통과한다(실제로 그렇게 틀렸다).
# set -e 아래라 grep -c 가 0매치로 exit 1 하면 스크립트가 죽으므로 || true 로 받는다.
# 만료 조건: 정규식이 lib/loop.jq 로 가면.
epic_of_n=$(grep -cF -- 'capture("^[[:space:]]*epic[[:space:]]+#' scripts/loop-status.sh || true)
[ "$epic_of_n" = 1 ] \
  || { echo "  ✗ scripts/loop-status.sh 의 epic_of 정규식이 $epic_of_n 벌이다 — 한 벌이어야 한다(#292)"; exit 1; }

# 행 84-b — 창 상수 RESUME_AFTER_MIN 정의는 scripts/lib/constants.sh 한 자리(#364).
# hold:ladder 설명이 가리키는 창 상수명은 실제 정의와 같은 철자여야 한다 — 상수를
# 개명하면 설명이 없는 이름을 가리킨다. 만료 조건: 라벨 정의·상수 목록이
# setup-labels.test.sh 로 넘어가면.
grep -qE '^: "\$\{RESUME_AFTER_MIN:=' scripts/lib/constants.sh \
  || { echo "  ✗ scripts/lib/constants.sh: 창 상수 RESUME_AFTER_MIN 정의가 없다 — hold:ladder 설명이 가리키는 상수명 (#364)"; exit 1; }
