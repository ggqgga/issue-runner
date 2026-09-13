#!/usr/bin/env bash
# 단계 6 — closeout 레인의 문서 계약: SKILL 이벤트 행선지 · 머신 코멘트 센티널 ·
# 프롬프트 템플릿의 런타임 치환 슬롯 · 네이티브↔폴백 배타성 · codex 호출 상한.
# 전부 「지우면 프롬프트가 빈 컨텍스트로 돌거나 봇이 이벤트를 흘려보낸다」 부류다.
#
# 실패 시: `  ✗ <파일> 에 <슬롯|문구> 없음` 계열 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 91–242행):
#   • [closeout ① Reconcile] human_hold 행선지            (행 16 · 부행 16-b · #271 ⑺)
#   • [closeout] 머신 코멘트 sentinel 마커 주입 지시      (행 24 · #72)
#   • [closeout] references placeholder 검사              (행 26 · #54 · #207 · #261)
#   • [#261] spinoff-inherit — <EPIC_LINE> 슬롯 앵커 + 격자 러너 (행 27 · 부행 27-b·27-d)
#   • [test] spinoff-issue.sh 파생 발행 격자              (행 28 · #447)
#   • [#411] closeout 6단계 판정 표·파생 판정 코멘트·출처 줄 (표 신규 행 · #411)
#   • [closeout] ③-1 네이티브↔폴백 프롬프트 동기화        (행 29 · #207 attempt8)
#   • [closeout·verify-runner] codex 호출 상한 불변       (행 31 · #375)
#   • [closeout] smoke-prompt 한/영 placeholder           (행 32 · #69)
#   • [closeout] verifier-prompt lessons 주입 placeholder (행 38 · #80)
#
# 만료 조건 — 치환 슬롯 축(26·27-b·32·38): 프롬프트 조립이 산문이 아니라 스크립트
# 인자로 옮겨질 때. 센티널(24): 주입이 코멘트 게시 스크립트로 갈 때. 배타성(29): 두
# 프롬프트가 한 템플릿+인자로 합쳐질 때. 상한(31): CODEX_REVIEW_LIMIT 값이
# scripts/lib/constants.sh 로 이사하면 ⓑ. #411: 6단계 판정 표가 스크립트로 갈 때.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[closeout ① Reconcile] SKILL 한/영 이벤트 목록에 human_hold 행선지가 있는가 (#271 ⑺)"
# 스크립트가 내는 이벤트에 SKILL 쪽 목적지가 없으면 봇은 그 줄을 그냥 흘려보낸다 —
# 사람이 붙인 보류가 아무 데도 도착하지 않고 PR 이 레인에 남는다. 판정 자체(needs-human
# 있음/없음/미상 → human_hold·resume)는 scripts/tests/closeout-reconcile.test.sh 가 문다.
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qF 'human_hold' "$f" \
    || { echo "  ✗ $f 의 ① Reconcile 이벤트 목록에 human_hold 행선지가 없다 — 이벤트에 목적지가 없으면 봇이 무시한다 (#271 ⑺)"; exit 1; }
done

echo "[closeout] 머신 코멘트 sentinel 마커 주입 지시 검사 (#72)"
# 워커/closeout 머신 코멘트에 <!-- bodat:worker --> 마커를 박으라는 지시가 워커
# 템플릿(한/영)+closeout SKILL(한/영) 양쪽에 있어야 한다. 빠지면 접두사 allowlist 회귀.
for f in references/worker-template.md references/worker-template.en.md \
         skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qF '<!-- bodat:worker -->' "$f" || { echo "  ✗ $f 에 sentinel 마커 주입 지시 없음"; exit 1; }
done

echo "[closeout] references placeholder 검사"
# macOS 기본 bash 3.2 는 declare -A 미지원 — case 분기로 파일별 placeholder 매핑.
for f in skills/closeout/references/verifier-prompt.md \
         skills/closeout/references/verifier-prompt-fallback.md \
         skills/closeout/references/deploy-check-issue.md \
         skills/closeout/references/spinoff-issue.md; do
  [ -f "$f" ] || { echo "  ✗ 누락: $f"; exit 1; }
  case "$f" in
    # <ISSUE_BODY>: 검증자가 sandbox 네트워크 없이 이슈 수용 기준을 판정하도록 메인
    # 세션이 이슈 본문을 동봉하는 지점 — 지우면 원문 fetch 회귀(#54). diff 는 동봉하지
    # 않는다 — #134 내장 리뷰어가 `--base` 범위를 이 프롬프트 지시로 워크트리에서
    # 직접 읽는다(#207: 동봉 전제 문구와 SKILL 의 "동봉 안 함" 이 정면 충돌해 fail-open).
    *verifier-prompt-fallback.md)
      # 폴백(general-purpose)은 Agent 툴에 --cd 대응 인자가 없어 워크트리에 스코프
      # 안 된다 — 그래서 네이티브 템플릿과 달리 <DIFF> 를 실제로 동봉해야 한다(#207
      # attempt8). <BASE> 는 없다 — 폴백은 --base 를 넘기지 않고 동봉 diff 로만 판정한다.
      phs="<PR> <REPO> <PLAN_REF> <ISSUE_BODY> <DIFF>" ;;
    *verifier-prompt.md)    phs="<PR> <REPO> <BASE> <PLAN_REF> <ISSUE_BODY>" ;;
    *deploy-check-issue.md) phs="<PR> <SHA> <SUMMARY> <DEPLOY_CMD> <LIVE_CHECKS> <VERIFY_URL>" ;;
    # <EPIC_LINE>: 파생이 부모의 에픽을 본문 **첫 줄**(`Epic #N`)로 물려받는 자리 (#261).
    # 지우면 파생이 에픽 밖 고아가 되고 loop-status 에픽 절의 leaf 집계에서 사라진다.
    # <ORIGIN_LINE>: 둘째 줄 `Spinoff of PR #<pr> (issue #<부모>)` — spinoff-issue.sh 가 채운다 (#411).
    *spinoff-issue.md)      phs="<EPIC_LINE> <ORIGIN_LINE> <BACKGROUND> <REASON> <PLAN> <TEST_PLAN> <RELATED>" ;;
  esac
  # shellcheck disable=SC2086
  for ph in $phs; do
    grep -qF "$ph" "$f" || { echo "  ✗ $f 에 $ph 없음"; exit 1; }
  done
done
# 네이티브↔폴백 파일 간 전제 교차오염 방지 검사는 아래 "③-1 네이티브↔폴백 프롬프트
# 동기화 검사"(#207 attempt8) 에서 한다.

echo "[#261] spinoff-inherit 헬퍼 — 실행비트·Epic 정규식 SSOT 동기화·격자 테스트"
# closeout 6단계가 `$SCRIPTS/spinoff-inherit.sh` 로 직접 exec 하므로 실행 비트를 여기서 문다.
# 비트가 빠지면 조용히 exit 126 → `eval` 이 빈 문자열을 먹어 `$priority` 가 **빈 값**이 되고,
# `gh issue create --label ""` 로 발행이 통째로 실패하거나 무라벨 이슈가 남는다(PR#173 말미의
# "새 헬퍼는 실행 비트가 빠지면 값이 항상 빈 값이 되어 조용히 degrade" 와 같은 함정).
# `<EPIC_LINE>` 은 머리 주석의 *설명*이 아니라 본문 **첫 줄 자리**여야 한다 — HTML 주석이
# 끝난 뒤 첫 비지 않은 줄이 정확히 `<EPIC_LINE>` 이어야, 채워진 본문의 첫 줄이 `Epic #N` 이
# 되고 6단계 '발행 직후 확인' 의 "첫 줄이 Epic #N 인가" 가 참이 될 수 있다. 위 placeholder
# 검사는 **파일 어딘가**에 문자열이 있으면 통과하므로, 슬롯이 지워지고 주석 언급만 남은
# 회귀를 못 본다(실측으로 확인한 사각지대 — 그래서 이 줄 앵커 검사가 따로 필요하다).
tpl_slot=$(sed -n '/-->/,$p' skills/closeout/references/spinoff-issue.md \
  | sed '1s/.*-->//' | grep -v '^[[:space:]]*$' | head -1)
[ "$tpl_slot" = '<EPIC_LINE>' ] \
  || { echo "  ✗ spinoff-issue.md: 머리 주석 뒤 첫 줄이 <EPIC_LINE> 슬롯이 아니다 (실제=[$tpl_slot])"; exit 1; }
# `Epic #N` **전용 줄** 정규식의 SSOT 는 `loop-status.sh` 의 `epic_of`(#260) 다. 파생의 에픽
# 판정(spinoff-inherit)과 에픽 절의 leaf 판정(loop-status)이 갈라지면 두 경로가 서로 다른
# 세계를 재게 된다 — #216 교훈("같은 X 를 쓴다"는 단언은 갈래마다 실제로 참인지 확인하라).
# 두 파일에 **문자 그대로 같은 문자열**이 있는지 문다(한쪽만 고치면 여기서 빨개진다).
bash scripts/tests/spinoff-inherit.test.sh

echo "[test] spinoff-issue.sh 파생 발행 격자 — 상속·Epic 첫 줄·라벨 3단 fail-closed·부모 PR 마커 (#447)"
bash scripts/tests/spinoff-issue.test.sh

echo "[#411] closeout 6단계 판정 표(ⓐ~ⓔ)·파생 판정 코멘트·출처 줄 — 검증자 잔여를 필사하지 않는다 (한/영)"
# 6단계가 리뷰어 항목을 그대로 이슈로 옮겨 WARN 잔여 파생이 33건+ 쌓였다(2026-09-13 실측, 사람과 다시
# 읽으니 이슈가 맞는 것 0/10). 판정 표 다섯 갈래·판정 코멘트·출처 줄이 6단계 구간(`**6단계 —` ~ `## ⑤`)에
# 있어야 하고, 템플릿엔 <EPIC_LINE> 바로 다음 줄에 <ORIGIN_LINE> 슬롯이, 표면 교정 판정 SSOT(loop-conventions
# §10)엔 "이 PR 이 도입한 가드" 흡수 문장이 있어야 한다. 출처 줄 치환 자체는 spinoff-issue.test ⑪ 이 문다.
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  case "$f" in *.en.md) s6='^\*\*Step 6 —' ;; *) s6='^\*\*6단계 —' ;; esac
  s6_line=$(grep -nE "$s6" "$f" | head -1 | cut -d: -f1 || true)   # 무매치는 아래 진단이 잡는다(pipefail 로 조용히 죽지 않게)
  d_line=$(grep -nE '^## ⑤' "$f" | head -1 | cut -d: -f1 || true)
  [ -n "$s6_line" ] && [ -n "$d_line" ] || { echo "  ✗ $f: 6단계/⑤ 앵커 없음"; exit 1; }
  seg=$(sed -n "${s6_line},${d_line}p" "$f")
  for tok in '| ⓐ ' '| ⓑ ' '| ⓒ ' '| ⓓ ' '| ⓔ ' '파생 판정:' 'Spinoff of PR #'; do
    printf '%s\n' "$seg" | grep -qF -- "$tok" \
      || { echo "  ✗ $f: 6단계 구간에 '$tok' 없음 (판정 표·판정 코멘트·출처 줄)"; exit 1; }
  done
done
# 슬롯은 **줄 전체**로 문다 — 머리 주석에도 같은 문자열이 있어 -F 부분 일치는 슬롯을 지워도 초록이다.
# 자리도 문다: <EPIC_LINE> 바로 다음 줄이어야 "둘째 줄" 계약이 참이다.
origin_slot=$(grep -A1 -xF '<EPIC_LINE>' skills/closeout/references/spinoff-issue.md | tail -1 || true)
[ "$origin_slot" = "<ORIGIN_LINE>" ] \
  || { echo "  ✗ spinoff-issue.md: <EPIC_LINE> 다음 줄이 <ORIGIN_LINE> 이 아니다(없거나 자리가 틀림, 실제=[$origin_slot])"; exit 1; }
# §10 은 예시(받는 것)보다 규칙(막는 것)이 판정을 바꾼다 — 종전 "새 가드" 평서 금지가 머리 기준과 충돌하던 자리.
for tok in '이 PR 이 도입한 가드' '다른 동작을 **새로 무는**'; do
  grep -qF -- "$tok" references/loop-conventions.md \
    || { echo "  ✗ loop-conventions.md §10: '$tok' 없음 — 표면 교정 판정이 #411 이전 문구로 되돌아갔다"; exit 1; }
done

echo "[closeout] ③-1 네이티브↔폴백 프롬프트 동기화 검사 (#207 attempt8)"
# 이 이슈의 뿌리는 SKILL.md 가 폴백(general-purpose)이 diff 를 동봉한다고 적어놓고
# 실제로는 네이티브 전용 템플릿(<DIFF> 없음·"이 워크트리는 최신" 전제)을 그대로
# 재사용해 그 주장이 거짓이었던 것이다. 한쪽만 고쳐도(문서가 새 파일명을 안 부르거나,
# 새 파일이 실제로 diff 를 안 담으면) 여기서 빨개져야 한다.
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qF 'verifier-prompt-fallback.md' "$f" \
    || { echo "  ✗ $f 이 폴백 전용 템플릿(verifier-prompt-fallback.md)을 이름으로 지목하지 않는다 — 네이티브 템플릿과 같은 파일을 쓴다고 오독될 수 있다(#207)"; exit 1; }
done
[ -f skills/closeout/references/verifier-prompt-fallback.md ] \
  || { echo "  ✗ skills/closeout/references/verifier-prompt-fallback.md 없음"; exit 1; }
grep -qF '<DIFF>' skills/closeout/references/verifier-prompt-fallback.md \
  || { echo "  ✗ verifier-prompt-fallback.md 에 <DIFF> placeholder 없음 — 폴백은 --cd 로 스코프되지 않아 diff 를 실제로 동봉해야 한다(#207)"; exit 1; }
grep -qF '<DIFF>' skills/closeout/references/verifier-prompt.md \
  && { echo "  ✗ verifier-prompt.md(네이티브)에 <DIFF> 가 있음 — 동봉 전제는 verifier-prompt-fallback.md 전용이어야 한다(#207 원 결함 재발)"; exit 1; }
grep -qF '이 워크트리는' skills/closeout/references/verifier-prompt-fallback.md \
  && { echo "  ✗ verifier-prompt-fallback.md 에 네이티브 전용 워크트리 전제 문구가 있음 — general-purpose 는 --cd 로 스코프되지 않아 거짓이다(#207)"; exit 1; }

echo "[closeout·verify-runner] codex 호출 상한 불변 가드 (#375)"
# codex 는 PR 당 2회이고 둘 다 verify-runner 몫이다(사용자 결정 2026-09-13). closeout 1단계가 세 번째로
# 부르던 호출이 되살아나거나, verify-runner 의 상한 상수가 사라지면 회차 비용이 조용히 되돌아간다.
if grep -qE 'codex-review-gate\.sh --' skills/closeout/SKILL.md skills/closeout/SKILL.en.md; then
  echo "  ✗ closeout SKILL 에 codex-review-gate.sh 호출이 있다 — 1단계는 general-purpose 계획 부합 한 번뿐(#375)"; exit 1
fi
grep -qF 'CODEX_REVIEW_LIMIT = 2' skills/verify-runner/SKILL.md \
  || { echo "  ✗ verify-runner SKILL.md 에 'CODEX_REVIEW_LIMIT = 2' 가 없다 — PR 당 codex 2회 상한(#375)"; exit 1; }

echo "[closeout] smoke-prompt 한/영 placeholder 검사 (#69)"
# 5단계 Chrome 스모크 동봉형 프롬프트(verifier-prompt.md 미러) — 한/영 양쪽이
# 존재하고 두 placeholder 를 다 담아야 한다. <VERIFY_URL>=production 베이스 URL,
# <LIVE_CHECKS>=배포 이슈 본문의 검증 항목 — 5단계가 런타임에 치환하는 계약.
# 지우면 동봉형 프롬프트가 깨져 스모크가 빈 컨텍스트로 도는 회귀.
for f in skills/closeout/references/smoke-prompt.md \
         skills/closeout/references/smoke-prompt.en.md; do
  [ -f "$f" ] || { echo "  ✗ 누락: $f"; exit 1; }
  for ph in '<VERIFY_URL>' '<LIVE_CHECKS>'; do
    grep -qF "$ph" "$f" || { echo "  ✗ $f 에 $ph 없음"; exit 1; }
  done
done

echo "[closeout] verifier-prompt lessons 주입 placeholder 검사 (#80 변경 4)"
# 1단계 검증자가 과거 오판 패턴(인용 오판·base 맹점 등)을 반복하지 않도록 lessons 를
# 프롬프트에 주입한다 — 프롬프트가 유일한 전달 경로라는 기존 계약 유지.
# (<LESSONS_OR_ 는 접미사가 언어별로 다를 수 있어 워커 템플릿과 동일하게 접두만 본다.)
grep -qF '<LESSONS_OR_' skills/closeout/references/verifier-prompt.md \
  || { echo "  ✗ verifier-prompt.md 에 <LESSONS_OR_ placeholder 없음"; exit 1; }
grep -qF '<LESSONS_OR_' skills/closeout/references/verifier-prompt-fallback.md \
  || { echo "  ✗ verifier-prompt-fallback.md 에 <LESSONS_OR_ placeholder 없음"; exit 1; }
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  awk 'BEGIN{RS="";ok=0} /<LESSONS_OR_/ && /lessons(-verifier)?\.md/ {ok=1} END{exit ok?0:1}' "$f" \
    || { echo "  ✗ $f: 1단계 검증자에 lessons 주입(<LESSONS_OR_ ← lessons-verifier.md) 지시 없음"; exit 1; }
done

