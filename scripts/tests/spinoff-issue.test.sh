#!/usr/bin/env bash
# spinoff-issue.sh 픽스처 테스트 — 네트워크 무접속(gh 는 PATH 스텁), 기대값은 손으로.
#
# #447: closeout 6단계(와 5단계 fail 갈래)의 파생 발행이 산문 다섯 문단 대신 스크립트 한 줄이
# 되도록 묶은 절차의 SSOT 테스트다. 무는 것:
#   ⑴ 상속(`Epic #N` 첫 줄 · P 라벨)이 실제로 본문·라벨에 실린다(#261)
#   ⑵ 단발 부모면 `<EPIC_LINE>` 이 빈 줄이 되고 마커가 `Epic #없음` 이다
#   ⑶ 부모 미상(`-`)은 **발행조차 하지 않는다** — exit 1, gh 호출 0회(상속 없이 발행 금지)
#   ⑷ 라벨 부재는 `setup-labels.sh` 1회 + 재시도 1회로 복구된다
#   ⑸ 재시도도 실패하면 **무라벨로라도 이슈는 만든다**(발행 유실 방지) + exit 2 +
#      그 건은 라벨 readback 을 **하지 않는다**(#223) + PR 마커는 그래도 남는다
#   ⑹ 발행 자체 실패는 exit 1·무출력(빈 번호를 정상값으로 흘리지 않는다)
#   ⑺ readback 에서 라벨이 빠졌으면 `--add-label` 로 보강한다
#   ⑪ 출처 줄 `Spinoff of PR #<pr> (issue #<부모>)` 가 **둘째 줄**에 실린다 — 슬롯이 있으면 치환,
#      없으면 끼워 넣는다(#411)
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/spinoff-issue.sh"

command -v jq >/dev/null 2>&1 || { echo "  ✗ jq 미설치 — 이 테스트는 jq 를 요구한다"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"

# gh 스텁 — 호출을 전부 기록하고, 기대 밖 호출은 exit 1 로 드러낸다.
#   SO_CREATE=ok|labelfail|labelfail2|allfail 로 `issue create` 거동을 고른다.
#     labelfail  — 1회차만 라벨 not found (setup-labels 뒤 재시도는 성공)
#     labelfail2 — 라벨 붙은 create 는 **매번** 실패(무라벨 폴백 경로)
#     allfail    — 라벨과 무관한 실패(발행 자체가 안 된다)
#   SO_READBACK=<json> 로 발행 직후 readback 응답을 고른다.
cat > "$tmp/stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SO_CALLS"
case "$*" in
  *"issue view"*"--json body,labels"*)            # 부모 조회(spinoff-inherit)
    cat "$SO_PARENT"; exit 0 ;;
  *"issue view"*"--json labels,body"*)            # 발행 직후 readback
    if [ "${SO_VIEW2_FAIL:-0}" = 1 ] && [ "$(grep -c -- "--json labels,body" "$SO_CALLS")" -gt 1 ]; then exit 1; fi
    healthy='{"labels":[{"name":"agent-ready"},{"name":"spinoff"},{"name":"P1"},{"name":"P0"}],"body":"Epic #4962\n\n## 배경"}'
    # 보강(`issue edit`)이 이미 한 번 있었으면 그 뒤 재조회는 정상값을 돌려준다(실 gh 처럼).
    if grep -q "issue edit" "$SO_CALLS" && [ "$(grep -c "issue view" "$SO_CALLS")" -gt 1 ]; then
      printf '%s' "$healthy"
    else
      printf '%s' "${SO_READBACK:-$healthy}"
    fi
    exit 0 ;;
  *"issue create"*)
    n=$(grep -c 'issue create' "$SO_CALLS")
    # 렌더된 본문을 잡아 둔다(임시 파일이라 호출 뒤엔 사라진다) — 출처 줄 단언용(#411)
    if [ -n "${SO_BODY_OUT:-}" ]; then
      prev=; for a in "$@"; do [ "$prev" = "--body-file" ] && cp "$a" "$SO_BODY_OUT"; prev=$a; done
    fi
    case "${SO_CREATE:-ok}" in
      labelfail)  [ "$n" = 1 ] && { echo "could not add label: 'spinoff' not found" >&2; exit 1; } ;;
      labelfail2) case "$*" in *--label*) echo "could not add label: 'spinoff' not found" >&2; exit 1 ;; esac ;;
      allfail)    echo "HTTP 502" >&2; exit 1 ;;
    esac
    echo "https://github.com/ggqgga/BodaT/issues/${SO_NEW:-501}"; exit 0 ;;
  *"issue edit"*)  exit "${SO_EDIT_RC:-0}" ;;
  *"pr comment"*)  exit 0 ;;
  *"label create"*|*"repo edit"*) exit 0 ;;        # setup-labels.sh 경유
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/stub/gh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

cat > "$tmp/body.md" <<'EOF'
<EPIC_LINE>
<ORIGIN_LINE>

## 배경
파생 사유.
EOF

# mkparent <body> <label-csv>
mkparent() {
  labels=$(printf '%s' "$2" | jq -Rs 'split(",") | map(select(. != "")) | map({name: .})')
  jq -n --arg b "$1" --argjson l "$labels" '{body: $b, labels: $l}' > "$tmp/parent.json"
}

# run <parent> [부모PR] [본문파일] — OUT/ERR/RC/CALLS 를 채운다.
run() {
  : > "$tmp/calls.log"; rm -f "$tmp/sent-body.md"
  OUT=$(SO_CALLS="$tmp/calls.log" SO_PARENT="$tmp/parent.json" SO_BODY_OUT="$tmp/sent-body.md" \
        PATH="$tmp/stub:$PATH" \
        bash "$SUT" ggqgga/BodaT "$1" "${2:-77}" \
        --title "파생 제목" --body-file "${3:-$tmp/body.md}" 2>"$tmp/err.log")
  RC=$?
  ERR=$(cat "$tmp/err.log")
  CALLS=$(cat "$tmp/calls.log")
}

echo "── 발행 격자 ─────────────────────────────────────────────────────"

# ① 에픽 있는 부모 — Epic 첫 줄 · P1 · 세 라벨 · 마커
mkparent $'Epic #4962\n\n## 배경\n어쩌고.' 'P1,difficulty:easy'
run 4979
[ "$RC" = 0 ] && [ "$OUT" = "501" ] && ok || bad "① rc=$RC out=[$OUT] err=[$ERR]"
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label agent-ready --label spinoff --label P1' \
  && ok || bad "① 세 라벨이 create 에 없다: $(printf '%s\n' "$CALLS" | grep 'issue create')"
printf '%s\n' "$CALLS" | grep -qF -- 'pr comment 77 --repo ggqgga/BodaT --body 파생: #501 (Epic #4962 · P1)' \
  && ok || bad "① PR 마커 형태가 다르다: $(printf '%s\n' "$CALLS" | grep 'pr comment')"
head -1 "$tmp/body.md" | grep -qF '<EPIC_LINE>' && ok || bad "① 원본 본문 파일을 건드렸다(읽기 전용이어야)"
printf '%s\n' "$CALLS" | grep -q 'issue edit' && bad "① 정상 발행인데 보강 edit 를 불렀다(불필요한 쓰기)" || ok

# ② 단발 부모 — `<EPIC_LINE>` 은 빈 줄, 마커는 `Epic #없음`
mkparent $'## 배경\n에픽 줄 없는 단발.' 'difficulty:medium'
run 4979
[ "$RC" = 0 ] && ok || bad "② rc=$RC err=[$ERR]"
printf '%s\n' "$CALLS" | grep -qF -- '--body 파생: #501 (Epic #없음 · P1)' \
  && ok || bad "② 단발 마커 형태가 다르다: $(printf '%s\n' "$CALLS" | grep 'pr comment')"

# ③ 부모 미상(`-`) — 발행조차 하지 않는다(gh 호출 0회, 무출력)
run -
{ [ "$RC" = 1 ] && [ -z "$OUT" ] && [ -z "$CALLS" ]; } && ok \
  || bad "③ 부모 미상 rc=$RC out=[$OUT] calls=[$CALLS] (기대 rc1·무출력·gh 0회)"

# ④ 라벨 부재 → setup-labels 1회 + 재시도 1회로 복구
mkparent $'Epic #4962\n' 'P0'
SO_CREATE=labelfail run 4979
[ "$RC" = 0 ] && [ "$OUT" = "501" ] && ok || bad "④ rc=$RC out=[$OUT] err=[$ERR]"
[ "$(printf '%s\n' "$CALLS" | grep -c 'issue create')" = 2 ] \
  && ok || bad "④ create 호출 $(printf '%s\n' "$CALLS" | grep -c 'issue create')회 (기대 2: 실패 1 + 재시도 1)"
printf '%s\n' "$CALLS" | grep -q 'label create' && ok || bad "④ setup-labels.sh 를 안 불렀다"
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label P0' && ok || bad "④ 부모 P0 상속이 라벨에 없다"

# ⑤ 재시도도 실패 → 무라벨 폴백 + exit 2 + readback 없음(#223) + PR 마커는 남는다
mkparent $'Epic #4962\n' 'P1'
SO_CREATE=labelfail2 run 4979
{ [ "$RC" = 2 ] && [ "$OUT" = "501" ]; } && ok || bad "⑤ rc=$RC out=[$OUT] (기대 rc2·번호 출력)"
printf '%s\n' "$CALLS" | grep -q 'issue create --repo ggqgga/BodaT --title 파생 제목 --body-file [^ ]*$' \
  && ok || bad "⑤ 무라벨 create 가 없다: $(printf '%s\n' "$CALLS" | grep 'issue create')"
printf '%s\n' "$CALLS" | grep -q 'issue view.*--json labels,body' \
  && bad "⑤ 폴백 건인데 라벨 readback 을 불렀다 (#223)" || ok
printf '%s\n' "$CALLS" | grep -q 'pr comment' && ok || bad "⑤ 폴백 건에 PR 마커가 없다(중복 발행 방지 마커 유실)"

# ⑥ 라벨과 무관한 발행 실패 → exit 1·무출력
SO_CREATE=allfail run 4979
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "⑥ rc=$RC out=[$OUT] (기대 rc1·무출력)"

# ⑦ readback 에 spinoff 라벨이 빠져 있으면 --add-label 로 보강한다
mkparent $'Epic #4962\n' 'P1'
: > "$tmp/calls.log"
OUT=$(SO_CALLS="$tmp/calls.log" SO_PARENT="$tmp/parent.json" \
      SO_READBACK='{"labels":[{"name":"agent-ready"},{"name":"P1"}],"body":"Epic #4962\n"}' \
      PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 4979 77 \
      --title "파생 제목" --body-file "$tmp/body.md" 2>/dev/null)
RC=$?
CALLS=$(cat "$tmp/calls.log")
printf '%s\n' "$CALLS" | grep -q 'issue edit 501 .*--add-label spinoff' \
  && ok || bad "⑦ 빠진 라벨 보강(--add-label spinoff)이 없다: $(printf '%s\n' "$CALLS" | grep 'issue edit')"
[ "$RC" = 0 ] && ok || bad "⑦ 보강 성공인데 rc=$RC (기대 0)"

# ⑧ 라벨 보강 `issue edit` 가 실패하면 삼키지 않는다 (#467 P1-3) — 2차 readback 이 비어
#    `still` 이 빈 값이 되는 바람에 "붙었다" 로 읽히면 agent-ready 없는 파생이 영영 안 집힌다.
: > "$tmp/calls.log"
OUT=$(SO_CALLS="$tmp/calls.log" SO_PARENT="$tmp/parent.json" SO_EDIT_RC=1 \
      SO_READBACK='{"labels":[{"name":"agent-ready"}],"body":"Epic #4962\n"}' \
      PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 4979 77 \
      --title "파생 제목" --body-file "$tmp/body.md" 2>"$tmp/err.log")
RC=$?
{ [ "$RC" = 2 ] && [ "$OUT" = "501" ]; } && ok \
  || bad "⑧ edit 실패인데 rc=$RC out=[$OUT] (기대 2·번호는 출력)"
grep -q '보강' "$tmp/err.log" && ok || bad "⑧ 보강 실패 사유가 stderr 에 없다: [$(cat "$tmp/err.log")]"

# ⑨ 2차 readback 이 실패해도 rc=2 — 확인 못 한 것을 확인된 것으로 쓰지 않는다.
: > "$tmp/calls.log"
OUT=$(SO_CALLS="$tmp/calls.log" SO_PARENT="$tmp/parent.json" SO_VIEW2_FAIL=1 \
      SO_READBACK='{"labels":[{"name":"agent-ready"}],"body":"Epic #4962\n"}' \
      PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 4979 77 \
      --title "파생 제목" --body-file "$tmp/body.md" 2>"$tmp/err.log")
RC=$?
{ [ "$RC" = 2 ] && [ "$OUT" = "501" ]; } && ok || bad "⑨ 2차 readback 실패인데 rc=$RC (기대 2)"
grep -q '부착 확인 불가' "$tmp/err.log" && ok || bad "⑨ 확인 불가 사유가 stderr 에 없다"

# ⑩ 값 옵션이 마지막에 오면 무한루프가 아니라 즉시 usage 64 (#467 P2-3)
for flag in --title --body-file --label; do
  PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 4979 77 "$flag" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 64 ] && ok || bad "⑩ $flag 값 누락 exit $rc (기대 64)"
done

echo "── 계약(usage·실행비트) ──────────────────────────────────────────"

# ⑧ 인자 부족 → usage exit 64
PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑧ 인자 부족 exit $rc (기대 64)"

# ⑨ 본문 파일 없음 → exit 64 (발행 시도조차 하지 않는다)
PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 4979 77 --title T --body-file "$tmp/nope.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑨ 본문 파일 없음 exit $rc (기대 64)"

# ⑪ 출처 줄 — 슬롯이 있으면 둘째 줄로 치환, 슬롯 없는 옛 본문이면 둘째 줄에 끼워 넣는다(#411)
mkparent $'Epic #4962\n\n## 배경\n어쩌고.' 'P1'
run 4979 77
[ "$RC" = 0 ] && [ "$(sed -n 2p "$tmp/sent-body.md")" = "Spinoff of PR #77 (issue #4979)" ] && ok \
  || bad "⑪ 슬롯 치환 — 둘째 줄이 출처 줄이 아니다(rc=$RC): [$(sed -n 2p "$tmp/sent-body.md")]"
# 슬롯이 엉뚱한 자리(산문 뒤)에 있으면 걷어 내고 둘째 줄에 다시 세운다 — 정확히 1줄.
printf '<EPIC_LINE>\n산문 한 줄.\n<ORIGIN_LINE>\n\n## 배경\n내용.\n' > "$tmp/body-misplaced.md"
run 4979 77 "$tmp/body-misplaced.md"
[ "$RC" = 0 ] && [ "$(sed -n 2p "$tmp/sent-body.md")" = "Spinoff of PR #77 (issue #4979)" ] \
  && [ "$(grep -c 'Spinoff of PR #' "$tmp/sent-body.md")" = 1 ] && ok \
  || bad "⑪ 엉뚱한 자리의 출처 줄 — 둘째 줄로 옮기고 하나만 남겨야(rc=$RC): [$(head -4 "$tmp/sent-body.md" | tr '\n' '|')]"
printf '<EPIC_LINE>\n\n## 배경\n슬롯 없는 옛 본문.\n' > "$tmp/body-noslot.md"
run 4979 77 "$tmp/body-noslot.md"
[ "$RC" = 0 ] && [ "$(sed -n 2p "$tmp/sent-body.md")" = "Spinoff of PR #77 (issue #4979)" ] && ok \
  || bad "⑪ 슬롯 없음 — 둘째 줄에 끼워 넣지 않았다(rc=$RC): [$(sed -n 2p "$tmp/sent-body.md")]"
# 단발 부모(epic=-) + 슬롯이 하나도 없는 손본문 — 첫 줄이 `## 배경` 이라 그 다음에 끼우면 본문 절을 가른다.
# 빈 줄을 먼저 세우고 둘째 줄에 출처를 둔다(템플릿 렌더 결과와 같은 꼴).
mkparent $'## 배경\n단발.' 'P1'
printf '## 배경\n내용.\n' > "$tmp/body-bare.md"
run 4979 77 "$tmp/body-bare.md"
[ "$RC" = 0 ] && [ "$(sed -n '1p;2p;3p' "$tmp/sent-body.md" | tr '\n' '|')" = "|Spinoff of PR #77 (issue #4979)|## 배경|" ] && ok \
  || bad "⑪ 단발+슬롯 없음 — 본문 절을 갈랐다: [$(head -3 "$tmp/sent-body.md" | tr '\n' '|')]"

# ⑩ 실행 비트 — closeout 6단계가 `$SCRIPTS/spinoff-issue.sh` 로 직접 exec 한다(PR#173 함정).
[ -x "$SUT" ] && ok || bad "⑩ spinoff-issue.sh 실행 비트 없음"

echo "spinoff-issue.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
