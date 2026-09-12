#!/usr/bin/env bash
# epic-sweep.sh — leaf 가 **전부 닫힌** 에픽을 닫는다 (#258, closeout ① Reconcile).
#
# 사용: epic-sweep.sh [--repos-file <경로>] [--repo <owner/repo>]... [--dry-run]
#   스코프: `--repo` 가 있으면 그것들, 없으면 `--repos-file`(기본 `$PWD/.loop/repos`).
#           둘 다 없으면 usage exit 64 — `loop-status.sh` 와 **같은 규약**.
#   환경변수: EPIC_LIST_LIMIT(기본 100) · EPIC_SEARCH_PER_PAGE(기본 100)
#             — 테스트가 상한 도달 경로를 100건짜리 픽스처 없이 재현하려고 열어 둔 값이다
#               (운영에서 내리는 값이 아니다 — 내리면 그만큼 잘리고, 잘림은 warn 으로 드러난다).
#             EPIC_CLOSE_RETRIES(기본 3) · EPIC_CLOSE_RETRY_SLEEP(기본 2, 초)
#             — close 의 같은 틱 재시도(아래 "멱등" 절). 테스트는 sleep 0 으로 돌린다.
#
# 왜 있나: 에픽 이슈는 **워커가 집지 않아** 아무 루프도 닫지 않는다. leaf 를 다 닫고도
# 열린 채 남아 목록을 채운다(2026-09-11 실측: leaf 12건 중 11건 종료된 에픽이 덩그러니
# 남아 있었다). `loop-status.sh` 는 이미 그 상태를 `에픽 leaf 전부 종료` warn 으로 **보기만**
# 한다 — 이 스크립트는 그 자리에서 **닫는다**. 에픽 종료는 결정이 아니라 **정리**다.
#
# 출력(JSON lines — resume-sweep.sh 관행):
#   closed — 에픽을 닫았다. `leaves` 는 근거가 된 leaf 번호(오름차순).
#   note   — **아무것도 안 건드린** 정보 줄. 조치할 것이 없는 정상 상태다
#            (leaf 0 = 옛 에픽 · deploy-wait 에픽). warn 의 정의를 "루프가 교정 가능한
#            불변식 위반" 으로 좁힌 #188 의 선을 그대로 따른다.
#   warn   — 판정을 **보류**했거나(조회 상한) 실패했다(조회·쓰기). 어느 쪽이든 쓰기는 0 이거나
#            중간에 멈췄고, 다음 틱이 다시 본다.
#   `--dry-run` 이면 세 이벤트 모두에 `"dry_run":true` 가 붙는다(쓰기 0).
#
# 종료코드: 0 정상 · 1 조회·쓰기 **실패**가 하나라도 있었다 · 64 스코프 없음(usage).
#   **조회 상한 도달은 rc 를 올리지 않는다** — 실패가 아니라 결정론적 보류라서, rc 1 로
#   치면 큰 에픽 하나가 매 틱 영구 실패로 보고된다(경보가 상시화되면 진짜 실패가 묻힌다).
#
# 상태 파일 없음 — SSOT 는 GitHub(이슈 상태·라벨·코멘트 마커). 멱등성은 에픽에 달린
# `<!-- epic-sweep -->` 코멘트 마커가 보장한다 — 마커는 코멘트뿐 아니라 **close 의 게이트**다(#377):
#   마커가 있는 에픽이 지금 **열려 있으면** "스윕이 한 번 닫았는데 사람이 되돌렸다" 는 뜻이라
#   코멘트도 close 도 하지 않는다(note). 마커가 코멘트만 막고 close 는 매 틱 그대로 실행하던
#   판본에서는 사람의 재오픈이 다음 틱에 **새 코멘트 없이** 다시 닫혀 흔적조차 안 남았다.
#   그래서 "코멘트는 됐는데 close 가 실패한" 중간 상태는 다음 틱으로 **이월할 수 없다**(다음
#   틱은 그것을 되돌림으로 읽는다) — 같은 틱 안에서 close 를 `EPIC_CLOSE_RETRIES` 번 재시도하고,
#   그래도 실패하면 warn(rc 1) 으로 "다음 틱이 재시도하지 않는다" 를 말한다. 그 에픽은 사람이
#   직접 닫거나, 마커 코멘트를 지우면 다음 틱이 처음부터(코멘트 → close) 다시 한다.
#   (대안이던 "마커 2종 — 코멘트에 close 성공 여부를 실어 넣기" 는 close 뒤 코멘트 편집이라는
#   세 번째 쓰기가 필요하고 그 편집이 실패하는 창에서 같은 버그가 좁게 남아 택하지 않았다.)
#
# 알려진 느슨함 ⑴ (숨기지 않는다): **검색 인덱싱 지연**. leaf 를 GitHub 검색으로 찾으므로,
# 방금 열린 leaf 가 아직 색인되지 않았으면 세 상한 신호(items·total_count·incomplete)가 전부
# 정상인 채 그 leaf 만 안 보인다 — 그 순간 에픽이 닫힐 수 있다. 이슈 #258 이 "검색 한 번" 을
# 설계로 지정했으므로 여기서 뒤집지 않는다(이슈 목록 전수 스캔은 레포당 비용이 전혀 다르다).
# 피해는 되돌릴 수 있다: 에픽 재오픈은 사람이 클릭 한 번이고, 위 마커 게이트가 그 재오픈을
# **지킨다**(다시 닫지 않는다). 근거 코멘트에 그때 세어진 leaf 번호가 그대로 남아 무엇을
# 못 봤는지 바로 대조된다. 되돌린 에픽은 이후 leaf 가 전부 닫혀도 스윕이 닫지 않으므로 종료는
# 사람 몫이다 — `loop-status.sh` 의 `에픽 leaf 전부 종료` warn 이 그 에픽을 계속 보여 준다.
#
# 알려진 느슨함 ⑵: 마커 탐지는 인용 구간(코드펜스·백틱)을 걷어내지 않는다
# (resume-sweep.sh 의 `JQ_UNQUOTE` 같은 장치가 없다). 누군가 코멘트에 마커를 **인용**하면
# 그 에픽은 스윕이 되돌림으로 읽어 **닫지 않는다**(note) — 방향이 "덜 쓴다" 쪽이고, 그 인용을
# 지우거나 사람이 직접 닫으면 풀린다. 반대 방향(마커를 못 봐서 코멘트가 하나 더 붙는 것)은
# close 는 한 번뿐이라 코멘트 하나가 더 붙는 데서 그친다.
set -uo pipefail

SELF=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  {
    echo "usage: $SELF [--repos-file <경로>] [--repo <owner/repo>]... [--dry-run]"
    echo "  스코프: --repo 가 있으면 그것들, 없으면 --repos-file (기본 \$PWD/.loop/repos)."
    echo "          둘 다 없으면 이 도움말(exit 64)."
    echo "  --dry-run : 쓰기 0. 같은 이벤트를 dry_run:true 로 낸다."
  } >&2
  exit 64
}

EPIC_LIST_LIMIT="${EPIC_LIST_LIMIT:-100}"
EPIC_SEARCH_PER_PAGE="${EPIC_SEARCH_PER_PAGE:-100}"
EPIC_CLOSE_RETRIES="${EPIC_CLOSE_RETRIES:-3}"
EPIC_CLOSE_RETRY_SLEEP="${EPIC_CLOSE_RETRY_SLEEP:-2}"

# 값 검증은 **모든 GitHub 호출 앞**에 둔다 — `[ "$x" -ge "$y" ]` 는 정수가 아니면 bash 가
# 에러를 내고 거짓으로 떨어지는데, set -e 가 아니라 그대로 흘러 "상한에 안 닿았다" 로
# 오판한다(잘린 검색 결과를 완전한 것으로 읽어 **열린 leaf 를 못 보고 닫는** 방향이다).
_pos_int() { case "$1" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac; }
if ! _pos_int "$EPIC_LIST_LIMIT"; then
  echo "$SELF: EPIC_LIST_LIMIT 은 1 이상의 정수여야 한다 (받은 값: '$EPIC_LIST_LIMIT')" >&2
  exit 64
fi
if ! _pos_int "$EPIC_SEARCH_PER_PAGE"; then
  echo "$SELF: EPIC_SEARCH_PER_PAGE 는 1 이상의 정수여야 한다 (받은 값: '$EPIC_SEARCH_PER_PAGE')" >&2
  exit 64
fi
if ! _pos_int "$EPIC_CLOSE_RETRIES"; then
  echo "$SELF: EPIC_CLOSE_RETRIES 는 1 이상의 정수여야 한다 (받은 값: '$EPIC_CLOSE_RETRIES')" >&2
  exit 64
fi
case "$EPIC_CLOSE_RETRY_SLEEP" in
  ''|*[!0-9]*)
    echo "$SELF: EPIC_CLOSE_RETRY_SLEEP 은 0 이상의 정수(초)여야 한다 (받은 값: '$EPIC_CLOSE_RETRY_SLEEP')" >&2
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

# ── 스코프 확정 (loop-status.sh 와 같은 규약) ──────────────────────────────
if [ "${#repos[@]}" -eq 0 ]; then
  if [ "$repos_file_given" = 1 ]; then
    # 사람이 경로를 콕 집었는데 없으면 usage 로 뭉개지 말고 그 사실만 말한다.
    if [ ! -f "$repos_file" ]; then
      echo "$SELF: repos 파일 없음: $repos_file" >&2
      exit 64
    fi
  else
    repos_file="$PWD/.loop/repos"
    [ -f "$repos_file" ] || usage
  fi
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d ' \t')
    case "$line" in ""|"#"*) continue ;; esac
    # owner/repo 형식이 아닌 줄은 조용히 버리지 않는다 — 오타 한 글자가 레포 하나를
    # 스코프에서 통째로 지우고도 흔적이 없으면 "그 레포엔 닫을 에픽이 없다" 로 읽힌다.
    case "$line" in
      */*) ;;
      *) echo "$SELF: $repos_file 무시된 줄: $line" >&2; continue ;;
    esac
    repos+=("$line")
  done < "$repos_file"
fi
[ "${#repos[@]}" -gt 0 ] || usage

command -v jq >/dev/null 2>&1 || { echo "$SELF: jq 없음 — 판정 불가" >&2; exit 1; }

tmp=$(mktemp -d) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  echo "$SELF: 임시 디렉터리 생성 실패 — 조회 결과를 못 받으므로 중단" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT

# ── 이벤트 방출 ────────────────────────────────────────────────────────────
# JSON 은 jq 로 만든다 — `leaves` 가 배열이라 printf 조립이면 따옴표·개행이 섞인 순간
# 줄 전체가 JSON 이 아니게 되고(#193), 그러면 경보가 조용히 사라진다.
dry_field='{}'
[ "$dry_run" = 1 ] && dry_field='{"dry_run":true}'

# 방출용 번호 술어 — **정규 JSON 정수 리터럴**인가(`0` | `[1-9][0-9]*`). 선행 0 은 거절한다:
# 출처가 `jq -r '.number'` 하나뿐이라 `01` 을 낼 경로가 없으므로, 그건 특이 표기가 아니라
# 파싱이 어긋났다는 증거다(resume-sweep.sh `_json_int` 와 같은 규칙·같은 이유).
_json_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0)  return 0 ;;
    0*) return 1 ;;
    *)  return 0 ;;
  esac
}

emit_closed() {  # emit_closed <repo> <num> <leaves JSON 배열>
  jq -nc --arg r "$1" --argjson n "$2" --argjson l "$3" --argjson d "$dry_field" \
    '{event:"closed", repo:$r, number:$n, leaves:$l} + $d'
}
emit_note() {  # emit_note <repo> <num> <why>
  jq -nc --arg r "$1" --argjson n "$2" --arg w "$3" --argjson d "$dry_field" \
    '{event:"note", repo:$r, number:$n, why:$w} + $d'
}
emit_warn() {  # emit_warn <repo> <num> <why>
  jq -nc --arg r "$1" --argjson n "$2" --arg w "$3" --argjson d "$dry_field" \
    '{event:"warn", repo:$r, number:$n, why:$w} + $d'
}

has_label() {  # has_label <콤마목록> <라벨>
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}

# close 를 같은 틱 안에서 `EPIC_CLOSE_RETRIES` 번까지 시도한다. 마커 게이트(sweep_epic 참고)
# 때문에 "코멘트만 남고 안 닫힌" 상태는 다음 틱이 이어받지 못하므로 재시도는 여기뿐이다.
close_epic() {  # close_epic <repo> <num>
  local i=1
  while :; do
    gh issue close "$2" --repo "$1" --reason completed >/dev/null 2>&1 && return 0
    [ "$i" -lt "$EPIC_CLOSE_RETRIES" ] || return 1
    i=$((i + 1))
    [ "$EPIC_CLOSE_RETRY_SLEEP" -eq 0 ] || sleep "$EPIC_CLOSE_RETRY_SLEEP"
  done
}

# leaf 판정 — `loop-status.sh` 의 `epic_of`(#260)와 **같은 술어**다. 본문의 **전용 줄**
# (줄 시작의 `epic\s+#N` 뒤가 줄 끝까지 공백뿐, 대소문자 무시)의 **첫 매치**만 취한다:
# 한 이슈 = 최대 한 에픽.
# 검색(`in:body`)은 산문 매치도 돌려주므로 이 재확인이 없으면 `… epic #100 …` 을 지나가며
# 언급한 이슈가 leaf 로 잡혀 **남의 진척으로 에픽이 닫힌다**. 번호는 문자열 비교가 아니라
# **추출 후 수 비교**라 `Epic #1000` 이 `Epic #100` 의 leaf 로 새지 않는다.
# 끝 앵커(`[[:space:]]*$`)는 #327 에서 `loop-status.sh` 와 **같은 커밋에서** 넣었다 —
# 줄 시작은 전용 줄 모양이나 뒤에 산문이 이어지는 `Epic #100 의 후속 논의` 류가 앵커 없이는
# leaf 로 새고, 그런 언급만 달린 옛 에픽은 leaf ≥1·전부 CLOSED 로 읽혀 **잘못 닫힌다**
# (전용 줄 규약 #259 는 `Epic #N` 단독 줄을 요구한다). 허용하는 잉여는 줄 끝 공백뿐이고
# CRLF 본문의 `\r` 도 `[[:space:]]` 라 그대로 통과한다.
# 이 capture 문자열이 loop-status.sh 와 갈라지면 두 계산기가 다른 leaf 를 센다 —
# scripts/tests/epic-sweep.test.sh ⑪ 이 두 파일에서 뽑아 대조한다(끝 앵커 유무도 ⑪-b 가 문다).
JQ_EPIC_OF='def epic_of($body):
  ([($body // "") | split("\n")[]
      | capture("^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)[[:space:]]*$"; "i") | .n]
   | if length > 0 then (.[0] | tonumber) else null end);'

rc=0

# ── 에픽 1건 처리 ──────────────────────────────────────────────────────────
sweep_epic() {  # sweep_epic <repo> <에픽 JSON 한 줄>
  local repo="$1" row="$2"
  local num labels sres stats total open_n leaves_json items_n total_count inc ctext cjson marker

  num=$(printf '%s' "$row" | jq -r '.number // "" | tostring' 2>/dev/null) || num=""
  if ! _json_int "$num"; then
    emit_warn "$repo" 0 "에픽 번호 파싱 실패 — 이 행은 건너뛴다"
    rc=1
    return 0
  fi

  # 라벨 파싱 실패는 **fail-closed** — 빈 값으로 떨어뜨리면 `deploy-wait` 가드가 "라벨이
  # 없다" 로 읽혀 배포 게이트 에픽을 닫는 방향으로 샌다(하필 §되돌리지 마라 의 "절대 닫지
  # 마라" 조항의 가드다). 빈 결과(라벨 0개)와 실패를 rc 로 가른다.
  # 필터 첫 줄의 `# epic-labels` 는 스위트가 **이 한 호출만** 실패시켜 fail-closed 를
  # 실증하기 위한 표식이다 — row 는 이미 유효 JSON 이라 데이터로는 이 경로에 못 닿는다.
  if ! labels=$(printf '%s' "$row" | jq -r '# epic-labels (#258)
        [.labels[]?.name] | join(",")' 2>/dev/null); then
    emit_warn "$repo" "$num" "라벨 파싱 실패 — deploy-wait 여부를 몰라 건드리지 않는다"
    rc=1
    return 0
  fi
  # 배포 대기 이슈는 에픽이 **아니어야** 하지만(라벨이 잘못 겹칠 수 있다) 방어한다 —
  # 사람이 답해야 풀리는 게이트를 루프가 닫아 버리면 그 배포가 통째로 증발한다.
  if has_label "$labels" "deploy-wait"; then
    emit_note "$repo" "$num" "deploy-wait 라벨 — 배포 게이트라 건드리지 않는다"
    return 0
  fi
  # `full-cycle`·`needs-human` 은 **닫는다** — 에픽 종료는 결정이 아니라 정리다(#258).
  # leaf 를 다 닫은 에픽에 남은 사람 게이트는 실체가 없다(leaf 쪽에서 이미 해소됐다).

  # ── leaf 검색 — 에픽당 gh 호출 **1회** ──────────────────────────────────
  if ! sres=$(gh api -X GET search/issues \
        -f q="repo:$repo is:issue \"Epic #$num\" in:body" \
        -f per_page="$EPIC_SEARCH_PER_PAGE" 2>/dev/null); then
    emit_warn "$repo" "$num" "leaf 검색 실패 — 판정 보류(다음 틱 재시도)"
    rc=1
    return 0
  fi
  if ! printf '%s' "$sres" | jq -e 'type=="object" and (.items|type=="array")' >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "leaf 검색 응답 파싱 실패 — 판정 보류"
    rc=1
    return 0
  fi

  # 한 번의 jq 로 전부 뽑는다(에픽 수만큼 도는 함수라 필드마다 프로세스를 띄우면
  # 조회보다 파싱이 더 비싸진다). @tsv 라 필드에 탭이 못 들어온다.
  stats=$(printf '%s' "$sres" | jq -r --argjson n "$num" "$JQ_EPIC_OF"'
    ([ .items[]?
       | select((.number // -1) != $n)          # 에픽 자신은 자기 leaf 가 아니다
       | select(epic_of(.body) == $n) ]) as $leaves
    | [ ($leaves | length),
        ([$leaves[] | select((.state // "") != "closed")] | length),
        (.items | length),
        (.total_count // 0),
        (if (.incomplete_results // false) then 1 else 0 end),
        ($leaves | map(.number) | sort | tojson) ] | @tsv' 2>/dev/null) || stats=""
  if [ -z "$stats" ]; then
    emit_warn "$repo" "$num" "leaf 집계 실패 — 판정 보류"
    rc=1
    return 0
  fi
  IFS=$'\t' read -r total open_n items_n total_count inc leaves_json <<EOF
$stats
EOF

  # ── 조회가 잘렸는가 — **판정보다 먼저** ─────────────────────────────────
  # 잘린 결과로 판정하면 "열린 leaf 는 잘린 쪽에 있었다" 를 못 보고 닫는다(조용한 오판).
  # 세 신호 모두 "이 목록이 전부라고 말할 수 없다" 는 같은 뜻이다.
  if [ "${items_n:-0}" -ge "$EPIC_SEARCH_PER_PAGE" ] \
     || [ "${total_count:-0}" -gt "${items_n:-0}" ] \
     || [ "${inc:-0}" -ne 0 ]; then
    emit_warn "$repo" "$num" "leaf 조회 상한($EPIC_SEARCH_PER_PAGE, total=$total_count) — 판정 보류"
    return 0
  fi

  if [ "${total:-0}" -eq 0 ]; then
    # 옛 에픽 — `Epic #N` 줄이 없는 leaf 는 기계가 볼 수 없다. 닫지 않는다.
    emit_note "$repo" "$num" "연결된 leaf 없음"
    return 0
  fi
  if [ "${open_n:-0}" -gt 0 ]; then
    return 0   # 열린 leaf 가 있다 — 아무것도 안 한다(조용히)
  fi

  # ── leaf ≥ 1 · 전부 CLOSED → 코멘트 + close ────────────────────────────
  # 근거 목록 — 빈 값으로 떨어뜨리지 않는다. 이 스크립트는 "왜 닫혔는지" 를 남기려고
  # 코멘트를 close **앞에** 다는데(아래), `leaf ` 뒤가 빈 코멘트를 남기고 닫으면 그 설계가
  # 바로 그 자리에서 무너진다. 표식 `# leaf-list` 의 이유는 위 `# epic-labels` 와 같다.
  local leaves_txt
  if ! leaves_txt=$(printf '%s' "$leaves_json" | jq -r '# leaf-list (#258)
        map("#" + tostring) | join(" ")' 2>/dev/null) || [ -z "$leaves_txt" ]; then
    emit_warn "$repo" "$num" "leaf 번호 목록 생성 실패 — 근거 없는 종료를 만들지 않는다"
    rc=1
    return 0
  fi

  # ── 마커 게이트 — dry-run **앞**에서 본다(읽기라 쓰기 0 규약과 무관) ──────────
  # 마커(`<!-- epic-sweep -->`)가 있는데 이 에픽이 열려 있다 = 스윕이 한 번 닫았고 사람이
  # 되돌렸다. 코멘트도 close 도 하지 않는다. dry-run 도 같은 판정을 내야 한다 — #377 의 실측이
  # `--dry-run` 으로 "다시 닫겠다" 는 거짓 예측을 봤다. 코멘트 전량은 `pr-comments.sh` 로
  # 읽는다: `gh issue view --json comments` 는 페이지네이션 없이 **첫 100건만** 주고, 그
  # 상한을 넘긴 에픽은 마커를 못 봐 매 틱 코멘트를 하나씩 더 붙인다(PR#173 교훈, 같은 함정의
  # 이슈 판).
  if ! cjson=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$num"); then
    emit_warn "$repo" "$num" "코멘트 조회 실패 — 마커 유무를 몰라 쓰지 않는다(중복 코멘트 방지)"
    rc=1
    return 0
  fi
  marker=$(printf '%s' "$cjson" \
    | jq -r '[.[]? | select((.body // "") | test("<!--\\s*epic-sweep\\s*-->"))] | length' 2>/dev/null) || marker=""
  if [ -z "$marker" ]; then
    emit_warn "$repo" "$num" "코멘트 파싱 실패 — 마커 유무를 몰라 쓰지 않는다"
    rc=1
    return 0
  fi
  if [ "$marker" -gt 0 ]; then
    emit_note "$repo" "$num" "스윕 마커가 있는데 열려 있다 — 사람이 되돌린 것이라 다시 닫지 않는다(종료는 사람 몫)"
    return 0
  fi

  if [ "$dry_run" = 1 ]; then
    emit_closed "$repo" "$num" "$leaves_json"
    return 0
  fi

  # 마커 둘: `epic-sweep` 는 이 스크립트의 **멱등 판정 축**이고, `bodat:worker` 는 이
  # 레포의 기계 코멘트 표식이다(resume-sweep.sh 의 재개·승격 코멘트와 같은 관행).
  # 멱등은 `epic-sweep` 만 본다 — 표식이 바뀌어도 판정이 흔들리지 않게.
  ctext="leaf 전부 종료로 자동 종료 — leaf $leaves_txt <!-- epic-sweep --><!-- bodat:worker -->"
  # 코멘트를 **먼저**, close 는 그다음. 반대로 하면 close 가 성공하고 코멘트가 실패했을 때
  # 닫힌 에픽에 근거가 없다(사람이 왜 닫혔는지 못 읽고, 다음 틱은 열린 에픽만 보므로
  # 영영 안 고친다). 이 순서의 실패(코멘트만 남고 안 닫힘)는 위 마커 게이트 때문에 다음 틱이
  # 이어받지 못한다 — 그래서 close 는 `close_epic` 이 같은 틱에서 재시도한다.
  if ! gh issue comment "$num" --repo "$repo" --body "$ctext" >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "종료 근거 코멘트 실패 — 닫지 않는다(다음 틱 재시도)"
    rc=1
    return 0
  fi

  if ! close_epic "$repo" "$num"; then
    emit_warn "$repo" "$num" "에픽 close 실패(${EPIC_CLOSE_RETRIES}회 시도) — 근거 코멘트는 남았고 다음 틱은 그 마커를 되돌림으로 읽어 재시도하지 않는다: 사람이 직접 닫거나 마커 코멘트를 지워라"
    rc=1
    return 0
  fi
  emit_closed "$repo" "$num" "$leaves_json"
}

# ── 레포별 스윕 ───────────────────────────────────────────────────────────
for repo in "${repos[@]}"; do
  [ -n "$repo" ] || continue

  # `labels` 는 `deploy-wait` 방어(§되돌리지 마라)에 필요하다 — 같은 호출에 실어 오므로
  # gh 왕복은 늘지 않는다. `title` 은 이슈 #258 이 지정한 필드라 함께 받는다.
  if ! elist=$(gh issue list --repo "$repo" --label epic --state open \
        --limit "$EPIC_LIST_LIMIT" --json number,title,labels 2>/dev/null); then
    emit_warn "$repo" 0 "열린 epic 이슈 목록 조회 실패 — 이 레포는 건너뛴다"
    rc=1
    continue
  fi
  # 조회 실패를 "에픽 없음" 과 구분 못 하면 닫을 에픽이 조용히 영영 안 닫힌다.
  if ! printf '%s' "$elist" | jq -e 'type=="array"' >/dev/null 2>&1; then
    emit_warn "$repo" 0 "열린 epic 이슈 목록 파싱 실패 — 이 레포는 건너뛴다"
    rc=1
    continue
  fi
  ecount=$(printf '%s' "$elist" | jq 'length' 2>/dev/null) || ecount=0
  if [ "${ecount:-0}" -ge "$EPIC_LIST_LIMIT" ]; then
    # 상한에 닿았으면 잘렸을 수 있다 — 조용히 지나가면 "그 레포엔 닫을 에픽이 없다" 로
    # 위장된다. number 는 특정 이슈가 아니라는 뜻의 0.
    emit_warn "$repo" 0 "에픽 목록 상한 도달($EPIC_LIST_LIMIT) — 잘린 에픽은 이번 틱에 안 보인다"
  fi
  printf '%s' "$elist" | jq -c '.[]' > "$tmp/epics" 2>/dev/null || : > "$tmp/epics"

  # fd 3 으로 읽는다 — 안에서 부르는 gh 가 stdin 을 건드리면 목록이 통째로 먹힌다.
  while IFS= read -r erow <&3; do
    [ -n "$erow" ] || continue
    sweep_epic "$repo" "$erow"
  done 3< "$tmp/epics"
done

exit "$rc"
