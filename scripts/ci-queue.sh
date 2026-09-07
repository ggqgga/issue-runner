#!/usr/bin/env bash
# ci-queue.sh — 박스 전역 로컬 CI 큐 (티켓 락 FIFO, 데몬 없음). 설계: Plans/ci-queue.md (#127)
#
#   ci-queue.sh run <ROOT> <SHA> [--slug <slug>] [--repo <owner/repo>]
#   ci-queue.sh status [<SHA>]
#
# 세 진입점(push 훅 local-ci.sh · 루프 run-local-ci.sh · 세션 직접)이 전부 이걸 거쳐
# `bin/ci` 를 **박스 전체에서 한 번에 하나만** 돌린다. 워크트리·레포 무관.
#
# 큐 = $HOME/.claude/.local-ci/.queue/ (local-ci 캐시 예외 안 — CLAUDE.md 규칙)
#   티켓  = <epoch10>.<pid>.<sha>  파일(내용 root=/slug=/repo=). 이름 정렬 = FIFO.
#   실행권 = .queue/.running/ 디렉터리(mkdir 원자 토큰) + 그 안의 pid.
# 각 잡은 **자기 프로세스 안에서** 기다리다 실행한다 — 런너 데몬이 없으니 "런너가
# 죽으면 큐가 멈춤"이 없다. 죽은 pid 의 티켓·.running 은 지나가는 대기자가 치운다.
#
# run 종료 코드: 0=pass · 1=fail · 2=폐기(실행 시점 HEAD ≠ SHA — 새 push 가 자기 티켓을
# 냈으니 이 잡은 의미 없음) · 3=ROOT 부재. 결과 파일 형식(<slug>/<sha>.{log,result})은
# 기존 그대로 — ci-gate·closeout-ci-pass 호환.
# status 출력: `status` = 줄마다 "running <short> <slug>" / "queued <n> <short> <slug>",
#              `status <sha>` = "running" / "queued <n>" / "none".
# macOS bash 3.2 대상.
set -u

QDIR="$HOME/.claude/.local-ci/.queue"
RUNNING="$QDIR/.running"
POLL="${CI_QUEUE_POLL:-10}"

usage() {
  printf 'usage: ci-queue.sh run <ROOT> <SHA> [--slug <slug>] [--repo <owner/repo>]\n       ci-queue.sh status [<SHA>]\n       ci-queue.sh wait <SHA> [--timeout <sec>]\n' >&2
  exit 64
}
log() { printf 'ci-queue: %s\n' "$*" >&2; }
slug_of() { printf '%s' "$1" | sed 's#[/ ]#_#g; s#^_##'; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# 티켓 파일 이름 → 필드
ticket_pid() { printf '%s' "$1" | cut -d. -f2; }
ticket_sha() { printf '%s' "$1" | cut -d. -f3; }
ticket_field() {  # <ticket-path> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# 유령 회수 — pid 가 죽은 티켓, pid 가 죽은(또는 pid 없이 2분 넘은) .running
reap() {
  local t p
  for t in "$QDIR"/*; do
    [ -f "$t" ] || continue
    p=$(ticket_pid "$(basename "$t")")
    alive "$p" || rm -f "$t"
  done
  if [ -d "$RUNNING" ]; then
    if [ -f "$RUNNING/pid" ]; then
      alive "$(cat "$RUNNING/pid" 2>/dev/null)" || rm -rf "$RUNNING"
    elif [ -n "$(find "$RUNNING" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rm -rf "$RUNNING"
    fi
  fi
}

# 살아 있는 티켓을 FIFO 순으로
tickets() {
  local t
  for t in "$QDIR"/*; do [ -f "$t" ] && basename "$t"; done | sort
}

# 정렬된 티켓 목록에서 <ticket> 의 순번(1부터)
position_of() {
  tickets | awk -v t="$1" '{ if ($0 == t) { print NR; exit } }'
}

running_ticket() {
  [ -d "$RUNNING" ] && cat "$RUNNING/ticket" 2>/dev/null
}

# commit status 게시 — 실패는 무시(gh 미설치·미인증·원격 부재여도 큐 본연 동작 무손상).
# 머지 게이트는 로컬 캐시로 판정하므로 status 는 표시용.
post_status() {  # <state> <description>
  command -v gh >/dev/null 2>&1 || return 0
  if [ -n "$REPO" ]; then
    gh api "repos/$REPO/statuses/$SHA" -f state="$1" -f context="local-ci" -f description="$2" >/dev/null 2>&1
  else
    (cd "$ROOT" 2>/dev/null && gh api "repos/{owner}/{repo}/statuses/$SHA" -f state="$1" -f context="local-ci" -f description="$2") >/dev/null 2>&1
  fi
  return 0
}

result_exit() {  # result 파일 내용 → 종료 코드
  [ "$(cat "$RESULT" 2>/dev/null)" = pass ] && return 0
  return 1
}

cmd_status() {
  local want="${1:-}" run_t run_sha n t sha slug
  mkdir -p "$QDIR" 2>/dev/null
  reap
  run_t=$(running_ticket)
  run_sha=""; [ -n "$run_t" ] && run_sha=$(ticket_sha "$run_t")
  if [ -n "$want" ]; then
    [ "$run_sha" = "$want" ] && { echo running; return 0; }
    n=0
    for t in $(tickets); do
      [ "$t" = "$run_t" ] && continue
      n=$((n + 1))
      [ "$(ticket_sha "$t")" = "$want" ] && { echo "queued $n"; return 0; }
    done
    echo none; return 0
  fi
  if [ -n "$run_t" ]; then
    echo "running $(printf '%s' "$run_sha" | cut -c1-8) $(ticket_field "$QDIR/$run_t" slug)"
  fi
  n=0
  for t in $(tickets); do
    [ "$t" = "$run_t" ] && continue
    n=$((n + 1))
    sha=$(ticket_sha "$t"); slug=$(ticket_field "$QDIR/$t" slug)
    echo "queued $n $(printf '%s' "$sha" | cut -c1-8) $slug"
  done
  return 0
}

cmd_run() {
  [ $# -ge 2 ] || usage
  ROOT="$1"; SHA="$2"; shift 2
  SLUG=""; REPO=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) SLUG="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -d "$ROOT" ] || { log "ROOT 없음: $ROOT"; return 3; }
  ROOT=$(cd "$ROOT" && pwd -P)
  [ -n "$SLUG" ] || SLUG=$(slug_of "$ROOT")
  OUT="$HOME/.claude/.local-ci/$SLUG"
  RESULT="$OUT/$SHA.result"
  LOG="$OUT/$SHA.log"
  SHORT=$(printf '%s' "$SHA" | cut -c1-8)
  mkdir -p "$OUT" "$QDIR" 2>/dev/null

  # mise toolchain — shim 을 PATH 앞에(시스템 ruby 로 Gemfile 파싱이 깨지는 것 방지). 부재 시 무해.
  if [ -d "$HOME/.local/share/mise/shims" ]; then
    PATH="$HOME/.local/share/mise/shims:$PATH"; export PATH
  fi

  # dedup ① — 이미 검사됨
  if [ -f "$RESULT" ]; then
    log "$SHORT 이미 검사됨($(cat "$RESULT"))"
    result_exit; return $?
  fi

  reap
  # dedup ② — 같은 SHA 의 살아 있는 티켓이 있으면 새로 내지 않고 그 결과를 기다린다
  # (훅이 이미 큐에 넣은 SHA 를 루프가 다시 run 하는 경우 — bin/ci 는 1회만).
  local other
  for other in "$QDIR"/*."$SHA"; do
    [ -f "$other" ] || continue
    log "$SHORT 이미 대기열에 있음 — 그 결과를 기다림"
    while [ -f "$other" ] && [ ! -f "$RESULT" ]; do
      sleep "$POLL"
      alive "$(ticket_pid "$(basename "$other")")" || break
    done
    if [ -f "$RESULT" ]; then result_exit; return $?; fi
    break   # 티켓이 결과 없이 사라짐(폐기·사망) — 아래에서 내 티켓으로 진행
  done

  TICKET=$(printf '%010d.%d.%s' "$(date +%s)" "$$" "$SHA")
  printf 'root=%s\nslug=%s\nrepo=%s\n' "$ROOT" "$SLUG" "$REPO" > "$QDIR/$TICKET"
  OWNER=0
  cleanup() {
    rm -f "$QDIR/$TICKET"
    if [ "$OWNER" = 1 ] && [ "$(cat "$RUNNING/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$RUNNING"; fi
  }
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  local pos ahead
  pos=$(position_of "$TICKET"); ahead=$((pos - 1))
  post_status pending "로컬 CI 대기열 ${pos}번째"
  log "$SHORT 대기열 ${pos}번째 (앞에 ${ahead}건)"

  # 실행권 — 내 티켓이 가장 오래됐고 .running 을 내가 만들었을 때만
  while :; do
    reap
    if [ "$(tickets | head -1)" = "$TICKET" ] && mkdir "$RUNNING" 2>/dev/null; then
      echo "$$" > "$RUNNING/pid"
      printf '%s' "$TICKET" > "$RUNNING/ticket"
      OWNER=1
      break
    fi
    sleep "$POLL"
  done

  # 실행 직전 검사 — 큐가 push↔실행 간격을 늘리므로 "워킹트리 ≠ SHA" 를 여기서 닫는다
  if [ ! -d "$ROOT" ]; then log "$SHORT ROOT 사라짐: $ROOT"; return 3; fi
  local head
  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
  if [ "$head" != "$SHA" ]; then
    log "$SHORT 폐기 — 실행 시점 HEAD 가 $(printf '%s' "$head" | cut -c1-8) (새 push 가 자기 티켓을 냄)"
    post_status pending "로컬 CI 폐기 — HEAD 가 이동함(새 push 의 결과를 보라)"
    return 2
  fi

  post_status pending "bin/ci 실행 중 (로컬)"
  local start verdict dur
  start=$SECONDS
  if (cd "$ROOT" && bin/ci) >"$LOG" 2>&1; then verdict=pass; else verdict=fail; fi
  dur=$(( SECONDS - start ))
  printf '%s\n' "$verdict" > "$RESULT"
  if [ "$verdict" = pass ]; then
    post_status success "bin/ci 통과 (로컬, ${dur}s)"
  else
    post_status failure "bin/ci 실패 (로컬, ${dur}s) — 로그: ~/.claude/.local-ci/$SLUG"
  fi
  log "$SHORT $verdict (${dur}s) → $RESULT"
  if command -v osascript >/dev/null 2>&1; then
    local name; name=$(basename "$ROOT")
    if [ "$verdict" = pass ]; then
      osascript -e "display notification \"로컬 CI 통과 $SHORT\" with title \"✅ $name\"" >/dev/null 2>&1
    else
      osascript -e "display notification \"로컬 CI 실패 $SHORT — bin/ci 로그 확인\" with title \"❌ $name\"" >/dev/null 2>&1
    fi
  fi
  [ "$verdict" = pass ]
}

# wait — 세션이 "멍하게" 폴링하지 않게 하는 통로. 세션은 이 명령을 **백그라운드 Bash**
# (run_in_background) 로 띄운다 — 결과가 나오면 명령이 끝나고 Claude Code 가 세션을 깨운다.
# 결과는 슬러그 무관하게 <sha>.result 를 찾는다(워크트리 슬러그·메인 슬러그 어느 쪽이든).
# 종료 코드: 0=pass · 1=fail · 2=큐에 없고 결과도 없음(훅 미발화·폐기 — grace 초 관찰 후) ·
# 124=타임아웃.
find_result() {  # <sha> → 결과 파일 경로(첫 것) 또는 빈 문자열
  ls "$HOME/.claude/.local-ci"/*/"$1.result" 2>/dev/null | head -1
}
cmd_wait() {
  [ $# -ge 1 ] || usage
  local sha="$1"; shift
  local timeout="${CI_QUEUE_WAIT_TIMEOUT:-7200}" grace="${CI_QUEUE_WAIT_GRACE:-60}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  local short r st last="" waited=0 none_for=0 verdict logf
  short=$(printf '%s' "$sha" | cut -c1-8)
  while :; do
    r=$(find_result "$sha")
    if [ -n "$r" ]; then
      verdict=$(cat "$r" 2>/dev/null)
      printf 'ci-queue: %s %s — %s\n' "$short" "$verdict" "$r"
      if [ "$verdict" = pass ]; then return 0; fi
      logf="${r%.result}.log"
      printf -- '--- bin/ci 마지막 출력 ---\n%s\n----------------------------\n' "$(tail -25 "$logf" 2>/dev/null)"
      return 1
    fi
    st=$(cmd_status "$sha")
    if [ "$st" != "$last" ]; then
      case "$st" in
        running) printf 'ci-queue: %s 실행 중\n' "$short" ;;
        queued*) printf 'ci-queue: %s 대기열 %s번째\n' "$short" "${st#queued }" ;;
      esac
      last="$st"
    fi
    if [ "$st" = none ]; then
      none_for=$((none_for + POLL))
      if [ "$none_for" -ge "$grace" ]; then
        printf 'ci-queue: %s 큐에 없고 결과도 없음(%s초 관찰) — push 훅이 안 떴거나 HEAD 이동으로 폐기됨.\n재등록: ci-queue.sh run <ROOT> %s\n' "$short" "$grace" "$sha"
        return 2
      fi
    else
      none_for=0
    fi
    if [ "$waited" -ge "$timeout" ]; then
      printf 'ci-queue: %s 타임아웃(%s초) — 큐 상태: %s\n' "$short" "$timeout" "$st"
      return 124
    fi
    sleep "$POLL"; waited=$((waited + POLL))
  done
}

[ $# -ge 1 ] || usage
case "$1" in
  run)    shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  wait)   shift; cmd_wait "$@" ;;
  *)      usage ;;
esac
