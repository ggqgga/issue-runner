#!/usr/bin/env bash
# transition.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# #144: 세 루프가 산문으로 흩어 하던 라벨 이동을 전이 표 하나로 묶은 스크립트의 가드.
# bats 미도입 레포라 release-labels.test.sh 와 같은 순수 bash assert 관행을 따른다.
#
# 스텁은 **상태를 갖는다** — `issue edit` 의 add/remove 를 픽스처 파일에 반영하고
# `issue view --json labels` 가 그 파일을 돌려준다. 그래야 readback 검증이 실제 동작을
# 모사한다(스텁이 edit 를 무시하면 remove 단언이 공허하게 통과하는 걸 막는다).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SUT 는 sibling 경로로 setup-labels.sh 를 부른다("$(dirname "$0")/setup-labels.sh").
# PATH 스텁으로는 못 가로채므로 SUT 사본과 가짜 setup-labels.sh 를 tmp 에 나란히 둔다.
cp "$DIR/transition.sh" "$tmp/transition.sh"
SUT="$tmp/transition.sh"
cat > "$tmp/setup-labels.sh" <<'SETUP'
#!/usr/bin/env bash
echo "$*" >> "$STUB_SETUP_LOG"
if [ "${STUB_SETUP_FAIL:-0}" = "1" ]; then
  echo "gh: label create 'harvesting' 권한 없음" >&2
  exit 1
fi
SETUP
chmod +x "$tmp/setup-labels.sh"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 상태 파일: $STUB_STATE_DIR/<번호>.labels — 한 줄 한 라벨.
# STUB_MODE: ok | ignore(=edit 를 조용히 무시) | fail(=gh 호출 자체 실패)
#            | notfound-once(=첫 edit 만 'could not add label') | notfound-always
#            | notfound-404(='HTTP 404: Not Found' — 라벨 문맥이 아닌 404)
set -uo pipefail
mode=${STUB_MODE:-ok}
sub="${1:-} ${2:-}"
shift 2 || true

if [ "$sub" = "issue view" ]; then
  num=$1
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  [ "${STUB_VIEW_FAIL:-0}" = "1" ] && { echo "gh: connection refused" >&2; exit 1; }
  f="$STUB_STATE_DIR/$num.labels"
  printf '{"labels":['
  sep=""
  if [ -s "$f" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      printf '%s{"name":"%s"}' "$sep" "$l"; sep=","
    done < "$f"
  fi
  printf ']}\n'
  exit 0
fi

if [ "$sub" = "issue edit" ]; then
  num=$1; shift
  printf 'edit %s %s\n' "$num" "$*" >> "$STUB_EDIT_LOG"
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  if [ "$mode" = "notfound-404" ]; then
    echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/issues/$num)" >&2
    exit 1
  fi
  if [ "$mode" = "notfound-always" ]; then
    echo "could not add label: 'x' not found" >&2; exit 1
  fi
  if [ "$mode" = "notfound-once" ]; then
    if [ ! -f "$STUB_STATE_DIR/.tripped" ]; then
      : > "$STUB_STATE_DIR/.tripped"
      echo "could not add label: 'x' not found" >&2; exit 1
    fi
  fi
  [ "$mode" = "ignore" ] && exit 0
  f="$STUB_STATE_DIR/$num.labels"
  touch "$f"
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label)    shift; grep -qxF -- "$1" "$f" || printf '%s\n' "$1" >> "$f" ;;
      --remove-label) shift; grep -vxF -- "$1" "$f" > "$f.new" || true; mv "$f.new" "$f" ;;
    esac
    shift
  done
  exit 0
fi
echo "gh: unexpected call: $sub $*" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

pass=0
fail=0
check() {
  if [ "$2" = "ok" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; fi
}
ck() { check "$1" "$([ "$2" = "$3" ] && echo ok || echo no)"; }

# seed <num> <라벨...> — 픽스처 초기 라벨을 심는다.
seed() {
  local n=$1; shift
  : > "$tmp/state/$n.labels"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$tmp/state/$n.labels"; done
}

# run <mode> <전이> <issue> <pr> — 스텁으로 SUT 를 돌리고 exit code 를 RC 에 담는다.
run() {
  local mode=$1; shift
  STUB_MODE="$mode" STUB_STATE_DIR="$tmp/state" STUB_SETUP_FAIL="${STUB_SETUP_FAIL:-0}" \
  STUB_EDIT_LOG="$tmp/edit.log" STUB_SETUP_LOG="$tmp/setup.log" \
  PATH="$tmp/bin:$PATH" "$SUT" "$1" owner/repo "$2" "$3" >"$tmp/out" 2>"$tmp/err"
  RC=$?
}

reset() {
  rm -rf "$tmp/state"; mkdir -p "$tmp/state"
  : > "$tmp/edit.log"; : > "$tmp/setup.log"
}

# labels_of <num> — 현재 픽스처 라벨(정렬)
labels_of() { sort "$tmp/state/$1.labels" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
sorted() { printf '%s\n' $1 | sort | tr '\n' ' ' | sed 's/ *$//'; }

# ── ① 7개 전이의 add/remove 집합이 표와 일치(PR·이슈 양쪽) ───────────────────
# "모든 라벨을 다 붙여 둔" 픽스처에서 전이를 걸면, 남는 집합 = (전체 − remove) ∪ add.
# 기대값을 여기 손으로 적어 표를 두 번 쓰게 만든다(SUT 의 case 를 그대로 베끼면 공허해진다).
ALL="agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready harvesting needs-human"

# expect <전이> <PR 기대 잔존> <이슈 기대 잔존>
expect() {
  local name=$1 want_pr=$2 want_iss=$3
  reset
  # shellcheck disable=SC2086
  seed 7 $ALL
  # shellcheck disable=SC2086
  seed 9 $ALL
  run ok "$name" 9 7
  ck "$name: exit 0" "$RC" 0
  ck "$name: PR 라벨" "$(labels_of 7)" "$(sorted "$want_pr")"
  ck "$name: 이슈 라벨" "$(labels_of 9)" "$(sorted "$want_iss")"
  # 비공허 실증 — 양쪽 모두에 대해 edit 이 실제로 기록됐는지(no-op 통과 방지)
  check "$name: PR edit 기록" \
    "$(grep -q "^edit 7 " "$tmp/edit.log" && echo ok || echo no)"
  check "$name: 이슈 edit 기록" \
    "$(grep -q "^edit 9 " "$tmp/edit.log" && echo ok || echo no)"
  check "$name: --repo 전달" \
    "$(grep -q -- '--repo owner/repo' "$tmp/edit.log" && echo ok || echo no)"
}

#        전이                  PR 잔존                                                          이슈 잔존
expect handoff-verify \
  "agent-ready agent:claimed flow:verify flow:ready harvesting needs-human" \
  "agent-ready flow:ci flow:codex flow:verify flow:ready harvesting needs-human"
expect verify-pass \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human" \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human"
expect verify-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human" \
  "agent-ready flow:ci flow:codex flow:ready harvesting needs-human"
# ↓ verify-held·closeout-blocked 의 PR add 는 needs-human — ALL 픽스처엔 이미 있어
#   잔존 집합이 안 변한다. 그 칸의 비공허 실증은 ②-b(needs-human 없는 픽스처)가 맡는다.
expect verify-held \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human" \
  "agent-ready flow:ci flow:codex flow:ready harvesting needs-human"
expect closeout-pick \
  "agent-ready agent:claimed harvesting needs-human" \
  "agent-ready agent:claimed flow:ci flow:codex harvesting needs-human"
expect closeout-blocked \
  "agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready needs-human" \
  "agent-ready agent:claimed flow:ci flow:codex needs-human"
expect closeout-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex needs-human" \
  "agent-ready flow:ci flow:codex needs-human"

# ── ② `-` 인자 — 한쪽만 적용, 없는 쪽은 건드리지 않는다 ─────────────────────
reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-pass - 7
ck "PR 만: exit 0" "$RC" 0
ck "PR 만: PR 이동" "$(labels_of 7)" "flow:ready"
ck "PR 만: 이슈 무변" "$(labels_of 9)" "flow:verify"
check "PR 만: 이슈 edit 없음" \
  "$(grep -q '^edit 9 ' "$tmp/edit.log" && echo no || echo ok)"
check "PR 만: 성공 한 줄 출력" \
  "$(grep -q 'issue=- pr=7' "$tmp/out" && echo ok || echo no)"

reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-pass 9 -
ck "이슈 만: exit 0" "$RC" 0
ck "이슈 만: 이슈 이동" "$(labels_of 9)" "flow:ready"
ck "이슈 만: PR 무변" "$(labels_of 7)" "flow:verify"

# ②-b 연결 이슈 없는 PR(issue=-)에도 사람 신호가 남는가 — 이슈에만 붙이면 needs-human
# 이 아무 데도 안 붙고 exit 0 `ok` 로 끝나 사람 대기가 조용히 사라진다.
reset; seed 7 flow:verify
run ok verify-held - 7
ck "verify-held issue=-: exit 0" "$RC" 0
ck "verify-held issue=-: PR 에 needs-human" "$(labels_of 7)" "needs-human"

reset; seed 7 harvesting
run ok closeout-blocked - 7
ck "closeout-blocked issue=-: exit 0" "$RC" 0
ck "closeout-blocked issue=-: PR 에 needs-human" "$(labels_of 7)" "needs-human"

# 양쪽 다 있는 정상 호출에서도 PR·이슈 둘 다 needs-human 을 받는다
reset; seed 7 harvesting; seed 9 "harvesting" "flow:ready"
run ok closeout-blocked 9 7
ck "closeout-blocked 양쪽: PR needs-human" "$(labels_of 7)" "needs-human"
ck "closeout-blocked 양쪽: 이슈 needs-human" "$(labels_of 9)" "needs-human"

reset
run ok verify-pass - -
ck "둘 다 '-': usage exit 64" "$RC" 64
reset; run ok bogus-transition 9 7
ck "미지의 전이: usage exit 64" "$RC" 64
reset; STUB_MODE=ok "$SUT" >/dev/null 2>&1; ck "인자 없음: exit 64" "$?" 64

# ── ③ readback 불일치 → exit 1 (스텁이 edit 를 조용히 무시) ─────────────────
reset; seed 7 flow:verify; seed 9 flow:verify
run ignore verify-pass 9 7
ck "readback 불일치: exit 1" "$RC" 1
check "readback 불일치: stderr 에 어긋난 라벨" \
  "$(grep -q "flow:ready" "$tmp/err" && echo ok || echo no)"
check "readback 불일치: stderr 에 어느 쪽인지" \
  "$(grep -qE 'pr #7|issue #9' "$tmp/err" && echo ok || echo no)"

# ── ④ gh 호출 실패 → exit 2 ────────────────────────────────────────────────
reset; seed 7 flow:verify; seed 9 flow:verify
run fail verify-pass 9 7
ck "gh edit 실패: exit 2" "$RC" 2
check "gh edit 실패: stderr 한 줄" \
  "$(grep -q '라벨 편집 실패' "$tmp/err" && echo ok || echo no)"

# view 만 실패 — edit 은 성공했는데 재조회가 실패하면 불일치(1)가 아니라 조회 실패(2)
reset; seed 7 flow:verify; seed 9 flow:verify
STUB_MODE=ok STUB_VIEW_FAIL=1 STUB_STATE_DIR="$tmp/state" \
  STUB_EDIT_LOG="$tmp/edit.log" STUB_SETUP_LOG="$tmp/setup.log" \
  PATH="$tmp/bin:$PATH" "$SUT" verify-pass owner/repo 9 7 >/dev/null 2>"$tmp/err"
ck "gh view 실패: exit 2" "$?" 2
check "gh view 실패: 재조회 실패로 보고" \
  "$(grep -q '재조회 실패' "$tmp/err" && echo ok || echo no)"

# ── ⑤ 라벨 부재 보강 — 1회 실패 → setup-labels 1회 → 재시도 성공 ────────────
reset; seed 7 flow:verify; seed 9 flow:verify
run notfound-once verify-pass 9 7
ck "부재 보강: exit 0" "$RC" 0
ck "부재 보강: setup-labels 1회" "$(grep -c . "$tmp/setup.log")" 1
check "부재 보강: setup-labels 에 repo 전달" \
  "$(grep -qx 'owner/repo' "$tmp/setup.log" && echo ok || echo no)"
ck "부재 보강: 재시도로 라벨 이동" "$(labels_of 7)" "flow:ready"

# 2회 연속 실패 → exit 2, setup-labels 는 그래도 1회만(무한루프 금지)
reset; seed 7 flow:verify; seed 9 flow:verify
run notfound-always verify-pass 9 7
ck "부재 지속: exit 2" "$RC" 2
ck "부재 지속: setup-labels 1회만" "$(grep -c . "$tmp/setup.log")" 1
ck "부재 지속: edit 은 2회(원본+재시도 1회)" "$(grep -c '^edit ' "$tmp/edit.log")" 2

# 라벨 문맥이 아닌 404(오타 이슈 번호 등)는 setup-labels 를 **돌리지 않는다** —
# setup-labels 는 라벨 14개 --force + `gh repo edit` 이라는 쓰기다.
reset; seed 7 flow:verify; seed 9 flow:verify
run notfound-404 verify-pass 9 7
ck "일반 404: exit 2" "$RC" 2
ck "일반 404: setup-labels 미호출" "$(grep -c . "$tmp/setup.log")" 0
ck "일반 404: edit 은 1회(재시도 없음)" "$(grep -c '^edit ' "$tmp/edit.log")" 1

# 보강 자체가 실패하면(스크립트 부재·권한·부분 적용) 삼키지 않고 stderr 한 줄 남긴다.
reset; seed 7 flow:verify; seed 9 flow:verify
STUB_SETUP_FAIL=1 run notfound-once verify-pass 9 7
ck "보강 실패해도 재시도 성공하면 exit 0" "$RC" 0
check "보강 실패: stderr 에 경고 한 줄" \
  "$(grep -q '라벨 보강 실패(부분 적용 가능)' "$tmp/err" && echo ok || echo no)"
check "보강 실패: 마지막 출력 줄을 싣는다" \
  "$(grep -q '권한 없음' "$tmp/err" && echo ok || echo no)"
unset STUB_SETUP_FAIL

# ── ⑥ 멱등 — 같은 전이를 두 번 걸어도 exit 0, 라벨 동일 ─────────────────────
reset; seed 7 flow:verify flow:ci; seed 9 flow:verify agent:claimed
run ok verify-pass 9 7
ck "멱등 1회차: exit 0" "$RC" 0
first_pr=$(labels_of 7); first_iss=$(labels_of 9)
run ok verify-pass 9 7
ck "멱등 2회차: exit 0" "$RC" 0
ck "멱등 2회차: PR 라벨 동일" "$(labels_of 7)" "$first_pr"
ck "멱등 2회차: 이슈 라벨 동일" "$(labels_of 9)" "$first_iss"

echo "transition: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
