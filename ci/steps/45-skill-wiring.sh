#!/usr/bin/env bash
# 단계 5 — issue-runner·verify-runner SKILL 이 회차 카운터와 규칙0 을 **스크립트에
# 위임하는 형태**인지. 산문이 판정을 되찾아오면 두 레인이 서로 다른 규칙으로 돈다.
#
# 실패 시: `  ✗ <파일>: <배선> 없음 (#NNN)` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 63–90행):
#   • [#444] 회차 카운터는 scripts/attempt-counter.sh 한 자리 (분류표 행 12 · 부행 12-b)
#   • [#449] 규칙0 은 pr-state.sh 한 자리 + 표(SSOT)→진입점 포인터 (행 13 · 부행 13-b·13-d)
#
# 만료 조건 — #444: 회차 규칙이 references/loop-conventions.md 의 새 절로 옮겨지면 ⓑ 로
# 내려가 지운다(현재 references/ 안 언급 0건). #449: 규칙0 이 스크립트 인자로 바뀔 때.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[#444] 회차 카운터는 scripts/attempt-counter.sh 한 자리 — 산문 읽기/쓰기 0"
# `<!-- repair-count: N -->`(issue-runner ②)·`<!-- verify-attempt: N -->`(verify-runner ③④)의
# 읽기-증가-쓰기가 SKILL 산문으로 되살아나면 두 레인의 회차 규칙이 갈리고(한쪽만 고쳐진다)
# 그 차이는 출력에 안 보인다 — 상한 비교만 SKILL 노브로 남는다.
# 만료 조건: 두 SKILL 이 회차를 스크립트로만 읽는 형태를 유지하는 한 이 가드가 그 형태의 강제자다.
for f in SKILL.md SKILL.en.md skills/verify-runner/SKILL.md; do
  grep -qF 'attempt-counter.sh' "$f" \
    || { echo "  ✗ $f: attempt-counter.sh 배선 없음 (#444)"; exit 1; }
  # 산문 회귀 — 본문 주석을 손으로 읽거나(`--json body`) 손으로 쓰는(`gh pr edit … --body`) 형태.
done

echo "[#449] 규칙0 은 pr-state.sh 한 자리 — 판정→목표 라벨 매핑 산문 0"
# `references/state-machine.md` 가 표 SSOT 이고 `pr-state.sh` 가 그 표를 기계가 읽는 진입점이다.
# 산문이 "마지막 판정 → flow:<칸>" 매핑을 다시 들면 표와 두 벌이 되고, 그 차이는 라벨이
# 어긋난 뒤에야 보인다(#281 미러가 갈리는 자리).
# 만료 조건: 한/영 ② Maintain 규칙0 이 매핑을 스크립트에 위임하는 형태를 유지하는 한
# 이 가드가 그 형태의 강제자다.
for f in SKILL.md SKILL.en.md; do
  grep -qF 'pr-state.sh' "$f" \
    || { echo "  ✗ $f: 규칙0 에 pr-state.sh 배선 없음 (#449)"; exit 1; }
  grep -qF 'mismatch' "$f" \
    || { echo "  ✗ $f: 규칙0 이 pr-state.sh 의 mismatch 를 처분하지 않는다 (#449)"; exit 1; }
  # 산문 회귀 — 판정 기호에서 목표 flow 라벨을 직접 유도하는 매핑 화살표.
done
# 표(SSOT)가 이 진입점을 가리키는지 — 표만 고치고 스크립트를 안 고치는 드리프트 방지.
grep -qF 'pr-state.sh' references/state-machine.md \
  || { echo "  ✗ references/state-machine.md 가 기계 진입점(pr-state.sh)을 가리키지 않는다 (#449)"; exit 1; }

