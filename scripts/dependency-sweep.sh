#!/usr/bin/env bash
# dependency-sweep.sh — 본문 `Blocked by #N` 줄 · `blocked-by:<N>` 라벨을 GitHub 네이티브 이슈
# 의존성(`blocked_by` 관계)으로 **미러**한다 (#581, issue-runner ① Reconcile).
#
# 사용: dependency-sweep.sh [--repos-file <경로>] [--repo <owner/repo>]... [--dry-run]
#   스코프: `--repo` 가 있으면 그것들, 없으면 `--repos-file`(기본 `$PWD/.loop/repos`).
#           둘 다 없으면 usage exit 64 — `epic-sweep.sh` 와 **같은 규약**.
#   환경변수: DEP_OPEN_LIMIT(기본 500) — 레포당 열린 이슈 목록 상한. 닿으면 warn(잘린 이슈는
#             이번 틱에 안 보인다) — 실패가 아니라 보류라 rc 는 올리지 않는다(epic-sweep 과 같은 선).
#
# 왜 있나: 막힘은 본문 줄·라벨로만 존재하고, 발행 경로(loop-issues 생성 · closeout 파생 ·
# full-cycle · 사람 편집)는 거의 전부 본문 줄만 쓴다. 그러면 GitHub 이슈 목록에서 `agent-ready`
# 인데 안 도는 이슈가 막힌 것인지 안 보인다. 네이티브 관계는 목록에 "Blocked" 를 띄우고 블로커가
# 닫히면 표시가 스스로 사라진다. 쓰는 곳이 넷 이상이라 경로별 배선 대신 스윕 한 자리에 둔다.
#
# ★ **표시 전용이다.** 디스패치 게이트는 계속 본문 줄 ∪ `blocked-by:<N>` 라벨이고(SSOT 는
#   `eligible-issues.sh`), 이 스크립트는 어떤 게이트도 읽지도 바꾸지도 않는다.
#
# 규약:
#   · **추가만 한다.** 본문 줄/라벨에 있는데 네이티브 관계가 없는 (이슈, 블로커) 쌍만
#     `POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by -F issue_id=<블로커 REST id>` 로 건다.
#     본문에 없는 네이티브 관계는 지우지 않는다(사람이 UI 에서 건 것일 수 있다).
#   · **열린 블로커만** — 닫힌 블로커는 표시 효과가 없다. 블로커가 PR 이거나 없는(404) 번호면 note.
#   · 줄 판정 정규식은 `eligible-issues.sh` 와 **같은 문자열·같은 대소문자 무시 플래그**다
#     (PR#318 교훈 — 흉내내지 말고 복사). 같은 레포 번호만 다룬다.
#   · 기존 관계는 `GET …/dependencies/blocked_by` 의 **REST id** 로 대조한다(번호로 대조하면
#     다른 레포의 같은 번호 블로커를 "이미 있음" 으로 오인한다). POST 가 "이미 있음" 류 422 를
#     내면 note(실패로 세지 않는다) — 판정어는 `already` 하나다(`exist` 는 "does not exist" 류
#     진짜 실패까지 삼킨다).
#
# 출력(JSON lines — epic-sweep.sh·resume-sweep.sh 관행):
#   linked — 관계를 걸었다(`number` 막힌 이슈 · `blocker` 블로커 번호).
#   note   — 아무것도 안 건드린 정보 줄(블로커 미존재·PR·자기 참조·이미 있음 422).
#   warn   — 조회·쓰기 실패 또는 목록 상한. 다음 틱이 다시 본다.
#   `--dry-run` 이면 쓰기 0 이고 모든 이벤트에 `"dry_run":true` 가 붙는다(조회는 한다).
#
# 종료코드: 0 정상 · 1 조회·쓰기 실패가 하나라도 · 64 usage. 한 쌍의 실패가 나머지 쌍을 멈추지 않는다.
# 상태 파일 없음 — 멱등성은 GitHub 의 기존 관계 조회가 보장한다.
set -uo pipefail

SELF=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/scope.sh
. "$SCRIPT_DIR/lib/scope.sh"   # scope_lines · scope_file 기본값 — 판정은 한 자리 (#427)

usage() {
  {
    echo "usage: $SELF [--repos-file <경로>] [--repo <owner/repo>]... [--dry-run]"
    echo "  스코프: --repo 가 있으면 그것들, 없으면 --repos-file (기본 \$PWD/.loop/repos)."
    echo "          둘 다 없으면 이 도움말(exit 64)."
    echo "  --dry-run : 쓰기 0. 같은 이벤트를 dry_run:true 로 낸다."
  } >&2
  exit 64
}

DEP_OPEN_LIMIT="${DEP_OPEN_LIMIT:-500}"
case "$DEP_OPEN_LIMIT" in
  ''|*[!0-9]*|0)
    echo "$SELF: DEP_OPEN_LIMIT 은 1 이상의 정수여야 한다 (받은 값: '$DEP_OPEN_LIMIT')" >&2
    exit 64 ;;
esac

repos=()
repos_file=""
repos_file_given=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      shift; [ $# -gt 0 ] || usage
      case "$1" in */*) ;; *) usage ;; esac
      repos+=("$1") ;;
    --repos-file)
      shift; [ $# -gt 0 ] || usage
      repos_file="$1"; repos_file_given=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

# ── 스코프 확정 (epic-sweep.sh 와 같은 규약) ───────────────────────────────
if [ "${#repos[@]}" -eq 0 ]; then
  if [ "$repos_file_given" = 1 ]; then
    if [ ! -f "$repos_file" ]; then
      echo "$SELF: repos 파일 없음: $repos_file" >&2
      exit 64
    fi
  else
    repos_file="$scope_file"
    [ -f "$repos_file" ] || usage
  fi
  while IFS= read -r line; do
    case "$line" in
      */*) ;;
      *) echo "$SELF: $repos_file 무시된 줄: $line" >&2; continue ;;
    esac
    repos+=("$line")
  done < <(scope_lines "$repos_file")
fi
[ "${#repos[@]}" -gt 0 ] || usage

command -v jq >/dev/null 2>&1 || { echo "$SELF: jq 없음 — 판정 불가" >&2; exit 1; }

tmp=$(mktemp -d) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  echo "$SELF: 임시 디렉터리 생성 실패 — 중단" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# ── 이벤트 방출 ────────────────────────────────────────────────────────────
dry_field='{}'
[ "$dry_run" = 1 ] && dry_field='{"dry_run":true}'

emit() {  # emit <event> <repo> <num> <blocker|-> [why]
  local b="null"
  [ "$4" = "-" ] || b="$4"
  jq -nc --arg e "$1" --arg r "$2" --argjson n "$3" --argjson b "$b" --arg w "${5:-}" --argjson d "$dry_field" \
    '{event:$e, repo:$r, number:$n}
     + (if $b != null then {blocker:$b} else {} end)
     + (if $w != "" then {why:$w} else {} end) + $d'
}

# 여러 줄 오류문을 한 줄로 — ④ Report 가 옮기는 warn 은 한 줄이다.
one_line() { tr '\n' ' ' < "$1" | sed 's/[[:space:]]*$//'; }

rc=0

# 블로커 조회 — 레포 안 캐시. 결과는 `$tmp/b/<번호>` 에 `<id><TAB><state><TAB><pr여부>` 또는 `404`.
# 조회 실패(404 외)는 캐시하지 않는다 — 같은 틱의 다음 쌍이 다시 시도한다.
blocker_info() {  # blocker_info <repo> <b> → stdout 한 줄 · rc 1 = 조회 실패(stderr 는 $tmp/err)
  local f="$tmp/b/$2" out
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  if out=$(gh api "repos/$1/issues/$2" \
        --jq '[(.id|tostring), (.state // ""), (if .pull_request then "pr" else "issue" end)] | @tsv' 2>"$tmp/err"); then
    case "$out" in
      [0-9]*"	"*) printf '%s\n' "$out" > "$f"; printf '%s\n' "$out"; return 0 ;;
    esac
    printf '응답 파싱 실패: %s' "$out" > "$tmp/err"
    return 1
  fi
  if grep -q 'HTTP 404' "$tmp/err"; then
    echo 404 > "$f"; echo 404; return 0
  fi
  return 1
}

# ── 이슈 1건 처리 ──────────────────────────────────────────────────────────
sweep_issue() {  # sweep_issue <repo> <이슈 JSON 한 줄>
  local repo="$1" row="$2" num body body_blockers label_blockers blockers b info bid bstate bkind
  local existing="" existing_ok=0 perr

  num=$(printf '%s' "$row" | jq -r '.number // "" | tostring' 2>/dev/null) || num=""
  case "$num" in ''|*[!0-9]*) emit warn "$repo" 0 - "이슈 번호 파싱 실패 — 이 행은 건너뛴다"; rc=1; return 0 ;; esac

  body=$(printf '%s' "$row" | jq -r '.body // ""' 2>/dev/null) || body=""
  # ★ 아래 정규식·플래그는 `eligible-issues.sh` 블로커 파싱과 **같은 문자열**이다 — 고치면 같이 고쳐라.
  body_blockers=$(printf '%s' "$body" \
    | grep -oiE '^[[:space:]]*blocked[- ]by[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+$' || true)
  label_blockers=$(printf '%s' "$row" \
    | jq -r '[.labels[].name | select(startswith("blocked-by:")) | ltrimstr("blocked-by:")] | .[]' \
    2>/dev/null || true)
  blockers=$(printf '%s\n%s\n' "$body_blockers" "$label_blockers" \
    | grep -E '^[0-9]+$' | sort -un || true)
  [ -n "$blockers" ] || return 0

  for b in $blockers; do
    b=$((10#$b))
    if [ "$b" = "$num" ]; then
      emit note "$repo" "$num" "$b" "자기 참조 — 건너뛴다"
      continue
    fi
    if ! info=$(blocker_info "$repo" "$b"); then
      emit warn "$repo" "$num" "$b" "블로커 조회 실패 — 다음 틱 재시도: $(one_line "$tmp/err")"
      rc=1
      continue
    fi
    if [ "$info" = 404 ]; then
      emit note "$repo" "$num" "$b" "블로커 미존재(404) — 건너뛴다"
      continue
    fi
    IFS=$'\t' read -r bid bstate bkind <<EOF
$info
EOF
    [ "$bstate" = "open" ] || continue   # 닫힌 블로커 — 표시 효과 없음(조용히)
    if [ "$bkind" = "pr" ]; then
      emit note "$repo" "$num" "$b" "블로커가 PR 이다 — 이슈 의존성 대상 아님"
      continue
    fi

    # 기존 관계 — 이슈당 1회(열린 블로커가 하나라도 있을 때만).
    if [ "$existing_ok" = 0 ]; then
      if existing=$(gh api --paginate "repos/$repo/issues/$num/dependencies/blocked_by?per_page=100" \
            --jq '.[].id' 2>"$tmp/err"); then
        existing_ok=1
      else
        emit warn "$repo" "$num" "$b" "기존 의존성 조회 실패 — 다음 틱 재시도: $(one_line "$tmp/err")"
        rc=1
        existing_ok=2
      fi
    fi
    [ "$existing_ok" = 1 ] || continue
    if printf '%s\n' "$existing" | grep -qxF "$bid"; then
      continue   # 이미 있음 — 멱등
    fi

    if [ "$dry_run" = 1 ]; then
      emit linked "$repo" "$num" "$b"
      continue
    fi
    if gh api -X POST "repos/$repo/issues/$num/dependencies/blocked_by" -F "issue_id=$bid" \
          >"$tmp/post" 2>"$tmp/err"; then
      emit linked "$repo" "$num" "$b"
      existing=$(printf '%s\n%s' "$existing" "$bid")
    else
      perr="$(one_line "$tmp/err") $(one_line "$tmp/post")"
      if printf '%s' "$perr" | grep -q 'HTTP 422' \
         && printf '%s' "$perr" | grep -qi 'already'; then
        emit note "$repo" "$num" "$b" "이미 있음(422) — 건너뛴다"
      else
        emit warn "$repo" "$num" "$b" "의존성 추가 실패: $perr"
        rc=1
      fi
    fi
  done
}

# ── 레포별 스윕 ───────────────────────────────────────────────────────────
for repo in "${repos[@]}"; do
  [ -n "$repo" ] || continue
  rm -rf "$tmp/b"; mkdir -p "$tmp/b"

  if ! ilist=$(gh issue list --repo "$repo" --state open --limit "$DEP_OPEN_LIMIT" \
        --json number,body,labels 2>"$tmp/err"); then
    emit warn "$repo" 0 - "열린 이슈 목록 조회 실패 — 이 레포는 건너뛴다: $(one_line "$tmp/err")"
    rc=1
    continue
  fi
  if ! icount=$(printf '%s' "$ilist" | jq -e 'if type=="array" then length else error end' 2>/dev/null); then
    emit warn "$repo" 0 - "열린 이슈 목록 파싱 실패 — 이 레포는 건너뛴다"
    rc=1
    continue
  fi
  if [ "$icount" -ge "$DEP_OPEN_LIMIT" ]; then
    emit warn "$repo" 0 - "열린 이슈 목록 상한 도달($DEP_OPEN_LIMIT) — 잘린 이슈는 이번 틱에 안 보인다"
  fi
  # 후보 사전 필터 — 본문에 `blocked`(대소문자 무시)가 있거나 `blocked-by:` 라벨이 있는 이슈만.
  # 위 정규식보다 **넓은** 술어라 놓치는 쌍이 없고, 나머지 이슈에 grep 프로세스를 띄우지 않는다.
  printf '%s' "$ilist" | jq -c 'sort_by(.number) | .[]
      | select(((.body // "") | test("blocked"; "i"))
               or ([.labels[]?.name | startswith("blocked-by:")] | any))' \
    > "$tmp/issues" 2>/dev/null || : > "$tmp/issues"

  # fd 3 으로 읽는다 — 안에서 부르는 gh 가 stdin 을 건드리면 목록이 통째로 먹힌다.
  while IFS= read -r irow <&3; do
    [ -n "$irow" ] || continue
    sweep_issue "$repo" "$irow"
  done 3< "$tmp/issues"
done

exit "$rc"
