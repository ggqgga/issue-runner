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
#   warn      — **아무것도 안 건드린** 채 넘긴 사유(사유 라벨 부재 · 경합 · 첫 쓰기 실패).
#   warn_after_edit — 쓰기가 **이미 반영된 뒤** 후속 단계가 실패했다(라벨·PR 미러·readback).
#               warn 과 섞으면 "손대지 않았다" 가 거짓이 되어, 보고를 읽는 쪽이 GitHub 상태를
#               되짚어야 할 때(사람 확인)와 그냥 다음 틱을 기다리면 될 때를 못 가른다.
#   note      — **아무것도 안 건드린** 정보 줄. warn 과 달리 조치할 것이 **없는** 정상 상태다
#               (배포 대기 이슈의 사유 없는 needs-human). 버리지 않고 남기는 이유는 emit_note 주석.
#
# 상태 파일 없음 — 재개 횟수는 **이슈 코멘트에 붙은 마커**(`<!-- ladder-resume: N -->`)의
# 개수가 SSOT 다. 재개 코멘트가 자기 마커를 품으므로 카운터와 알림이 한 번의 append 로 끝나고,
# 본문은 **읽지도 쓰지도 않는다** — `--body-file` 은 본문 전체를 다시 올리는 일이라, 그 사이
# 사람이 쓴 글을 통째로 덮어쓸 수 있었다(마커 한 줄 때문에 남의 글이 사라지는 경로).
# append-only 라 경합에 안전하고, 상태 = 값의 존재라는 레포 규약과도 같은 모양이다.
#
# 왜 `hold:ladder` 만 자동 재개하나 (플랜 갈림길 3): `hold:conflict`·`hold:policy` 는
# **사람이 결정해야 하는 것**이고, 사유 라벨이 아예 없는 needs-human 은 사람이 손으로
# 붙였을 수 있다 — 루프가 사람의 손을 떼는 일은 없어야 한다. 그래서 그 둘은 무편집.
#
# PR 미러: `transition.sh verify-held`·`closeout-blocked` 는 정지 라벨을 이슈와 **PR 양쪽**에
# 붙인다. 이슈만 되돌리면 PR 은 영구 사람대기로 남고, 뒤 전이(handoff-verify·verify-pass·
# closeout-pick)는 그 라벨을 떼지 않아 사람이 손으로 지워야 흐른다. 그래서 재개·승격은
# 연결된 열린 PR 의 같은 라벨까지 **같은 단계에서** 함께 되돌린다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RESUME_AFTER_MIN="${RESUME_AFTER_MIN:-120}"
LADDER_RESUME_LIMIT="${LADDER_RESUME_LIMIT:-2}"
# 목록·탐색 조회 상한. 기본 200 — 기본 limit(30)은 조용히 잘라 그 이슈들이 영영 안 보인다.
# 테스트가 상한 도달 경로를 200건짜리 픽스처 없이 재현하도록 env 로 낮출 수 있게 열어 뒀다
# (운영에서 내리는 값이 아니다 — 내리면 그만큼 잘린다. 잘림 자체는 warn 으로 드러난다).
LIST_LIMIT="${RESUME_LIST_LIMIT:-1000}"   # gh issue list 가 내부 페이지네이션(100/페이지)으로 채운다 — #151

# 값 검증은 **모든 GitHub 호출 앞**에 둔다. `[ "$x" -lt "$y" ]` 는 정수가 아니면 bash 가
# 에러를 내고 거짓으로 떨어지는데, set -e 가 아니라 그대로 흘러 "창이 지났다"·"상한을
# 안 넘었다" 로 오판한다 — 오타 하나(RESUME_AFTER_MIN=120m)가 전 이슈 즉시 재개가 된다.
_nonneg_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ! _nonneg_int "$RESUME_AFTER_MIN"; then
  echo "resume-sweep: RESUME_AFTER_MIN 은 음이 아닌 정수여야 한다 (받은 값: '$RESUME_AFTER_MIN')" >&2
  exit 64
fi
if ! _nonneg_int "$LADDER_RESUME_LIMIT"; then
  echo "resume-sweep: LADDER_RESUME_LIMIT 은 음이 아닌 정수여야 한다 (받은 값: '$LADDER_RESUME_LIMIT')" >&2
  exit 64
fi
if ! _nonneg_int "$LIST_LIMIT" || [ "$LIST_LIMIT" -lt 1 ]; then
  echo "resume-sweep: RESUME_LIST_LIMIT 은 1 이상의 정수여야 한다 (받은 값: '$LIST_LIMIT')" >&2
  exit 64
fi

# 사용자 확인은 공유 헬퍼(gh-login.sh) — REST /user 503 폴백·형식 검증·재시도는 그 안.
# 오염된 me 로 빈 스코프를 위장하지 않는다(fail-loud).
me=$("$SCRIPT_DIR/gh-login.sh") || me=""
if [ -z "$me" ]; then
  echo "resume-sweep: GitHub 사용자 확인 실패 (REST /user·GraphQL viewer 모두 응답 없음)" >&2
  exit 1
fi

tmp=$(mktemp -d) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  echo "resume-sweep: 임시 디렉터리 생성 실패 — 조회 결과를 못 받으므로 중단" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT

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

# `number` 는 따옴표 **밖**의 %s 라, 값이 비거나 정수가 아니면 `{…,"number":,…}` 가 나가
# 줄 전체가 JSON 이 아니게 된다(#193). 그 줄은 관대한 파서에선 통째로 유실되고 엄격한
# 파서에선 읽기를 멈춘다 — 어느 쪽이든 **경보가 조용히 사라지는** 방향이다. 그래서:
#   · 줄은 **반드시 나간다** — 번호를 못 구했다고 경보를 버리면 고치려던 것을 그대로 재현한다.
#   · 번호는 `0` 으로 낮춘다 — "특정 이슈가 아니다" 라는 뜻으로 레포 단위 경보가 이미 쓰는 값.
#   · `0` 만으로는 그 레포 단위 경보와 구분이 안 되니, 못 구했다는 사실을 msg **끝에** 덧붙인다.
#     기존 문구는 접두로 한 바이트도 안 바뀌어 남는다 — 디스패처 SKILL.md 가 문구로 분기한다.
# 세 헬퍼가 **같은 규칙**을 따르도록 방출을 한 곳(_emit)으로 모은다 — 한 헬퍼만 고치면
# 나머지 둘이 같은 모양으로 남는다.
NUM_UNKNOWN_SUFFIX=' [이슈 번호 미상 — 목록 행 파싱 실패]'
_emit() {  # _emit <event> <repo> <num> <msg>
  local num="$3" msg="$4"
  if ! _nonneg_int "$num"; then
    msg="$msg$NUM_UNKNOWN_SUFFIX"
    num=0
  fi
  printf '{"event":"%s","repo":"%s","number":%s,"msg":"%s"}\n' "$1" "$2" "$num" "$msg"
}

emit_warn() {  # emit_warn <repo> <num> <msg> — msg 는 이 파일이 쓰는 고정 문구(따옴표 없음)
  _emit warn "$1" "$2" "$3"
}

# 쓰기가 이미 GitHub 에 반영된 뒤의 실패. warn 과 나누는 이유는 대응이 다르기 때문이다 —
# warn 은 "그대로 두면 다음 틱이 다시 본다", 이건 "상태가 반쯤 바뀌었으니 사람이 본다".
emit_warn_after_edit() {  # emit_warn_after_edit <repo> <num> <msg>
  _emit warn_after_edit "$1" "$2" "$3"
}

# 조치할 것이 **없는** 정보 줄. warn 의 정의를 "루프가 교정 가능한 불변식 위반" 으로 좁히고
# (형제 이슈 #188 이 loop-status.sh 에서 정한 정의) 거기서 빠지는 건을 여기로 내린다.
# 그냥 빼지 않는 이유: 관측에서 통째로 사라지면 그 자체가 다른 사각지대가 된다.
# msg 는 이 파일이 쓰는 고정 문구다 — 라벨 이름을 끼워 넣지만 그 값은 아래 ② 가 고르는
# **jq 문자열 리터럴 두 개("deploy-wait"·"full-cycle") 중 하나**이지 GitHub 에서 온 텍스트가
# 아니다. 따옴표·개행이 못 들어오므로 printf JSON 포맷 계약이 깨질 경로가 없다.
emit_note() {  # emit_note <repo> <num> <msg>
  _emit note "$1" "$2" "$3"
}

# ── GitHub 읽기 헬퍼 — 전부 **조회 실패는 rc 1** ──────────────────────────
# 빈 값을 실패로 치면 "라벨이 0개인 이슈"·"코멘트가 0개인 이슈" 같은 정상 결과가
# 영영 조회 실패로 오분류된다. 값이 아니라 rc 로 가른다.
read_labels() {  # read_labels <repo> <num> — 이슈 라벨 콤마목록
  local out
  out=$(gh issue view "$2" --repo "$1" --json labels 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# 편집 직전 재조회 — 라벨과 updatedAt 을 한 번에. 본문은 더 이상 읽지 않는다(마커=코멘트).
read_state() {  # read_state <repo> <num> <updatedAt 저장파일> — 라벨 콤마목록을 stdout
  local out
  out=$(gh issue view "$2" --repo "$1" --json labels,updatedAt 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.updatedAt // ""' > "$3" || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# 재개 횟수 = 마커를 품은 코멘트의 **개수**. 창을 넘긴 후보에만 부른다(코멘트 조회는
# 이슈당 한 번의 왕복이라, 대기 중인 건까지 훑으면 틱마다 큰 레포를 헛돈다).
count_markers() {  # count_markers <repo> <num>
  local out
  out=$(gh issue view "$2" --repo "$1" --json comments 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" \
    | jq '[.comments[]? | select(.body | test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
}

# 연결된 **열린** PR 들 — "<번호><TAB><라벨 콤마목록>" 줄. 없으면 빈 출력(정상).
list_mirror_prs() {  # list_mirror_prs <repo> <num>
  local out
  out=$(gh pr list --repo "$1" --state open --head "agent/issue-$2" \
    --json number,labels --limit 20 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.[] | [(.number|tostring), ([.labels[].name] | join(","))] | @tsv'
}

read_pr_labels() {  # read_pr_labels <repo> <pr>
  local out
  out=$(gh pr view "$2" --repo "$1" --json labels 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '[.labels[].name] | join(",")'
}

# ── PR 미러 해제 — 이슈 편집과 **같은 단계**에서 ──────────────────────────
# 이미 이슈 라벨을 고친 뒤에 부르므로 여기서의 실패는 전부 warn_after_edit 이다.
# 라벨을 하나도 안 달고 있는 PR 은 건드리지 않는다 — 레포에 없는 라벨을 remove 하면
# gh 가 편집 **전체**를 실패시키므로(실측), 불필요한 편집은 애초에 안 낸다.
mirror_labels() {  # mirror_labels <repo> <num> <resume|escalate>
  local repo="$1" num="$2" mode="$3" prs prnum prlabels back
  if ! prs=$(list_mirror_prs "$repo" "$num"); then
    emit_warn_after_edit "$repo" "$num" "연결 PR 조회 실패 — 이슈는 반영됐지만 PR 미러 라벨이 남았을 수 있다"
    return 0
  fi
  [ -n "$prs" ] || return 0   # 연결된 열린 PR 없음 = 정상(이슈만 고치면 된다)
  printf '%s\n' "$prs" | while IFS=$'\t' read -r prnum prlabels; do
    [ -n "$prnum" ] || continue
    if [ "$mode" = resume ]; then
      has_label "$prlabels" "needs-human" || has_label "$prlabels" "hold:ladder" || continue
      if ! gh pr edit "$prnum" --repo "$repo" \
           --remove-label "needs-human" --remove-label "hold:ladder" >/dev/null 2>&1; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 라벨 해제 실패 — PR 이 사람대기로 남는다"
        continue
      fi
      if ! back=$(read_pr_labels "$repo" "$prnum"); then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 조회 실패 — 반영 여부 미상"
        continue
      fi
      if has_label "$back" "needs-human" || has_label "$back" "hold:ladder"; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 불일치(정지 라벨이 남아 있다)"
      fi
    else
      has_label "$prlabels" "hold:ladder" || continue
      if ! gh pr edit "$prnum" --repo "$repo" \
           --add-label "hold:policy" --remove-label "hold:ladder" >/dev/null 2>&1; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 승격 실패 — PR 사유 라벨이 이슈와 어긋난다"
        continue
      fi
      if ! back=$(read_pr_labels "$repo" "$prnum"); then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 조회 실패 — 반영 여부 미상"
        continue
      fi
      if ! has_label "$back" "hold:policy" || has_label "$back" "hold:ladder"; then
        emit_warn_after_edit "$repo" "$num" "PR #$prnum 미러 readback 불일치(hold:policy 부착·hold:ladder 해제 기대)"
      fi
    fi
  done
}

rc=0

# ── 이슈 1건 처리 (재개 대상 = needs-human ∧ hold:ladder) ─────────────────
sweep_issue() {  # sweep_issue <repo> <이슈 JSON 한 줄>
  local repo="$1" row="$2"
  local num updated row_tsv then_epoch elapsed attempts next cur back live_updated

  # 한 번의 jq 로 둘 다 뽑는다 — 큰 레포에선 이 함수가 이슈 수만큼 돌아, 필드마다
  # 프로세스를 띄우면 조회보다 파싱이 더 비싸진다.
  row_tsv=$(printf '%s' "$row" | jq -r '[(.number|tostring), (.updatedAt // "")] | @tsv')
  num=${row_tsv%%$'\t'*}
  updated=${row_tsv#*$'\t'}

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

  # ── 편집 직전 재조회(경합 가드) ───────────────────────────────────────
  # 목록 조회와 편집 사이에 사람이 needs-human 을 뗐을 수 있다. 그 경우 편집은 **성공**
  # 하고(없는 라벨 제거는 no-op) 편집 후 readback 도 기대와 똑같아 보인다 — 사후
  # readback 만으로는 이 경합을 절대 구분 못 한다. 그래서 편집 **전에** 한 번 더 읽는다.
  if ! cur=$(read_state "$repo" "$num" "$tmp/updated.live"); then
    emit_warn "$repo" "$num" "재조회 실패(라벨·updatedAt) — 경합 판별 불가라 건드리지 않는다"
    return 0
  fi
  if ! has_label "$cur" "needs-human" || ! has_label "$cur" "hold:ladder"; then
    emit_warn "$repo" "$num" "재조회 시 needs-human·hold:ladder 가 이미 없다(사람 조작 경합) — 자동 재개 안 함"
    return 0
  fi
  # `hold:ladder` 옆에 사람 몫 사유가 함께 붙어 있으면 자동 재개 대상이 아니다 — 사다리는
  # 재시도로 풀려도 conflict·policy 는 안 풀리는데, 라벨을 떼면 그 사람 몫이 조용히 사라진다.
  if has_label "$cur" "hold:policy" || has_label "$cur" "hold:conflict"; then
    emit_warn "$repo" "$num" "hold:ladder 외 사람 몫 hold:* 동존 — 자동 재개 안 함"
    return 0
  fi
  # 창 재판정 — 스냅샷 이후 사람이 이슈를 건드렸으면 그 시각이 새 기준이다(스펙의 시계는
  # "마지막 갱신" 이지 "우리가 목록을 뜬 시각" 이 아니다).
  live_updated=$(cat "$tmp/updated.live" 2>/dev/null)
  if [ -n "$live_updated" ] && [ "$live_updated" != "$updated" ]; then
    then_epoch=$(to_epoch "$live_updated")
    if [ -n "$then_epoch" ]; then
      elapsed=$(( (now_epoch - then_epoch) / 60 ))
      [ "$elapsed" -lt 0 ] && elapsed=0
      if [ "$elapsed" -lt "$RESUME_AFTER_MIN" ]; then
        printf '{"event":"waiting","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$num" "$elapsed"
        return 0
      fi
    fi
  fi

  # ── 재개 횟수 = 마커 코멘트 개수 ──────────────────────────────────────
  if ! attempts=$(count_markers "$repo" "$num"); then
    emit_warn "$repo" "$num" "코멘트 조회 실패 — 재개 횟수를 못 세 상한을 지킬 수 없어 건드리지 않는다"
    return 0
  fi
  _nonneg_int "$attempts" || attempts=0
  next=$((attempts + 1))

  # ── 상한 초과 → hold:policy 승격 (needs-human 유지) ───────────────────
  if [ "$next" -gt "$LADDER_RESUME_LIMIT" ]; then
    if ! gh issue edit "$num" --repo "$repo" \
         --add-label "hold:policy" --remove-label "hold:ladder" >/dev/null 2>&1; then
      emit_warn "$repo" "$num" "상한 초과 승격 실패(라벨 편집) — 다음 틱 재시도"
      return 0
    fi
    mirror_labels "$repo" "$num" escalate
    # 승격 코멘트에는 마커를 넣지 않는다 — 넣으면 재개 횟수가 스스로 부풀어 오른다.
    gh issue comment "$num" --repo "$repo" \
      --body "사람 확인(policy): 사다리 재개 상한($LADDER_RESUME_LIMIT) 초과 — 마지막 재개 코멘트의 실패 출력을 읽고, 사다리 밖 통로(직접 조작·스펙 변경)가 필요한지 답하라 <!-- hold-note: policy --><!-- bodat:worker -->" >/dev/null 2>&1 \
      || emit_warn_after_edit "$repo" "$num" "승격 코멘트 실패(라벨은 이미 반영됨)"
    if ! back=$(read_labels "$repo" "$num"); then
      emit_warn_after_edit "$repo" "$num" "승격 readback 조회 실패 — 라벨 반영 여부 미상, 사람 확인 필요"
      return 0
    fi
    if ! has_label "$back" "hold:policy" \
       || has_label "$back" "hold:ladder" || ! has_label "$back" "needs-human"; then
      emit_warn_after_edit "$repo" "$num" "승격 readback 불일치(hold:policy·needs-human 유지·hold:ladder 해제 기대) — 사람 확인 필요"
      return 0
    fi
    # attempt 는 **마커가 실제로 기록한 값**(소진한 재개 횟수)이다 — 거절된 next 가 아니다.
    # 승격에선 마커를 안 남기므로 next 를 실으면 GitHub 어디에도 대응하는 숫자가 없는 값이
    # 이벤트에만 떠돈다(합산하는 소비자는 승격마다 1씩 과다 계수한다).
    printf '{"event":"escalated","repo":"%s","number":%s,"attempt":%s,"limit":%s}\n' \
      "$repo" "$num" "$attempts" "$LADDER_RESUME_LIMIT"
    return 0
  fi

  # ── 재개 ───────────────────────────────────────────────────────────────
  # 마커 코멘트를 **먼저** 남기고 그다음 라벨을 뗀다. 라벨을 먼저 떼면 그 뒤 코멘트가
  # 실패했을 때 "재개는 됐는데 횟수는 안 셌다" 가 되어 상한이 영영 안 걸린다(무한 재시도).
  # 반대 순서의 실패(마커만 남고 라벨은 그대로)는 재개 한 번을 낭비할 뿐 폭주가 없다.
  if ! gh issue comment "$num" --repo "$repo" \
       --body "재개 $next/$LADDER_RESUME_LIMIT: 사다리 재시도 — <!-- ladder-resume: $next --><!-- bodat:worker -->" \
       >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "재개 마커 코멘트 실패 — 카운터 없이 재개하면 무한 재시도라 라벨을 그대로 둔다"
    return 0
  fi
  # agent-ready 는 건드리지 않는다 — 그게 재디스패치 자격이고, 재개는 그 앞을 막던
  # needs-human·hold:ladder 를 치우는 일이다.
  if ! gh issue edit "$num" --repo "$repo" \
       --remove-label "needs-human" --remove-label "hold:ladder" >/dev/null 2>&1; then
    emit_warn_after_edit "$repo" "$num" "라벨 해제 실패 — 마커는 이미 남았다(다음 틱이 남은 횟수로 재시도)"
    return 0
  fi
  mirror_labels "$repo" "$num" resume

  # 라벨이 0개로 돌아오는 것은 **성공**이다(둘 다 떨어진 이슈). rc 로만 실패를 가른다.
  if ! back=$(read_labels "$repo" "$num"); then
    emit_warn_after_edit "$repo" "$num" "재개 readback 조회 실패 — 라벨 반영 여부 미상, 사람 확인 필요"
    return 0
  fi
  if has_label "$back" "needs-human" || has_label "$back" "hold:ladder"; then
    emit_warn_after_edit "$repo" "$num" "재개 readback 불일치(needs-human·hold:ladder 가 남아 있다) — 사람 확인 필요"
    return 0
  fi
  printf '{"event":"resumed","repo":"%s","number":%s,"attempt":%s}\n' "$repo" "$num" "$next"
}

# ── 스코프 레포 목록 ───────────────────────────────────────────────────────
# 파이프 대신 파일로 받는다 — `cmd | while` 은 서브셸이라 루프 안에서 올린 exit 상태가
# 밖으로 안 나온다(조회 실패의 fail-loud 가 조용히 삼켜진다).
scope_file="$PWD/.loop/repos"
repos_file="$tmp/repos"
if [ -f "$scope_file" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' > "$repos_file"
else
  # 부정 라벨(`-label:`)은 gh search CLI 가 오파싱하지만(#21) 단일 긍정 라벨은 정상 —
  # reconcile.sh 스윕의 레포 열거와 같은 형태다. 다만 여기선 두 가지를 더 조인다:
  #   · `is:open is:issue` — 닫힌 이슈·PR 이 창을 채우면 진짜 대상 레포가 밀려난다.
  #   · `--limit 200` — 기본 limit(30)은 조용히 잘라내 그 레포들이 영영 안 스윕된다.
  if ! gh search issues "label:needs-human is:open is:issue" --owner "$me" --limit "$LIST_LIMIT" \
       --json repository -q '.[].repository.nameWithOwner' > "$tmp/search.raw" 2>/dev/null; then
    echo "resume-sweep: 계정 전체 needs-human 탐색 실패 — 스코프를 못 정해 중단(빈 목록과 구분)" >&2
    exit 2
  fi
  search_hits=$(grep -c . "$tmp/search.raw" || true)
  sort -u "$tmp/search.raw" > "$repos_file"
  # 상한에 정확히 닿았으면 잘렸을 수 있다 — 조용히 지나가면 "그 레포엔 멈춘 건이 없다" 로
  # 위장된다. repo 는 특정 레포가 아니라는 뜻으로 `*`.
  if [ "${search_hits:-0}" -ge "$LIST_LIMIT" ]; then
    printf '{"event":"warn","repo":"*","number":0,"msg":"탐색 상한 도달(%s) — 일부 레포가 누락됐을 수 있다. .loop/repos 로 스코프를 좁혀라"}\n' "$LIST_LIMIT"
  fi
fi

# fetch_issues <repo> <출력파일> <쿼리이름> <gh 추가인자…> — 성공 0 / 조회 실패 1.
# 상한에 닿으면 warn 을 낸다(잘린 나머지가 "없음" 으로 위장되지 않게).
fetch_issues() {
  local repo="$1" out="$2" qname="$3"
  shift 3
  local body count
  body=$(gh issue list --repo "$repo" --state open "$@" \
    --limit "$LIST_LIMIT" --json number,labels,updatedAt 2>/dev/null)
  # 조회 실패를 "해당 이슈 없음" 과 구분 못 하면 멈춘 건이 조용히 영영 안 재개된다.
  printf '%s' "$body" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$body" | jq 'length')
  if [ "${count:-0}" -ge "$LIST_LIMIT" ]; then
    printf '{"event":"warn","repo":"%s","number":0,"msg":"목록 상한 도달(%s) — 잘린 이슈는 이번 틱에 안 보인다"}\n' \
      "$repo" "$qname"
  fi
  printf '%s' "$body" | jq -c '.[]' > "$out" 2>/dev/null || : > "$out"
  return 0
}

# ── 레포별 스윕 ───────────────────────────────────────────────────────────
while IFS= read -r repo; do
  [ -n "$repo" ] || continue

  # ① 재개 대상 — 라벨 AND 로 **서버에서** 좁힌다. 클라이언트 필터만 쓰면 창(limit)을
  #    다른 needs-human 이슈들이 채워 진짜 대상이 밀려난다(eligible-issues.sh 와 같은 교훈).
  if fetch_issues "$repo" "$tmp/issues.ladder" "needs-human+hold:ladder" \
       --label needs-human --label hold:ladder; then
    # fd 3 으로 읽는다 — 안에서 부르는 gh 가 stdin 을 건드리면 목록이 통째로 먹힌다.
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      sweep_issue "$repo" "$row"
    done 3< "$tmp/issues.ladder"
  else
    echo "resume-sweep: $repo needs-human+hold:ladder 목록 조회 실패 — 이 레포는 건너뛴다" >&2
    rc=2
  fi

  # ② 사유 없는 needs-human — 사람이 손으로 붙였을 수 있으니 **손대지 않고** 알린다.
  #    (여기서 코멘트를 달면 updatedAt 이 갱신돼 자기가 자기 창을 밀어버린다 — 무편집이 규율.)
  if fetch_issues "$repo" "$tmp/issues.human" "needs-human" --label needs-human; then
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      if ! printf '%s' "$row" \
           | jq -e '[.labels[].name | select(startswith("hold:"))] | length > 0' >/dev/null 2>&1; then
        # 배포 대기 이슈는 **사유 라벨 없이 needs-human 으로 쉬는 것이 정상**이다(머지 뒤 사람이
        # 배포할 때까지). 교정할 불변식 위반이 없는데 매 틱 warn 이면, 머지가 쌓일수록 그 줄들이
        # 진짜 "사람이 사유 없이 붙인 needs-human" 을 묻어 버린다 — warn 은 **루프가 교정 가능한
        # 불변식 위반일 때만**(형제 이슈 #188 이 loop-status.sh 에서 정한 정의). 그래서 note 로
        # 강등한다. 조용히 버리지 않는 이유는 emit_note 주석 참고.
        #
        # 축은 **라벨만** 본다 — 제목은 사람이 자유롭게 쓰므로 판별 축이 될 수 없다(그래서 이
        # 스크립트는 title 을 조회조차 하지 않는다). 제외 판정도 **같은 row 에 대한 jq 테스트**로만
        # 한다: 별도 `gh issue list --label deploy-wait` 로 제외 집합을 만들면 그 조회의 실패가
        # "배포 대기 이슈 없음" 으로 위장돼 전부 다시 warn 이 된다(조회 실패를 '해당 없음' 으로
        # 삼키지 않는다는 이 파일의 규율).
        #
        # `deploy-wait` 가 정본 축이다(closeout 이 배포 대기 이슈에 붙인다) — 그래서 둘 다 있으면
        # 이쪽을 문구에 남긴다. `full-cycle` 은 **과도기 축**이다: 사람 세션 스킬 full-cycle §7 이
        # 배포 대기 이슈에 `needs-human`+`full-cycle` 만 붙이고 `deploy-wait` 를 빠뜨려서 생긴
        # 구멍인데, 그 스킬은 이 레포 밖이라 여기서 못 고친다. **그쪽이 `deploy-wait` 를 붙이는 날
        # 이 갈래(full-cycle)는 뗀다** — 원칙적 축으로 오해하지 마라. 그때까지의 대가는 `full-cycle`
        # 이 붙은 구현 이슈까지 note 로 내려간다는 것이고, 이는 의도된 트레이드오프다
        # (실측상 그런 이슈는 계정 전체에 0건 — 2026-09-11).
        # 번호와 축을 **한 번의 jq 로 함께** 뽑는다 — 이 루프는 레포의 needs-human 이슈 수만큼
        # 도니 필드마다 프로세스를 띄우면 조회보다 파싱이 더 비싸진다(read_state 가 같은 이유로
        # 같은 모양이다). jq 가 실패하면 둘 다 비고, 빈 축은 아래에서 warn 으로 떨어진다 —
        # 강등이 조회 실패를 타고 번지지 않는 방향이다.
        row_tsv=$(printf '%s' "$row" | jq -r '
          [.labels[].name] as $n
          | [(.number|tostring),
             (if ($n | index("deploy-wait") != null) then "deploy-wait"
              elif ($n | index("full-cycle") != null) then "full-cycle"
              else "" end)] | @tsv' 2>/dev/null) || row_tsv=""
        hnum=${row_tsv%%$'\t'*}
        dwlabel=${row_tsv#*$'\t'}
        if [ -n "$dwlabel" ]; then
          emit_note "$repo" "$hnum" "배포 대기(라벨 $dwlabel) — needs-human 이 정상 상태라 warn 아님"
        else
          emit_warn "$repo" "$hnum" \
            "needs-human 사유 없음(hold:* 부재) — 사람이 붙였을 수 있어 자동 재개 안 함"
        fi
      fi
    done 3< "$tmp/issues.human"
  else
    echo "resume-sweep: $repo needs-human 목록 조회 실패 — 사유 점검을 건너뛴다" >&2
    rc=2
  fi
  # ③ policy 재심 — `hold:policy` 가 창(RESUME_AFTER_MIN)을 넘겼는데 재심 마커 코멘트
  #    `<!-- policy-review: … -->` 가 없으면 **1회** 재심 대상(#155). 스크립트는 판정하지 않고
  #    이벤트만 낸다(판정은 디스패처 ① — 질문 한 줄이 루프가 답할 수 있는 것인지). 무편집.
  if fetch_issues "$repo" "$tmp/issues.policy" "needs-human+hold:policy" \
       --label needs-human --label hold:policy; then
    while IFS= read -r row <&3; do
      [ -n "$row" ] || continue
      pnum=$(printf '%s' "$row" | jq -r '.number')
      pupd=$(printf '%s' "$row" | jq -r '.updatedAt // ""')
      pep=$(jq -n --arg u "$pupd" '($u | try fromdateiso8601 catch -1)' 2>/dev/null || echo -1)
      [ "${pep:--1}" -ge 0 ] || { emit_warn "$repo" "$pnum" "updatedAt 해석 불가($pupd) — 재심 창 판정 못 함"; continue; }
      pmin=$(( ( $(date -u +%s) - pep ) / 60 ))
      [ "$pmin" -ge "$RESUME_AFTER_MIN" ] || continue
      pout=$(gh issue view "$pnum" --repo "$repo" --json comments 2>/dev/null) \
        || { emit_warn "$repo" "$pnum" "재심 마커 조회 실패 — 이번 틱은 건너뛴다"; continue; }
      # 에피소드 단위: 마지막 `hold-note: policy` 코멘트(=이번 홀드의 질문) **이후**에 재심 마커가
      # 있어야 "이번 홀드는 재심됨" 이다. 옛 홀드의 마커가 새 홀드의 재심을 막지 않게.
      # 질문(hold-note) 자체가 없으면 재심할 대상이 없다 — warn 으로만(레거시·손으로 붙인 홀드).
      pstate=$(printf '%s' "$pout" | jq -r '
        [.comments[]? | .body] as $b
        | ([range(0; $b|length)] | map(select($b[.] | test("<!--\\s*hold-note:\\s*policy"))) | last) as $q
        | if $q == null then "no-note"
          else ([range($q+1; $b|length)] | map(select($b[.] | test("<!--\\s*policy-review:"))) | length) as $r
               | if $r > 0 then "reviewed" else "due" end end' 2>/dev/null || echo "parse-fail")
      case "$pstate" in
        reviewed) continue ;;   # 이번 홀드는 이미 1회 재심됨 — 사람이 라벨을 뗄 때까지 다시 안 묻는다
        no-note)  emit_warn "$repo" "$pnum" "hold:policy 인데 질문(hold-note) 코멘트가 없다 — 재심 불가, --note 로 다시 걸거나 사람이 처리"; continue ;;
        due) ;;
        *) emit_warn "$repo" "$pnum" "재심 마커 해석 실패 — 이번 틱은 건너뛴다"; continue ;;
      esac
      printf '{"event":"policy_review_due","repo":"%s","number":%s,"minutes":%s}\n' "$repo" "$pnum" "$pmin"
    done 3< "$tmp/issues.policy"
  else
    echo "resume-sweep: $repo needs-human+hold:policy 목록 조회 실패 — 재심 점검을 건너뛴다" >&2
    rc=2
  fi
done < "$repos_file"

exit "$rc"
