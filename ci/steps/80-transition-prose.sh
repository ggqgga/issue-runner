#!/usr/bin/env bash
# 단계 9 — 전이·정지·보류를 **산문이 아니라 transition.sh 로** 한다는 계약. 라벨 이동을
# 손으로 적는 형태가 되살아나면 PR 과 이슈의 라벨이 갈리고 다음 틱이 어긋난 쪽을
# 진실로 읽는다. 문단 스코프 계약(①-b 대상 필터·규칙0·policy_review_due 순서)도 여기다 —
# 이 문단들은 모델이 실제로 실행하는 지시라 형태가 곧 동작이다.
#
# 실패 시: `  ✗ <파일>: <어긋난 형태>` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 445–576행):
#   • [#147] 정지·보류 전이 서술 계약 (행 81 · 부행 81-b~81-j ·
#     #147 · #151 · #155 · #163 · #244 · #275 · #344 · #375)
#   • [#144] 전이·스냅샷 스크립트 배선 문서화 (행 82 · 부행 82-a·82-b(워커 템플릿 축)·82-c)
#
# 사다리 포인터 축(81-a)과 needs-human+hold:* 쌍 서술 금지 축(81-h 일부)은 #541 이
# ci/guards/prose-regression.sh 로 옮겼다 — 단계 3 이 부른다.
#
# 공유 함수 `check_phrase` 는 ci/lib.sh 에 있다(#524).
#
# 만료 조건 — 81-b~81-d·81-i·81-j·82-a·82-c: 그 계약이 스크립트 인자로 옮겨질 때.
# 81-e(문단 순서)·81-f·81-g·81-h: ①-b 대상 필터·규칙0 문단이 스크립트 인자로 갈 때.
# 82-b 워커 템플릿 축: state-machine.md 「전이 실패의 공통 규칙」 이 ④ Report 로 한정한
# 범위를 넓혀 워커 템플릿까지 인수하면 즉시.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[#147] 정지·보류 전이 서술 계약 — --reason/--note 필수 · 산문 needs-human 금지 · policy-kept 순서 · ①-b 대상 필터"
# (사다리 포인터 축 81-a 는 ci/guards/prose-regression.sh 로 갔다 — #541.)
for f in SKILL.md SKILL.en.md skills/verify-runner/SKILL.md skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  if grep -nE 'transition\.sh (verify-held|closeout-blocked|runner-held) [^\n]*' "$f" | grep -v -- '--reason' | grep -q .; then
    echo "  ✗ $f: --reason 없는 verify-held/closeout-blocked/runner-held 호출"; exit 1; fi
  # policy·conflict 사유엔 --note 한 줄이 필수(#155) — policy 는 사람이 답할 질문, conflict 는
  # 재개 워커가 받을 범위(#344, closeout ③ CONFLICTING 항목). 어느 쪽이든 없으면 빨강.
  if grep -nE 'transition\.sh [a-z-]+ <repo>[^\n]*--reason (policy|conflict)' "$f" | grep -v -- '--note' | grep -q .; then
    echo "  ✗ $f: --note 없는 --reason policy|conflict 호출 — policy 는 질문 한 줄, conflict 는 워커 재개 범위 한 줄(#344)을 적으라"; exit 1; fi
  # 맨 needs-human 산문 작성 금지(#151) — 사유 없는 사람 대기는 loop-status 가 warn 하고 재개 스윕이 거부한다.
  # #214 의 예외(4단계 배포 티켓 발행 직후 라벨 보강이 needs-human 을 deploy-wait 와 함께
  # 되살리는 줄)는 #243 으로 **소비자가 사라져** 걷어냈다 — 그 보강은 이제 deploy-wait 하나만
  # 붙인다. 예외를 남겨 두면 산문으로 needs-human 을 되돌릴 통로가 그대로 열려 있다.
  if grep -nE -- '--add-label "?needs-human"?' "$f" | grep -q .; then
    echo "  ✗ $f: 산문 --add-label needs-human — runner-held/verify-held/closeout-blocked --reason 을 쓰라"; exit 1; fi
done
for f in SKILL.md SKILL.en.md; do grep -qF "resume-sweep.sh" "$f" || { echo "  ✗ $f: 재개 스윕 배선 없음"; exit 1; }; done
# (#244) 재심 "사람 몫 유지" 판정의 needs-human 부착 배선 — 이게 빠지면 `hold:policy` 재심이
# 끝나도 사람 호출 신호가 아무 데도 안 남는다(기계 정지에서 needs-human 을 뗀 뒤 남는 유일한
# 생산자다). 산문 `--add-label needs-human` 은 위 가드가 막으므로 전이로만 배선된다.
for f in SKILL.md SKILL.en.md; do
  grep -qF 'transition.sh policy-kept' "$f" \
    || { echo "  ✗ $f: 재심 '사람 몫 유지' 의 policy-kept 배선 없음 (#244)"; exit 1; }
done
grep -qE '^  policy-kept\)' scripts/transition.sh \
  || { echo "  ✗ scripts/transition.sh: policy-kept 전이 없음 (#244)"; exit 1; }
# (#244) 순서 계약 — **전이 먼저, 마커 나중**. `<!-- policy-review: kept -->` 는 resume-sweep 이
# "재심 끝"(reviewed)으로 읽는 유일한 신호라, 마커를 전이보다 먼저 올리면 `policy-kept` 가
# exit 1/2/64 로 죽어도 다음 틱부터 그 건이 접혀 `needs-human` 이 영영 안 붙고 `policy_review_due`
# 가 다시는 안 난다(사람 결정이 needs-human 칸에서 봉인). 문단 스코프로 좁힌다(#223) — 파일 다른
# 곳의 같은 문자열이 순서를 대신 만족시키면 가드가 무의미해진다.
for f in SKILL.md SKILL.en.md; do
  pr_s=$(grep -n '^- `policy_review_due`' "$f" | head -1 | cut -d: -f1)
  pr_e=$(grep -n '^- `waiting`' "$f" | head -1 | cut -d: -f1)
  { [ -n "$pr_s" ] && [ -n "$pr_e" ]; } \
    || { echo "  ✗ $f: policy_review_due 불릿 경계(다음 불릿 \`waiting\`)를 못 찾았다 (#244)"; exit 1; }
  pr_body=$(sed -n "${pr_s},${pr_e}p" "$f")
  t_line=$(printf '%s\n' "$pr_body" | grep -nF 'transition.sh policy-kept' | head -1 | cut -d: -f1)
  m_line=$(printf '%s\n' "$pr_body" | grep -nF '<!-- policy-review: kept -->' | head -1 | cut -d: -f1)
  { [ -n "$t_line" ] && [ -n "$m_line" ]; } \
    || { echo "  ✗ $f: policy_review_due 불릿에 policy-kept 전이 또는 kept 마커가 없다 (#244)"; exit 1; }
  [ "$t_line" -lt "$m_line" ] \
    || { echo "  ✗ $f: kept 마커가 policy-kept 전이보다 앞이다 — 전이가 죽으면 재심이 봉인된다 (#244)"; exit 1; }
  printf '%s\n' "$pr_body" | grep -qF 'BLOCKED: 전이 실패 policy-kept' \
    || { echo "  ✗ $f: 전이 비0 시의 목적지(\`BLOCKED: 전이 실패 policy-kept\` · 마커 미부착)가 없다 (#244)"; exit 1; }
done
# (#244) closeout ①-b 스윕 **대상 필터** — 기계 정지의 마지막 소비자. 이 필터는 `needs-human`
# 미부착만 보던 자리인데, #244 가 기계 정지에서 그 라벨을 떼므로 홀드된 PR(harvesting·
# flow:verify·needs-human 이 전부 없고 `hold:*` 만 남은 PR)이 매 틱 다시 대상이 된다 —
# hold-note 를 다시 달고, `stale_reverify` 갈래에선 `closeout-redispatch` 가 verify-runner 가
# 방금 세운 홀드를 통째로 벗긴다(#151 재현). 그래서 ⑴ **대상 문단 안에** `hold:` 접두
# 미부착이 함께 적혀 있어야 하고(문단 스코프 — 파일 아무 데나 `hold:` 가 있다고 통과하지
# 않는다), ⑵ 같은 두 파일이 기계 정지를 `needs-human`+`hold:*` **쌍**으로 계속 광고하면
# 안 된다(전이는 이제 사유 라벨 하나만 붙인다 — 읽는 사람과 다음 구현자가 서로 다른
# 계약을 믿게 된다, #191).
awk 'BEGIN{RS="";ok=0} /\*\*대상\*\*:/ && /`hold:` 접두 미부착/ {ok=1} END{exit ok?0:1}' skills/closeout/SKILL.md \
  || { echo "  ✗ skills/closeout/SKILL.md: ①-b 대상 문단에 \`hold:\` 접두 미부착 필터 없음 (#244)"; exit 1; }
awk 'BEGIN{RS="";ok=0} /\*\*Targets\*\*:/ && /no `hold:`-prefixed label/ {ok=1} END{exit ok?0:1}' skills/closeout/SKILL.en.md \
  || { echo "  ✗ skills/closeout/SKILL.en.md: ①-b Targets 문단에 no \`hold:\`-prefixed label 필터 없음 (#244)"; exit 1; }
# (#275) 같은 대상 문단이 verify-runner **점유** 라벨 `verifying` 도 제외해야 한다 — `flow:verify`
# 는 검증대기이고 `verifying` 은 verify-runner 가 집는 순간 flow:verify 를 떼고 붙이는 점유
# 라벨(harvesting 동형)이라, 이 문단이 `flow:verify` 만 보면 검증이 **지금 도는** PR 이
# 스윕의 입양·재디스패치 대상이 된다(closeout-eligible.sh 는 둘 다 제외한다 — 스윕 문단만
# 빠지면 두 필터가 갈린다). 문단 스코프로 잰다 — 파일 아무 데나 `verifying` 이 있다고 통과하지 않는다.
awk 'BEGIN{RS="";ok=0} /\*\*대상\*\*:/ && /`verifying` 미부착/ {ok=1} END{exit ok?0:1}' skills/closeout/SKILL.md \
  || { echo "  ✗ skills/closeout/SKILL.md: ①-b 대상 문단에 \`verifying\` 미부착 필터 없음 (#275)"; exit 1; }
awk 'BEGIN{RS="";ok=0} /\*\*Targets\*\*:/ && /not labeled `verifying`/ {ok=1} END{exit ok?0:1}' skills/closeout/SKILL.en.md \
  || { echo "  ✗ skills/closeout/SKILL.en.md: ①-b Targets 문단에 not labeled \`verifying\` 필터 없음 (#275)"; exit 1; }
# issue-runner ② Maintain 규칙0(단계 라벨 보정)·소유 규칙도 `verifying` PR 을 건드리지 않아야 한다 —
# 보정이 `🔄` 만 보고 `flow:verify` 를 되붙이면 검증 중인 PR 에 단계 라벨이 둘이 된다.
awk 'BEGIN{RS="";ok=0} /\*\*0\. 단계 라벨 보정/ && /`verifying`/ {ok=1} END{exit ok?0:1}' SKILL.md \
  || { echo "  ✗ SKILL.md: ② Maintain 규칙0 문단이 \`verifying\` PR 을 건너뛰지 않는다 (#275)"; exit 1; }
# (#244 WARN) 같은 파일 안에서 계약이 **두 값**으로 갈리지 않게 — `verify-runner` 의 ④ held 절차문은
# `transition.sh verify-held` 가 붙일 수 있는 라벨(`hold:<reason>`)만 광고해야 한다. 옛 문구(재디스패치
# 상한 초과를 `needs-human` 으로 승격)는 붙일 수 없는 라벨이라 읽는 사람과 다음 구현자가 서로 다른
# 계약을 믿는다(#191 과 같은 자리). #375 부터 리뷰 반송 상한은 held 사유가 아니다(codex 2회 → 3회차
# 자체 리뷰 완료) — 그 옛 서술(`상한 초과 → hold:policy`)이 되살아나면 여기서 빨강.
if grep -nE '`needs-human` *으로 승격' skills/verify-runner/SKILL.md | grep -q .; then
  echo "  ✗ skills/verify-runner/SKILL.md: 재디스패치 상한 초과를 needs-human 승격으로 서술 — 정지는 \`hold:<reason>\` 다 (#244)"; exit 1; fi
grep -qF 'verify-held <repo> <issue|-> <pr> --reason' skills/verify-runner/SKILL.md \
  || { echo "  ✗ skills/verify-runner/SKILL.md: held 가 transition.sh verify-held --reason 으로 정지한다는 서술 없음 (#244)"; exit 1; }
if grep -qE '상한 초과\*\* → `policy`|재디스패치 상한 초과\(VERIFY_ATTEMPTS_LIMIT\)' skills/verify-runner/SKILL.md; then
  echo "  ✗ skills/verify-runner/SKILL.md: 리뷰 반송 상한 초과를 hold:policy 사유로 서술 — #375 부터 3회차는 자체 리뷰로 완료한다"; exit 1; fi
# 루프 현황 대시보드(#163) — 세 루프 ④ Report 가 --post 로 게시해야 깃헙만 보고 현황을 안다.
for f in SKILL.md SKILL.en.md skills/verify-runner/SKILL.md skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qE 'loop-status\.sh --post (issue-runner|verify-runner|closeout)' "$f" || { echo "  ✗ $f: loop-status.sh --post 배선 없음"; exit 1; }
done

echo "[#144] 전이·스냅샷 스크립트 배선 문서화 검사 — 세 루프 SKILL + 워커 템플릿"
# 루프 문서가 산문 `gh issue edit` 대신 scripts/transition.sh(전이 표 SSOT)를 부르고,
# ④ Report 가 scripts/loop-status.sh 스냅샷을 붙이는지. 배선이 빠지면 라벨이 한쪽만
# 옮겨져 PR·이슈가 갈리고(다음 틱이 어긋난 쪽을 진실로 읽는다), 재고가 아무 보고에도
# 안 나온다.
for tok in 'transition.sh verify-pass' 'transition.sh verify-redispatch' \
           'transition.sh verify-held' 'loop-status.sh'; do
  grep -qF -- "$tok" skills/verify-runner/SKILL.md \
    || { echo "  ✗ skills/verify-runner/SKILL.md 에 '$tok' 배선 없음"; exit 1; }
done
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  for tok in 'transition.sh closeout-pick' 'transition.sh closeout-blocked' \
             'loop-status.sh' '--label spinoff' '--label deploy-wait'; do
    grep -qF -- "$tok" "$f" || { echo "  ✗ $f 에 '$tok' 배선 없음"; exit 1; }
  done
done
for f in SKILL.md SKILL.en.md; do
  grep -qF -- 'loop-status.sh' "$f" || { echo "  ✗ $f 에 loop-status.sh 스냅샷 배선 없음"; exit 1; }
done
for f in references/worker-template.md references/worker-template.en.md; do
  grep -qF -- 'transition.sh handoff-verify' "$f" \
    || { echo "  ✗ $f 에 transition.sh handoff-verify 배선 없음"; exit 1; }
done
# 전이 실패(exit 1 readback 불일치 · 2 gh 실패)를 조용히 넘기지 않는다는 보고 규약 —
# **워커 템플릿 축만** 여기서 본다. 세 루프 SKILL 의 `BLOCKED: 전이 실패 …` 는
# `references/state-machine.md` 「전이 실패의 공통 규칙」 이 인수했다(그 절 제목이 "세 SKILL 이
# 각자 14회 재진술하던 것" 이다 · 문구까지 그 자리에 있다). 워커 템플릿은 ④ Report 가 없어
# 그 절의 범위 밖이라 종료 보고 문구(`전이 실패: handoff-verify`)를 여기서 계속 문다.
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/../lib.sh"
check_phrase references/worker-template.md    '전이 실패: handoff-verify'
check_phrase references/worker-template.en.md '전이 실패: handoff-verify'
# 산문 회귀 가드 — 위 파일들에서 손수 라벨을 옮기는 형태가 되살아나면 실패.
# (`--add-label` 형태만 본다 — setup-labels.sh 설명·라벨 표의 라벨명 나열은 안 걸린다.)
for f in SKILL.md SKILL.en.md skills/verify-runner/SKILL.md \
         skills/closeout/SKILL.md skills/closeout/SKILL.en.md \
         references/worker-template.md references/worker-template.en.md; do
  if grep -nE -- '--add-label "?(flow:ready|flow:verify|harvesting)"?' "$f"; then
    echo "  ✗ $f: 산문 라벨 이동이 되살아남 — transition.sh 전이를 써라"
    exit 1
  fi
done

