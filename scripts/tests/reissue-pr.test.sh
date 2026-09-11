#!/usr/bin/env bash
# reissue-pr.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 resume-sweep.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것 (#301):
#   ① 정상 재발행 — 새 이슈 본문에 `재발행:` 첫 절·검증자 BLOCKER 절·`Epic` 줄·수용 기준이
#      들어가고, 라벨은 원 이슈에서 상속하되 레인 라벨(agent:claimed·flow:*)은 빠지고
#      `agent-ready` 가 붙는다. 원 이슈는 not planned 로 닫히고 PR 도 닫힌다.
#   ② **쓰기 순서가 안전 계약이다** — 발행 → 확인 → PR 닫기 → 원 이슈 닫기. 새 이슈
#      발행이 실패하면 **아무것도 닫지 않는다**(뒤집히면 원 이슈가 닫히고 새 이슈가 없는
#      유실이 난다).
#   ③ `blocked-by:<구>` 라벨을 단 이슈는 새 번호로 옮긴다(옮기기 전엔 원 이슈를 안 닫는다 —
#      닫힌 블로커는 eligible 게이트가 해제로 읽어 하위가 조기 풀린다).
#   ④ `회차 허용: +1 — 범위: <한 줄>` 1회 → PR 본문 verify-attempt 를 LIMIT-1 로 갱신 +
#      `<!-- round-granted -->` 마커 코멘트.
#   ⑤ 2회(마커가 이미 있음) → 무시 + warn. 예외는 이슈당 한 번.
#   ⑥ **인용은 신호가 아니다** — 코드펜스·인라인 백틱 안의 문형, 그리고 이 기능의 **자기
#      문서**(SKILL.md·README)를 통째로 붙여넣은 코멘트도 판정에 안 걸린다.
#   ⑦ 조회 실패는 "없음"으로 위장되지 않는다 — fail-closed(아무것도 안 닫고/안 쓰고 비0).
#   ⑧ 살아있는 회차 허용은 재발행에 밟히지 않는다(exit 65, 무쓰기).
#   ⑨ 멱등 — `<!-- reissued: #N -->` 마커가 있으면 새 이슈를 또 만들지 않는다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name"
  fi
}
want_in() {  # want_in <name> <파일> <문자열>
  check "$1" "$(grep -qF -- "$3" "$2" && echo ok || echo no)"
}
want_not_in() {
  check "$1" "$(grep -qF -- "$3" "$2" && echo no || echo ok)"
}

REPO="owner/repo"
OLD=10
PR=55
NEW=900

# ── SUT 사본 + 형제 헬퍼 ───────────────────────────────────────────────────
sut="$tmp/scripts"
mkdir -p "$sut" "$tmp/bin"
for f in reissue-pr.sh pr-comments.sh jq-unquote.sh block-issue.sh; do
  cp "$DIR/$f" "$sut/$f"
done
mkdir -p "$sut/../skills/verify-runner/references"
cp "$DIR/../skills/verify-runner/references/reissue.md" "$sut/../skills/verify-runner/references/reissue.md"
chmod +x "$sut"/*.sh
export PATH="$tmp/bin:$PATH"

# ── gh 스텁 — 조회는 픽스처 파일, 쓰기는 로그(+본문 파일 캡처) ─────────────
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"

fail_if() { [ ! -f "$STUB_DIR/fail-$1" ] || { echo "gh: $1 boom" >&2; exit 1; }; }

case "${1:-} ${2:-}" in
  "api "*|"api")
    fail_if api
    url="$2"
    num=$(printf '%s' "$url" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    fail_if "comments-$num"
    fx="$STUB_DIR/comments-$num.json"
    [ -f "$fx" ] || fx="$STUB_DIR/empty.json"
    jqf=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--jq" ] && { jqf="$2"; break; }
      shift
    done
    if [ -n "$jqf" ]; then jq -c "$jqf" "$fx"; else cat "$fx"; fi
    exit 0 ;;
  "issue view")
    fail_if issue-view
    num="$3"
    case "$*" in
      *"--json number,state"*)
        st=$(cat "$STUB_DIR/state-$num" 2>/dev/null || echo OPEN)
        [ "$st" = "__FAIL__" ] && exit 1
        jq -n --argjson n "$num" --arg s "$st" '{number:$n, state:$s}' ;;
      *)
        fx="$STUB_DIR/issue-$num.json"
        [ -f "$fx" ] || exit 1
        cat "$fx" ;;
    esac
    exit 0 ;;
  "pr view")
    fail_if pr-view
    cat "$STUB_DIR/pr-$3.json"
    exit 0 ;;
  "issue create")
    fail_if create
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) cp "$2" "$STUB_DIR/created-body.md"; shift 2 ;;
        --title) printf '%s\n' "$2" > "$STUB_DIR/created-title.txt"; shift 2 ;;
        --label) printf '%s\n' "$2" >> "$STUB_DIR/created-labels.txt"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "https://github.com/owner/repo/issues/$(cat "$STUB_DIR/new-number")"
    exit 0 ;;
  "issue comment")
    fail_if issue-comment
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) printf '%s\n' "$2" >> "$STUB_DIR/comments-posted.txt"
                jq -n --arg b "$2" '{body:$b, created_at:"2026-09-12T00:00:00Z"}' \
                  >> "$STUB_DIR/posted-$3.jsonl"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  "pr edit")
    fail_if pr-edit
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) cp "$2" "$STUB_DIR/pr-body-new.md"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  "pr close")
    fail_if pr-close
    exit 0 ;;
  "issue close")
    fail_if issue-close
    exit 0 ;;
  "issue edit")
    fail_if issue-edit
    exit 0 ;;
  "issue list")
    fail_if issue-list
    fx="$STUB_DIR/blocked-list.json"
    [ -f "$fx" ] || fx="$STUB_DIR/empty.json"
    cat "$fx"
    exit 0 ;;
  "label create")
    exit 0 ;;
esac
echo "gh: 스텁이 모르는 호출: $*" >&2
exit 90
STUB
chmod +x "$tmp/bin/gh"

export STUB_DIR="$tmp/state"
export STUB_LOG="$tmp/state/log.txt"

ISSUE_BODY='Epic #42

## 배경
원래 배경 한 줄.

## 수용 기준

- [ ] 가드 A 를 세운다
- [ ] 가드 B 를 세운다

## Test plan

```
bash scripts/tests/foo.test.sh
```
'

VERIFIER_BODY='검증자 리뷰: BLOCKER 2 / WARN 1건 · gpt-5/120s
[P1] scripts/foo.sh:12 — 조용한 폴백이 실패를 삼킨다
[P1] scripts/foo.sh:40 — 가드가 옛 문면에서도 참이다
[P2] scripts/foo.sh:77 — 주석이 실측과 반대
<!-- bodat:worker -->'

setup() {  # setup [<verify-attempt 값>]
  local attempt="${1:-2}"
  rm -rf "$tmp/state"
  mkdir -p "$tmp/state"
  : > "$STUB_LOG"
  echo '[]' > "$tmp/state/empty.json"
  echo "$NEW" > "$tmp/state/new-number"
  jq -n --argjson n "$OLD" --arg b "$ISSUE_BODY" \
    '{number:$n, title:"조립기 2FA 블록", body:$b, state:"OPEN",
      labels:[{name:"P1"},{name:"difficulty:easy"},{name:"agent:claimed"},
              {name:"flow:verify"},{name:"blocked-by:7"}]}' > "$tmp/state/issue-$OLD.json"
  jq -n --argjson n "$PR" --arg b "PR 본문
<!-- verify-attempt: $attempt -->" \
    '{number:$n, state:"OPEN", headRefName:"agent/issue-10",
      headRefOid:"abc1234567890abc1234567890abc1234567890a", body:$b}' > "$tmp/state/pr-$PR.json"
  jq -n --arg v "$VERIFIER_BODY" \
    '[{body:"재검증 실패: #10 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->", created_at:"2026-09-11T01:00:00Z"},
      {body:$v, created_at:"2026-09-11T02:00:00Z"}]' > "$tmp/state/comments-$PR.json"
  echo '[]' > "$tmp/state/comments-$OLD.json"
}

issue_comments() {  # issue_comments <json 배열 문자열>
  printf '%s' "$1" > "$tmp/state/comments-$OLD.json"
}

run() {  # run <인자...> — stdout/stderr/exit 를 파일로
  "$sut/reissue-pr.sh" "$@" > "$tmp/state/out.txt" 2> "$tmp/state/err.txt"
  echo $? > "$tmp/state/rc.txt"
}
rc() { cat "$tmp/state/rc.txt"; }

echo "── ① 정상 재발행 ──────────────────────────────────────────────────"
setup
run "$REPO" "$PR" "$OLD"
check "① exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "① 새 본문: 재발행 첫 절"        "$tmp/state/created-body.md" "재발행: PR #55 ← #10"
want_in "① 새 본문: Epic 줄 상속"        "$tmp/state/created-body.md" "Epic #42"
want_in "① 새 본문: 수용 기준 원문"      "$tmp/state/created-body.md" "가드 A 를 세운다"
want_in "① 새 본문: 검증자 BLOCKER 절"   "$tmp/state/created-body.md" "[P1] scripts/foo.sh:12 — 조용한 폴백이 실패를 삼킨다"
want_in "① 새 본문: 브랜치·head SHA"     "$tmp/state/created-body.md" "agent/issue-10"
want_in "① 새 본문: head SHA"            "$tmp/state/created-body.md" "abc1234567890abc1234567890abc1234567890a"
want_in "① 새 본문: 이어받지 않는다"     "$tmp/state/created-body.md" "그대로 이어받지 않는다"
want_in "① 라벨: agent-ready"            "$tmp/state/created-labels.txt" "agent-ready"
want_in "① 라벨: P 상속"                 "$tmp/state/created-labels.txt" "P1"
want_in "① 라벨: 레포 규약 라벨 상속"    "$tmp/state/created-labels.txt" "difficulty:easy"
want_not_in "① 라벨: agent:claimed 제외" "$tmp/state/created-labels.txt" "agent:claimed"
want_not_in "① 라벨: flow:* 제외"        "$tmp/state/created-labels.txt" "flow:verify"
want_not_in "① 라벨: spinoff 안 붙인다"  "$tmp/state/created-labels.txt" "spinoff"
want_in "① PR 닫힘"                      "$STUB_LOG" "pr close 55"
want_in "① 원 이슈 닫힘(not planned)"    "$STUB_LOG" "issue close 10"
check "① 원 이슈 close 에 not planned" \
  "$(grep -F 'issue close 10' "$STUB_LOG" | grep -qF 'not planned' && echo ok || echo no)"
want_in "① 재발행 마커 코멘트"           "$tmp/state/comments-posted.txt" "<!-- reissued: #900 -->"
want_in "① stdout 보고 한 줄"            "$tmp/state/out.txt" "재발행: #10 → #900"
# 순서 계약: create → confirm → pr close → issue close
order=$(grep -nE '^(issue create|issue view 900|pr close|issue close)' "$STUB_LOG" \
  | sed 's/:.*//' | tr '\n' ' ')
c_create=$(grep -n '^issue create' "$STUB_LOG" | head -1 | cut -d: -f1)
c_conf=$(grep -n "^issue view $NEW " "$STUB_LOG" | head -1 | cut -d: -f1)
c_prclose=$(grep -n '^pr close' "$STUB_LOG" | head -1 | cut -d: -f1)
c_iclose=$(grep -n '^issue close' "$STUB_LOG" | head -1 | cut -d: -f1)
check "① 순서: 발행 < 확인 < PR닫기 < 원이슈닫기 ($order)" \
  "$([ -n "$c_create" ] && [ -n "$c_conf" ] && [ -n "$c_prclose" ] && [ -n "$c_iclose" ] \
     && [ "$c_create" -lt "$c_conf" ] && [ "$c_conf" -lt "$c_prclose" ] \
     && [ "$c_prclose" -lt "$c_iclose" ] && echo ok || echo no)"

echo "── ② 발행 실패 → 아무것도 닫지 않는다 ─────────────────────────────"
setup
touch "$tmp/state/fail-create"
run "$REPO" "$PR" "$OLD"
check "② exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "② PR 을 닫지 않았다"     "$STUB_LOG" "pr close"
want_not_in "② 원 이슈를 닫지 않았다" "$STUB_LOG" "issue close"
want_in "② 사유가 stderr 에"          "$tmp/state/err.txt" "발행 실패"

echo "── ②-b 확인 실패(새 이슈가 OPEN 이 아님) → 아무것도 닫지 않는다 ──"
setup
echo "__FAIL__" > "$tmp/state/state-$NEW"
run "$REPO" "$PR" "$OLD"
check "②-b exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "②-b PR 을 닫지 않았다"     "$STUB_LOG" "pr close"
want_not_in "②-b 원 이슈를 닫지 않았다" "$STUB_LOG" "issue close"

echo "── ③ blocked-by:<구> 이전 ─────────────────────────────────────────"
setup
echo '[{"number":77}]' > "$tmp/state/blocked-list.json"
run "$REPO" "$PR" "$OLD"
check "③ exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "③ 새 번호 부착"  "$STUB_LOG" "issue edit 77 --repo owner/repo --add-label blocked-by:900"
want_in "③ 옛 번호 제거"  "$STUB_LOG" "issue edit 77 --repo owner/repo --remove-label blocked-by:10"
c_move=$(grep -n 'remove-label blocked-by:10' "$STUB_LOG" | head -1 | cut -d: -f1)
c_iclose=$(grep -n '^issue close' "$STUB_LOG" | head -1 | cut -d: -f1)
check "③ 이전이 원 이슈 닫기보다 먼저" \
  "$([ -n "$c_move" ] && [ -n "$c_iclose" ] && [ "$c_move" -lt "$c_iclose" ] && echo ok || echo no)"

echo "── ③-b 이전 실패 → 원 이슈를 닫지 않는다 ──────────────────────────"
setup
echo '[{"number":77}]' > "$tmp/state/blocked-list.json"
touch "$tmp/state/fail-issue-edit"
run "$REPO" "$PR" "$OLD"
check "③-b exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "③-b 원 이슈를 닫지 않았다" "$STUB_LOG" "issue close"

echo "── ④ 회차 허용 1회 → 마커 갱신 ────────────────────────────────────"
setup 2
issue_comments '[{"body":"회차 허용: +1 — 범위: bounce-state 판정만 손대라","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
check "④ exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "④ stdout granted"        "$tmp/state/out.txt" "granted"
want_in "④ 범위 문장을 그대로 실어 보낸다" "$tmp/state/out.txt" "bounce-state 판정만 손대라"
want_in "④ round-granted 마커 코멘트"      "$tmp/state/comments-posted.txt" "<!-- round-granted -->"
want_in "④ 마커 코멘트에 범위 인용"        "$tmp/state/comments-posted.txt" "bounce-state 판정만 손대라"
want_in "④ PR 본문 verify-attempt = LIMIT-1" "$tmp/state/pr-body-new.md" "<!-- verify-attempt: 2 -->"
want_in "④ PR 본문 나머지 보존"              "$tmp/state/pr-body-new.md" "PR 본문"

echo "── ④-b 창 전(attempt 0)엔 회차를 깎지 않는다 ──────────────────────"
setup 0
issue_comments '[{"body":"회차 허용: +1 — 범위: 여기만","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
check "④-b exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "④-b granted"                 "$tmp/state/out.txt" "granted"
want_not_in "④-b attempt 0 은 안 깎는다(PR 본문 미편집)" "$STUB_LOG" "pr edit"

echo "── ⑤ 두 번째 회차 허용 → 무시 + warn ──────────────────────────────"
setup 2
issue_comments '[{"body":"회차 허용: +1 — 범위: 첫 번째","created_at":"2026-09-11T03:00:00Z"},
 {"body":"회차 허용 접수: attempt 을 2 로 되돌린다 — 범위: 첫 번째\n<!-- round-granted -->\n<!-- bodat:worker -->","created_at":"2026-09-11T03:10:00Z"},
 {"body":"회차 허용: +1 — 범위: 두 번째","created_at":"2026-09-11T04:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
check "⑤ exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "⑤ stdout ignored"   "$tmp/state/out.txt" "ignored"
want_in "⑤ warn 이 stderr 에" "$tmp/state/err.txt" "warn"
want_not_in "⑤ 두 번째는 아무것도 안 쓴다(코멘트)" "$STUB_LOG" "issue comment"
want_not_in "⑤ 두 번째는 아무것도 안 쓴다(PR 본문)" "$STUB_LOG" "pr edit"

echo "── ⑥ 인용된 문형은 신호가 아니다 ──────────────────────────────────"
setup 2
issue_comments '[{"body":"이럴 땐 `회차 허용: +1 — 범위: 이렇게` 라고 적으면 된다","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "⑥ 인라인 백틱: none" "$tmp/state/out.txt" "none"
want_not_in "⑥ 인라인 백틱: 무쓰기" "$STUB_LOG" "issue comment"

setup 2
issue_comments '[{"body":"예시는 아래와 같다\n\n```\n회차 허용: +1 — 범위: 이렇게\n```\n","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "⑥ 코드펜스: none" "$tmp/state/out.txt" "none"
want_not_in "⑥ 코드펜스: 무쓰기" "$STUB_LOG" "issue comment"

echo "── ⑥-d 대조군: 인용을 **더** 지우면 안 된다(닫힌 펜스 뒤 맨몸 문형은 신호) ──"
setup 2
issue_comments '[{"body":"예시는 이렇다\n\n```\n예시 줄\n```\n\n회차 허용: +1 — 범위: 진짜 지시다","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "⑥-d 펜스 뒤 맨몸 문형은 센다" "$tmp/state/out.txt" "진짜 지시다"

echo "── ⑥-b 자기 문서를 통째로 붙여도 판정에 안 걸린다 ─────────────────"
for doc in "$DIR/../skills/verify-runner/SKILL.md" "$DIR/../README.md" "$DIR/../README.ko.md" \
           "$DIR/../skills/verify-runner/references/reissue.md" "$DIR/reissue-pr.sh"; do
  setup 2
  jq -n --rawfile b "$doc" '[{body:$b, created_at:"2026-09-11T03:00:00Z"}]' \
    > "$tmp/state/comments-$OLD.json"
  run grant-round "$REPO" "$PR" "$OLD"
  check "⑥-b $(basename "$doc") 를 코멘트로 붙여도 none" \
    "$(grep -qF 'none' "$tmp/state/out.txt" && echo ok || echo no)"
done

echo "── ⑥-c 머신 코멘트의 문형은 사람 신호가 아니다 ────────────────────"
setup 2
issue_comments '[{"body":"회차 허용: +1 — 범위: 기계가 적었다\n<!-- bodat:worker -->","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "⑥-c 머신 코멘트: none" "$tmp/state/out.txt" "none"

echo "── ⑦ 조회 실패는 fail-closed ──────────────────────────────────────"
setup 2
touch "$tmp/state/fail-comments-$OLD"
run grant-round "$REPO" "$PR" "$OLD"
check "⑦ grant 조회 실패 exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "⑦ grant 조회 실패 무쓰기" "$STUB_LOG" "issue comment"

setup 2
touch "$tmp/state/fail-comments-$PR"
run "$REPO" "$PR" "$OLD"
check "⑦ 재발행 코멘트 조회 실패 exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "⑦ 재발행 조회 실패: 발행 안 함" "$STUB_LOG" "issue create"
want_not_in "⑦ 재발행 조회 실패: 안 닫음"   "$STUB_LOG" "issue close"

echo "── ⑧ 살아있는 회차 허용은 재발행에 밟히지 않는다 ──────────────────"
setup 2
issue_comments '[{"body":"회차 허용: +1 — 범위: 첫 번째","created_at":"2026-09-11T03:00:00Z"},
 {"body":"회차 허용 접수: attempt 을 2 로 되돌린다 — 범위: 첫 번째\n<!-- round-granted -->\n<!-- bodat:worker -->","created_at":"2026-09-11T03:10:00Z"}]'
run "$REPO" "$PR" "$OLD"
check "⑧ exit 65" "$([ "$(rc)" = 65 ] && echo ok || echo no)"
want_in "⑧ stdout grant-live + 범위" "$tmp/state/out.txt" "첫 번째"
want_not_in "⑧ 발행 안 함" "$STUB_LOG" "issue create"
want_not_in "⑧ 안 닫음"   "$STUB_LOG" "issue close"

echo "── ⑧-b 소진된 회차 허용(attempt≥LIMIT)은 재발행을 막지 않는다 ─────"
setup 3
issue_comments '[{"body":"회차 허용: +1 — 범위: 첫 번째","created_at":"2026-09-11T03:00:00Z"},
 {"body":"회차 허용 접수: attempt 을 2 로 되돌린다 — 범위: 첫 번째\n<!-- round-granted -->\n<!-- bodat:worker -->","created_at":"2026-09-11T03:10:00Z"}]'
run "$REPO" "$PR" "$OLD"
check "⑧-b exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "⑧-b 재발행했다" "$STUB_LOG" "issue create"

echo "── ⑨ 멱등 — 이미 재발행된 이슈는 다시 발행하지 않는다 ─────────────"
setup 2
issue_comments '[{"body":"재발행: #10 → #900 (attempt 상한)\n<!-- reissued: #900 -->\n<!-- bodat:worker -->","created_at":"2026-09-11T05:00:00Z"}]'
run "$REPO" "$PR" "$OLD"
check "⑨ exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_not_in "⑨ 새 이슈를 또 만들지 않는다" "$STUB_LOG" "issue create"
want_in "⑨ 닫기는 마저 한다(PR)"          "$STUB_LOG" "pr close 55"
want_in "⑨ 닫기는 마저 한다(원 이슈)"      "$STUB_LOG" "issue close 10"

echo "── ⑩ 사용법·인자 검증 ─────────────────────────────────────────────"
setup
run "$REPO" "$PR"
check "⑩ 인자 부족 exit 64" "$([ "$(rc)" = 64 ] && echo ok || echo no)"
setup
run "$REPO" "$PR" "열"
check "⑩ 이슈 번호가 숫자가 아니면 exit 64" "$([ "$(rc)" = 64 ] && echo ok || echo no)"

echo "reissue-pr: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
