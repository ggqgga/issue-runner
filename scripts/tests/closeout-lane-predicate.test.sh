#!/usr/bin/env bash
# closeout ①-c 멱등 분기의 **하류 레인 술어 실효성** 테스트 (#334 BLOCKER)
#
# 왜 이 테스트가 있는가 — 검증자 반송문 그대로: *"새 동작이 전부 산문이라 스크립트 테스트가
# 없고 `bin/ci` 새 가드는 전부 **문구 존재/순서**만 잰다 — 특히 `L` 의 **실효성**
# (agent-ready 상수 · harvesting 반전)을 재는 검사가 없어 **정의가 의미를 잃어도 초록**이다."*
#
# 그래서 여기서는 문구를 세지 않는다. `skills/closeout/SKILL.md`(·`.en.md`)의 **정의식을
# 파싱해 실제로 평가**하고, 픽스처 격자에서 분기 결정이 `want` 와 같은지 본다. 정의가
# 상수가 되거나 라벨 하나가 빠지면 **이 테스트가 빨개진다** — 문구는 그대로여도.
#
# 재는 축 넷:
#   ⑴ `A` 에 `agent-ready` 가 들어 있지 않다 (∨ 항에 상수 참이 있으면 술어 전체가 상수).
#   ⑵ `A`·`R` 의 라벨 집합이 전이 표(`transition.sh:20` closeout-redispatch 행)와 일치한다.
#   ⑶ **값이 갈린다** — "전이 섰음" 픽스처와 "전이 실패(이슈측 편집 미적용)" 픽스처에서
#      분기 결정이 **다르다**. 구 술어(`agent-ready` 포함)에서는 둘이 **같았다**(=고친 게
#      아니라는 반증의 기준선). 구 술어 결정도 같은 격자에서 함께 계산해 나란히 찍는다.
#   ⑷ 격자 10·13행이 **도달 가능**하다(구 술어에선 상수 참이라 도달 불가였다).
#
# 뮤테이션 방증 — `LANE_MUT` 로 정의를 일부러 망가뜨리면 fail>0 이어야 한다(양방향):
#   LANE_MUT=loose : `A` 에 `agent-ready` 를 도로 넣는다(구 동작 = 너무 느슨)
#   LANE_MUT=tight : `A` 에서 `flow:verify` 를 뺀다(너무 조임 — 살아있는 검증 레인을 걷어냄)
# `bin/ci` 가 정상 1회 + 뮤테이션 2회를 돌려 뒤 둘이 **실제로 빨개지는지** 확인한다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KO="$DIR/skills/closeout/SKILL.md"
EN="$DIR/skills/closeout/SKILL.en.md"
MUT=${LANE_MUT:-}

pass=0
fail=0
check_eq() { # check_eq <이름> <기대> <실제>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  ✗ $1"; echo "    기대: [$2]"; echo "    실제: [$3]"
  fi
}
check_true() { # check_true <이름> <조건결과 0/1>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  ✗ $2 — $1"; fi
}

# ── 정의식 추출 ────────────────────────────────────────────────────────────
# ①-c 절만 잘라 한 줄로 편 뒤, 정의 표지 다음부터 닫는 `**` 앞까지를 취한다(bin/ci 의
# `lanew` 가드와 같은 관용구 — 절 전체를 훑으면 파생 설명의 라벨 이름이 정의를 대신해
# 초록으로 남는다).
sec_flat() { awk '/^## ①-c /{on=1} on && /^## / && !/^## ①-c /{exit} on' "$1" | tr '\n' ' '; }
sec_flat_en() { awk '/^## ①-c /{on=1} on && /^## / && !/^## ①-c /{exit} on' "$1" | tr '\n' ' '; }

# defexpr <flat> <표지> → 표지 뒤 ~ 닫는 `**` 앞
defexpr() { sed -n "s/.*$2//p" <<<"$1" | sed 's/\*\*.*//'; }
# labels_of <식> → 백틱 토큰만, 한 줄에 하나
labels_of() { grep -oE '`[^`]+`' <<<"$1" | tr -d '`' | sed 's/ *$//'; }

ko_flat=$(sec_flat "$KO")
en_flat=$(sec_flat_en "$EN")
[ -n "$ko_flat" ] || { echo "  ✗ SKILL.md 의 ①-c 절을 못 찾음"; exit 1; }
[ -n "$en_flat" ] || { echo "  ✗ SKILL.en.md 의 ①-c 절을 못 찾음"; exit 1; }

ko_a=$(defexpr "$ko_flat" '하류 활성 레인 라벨 `A` = ')
en_a=$(defexpr "$en_flat" 'Downstream active lane labels `A` = ')
ko_r=$(defexpr "$ko_flat" '재디스패치 목표 상태 `R` = ')
en_r=$(defexpr "$en_flat" 'Redispatch target state `R` = ')
for v in ko_a en_a ko_r en_r; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "  ✗ 정의식 '$v' 를 못 뽑았다 — SKILL 의 정의 표지가 바뀌었다"; exit 1; }
done

A_SET=$(labels_of "$ko_a" | sort -u | tr '\n' ' ')
A_SET_EN=$(labels_of "$en_a" | sort -u | tr '\n' ' ')
# R 은 `있음 ∧` / `present ∧` 로 존재부/부재부를 가른다.
ko_r_have=${ko_r%%있음 ∧*}; ko_r_none=${ko_r#*있음 ∧}
en_r_have=${en_r%%present ∧*}; en_r_none=${en_r#*present ∧}
R_HAVE=$(labels_of "$ko_r_have" | sort -u | tr '\n' ' ')
R_NONE=$(labels_of "$ko_r_none" | sort -u | tr '\n' ' ')
R_HAVE_EN=$(labels_of "$en_r_have" | sort -u | tr '\n' ' ')
R_NONE_EN=$(labels_of "$en_r_none" | sort -u | tr '\n' ' ')

# ── 뮤테이션 주입 ──────────────────────────────────────────────────────────
case "$MUT" in
  loose) A_SET="$A_SET agent-ready "; A_SET_EN="$A_SET_EN agent-ready " ;;
  tight) A_SET=${A_SET//flow:verify /}; A_SET_EN=${A_SET_EN//flow:verify /} ;;
  '') ;;
  *) echo "  ✗ 알 수 없는 LANE_MUT=[$MUT]"; exit 2 ;;
esac

echo "  A(ko) = [$A_SET]"
echo "  R.있음 = [$R_HAVE] · R.없음 = [$R_NONE]"

# ── ⑴⑵ 집합 자체 ──────────────────────────────────────────────────────────
# 전이 표 `closeout-redispatch` 행(이슈): add=agent-ready · remove=harvesting flow:ready
# flow:verify agent:claimed needs-human hold:*  — A 는 그중 **사다리 뒤 단계 넷**,
# R 은 add 있음 ∧ remove 전부 없음.
check_eq "A 집합 = 사다리 뒤 단계 넷(agent-ready 없음)" \
  "agent:claimed flow:ready flow:verify harvesting " "$A_SET"
check_eq "A 집합 — en 동문" "$A_SET" "$A_SET_EN"
case " $A_SET " in
  *" agent-ready "*) fail=$((fail + 1)); echo "  ✗ A 에 agent-ready 가 있다 — 사다리 내내 유지되는 자격 라벨이라 상수 참이고, ∨ 항에 상수가 하나만 있어도 술어 전체가 상수가 된다(#334 BLOCKER)" ;;
  *) pass=$((pass + 1)) ;;
esac
check_eq "R.있음 = agent-ready" "agent-ready " "$R_HAVE"
check_eq "R.없음 = remove 칸 전부" \
  "agent:claimed flow:ready flow:verify harvesting hold:* needs-human " "$R_NONE"
check_eq "R.있음 — en 동문" "$R_HAVE" "$R_HAVE_EN"
check_eq "R.없음 — en 동문" "$R_NONE" "$R_NONE_EN"

# ── 술어 평가기 ────────────────────────────────────────────────────────────
has() { # has <라벨목록(콤마)> <라벨>  — hold:* 는 접두 매칭
  local labels=",$1," want="$2"
  if [ "$want" = 'hold:*' ]; then
    case "$labels" in *",hold:"*) return 0 ;; *) return 1 ;; esac
  fi
  case "$labels" in *",$want,"*) return 0 ;; *) return 1 ;; esac
}
eval_A() { # eval_A <라벨목록> → 0=참
  local l
  for l in $A_SET; do has "$1" "$l" && return 0; done
  return 1
}
eval_R() { # eval_R <라벨목록> → 0=참
  local l
  for l in $R_HAVE; do has "$1" "$l" || return 1; done
  for l in $R_NONE; do has "$1" "$l" && return 1; done
  return 0
}
decide() { # decide <라벨목록> → untouched|recall  (분기 순서: A 먼저, 그다음 R)
  if eval_A "$1"; then echo untouched
  elif eval_R "$1"; then echo untouched
  else echo recall; fi
}
# 구 술어 — `agent-ready` 를 포함한 5항 ∨. 반증 기준선(고정 리터럴: 옛 정의의 기록이다).
decide_old() {
  local l
  for l in agent-ready agent:claimed flow:verify flow:ready harvesting; do
    has "$1" "$l" && { echo untouched; return; }
  done
  echo recall
}

# ── ⑶⑷ 픽스처 격자 ────────────────────────────────────────────────────────
# id | 이슈 라벨 | want(새 술어) | 격자 행
GRID='
landed|agent-ready|untouched|26
failed_hold|agent-ready,needs-human,hold:policy|recall|13
failed_hold_only|agent-ready,hold:policy|recall|13
verify_window|agent-ready,flow:verify|untouched|14
new_claim|agent-ready,agent:claimed|untouched|12
harvest|agent-ready,harvesting|untouched|12
ready|agent-ready,flow:ready|untouched|12
ar_removed|flow:ci|recall|27
bare|—|recall|27
'
echo "  ── 격자(새 술어 vs 구 술어) ──"
printf '  %-18s %-40s %-10s %-10s %s\n' id 라벨 want 새 구
while IFS='|' read -r id labels want row; do
  [ -n "$id" ] || continue
  [ "$labels" = '—' ] && labels=''
  got=$(decide "$labels")
  old=$(decide_old "$labels")
  printf '  %-18s %-40s %-10s %-10s %s\n' "$id" "${labels:-(없음)}" "$want" "$got" "$old"
  check_eq "격자 ${row}행 $id" "$want" "$got"
done <<< "$GRID"

# ⑶ **값이 갈린다** — 전이 섰음 vs 전이 실패에서 결정이 달라야 한다.
d_landed=$(decide 'agent-ready')
d_failed=$(decide 'agent-ready,needs-human,hold:policy')
if [ "$d_landed" != "$d_failed" ]; then
  pass=$((pass + 1))
  echo "  ✓ 값이 갈린다: 전이 섰음=[$d_landed] ≠ 전이 실패=[$d_failed]"
else
  fail=$((fail + 1))
  echo "  ✗ 값이 안 갈린다 — 전이 섰음·실패 두 상태에서 결정이 같다([$d_landed]). '조건을 넓혔다' 가 아니라 '값이 갈린다' 를 증명해야 한다(#334)"
fi
# 구 술어는 갈리지 않았다(반증 기준선) — 이 단언은 뮤테이션과 무관하게 항상 참이어야 한다.
o_landed=$(decide_old 'agent-ready')
o_failed=$(decide_old 'agent-ready,needs-human,hold:policy')
check_eq "구 술어는 전이 섰음에서 무접촉" "untouched" "$o_landed"
check_eq "구 술어는 전이 실패에서도 무접촉(=가르지 못했다)" "untouched" "$o_failed"

# ⑷ 도달 가능성 — 구 술어에서 상수 참이라 도달 불가였던 두 갈래.
#  · 격자 13행: `A` 거짓 ∧ `R` 거짓 → 전이 재호출
#  · 격자 10행/착수 판정 `r` 없음: 이슈 라벨이 `agent-ready` 뿐일 때 `A` 가 **거짓**이어야
#    3) 모호 경로에 도달한다(구 술어는 여기서 참이라 영원히 `active` 였다).
if eval_A 'agent-ready'; then
  fail=$((fail + 1))
  echo "  ✗ 착수 판정 'r 없음' 갈래: A(agent-ready 뿐)=참 — 격자 10행이 도달 불가다(#334 BLOCKER)"
else
  pass=$((pass + 1)); echo "  ✓ 격자 10행 도달 가능: A(agent-ready 뿐)=거짓"
fi
check_eq "격자 13행 도달 가능" "recall" "$(decide 'agent-ready,needs-human,hold:policy')"

# `A` 가 격자 위에서 상수가 아니다(상수면 어떤 입력도 못 가른다).
a_true=0; a_false=0
while IFS='|' read -r id labels want row; do
  [ -n "$id" ] || continue
  [ "$labels" = '—' ] && labels=''
  if eval_A "$labels"; then a_true=$((a_true + 1)); else a_false=$((a_false + 1)); fi
done <<< "$GRID"
if [ "$a_true" -gt 0 ] && [ "$a_false" -gt 0 ]; then
  pass=$((pass + 1)); echo "  ✓ A 는 상수가 아니다(참 $a_true · 거짓 $a_false)"
else
  fail=$((fail + 1)); echo "  ✗ A 가 격자 위에서 상수다(참 $a_true · 거짓 $a_false)"
fi

# 실행 비트 회귀 (#173 — 빠지면 exit 126 으로 조용히 degrade)
if [ -x "$0" ] || [ -x "$DIR/scripts/tests/closeout-lane-predicate.test.sh" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  ✗ closeout-lane-predicate.test.sh 실행 비트 없음"
fi

echo "closeout-lane-predicate.test${MUT:+ (LANE_MUT=$MUT)}: pass=$pass fail=$fail"
[ "$fail" = 0 ]
