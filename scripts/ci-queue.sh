#!/usr/bin/env bash
# ci-queue.sh — 박스 전역 로컬 CI 큐 (티켓 락 FIFO, 데몬 없음). 설계: Plans/ci-queue.md (#127)
#
#   ci-queue.sh run <ROOT> <SHA> [--slug <slug>] [--repo <owner/repo>]
#   ci-queue.sh status [<SHA>]
#   ci-queue.sh result <SHA>
#   ci-queue.sh wait <SHA> [--timeout <sec>]
#
# 세 진입점(push 훅 local-ci.sh · 루프 run-local-ci.sh · 세션 직접)이 전부 이걸 거쳐
# `bin/ci` 를 **박스 전체에서 한 번에 하나만** 돌린다. 워크트리·레포 무관.
#
# 큐 = $HOME/.claude/.local-ci/.queue/ (local-ci 캐시 예외 안 — CLAUDE.md 규칙)
#   티켓  = <epoch10>.<pid>.<sha>  파일(내용 slug=). 이름 정렬 = FIFO.
#   실행권 = .queue/.running/ 디렉터리(mkdir 원자 토큰) + 그 안의 pid·ticket.
# 각 잡은 **자기 프로세스 안에서** 기다리다 실행한다 — 런너 데몬이 없으니 "런너가
# 죽으면 큐가 멈춤"이 없다. 죽은 pid 의 티켓·.running 은 지나가는 대기자가 치운다.
#
# 결과 = $HOME/.claude/.local-ci/<slug>/<sha>.{log,result} (기존 형식 그대로 — ci-gate·
# closeout-ci-pass 호환). **조회 키는 SHA** — 어느 슬러그(워크트리·메인)에 떨어졌든
# `result <SHA>` 가 찾는다. 실행 직전 HEAD==SHA 를 검사하므로 같은 SHA 의 결과는 같은 커밋의 결과다.
#
# 종료 코드 — run: 0=pass · 1=fail · 2=폐기(실행 시점 HEAD ≠ SHA — 새 push 가 자기 티켓을
# 냈으니 이 잡은 의미 없음) · 3=ROOT 부재. wait: 0=pass · 1=fail · 2=큐에 없고 결과도 없음 ·
# 124=타임아웃. result: 0=있음(`pass|fail <path>` 출력) · 1=없음(`none`).
# status 출력: `status` = 줄마다 "running <sha> <slug>" / "queued <n> <sha> <slug>",
#              `status <sha>` = "running" / "queued <n>" / "none".
# macOS bash 3.2 대상 — 폴 루프 안은 서브프로세스 없이 파라미터 확장만 쓴다.
set -u

CACHE="$HOME/.claude/.local-ci"
QDIR="$CACHE/.queue"
RUNNING="$QDIR/.running"
POLL="${CI_QUEUE_POLL:-10}"

usage() {
  printf 'usage: ci-queue.sh run <ROOT> <SHA> [--slug <slug>] [--repo <owner/repo>]\n       ci-queue.sh status [<SHA>]\n       ci-queue.sh result <SHA>\n       ci-queue.sh wait <SHA> [--timeout <sec>]\n' >&2
  exit 64
}
log() { printf 'ci-queue: %s\n' "$*" >&2; }
slug_of() { printf '%s' "$1" | sed 's#[/ ]#_#g; s#^_##'; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# 티켓 이름 <epoch>.<pid>.<sha> → 필드 (프로세스 0)
ticket_pid() { local p="${1#*.}"; printf '%s' "${p%%.*}"; }
ticket_sha() { printf '%s' "${1##*.}"; }
ticket_slug() { local v; v=$(sed -n 's/^slug=//p' "$QDIR/$1" 2>/dev/null); printf '%s' "$v"; }

# 유령 회수 — pid 가 죽은 티켓, pid 가 죽은(또는 pid 없이 2분 넘은) .running
reap() {
  local t
  for t in "$QDIR"/*; do
    [ -f "$t" ] || continue
    alive "$(ticket_pid "${t##*/}")" || rm -f "$t"
  done
  if [ -d "$RUNNING" ]; then
    if [ -f "$RUNNING/pid" ]; then
      alive "$(cat "$RUNNING/pid" 2>/dev/null)" || rm -rf "$RUNNING"
    elif [ -n "$(find "$RUNNING" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rm -rf "$RUNNING"
    fi
  fi
}

# 티켓 이름을 FIFO 순으로 — 글롭이 이미 이름순이고 이름은 ASCII(숫자·점·hex)라 sort 불필요
tickets() {
  local t
  for t in "$QDIR"/*; do [ -f "$t" ] && printf '%s\n' "${t##*/}"; done
}
head_ticket() { local t; for t in "$QDIR"/*; do [ -f "$t" ] && { printf '%s' "${t##*/}"; return; }; done; }
running_ticket() { cat "$RUNNING/ticket" 2>/dev/null; }

# 결과 조회(키=SHA, 슬러그 무관) — 게이트·wait·dedup·closeout-ci-pass 가 전부 이걸 쓴다
cmd_result() {
  [ $# -ge 1 ] || usage
  local r
  for r in "$CACHE"/*/"$1.result"; do
    [ -f "$r" ] || continue
    printf '%s %s\n' "$(cat "$r")" "$r"
    return 0
  done
  echo none; return 1
}

# status — 한 루프로 전체를 찍고, <sha> 지정 시 그 줄만 골라 running / queued n / none 으로
cmd_status() {
  local want="${1:-}" run_t n t sha line
  mkdir -p "$QDIR" 2>/dev/null
  reap
  run_t=$(running_ticket)
  n=0
  for t in $(tickets); do
    sha=$(ticket_sha "$t")
    if [ "$t" = "$run_t" ]; then line="running $sha $(ticket_slug "$t")"
    else n=$((n + 1)); line="queued $n $sha $(ticket_slug "$t")"; fi
    if [ -z "$want" ]; then printf '%s\n' "$line"
    elif [ "$sha" = "$want" ]; then
      case "$line" in running*) echo running ;; *) echo "queued $n" ;; esac
      return 0
    fi
  done
  [ -n "$want" ] && echo none
  return 0
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

# wait — 세션이 "멍하게" 폴링하지 않게 하는 통로. 세션은 이 명령을 **백그라운드 Bash**
# (run_in_background) 로 띄운다 — 결과가 나오면 명령이 끝나고 Claude Code 가 세션을 깨운다.
# CI_QUEUE_WAIT_GRACE: 큐에도 결과도 없는 상태를 몇 초 보고 2 로 끝낼지(훅의 nohup 등록 지연 흡수).
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
  local short="${sha:0:8}" res st last="" waited=0 none_for=0 verdict path
  while :; do
    if res=$(cmd_result "$sha"); then
      verdict="${res%% *}"; path="${res#* }"
      printf 'ci-queue: %s %s — %s\n' "$short" "$verdict" "$path"
      [ "$verdict" = pass ] && return 0
      printf -- '--- bin/ci 마지막 출력 ---\n%s\n----------------------------\n' "$(tail -25 "${path%.result}.log" 2>/dev/null)"
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
  local out="$CACHE/$SLUG" short="${SHA:0:8}" rc
  RESULT="$out/$SHA.result"
  mkdir -p "$out" "$QDIR" 2>/dev/null
  find "$out" -type f -mtime +7 -delete 2>/dev/null   # 7일 지난 캐시 prune

  # mise toolchain — shim 을 PATH 앞에(시스템 ruby 로 Gemfile 파싱이 깨지는 것 방지). 부재 시 무해.
  if [ -d "$HOME/.local/share/mise/shims" ]; then
    PATH="$HOME/.local/share/mise/shims:$PATH"; export PATH
  fi

  # dedup — 이미 검사됐거나(어느 슬러그든) 같은 SHA 가 큐에 있으면 그 결과를 기다린다(bin/ci 1회).
  # wait 가 2(큐에도 결과도 없음)로 돌아올 때만 내 티켓으로 진행한다.
  rc=0; CI_QUEUE_WAIT_GRACE="$POLL" cmd_wait "$SHA" >/dev/null || rc=$?
  case "$rc" in
    0|1) log "$short 이미 검사됨"; return "$rc" ;;
    2) ;;
    *) return "$rc" ;;
  esac

  TICKET=$(printf '%010d.%d.%s' "$(date +%s)" "$$" "$SHA")
  printf 'slug=%s\n' "$SLUG" > "$QDIR/$TICKET"
  cleanup() {
    rm -f "$QDIR/$TICKET"
    [ "$(cat "$RUNNING/pid" 2>/dev/null)" = "$$" ] && rm -rf "$RUNNING"
  }
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  local pos
  pos=$(cmd_status "$SHA"); pos="${pos#queued }"
  post_status pending "로컬 CI 대기열 ${pos}번째"
  log "$short 대기열 ${pos}번째"

  # 실행권 — 내 티켓이 가장 오래됐고 .running 을 내가 만들었을 때만
  while :; do
    reap
    if [ "$(head_ticket)" = "$TICKET" ] && mkdir "$RUNNING" 2>/dev/null; then
      echo "$$" > "$RUNNING/pid"
      printf '%s' "$TICKET" > "$RUNNING/ticket"
      break
    fi
    sleep "$POLL"
  done

  # 실행 직전 검사 — 큐가 push↔실행 간격을 늘리므로 "워킹트리 ≠ SHA" 를 여기서 닫는다
  if [ ! -d "$ROOT" ]; then log "$short ROOT 사라짐: $ROOT"; return 3; fi
  local head
  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
  if [ "$head" != "$SHA" ]; then
    log "$short 폐기 — 실행 시점 HEAD 가 ${head:0:8} (새 push 가 자기 티켓을 냄)"
    post_status pending "로컬 CI 폐기 — HEAD 가 이동함(새 push 의 결과를 보라)"
    return 2
  fi

  post_status pending "bin/ci 실행 중 (로컬)"
  local start verdict dur
  start=$SECONDS
  if (cd "$ROOT" && bin/ci) >"$out/$SHA.log" 2>&1; then verdict=pass; else verdict=fail; fi
  dur=$(( SECONDS - start ))
  printf '%s\n' "$verdict" > "$RESULT"
  if [ "$verdict" = pass ]; then
    post_status success "bin/ci 통과 (로컬, ${dur}s)"
  else
    post_status failure "bin/ci 실패 (로컬, ${dur}s) — 로그: ~/.claude/.local-ci/$SLUG"
  fi
  log "$short $verdict (${dur}s) → $RESULT"
  if command -v osascript >/dev/null 2>&1; then
    local name="${ROOT##*/}"
    if [ "$verdict" = pass ]; then
      osascript -e "display notification \"로컬 CI 통과 $short\" with title \"✅ $name\"" >/dev/null 2>&1
    else
      osascript -e "display notification \"로컬 CI 실패 $short — bin/ci 로그 확인\" with title \"❌ $name\"" >/dev/null 2>&1
    fi
  fi
  [ "$verdict" = pass ]
}

[ $# -ge 1 ] || usage
case "$1" in
  run)    shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  result) shift; cmd_result "$@" ;;
  wait)   shift; cmd_wait "$@" ;;
  *)      usage ;;
esac
