#!/usr/bin/env bash
# hold-resolve.sh <owner/repo> <pr> [<issue>|-]
#
# closeout ①-c 보류 해제 방향 판정의 **결정론 부분** (#334 · #198 재발행 · #174 흡수).
# 사람이 `needs-human`·`hold:*` 를 뗐다는 것은 "머지해도 좋다" 가 아니다 — 해제의 결론은
# 기각(원안 머지)과 시정(코드 수정) 둘인데 라벨 제거는 둘 다 같은 모양이고, 시정 쪽엔 안전망이
# 없었다(bodat PR #4989: 사람이 "고쳐라" 라고 한 코드를 다음 틱이 그대로 머지할 뻔). 이 스크립트는
# 코멘트 배열 인덱스·현재 라벨·head 시각만으로 **어느 갈래인지**를 정하고, 사람 산문의 방향
# (기각/시정/모호)을 읽는 것만 SKILL(LLM)에 남긴다 — 결정론은 스크립트, 판단은 산문(#443).
#
# ── 입력 ─────────────────────────────────────────────────────────────────────
#   PR·이슈 코멘트 배열 : `pr-comments.sh`(--paginate 안에 있음 — 첫 100건 상한 회피)
#   현재 라벨          : `gh issue view --json labels` · `gh pr view --json labels`
#   head 커밋 시각      : `pr-head-at.sh`
#   테스트 주입(finish-classify 와 같은 관행 — 네트워크 무접속):
#     HR_PR_COMMENTS_JSON · HR_ISSUE_COMMENTS_JSON  (`none` = 조회 실패)
#     HR_PR_LABELS · HR_ISSUE_LABELS               (콤마 목록 · `none` = 조회 실패)
#     HR_HEAD_AT                                   (ISO8601 · 빈 값 = 조회 실패)
#
# ── 코멘트 분류(토큰) — 각 출처의 배열 안에서 **마지막 매칭 인덱스**로 잰다 ─────────────
#   H 보류 경계   `마감 검증: ⚠ 보류`·`머지 판정: ⚠ 보류`·`Merge verdict: ⚠` 로 시작 ∨ `<!-- hold-note: ` 포함
#   R 반송 마커   `재디스패치: #` 로 시작 (①-c 시정·①-b stale_reverify 가 남긴다)
#   F 완결 판정   `머지 판정: ✅`·`마감 검증: ✅`·`Merge verdict: ✅` 로 시작 — **이 셋뿐**(🔄 는 완결 아님)
#   D 사람 결정문 `<!-- bodat:worker -->` 없음 ∨ `<!-- policy-review: resumed -->` 포함 (`kept` 는 아님)
#   인덱스로 재는 이유: GitHub 코멘트 시각은 초 단위라 동초 선후를 못 가린다(closeout-eligible 관용구).
#   경계는 출처마다 그 출처의 배열로 따로 구하고 **배열을 넘는 비교는 하지 않는다**(#334 사람 결정 ⓐ).
#
# ── 라벨 술어 ─────────────────────────────────────────────────────────────────
#   H = 이슈∪PR 에 `needs-human` ∨ `hold:*`               (사람이 들고 있다)
#   A = 이슈에 `agent:claimed`∨`flow:verify`∨`verifying`∨`flow:ready`∨`harvesting`  (하류 활성 레인 소유 —
#       transition.sh closeout-redispatch 행의 remove 칸 중 사다리 뒤 다섯. `agent-ready` 는 넣지 않는다:
#       어느 remove 칸에도 없어 상수 참이 되면 술어가 아무것도 못 가른다, #334 BLOCKER)
#   R = 이슈에 `agent-ready` ∧ A 의 다섯·`needs-human`·`hold:*` 전부 없음  (재디스패치 목표 상태 =
#       eligible-issues.sh 의 디스패치 자격과 같은 집합 — 참이면 다음 디스패치 틱이 집는다)
#
# ── 판정 순서(계약 — 뒤집지 마라: 해소 → 착수 → 멱등 → 결정문) ─────────────────────
#   0) PR·이슈 양쪽 경계 0            → H ? keep : pick             (보류가 없었다 — 라벨만 있으면 보류 유지)
#   1) 이슈측 단독 경계(PR 경계 0)     → H ? keep : restore          (r·f·D 무관 — 비교하지 않고 양측 경계 복구)
#   2) 해소: f > max(h, r)             → H ? keep : pick             (마커보다 이른 ✅ 는 반송 이전 코드의 판정)
#      F 가 `마감 검증: ✅ 기각 승계` 면 `resume: step2` 를 덧붙인다(③-1 재실행 금지 — 같은 P1 재생산)
#   3) 착수: head 시각 > max(h,r) 코멘트 시각(c)
#        조회 실패                     → blocked head_lookup         (값 없이 되돌리기 판단을 하지 않는다)
#        c ∧ r 있음                    → active                      (이 절이 되돌린 워커가 착수)
#        c ∧ r 없음 ∧ A               → active                      (그 레인이 들고 있다)
#        c ∧ r 없음 ∧ ¬A              → ambiguous new_commit        (반송 없는 새 커밋 — 사람에게)
#   4) 멱등: r > h (이 보류의 반송이 이미 나갔다)
#        연결 이슈 없음                → ambiguous no_issue
#        A                             → active                      (살아있는 레인 — 재호출 금지)
#        ¬A ∧ R                        → active                      (목표 상태 — 디스패처가 집는다)
#        ¬A ∧ ¬R                       → recall                      (마커 재발행 없이 전이만 재호출)
#   5) 결정문: D = 경계 뒤 결정문(PR ∪ 이슈, 각자 자기 경계 뒤)
#        H                             → keep                        (라벨이 남아 있다 — closeout-blocked 재호출 금지:
#                                                                     새 hold-note 가 경계를 결정문 뒤로 밀어 결정을 폐기한다)
#        D                             → direction + 후보 본문       (LLM 이 기각/시정/모호를 읽는다)
#        ¬D                            → ambiguous no_decision       (라벨만 뗐다)
#   조회 실패(코멘트·라벨)             → blocked <사유>               (상태 불변 — gh 일시 실패로 사람 게이트를 박지 않는다)
#
# ── 출력 ──────────────────────────────────────────────────────────────────────
#   stdout 1줄째: pick | keep | restore | active | recall | direction | ambiguous | blocked
#   이어지는 줄(있을 때만): `reason: <토큰>` · `resume: step2` · `pr_decision: <한 줄>` · `issue_decision: <한 줄>`
#   exit 0 (판정 있음) · 64 usage. 판정 실패는 exit 가 아니라 `blocked` 토큰이다 — 호출자가 ④ Report 에 올린다.
#
# macOS bash 3.2 대상(연관배열·mapfile 금지).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"

usage() { echo "usage: hold-resolve.sh <owner/repo> <pr> [<issue>|-]" >&2; }
repo=${1:-}; pr=${2:-}; issue=${3:--}
[ -n "$repo" ] && [ -n "$pr" ] || { usage; exit 64; }
case "$pr" in ''|*[!0-9]*) usage; exit 64 ;; esac
case "$issue" in -|'') issue=- ;; *[!0-9]*) usage; exit 64 ;; esac

blocked() { printf 'blocked\nreason: %s\n' "$1"; exit 0; }

# ── 입력 조회 ────────────────────────────────────────────────────────────────
fetch_comments() {  # fetch_comments <번호> <env 값|unset 표식>
  if [ "$2" != "__unset__" ]; then
    [ "$2" = none ] && return 1
    printf '%s' "$2"; return 0
  fi
  "$here/pr-comments.sh" "$repo" "$1"
}
pr_json=$(fetch_comments "$pr" "${HR_PR_COMMENTS_JSON-__unset__}") || blocked comments_lookup
issue_json='[]'
if [ "$issue" != - ]; then
  issue_json=$(fetch_comments "$issue" "${HR_ISSUE_COMMENTS_JSON-__unset__}") || blocked comments_lookup
fi

fetch_labels() {  # fetch_labels <issue|pr> <번호> <env 값|unset 표식> → 콤마 목록
  if [ "$3" != "__unset__" ]; then
    [ "$3" = none ] && return 1
    printf '%s' "$3"; return 0
  fi
  gh "$1" view "$2" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null
}
pr_labels=$(fetch_labels pr "$pr" "${HR_PR_LABELS-__unset__}") || blocked labels_lookup
issue_labels=''
if [ "$issue" != - ]; then
  issue_labels=$(fetch_labels issue "$issue" "${HR_ISSUE_LABELS-__unset__}") || blocked labels_lookup
fi

# ── 코멘트 분류 ──────────────────────────────────────────────────────────────
classify='
  def tok:
    if (.body | (startswith("마감 검증: ⚠ 보류") or startswith("머지 판정: ⚠ 보류")
                or startswith("Merge verdict: ⚠") or contains("<!-- hold-note: "))) then "H"
    elif (.body | startswith("재디스패치: #")) then "R"
    elif (.body | (startswith("머지 판정: ✅") or startswith("마감 검증: ✅") or startswith("Merge verdict: ✅"))) then "F"
    elif (.body | ((contains("<!-- bodat:worker -->") | not) or contains("<!-- policy-review: resumed -->"))) then "D"
    else "X" end;
  [ .[] | tok ] | join(",")'
pr_toks=$(printf '%s' "$pr_json" | jq -r "$classify" 2>/dev/null) || blocked comments_parse
is_toks=$(printf '%s' "$issue_json" | jq -r "$classify" 2>/dev/null) || blocked comments_parse

last_idx() {  # last_idx <토큰열> <토큰> → 마지막 매칭 인덱스, 없으면 -1
  local i=0 t found=-1
  [ -z "$1" ] && { echo -1; return; }
  IFS=',' read -r -a _toks <<<"$1"
  for t in "${_toks[@]}"; do [ "$t" = "$2" ] && found=$i; i=$((i + 1)); done
  echo "$found"
}
last_idx_after() {  # last_idx_after <토큰열> <토큰> <경계> → 경계 뒤 마지막 매칭, 없으면 -1
  local i=0 t found=-1
  [ -z "$1" ] && { echo -1; return; }
  IFS=',' read -r -a _toks <<<"$1"
  for t in "${_toks[@]}"; do [ "$t" = "$2" ] && [ "$i" -gt "$3" ] && found=$i; i=$((i + 1)); done
  echo "$found"
}
body_at() {  # body_at <json> <인덱스> → 본문을 한 줄로 접어(개행·탭 → 공백) 200자
  printf '%s' "$1" | jq -r --argjson i "$2" '.[$i].body // ""' | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-200
}
created_at() { printf '%s' "$1" | jq -r --argjson i "$2" '.[$i].createdAt // ""'; }
to_epoch() {  # ISO8601 Z → epoch (BSD/GNU) · 실패면 빈 값
  local s="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null || date -u -d "$s" +%s 2>/dev/null || true
}

has_label() {  # has_label <콤마 목록> <이름|접두*>
  local IFS=',' l pat="$2"
  for l in $1; do
    case "$pat" in
      *\*) case "$l" in "${pat%\*}"*) return 0 ;; esac ;;
      *)   [ "$l" = "$pat" ] && return 0 ;;
    esac
  done
  return 1
}
H=0; { has_label "$issue_labels" needs-human || has_label "$issue_labels" 'hold:*' \
    || has_label "$pr_labels" needs-human || has_label "$pr_labels" 'hold:*'; } && H=1
A=0; for l in agent:claimed flow:verify verifying flow:ready harvesting; do has_label "$issue_labels" "$l" && A=1; done
R=0
if [ "$issue" != - ] && has_label "$issue_labels" agent-ready && [ "$A" = 0 ] \
   && ! has_label "$issue_labels" needs-human && ! has_label "$issue_labels" 'hold:*'; then R=1; fi

h_pr=$(last_idx "$pr_toks" H); r_pr=$(last_idx "$pr_toks" R); f_pr=$(last_idx "$pr_toks" F)
h_is=$(last_idx "$is_toks" H)

keep_or() { [ "$H" = 1 ] && echo keep || echo "$1"; }

# 0) 양쪽 경계 0 — 보류가 없었다
if [ "$h_pr" -lt 0 ] && [ "$h_is" -lt 0 ]; then keep_or pick; exit 0; fi
# 1) 이슈측 단독 경계 — 비교하지 않는다(사람 결정 ⓐ)
if [ "$h_pr" -lt 0 ]; then keep_or restore; exit 0; fi

# 2) 해소 — PR 배열 안에서만
base=$h_pr; [ "$r_pr" -gt "$base" ] && base=$r_pr
if [ "$f_pr" -gt "$base" ]; then
  out=$(keep_or pick); echo "$out"
  if [ "$out" = pick ]; then
    case "$(body_at "$pr_json" "$f_pr")" in "마감 검증: ✅ 기각 승계"*) echo "resume: step2" ;; esac
  fi
  exit 0
fi

# 3) 착수 — head 시각 vs max(h, r) 코멘트 시각
if [ "${HR_HEAD_AT+set}" = set ]; then head_at="$HR_HEAD_AT"; else head_at=$("$here/pr-head-at.sh" "$repo" "$pr" 2>/dev/null) || head_at=""; fi
[ -n "$head_at" ] || blocked head_lookup
head_ep=$(to_epoch "$head_at"); base_ep=$(to_epoch "$(created_at "$pr_json" "$base")")
{ [ -n "$head_ep" ] && [ -n "$base_ep" ]; } || blocked head_lookup
if [ "$head_ep" -gt "$base_ep" ]; then
  if [ "$r_pr" -ge 0 ]; then echo active; exit 0; fi
  if [ "$issue" != - ] && [ "$A" = 1 ]; then echo active; exit 0; fi
  printf 'ambiguous\nreason: new_commit\n'; exit 0
fi

# 4) 멱등 — 이 보류의 반송이 이미 나갔다
if [ "$r_pr" -gt "$h_pr" ]; then
  [ "$issue" != - ] || { printf 'ambiguous\nreason: no_issue\n'; exit 0; }
  if [ "$A" = 1 ] || [ "$R" = 1 ]; then echo active; exit 0; fi
  echo recall; exit 0
fi

# 5) 결정문 ∧ 라벨 부재
d_pr=$(last_idx_after "$pr_toks" D "$h_pr")
d_is=-1; [ "$h_is" -ge 0 ] && d_is=$(last_idx_after "$is_toks" D "$h_is")
[ "$H" = 1 ] && { echo keep; exit 0; }
if [ "$d_pr" -ge 0 ] || [ "$d_is" -ge 0 ]; then
  echo direction
  [ "$d_pr" -ge 0 ] && printf 'pr_decision: %s\n' "$(body_at "$pr_json" "$d_pr")"
  [ "$d_is" -ge 0 ] && printf 'issue_decision: %s\n' "$(body_at "$issue_json" "$d_is")"
  exit 0
fi
printf 'ambiguous\nreason: no_decision\n'; exit 0
