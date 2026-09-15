#!/usr/bin/env bash
# 단계 11 — 라벨 축 정리(#245 label-taxonomy-cleanup)의 불변식: full-cycle 정의가 있고,
# 기존 라벨 정의가 **하나도 사라지지 않았다**. transition.sh 가 붙이는 라벨이 레포에
# 없으면 편집 전체가 실패하므로 삭제·이름변경은 이 축의 범위 밖이다.
#
# 실패 시: `  ✗ scripts/setup-labels.sh: … (#245)` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 620–642행 · 분류표 행 84 · 부행 84-a · #245 · #364 — 그리고 원
# 55–62행 · 분류표 행 7 · #281 의 다섯 라벨(harvesting·epic·verifying·flow:agent-ready·
# flow:claimed)을 #571 이 이 목록으로 흡수했다. 단계 40 은 은퇴):
#   • [setup-labels] 라벨 정의 존재 — full-cycle 추가·기존 라벨 정의 생존
#
# 100자 상한 축(84-c)은 scripts/tests/setup-labels.test.sh(#346), RESUME_AFTER_MIN 정의
# 축(84-b)은 ci/guards/single-definition.sh 로 갔다.
#
# 만료 조건: 스크립트가 `--add-label`/`--label` 로 쓰는 라벨 리터럴 추출이 전수가 되어
# (지금은 P0·P1·flow:ci·flow:codex 가 변수로 조립된다) 「소비되는 이름은 전부 정의가 있다」 를
# 소비자 파생 가드가 물 수 있을 때 — 그때 이 손 목록을 지운다. 이 목록이 라벨 이름의
# **유일한** 손 목록이다(#571) — 새 라벨을 붙이는 스크립트를 넣으면 여기 한 자리만 늘린다.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[setup-labels] 라벨 정의 존재 — full-cycle 추가·기존 라벨 정의 생존(전이·미러 라벨 포함 21종)·RESUME_AFTER_MIN 상수 (#245 · #364 · #281)"
# 플랜 4단계(label-taxonomy-cleanup). 스크립트가 읽는 것은 라벨 **이름**뿐이라
# 여기 남기는 것도 `gh label create <이름>` 정의의 존재다 — `--description` 문구 대조와
# README 라벨 표 행 검사, resume-sweep.sh 머리 주석 문구 대조는 #398 로 걷었다
# (그 문자열을 읽는 스크립트가 0 — 산문 드리프트는 리뷰 몫이다).
# ⑴ full-cycle — 지금까지 스크립트가 만들지 않아 새로 옵트인하는 레포에서 `--add-label
#    full-cycle` 편집이 통째로 실패했다(`transition.sh` 의 "레포에 없는 라벨" 계열).
grep -qF 'gh label create "full-cycle"' scripts/setup-labels.sh \
  || { echo "  ✗ scripts/setup-labels.sh: full-cycle 라벨 정의 누락 (#245)"; exit 1; }
# ⑵ 이 축 정리는 **추가와 설명 변경만** 한다 — 기존 라벨 정의가 하나라도 사라지면 빨강
#    (이름 변경·삭제는 다중 레포 마이그레이션이라 범위 밖이고, transition.sh 가 붙이는
#    라벨이 레포에 없으면 편집 전체가 실패한다).
#    예외 하나: `P2` 는 #401 이 축을 P0·P1 둘로 줄이며 **의도적으로** 목록에서 뺐다
#    (레포별 라벨 삭제는 여전히 데이터 작업이라 이 스크립트 밖이다 — 더 만들지 않을 뿐).
#    flow:agent-ready·flow:claimed(#281)는 PR 미러 앞 두 칸, verifying(#275)은 verify-runner
#    점유 라벨 — 정의가 없으면 transition.sh 의 반송 add 와 claim-issue.sh 의 미러 edit 이
#    레포에서 `not found` 로 실패한다(옛 단계 40 이 보던 다섯, #571 로 여기 합류).
for lbl in agent-ready agent:claimed needs-human P0 P1 harvesting epic verifying \
           flow:agent-ready flow:claimed flow:ci flow:verify flow:codex flow:ready \
           spinoff deploy-wait loop-dashboard hold:conflict hold:policy hold:ladder dup; do
  grep -qE "gh label create \"?${lbl}\"? " scripts/setup-labels.sh \
    || { echo "  ✗ scripts/setup-labels.sh: 기존 라벨 '$lbl' 정의가 사라짐 — 이 축 정리는 삭제·이름변경을 하지 않는다 (#245)"; exit 1; }
done
# ⑶ (#364) hold:ladder 설명이 가리키는 창 상수명은 resume-sweep.sh 의 실제 정의와 같은
#    철자여야 한다 — 상수를 개명하면 설명이 없는 이름을 가리킨다.
# (#427) 정의 자리는 `scripts/lib/constants.sh` 로 이사했다 — 철자 대조라는 취지는 그대로다.

