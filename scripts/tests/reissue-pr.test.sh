#!/usr/bin/env bash
# reissue-pr.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# bats 미도입 레포라 resume-sweep.test.sh·reconcile.test.sh 와 같은 순수 bash assert 관행.
#
# 가드하는 것 (#301):
#   ① 정상 재발행 — 새 이슈 본문에 `재발행:` 첫 절·검증자 BLOCKER 절·`Epic` 줄·수용 기준이
#      들어가고, 라벨은 원 이슈에서 상속하되 레인 라벨(agent:claimed·flow:*)은 빠지고
#      `agent-ready` 가 붙는다. 원 이슈는 not planned 로 닫히고 PR 도 닫힌다.
#   ② **쓰기 순서가 안전 계약이다** — 발행 → 확인 → 원 이슈 닫기 → PR 닫기. 새 이슈
#      발행이 실패하면 **아무것도 닫지 않는다**(뒤집히면 원 이슈가 닫히고 새 이슈가 없는
#      유실이 난다). PR 이 마지막인 이유: 원 이슈 닫기가 실패해도 PR 이 열린 채 큐에 남아
#      다음 틱이 같은 PR 로 재진입해 마저 닫는다(①-e).
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
for f in reissue-pr.sh pr-comments.sh jq-unquote.sh block-issue.sh spinoff-inherit.sh; do
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
        lb=$(cat "$STUB_DIR/labels-$num" 2>/dev/null || echo "agent-ready")
        jq -n --argjson n "$num" --arg s "$st" --arg l "$lb" \
          '{number:$n, state:$s, labels: ($l|split(",")|map(select(length>0)|{name:.}))}' ;;
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
    tgt="$3"   # 루프가 shift 하기 전에 잡는다 — 재진입 픽스처가 이 파일을 다음 회차 입력으로 쓴다
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) printf '%s\n' "$2" >> "$STUB_DIR/comments-posted.txt"
                jq -n --arg b "$2" '{body:$b, createdAt:"2026-09-12T00:00:00Z"}' \
                  >> "$STUB_DIR/posted-$tgt.jsonl"; shift 2 ;;
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
    tgt="$3"
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label)
          cur=$(cat "$STUB_DIR/labels-$tgt" 2>/dev/null || echo "")
          case ",$cur," in *",$2,"*) ;; *) printf '%s' "${cur:+$cur,}$2" > "$STUB_DIR/labels-$tgt" ;; esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  "issue list")
    case "$*" in
      *--search*)
        fail_if body-blocked-list
        fx="$STUB_DIR/body-blocked-list.json" ;;
      *)
        fail_if issue-list
        fx="$STUB_DIR/blocked-list.json" ;;
    esac
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
# PR 은 **마지막**이다 — 원 이슈 닫기가 실패해도 PR 이 `verify-eligible`(is:open) 큐에 남아
# 다음 틱이 같은 PR 로 재진입한다(재심 2026-09-12: PR 을 먼저 닫으면 재개 경로가 사라진다).
check "① 순서: 발행 < 확인 < 원이슈닫기 < PR닫기 ($order)" \
  "$([ -n "$c_create" ] && [ -n "$c_conf" ] && [ -n "$c_prclose" ] && [ -n "$c_iclose" ] \
     && [ "$c_create" -lt "$c_conf" ] && [ "$c_conf" -lt "$c_iclose" ] \
     && [ "$c_iclose" -lt "$c_prclose" ] && echo ok || echo no)"

echo "── ①-e 원 이슈 닫기 실패 → 같은 PR 로 재진입 → 발행 없이 마저 닫힌다 ──"
# 1회차: 발행·확인·마커까지 성공, 원 이슈 닫기에서 죽는다. PR 은 아직 열려 있어야 한다.
setup
touch "$tmp/state/fail-issue-close"
run "$REPO" "$PR" "$OLD"
check "①-e 1회차 exit 비0"              "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_in "①-e 1회차 발행했다"             "$STUB_LOG" "issue create"
want_in "①-e 1회차 마커 코멘트"          "$tmp/state/comments-posted.txt" "<!-- reissued: #900 -->"
want_not_in "①-e 1회차 PR 은 열린 채다(큐 잔류)" "$STUB_LOG" "pr close"
# 2회차: 1회차가 남긴 코멘트(마커)를 그대로 읽는다. 원 이슈는 아직 OPEN.
rm -f "$tmp/state/fail-issue-close"
jq -s '.' "$tmp/state/posted-$OLD.jsonl" > "$tmp/state/comments-$OLD.json"
: > "$STUB_LOG"
rm -f "$tmp/state/created-body.md"
run "$REPO" "$PR" "$OLD"
check "①-e 2회차 exit 0"                "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_not_in "①-e 2회차 새 이슈를 또 내지 않는다" "$STUB_LOG" "issue create"
want_in "①-e 2회차 확인을 다시 지난다"    "$STUB_LOG" "issue view $NEW "
want_in "①-e 2회차 원 이슈 닫힘"          "$STUB_LOG" "issue close 10"
want_in "①-e 2회차 PR 닫힘"               "$STUB_LOG" "pr close 55"
want_in "①-e 2회차 보고 한 줄"            "$tmp/state/out.txt" "재발행: #10 → #900"

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

echo "── ①-d 상속은 spinoff-inherit.sh(#261) 한 자리 — P 없는 부모는 P2, 소문자 epic 줄도 Epic #N ──"
# 이슈 본문의 상속 규칙("`spinoff-inherit.sh` #261 이 있으면 그것으로") — 손으로 옮긴 규칙은
# 그 헬퍼와 두 자리에서 갈린다: P 라벨이 없는 부모(헬퍼는 P2 기본값, 손 규칙은 무라벨) ·
# `epic #N` 소문자·들여쓴 줄(헬퍼의 EPIC_RE 는 대소문자 무시, 손 규칙 `^Epic #` 은 못 본다).
setup 2
jq -n --argjson n "$OLD" --arg b "  epic #77

## 수용 기준

- [ ] 가드 A" \
  '{number:$n, title:"P 없는 부모", body:$b, state:"OPEN",
    labels:[{name:"difficulty:easy"},{name:"agent:claimed"}]}' > "$tmp/state/issue-$OLD.json"
run "$REPO" "$PR" "$OLD"
check "①-d exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "①-d P 없는 부모 → P2 기본값(헬퍼 규칙)" "$tmp/state/created-labels.txt" "P2"
want_in "①-d 소문자 epic 줄도 Epic #N 으로 정규화" "$tmp/state/created-body.md" "Epic #77"
want_in "①-d spinoff-inherit 를 실제로 불렀다"    "$STUB_LOG" "issue view $OLD --repo $REPO --json body,labels"

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

echo "── ④-d 실사용 문형(2026-09-12 #283·#244) — 머리말·굵게 표시 뒤의 문형도 같은 신호 ──"
# 사람이 실제로 적은 줄은 줄 머리가 아니라 `사람 결정: **ⓐ — ` 뒤에 문형이 오고, 범위 문장은
# `**` 로 닫힌 뒤 같은 줄에 한 문장이 더 붙는다. 문서가 규정한 문형과 파서가 읽는 형태가
# 갈리면 규칙이 없는 것과 같다(#318 반송 ⑶) — 문형 문자열은 그대로 두고 앞자리만 넓힌다.
setup 2
issue_comments '[{"body":"사람 결정: **ⓐ — 회차 허용: +1 — 범위: 17:23 검증자 리뷰의 fail-open 2칸(같은 줄 면책 · 헤더+불릿)만.** 그 외 수정 금지.\n\n근거: 새는 칸 2개를 남긴 채 닫지 않는다.\n\n기계 표현: PR #295 본문 `<!-- verify-attempt: 2 -->` → `1`. **이 회차도 BLOCKER 면 #301 규칙대로 재발행**.","created_at":"2026-09-12T04:22:31Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
check "④-d exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "④-d granted"                          "$tmp/state/out.txt" "granted"
want_in "④-d 범위 = 문형 뒤 줄 끝까지(굵게 표시 제거)" "$tmp/state/out.txt" "범위: 17:23 검증자 리뷰의 fail-open 2칸(같은 줄 면책 · 헤더+불릿)만. 그 외 수정 금지."
want_not_in "④-d 범위에 ** 가 남지 않는다"       "$tmp/state/out.txt" "**"
want_in "④-d 마커 코멘트"                       "$tmp/state/comments-posted.txt" "<!-- round-granted -->"
want_in "④-d verify-attempt = LIMIT-1"          "$tmp/state/pr-body-new.md" "<!-- verify-attempt: 2 -->"
want_not_in "④-d 어긋난 문형 warn 이 뜨지 않는다" "$tmp/state/err.txt" "문형이 어긋난"

echo "── ④-e 대조군: 따옴표·등호 바로 뒤의 문형은 인용이다(스크립트 줄을 붙여넣은 경우) ──"
setup 2
issue_comments '[{"body":"형식은 '"'"'회차 허용: +1 — 범위: <한 줄>'"'"' 이고 GRANT_PHRASE=\"회차 허용: +1 — 범위: x\" 다","created_at":"2026-09-12T04:22:31Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "④-e none"   "$tmp/state/out.txt" "none"
want_not_in "④-e 무쓰기" "$STUB_LOG" "issue comment"

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

echo "── ⑨-b 멱등 재진입도 **확인**을 지난다 (레인 밖 새 이슈를 두고 닫지 않는다) ──"
setup 2
issue_comments '[{"body":"재발행: #10 → #900 (attempt 상한)\n<!-- reissued: #900 -->\n<!-- bodat:worker -->","created_at":"2026-09-11T05:00:00Z"}]'
printf 'P1' > "$tmp/state/labels-$NEW"        # 앞 회차가 agent-ready 부착에서 멈춘 상태
touch "$tmp/state/fail-issue-edit"            # 이번에도 부착이 실패한다
run "$REPO" "$PR" "$OLD"
check "⑨-b exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_in "⑨-b 사유가 stderr 에"        "$tmp/state/err.txt" "agent-ready"
want_not_in "⑨-b PR 을 닫지 않았다"     "$STUB_LOG" "pr close"
want_not_in "⑨-b 원 이슈를 닫지 않았다" "$STUB_LOG" "issue close"

echo "── ⑨-c 재진입이 레인을 복구하면 닫기를 마저 한다 ──────────────────"
setup 2
issue_comments '[{"body":"재발행: #10 → #900 (attempt 상한)\n<!-- reissued: #900 -->\n<!-- bodat:worker -->","created_at":"2026-09-11T05:00:00Z"}]'
printf 'P1' > "$tmp/state/labels-$NEW"
run "$REPO" "$PR" "$OLD"
check "⑨-c exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "⑨-c agent-ready 를 붙였다" "$STUB_LOG" "issue edit 900 --repo owner/repo --add-label agent-ready"
want_in "⑨-c PR 닫힘"               "$STUB_LOG" "pr close 55"
want_in "⑨-c 원 이슈 닫힘"          "$STUB_LOG" "issue close 10"

echo "── ③-c 본문 'Blocked by #구' 도 새 번호로 잇는다 (라벨만 보면 조기 해제) ──"
setup
echo '[{"number":88,"body":"Blocked by #10 — 앞 건이 먼저"}]' > "$tmp/state/body-blocked-list.json"
run "$REPO" "$PR" "$OLD"
check "③-c exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "③-c 새 번호 라벨로 막힘을 이었다" "$STUB_LOG" "issue edit 88 --repo owner/repo --add-label blocked-by:900"
want_in "③-c 낡은 본문 줄을 warn 으로 알린다" "$tmp/state/err.txt" "본문 'Blocked by #10' 줄은 낡았다"

echo "── ③-d 본문 블로커 조회 실패 → 원 이슈를 닫지 않는다 ──────────────"
setup
touch "$tmp/state/fail-body-blocked-list"
run "$REPO" "$PR" "$OLD"
check "③-d exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "③-d 원 이슈를 닫지 않았다" "$STUB_LOG" "issue close"

echo "── ①-b 검증자 코멘트 부재 → 발행은 하되 조용히 넘기지 않는다 ──────"
setup
printf '%s' '[{"body":"재검증 실패: #10 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->","created_at":"2026-09-11T01:00:00Z"}]' > "$tmp/state/comments-$PR.json"
run "$REPO" "$PR" "$OLD"
check "①-b exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "①-b warn 이 stderr 에" "$tmp/state/err.txt" "검증자 리뷰"
want_in "①-b 본문에 자리표시자"  "$tmp/state/created-body.md" "코멘트를 직접 읽어라"

echo "── ①-c 판정 줄이 코멘트 **중간**이어도 싣는다 (머리 매칭 함정) ─────"
setup
jq -n '[{body:"자동 보고 머리말\n검증자 리뷰: BLOCKER 1 / WARN 0건 · gpt-5/90s\n[P1] scripts/mid.sh:7 — 중간 줄 판정\n<!-- bodat:worker -->", created_at:"2026-09-11T02:00:00Z"}]' > "$tmp/state/comments-$PR.json"
run "$REPO" "$PR" "$OLD"
want_in "①-c 중간 줄 검증자 지적도 새 본문에" "$tmp/state/created-body.md" "[P1] scripts/mid.sh:7 — 중간 줄 판정"

echo "── ②-c 멱등 마커 코멘트 실패 → 닫기는 계속(중복 발행 창을 줄인다) ──"
setup
touch "$tmp/state/fail-issue-comment"
run "$REPO" "$PR" "$OLD"
check "②-c exit 0" "$([ "$(rc)" = 0 ] && echo ok || echo no)"
want_in "②-c warn 이 stderr 에" "$tmp/state/err.txt" "재발행 마커 코멘트 실패"
want_in "②-c PR 닫힘"           "$STUB_LOG" "pr close 55"
want_in "②-c 원 이슈 닫힘"      "$STUB_LOG" "issue close 10"

echo "── ④-c 이미 적용된 허용은 매 틱 warn 을 쌓지 않는다 (조용한 none) ──"
setup 2
issue_comments '[{"body":"회차 허용: +1 — 범위: 첫 번째","created_at":"2026-09-11T03:00:00Z"},
 {"body":"회차 허용 접수: attempt 을 2 로 되돌린다 — 범위: 첫 번째\n<!-- round-granted -->\n<!-- bodat:worker -->","created_at":"2026-09-11T03:10:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "④-c none"                 "$tmp/state/out.txt" "none"
want_not_in "④-c warn 을 안 쌓는다" "$tmp/state/err.txt" "warn"
want_not_in "④-c 무쓰기"            "$STUB_LOG" "issue comment"

echo "── ⑤-b 문형이 어긋나면(하이픈·빈 범위) 조용히 흘리지 않고 warn ────"
setup 2
issue_comments '[{"body":"회차 허용: +1 - 범위: 하이픈으로 적었다","created_at":"2026-09-11T03:00:00Z"}]'
run grant-round "$REPO" "$PR" "$OLD"
want_in "⑤-b none"          "$tmp/state/out.txt" "none"
want_in "⑤-b 어긋난 문형 warn" "$tmp/state/err.txt" "문형이 어긋난"

echo "── ⑦-b jq 판정 실패는 '문형 없음'으로 둔갑하지 않는다 ─────────────"
setup 2
printf '%s' '[{"body":42}]' > "$tmp/state/comments-$OLD.json"
run grant-round "$REPO" "$PR" "$OLD"
check "⑦-b exit 비0" "$([ "$(rc)" != 0 ] && echo ok || echo no)"
want_not_in "⑦-b 무쓰기" "$STUB_LOG" "issue comment"

echo "── ⑩ 사용법·인자 검증 ─────────────────────────────────────────────"
setup
run "$REPO" "$PR"
check "⑩ 인자 부족 exit 64" "$([ "$(rc)" = 64 ] && echo ok || echo no)"
setup
run "$REPO" "$PR" "열"
check "⑩ 이슈 번호가 숫자가 아니면 exit 64" "$([ "$(rc)" = 64 ] && echo ok || echo no)"

echo "reissue-pr: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
