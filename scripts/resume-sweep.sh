#!/usr/bin/env bash
# resume-sweep.sh — 사다리 검증에서 멈춘 이슈(needs-human + hold:ladder)를 창이 지나면
# 자동으로 재개한다. "사람이 '진행해' 를 치던 것을 틱이 대신 친다" (플랜 §4 · 원칙 4).
#
# 사용: resume-sweep.sh          (인자 없음)
#   스코프: 실행 cwd 의 `.loop/repos` 목록. 없으면 계정 전체(reconcile.sh 와 같은 규약 #40).
#   환경변수: RESUME_AFTER_MIN(기본 120) · LADDER_RESUME_LIMIT(기본 2)
#
# 출력(JSON lines):
#   resumed   — 라벨을 되돌려 재디스패치 가능 상태로. attempt = 이번이 몇 번째 재개인가.
#   escalated — 재개 상한 초과 → hold:policy 로 승격(needs-human 유지). 그때만 사람.
#   waiting   — 아직 창(RESUME_AFTER_MIN) 안. minutes = 마지막 갱신 후 경과 분.
#   warn      — 손대지 않은 사유(사유 라벨 부재 · 경합 · 조회/편집 실패 · readback 불일치).
#
# 상태 파일 없음 — 재개 횟수는 이슈 본문 마커 `<!-- ladder-resume: N -->` 가 SSOT 다
# (상태 = GitHub 위의 값. 로컬 카운터를 두면 머신이 바뀌는 순간 상한이 무의미해진다).
#
# 왜 `hold:ladder` 만 자동 재개하나 (플랜 갈림길 3): `hold:conflict`·`hold:policy` 는
# **사람이 결정해야 하는 것**이고, 사유 라벨이 아예 없는 needs-human 은 사람이 손으로
# 붙였을 수 있다 — 루프가 사람의 손을 떼는 일은 없어야 한다. 그래서 그 둘은 무편집.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RESUME_AFTER_MIN="${RESUME_AFTER_MIN:-120}"
LADDER_RESUME_LIMIT="${LADDER_RESUME_LIMIT:-2}"

# 사용자 확인은 공유 헬퍼(gh-login.sh) — REST /user 503 폴백·형식 검증·재시도는 그 안.
# 오염된 me 로 빈 스코프를 위장하지 않는다(fail-loud).
me=$("$SCRIPT_DIR/gh-login.sh") || me=""
if [ -z "$me" ]; then
  echo "resume-sweep: GitHub 사용자 확인 실패 (REST /user·GraphQL viewer 모두 응답 없음)" >&2
  exit 1
fi

tmp=$(mktemp -d) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  echo "resume-sweep: 임시 디렉터리 생성 실패 — 본문 갱신을 안전하게 못 하므로 중단" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# ── 스코프 레포 목록 ───────────────────────────────────────────────────────
# 파이프 대신 파일로 받는다 — `cmd | while` 은 서브셸이라 루프 안에서 올린 exit 상태가
# 밖으로 안 나온다(조회 실패의 fail-loud 가 조용히 삼켜진다).
scope_file="$PWD/.loop/repos"
repos_file="$tmp/repos"
if [ -f "$scope_file" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' > "$repos_file"
else
  # 부정 라벨(`-label:`)은 gh search CLI 가 오파싱하지만(#21) 단일 긍정 라벨은 정상 —
  # reconcile.sh 스윕의 레포 열거와 같은 형태다.
  gh search issues "label:needs-human" --owner "$me" --json repository \
    -q '.[].repository.nameWithOwner' 2>/dev/null | sort -u > "$repos_file"
fi

now_epoch=$(date -u +%s)

# RFC3339(UTC) → epoch. BSD(date -j -f) 우선, 실패하면 GNU(date -d).
to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

has_label() {  # has_label <콤마목록> <라벨>
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}

# 현재 라벨을 GitHub 에서 다시 읽는다. 조회 자체가 실패하면 exit 1(빈 목록과 구분).
read_labels() {  # read_labels <repo> <num>
  gh issue view "$2" --repo "$1" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null
}

emit_warn() {  # emit_warn <repo> <num> <msg>  — msg 는 이 파일이 쓰는 고정 문구(따옴표 없음)
  printf '{"event":"warn","repo":"%s","number":%s,"msg":"%s"}\n' "$1" "$2" "$3"
}

rc=0

# ── 이슈 1건 처리 ─────────────────────────────────────────────────────────
sweep_issue() {  # sweep_issue <repo> <이슈 JSON 한 줄>
  local repo="$1" row="$2"
  local num labels updated then_epoch elapsed attempts next cur back

  num=$(printf '%s' "$row" | jq -r '.number')
  labels=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")')
  updated=$(printf '%s' "$row" | jq -r '.updatedAt')

  # 사유 라벨이 하나도 없는 needs-human — 사람이 붙였을 수 있으니 **손대지 않고** 알린다.
  # (여기서 코멘트를 달면 updatedAt 이 갱신돼 자기가 자기 창을 밀어버린다 — 무편집이 규율.)
  if ! printf '%s' "$row" \
       | jq -e '[.labels[].name | select(startswith("hold:"))] | length > 0' >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "needs-human 사유 없음(hold:* 부재) — 사람이 붙였을 수 있어 자동 재개 안 함"
    return 0
  fi

  # hold:conflict·hold:policy 는 사람 몫 — 이벤트 없이 통과(플랜 갈림길 3).
  has_label "$labels" "hold:ladder" || return 0

  then_epoch=$(to_epoch "$updated")
  if [ -z "$then_epoch" ]; then
    emit_warn "$repo" "$num" "updatedAt 해석 불가($updated) — 창 판정 못 해 건드리지 않는다"
    return 0
  fi
  elapsed=$(( (now_epoch - then_epoch) / 60 ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  if [ "$elapsed" -lt "$RESUME_AFTER_MIN" ]; then
    # SKILL 은 이 이벤트를 보고하지 않지만(조용히 넘긴다) **내보내는 것 자체가 계약**이다 —
    # "창 안이라 안 건드렸다" 와 "대상이 아예 없었다" 를 구분하는 유일한 신호라, 사람이
    # 스윕을 손으로 돌려 디버깅할 때·앞으로 loop-status 가 세게 될 때 이 줄이 근거다.
    printf '{"event":"waiting","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$num" "$elapsed"
    return 0
  fi

  # ── 편집 직전 라벨 재조회(경합 가드) ───────────────────────────────────
  # 목록 조회와 편집 사이에 사람이 needs-human 을 뗐을 수 있다. 그 경우 편집은 **성공**
  # 하고(없는 라벨 제거는 no-op) 편집 후 readback 도 기대와 똑같아 보인다 — 사후
  # readback 만으로는 이 경합을 절대 구분 못 한다. 그래서 편집 **전에** 한 번 더 읽어
  # "아직 스윕 대상인가" 를 확인하고, 아니면 마커도 안 올리고 빠진다.
  cur=$(read_labels "$repo" "$num")
  if [ -z "$cur" ]; then
    emit_warn "$repo" "$num" "라벨 재조회 실패 — 경합 판별 불가라 이번 틱은 건드리지 않는다"
    return 0
  fi
  if ! has_label "$cur" "needs-human" || ! has_label "$cur" "hold:ladder"; then
    emit_warn "$repo" "$num" "재조회 시 needs-human·hold:ladder 가 이미 없다(사람 조작 경합) — 자동 재개 안 함"
    return 0
  fi

  # ── 재개 횟수 마커 ─────────────────────────────────────────────────────
  printf '%s' "$row" | jq -rj '.body // ""' > "$tmp/body.orig"
  attempts=$(grep -oE '<!--[[:space:]]*ladder-resume:[[:space:]]*[0-9]+[[:space:]]*-->' "$tmp/body.orig" 2>/dev/null \
    | grep -oE '[0-9]+' | tail -n1)
  [ -n "$attempts" ] || attempts=0
  next=$((attempts + 1))

  # ── 상한 초과 → hold:policy 승격 (needs-human 유지) ───────────────────
  if [ "$next" -gt "$LADDER_RESUME_LIMIT" ]; then
    if ! gh issue edit "$num" --repo "$repo" \
         --add-label "hold:policy" --remove-label "hold:ladder" >/dev/null 2>&1; then
      emit_warn "$repo" "$num" "상한 초과 승격 실패(라벨 편집) — 다음 틱 재시도"
      return 0
    fi
    gh issue comment "$num" --repo "$repo" \
      --body "재개 상한 초과($LADDER_RESUME_LIMIT) — 사람 판단 필요 <!-- bodat:worker -->" >/dev/null 2>&1 \
      || emit_warn "$repo" "$num" "승격 코멘트 실패(라벨은 반영됨)"
    back=$(read_labels "$repo" "$num")
    if [ -z "$back" ] || ! has_label "$back" "hold:policy" \
       || has_label "$back" "hold:ladder" || ! has_label "$back" "needs-human"; then
      emit_warn "$repo" "$num" "승격 readback 불일치(hold:policy·needs-human 유지·hold:ladder 해제 기대) — 사람 확인 필요"
      return 0
    fi
    # attempt 는 **본문 마커가 실제로 기록한 값**(소진한 재개 횟수)이다 — 거절된 next 가
    # 아니다. 승격에선 마커를 올리지 않으므로 next 를 실으면 GitHub 어디에도 대응하는
    # 숫자가 없는 값이 이벤트에만 떠돈다(합산하는 소비자는 승격마다 1씩 과다 계수한다).
    # "attempt/limit = 2/2" 로 읽혀 "상한을 다 썼다" 가 그대로 드러난다.
    printf '{"event":"escalated","repo":"%s","number":%s,"attempt":%s,"limit":%s}\n' \
      "$repo" "$num" "$attempts" "$LADDER_RESUME_LIMIT"
    return 0
  fi

  # ── 재개 ───────────────────────────────────────────────────────────────
  # 본문 마커(카운터)를 **먼저** 올린다. 라벨을 먼저 떼면 그 뒤 본문 갱신이 실패했을 때
  # "재개는 됐는데 횟수는 안 셌다" 가 되어 상한이 영영 안 걸린다(무한 재시도).
  # 반대 순서의 실패(마커만 오르고 라벨은 그대로)는 재개 한 번을 낭비할 뿐 폭주가 없다.
  if grep -qE '<!--[[:space:]]*ladder-resume:[[:space:]]*[0-9]+[[:space:]]*-->' "$tmp/body.orig" 2>/dev/null; then
    sed -E "s/<!--[[:space:]]*ladder-resume:[[:space:]]*[0-9]+[[:space:]]*-->/<!-- ladder-resume: $next -->/g" \
      "$tmp/body.orig" > "$tmp/body.new"
  else
    cp "$tmp/body.orig" "$tmp/body.new"
    printf '\n\n<!-- ladder-resume: %s -->\n' "$next" >> "$tmp/body.new"
  fi
  # 빈 파일을 --body-file 로 올리면 이슈 본문이 통째로 지워진다 — 올리기 전에 반드시 본다.
  if [ ! -s "$tmp/body.new" ]; then
    emit_warn "$repo" "$num" "갱신 본문이 비었다 — 본문 삭제 위험이라 중단"
    return 0
  fi
  if ! gh issue edit "$num" --repo "$repo" --body-file "$tmp/body.new" >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "본문 마커 갱신 실패 — 카운터 없이 재개하면 무한 재시도라 라벨을 그대로 둔다"
    return 0
  fi
  # agent-ready 는 건드리지 않는다 — 그게 재디스패치 자격이고, 재개는 그 앞을 막던
  # needs-human·hold:ladder 를 치우는 일이다.
  if ! gh issue edit "$num" --repo "$repo" \
       --remove-label "needs-human" --remove-label "hold:ladder" >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "라벨 해제 실패 — 마커는 이미 올랐다(다음 틱이 남은 횟수로 재시도)"
    return 0
  fi
  gh issue comment "$num" --repo "$repo" \
    --body "재개 $next/$LADDER_RESUME_LIMIT: 사다리 재시도 — <!-- bodat:worker -->" >/dev/null 2>&1 \
    || emit_warn "$repo" "$num" "재개 코멘트 실패(라벨은 반영됨)"

  back=$(read_labels "$repo" "$num")
  if [ -z "$back" ]; then
    emit_warn "$repo" "$num" "재개 readback 조회 실패 — 라벨 반영 여부 미상, 사람 확인 필요"
    return 0
  fi
  if has_label "$back" "needs-human" || has_label "$back" "hold:ladder"; then
    emit_warn "$repo" "$num" "재개 readback 불일치(needs-human·hold:ladder 가 남아 있다) — 사람 확인 필요"
    return 0
  fi
  printf '{"event":"resumed","repo":"%s","number":%s,"attempt":%s}\n' "$repo" "$num" "$next"
}

# ── 레포별 스윕 ───────────────────────────────────────────────────────────
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  issues=$(gh issue list --repo "$repo" --state open --label needs-human \
    --limit 200 --json number,labels,updatedAt,body 2>/dev/null)
  # 조회 실패를 "needs-human 이슈 없음" 과 구분 못 하면 멈춘 건이 조용히 영영 안 재개된다.
  if ! printf '%s' "$issues" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "resume-sweep: $repo needs-human 목록 조회 실패 — 이 레포는 건너뛴다" >&2
    rc=2
    continue
  fi
  printf '%s' "$issues" | jq -c '.[]' > "$tmp/issues" 2>/dev/null || : > "$tmp/issues"
  # fd 3 으로 읽는다 — 안에서 부르는 gh 가 stdin 을 건드리면 목록이 통째로 먹힌다.
  while IFS= read -r row <&3; do
    [ -n "$row" ] || continue
    sweep_issue "$repo" "$row"
  done 3< "$tmp/issues"
done < "$repos_file"

exit "$rc"
