#!/usr/bin/env bash
# deploy-wait-issue.sh 픽스처 테스트 — 네트워크 무접속(gh 는 PATH 스텁), 기대값은 손으로.
#
# #446: closeout 4단계와 full-cycle §7 이 각자 산문으로 밟던 배포 대기 이슈 발행을 한 자리로
# 접은 스크립트의 SSOT 테스트다. 이 스크립트가 내는 **제목·절 이름·`없음`·`(승격만)` 은
# deploy-cycle · deploy-bodat 이 읽는 파싱 계약**이라, 여기 단언들이 그 계약의 회귀 가드다.
# 무는 것:
#   ⑴ 제목 형태 `배포 대기: PR #<pr> — <요약>` · 항목 0이면 ` (승격만)` 접미
#   ⑵ 본문에 `## 검증 URL` · `## 라이브/하드웨어 검증 항목` 절이 그대로 있고 placeholder
#      6개가 남김없이 치환된다
#   ⑶ 산문 항목은 **발행 전** exit 65 (gh 를 한 번도 부르지 않는다 — 잃은 것 없음)
#   ⑷ `needs:hardware` 는 레포에 라벨이 있을 때만 붙는다(없는 라벨 하나가 create 를 통째로
#      죽여 `deploy-wait` 까지 잃게 하지 않는다)
#   ⑸ 라벨 부재 3단 사다리: setup-labels 1회 + 재시도 1회 → 무라벨 발행(exit 2) + readback
#      제외(#223) + PR 마커는 그래도 남는다
#   ⑹ 발행 자체 실패는 exit 1·무출력
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/deploy-wait-issue.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"

# gh 스텁 — 호출을 기록하고 `issue create` 의 본문을 $DW_BODY 로 떠 둔다.
#   DW_CREATE=ok|labelfail|labelfail2|allfail · DW_HWLABEL=1 이면 레포에 needs:hardware 있음
cat > "$tmp/stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DW_CALLS"
case "$*" in
  *"label list"*)
    echo "deploy-wait"
    [ "${DW_HWLABEL:-0}" = 1 ] && echo "needs:hardware"
    exit 0 ;;
  *"issue create"*)
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$DW_BODY"
      [ "$prev" = "--title" ] && printf '%s\n' "$a" > "$DW_TITLE"
      prev=$a
    done
    n=$(grep -c 'issue create' "$DW_CALLS")
    case "${DW_CREATE:-ok}" in
      labelfail)  [ "$n" = 1 ] && { echo "could not add label: 'deploy-wait' not found" >&2; exit 1; } ;;
      labelfail2) case "$*" in *--label*) echo "could not add label: 'deploy-wait' not found" >&2; exit 1 ;; esac ;;
      allfail)    echo "HTTP 502" >&2; exit 1 ;;
    esac
    echo "https://github.com/ggqgga/BodaT/issues/${DW_NEW:-5200}"; exit 0 ;;
  *"issue view"*"--json labels"*) printf '%s\n' "${DW_READBACK:-deploy-wait}"; exit 0 ;;
  *"issue view"*"--json body,labels"*) cat "$DW_PARENT"; exit 0 ;;
  *"issue edit"*|*"pr comment"*|*"label create"*|*"repo edit"*) exit 0 ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/stub/gh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

printf '주석 한 줄 고침. 관찰 가능한 변화 없음.\n' > "$tmp/summary.md"
printf -- '- [ ] /pcs 에 워커 카드가 렌더된다\n- [ ] [칸 ③] TEST 워커 프로필 #18 드라이런\n' > "$tmp/items.md"
printf '없음\n' > "$tmp/none.md"
printf '없음. 주석 13줄이 전부다 — 관찰 가능한 변화가 없다.\n' > "$tmp/prose.md"
printf '{"body":"Epic #4962","labels":[{"name":"P0"}]}\n' > "$tmp/parent.json"

# run <items> [추가 인자...] — OUT/RC/CALLS/BODY/TITLE 을 채운다.
run() {
  items=$1; shift
  : > "$tmp/calls.log"; : > "$tmp/body.out"; : > "$tmp/title.out"
  OUT=$(DW_CALLS="$tmp/calls.log" DW_BODY="$tmp/body.out" DW_TITLE="$tmp/title.out" \
        DW_PARENT="$tmp/parent.json" PATH="$tmp/stub:$PATH" \
        bash "$SUT" ggqgga/BodaT 5300 --sha abc1234 --title "워커 카드 렌더 수정" \
        --summary-file "$tmp/summary.md" --items-file "$items" \
        --verify-url "http://100.65.53.51:3000" "$@" 2>"$tmp/err.log")
  RC=$?
  CALLS=$(cat "$tmp/calls.log"); BODY=$(cat "$tmp/body.out"); TITLE=$(cat "$tmp/title.out")
  ERR=$(cat "$tmp/err.log")
}

echo "── 제목·본문 파싱 계약 ───────────────────────────────────────────"

# ① 항목 있음 — 제목에 `(승격만)` 이 붙지 않는다
run "$tmp/items.md"
[ "$RC" = 0 ] && [ "$OUT" = "5200" ] && ok || bad "① rc=$RC out=[$OUT] err=[$ERR]"
[ "$TITLE" = "배포 대기: PR #5300 — 워커 카드 렌더 수정" ] \
  && ok || bad "① 제목 계약 위반: [$TITLE]"

# ② 본문 — 두 절 이름이 살아 있고 placeholder 가 남김없이 치환된다
printf '%s\n' "$BODY" | grep -qx '## 검증 URL' && ok || bad "② 본문에 '## 검증 URL' 절이 없다(deploy-cycle 파싱 계약)"
printf '%s\n' "$BODY" | grep -qx '## 라이브/하드웨어 검증 항목' && ok \
  || bad "② 본문에 '## 라이브/하드웨어 검증 항목' 절이 없다(deploy-cycle 파싱 계약)"
for ph in '<PR>' '<SHA>' '<SUMMARY>' '<DEPLOY_CMD>' '<LIVE_CHECKS>' '<VERIFY_URL>'; do
  printf '%s\n' "$BODY" | grep -qF "$ph" && bad "② placeholder 미치환: $ph" || ok
done
printf '%s\n' "$BODY" | grep -qF 'PR #5300 머지됨 (HEAD abc1234)' && ok || bad "② PR·SHA 치환 실패"
printf '%s\n' "$BODY" | grep -qF -- '- [ ] [칸 ③] TEST 워커 프로필 #18 드라이런' && ok \
  || bad "② 항목이 본문에 그대로 실리지 않았다(표식 유실 = 5단계 판별 붕괴)"
printf '%s\n' "$BODY" | grep -qF '주석 한 줄 고침' && ok || bad "② 요약이 본문에 없다"

# ③ 항목 `없음` → `(승격만)` 접미 + 본문 절에 `없음`
run "$tmp/none.md"
[ "$TITLE" = "배포 대기: PR #5300 — 워커 카드 렌더 수정 (승격만)" ] \
  && ok || bad "③ (승격만) 접미 계약 위반: [$TITLE]"
printf '%s\n' "$BODY" | grep -qx '없음' && ok || bad "③ 본문 항목 절이 `없음` 이 아니다"

# ④ 산문 항목 → 발행 전 exit 65, gh 호출 0회(잃은 것 없음 — 고쳐서 다시 부르면 된다)
run "$tmp/prose.md"
{ [ "$RC" = 65 ] && [ -z "$OUT" ] && [ -z "$CALLS" ]; } && ok \
  || bad "④ 산문 항목 rc=$RC out=[$OUT] calls=[$CALLS] (기대 65·무출력·gh 0회)"

echo "── 템플릿 치환(#484) ────────────────────────────────────────────"

# ⑮ --lane closeout(기본) → 배경 절 레인 문구가 그대로 치환된다
run "$tmp/items.md"
printf '%s\n' "$BODY" | grep -qF 'closeout 4단계 → deploy-cycle 레인' && ok \
  || bad "⑮ closeout 레인 문구 치환 실패"

# ⑯ --lane full-cycle → 배경 절 레인 문구가 사람 게이트 문구로 바뀐다
run "$tmp/items.md" --lane full-cycle
printf '%s\n' "$BODY" | grep -qF '사람 세션 full-cycle — 사람 게이트' && ok \
  || bad "⑯ full-cycle 레인 문구 치환 실패"

# ⑰ --deploy-cmd 값 양끝 백틱은 벗겨지고 템플릿이 한 번만 감싼다(이중 방지)
run "$tmp/items.md" --deploy-cmd '`custom deploy`'
printf '%s\n' "$BODY" | grep -qF '`custom deploy`' && ok || bad "⑰ deploy-cmd 값이 본문에 없다"
printf '%s\n' "$BODY" | grep -qF '``custom deploy``' \
  && bad "⑰ deploy-cmd 백틱이 이중으로 감싸졌다" || ok

# ⑱ --verify-url 없음 → BoDAT 안내 산문 없이 값만 남는다
run "$tmp/items.md" --verify-url "없음"
printf '%s\n' "$BODY" | grep -qx '없음' && ok || bad "⑱ verify-url 값(없음)이 본문에 없다"
printf '%s\n' "$BODY" | grep -qF 'production 베이스 URL' \
  && bad "⑱ verify-url 없음인데 안내 산문이 남았다" || ok

echo "── 라벨 ─────────────────────────────────────────────────────────"

# ⑤ 기본 라벨은 deploy-wait 하나
run "$tmp/items.md"
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label deploy-wait' && ok || bad "⑤ deploy-wait 라벨이 없다"
printf '%s\n' "$CALLS" | grep -q 'needs-human' && bad "⑤ needs-human 을 붙였다 (#243 위반)" || ok

# ⑥ --lane full-cycle → full-cycle 라벨 · --parent-issue → P 상속(P0)
run "$tmp/items.md" --lane full-cycle --parent-issue 4979
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label full-cycle' && ok || bad "⑥ 레인 라벨(full-cycle) 없음"
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label P0' && ok || bad "⑥ 부모 P0 상속 실패"

# ⑦ --hardware 이고 레포에 라벨이 있을 때만 needs:hardware
DW_HWLABEL=1 run "$tmp/items.md" --hardware
printf '%s\n' "$CALLS" | grep -q 'issue create.*--label needs:hardware' && ok || bad "⑦ 라벨이 있는데 needs:hardware 미부착"
run "$tmp/items.md" --hardware
printf '%s\n' "$CALLS" | grep -q 'needs:hardware' \
  && bad "⑦ 레포에 없는 needs:hardware 를 붙였다(create 통째 실패 위험)" || ok

echo "── 라벨 부재 3단 사다리 ──────────────────────────────────────────"

# ⑧ 1회차 not found → setup-labels 1회 + 재시도 1회로 복구
DW_CREATE=labelfail run "$tmp/items.md"
[ "$RC" = 0 ] && [ "$OUT" = "5200" ] && ok || bad "⑧ rc=$RC out=[$OUT] (기대 0·5200)"
[ "$(printf '%s\n' "$CALLS" | grep -c 'issue create')" = 2 ] \
  && ok || bad "⑧ create 호출 $(printf '%s\n' "$CALLS" | grep -c 'issue create')회 (기대 2)"
printf '%s\n' "$CALLS" | grep -q 'label create' && ok || bad "⑧ setup-labels.sh 미호출"

# ⑨ 재시도도 실패 → 무라벨 발행 + exit 2 + readback 제외(#223) + PR 마커 유지
DW_CREATE=labelfail2 run "$tmp/items.md"
{ [ "$RC" = 2 ] && [ "$OUT" = "5200" ]; } && ok || bad "⑨ rc=$RC out=[$OUT] (기대 2·번호 출력)"
printf '%s\n' "$CALLS" | grep -q 'issue create --repo ggqgga/BodaT --title [^-]*--body-file [^ ]*$' \
  && ok || bad "⑨ 무라벨 create 가 없다"
printf '%s\n' "$CALLS" | grep -q 'issue view.*--json labels' \
  && bad "⑨ 폴백 건인데 라벨 readback 을 불렀다 (#223)" || ok
printf '%s\n' "$CALLS" | grep -qF -- '--body 배포 대기: #5200' && ok \
  || bad "⑨ 폴백 건에 PR 마커가 없다(티켓은 있는데 아무도 모르는 상태)"

# ⑩ readback 에 deploy-wait 이 없으면 보강한다
DW_READBACK="P1" run "$tmp/items.md"
printf '%s\n' "$CALLS" | grep -q 'issue edit 5200 .*--add-label deploy-wait' && ok \
  || bad "⑩ 라벨 보강(--add-label deploy-wait) 없음"

# ⑪ 발행 자체 실패 → exit 1·무출력
DW_CREATE=allfail run "$tmp/items.md"
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "⑪ rc=$RC out=[$OUT] (기대 1·무출력)"

# ⑫ 유효 항목 + 산문 한 줄이 섞이면 발행하지 않는다 (#467 P2-1). 총수만 세던 검사는
#    이걸 통과시켜 그 산문 줄이 이슈에 실렸고, 5단계 집계는 체크박스가 아니라 무시했다 —
#    밟아야 할 것이 원장에서 조용히 사라지는 형상.
printf -- '- [ ] /pcs 렌더 확인\n주석 13줄이 전부라 관찰 가능한 변화가 없다.\n' > "$tmp/mixed.md"
run "$tmp/mixed.md"
{ [ "$RC" = 65 ] && [ -z "$CALLS" ]; } && ok \
  || bad "⑫ 혼합(항목+산문) rc=$RC calls=[$CALLS] (기대 65·gh 0회)"
printf '%s\n' "$ERR" | grep -q '첫 위반 줄' && ok || bad "⑫ 위반 줄이 stderr 에 없다"

# ⑬ 전부 유효한 체크박스면 통과한다(위 검사가 정상 항목을 막지 않는다).
printf -- '- [ ] a\n- [x] 이미 밟음\n- [ ] [칸 ③] 실장비\n' > "$tmp/allbox.md"
run "$tmp/allbox.md"
[ "$RC" = 0 ] && ok || bad "⑬ 정상 체크박스 목록 rc=$RC err=[$ERR]"

# ⑭ 값 옵션이 마지막에 오면 무한루프가 아니라 즉시 usage 64 (#467 P2-3)
for flag in --sha --summary-file --items-file --title --lane --verify-url --priority --template; do
  PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 5300 "$flag" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 64 ] && ok || bad "⑭ $flag 값 누락 exit $rc (기대 64)"
done

echo "── 계약(usage·실행비트) ──────────────────────────────────────────"

# ⑫ 필수 인자 누락 → usage exit 64
PATH="$tmp/stub:$PATH" bash "$SUT" ggqgga/BodaT 5300 --sha abc >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑫ 인자 누락 exit $rc (기대 64)"

# ⑬ 실행 비트 — closeout 4단계·full-cycle §7 이 직접 exec 한다(PR#173 함정)
[ -x "$SUT" ] && ok || bad "⑬ deploy-wait-issue.sh 실행 비트 없음"

echo "deploy-wait-issue.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
