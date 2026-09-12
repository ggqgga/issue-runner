#!/usr/bin/env bash
# smoke-tally.sh [--checks|--result] <파일>
#
# closeout 5단계 Chrome 스모크의 **집계 계산기 — 한 자리** (#448 · 에픽 #443 2단계).
# 종전엔 같은 산술 규칙(표식 판별 · 분모 제외 · 보류 합산)이 SKILL 5단계 산문과
# `references/smoke-prompt.md` 양쪽에 적혀 있었다 — closeout SKILL 이 자인한 "실장비를
# 세는 계산기가 둘" 상태다. 규칙의 SSOT 는 이제 이 주석과 아래 코드다. 프롬프트는
# **판정 어휘(pass/fail/보류)를 낳고**, 이 스크립트가 **셈한다**.
#
# ── 입력 두 종류 (모드는 명시적 플래그로 가른다 — 추측하지 않는다) ───────────────
# ⒜ `--checks <파일>` : 배포 이슈 본문의 `## 라이브/하드웨어 검증 항목` 절 그대로.
#    스모크를 **돌리기 전에** "크롬이 밟을 줄이 있는가" 를 센다.
# ⒝ `--result <파일>` (기본) : 스모크가 낸 **판정 줄만** 담은 파일.
#
# ── ⒝ 판정 줄 문법 (smoke-prompt.md 「출력 계약」과 문자 그대로 같은 것) ─────────
#     <판정> <원본 항목 줄>[ — 근거]
#   `<판정>` = 줄의 **첫 공백 구분 토큰**이고 `pass`·`fail`·`보류`(영문 프롬프트는
#   `held`) 셋뿐이다(대소문자 무시). 그 뒤는 이슈 본문의 원본 항목 줄을 **그대로** 옮긴다
#   (`- [ ] [칸 ③] …` 의 표식이 살아 있어야 아래 표식 판별이 선다). 예:
#     pass	- [ ] /pcs 에 워커 카드가 렌더된다 — 카드 12개 확인
#     보류	- [ ] [칸 ③] TEST 워커 프로필 #18 드라이런
#   빈 줄과 `#` 로 시작하는 줄은 무시한다. 요약(`스모크: …`)·산문 문단은 이 파일에 넣지
#   마라 — 문법에 안 맞는 줄은 **조용히 사라지지 않고** `unparsed` 로 세어져 `held` 에
#   합산된다(그 틱은 green 이 될 수 없다). 판정 못 한 줄을 흘려보내면 그게 곧 거짓 초록이다.
#
# ── 세는 규칙 (우선순위 순 — 위가 이긴다) ──────────────────────────────────────
# ⑴ 항목이 이미 `- [x]` → `skipped`. 밟힌 줄은 보류에도 분모에도 안 들어간다.
# ⑵ 항목에 접두 표식 `[칸 ③]` → `held_marked`. **판정 토큰이 무엇이든 표식이 이긴다** —
#    실장비(사다리 칸 ③ TEST 워커 프로필 #18 드라이런)는 크롬이 못 밟으므로 pass/fail 로
#    적힌 것 자체가 거짓이다(#309). 분모에서 뺀다.
# ⑶ 그 밖 → 판정대로 `pass`·`fail`·`held_unstepped`(보류 = 브라우저 밖 수단이 필요해
#    **시도조차 못 한** 줄. 밟았는데 값이 달랐으면 그건 `fail` 이다 — 그 판정은 크롬을
#    쥔 프롬프트의 몫이고 여기서 뒤집지 않는다).
# ⑷ 문법 위반 → `unparsed`(+`held` 합산). fail-closed.
#
#   `denominator` = pass + fail  ( = `스모크: <통과수>/<전체수> 통과` 의 전체수)
#   `held`        = held_marked + held_unstepped + unparsed
#
# ── 출력 (stdout 한 줄 JSON) ────────────────────────────────────────────────────
# --result:
#   {"mode":"result","pass":N,"fail":N,"held":N,"held_marked":N,"held_unstepped":N,
#    "unparsed":N,"skipped":N,"denominator":N,"verdict":"green|fail|held|skip"}
#   `verdict` 는 5단계 갈래를 그대로 옮긴 것이다(우선순위 순):
#     fail   — 한 건이라도 fail (후속 이슈 발행 갈래). **`held` 는 따로 읽어라** — fail 과
#              보류는 동시에 참일 수 있고, 보류가 남으면 fail 갈래에서도 이슈를 닫지 않는다.
#     skip   — 분모 0 (`스모크 생략: 밟을 항목 0` — 0/0 은 통과가 아니라 아무것도 안 본 것)
#     held   — 전부 통과했지만 보류가 남음 (`종결 보류: 실장비 항목 <n>건`)
#     green  — 전부 통과 + 보류 0 (`✅ 스모크: <n>/<n> 통과` → 이슈 close)
# --checks:
#   {"mode":"checks","steppable":N,"held_marked":N,"skipped":N,"open":N}
#   `steppable` = 크롬이 밟을 열린 줄. **0이면 스모크를 돌리지 마라**(`없음` 절도, 표식
#   줄만 남은 절도 여기서 0이 된다 — 대조할 항목 0인 스모크는 거짓 초록이다).
#   체크박스가 아닌 줄(HTML 주석·`없음`)은 이 모드에서 세지 않는다.
#
# exit: 0 집계 성공(판정과 무관 — 판정은 JSON 이 낸다) · 64 usage · 66 파일 없음/못 읽음.
# 읽기 전용이다 — 네트워크도 gh 도 쓰지 않는다. macOS bash 3.2 대상(연관배열·mapfile 금지).
set -uo pipefail

usage() {
  echo "usage: smoke-tally.sh [--checks|--result] <파일>" >&2
}

mode=result
file=
while [ $# -gt 0 ]; do
  case "$1" in
    --checks) mode=checks; shift ;;
    --result) mode=result; shift ;;
    --) shift ;;
    -*) usage; exit 64 ;;
    *)
      if [ -n "$file" ]; then usage; exit 64; fi
      file=$1; shift ;;
  esac
done
[ -n "$file" ] || { usage; exit 64; }
[ -r "$file" ] || { echo "smoke-tally: 파일을 읽을 수 없다: $file" >&2; exit 66; }

pass=0; fail=0; held_marked=0; held_unstepped=0; unparsed=0; skipped=0; steppable=0

while IFS= read -r line || [ -n "$line" ]; do
  # 앞 공백 제거(들여쓴 불릿도 항목 줄이다)
  trimmed=${line#"${line%%[![:space:]]*}"}
  [ -n "$trimmed" ] || continue
  case "$trimmed" in '#'*) continue ;; esac

  if [ "$mode" = checks ]; then
    case "$trimmed" in
      '- [x]'*|'- [X]'*) skipped=$((skipped + 1)); continue ;;
      '- [ ]'*) ;;
      *) continue ;;                       # 체크박스 아닌 줄(주석·`없음`·산문)은 항목이 아니다
    esac
    case "$trimmed" in
      *'[칸 ③]'*) held_marked=$((held_marked + 1)) ;;
      *)          steppable=$((steppable + 1)) ;;
    esac
    continue
  fi

  # ── --result: 첫 토큰이 판정이다 ──
  tok=${trimmed%%[[:space:]]*}
  rest=${trimmed#"$tok"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  verdict=$(printf '%s' "$tok" | tr 'A-Z' 'a-z')
  case "$verdict" in
    pass|fail) ;;
    보류|held)  verdict=held ;;
    *)         verdict= ;;
  esac
  if [ -z "$verdict" ] || [ -z "$rest" ]; then
    unparsed=$((unparsed + 1)); continue    # fail-closed — 판정 못 한 줄은 사라지지 않는다
  fi
  case "$rest" in
    '- [x]'*|'- [X]'*) skipped=$((skipped + 1)); continue ;;
  esac
  case "$rest" in
    *'[칸 ③]'*) held_marked=$((held_marked + 1)); continue ;;   # 표식이 판정을 이긴다
  esac
  case "$verdict" in
    pass) pass=$((pass + 1)) ;;
    fail) fail=$((fail + 1)) ;;
    held) held_unstepped=$((held_unstepped + 1)) ;;
  esac
done < "$file"

if [ "$mode" = checks ]; then
  printf '{"mode":"checks","steppable":%d,"held_marked":%d,"skipped":%d,"open":%d}\n' \
    "$steppable" "$held_marked" "$skipped" "$((steppable + held_marked))"
  exit 0
fi

held=$((held_marked + held_unstepped + unparsed))
denominator=$((pass + fail))
if [ "$fail" -gt 0 ]; then          verdict=fail
elif [ "$denominator" = 0 ]; then   verdict=skip
elif [ "$held" -gt 0 ]; then        verdict=held
else                                verdict=green
fi
printf '{"mode":"result","pass":%d,"fail":%d,"held":%d,"held_marked":%d,"held_unstepped":%d,"unparsed":%d,"skipped":%d,"denominator":%d,"verdict":"%s"}\n' \
  "$pass" "$fail" "$held" "$held_marked" "$held_unstepped" "$unparsed" "$skipped" "$denominator" "$verdict"
exit 0
