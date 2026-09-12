#!/usr/bin/env bash
# attempt-counter.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# #444: PR 본문의 `<!-- <key>: N -->` 읽기·증가가 **한 자리**인지, 그리고 그 증가가
# 본문의 나머지를 한 글자도 건드리지 않는지(AC "본문 무손상")를 고정한다.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
#
# 스텁 계약: `gh pr view … --json body` 와 `gh pr edit … --body-file <f>` 두 형태만 안다.
# 그 밖의 호출은 **exit 1** 이다 — SUT 가 몰래 다른 gh 경로로 새면(예 `--json comments`
# 로 본문을 줍거나 `--body` 로 편집) 그 케이스가 즉시 빨개진다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/attempt-counter.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "  ✗ $1"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# STUB_VIEW_RC / STUB_EDIT_RC 로 각 경로의 실패를 주입한다(기본 0).
case "$*" in
  *"pr view"*"--json body"*)
    [ "${STUB_VIEW_RC:-0}" = 0 ] || exit "$STUB_VIEW_RC"
    # `-Rs` = 파일 전체를 **끝 개행까지** 한 문자열로. 종전 `--arg b "$(cat …)"` 는
    # 명령치환이 끝 개행을 지워 본문 끝 공백 축을 통째로 못 재게 만들었다(#465 [P2-1]).
    jq -Rs '{body: .}' < "$STUB_BODY_FILE"
    ;;
  *"pr edit"*"--body-file"*)
    [ "${STUB_EDIT_RC:-0}" = 0 ] || exit "$STUB_EDIT_RC"
    # 마지막 인자가 --body-file 값이다(호출 계약) — 그 파일을 그대로 캡처한다.
    last=""
    for a in "$@"; do last="$a"; done
    cp "$last" "$STUB_CAPTURE"
    ;;
  *)
    echo "STUB: 예상 밖 gh 호출: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# run <body-file> <expect_rc> <expect_stdout> -- <args...>
#   stdout 은 정확 일치(공백·개행 제외). 편집 결과 본문은 $tmp/captured 에 남는다.
run() {
  local bodyf="$1" want_rc="$2" want_out="$3"; shift 3; [ "$1" = -- ] && shift
  rm -f "$tmp/captured"
  out=$(PATH="$tmp/bin:$PATH" STUB_BODY_FILE="$bodyf" STUB_CAPTURE="$tmp/captured" \
    STUB_VIEW_RC="${STUB_VIEW_RC:-0}" STUB_EDIT_RC="${STUB_EDIT_RC:-0}" \
    bash "$SUT" "$@" 2>"$tmp/last.err")
  rc=$?
  [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]
}

# ── 픽스처 본문 ─────────────────────────────────────────────────────────
# 실제 워커 PR 본문을 닮게 — 마커 앞뒤로 산문·목록·코드펜스가 있고, 다른 키의 마커도
# 섞여 있다(키 격리 축).
cat > "$tmp/body_n2" <<'BODY'
Closes #444

## 요약
- 카운터를 스크립트 한 자리로
- 본문은 그대로 유지된다

```sh
echo '<!-- 코드펜스 안의 가짜 마커: 0 -->'
```

<!-- repair-count: 2 -->
<!-- verify-attempt: 1 -->
BODY

cat > "$tmp/body_none" <<'BODY'
Closes #444

본문에 마커가 아직 없다.
BODY

: > "$tmp/body_empty"

# ── 1) 마커 없음 → 0 ────────────────────────────────────────────────────
if run "$tmp/body_none" 0 "0" -- owner/repo 7 repair-count; then ok; else
  bad "마커 없음 → 0 (rc=$rc out=[$out])"; fi
# 읽기 모드는 편집 경로를 타면 안 된다 — 탔다면 캡처 파일이 생긴다.
if [ ! -e "$tmp/captured" ]; then ok; else bad "읽기 모드가 gh pr edit 을 호출했다"; fi

# ── 2) 마커 있음 → N ────────────────────────────────────────────────────
if run "$tmp/body_n2" 0 "2" -- owner/repo 7 repair-count; then ok; else
  bad "마커 N=2 → 2 (rc=$rc out=[$out])"; fi

# ── 3) 키 격리 — 같은 본문의 다른 키는 자기 값을 낸다 ────────────────────
if run "$tmp/body_n2" 0 "1" -- owner/repo 7 verify-attempt; then ok; else
  bad "키 격리: verify-attempt → 1 (rc=$rc out=[$out])"; fi

# ── 4) --bump — 새 값 출력 + 본문 무손상 ────────────────────────────────
if run "$tmp/body_n2" 0 "3" -- owner/repo 7 repair-count --bump; then ok; else
  bad "--bump 2→3 출력 (rc=$rc out=[$out])"; fi
if [ -s "$tmp/captured" ]; then ok; else bad "--bump 이 본문을 게시하지 않았다"; fi
# 본문 무손상: 갱신 본문에서 그 마커 한 줄만 바꿔치기하면 원본과 **바이트 동일**해야 한다.
sed 's/<!-- repair-count: 3 -->/<!-- repair-count: 2 -->/' "$tmp/captured" > "$tmp/rolled"
if cmp -s "$tmp/rolled" "$tmp/body_n2"; then ok; else
  bad "--bump 이 마커 밖 본문을 건드렸다:"; diff "$tmp/body_n2" "$tmp/rolled" | sed 's/^/      /'; fi
# 다른 키의 마커·코드펜스 안 가짜 마커는 그대로여야 한다.
if grep -qF '<!-- verify-attempt: 1 -->' "$tmp/captured" \
   && grep -qF "코드펜스 안의 가짜 마커: 0" "$tmp/captured"; then ok; else
  bad "--bump 이 다른 키/코드펜스의 마커를 건드렸다"; fi

# ── 5) --bump — 마커 부재 → 1, 끝에 추가 ────────────────────────────────
if run "$tmp/body_none" 0 "1" -- owner/repo 7 repair-count --bump; then ok; else
  bad "--bump 마커 부재 → 1 (rc=$rc out=[$out])"; fi
if [ "$(tail -1 "$tmp/captured")" = "<!-- repair-count: 1 -->" ]; then ok; else
  bad "--bump 마커 부재: 본문 끝에 안 붙었다 (마지막 줄=[$(tail -1 "$tmp/captured")])"; fi
# 원본 본문 전체가 앞에 그대로 남아 있어야 한다.
if head -n "$(wc -l < "$tmp/body_none")" "$tmp/captured" | cmp -s - "$tmp/body_none"; then ok; else
  bad "--bump 마커 부재: 기존 본문이 보존되지 않았다"; fi

# ── 6) --bump — 빈 본문 → 마커만 ────────────────────────────────────────
if run "$tmp/body_empty" 0 "1" -- owner/repo 7 repair-count --bump; then ok; else
  bad "--bump 빈 본문 → 1 (rc=$rc out=[$out])"; fi
if [ "$(cat "$tmp/captured")" = "<!-- repair-count: 1 -->" ]; then ok; else
  bad "--bump 빈 본문: 마커만 남아야 한다 (실제=[$(cat "$tmp/captured")])"; fi

# ── 7) 두 번 bump 는 두 칸 오른다(멱등 아님 — 회차 카운터다) ────────────
if run "$tmp/body_n2" 0 "3" -- owner/repo 7 repair-count --bump; then
  cp "$tmp/captured" "$tmp/body_n3"
  if run "$tmp/body_n3" 0 "4" -- owner/repo 7 repair-count --bump; then ok; else
    bad "연속 bump 3→4 (rc=$rc out=[$out])"; fi
else bad "연속 bump 준비 실패"; fi

# ── 8) 느슨한 마커 문법을 읽고 정규형으로 수렴한다 ──────────────────────
printf '앞머리\n<!--repair-count:  5   -->\n꼬리\n' > "$tmp/body_loose"
if run "$tmp/body_loose" 0 "5" -- owner/repo 7 repair-count; then ok; else
  bad "느슨한 마커 읽기 → 5 (rc=$rc out=[$out])"; fi
if run "$tmp/body_loose" 0 "6" -- owner/repo 7 repair-count --bump \
   && grep -qF '<!-- repair-count: 6 -->' "$tmp/captured"; then ok; else
  bad "느슨한 마커 bump 가 정규형으로 안 바뀐다: [$(cat "$tmp/captured" 2>/dev/null)]"; fi

# ── 9) 조회 실패 → exit 2 · 무출력 ──────────────────────────────────────
STUB_VIEW_RC=1
if run "$tmp/body_n2" 2 "" -- owner/repo 7 repair-count; then ok; else
  bad "조회 실패 → exit 2 무출력 (rc=$rc out=[$out])"; fi
if run "$tmp/body_n2" 2 "" -- owner/repo 7 repair-count --bump; then ok; else
  bad "조회 실패(bump) → exit 2 무출력 (rc=$rc out=[$out])"; fi
STUB_VIEW_RC=0

# ── 10) 편집 실패 → exit 2 · 무출력 (fail-closed — 값이 올라간 척하지 않는다) ──
STUB_EDIT_RC=1
if run "$tmp/body_n2" 2 "" -- owner/repo 7 repair-count --bump; then ok; else
  bad "편집 실패 → exit 2 무출력 (rc=$rc out=[$out])"; fi
if grep -qF 'gh pr edit 실패' "$tmp/last.err"; then ok; else
  bad "편집 실패에 stderr 한 줄이 없다: [$(cat "$tmp/last.err")]"; fi
STUB_EDIT_RC=0

# ── 11) 호출 형태 오류 → exit 64 (쓰기 전에 멈춘다) ─────────────────────
for bad_args in "owner/repo" "owner/repo 7" "owner/repo x repair-count" \
                "owner/repo 7 bad:key" "owner/repo 7 key extra"; do
  # shellcheck disable=SC2086
  if run "$tmp/body_n2" 64 "" -- $bad_args; then ok; else
    bad "usage 오류 '$bad_args' → exit 64 무출력 (rc=$rc out=[$out])"; fi
done

# ── 11-b) 끝 개행 보존 — bump 를 반복해도 마커 밖 바이트가 안 변한다 (#465 [P2-1]) ──
# `jq -r` 로 본문을 뽑으면 종결자가 하나 더 붙어, 개행으로 끝나는 본문은 bump 마다 끝에
# 빈 줄이 하나씩 쌓인다. 카운터는 같은 PR 에서 여러 번 도는 물건이라 그 누적이 실제로 보인다.
printf '앞머리\n\n가운데\n\n' > "$tmp/body_nl2"   # `\n\n` 으로 끝난다
if run "$tmp/body_nl2" 0 "1" -- owner/repo 7 repair-count --bump; then ok; else
  bad "끝 개행 픽스처 첫 bump (rc=$rc out=[$out])"; fi
cp "$tmp/captured" "$tmp/nl_b1"
# 원본이 접두로 **바이트 그대로** 남아 있어야 한다(끝 개행 개수 포함).
if head -c "$(wc -c < "$tmp/body_nl2")" "$tmp/nl_b1" | cmp -s - "$tmp/body_nl2"; then ok; else
  bad "첫 bump 가 본문 끝 바이트를 바꿨다: $(od -c "$tmp/nl_b1" | tail -3)"; fi
# 두 번째·세 번째 bump — 마커 한 조각 말고는 바이트가 움직이면 안 된다.
if run "$tmp/nl_b1" 0 "2" -- owner/repo 7 repair-count --bump; then ok; else
  bad "끝 개행 픽스처 둘째 bump (rc=$rc out=[$out])"; fi
cp "$tmp/captured" "$tmp/nl_b2"
if run "$tmp/nl_b2" 0 "3" -- owner/repo 7 repair-count --bump; then ok; else
  bad "끝 개행 픽스처 셋째 bump (rc=$rc out=[$out])"; fi
cp "$tmp/captured" "$tmp/nl_b3"
sed 's/<!-- repair-count: 2 -->/<!-- repair-count: 1 -->/' "$tmp/nl_b2" > "$tmp/nl_r2"
sed 's/<!-- repair-count: 3 -->/<!-- repair-count: 1 -->/' "$tmp/nl_b3" > "$tmp/nl_r3"
if cmp -s "$tmp/nl_r2" "$tmp/nl_b1" && cmp -s "$tmp/nl_r3" "$tmp/nl_b1"; then ok; else
  bad "반복 bump 가 마커 밖 바이트를 바꿨다(빈 줄 누적):"
  diff <(od -c "$tmp/nl_b1") <(od -c "$tmp/nl_r3") | sed 's/^/      /'; fi
# 끝 개행이 **없는** 본문도 그대로 — 없던 개행을 만들지 않는다.
printf '개행 없이 끝' > "$tmp/body_nonl"
if run "$tmp/body_nonl" 0 "1" -- owner/repo 7 repair-count --bump \
   && head -c "$(wc -c < "$tmp/body_nonl")" "$tmp/captured" | cmp -s - "$tmp/body_nonl"; then ok; else
  bad "끝 개행 없는 본문의 접두 바이트가 바뀌었다"; fi

# ── 12) 실행 비트 — 두 SKILL 이 `$SCRIPTS/attempt-counter.sh` 로 직접 exec 한다 ──
# 비트가 빠지면 조용히 exit 126 → 회차가 항상 빈 값으로 degrade 한다
# (pr-head-at·bounce-state·bounce-comment 가 이미 밟은 함정).
if [ -x "$SUT" ]; then ok; else bad "attempt-counter.sh 실행 비트 없음"; fi

echo "attempt-counter.test.sh: pass=$pass fail=$fail"
[ "$fail" = 0 ]
