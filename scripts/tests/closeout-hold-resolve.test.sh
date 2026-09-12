#!/usr/bin/env bash
# closeout ①-c 해소 판정 — **경계 형상 격자** 테스트 (#334 attempt 4 · 사람 결정 ⓐ)
#
# 왜 이 테스트가 있는가 — 같은 축(①-c 인덱스/경계 비교)에서 codex BLOCKER 가 3회 연속
# 났다. 회차마다 지적된 한 사례(교차 배열 비교 → `r` 없음 갈래 → `r` 있음 갈래)만 닫았기
# 때문이다(PR#202·PR#239 교훈). 상한에 닿아 사람이 판정 모델을 **단순화**했다:
#
#   이슈측 단독 경계 형상(PR 배열에 보류 경계 0 · 이슈 배열에 있음)은 **`r` 유무 무관
#   "해소 후보 없음"** — 인덱스·`createdAt` 어느 것으로도 방향을 추정하지 않는다.
#   `closeout-blocked` 재호출로 **양측 경계를 복구**한 뒤 정상 경로로 돌아온다.
#
# 그리고 attempt 3 P2: `D=true, H=true`(결정문은 달렸는데 라벨은 아직) 에서 `closeout-blocked`
# 를 다시 부르면 새 `<!-- hold-note: -->` 가 경계를 사람 결정 **뒤로** 밀어 그 결정을 폐기한다
# → 라벨이 남아 있으면 **무접촉**(경계를 다시 쓰지 않는다). 재호출은 "양측 경계 복구" 이므로
# 재호출 **뒤** 의 사람 결정(더 늦은 것)이 이기고, 재호출 **앞** 의 결정은 세지 않는다.
#
# 이 파일은 그 모델을 픽스처 격자 위에서 **평가**한다 — 형상 전체를 동치류마다 1개 + 경계
# 1개로 못박는다(격자의 `want` 열이 계약). 동시에 `skills/closeout/SKILL.md`(·`.en.md`) ①-c
# 격자의 해당 행 `want` 칸이 같은 결론을 적고 있는지 **교차 확인**한다 — 문서와 이 격자가
# 갈리면 빨강이다(문서만 고치고 모델을 안 고쳤거나 그 반대).
#
# 뮤테이션 방증 — `HOLD_MUT` 로 판정 모델을 옛 회차의 동작으로 되돌리면 fail>0 이어야 한다:
#   HOLD_MUT=cross  : attempt 1(`fbdcfba`) — 이슈 배열 경계 인덱스와 PR 배열 완결 인덱스를
#                     교차 비교해 낡은 ✅ 를 해소로 읽는다.
#   HOLD_MUT=index  : attempt 3(`411f51a2`) — 이슈측 단독 경계에서 PR 배열에 `r` 이 있으면
#                     `f > r` 로 해소, 없으면 이슈측 결정문으로 방향 판정.
#   HOLD_MUT=repost : attempt 3 P2 — `D=true, H=true` 에서 `closeout-blocked` 를 재호출해
#                     경계를 결정문 뒤로 민다(결정 폐기).
# `bin/ci` 가 정상 1회 + 뮤테이션 3회를 돌려 뒤 셋이 **실제로 fail>0 으로 끝나는지** 확인한다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KO="$DIR/skills/closeout/SKILL.md"
EN="$DIR/skills/closeout/SKILL.en.md"
MUT=${HOLD_MUT:-}

pass=0
fail=0
check_eq() { # check_eq <이름> <기대> <실제>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ $1"; echo "    기대: [$2]"; echo "    실제: [$3]"
  fi
}

# ── 코멘트 배열 표기 ───────────────────────────────────────────────────────
# 배열은 토큰을 콤마로 이은 문자열이다(인덱스 0 부터). 토큰:
#   H = 보류 경계(`마감 검증: ⚠ 보류`·`머지 판정: ⚠ 보류`·`<!-- hold-note: `)
#   R = 재디스패치 마커(`재디스패치: #<이슈>`)     F = 완결 판정(`머지 판정: ✅`·`마감 검증: ✅`)
#   D = 사람 결정문(마커 없는 코멘트 ∪ `<!-- policy-review: resumed -->`)   X = 그 밖
# `-` 는 빈 배열. 이슈 배열엔 R·F 가 오지 않는다(생산자가 PR 에만 쓴다).
last_idx() { # last_idx <배열> <토큰> → 마지막 매칭 인덱스, 없으면 -1
  local i=0 t found=-1 arr="$1"
  [ "$arr" = '-' ] && { echo -1; return; }
  IFS=',' read -r -a toks <<<"$arr"
  for t in "${toks[@]}"; do [ "$t" = "$2" ] && found=$i; i=$((i + 1)); done
  echo "$found"
}
has_after() { # has_after <배열> <토큰> <경계 인덱스> → 0 = 경계 **뒤** 에 그 토큰이 있다
  local i=0 t arr="$1"
  [ "$arr" = '-' ] && return 1
  IFS=',' read -r -a toks <<<"$arr"
  for t in "${toks[@]}"; do [ "$t" = "$2" ] && [ "$i" -gt "$3" ] && return 0; i=$((i + 1)); done
  return 1
}

# ── 판정 모델 ─────────────────────────────────────────────────────────────
# decide <PR 배열> <이슈 배열> <H(0/1)> → 결론 하나:
#   pick      = 해소 → ② Pick                keep      = 보류 유지 · 무접촉
#   restore   = 해소 후보 없음 → `closeout-blocked` 재호출로 **양측 경계 복구**
#   direction = 2) 논리곱 참 → 3) 방향 판정  ambiguous = 2)ⓐ 거짓 → 3) 모호 → `closeout-blocked`
#   idem      = 멱등 분기(`r > h`, 라벨 술어 — closeout-lane-predicate.test.sh 의 몫)
decide() {
  local pr="$1" is="$2" H="$3" h_pr r_pr f_pr h_is base D=1
  h_pr=$(last_idx "$pr" H); r_pr=$(last_idx "$pr" R); f_pr=$(last_idx "$pr" F)
  h_is=$(last_idx "$is" H)
  # 0) 경계 0(양쪽 다) — 보류가 없었다. 라벨만 있으면 보류 유지.
  if [ "$h_pr" -lt 0 ] && [ "$h_is" -lt 0 ]; then
    [ "$H" = 1 ] && echo keep || echo pick; return
  fi
  # 이슈측 단독 경계 — PR 배열엔 경계 0, 이슈 배열엔 있음.
  if [ "$h_pr" -lt 0 ]; then
    case "$MUT" in
      cross) # attempt 1: 배열을 넘어 인덱스 비교 — 낡은 ✅(PR 인덱스) > 이슈 경계 인덱스면 해소
        if [ "$f_pr" -gt "$h_is" ]; then [ "$H" = 1 ] && echo keep || echo pick; return; fi ;;
      index) # attempt 3: PR 배열에 r 이 있으면 f > r 로 해소, 없으면 이슈측 결정문으로 방향 판정
        if [ "$r_pr" -ge 0 ] && [ "$f_pr" -gt "$r_pr" ]; then [ "$H" = 1 ] && echo keep || echo pick; return; fi
        [ "$H" = 1 ] && { echo keep; return; }
        has_after "$is" D "$h_is" && echo direction || echo ambiguous; return ;;
    esac
    # 사람 결정 ⓐ: r 유무 무관 해소 후보 없음 — 비교하지 않는다. 라벨이 있으면 무접촉,
    # 없으면 closeout-blocked 재호출로 양측 경계를 복구한다.
    [ "$H" = 1 ] && echo keep || echo restore; return
  fi
  # 양측 경계 정상 — 인덱스 비교는 PR 배열 안에서만.
  base=$h_pr; [ "$r_pr" -gt "$base" ] && base=$r_pr
  if [ "$f_pr" -gt "$base" ]; then [ "$H" = 1 ] && echo keep || echo pick; return; fi
  if [ "$r_pr" -gt "$h_pr" ]; then echo idem; return; fi
  # 2) 결정문 ∧ 라벨 부재 — 결정문은 **그 출처 자신의** 경계 뒤에서만 센다.
  has_after "$pr" D "$h_pr" && D=0
  [ "$h_is" -ge 0 ] && has_after "$is" D "$h_is" && D=0
  if [ "$H" = 1 ]; then
    # attempt 3 P2 뮤테이션: 라벨이 남았는데 closeout-blocked 를 재호출 → 새 경계가 결정문 뒤로
    [ "$MUT" = repost ] && { echo restore; return; }
    echo keep; return
  fi
  [ "$D" = 0 ] && echo direction || echo ambiguous
}

# ── 픽스처 격자 ───────────────────────────────────────────────────────────
# id | PR 배열 | 이슈 배열 | H | want | SKILL 격자 행(교차 확인, `-` 는 행 없음)
# 동치류마다 1개 + 경계 1개:
#   양측 경계 정상       : both_decided(대표) · both_resolved(경계: F 가 H 바로 뒤) ·
#                          both_stale_f(경계: F 가 H 바로 앞 → 해소 아님)
#   이슈측 단독(r 없음)   : issue_only(대표 — 낡은 F 가 이슈 경계보다 큰 인덱스) · issue_only_H(경계: 라벨 있음)
#   이슈측 단독(r 있음)   : issue_only_r_f(대표 — attempt 3 P1 형상, f > r 인데 이슈 보류가 후발) ·
#                          issue_only_r_only(경계: r 만, f 없음)
#   재호출 뒤 사람 결정   : restored_then_d(대표 — 복구된 경계 뒤 결정문이 이긴다) ·
#                          restored_d_before(경계: 결정문이 복구 경계 **앞** — 세지 않는다)
#   P2 결정문 + 라벨 아직 : decided_labels_stay(D 참 · H 참 → 무접촉, 경계를 다시 쓰지 않는다)
GRID='
both_decided|H|H,D|0|direction|17
both_resolved|H,F|H|0|pick|3
both_stale_f|F,H|H,D|0|direction|-
issue_only|F|H,D|0|restore|28
issue_only_H|F|H,D|1|keep|29
issue_only_r_f|R,F|H,H|0|restore|30
issue_only_r_only|R|H,D|0|restore|-
restored_then_d|H|H,H,D|0|direction|32
restored_d_before|H|D,H|0|ambiguous|33
decided_labels_stay|H|H,D|1|keep|31
'

# ── SKILL 격자 행의 want 칸 교차 확인 ─────────────────────────────────────
# ①-c 절 안의 `| N |` 행에서 5번째 칸(`want`)을 뽑아 결론 어휘가 들어 있는지 본다.
ic_sec() { awk '/^## ①-c /{on=1} on && /^## / && !/^## ①-c /{exit} on' "$1"; }
want_cell() { # want_cell <파일> <행번호> → want 칸 텍스트(없으면 빈 문자열)
  ic_sec "$1" | grep -E "^\| $2 \|" | head -1 | awk -F'|' '{print $6}'
}
want_word() { # want_word <ko|en> <결론> → 그 결론이 want 칸에 반드시 담는 어휘
  case "$1:$2" in
    ko:pick) echo '② Pick' ;;       en:pick) echo '② Pick' ;;
    ko:keep) echo '무접촉' ;;        en:keep) echo 'untouched' ;;
    ko:restore) echo '양측 경계 복구' ;; en:restore) echo 'restore both boundaries' ;;
    ko:direction) echo '방향 판정' ;; en:direction) echo 'direction judgment' ;;
    ko:ambiguous) echo '모호' ;;     en:ambiguous) echo 'ambiguous' ;;
  esac
}

echo "  ── 격자(경계 형상 → 결론) ──"
printf '  %-22s %-8s %-8s %-3s %-10s %s\n' id PR 이슈 H want 실제
while IFS='|' read -r id pr is H want row; do
  [ -n "$id" ] || continue
  got=$(decide "$pr" "$is" "$H")
  printf '  %-22s %-8s %-8s %-3s %-10s %s\n' "$id" "$pr" "$is" "$H" "$want" "$got"
  check_eq "격자 $id" "$want" "$got"
  [ "$row" != '-' ] || continue
  for lang in ko en; do
    f=$KO; [ "$lang" = en ] && f=$EN
    cell=$(want_cell "$f" "$row")
    if [ -z "$cell" ]; then
      fail=$((fail + 1)); echo "  ✗ SKILL($lang) ①-c 격자에 ${row}행이 없다 — $id 형상이 문서에 못박혀 있지 않다"
      continue
    fi
    w=$(want_word "$lang" "$want")
    if grep -qF "$w" <<<"$cell"; then pass=$((pass + 1)); else
      fail=$((fail + 1)); echo "  ✗ SKILL($lang) ①-c 격자 ${row}행 want 칸에 '$w' 없음 — 문서와 이 격자의 결론이 다르다($id): $cell"
    fi
  done
done <<< "$GRID"

# ── 형상 불변식 ───────────────────────────────────────────────────────────
# ⑴ 이슈측 단독 경계에서 결론은 r·f·D 어느 것에도 의존하지 않는다 — H 로만 갈린다.
inv_ok=0
for pr in F R,F R -; do
  for is in H H,D D,H; do
    [ "$(decide "$pr" "$is" 0)" = restore ] || inv_ok=1
    [ "$(decide "$pr" "$is" 1)" = keep ] || inv_ok=1
  done
done
if [ "$inv_ok" = 0 ]; then pass=$((pass + 1)); echo "  ✓ 이슈측 단독 경계: r·f·D 무관 — H 없음=restore · H 있음=keep (12칸)"
else fail=$((fail + 1)); echo "  ✗ 이슈측 단독 경계 결론이 r·f·D 에 의존한다 — 사람 결정 ⓐ 위반(비교로 방향을 추정)"; fi
# ⑵ 양측 경계 정상에서 낡은 F(경계 앞)는 어떤 r 형상에서도 해소가 아니다.
[ "$(decide 'F,H' 'H,D' 0)" != pick ] && [ "$(decide 'F,H,R' 'H,D' 0)" != pick ] \
  && { pass=$((pass + 1)); } \
  || { fail=$((fail + 1)); echo "  ✗ 경계 앞의 낡은 F 가 해소로 읽힌다"; }
# ⑶ 재호출(양측 경계 복구) 뒤: 그 뒤의 결정문만 센다 — 복구 앞 결정문은 D 거짓.
[ "$(decide 'H' 'D,H' 0)" = ambiguous ] && [ "$(decide 'H' 'D,H,D' 0)" = direction ] \
  && { pass=$((pass + 1)); echo "  ✓ 복구 경계 앞 결정문은 세지 않고, 뒤 결정문이 이긴다"; } \
  || { fail=$((fail + 1)); echo "  ✗ 복구 경계 전후 결정문의 선후가 결론에 반영되지 않는다"; }

# 실행 비트 회귀 (#173 — 빠지면 exit 126 으로 조용히 degrade)
if [ -x "$0" ] || [ -x "$DIR/scripts/tests/closeout-hold-resolve.test.sh" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  ✗ closeout-hold-resolve.test.sh 실행 비트 없음"
fi

echo "closeout-hold-resolve.test${MUT:+ (HOLD_MUT=$MUT)}: pass=$pass fail=$fail"
[ "$fail" = 0 ]
