#!/usr/bin/env bash
# 한/영 구조 동기화 가드 — bin/ci 인라인의 「[4/5] 한/영 SKILL 구조 동기화 검사」
# 블록을 통째로 옮긴 것 (분류표 Plans/ci-guard-classification.md L6 절 대상 행
# 5-a · 5-b, 원 이슈 없음 — 한/영 두 벌 체제가 생길 때부터의 계약).
#
# 무엇을 무는가 — 쌍 목록의 네 쌍(SKILL · loop-issues · closeout · 워커 템플릿)에서
#   ⑴ 쌍이 둘 다 존재하는가
#   ⑵ `## ` 헤더 개수가 같은가 (5-a)
#   ⑶ 헤더 제목은 번역되므로 언어 불변 마커(원형 숫자 ①②…)가 같은 위치에 있는가 (5-a)
#   ⑷ 워커 템플릿 쌍 한정 — `## ` 헤더가 없는 파일이라 절차 번호 줄(^N.) 개수가 같은가 (5-b)
# 한쪽만 고친 번역은 디스패처가 영문 프롬프트로 옛 절차를 읽게 만든다.
#
# ⓓ 축이 함께 왔다 — 워커 템플릿 placeholder 존재 검사(<WT_PATH> 등 6종, 디스패처
# 런타임 치환 계약)는 분류표에서 ⓓ(유지·대체물 없음)지만, 같은 `for pair` 루프 안
# `if [ "$ko" = "references/worker-template.md" ]` 아래에 중첩돼 있고 같은 `fail`
# 을 누적한다. 떼어내면 쌍 파일이 없을 때 건너뛰던 실패 모양이 달라지므로
# (동작 불변이 최우선) 블록째로 데려왔다. 검사 자체는 없애지 않았다.
#
# 실패 시 — 어느 쌍의 어느 축이 어긋났는지(개수·번째 헤더·placeholder 이름)를 찍고,
# 헤더 개수가 갈린 쌍은 양쪽 `## ` 헤더 목록을 줄번호와 함께 덤프한 뒤 exit 1.
#
# 만료 조건: 한/영 쌍이 없어지거나 번역 동기 검사기가 들어오면 지운다. placeholder
# 축은 워커 프롬프트 조립이 스크립트 인자로 옮겨질 때.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0
for pair in "SKILL.md:SKILL.en.md" "skills/loop-issues/SKILL.md:skills/loop-issues/SKILL.en.md" "skills/closeout/SKILL.md:skills/closeout/SKILL.en.md" "references/worker-template.md:references/worker-template.en.md"; do
  ko="${pair%%:*}"
  en="${pair#*:}"
  if [ ! -f "$ko" ] || [ ! -f "$en" ]; then
    echo "  ✗ 파일 누락: $ko ↔ $en 쌍이 모두 존재해야 한다"
    fail=1
    continue
  fi
  ko_count=$(grep -c '^## ' "$ko" || true)
  en_count=$(grep -c '^## ' "$en" || true)
  if [ "$ko_count" != "$en_count" ]; then
    echo "  ✗ 섹션 개수 불일치: $ko(${ko_count}개) vs $en(${en_count}개)"
    echo "    --- $ko"
    grep -n '^## ' "$ko" | sed 's/^/      /'
    echo "    --- $en"
    grep -n '^## ' "$en" | sed 's/^/      /'
    fail=1
    continue
  fi
  # 순서 검사: 헤더 제목은 번역되므로 텍스트 비교 불가 —
  # 언어 불변 마커(원형 숫자 ①②…)가 같은 위치에서 일치하는지 본다
  i=0
  while IFS=$'\t' read -r ko_h en_h; do
    i=$((i + 1))
    ko_mark=$(printf '%s\n' "$ko_h" | grep -o '[①②③④⑤⑥⑦⑧⑨⑩]' | head -1 || true)
    en_mark=$(printf '%s\n' "$en_h" | grep -o '[①②③④⑤⑥⑦⑧⑨⑩]' | head -1 || true)
    if [ "$ko_mark" != "$en_mark" ]; then
      echo "  ✗ 섹션 순서 불일치 (${i}번째 헤더): $ko '$ko_h' ↔ $en '$en_h'"
      fail=1
    fi
  done < <(paste <(grep '^## ' "$ko") <(grep '^## ' "$en"))
  # worker-template 쌍 한정: ## 헤더가 없는 파일이므로 절차 번호 줄(^N.) 개수도 검사
  if [ "$ko" = "references/worker-template.md" ]; then
    ko_steps=$(grep -c '^[0-9][0-9]*\.' "$ko" || true)
    en_steps=$(grep -c '^[0-9][0-9]*\.' "$en" || true)
    if [ "$ko_steps" != "$en_steps" ]; then
      echo "  ✗ 절차 번호 줄 개수 불일치: $ko(${ko_steps}개) vs $en(${en_steps}개)"
      fail=1
    fi
    # 필수 placeholder 존재 검사 — 디스패처가 런타임에 치환하는 계약
    # (<LESSONS_OR_ 는 언어별 접미사("없음"/"none")가 달라 접두만 본다)
    for ph in '<WT_PATH>' '<REPO>' '<NUM>' '<TITLE>' '<DEFAULT_BRANCH>' '<LESSONS_OR_'; do
      for f in "$ko" "$en"; do
        if ! grep -qF "$ph" "$f"; then
          echo "  ✗ 필수 placeholder 누락: $f 에 $ph 없음"
          fail=1
        fi
      done
    done
  fi
done
[ "$fail" = 0 ] || exit 1
