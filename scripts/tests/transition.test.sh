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
[ "${STUB_REL_FAIL:-0}" = "1" ] && exit 1
exit 0
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

if [ "$sub" = "issue comment" ] || [ "$sub" = "pr comment" ]; then
  num=$1; shift
  case "$sub" in
    "pr comment") printf 'pr-comment %s\n' "$num" >> "$STUB_MUT_LOG"; cf="$STUB_STATE_DIR/$num.prcomment" ;;
    *)            printf 'issue-comment %s\n' "$num" >> "$STUB_MUT_LOG"; cf="$STUB_STATE_DIR/$num.comment" ;;
  esac
  [ "$mode" = "fail" ] && { echo "gh: connection refused" >&2; exit 1; }
  # 코멘트 API 만 일시 실패(#157) — 라벨 편집은 멀쩡한데 코멘트만 안 되는 실측 상황.
  # STUB_COMMENT_FAIL=1 이면 전부, STUB_COMMENT_FAIL_NTH=<n> 이면 n 번째 호출만 실패한다
  # (양쪽 대상 중 **둘째**만 실패하는 부분 성공을 재현하려면 카운터가 있어야 한다).
  n=1
  if [ -f "$STUB_STATE_DIR/.commentcount" ]; then n=$(( $(cat "$STUB_STATE_DIR/.commentcount") + 1 )); fi
  echo "$n" > "$STUB_STATE_DIR/.commentcount"
  [ "${STUB_COMMENT_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; }
  [ "$n" = "${STUB_COMMENT_FAIL_NTH:-0}" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; }
  while [ $# -gt 0 ]; do
    case "$1" in --body) shift; printf '%s\n' "${1:-}" >> "$cf" ;; esac
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
  if [ "$mode" = "notfound-quoted-once" ]; then   # 실측 형식: remove 대상이 레포에 없을 때
    if [ ! -f "$STUB_STATE_DIR/.tripped" ]; then
      : > "$STUB_STATE_DIR/.tripped"
      echo "failed to update https://github.com/owner/repo/issues/$num: 'hold:conflict' not found" >&2
      echo "failed to update 1 issue" >&2
      exit 1
    fi
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
  STUB_REL_FAIL="${STUB_REL_FAIL:-0}" STUB_COMMENT_FAIL="${STUB_COMMENT_FAIL:-0}" \
  STUB_COMMENT_FAIL_NTH="${STUB_COMMENT_FAIL_NTH:-0}" \
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
# `verifying`(#275) 도 픽스처에 넣는다 — verify-runner 가 집은 뒤의 **모든 출구**(verify-pass·
# verify-redispatch·verify-held·closeout-pick·closeout-blocked·closeout-redispatch·closeout-dup)가
# 이 점유 라벨을 떼야 한다. 하나라도 빠지면 "단계 라벨 중복" 이 남아 다음 틱이 고아로 재집는다.
# PR 미러 두 칸(#281) — `flow:agent-ready`(반송 대기)·`flow:claimed`(구현중)도 픽스처에 넣는다.
# 반송 두 전이는 PR 에 `flow:agent-ready` 를 **더하고**, 사다리를 오르는 네 전이(handoff-verify·
# verify-pick·closeout-pick·closeout-dup)는 둘 다 **뗀다**. 이슈 쪽은 이 둘을 모른다(PR 전용
# 이름) — 이슈 픽스처에 심어 두면 "이슈 쪽에서 절대 안 건드린다" 도 함께 실증된다.
ALL="agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder verifying flow:agent-ready flow:claimed"

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
# handoff-verify 는 워커 소유 전이라 `verifying` 을 모른다(그 시점엔 verify-redispatch 가 이미
# 뗐다) — 픽스처에 든 verifying 이 **그대로 남는** 것이 기대값이다.
expect handoff-verify \
  "agent-ready agent:claimed flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder verifying" \
  "agent-ready flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder verifying flow:agent-ready flow:claimed"
expect verify-pass \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder flow:agent-ready flow:claimed" \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder flow:agent-ready flow:claimed"
# ↓ 반송 = 사람 대기 해제(#147) — needs-human 과 hold:* 셋이 양쪽에서 사라진다.
#   PR 에는 대기 칸 미러 `flow:agent-ready` 가 붙는다(#281 — 픽스처에 이미 있으니 비공허 실증은
#   아래 ⑨ 의 맨몸 픽스처가 맡는다). `flow:claimed` 는 반송 표에 없어 그대로 남는다.
expect verify-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting flow:agent-ready flow:claimed" \
  "agent-ready flow:ci flow:codex flow:ready harvesting flow:agent-ready flow:claimed"
# ↓ verify-held·closeout-blocked 의 PR add 중 needs-human 은 ALL 픽스처에 이미 있다.
#   비공허 실증은 hold 쪽이 맡는다 — 준 사유만 남고 나머지 둘이 사라져야 한다.
expect verify-held \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:ladder flow:agent-ready flow:claimed" \
  "agent-ready flow:ci flow:codex flow:ready harvesting needs-human hold:ladder flow:agent-ready flow:claimed" \
  --reason ladder
expect closeout-pick \
  "agent-ready agent:claimed harvesting needs-human hold:conflict hold:policy hold:ladder" \
  "agent-ready agent:claimed flow:ci flow:codex harvesting needs-human hold:conflict hold:policy hold:ladder flow:agent-ready flow:claimed"
expect closeout-blocked \
  "agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready needs-human hold:conflict flow:agent-ready flow:claimed" \
  "agent-ready agent:claimed flow:ci flow:codex needs-human hold:conflict flow:agent-ready flow:claimed" \
  --reason conflict --note q
expect closeout-redispatch \
  "agent-ready agent:claimed flow:ci flow:codex flow:agent-ready flow:claimed" \
  "agent-ready flow:ci flow:codex flow:agent-ready flow:claimed"
# ↓ verify-pick(#275) — closeout-pick 과 같은 꼴: 검증대기(flow:verify)를 떼고 점유(verifying)를
#   붙인다. 그 외 라벨(사람 대기·harvesting·자격)은 손대지 않는다. PR 의 워커 칸 미러 둘은
#   방어적으로 뗀다(#281).
expect verify-pick \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder verifying" \
  "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder verifying flow:agent-ready flow:claimed"
# ↓ verify-unpick(#275) — verify-pick 의 정확한 역(flake_retry: 판정 없이 검증대기로 되돌린다).
expect verify-unpick \
  "agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder flow:agent-ready flow:claimed" \
  "agent-ready agent:claimed flow:ci flow:codex flow:verify flow:ready harvesting needs-human hold:conflict hold:policy hold:ladder flow:agent-ready flow:claimed"
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
  "$(sorted "agent-ready agent:claimed flow:ci flow:codex flow:ready harvesting needs-human hold:ladder flow:agent-ready flow:claimed")"

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

# ②-b 연결 이슈 없는 PR(issue=-)에도 사람 신호가 남는가 — 이슈에만 붙이면 정지 라벨
# 이 아무 데도 안 붙고 exit 0 `ok` 로 끝나 사람 대기가 조용히 사라진다.
reset; seed 7 flow:verify
run ok verify-held - 7 --reason conflict --note q
ck "verify-held issue=-: exit 0" "$RC" 0
ck "verify-held issue=-: PR 에 사유 라벨만(needs-human 없음)" "$(labels_of 7)" "$(sorted "hold:conflict")"

reset; seed 7 harvesting
run ok closeout-blocked - 7 --reason policy --note q
ck "closeout-blocked issue=-: exit 0" "$RC" 0
ck "closeout-blocked issue=-: PR 에 사유 라벨만(needs-human 없음)" "$(labels_of 7)" "$(sorted "hold:policy")"

# 양쪽 다 있는 정상 호출에서도 PR·이슈 둘 다 사유 라벨을 받는다(needs-human 은 안 붙는다, #244)
reset; seed 7 harvesting; seed 9 "harvesting" "flow:ready"
run ok closeout-blocked 9 7 --reason ladder
ck "closeout-blocked 양쪽: PR 사유 라벨만" "$(labels_of 7)" "$(sorted "hold:ladder")"
ck "closeout-blocked 양쪽: 이슈 사유 라벨만" "$(labels_of 9)" "$(sorted "hold:ladder")"

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

# 실측 형식(2026-09-09): 레포에 없는 라벨은 --remove-label 도 편집을 통째로 실패시키고
# 메시지는 `'hold:conflict' not found` 라 "label" 단어가 없다 → 그래도 보강 1회 + 재시도 성공.
reset; seed 7 flow:verify; seed 9 flow:verify
run notfound-quoted-once verify-held 9 7 --reason ladder
ck "따옴표 not found: exit 0" "$RC" 0
ck "따옴표 not found: setup-labels 1회" "$(grep -c . "$tmp/setup.log")" 1
ck "따옴표 not found: edit 3회(PR 원본+재시도, 이슈 1회)" "$(grep -c '^edit ' "$tmp/edit.log")" 3

# runner-held(#151) — 디스패처 자체의 사람 대기: 이슈 agent:claimed 해제 + 양쪽 hold:<r>(needs-human 은 안 붙인다, #244),
# 단계 라벨(flow:*·harvesting)은 손대지 않는다. PR 없음(`-`) 허용, --reason 필수.
reset; seed 7 flow:ci; seed 9 agent-ready agent:claimed hold:ladder
run ok runner-held 9 7 --reason policy --note q
ck "runner-held: exit 0" "$RC" 0
ck "runner-held: 이슈 라벨" "$(labels_of 9)" "agent-ready hold:policy"
ck "runner-held: PR 라벨(flow:ci 유지)" "$(labels_of 7)" "flow:ci hold:policy"
reset; seed 9 agent-ready agent:claimed
run ok runner-held 9 - --reason policy --note q
ck "runner-held issue만: exit 0" "$RC" 0
ck "runner-held issue만: 이슈 라벨" "$(labels_of 9)" "agent-ready hold:policy"
reset; seed 9 agent-ready agent:claimed
run ok runner-held 9 -
ck "runner-held --reason 없음: exit 64" "$RC" 64

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

# ── ⑥-b verify-pick ↔ verify-unpick 왕복(#275) — 원상 복귀 + 각각 두 번 걸어도 멱등 ────
# 기대값은 손으로 적는다: 검증대기 형상(PR flow:verify · 이슈 flow:verify+agent-ready)에서
# pick 하면 flow:verify 자리에 verifying 만 들어오고, unpick 하면 정확히 원래 집합이다.
reset; seed 7 flow:verify; seed 9 flow:verify agent-ready
run ok verify-pick 9 7
ck "verify-pick: exit 0" "$RC" 0
ck "verify-pick: PR = verifying" "$(labels_of 7)" "verifying"
ck "verify-pick: 이슈 = agent-ready verifying" "$(labels_of 9)" "agent-ready verifying"
run ok verify-pick 9 7
ck "verify-pick 2회차: exit 0(멱등)" "$RC" 0
ck "verify-pick 2회차: PR 동일" "$(labels_of 7)" "verifying"
ck "verify-pick 2회차: 이슈 동일" "$(labels_of 9)" "agent-ready verifying"
run ok verify-unpick 9 7
ck "verify-unpick: exit 0" "$RC" 0
ck "verify-unpick: PR 원상(flow:verify)" "$(labels_of 7)" "flow:verify"
ck "verify-unpick: 이슈 원상(agent-ready flow:verify)" "$(labels_of 9)" "agent-ready flow:verify"
run ok verify-unpick 9 7
ck "verify-unpick 2회차: exit 0(멱등)" "$RC" 0
ck "verify-unpick 2회차: PR 동일" "$(labels_of 7)" "flow:verify"
ck "verify-unpick 2회차: 이슈 동일" "$(labels_of 9)" "agent-ready flow:verify"
# 연결 이슈 없는 PR(issue=-)도 정식 호출 — 점유가 PR 에만 남는다.
reset; seed 7 flow:verify
run ok verify-pick - 7
ck "verify-pick issue=-: exit 0" "$RC" 0
ck "verify-pick issue=-: PR = verifying" "$(labels_of 7)" "verifying"
check "verify-pick issue=-: 이슈 edit 없음" \
  "$(grep -q '^edit 9 ' "$tmp/edit.log" && echo no || echo ok)"
# usage 에 두 전이가 나열돼야 호출부가 이름을 찾는다.
reset; run ok bogus-transition 9 7
check "usage 에 verify-pick·verify-unpick" \
  "$(grep -q 'verify-pick' "$tmp/err" && grep -q 'verify-unpick' "$tmp/err" && echo ok || echo no)"

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
for t in handoff-verify verify-pass verify-redispatch closeout-pick closeout-redispatch verify-pick verify-unpick; do
  reset; seed 7 flow:verify; seed 9 flow:verify
  run ok "$t" 9 7 --reason ladder
  ck "$t 에 --reason: exit 64" "$RC" 64
  ck "$t 에 --reason: gh edit 0회" "$(edits)" 0
done
reset; run ok closeout-dup 9 7 --note n --reason ladder
ck "closeout-dup 에 --reason: exit 64" "$RC" 64
# --note 도 대칭으로 막는다(스펙 확장 — "무시하지 않는다" 원칙을 --note 에도 적용)
reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-held 9 7 --reason ladder --note n
ck "verify-held ladder 에 --note(선택): exit 0" "$RC" 0
reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-pass 9 7 --note n
ck "verify-pass 에 --note: exit 64" "$RC" 64
# policy·conflict 는 질문 한 줄(--note)이 없으면 사람 몫이 아니다 → 64, 있으면 양쪽에 코멘트
reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-held 9 7 --reason policy
ck "verify-held policy --note 없음: exit 64" "$RC" 64
ck "verify-held policy --note 없음: 쓰기 0회" "$(mut_order)" ""
reset; seed 7 flow:verify; seed 9 flow:verify
run ok verify-held 9 7 --reason policy --note "이 스펙 갈림길은 A인가 B인가"
ck "verify-held policy --note: exit 0" "$RC" 0
ck "verify-held policy --note: 이슈 라벨" "$(labels_of 9)" "hold:policy"
case "$(mut_order)" in *"issue-comment 9"*"pr-comment 7"*|*"pr-comment 7"*"issue-comment 9"*) c=ok ;; *) c="$(mut_order)" ;; esac
ck "verify-held policy --note: 양쪽 코멘트" "$c" ok
reset; seed 9 agent-ready agent:claimed
run ok runner-held 9 - --reason conflict --note "충돌 해소 방향?"
ck "runner-held conflict --note(issue만): exit 0" "$RC" 0
case "$(mut_order)" in *"issue-comment 9"*) c=ok ;; *) c="$(mut_order)" ;; esac
ck "runner-held conflict --note: 이슈 코멘트" "$c" ok

# ── ⑦-b 질문 코멘트가 라벨보다 **먼저** (#157) ───────────────────────────────
# 코멘트가 라벨 뒤였을 때: 코멘트 API 가 일시 실패해도 라벨(needs-human+hold:*)은 이미
# 붙어 있어 "질문 없는 홀드" 가 남았다(재시도 주체 없음). 순서를 뒤집으면 코멘트 실패가
# 라벨 편집 **전에** exit 2 로 끝나 호출부가 다음 틱에 통째로 다시 건다.
for t in verify-held closeout-blocked runner-held; do
  reset; seed 7 flow:verify harvesting; seed 9 flow:verify harvesting agent:claimed
  STUB_COMMENT_FAIL=1 run ok "$t" 9 7 --reason policy --note "A인가 B인가"
  ck "$t 코멘트 실패: exit 2" "$RC" 2
  ck "$t 코멘트 실패: 라벨 편집 0회" "$(edits)" 0
  ck "$t 코멘트 실패: PR 라벨 무편집" "$(labels_of 7)" "$(sorted "flow:verify harvesting")"
  ck "$t 코멘트 실패: 이슈 라벨 무편집" "$(labels_of 9)" "$(sorted "flow:verify harvesting agent:claimed")"
  check "$t 코멘트 실패: stderr 에 코멘트 실패 한 줄" \
    "$(grep -q '코멘트 실패' "$tmp/err" && echo ok || echo no)"
  # 옛 문구("라벨은 반영됨")가 남아 있으면 사람이 라벨을 손으로 떼러 간다 — 사실과 반대다.
  check "$t 코멘트 실패: '라벨은 반영됨' 을 말하지 않는다" \
    "$(grep -q '라벨은 반영됨' "$tmp/err" && echo no || echo ok)"
done
unset STUB_COMMENT_FAIL

# **부분 성공** — 첫 코멘트(이슈)는 갔는데 둘째(PR)가 실패한 경우. "코멘트 둘 다 성공해야
# 라벨" 이 계약이라 여기서도 라벨은 0회다. 전부 실패시키는 스위치로는 이 경로를 못 짚는다
# (SUT 가 이슈부터 부르므로 PR 코멘트는 아예 시도되지 않는다) — 둘째만 실패시켜야 한다.
reset; seed 7 flow:verify; seed 9 flow:verify
STUB_COMMENT_FAIL_NTH=2 run ok verify-held 9 7 --reason conflict --note q
ck "둘째 코멘트만 실패: exit 2" "$RC" 2
ck "둘째 코멘트만 실패: 라벨 편집 0회" "$(edits)" 0
ck "둘째 코멘트만 실패: 첫 코멘트는 실제로 갔다" "$(mut_order)" "issue-comment 9|pr-comment 7"
ck "둘째 코멘트만 실패: PR 라벨 무편집" "$(labels_of 7)" "flow:verify"
ck "둘째 코멘트만 실패: 이슈 라벨 무편집" "$(labels_of 9)" "flow:verify"
check "둘째 코멘트만 실패: 실패한 쪽을 지목한다" \
  "$(grep -q 'pr #7 사유 코멘트 실패' "$tmp/err" && echo ok || echo no)"
unset STUB_COMMENT_FAIL_NTH

# 과차단 회귀 가드 — 코멘트가 되는 정상 경로에선 라벨이 종전대로 붙고, 쓰기 순서가
# 코멘트 → 라벨 이다(순서를 실측으로 못 박는다).
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
run ok verify-held 9 7 --reason policy --note "A인가 B인가"
ck "순서: exit 0" "$RC" 0
ck "순서: 코멘트가 라벨 편집보다 앞" "$(mut_order)" \
  "issue-comment 9|pr-comment 7|edit 7|edit 9"
ck "순서: PR 라벨 종전대로" "$(labels_of 7)" "$(sorted "hold:policy")"
ck "순서: 이슈 라벨 종전대로" "$(labels_of 9)" "$(sorted "hold:policy")"
# ★생산자↔소비자 마커 계약★ — 이 코멘트를 읽는 쪽은 loop-status.sh(질문 유무)와
# resume-sweep.sh(policy 재심)다. 양쪽이 각자 손으로 적은 정규식을 쓰므로, 여기서 실제
# 생성 본문을 **그 소비자들의 정규식으로** 물어 둔다 — 안 그러면 포맷이 바뀌어도 세 스위트가
# 다 초록인 채 프로덕션만 깨진다(각 스위트는 자기 사본만 보므로).
check "마커 계약: 생성 본문이 소비자 정규식에 걸린다" \
  "$(grep -qE '<!--[[:space:]]*hold-note:[[:space:]]*policy' "$tmp/state/9.comment" && echo ok || echo no)"
check "마커 계약: loop-status.sh 가 같은 마커를 찾는다" \
  "$(grep -qF 'hold-note:' "$DIR/loop-status.sh" && echo ok || echo no)"
check "마커 계약: resume-sweep.sh 가 같은 마커를 찾는다" \
  "$(grep -qF 'hold-note:' "$DIR/resume-sweep.sh" && echo ok || echo no)"
check "마커 계약: 워커 마커가 마지막 줄" \
  "$(tail -1 "$tmp/state/9.comment" | grep -qF '<!-- bodat:worker -->' && echo ok || echo no)"
# ★사유별 계약★ (#160) — loop-status 는 **지금 붙은 사유와 같은 사유**의 마커만 질문으로
# 센다(코멘트는 홀드가 풀려도 남으므로 낡은 사유의 마커가 지금 홀드를 가리면 안 된다).
# 그 규칙이 성립하려면 생산자가 사유를 **가려낼 수 있게** 실어 써야 한다 — 여기서 두 사유의
# 실제 생성 본문을 서로의 정규식으로 물어 "같은 사유에만 걸린다" 를 양방향으로 못 박는다.
check "사유별 마커: policy 본문은 conflict 정규식에 안 걸린다" \
  "$(grep -qE '<!--[[:space:]]*hold-note:[[:space:]]*conflict' "$tmp/state/9.comment" && echo no || echo ok)"
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
run ok verify-held 9 7 --reason conflict --note "어느 쪽으로 풀까"
ck "사유별 마커: conflict 홀드 exit 0" "$RC" 0
check "사유별 마커: conflict 본문이 conflict 정규식에 걸린다" \
  "$(grep -qE '<!--[[:space:]]*hold-note:[[:space:]]*conflict' "$tmp/state/9.comment" && echo ok || echo no)"
check "사유별 마커: conflict 본문은 policy 정규식에 안 걸린다" \
  "$(grep -qE '<!--[[:space:]]*hold-note:[[:space:]]*policy' "$tmp/state/9.comment" && echo no || echo ok)"
# 소비자(loop-status.sh)가 사유를 실제로 가리는지 — 사유 없는 마커 정규식 하나로 되돌아가면
# 여기서 걸린다(그 회귀의 행동 단언은 loop-status.test.sh ⑫-d 가 든다).
check "마커 계약: loop-status.sh 의 마커 정규식이 사유를 실어 나른다" \
  "$(grep -qF 'hold-note:\\s*(" + $reasons' "$DIR/loop-status.sh" && echo ok || echo no)"

# --note 가 없는 전이(ladder 선택 · 그 밖의 전이)는 코멘트 단계를 아예 거치지 않는다 —
# 코멘트 API 가 죽어 있어도 라벨은 종전대로 움직인다(과차단 회귀 가드).
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
STUB_COMMENT_FAIL=1 run ok verify-held 9 7 --reason ladder
ck "note 없는 ladder 홀드: 코멘트 API 죽어도 exit 0" "$RC" 0
ck "note 없는 ladder 홀드: PR 라벨" "$(labels_of 7)" "$(sorted "hold:ladder")"
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
STUB_COMMENT_FAIL=1 run ok verify-pass 9 7
ck "verify-pass: 코멘트 API 죽어도 exit 0" "$RC" 0
ck "verify-pass: 라벨 종전대로" "$(labels_of 9)" "$(sorted "flow:ready agent:claimed")"
unset STUB_COMMENT_FAIL

# ── ⑧ 세 사유가 각각 붙고, 나머지 두 hold 는 떨어진다(사유 교체 멱등) ────────
for r in conflict policy ladder; do
  reset
  seed 7 flow:verify hold:conflict hold:policy hold:ladder
  seed 9 flow:verify agent:claimed hold:conflict hold:policy hold:ladder
  run ok verify-held 9 7 --reason "$r" --note q
  ck "verify-held/$r: exit 0" "$RC" 0
  ck "verify-held/$r: PR" "$(labels_of 7)" "$(sorted "hold:$r")"
  ck "verify-held/$r: 이슈" "$(labels_of 9)" "$(sorted "hold:$r")"

  reset
  seed 7 harvesting hold:conflict hold:policy hold:ladder
  seed 9 harvesting flow:ready flow:verify hold:conflict hold:policy hold:ladder
  run ok closeout-blocked 9 7 --reason "$r" --note q
  ck "closeout-blocked/$r: exit 0" "$RC" 0
  ck "closeout-blocked/$r: PR" "$(labels_of 7)" "$(sorted "hold:$r")"
  ck "closeout-blocked/$r: 이슈" "$(labels_of 9)" "$(sorted "hold:$r")"
done

# 사유 교체: conflict 로 잡아 둔 건을 ladder 로 바꾸면 옛 사유가 남지 않는다
reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
run ok verify-held 9 7 --reason conflict --note q
ck "교체 전: PR hold:conflict" "$(labels_of 7)" "$(sorted "hold:conflict")"
run ok verify-held 9 7 --reason ladder
ck "교체 후: exit 0" "$RC" 0
ck "교체 후: PR hold:ladder 뿐" "$(labels_of 7)" "$(sorted "hold:ladder")"
ck "교체 후: 이슈 hold:ladder 뿐" "$(labels_of 9)" "$(sorted "hold:ladder")"
run ok verify-held 9 7 --reason ladder
ck "교체 재실행: exit 0" "$RC" 0
ck "교체 재실행: PR 동일" "$(labels_of 7)" "$(sorted "hold:ladder")"
ck "교체 재실행: 이슈 동일" "$(labels_of 9)" "$(sorted "hold:ladder")"

# ── ⑧-b (#244) 기계 정지 세 전이는 `hold:<사유>` **하나만** 붙인다 ──────────────
# 플랜 label-taxonomy-cleanup 3단계: `needs-human` 은 "사람이 직접 세웠다" 하나만 뜻한다.
# 기계 정지(verify-held·closeout-blocked·runner-held)가 겹쳐 붙이면 사람대기 칸이
# "손댈 게 없는 것"(창 지나면 루프가 스스로 재개하는 hold:ladder)으로 찬다.
# ★픽스처에 needs-human 을 **안** 넣는 것이 이 단언의 전부다★ — ① 의 ALL 픽스처는
# needs-human 을 이미 품고 있어(그리고 이 세 전이는 어느 remove 칸에도 안 넣는다)
# "붙였다" 와 "원래 있었다" 를 구분하지 못한다. 뮤테이션(부착 되돌리기)에 빨개지는
# 것은 이 절이다.
for t in verify-held closeout-blocked runner-held; do
  for r in conflict policy ladder; do
    reset; seed 7 flow:verify; seed 9 flow:verify agent:claimed
    run ok "$t" 9 7 --reason "$r" --note q
    ck "$t/$r: exit 0" "$RC" 0
    check "$t/$r: PR 에 needs-human 미부착" \
      "$(grep -qx 'needs-human' "$tmp/state/7.labels" && echo no || echo ok)"
    check "$t/$r: 이슈에 needs-human 미부착" \
      "$(grep -qx 'needs-human' "$tmp/state/9.labels" && echo no || echo ok)"
    check "$t/$r: PR 에 사유 라벨은 붙는다(비공허)" \
      "$(grep -qx "hold:$r" "$tmp/state/7.labels" && echo ok || echo no)"
    check "$t/$r: 이슈에 사유 라벨은 붙는다(비공허)" \
      "$(grep -qx "hold:$r" "$tmp/state/9.labels" && echo ok || echo no)"
  done
done
# 이미 붙어 있던 `needs-human`(사람이 손으로 세운 정지)은 **떼지도 않는다** — 이 세 전이의
# remove 칸에 없다. ① 의 ALL 픽스처가 그 방향을 들지만, 사유 라벨 하나만 남는 좁은
# 픽스처에서도 한 번 못 박는다(remove 칸에 needs-human 이 새로 들어오면 여기가 빨개진다).
reset; seed 7 flow:verify needs-human; seed 9 flow:verify agent:claimed needs-human
run ok verify-held 9 7 --reason ladder
ck "verify-held: 사람이 붙인 needs-human 은 유지" "$(labels_of 9)" "$(sorted "needs-human hold:ladder")"

# ── ⑧-c (#244) policy-kept — 재심 "사람 몫 유지" 판정만이 needs-human 을 붙인다 ──
# `hold:policy` 재심(#155)은 디스패처가 1회 판정한다. 답이 정말 사람 결정이면(`policy-review:
# kept`) 그때 사람 호출이 된다 — 그 부착을 산문 `gh issue edit` 이 아니라 전이 하나로 묶는다
# (PR 미러 규약과 readback 을 공짜로 받는다). 떼는 라벨은 없다 — `hold:policy` 는 사유로 남는다.
reset; seed 7 flow:verify hold:policy; seed 9 agent-ready hold:policy
run ok policy-kept 9 7
ck "policy-kept: exit 0" "$RC" 0
ck "policy-kept: 이슈 = needs-human 추가, hold:policy 유지" "$(labels_of 9)" \
  "$(sorted "agent-ready hold:policy needs-human")"
ck "policy-kept: PR 미러도 같이" "$(labels_of 7)" \
  "$(sorted "flow:verify hold:policy needs-human")"
# 멱등 — 같은 전이를 두 번 걸어도 같은 상태
run ok policy-kept 9 7
ck "policy-kept 재실행: exit 0" "$RC" 0
ck "policy-kept 재실행: 이슈 동일" "$(labels_of 9)" "$(sorted "agent-ready hold:policy needs-human")"
# PR 없음(`-`) 허용 — 재심은 PR 이 없는 이슈에도 걸린다
reset; seed 9 agent-ready hold:policy
run ok policy-kept 9 -
ck "policy-kept issue만: exit 0" "$RC" 0
ck "policy-kept issue만: 이슈 라벨" "$(labels_of 9)" "$(sorted "agent-ready hold:policy needs-human")"
# --reason·--note 는 이 전이에 금지(호출부가 붙였다고 착각하지 않게)
reset; seed 9 agent-ready hold:policy
run ok policy-kept 9 - --reason policy
ck "policy-kept --reason: exit 64" "$RC" 64
reset; seed 9 agent-ready hold:policy
run ok policy-kept 9 - --note q
ck "policy-kept --note: exit 64" "$RC" 64

# ── ⑨ 반송 = 사람 대기 해제 — 재개 스윕(#147 §4)이 쓰는 통로 ──────────────────
# 반송의 remove 칸에서는 `needs-human` 을 **유지한다**(#244) — 사람이 손으로 붙인
# 정지도 반송 때 함께 풀려야 하고, 없는 라벨 제거는 무해하다.
# PR 은 비는 게 아니라 대기 칸 미러 `flow:agent-ready` **하나만** 남는다(#281 — 맨몸 픽스처라
# add 가 실제로 생긴 것이고, 이슈엔 붙지 않는다).
reset; seed 7 flow:verify needs-human hold:ladder
seed 9 flow:verify agent:claimed needs-human hold:ladder
run ok verify-redispatch 9 7
ck "verify-redispatch: exit 0" "$RC" 0
ck "verify-redispatch: PR 사람대기 해제 + 대기 칸 미러" "$(labels_of 7)" "flow:agent-ready"
ck "verify-redispatch: 이슈 = agent-ready" "$(labels_of 9)" "agent-ready"

reset; seed 7 harvesting needs-human hold:policy
seed 9 harvesting flow:ready agent:claimed needs-human hold:policy
run ok closeout-redispatch 9 7
ck "closeout-redispatch: exit 0" "$RC" 0
ck "closeout-redispatch: PR 사람대기 해제 + 대기 칸 미러" "$(labels_of 7)" "flow:agent-ready"
ck "closeout-redispatch: 이슈 = agent-ready" "$(labels_of 9)" "agent-ready"

# ── ⑩ closeout-dup — 중복은 루프가 닫는다(needs-human 을 거치지 않는다) ───────
NOTE="이미 main 에 반영 — abc1234"
dup_seed() {
  reset
  # verifying(#275) 도 심는다 — ① 라벨 제거 목록에 들어야 "PR 라벨 = dup" 단언이 성립한다.
  # flow:agent-ready·flow:claimed(#281) 도 심는다 — 같은 이유(① 제거 목록 단언의 비공허성).
  seed 7 harvesting flow:ci flow:codex flow:verify flow:ready verifying flow:agent-ready flow:claimed
  seed 9 agent-ready agent:claimed harvesting
}

dup_seed
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup: exit 0" "$RC" 0
ck "closeout-dup: PR 라벨 = dup" "$(labels_of 7)" "dup"
# PR close 는 **맨 뒤** — 먼저 닫으면 뒤가 실패했을 때 closeout 이 다시 못 집는다.
ck "closeout-dup: 쓰기 순서(PR close 가 마지막)" "$(mut_order)" \
  "edit 7|pr-comment 7|issue-comment 9|issue-close 9|release-labels 9|pr-close 7"
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
ck "closeout-dup issue=-: PR 만" "$(mut_order)" "edit 7|pr-comment 7|pr-close 7"
check "closeout-dup issue=-: PR 코멘트 본문" \
  "$(grep -q "중복 종료: $NOTE" "$tmp/state/7.prcomment" 2>/dev/null && echo ok || echo no)"

# 멱등 — 이미 CLOSED 면 close 를 건너뛴다(코멘트는 남긴다)
dup_seed
seed_state 7 CLOSED; seed_state 9 CLOSED
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 이미 CLOSED: exit 0" "$RC" 0
ck "closeout-dup 이미 CLOSED: close 미호출(코멘트는 남는다)" "$(mut_order)" \
  "edit 7|pr-comment 7|issue-comment 9|release-labels 9"
check "closeout-dup 이미 CLOSED: PR 근거는 그래도 남는다" \
  "$(grep -q "중복 종료: $NOTE" "$tmp/state/7.prcomment" && echo ok || echo no)"

# 두 번 걸어도 무해 — 두 번째 런은 close 를 건너뛰고 같은 상태로 끝난다
dup_seed
run ok closeout-dup 9 7 --note "$NOTE"
first_dup=$(labels_of 7)
: > "$tmp/mut.log"   # 2회차의 쓰기만 보려고 로그만 비운다(픽스처 상태는 그대로 이어간다)
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 2회차: exit 0" "$RC" 0
ck "closeout-dup 2회차: PR 라벨 동일" "$(labels_of 7)" "$first_dup"
ck "closeout-dup 2회차: close 미호출" "$(mut_order)" \
  "edit 7|pr-comment 7|issue-comment 9|release-labels 9"

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
# ⑤ 만 남기고 ①~④ 는 끝나 있다 — PR 은 열린 채 dup 을 달고 남아 다음 틱이 다시 집는다.
ck "closeout-dup pr close 실패: ①~④ 는 완료" "$(mut_order)" \
  "edit 7|pr-comment 7|issue-comment 9|issue-close 9|release-labels 9|pr-close 7"
ck "closeout-dup pr close 실패: PR 은 열린 채 남는다" "$(cat "$tmp/state/7.state" 2>/dev/null || echo OPEN)" OPEN
ck "closeout-dup pr close 실패: PR 에 dup 은 붙어 있다" "$(labels_of 7)" dup
unset STUB_PRCLOSE_FAIL

# 실패 뒤 같은 전이를 다시 걸면(다음 틱) 완주한다 — ①~④ 는 멱등, ⑤ 만 남았다
: > "$tmp/mut.log"
run ok closeout-dup 9 7 --note "$NOTE"
ck "closeout-dup 재시도: exit 0" "$RC" 0
ck "closeout-dup 재시도: PR CLOSED" "$(cat "$tmp/state/7.state")" CLOSED
ck "closeout-dup 재시도: 이슈 close 는 건너뛴다" "$(mut_order)" \
  "edit 7|pr-comment 7|issue-comment 9|release-labels 9|pr-close 7"

# ④ 라벨 회수 실패는 흐름을 막지 않되(exit 0) 조용히 넘어가지도 않는다
dup_seed
STUB_REL_FAIL=1 run ok closeout-dup 9 7 --note "$NOTE"
ck "release-labels 실패: exit 0(흐름 유지)" "$RC" 0
check "release-labels 실패: stderr 경고 한 줄" \
  "$(grep -q '라벨 회수 실패(best-effort) — 사람 확인' "$tmp/err" && echo ok || echo no)"
ck "release-labels 실패: PR 은 그래도 닫힌다" "$(cat "$tmp/state/7.state")" CLOSED
unset STUB_REL_FAIL

echo "transition: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
