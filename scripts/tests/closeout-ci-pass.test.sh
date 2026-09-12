#!/usr/bin/env bash
# closeout-ci-pass.sh 격자 테스트 (#428) — 네트워크 무접속(gh 를 PATH 스텁으로, 로컬 CI
# 캐시는 HOME 을 픽스처로 갈아끼워 대체). 레포 해석도 픽스처 안에 가둔다
# (ISSUE_RUNNER_REPOS_CONF·ISSUE_RUNNER_PROJECTS_ROOT — 머신의 repos.conf 를 타면 안 된다).
# 무는 계약: 무출력 필터로 **0=pass · 1=비통과/조회 실패(fail-closed) · 2=로컬 CI HEAD
# 미실행(재검증 필요)** 세 값을 낸다. 분기는 "실행 가능한 bin/ci 보유" 하나이고,
# GitHub 폴백은 SUCCESS-only allowlist(미열거 종결값도 비통과)다.
# 이 헬퍼를 직접 exec 하는 소비자: scripts/closeout-eligible.sh · scripts/verify-eligible.sh.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/closeout-ci-pass.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj/fixture-428" "$TMP/home"
: > "$TMP/repos.conf"

REPO=fixture-owner/fixture-428
PR=5
SHA=feed0070abcdef1234567890abcdef1234567890
PROJ="$TMP/proj/fixture-428"
CACHE="$TMP/home/.claude/.local-ci"

# gh 스텁 — 두 조회만 응답하고 나머지는 exit 1(의도치 않은 네트워크 경로를 시끄럽게 만든다).
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--json headRefOid"*)
    case "${STUB_SHA:-FAIL}" in
      FAIL) echo "gh: could not connect" >&2; exit 1 ;;
      NULL) printf '{"headRefOid":null}\n' ;;
      *)    printf '{"headRefOid":"%s"}\n' "$STUB_SHA" ;;
    esac ;;
  *"--json statusCheckRollup"*)
    case "${STUB_ROLLUP:-FAIL}" in
      FAIL) echo "gh: could not connect" >&2; exit 1 ;;
      *)    printf '%s\n' "$STUB_ROLLUP" ;;
    esac ;;
  *) echo "예상 못한 gh 호출: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

pass=0
fail=0
STUB_SHA="$SHA"
STUB_ROLLUP=FAIL

run_case() {  # run_case <이름> <기대 exit> — 필터라 stdout 은 항상 비어야 한다
  local name="$1" erc="$2" out rc
  out=$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
    ISSUE_RUNNER_REPOS_CONF="$TMP/repos.conf" ISSUE_RUNNER_PROJECTS_ROOT="$TMP/proj" \
    STUB_SHA="$STUB_SHA" STUB_ROLLUP="$STUB_ROLLUP" \
    bash "$SUT" "$REPO" "$PR" 2>/dev/null); rc=$?
  if [ "$rc" = "$erc" ] && [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=exit $erc(무출력) 실제=exit $rc 출력=[$out]"
  fi
}

put_result() {  # put_result <pass|fail> — 로컬 CI 결과 캐시(키는 SHA, 슬러그 무관)
  mkdir -p "$CACHE/fixture_slug"
  printf '%s\n' "$1" > "$CACHE/fixture_slug/$SHA.result"
}
clear_result() { rm -rf "$CACHE"; }

# ── 로컬 CI 옵트인 레포(실행 가능한 bin/ci 보유) ────────────────────────
mkdir -p "$PROJ/bin"
printf '#!/bin/sh\nexit 0\n' > "$PROJ/bin/ci"
chmod +x "$PROJ/bin/ci"

put_result pass
run_case "head SHA 캐시가 pass → 통과" 0

put_result fail
run_case "head SHA 캐시가 fail → 비통과" 1

clear_result
# HEAD 가 rebase 등으로 바뀌어 새 SHA 캐시가 빈 경우 — fail(1)이 아니라 **재검증 필요(2)**.
run_case "결과 캐시 부재 → 미실행(재검증 필요)" 2

put_result pass
STUB_SHA=FAIL
run_case "head SHA 조회 실패 → fail-closed(미실행 2 가 아니다)" 1
STUB_SHA=NULL
run_case "headRefOid 가 null → fail-closed" 1
STUB_SHA="$SHA"

# 경계 — bin/ci 가 **있어도 실행 비트가 없으면** 로컬 분기가 아니다(GitHub 폴백으로 간다).
chmod -x "$PROJ/bin/ci"
STUB_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
run_case "bin/ci 실행 비트 없음 → GitHub 폴백으로 판정" 0
rm -rf "${PROJ:?}/bin"
clear_result

# ── GitHub statusCheckRollup 폴백(SUCCESS-only allowlist) ───────────────
STUB_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
run_case "등록 체크 전부 SUCCESS → 통과" 0

STUB_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]}'
run_case "하나라도 FAILURE → 비통과" 1

# denylist 가 아니라 good-then-negate — 미열거/미래 종결값도 자동으로 비통과다.
STUB_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"CANCELLED"}]}'
run_case "SUCCESS 아닌 종결값(CANCELLED) → 비통과" 1

# closeout 진입 필터라 진행 중 PR 은 아직 거두지 않는다.
STUB_ROLLUP='{"statusCheckRollup":[{"status":"IN_PROGRESS"},{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
run_case "진행 중 체크가 있으면 → 비통과" 1

STUB_ROLLUP='{"statusCheckRollup":[]}'
run_case "등록된 체크 0개 → fail-closed" 1

STUB_ROLLUP=FAIL
run_case "rollup 조회 실패 → fail-closed" 1

# 레거시 commit-status 형상 — status 필드 없이 state 만 있다.
STUB_ROLLUP='{"statusCheckRollup":[{"state":"SUCCESS"}]}'
run_case "레거시 commit-status state=SUCCESS → 통과" 0

echo "closeout-ci-pass.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
