#!/usr/bin/env bash
# 단계 7 — scripts/tests/*.test.sh 격자 러너 묶음(가장 긴 단계). 각 줄은 `[test] …`
# 한 줄 + `bash scripts/tests/<sut>.test.sh` 하나이고, 판정은 전부 그 격자 안에 있다.
#
# 실패 시: 격자 자신의 진단(케이스 이름·기대/실제)을 찍고 비0 → 그 자리에서 정지.
#
# 담은 블록 (원 bin/ci 243–379행 · 분류표 행 39–59·62–70 「ⓓ 테스트 러너」):
#   loop-jq(#426) · attempt-counter(#444) · pr-state(#449) · finish-classify(#88) ·
#   closeout-eligible(#171) · verify-eligible(#275) · hold-gate(#242) · lane-gate(#246) ·
#   eligible-issues(#247·#401·#257) · bounce-state(#196·#218) · closeout-step1-marker(#271) ·
#   bounce-comment(#212) · hold-resolve(#334) · closeout-sweep-gate(#218) ·
#   release-labels(#117) · ci-queue(#127) · codex-review-gate(#134) · reconcile(#131) ·
#   transition(#144·#147·#281) · claim-issue(#281) · resume-sweep(#147) · loop-status(#144) ·
#   epic-sweep(#258) · progress-evidence·claim-at·pr-head-at·closeout-ci-pass·
#   closeout-reconcile(#428) · smoke-tally(#448) · deploy-wait-issue(#446) ·
#   make-worktree(#445) · ci-gate(#47·#60) · cleanup-worktree(#62) · repo-flag(#109) ·
#   setup-labels(#346)
#
# 동승한 가드 블록 둘 — 원 bin/ci 의 실행 순서가 러너 사이에 끼워 둔 자리라 순서를
# 지키려고 여기 그대로 뒀다(stdout 불변이 우선). 둘 다 분류 ⓓ 기계 계약이다:
#   • [#334] closeout ①-c 배선 (원 284–300행 · 표 신규 행) — hold-resolve.test.sh 바로 뒤
#   • [#276] 루프 현황 9줄 RENDER_JQ padded 리터럴 (원 330–338행 · 부행 60-b) — loop-status.test.sh 바로 뒤
#
# 만료 조건 — 러너 줄: 없음(격자가 곧 자기 대체물이다. 격자 파일을 지울 때 같이 지운다).
# #334: ①-c 호출이 SKILL 산문이 아니라 스크립트 인자로 옮겨질 때. #276: loop-status.test.sh
# 가 렌더 9줄(이름·폭)을 스위트 안에서 단언하면 즉시.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[test] loop.jq 판정 술어 격자 — 한/영·마커 위치·빈 배열·null 본문 + 뮤테이션 1건 (#426)"
# 열한 소비처가 같은 술어를 부르므로 술어가 조용히 넓어지면 전부 같은 방향으로 틀어진다.
# 만료 조건: 없음(라이브러리 자체의 행동 테스트 — 이 파일이 그 SSOT 의 가드다).
bash scripts/tests/loop-jq.test.sh

echo "[test] attempt-counter.sh 회차 카운터 — 읽기·bump·본문 무손상·fail-closed (#444)"
bash scripts/tests/attempt-counter.test.sh

echo "[test] pr-state.sh 상태 판정 격자 — 사다리 6칸·정지 4종·반송·종료·mismatch 4축 (#449)"
bash scripts/tests/pr-state.test.sh

echo "[test] finish-classify.sh 분류 픽스처 테스트 (#88)"
bash scripts/tests/finish-classify.test.sh

echo "[test] closeout-eligible.sh 후보 필터 — ✅ 를 head SHA 와 대조 (#171)"
bash scripts/tests/closeout-eligible.test.sh

echo "[test] verify-eligible.sh 큐 순서 — verifying(고아, orphan:true) 먼저 · flow:verify FIFO · harvesting 제외 (#275)"
bash scripts/tests/verify-eligible.test.sh

echo "[test] 네 게이트의 needs-human·hold:* 배제 — 격자 한 벌을 네 SUT 에 전수 적용 (#242)"
bash scripts/tests/hold-gate.test.sh

echo "[test] verify·closeout 레인 판별 — head 이름 + full-cycle 라벨 두 축을 두 SUT 에 전수 적용 (#246)"
bash scripts/tests/lane-gate.test.sh

echo "[test] eligible-issues.sh 막힘 stderr 보고·블로커 상태 표기·검색 창 warn·stdout 불변 (#247)"
echo "       + 정렬 P0 먼저·같은 P 는 FIFO(#401)·Epic #N 파싱·loop-status 정규식 동기 (#257 → #401)"
bash scripts/tests/eligible-issues.test.sh

echo "[test] bounce-state.sh 반송 판정 — ①-b 입양 안전망·해제 경로 격자 (#196 · #218)"
bash scripts/tests/bounce-state.test.sh

echo "[test] closeout-step1-marker.sh 1단계 마커 판정 — ⚠보류·head 신선도·반송 선후 3축 격자 (#271)"
bash scripts/tests/closeout-step1-marker.test.sh

echo "[test] bounce-comment.sh 반송 코멘트 생성 — SKILL.md 문구와 바이트 동일 (#212)"
bash scripts/tests/bounce-comment.test.sh

echo "[test] hold-resolve.sh 보류 해제 방향 판정 격자 — 인덱스·라벨 술어·조회 실패 (#334)"
bash scripts/tests/hold-resolve.test.sh
echo "[#334] closeout ①-c 배선 — ② Pick 직전 hold-resolve.sh 호출 + ①-b done_verdict 행의 ①-c 배선 (한/영)"
# 판정은 스크립트(위 테스트)가 무는데, SKILL 이 그 스크립트를 부르지 않으면 판정이 없는 것과 같다. 두 자리만 본다:
# ①-c 절 안에 호출 줄이 있는가 · ①-b `done_verdict` 행이 ①-c 를 가리키는가(eligible 이 못 내는 형상을 스윕이 줍는 배선).
for f in skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  s=$(grep -nE '^## ①-c' "$f" | head -1 | cut -d: -f1 || true); e=$(grep -nE '^## ② Pick' "$f" | head -1 | cut -d: -f1 || true)
  [ -n "$s" ] && [ -n "$e" ] && [ "$s" -lt "$e" ] || { echo "  ✗ $f: ①-c 절이 ② Pick 앞에 없다"; exit 1; }
  sed -n "${s},${e}p" "$f" | grep -qF 'hold-resolve.sh <repo> <pr> <issue|->' \
    || { echo "  ✗ $f: ①-c 절에 hold-resolve.sh 호출 줄 없음"; exit 1; }
  grep -E '^\| `done_verdict` ' "$f" | grep -qF '①-c' \
    || { echo "  ✗ $f: ①-b done_verdict 행이 ①-c 를 가리키지 않는다"; exit 1; }
done
# 산문이 찍고 스크립트가 읽는 문자열 — `마감 검증: ✅ 기각 승계`(기각 → ③ 2단계부터). 한/영 SKILL 과
# hold-resolve.sh 셋이 바이트 동일해야 `resume: step2` 가 붙는다(드리프트하면 ③-1 재실행 → 같은 P1 → 보류↔해제 루프).
for f in scripts/hold-resolve.sh skills/closeout/SKILL.md skills/closeout/SKILL.en.md; do
  grep -qF '마감 검증: ✅ 기각 승계' "$f" || { echo "  ✗ $f: '마감 검증: ✅ 기각 승계' 리터럴 없음 — 세 파일이 같은 문자열을 들어야 한다 (#334)"; exit 1; }
done

echo "[test] closeout ①-b 스윕 판정 픽스처 8종 — 반송 게이트가 갈래 앞·held 해제 경로 (#218)"
bash scripts/tests/closeout-sweep-gate.test.sh

echo "[test] release-labels.sh 라벨 해제 규칙 테스트 (#117)"
bash scripts/tests/release-labels.test.sh

echo "[test] ci-queue.sh 박스 전역 FIFO · local-ci 훅 ROOT · 게이트 큐 분기 테스트 (#127)"
bash scripts/tests/ci-queue.test.sh

echo "[test] codex-review-gate.sh 내장 리뷰어 판정 매핑·fail-closed 테스트 (#134)"
bash scripts/tests/codex-review-gate.test.sh

echo "[test] reconcile.sh 재claim 필터 fail-closed·스윕 차단·gh-login 순차 폴백 (#131)"
bash scripts/tests/reconcile.test.sh

echo "[test] transition.sh 전이 집합·readback 검증·라벨 보강 (#144 · #147 --reason·closeout-dup · #281 PR 미러)"
bash scripts/tests/transition.test.sh

echo "[test] claim-issue.sh PR 미러 — 열린 agent/issue-N PR 에 flow:claimed 부착·flow:agent-ready 제거, best-effort (#281)"
bash scripts/tests/claim-issue.test.sh

echo "[test] resume-sweep.sh 재개 스윕 — 창·상한·경합 가드·마커 코멘트·PR 미러 (#147)"
bash scripts/tests/resume-sweep.test.sh

echo "[test] loop-status.sh 파이프라인 스냅샷 버킷·창 필터·warn·부분 실패 (#144)"
bash scripts/tests/loop-status.test.sh
# (#276) 사다리 버킷은 "누가 들고 있나" 로 이름 짓는다 — 이름·라벨·jq 키의 SSOT 는
# `scripts/loop-status.sh` 머리 주석 「★버킷 정의 — 이 주석이 SSOT★」 다. 여기서 무는 것은
# 렌더 계약(그 이름 9개가 RENDER_JQ padded 리터럴에 있고 폭이 같은가) 하나다.
echo "[#276] 루프 현황 9줄 — RENDER_JQ padded 이름·폭 리터럴"
# 9줄 렌더 계약 — RENDER_JQ 의 padded 리터럴에 새 이름 9개가 전부 있고 폭이 같다(15칸 = verify-runner 13 + 2).
for lit in '"waiting":"대기           "' '"claimed":"issue-runner   "' '"verify":"검증대기       "' \
           '"verifying":"verify-runner  "' '"ready":"마감대기       "' '"harvesting":"closeout       "' \
           '"held":"보류           "' '"human_wait":"needs-human    "' '"deploy_wait":"배포대기       "'; do
  grep -qF -- "$lit" scripts/loop-status.sh \
    || { echo "  ✗ scripts/loop-status.sh RENDER_JQ padded 에 $lit 이 없다 (#276 — 9줄 이름·15칸 폭)"; exit 1; }
done

echo "[test] epic-sweep.sh — leaf 전부 종료 에픽 자동 종료·전용 줄 판정·상한 보류·멱등 (#258)"
# closeout ① 이 `"$SCRIPTS/epic-sweep.sh"` 로 직접 exec 하므로 실행 비트도 여기서 문다
# (비트가 빠지면 조용히 exit 126 → 에픽 스윕이 매 틱 no-op 으로 degrade, PR#173 교훈과 동일 함정).
bash scripts/tests/epic-sweep.test.sh

echo "[test] progress-evidence.sh 진행 증거 3축 격자 — 커밋/큐/claim·3값 어휘·경계 (#428)"
bash scripts/tests/progress-evidence.test.sh

echo "[test] claim-at.sh 부착 시각 격자 — 마지막 매칭 인덱스·100건 상한·부재/실패 분리 (#428)"
bash scripts/tests/claim-at.test.sh

echo "[test] pr-head-at.sh head 시각 격자 — 상한 없는 조회 경로·SHA 형태 검사·fail-closed (#428)"
bash scripts/tests/pr-head-at.test.sh

echo "[test] closeout-ci-pass.sh CI 통과 판정 격자 — 로컬 캐시 0/1/2·폴백 SUCCESS-only allowlist (#428)"
bash scripts/tests/closeout-ci-pass.test.sh

echo "[test] closeout-reconcile.sh harvesting 점검 격자 — 상태별 이벤트·needs-human fail-closed·범위 필터 (#428)"
bash scripts/tests/closeout-reconcile.test.sh

echo "[test] smoke-tally.sh 스모크 집계 격자 — 표식 분모 제외·보류 합산·문법 위반 fail-closed (#448)"
bash scripts/tests/smoke-tally.test.sh

echo "[test] deploy-wait-issue.sh 배포 대기 발행 격자 — 제목·절 파싱 계약·(승격만)·라벨 3단 사다리 (#446)"
bash scripts/tests/deploy-wait-issue.test.sh

echo "[test] make-worktree.sh --sync 격자 — 원격 head 강제 동기화·더티 거부·untracked 무해·원격 부재 (#445)"
bash scripts/tests/make-worktree.test.sh

echo "[test] ci-gate 훅 — 대상 파싱 fail-closed·--repo 캐시 판정·rollup SUCCESS-only allowlist (#47 · #60)"
bash scripts/tests/ci-gate.test.sh

echo "[test] cleanup-worktree.sh worktree 처분 — clean+--merged 제거·더티/미push 보류(warn JSON)·멱등 (#62)"
bash scripts/tests/cleanup-worktree.test.sh

echo "[test] repo-flag.sh · repo-dir.sh repos.conf 파싱 — 3필드 이후 플래그·주석·conf 부재 off·'-' 경로 폴백 (#109)"
bash scripts/tests/repo-flag.test.sh

echo "[test] setup-labels.sh 라벨 세트 생성 — 설명 100자 상한·세트 전량 생성·전수 설명 (#346)"
bash scripts/tests/setup-labels.test.sh

