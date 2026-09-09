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

# closeout-dup ④ 도 sibling 호출이다 — 같은 이유로 tmp 에 가짜를 나란히 둔다.
cat > "$tmp/release-labels.sh" <<'REL'
#!/usr/bin/env bash
printf 'release-labels %s\n' "$2" >> "$STUB_MUT_LOG"
REL
chmod +x "$tmp/release-labels.sh"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 상태 파일: $STUB_STATE_DIR/<번호>.labels — 한 줄 한 라벨.
#            $STUB_STATE_DIR/<번호>.state  — OPEN|CLOSED|MERGED (없으면 OPEN)
# STUB_MODE: ok | ignore(=edit 를 조용히 무시) | fail(=gh 호출 자체 실패)
#            | notfound-once(=첫 edit 만 'could not add label') | notfound-always
#            | notfound-404('HTTP 404: Not Found' — 라벨 문맥이 아닌 404)
# 별도 스위치: STUB_VIEW_FAIL=1(view 만 실패) · STUB_PRCLOSE_FAIL=1(pr close 만 실패)
#            · STUB_NOCLOSE=1(close 가 상태를 안 바꾼다 — readback 상태 불일치 재현)
# $STUB_MUT_LOG 에는 **쓰기 호출만** 순서대로 남긴다(view 는 안 남긴다 — 읽기가 섞이면
# 순서 단언이 취약해진다): edit N / pr-close N / issue-comment N / issue-close N,
# 그리고 가짜 release-labels.sh 가 남기는 release-labels N.
set -uo pipefail
mode=${STUB_MODE:-ok}
sub="${1:-} ${2:-}"
shift 2 || true

if [ "$sub" = "issue view" ] || [ "$sub" = "pr view" ]; then
  num=$1; shift
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  [ "${STUB_VIEW_FAIL:-0}" = "1" ] && { echo "gh: connection refused" >&2; exit 1; }
  fields=labels
  while [ $# -gt 0 ]; do
    case "$1" in --json) shift; fields=${1:-} ;; esac
    shift
  done
  f="$STUB_STATE_DIR/$num.labels"
  st=OPEN
  [ -f "$STUB_STATE_DIR/$num.state" ] && st=$(cat "$STUB_STATE_DIR/$num.state")
  printf '{'
  sep=""
  case ",$fields," in *,state,*) printf '"state":"%s"' "$st"; sep="," ;; esac
  case ",$fields," in
    *,labels,*)
      printf '%s"labels":[' "$sep"
      lsep=""
      if [ -s "$f" ]; then
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          printf '%s{"name":"%s"}' "$lsep" "$l"; lsep=","
        done < "$f"
      fi
      printf ']' ;;
  esac
  printf '}\n'
  exit 0
fi

if [ "$sub" = "pr close" ] || [ "$sub" = "issue close" ]; then
  num=$1; shift
  case "$sub" in
    "pr close") printf 'pr-close %s\n' "$num" >> "$STUB_MUT_LOG" ;;
    *)          printf 'issue-close %s\n' "$num" >> "$STUB_MUT_LOG" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in --comment) shift; printf '%s\n' "${1:-}" > "$STUB_STATE_DIR/$num.prcomment" ;; esac
    shift
  done
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  if [ "$sub" = "pr close" ] && [ "${STUB_PRCLOSE_FAIL:-0}" = "1" ]; then
    echo "gh: could not close pull request" >&2; exit 1
  fi
  [ "${STUB_NOCLOSE:-0}" = "1" ] && exit 0
  echo CLOSED > "$STUB_STATE_DIR/$num.state"
  exit 0
fi

if [ "$sub" = "issue comment" ]; then
  num=$1; shift
  printf 'issue-comment %s\n' "$num" >> "$STUB_MUT_LOG"
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  while [ $# -gt 0 ]; do
    case "$1" in --body) shift; printf '%s\n' "${1:-}" > "$STUB_STATE_DIR/$num.comment" ;; esac
    shift
  done
  exit 0
fi

if [ "$sub" = "issue edit" ]; then
  num=$1; shift
  printf 'edit %s %s\n' "$num" "$*" >> "$STUB_EDIT_LOG"
  printf 'edit %s\n' "$num" >> "$STUB_MUT_LOG"
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

# run <mode> <전이> <issue> <pr> [옵션...] — 스텁으로 SUT 를 돌리고 exit code 를 RC 에.
run() {
  local mode=$1 tname=$2 iss=$3 prn=$4; shift 4
  STUB_MODE="$mode" STUB_STATE_DIR="$tmp/state" STUB_SETUP_FAIL="${STUB_SETUP_FAIL:-0}" \
  STUB_EDIT_LOG="$tmp/edit.log" STUB_SETUP_LOG="$tmp/setup.log" STUB_MUT_LOG="$tmp/mut.log" \
  STUB_PRCLOSE_FAIL="${STUB_PRCLOSE_FAIL:-0}" STUB_NOCLOSE="${STUB_NOCLOSE:-0}" \
  PATH="$tmp/bin:$PATH" "$SUT" "$tname" owner/repo "$iss" "$prn" "$@" >"$tmp/out" 2>"$tmp/err"
  RC=$?
}

reset() {
  rm -rf "$tmp/state"; mkdir -p "$tmp/state"
  : > "$tmp/edit.log"; : > "$tmp/setup.log"; : > "$tmp/mut.log"
}

# seed_state <num> <OPEN|CLOSED|MERGED>
seed_state() { printf '%s\n' "$2" > "$tmp/state/$1.state"; }

# mut_order — 쓰기 호출 순서를 한 줄로(읽기는 애초에 안 실린다)
mut_order() { tr '\n' '|' < "$tmp/mut.log" | sed 's/|$//'; }
edits() { grep -c '^edit ' "$tmp/edit.log"; }

# labels_of <num> — 현재 픽스처 라벨(정렬)
labels_of() { sort "$tmp/state/$1.labels" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
sorted() { printf '%s\n' $1 | sort | tr '\n' ' ' | sed 's/ *$//'; }

# ── ① 7개 전이의 add/remove 집합이 표와 일치(PR·이슈 양쪽) ───────────────────
# "모든 라벨을 다 붙여 둔" 픽스처에서 전이를 걸면, 남는 집합 = (전체 − remove) ∪ add.
# 기대값을 여기 손으로 적어 표를 두 번 쓰게 만든다(SUT 의 case 를 그대로 베끼면 공허해진다).
# hold:* 세 개도 픽스처에 넣는다 — 그래야 "사람 대기 두 전이 외엔 hold 를 안 건드린다"
# 와 "반송 두 전이는 hold 를 뗀다" 가 둘 다 실증된다(#147).
ALL="agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder"

# expect <전이> <PR 기대 잔존> <이슈 기대 잔존> [옵션...]
expect() {
  local name=$1 want_pr=$2 want_iss=$3; shift 3
  reset
  # shellcheck disable=SC2086
  seed 7 $ALL
  # shellcheck disable=SC2086
  seed 9 $ALL
  run ok "$name" 9 7 "$@"
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
  "agent-ready agent:claimed flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder" \
  "agent-ready flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder"
expect verify-pass \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder" \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder"
# ↓ 반송 = 사람 대기 해제(#147) — needs-human 과 hold:* 셋이 양쪽에서 사라진다.
expect verify-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting" \
  "agent-ready flow:ci flow:codex flow:ready harvesting"
# ↓ verify-held·closeout-blocked 의 PR add 중 needs-human 은 ALL 픽스처에 이미 있다.
#   비공허 실증은 hold 쪽이 맡는다 — 준 사유만 남고 나머지 둘이 사라져야 한다.
expect verify-held \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:ladder" \
  "agent-ready flow:ci flow:codex flow:ready harvesting needs-human hold:ladder" \
  --reason ladder
expect closeout-pick \
  "agent-ready agent:claimed harvesting needs-human hold:conflict hold:policy hold:ladder" \
  "agent-ready agent:claimed flow:ci flow:codex harvesting needs-human hold:conflict hold:policy hold:ladder"
expect closeout-blocked \
  "agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready needs-human hold:conflict" \
  "agent-ready agent:claimed flow:ci flow:codex needs-human hold:conflict" \
  --reason conflict
expect closeout-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex" \
  "agent-ready flow:ci flow:codex"
# 옵션이 맨 앞에 와도 같은 결과 — 파싱이 위치에 안 묶였는지(#147)
reset
# shellcheck disable=SC2086
seed 7 $ALL
# shellcheck disable=SC2086
seed 9 $ALL
STUB_MODE=ok STUB_STATE_DIR="$tmp/state" STUB_EDIT_LOG="$tmp/edit.log" \
  STUB_SETUP_LOG="$tmp/setup.log" STUB_MUT_LOG="$tmp/mut.log" \
  PATH="$tmp/bin:$PATH" "$SUT" --reason ladder verify-held owner/repo 9 7 >/dev/null 2>&1
ck "옵션 선행: exit 0" "$?" 0
ck "옵션 선행: PR 라벨" "$(labels_of 7)" \
  "$(sorted "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:ladder")"

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
run ok verify-held - 7 --reason conflict
ck "verify-held issue=-: exit 0" "$RC" 0
ck "verify-held issue=-: PR 에 needs-human+사유" "$(labels_of 7)" "$(sorted "needs-human hold:conflict")"

reset; seed 7 harvesting
run ok closeout-blocked - 7 --reason policy
ck "closeout-blocked issue=-: exit 0" "$RC" 0
ck "closeout-blocked issue=-: PR 에 needs-human+사유" "$(labels_of 7)" "$(sorted "needs-human hold:policy")"

# 양쪽 다 있는 정상 호출에서도 PR·이슈 둘 다 needs-human 을 받는다
reset; seed 7 harvesting; seed 9 "harvesting" "flow:ready"
run ok closeout-blocked 9 7 --reason ladder
ck "closeout-blocked 양쪽: PR needs-human" "$(labels_of 7)" "$(sorted "needs-human hold:ladder")"
ck "closeout-blocked 양쪽: 이슈 needs-human" "$(labels_of 9)" "$(sorted "needs-human hold:ladder")"

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
  STUB_EDIT_LOG="$tmp/edit.log" STUB_SETUP_LOG="$tmp/setup.log" STUB_MUT_LOG="$tmp/mut.log" \
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

# ── ⑦ --reason 게이트 (#147) — 사유 없는 needs-human 을 만들 수 없다 ──────────
# 거부는 gh 를 **한 번도 부르기 전에** 나야 한다: 라벨이 반만 움직인 뒤 64 로 끝나면
# PR 과 이슈가 갈린다.
for bad in "" dup hardware conflicted ""; do
  for t in verify-held closeout-blocked; do
    reset; seed 7 flow:verify harvesting; seed 9 flow:verify harvesting
    if [ -z "$bad" ]; then
      run ok "$t" 9 7
      lbl="--reason 없음"
    else
      run ok "$t" 9 7 --reason "$bad"
      lbl="--reason $bad"
    fi
    ck "$t $lbl: exit 64" "$RC" 64
    ck "$t $lbl: gh edit 0회" "$(edits)" 0
  done
done
# 금지 사유는 왜 금지인지 usage 가 말해 준다(문서 대신 도구가 가르친다)
reset; run ok verify-held 9 7 --reason dup
check "usage 에 허용값 셋" \
  "$(grep -q 'conflict|policy|ladder' "$tmp/err" && echo ok || echo no)"
check "usage 에 dup→closeout-dup · hardware→사다리" \
  "$(grep -q 'closeout-dup' "$tmp/err" && grep -q '사다리' "$tmp/err" && echo ok || echo no)"
# 값 없이 끝나는 --reason 은 다음 위치 인자를 삼키지 않는다
reset; run ok verify-held 9 7 --reason
ck "--reason 값 누락: exit 64" "$RC" 64

# 사유를 받을 수 없는 전이에 주면 무시가 아니라 거부 — 호출부가 "붙었겠지" 하면 안 된다
for t in handoff-verify verify-pass verify-redispatch closeout-pick closeout-redispatch; do
  reset; seed 7 flow:verify; seed 9 flow:verify
  run ok "$t" 9 7 --reason ladder
  ck "$t 에 --reason: exit 64" "$RC" 64
  ck "$t 에 --reason: gh edit 0회" "$(edits)" 0
done
reset; run ok closeout-dup 9 7 --note n --reason ladder
ck "closeout-dup 에 --reason: exit 64" "$RC" 64
# --note 도 대칭으로 막는다(스펙 확장 — "무시하지 않는다" 원칙을 --note 에도 적용)
reset; run ok verify-held 9 7 --reason ladder --note n
ck "verify-held 에 --note: exit 64" "$RC" 64

# ── ⑧ 세 사유가 각각 붙고, 나머지 두 hold 는 떨어진다(사유 교체 멱등) ────────
for r in conflict policy ladder; do
  reset
  seed 7 flow:verify hold:conflict hold:policy hold:ladder
  seed 9 flow:verify agent:claimed hold:conflict hold:policy hold:ladder
  run ok verify-held 9 7 --reason "$r"
  ck "verify-held/$r: exit 0" "$RC" 0
  ck "verify-held/$r: PR" "$(labels_of 7)" "$(sorted "needs-human hold:$r")"
  ck "verify-held/$r: 이슈" "$(labels_of 9)" "$(sorted "needs-human hold:$r")"

  reset
  seed 7 harvesting hold:conflict hold:policy hold:ladder
  seed 9 harvesting flow:ready flow:verify hold:conflict hold:policy hold:ladder
  run ok closeout-blocked 9 7 --reason "$r"
  ck "closeout-blocked/$r: exit 0" "$RC" 0
  ck "closeout-blocked/$r: PR" "$(labels_of 7)" "$(sorted "needs-human hold:$r")"
  ck "closeout-blocked/$r: 이슈" "$(labels_of 9)" "$(sorted "needs-human hold:$r")"
done

# 사유 교체: conflict 로 잡아 둔 건을 ladder 로 바꾸면 옛 사유가 남지 않는다
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
run ok verify-held 9 7 --reason conflict
ck "교체 전: PR hold:conflict" "$(labels_of 7)" "$(sorted "needs-human hold:conflict")"
run ok verify-held 9 7 --reason ladder
ck "교체 후: exit 0" "$RC" 0
ck "교체 후: PR hold:ladder 뿐" "$(labels_of 7)" "$(sorted "needs-human hold:ladder")"
ck "교체 후: 이슈 hold:ladder 뿐" "$(labels_of 9)" "$(sorted "needs-human hold:ladder")"
run ok verify-held 9 7 --reason ladder
ck "교체 재실행: exit 0" "$RC" 0
ck "교체 재실행: PR 동일" "$(labels_of 7)" "$(sorted "needs-human hold:ladder")"
ck "교체 재실행: 이슈 동일" "$(labels_of 9)" "$(sorted "needs-human hold:ladder")"

# ── ⑨ 반송 = 사람 대기 해제 — 재개 스윕(#147 §4)이 쓰는 통로 ──────────────────
reset; seed 7 flow:verify needs-human hold:ladder
seed 9 flow:verify agent:claimed needs-human hold:ladder
run ok verify-redispatch 9 7
ck "verify-redispatch: exit 0" "$RC" 0
ck "verify-redispatch: PR 사람대기 해제" "$(labels_of 7)" ""
ck "verify-redispatch: 이슈 = agent-ready" "$(labels_of 9)" "agent-ready"

reset; seed 7 harvesting needs-human hold:policy
seed 9 harvesting flow:ready agent:claimed needs-human hold:policy
run ok closeout-redispatch 9 7
ck "closeout-redispatch: exit 0" "$RC" 0
ck "closeout-redispatch: PR 사람대기 해제" "$(labels_of 7)" ""
ck "closeout-redispatch: 이슈 = agent-ready" "$(labels_of 9)" "agent-ready"

# ── ⑩ closeout-dup — 중복은 루프가 닫는다(needs-human 을 거치지 않는다) ───────
NOTE="이미 main 에 반영 — abc1234"
dup_seed() {
  reset
  seed 7 harvesting flow:ci flow:codex flow:verify flow:ready
  seed 9 agent-ready agent:claimed harvesting
}

dup_seed
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup: exit 0" "$RC" 0
ck "closeout-dup: PR 라벨 = dup" "$(labels_of 7)" "dup"
ck "closeout-dup: 쓰기 순서" "$(mut_order)" \
  "edit 7|pr-close 7|issue-comment 9|issue-close 9|release-labels 9"
ck "closeout-dup: PR CLOSED" "$(cat "$tmp/state/7.state")" CLOSED
ck "closeout-dup: 이슈 CLOSED" "$(cat "$tmp/state/9.state")" CLOSED
check "closeout-dup: 이슈 코멘트에 근거·PR 번호" \
  "$(grep -q "중복: $NOTE — PR #7 머지 없이 종료" "$tmp/state/9.comment" && echo ok || echo no)"
check "closeout-dup: 이슈 코멘트에 워커 마커" \
  "$(grep -qF '<!-- bodat:worker -->' "$tmp/state/9.comment" && echo ok || echo no)"
check "closeout-dup: 성공 한 줄 출력" \
  "$(grep -q 'issue=9 pr=7' "$tmp/out" && echo ok || echo no)"

# --note 는 필수 — 근거 없는 자동 종료를 만들 수 없다(gh 는 한 번도 안 부른다)
dup_seed
run ok closeout-dup 9 7
ck "closeout-dup --note 없음: exit 64" "$RC" 64
ck "closeout-dup --note 없음: 쓰기 0회" "$(mut_order)" ""
dup_seed
run ok closeout-dup 9 7 --note
ck "closeout-dup --note 값 누락: exit 64" "$RC" 64
# 닫을 PR 이 없으면 ①② 가 통째로 사라진다 — 조용한 no-op 대신 usage
dup_seed
run ok closeout-dup 9 -
ck "closeout-dup pr=-: exit 64" "$RC" 64

# 이슈가 `-` 면 PR 만 — ③④ 는 건너뛴다
dup_seed
run ok closeout-dup - 7 --note "$NOTE"
ck "closeout-dup issue=-: exit 0" "$RC" 0
ck "closeout-dup issue=-: PR 만" "$(mut_order)" "edit 7|pr-close 7"
check "closeout-dup issue=-: PR 코멘트 본문" \
  "$(grep -q "중복 종료: $NOTE" "$tmp/state/7.prcomment" 2>/dev/null && echo ok || echo no)"

# 멱등 — 이미 CLOSED 면 close 를 건너뛴다(코멘트는 남긴다)
dup_seed
seed_state 7 CLOSED; seed_state 9 CLOSED
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 이미 CLOSED: exit 0" "$RC" 0
ck "closeout-dup 이미 CLOSED: close 미호출" "$(mut_order)" \
  "edit 7|issue-comment 9|release-labels 9"

# 두 번 걸어도 무해 — 두 번째 런은 close 를 건너뛰고 같은 상태로 끝난다
dup_seed
run ok closeout-dup 9 7 --note "$NOTE"
first_dup=$(labels_of 7)
: > "$tmp/mut.log"   # 2회차의 쓰기만 보려고 로그만 비운다(픽스처 상태는 그대로 이어간다)
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 2회차: exit 0" "$RC" 0
ck "closeout-dup 2회차: PR 라벨 동일" "$(labels_of 7)" "$first_dup"
ck "closeout-dup 2회차: close 미호출" "$(mut_order)" \
  "edit 7|issue-comment 9|release-labels 9"

# readback — 라벨이 안 붙었으면 1
dup_seed
run ignore closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 라벨 불일치: exit 1" "$RC" 1
check "closeout-dup 라벨 불일치: stderr 에 dup" \
  "$(grep -q "'dup' 미부착" "$tmp/err" && echo ok || echo no)"

# readback — close 가 먹지 않았으면(상태 그대로) 1
dup_seed
STUB_NOCLOSE=1 run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 상태 불일치: exit 1" "$RC" 1
check "closeout-dup 상태 불일치: stderr 에 CLOSED 아님" \
  "$(grep -q 'CLOSED 아님' "$tmp/err" && echo ok || echo no)"
unset STUB_NOCLOSE

# gh 실패는 종전 규약대로 2
dup_seed
STUB_PRCLOSE_FAIL=1 run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup pr close 실패: exit 2" "$RC" 2
check "closeout-dup pr close 실패: stderr 한 줄" \
  "$(grep -q '종료 실패' "$tmp/err" && echo ok || echo no)"
ck "closeout-dup pr close 실패: 이슈는 안 건드린다" \
  "$(mut_order)" "edit 7|pr-close 7"
unset STUB_PRCLOSE_FAIL

echo "transition: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
