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
#   ⑵ `A`·`R` 의 라벨 집합이 전이 표(`transition.sh:22` closeout-redispatch 행)와 일치한다.
#   ⑶ **값이 갈린다** — "전이 섰음" 픽스처와 "전이 실패(이슈측 편집 미적용)" 픽스처에서
#      분기 결정이 **다르다**. 구 술어(`agent-ready` 포함)에서는 둘이 **같았다**(=고친 게
#      아니라는 반증의 기준선). 구 술어 결정도 같은 격자에서 함께 계산해 나란히 찍는다.
#   ⑷ 격자 10·13행이 **도달 가능**하다(구 술어에선 상수 참이라 도달 불가였다).
#
#   ⑸ **연산자·극성도 정의식에서 읽는다** (attempt 2 P2). 라벨 집합만 뽑고 `A` 를 ∨ 로, `R` 을
#      "있음/없음" 으로 하드코딩하면 정의가 `∨`→`∧` 로 바뀌거나 극성이 뒤집혀도 격자가
#      초록이다 — 광고한 "의미 회귀 가드" 가 아니다. 그래서 정의식을 **토큰열**(라벨 · 연산자 ·
#      극성어)로 파싱해 평가기가 그 연산자·극성을 **그대로 실행**하고, 별도로 기대 연산자·극성을
#      명시 단언한다(`A` 는 ∨ 단일 연산자, `R` 은 `agent-ready` 있음 ∧ 나머지 없음).
#
# 뮤테이션 방증 — `LANE_MUT` 로 정의를 일부러 망가뜨리면 fail>0 이어야 한다(양방향 + 의미):
#   LANE_MUT=loose : `A` 에 `agent-ready` 를 도로 넣는다(구 동작 = 너무 느슨)
#   LANE_MUT=tight : `A` 에서 `flow:verify` 를 뺀다(너무 조임 — 살아있는 검증 레인을 걷어냄)
#   LANE_MUT=and   : `A` 의 연산자를 ∨ → ∧ 로 바꾼다(라벨 집합은 그대로 — 집합만 재면 못 잡는다)
#   LANE_MUT=flip  : `R` 의 극성을 뒤집는다(있음↔없음 — 라벨 집합은 그대로)
# `bin/ci` 가 정상 1회 + 뮤테이션 4회를 돌려 뒤 넷이 **실제로 fail>0 으로 끝나는지** 확인한다.
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
# tokens_of <식> → 토큰열, 한 줄에 하나: `L:<라벨>` · `OP:∨` · `OP:∧` · `POL:have` · `POL:none`.
# 라벨 사이의 `·`(같은 극성 묶음의 나열)는 연산자가 아니라 구분자라 토큰을 내지 않는다.
# 극성어는 한/영 둘 다 받는다(있음/present → have · 없음/absent → none). 그 밖의 산문은 버린다.
tokens_of() {
  grep -oE '`[^`]+`|∨|∧|있음|없음|present|absent' <<<"$1" \
    | sed -e 's/^`\(.*\)`$/L:\1/' -e 's/^∨$/OP:∨/' -e 's/^∧$/OP:∧/' \
          -e 's/^있음$/POL:have/' -e 's/^present$/POL:have/' \
          -e 's/^없음$/POL:none/' -e 's/^absent$/POL:none/'
}
# parse_or_and <토큰열> → 라벨들 사이의 연산자가 **한 종류**면 그 연산자를 찍고 0, 아니면 1.
#   `A` 는 라벨 ∨ 라벨 ∨ … 꼴이라 극성어가 없다. 연산자가 섞이거나 하나도 없으면 실패다.
parse_or_and() {
  local ops
  ops=$(grep '^OP:' <<<"$1" | sort -u)
  [ "$(wc -l <<<"$ops" | tr -d ' ')" = 1 ] && [ -n "$ops" ] || return 1
  sed 's/^OP://' <<<"$ops"
}
# parse_groups <토큰열> → `∧` 로 나뉜 묶음마다 `<극성>|<라벨>` 을 한 줄씩 찍는다(라벨마다 한 줄).
#   묶음 = 라벨 1개 이상 + 극성어 정확히 1개. 극성어가 없거나 둘이면 실패(1). `∨` 가 섞여도 실패.
parse_groups() {
  local line labels='' pol='' out='' l
  while IFS= read -r line; do
    case "$line" in
      L:*) labels="$labels ${line#L:}" ;;
      POL:*) [ -z "$pol" ] || return 1; pol=${line#POL:} ;;
      OP:∧)
        [ -n "$labels" ] && [ -n "$pol" ] || return 1
        for l in $labels; do out="$out$pol|$l"$'\n'; done
        labels=''; pol='' ;;
      OP:∨) return 1 ;;
    esac
  done <<<"$1"
  [ -n "$labels" ] && [ -n "$pol" ] || return 1
  for l in $labels; do out="$out$pol|$l"$'\n'; done
  printf '%s' "$out"
}

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
# ⑸ 연산자·극성은 하드코딩하지 않고 정의식에서 **파싱**한다 — 평가기가 이 값을 그대로 쓴다.
A_OP=$(parse_or_and "$(tokens_of "$ko_a")") || { echo "  ✗ A(ko) 정의식의 연산자를 못 읽었다(섞였거나 없음): [$ko_a]"; exit 1; }
A_OP_EN=$(parse_or_and "$(tokens_of "$en_a")") || { echo "  ✗ A(en) 정의식의 연산자를 못 읽었다(섞였거나 없음): [$en_a]"; exit 1; }
R_GROUPS=$(parse_groups "$(tokens_of "$ko_r")") || { echo "  ✗ R(ko) 정의식을 '극성 묶음 ∧ 극성 묶음' 으로 못 읽었다: [$ko_r]"; exit 1; }
R_GROUPS_EN=$(parse_groups "$(tokens_of "$en_r")") || { echo "  ✗ R(en) 정의식을 '극성 묶음 ∧ 극성 묶음' 으로 못 읽었다: [$en_r]"; exit 1; }
# 파생 집합(집합 단언용) — 극성별 라벨. 평가기는 이게 아니라 R_GROUPS 를 직접 돈다.
R_HAVE=$(awk -F'|' '$1=="have"{print $2}' <<<"$R_GROUPS" | sort -u | tr '\n' ' ')
R_NONE=$(awk -F'|' '$1=="none"{print $2}' <<<"$R_GROUPS" | sort -u | tr '\n' ' ')
R_HAVE_EN=$(awk -F'|' '$1=="have"{print $2}' <<<"$R_GROUPS_EN" | sort -u | tr '\n' ' ')
R_NONE_EN=$(awk -F'|' '$1=="none"{print $2}' <<<"$R_GROUPS_EN" | sort -u | tr '\n' ' ')

# ── 뮤테이션 주입 ──────────────────────────────────────────────────────────
case "$MUT" in
  loose) A_SET="$A_SET agent-ready "; A_SET_EN="$A_SET_EN agent-ready " ;;
  tight) A_SET=${A_SET//flow:verify /}; A_SET_EN=${A_SET_EN//flow:verify /} ;;
  and)   A_OP='∧'; A_OP_EN='∧' ;;
  flip)  R_GROUPS=$(sed -e 's/^have|/X|/' -e 's/^none|/have|/' -e 's/^X|/none|/' <<<"$R_GROUPS")
         R_GROUPS_EN=$(sed -e 's/^have|/X|/' -e 's/^none|/have|/' -e 's/^X|/none|/' <<<"$R_GROUPS_EN")
         R_HAVE=$(awk -F'|' '$1=="have"{print $2}' <<<"$R_GROUPS" | sort -u | tr '\n' ' ')
         R_NONE=$(awk -F'|' '$1=="none"{print $2}' <<<"$R_GROUPS" | sort -u | tr '\n' ' ')
         R_HAVE_EN=$(awk -F'|' '$1=="have"{print $2}' <<<"$R_GROUPS_EN" | sort -u | tr '\n' ' ')
         R_NONE_EN=$(awk -F'|' '$1=="none"{print $2}' <<<"$R_GROUPS_EN" | sort -u | tr '\n' ' ') ;;
  '') ;;
  *) echo "  ✗ 알 수 없는 LANE_MUT=[$MUT]"; exit 2 ;;
esac

echo "  A(ko) = [$A_SET] · 연산자 = [$A_OP]"
echo "  R.있음 = [$R_HAVE] · R.없음 = [$R_NONE]"

# ── ⑸ 연산자·극성 명시 단언 ──────────────────────────────────────────────
# 평가기가 정의식을 그대로 실행하므로, 정의가 `∧` 로 바뀌거나 극성이 뒤집히면 아래 격자도
# 빨개진다. 그래도 여기서 **따로** 단언하는 이유: 격자 실패는 "어느 칸이 틀렸다" 만 말하고
# "연산자가 바뀌었다" 는 원인을 안 말한다 — 원인 줄이 하나 있어야 사람이 한 번에 짚는다.
check_eq "A 의 연산자는 ∨ 하나(하류 레인 라벨 **하나라도** 있으면 참)" "∨" "$A_OP"
check_eq "A 의 연산자 — en 동문" "$A_OP" "$A_OP_EN"
check_eq "R 의 극성: agent-ready 만 '있음'" "have|agent-ready" \
  "$(grep '^have|' <<<"$R_GROUPS" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check_eq "R 의 극성: 나머지 일곱은 전부 '없음'(#275 verifying 포함)" \
  "none|agent:claimed none|flow:ready none|flow:verify none|harvesting none|hold:* none|needs-human none|verifying" \
  "$(grep '^none|' <<<"$R_GROUPS" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check_eq "R 의 극성 묶음 — en 동문" "$(sort -u <<<"$R_GROUPS")" "$(sort -u <<<"$R_GROUPS_EN")"

# ── ⑴⑵ 집합 자체 ──────────────────────────────────────────────────────────
# 전이 표 `closeout-redispatch` 행(이슈): add=agent-ready · remove=harvesting flow:ready
# flow:verify verifying agent:claimed needs-human hold:*  — A 는 그중 **사다리 뒤 단계 다섯**(#275 verifying 포함),
# R 은 add 있음 ∧ remove 전부 없음.
check_eq "A 집합 = 사다리 뒤 단계 다섯(agent-ready 없음 · #275 verifying 포함)" \
  "agent:claimed flow:ready flow:verify harvesting verifying " "$A_SET"
check_eq "A 집합 — en 동문" "$A_SET" "$A_SET_EN"
case " $A_SET " in
  *" agent-ready "*) fail=$((fail + 1)); echo "  ✗ A 에 agent-ready 가 있다 — 사다리 내내 유지되는 자격 라벨이라 상수 참이고, ∨ 항에 상수가 하나만 있어도 술어 전체가 상수가 된다(#334 BLOCKER)" ;;
  *) pass=$((pass + 1)) ;;
esac
check_eq "R.있음 = agent-ready" "agent-ready " "$R_HAVE"
check_eq "R.없음 = remove 칸 전부" \
  "agent:claimed flow:ready flow:verify harvesting hold:* needs-human verifying " "$R_NONE"
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
eval_A() { # eval_A <라벨목록> → 0=참 — 파싱한 연산자대로: ∨ 면 하나라도, ∧ 면 전부
  local l
  case "$A_OP" in
    ∨) for l in $A_SET; do has "$1" "$l" && return 0; done; return 1 ;;
    ∧) for l in $A_SET; do has "$1" "$l" || return 1; done; return 0 ;;
    *) echo "  ✗ eval_A: 알 수 없는 연산자 [$A_OP]"; exit 2 ;;
  esac
}
eval_R() { # eval_R <라벨목록> → 0=참 — 파싱한 극성 묶음을 ∧ 로 잇는다(have=있어야, none=없어야)
  local pol l
  while IFS='|' read -r pol l; do
    [ -n "$l" ] || continue
    case "$pol" in
      have) has "$1" "$l" || return 1 ;;
      none) has "$1" "$l" && return 1 ;;
      *) echo "  ✗ eval_R: 알 수 없는 극성 [$pol]"; exit 2 ;;
    esac
  done <<<"$R_GROUPS"
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
verifying_window|agent-ready,verifying|untouched|14
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
