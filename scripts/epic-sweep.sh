#!/usr/bin/env bash
# epic-sweep.sh — leaf 가 **전부 닫힌** 에픽을 닫는다 (#258, closeout ① Reconcile).
#
# 사용: epic-sweep.sh [--repos-file <경로>] [--repo <owner/repo>]... [--dry-run]
#   스코프: `--repo` 가 있으면 그것들, 없으면 `--repos-file`(기본 `$PWD/.loop/repos`).
#           둘 다 없으면 usage exit 64 — `loop-status.sh` 와 **같은 규약**.
#   환경변수: EPIC_LIST_LIMIT(기본 100) · EPIC_SEARCH_PER_PAGE(기본 100)
#             — 테스트가 상한 도달 경로를 100건짜리 픽스처 없이 재현하려고 열어 둔 값이다
#               (운영에서 내리는 값이 아니다 — 내리면 그만큼 잘리고, 잘림은 warn 으로 드러난다).
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
# `<!-- epic-sweep -->` 코멘트 마커가 보장한다: 마커가 이미 있으면 코멘트를 다시 달지 않고
# close 만 재시도한다(코멘트는 성공했는데 close 가 실패한 중간 상태의 재개 경로).
#
# 알려진 느슨함(숨기지 않는다): 마커 탐지는 인용 구간(코드펜스·백틱)을 걷어내지 않는다
# (resume-sweep.sh 의 `JQ_UNQUOTE` 같은 장치가 없다). 누군가 코멘트에 마커를 **인용**하면
# 그 틱은 코멘트를 건너뛰고 close 만 한다 — 방향이 "덜 쓴다" 쪽이고, 에픽 종료는 코멘트가
# 아니라 close 가 본체라 실질 피해가 없다. 반대 방향(마커를 못 봐서 코멘트가 하나 더 붙는
# 것)도 close 는 한 번뿐이라 마찬가지다.
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

# leaf 판정 — `loop-status.sh` 의 `epic_of`(#260)와 **같은 술어**다. 본문 **줄 시작**의
# `epic\s+#N`(대소문자 무시)의 **첫 매치**만 취한다: 한 이슈 = 최대 한 에픽.
# 검색(`in:body`)은 산문 매치도 돌려주므로 이 재확인이 없으면 `… epic #100 …` 을 지나가며
# 언급한 이슈가 leaf 로 잡혀 **남의 진척으로 에픽이 닫힌다**. 번호는 문자열 비교가 아니라
# **추출 후 수 비교**라 `Epic #1000` 이 `Epic #100` 의 leaf 로 새지 않는다.
# 이 capture 문자열이 loop-status.sh 와 갈라지면 두 계산기가 다른 leaf 를 센다 —
# scripts/tests/epic-sweep.test.sh ⑪ 이 두 파일에서 뽑아 대조한다.
JQ_EPIC_OF='def epic_of($body):
  ([($body // "") | split("\n")[]
      | capture("^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)"; "i") | .n]
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

  labels=$(printf '%s' "$row" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null) || labels=""
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
  local leaves_txt
  leaves_txt=$(printf '%s' "$leaves_json" | jq -r 'map("#" + tostring) | join(" ")' 2>/dev/null) || leaves_txt=""
  if [ "$dry_run" = 1 ]; then
    emit_closed "$repo" "$num" "$leaves_json"
    return 0
  fi

  # 멱등 — 마커가 이미 있으면 코멘트를 다시 달지 않는다(코멘트는 됐는데 close 가 실패한
  # 중간 상태의 재개 경로). 코멘트 전량은 `pr-comments.sh` 로 읽는다: `gh issue view
  # --json comments` 는 페이지네이션 없이 **첫 100건만** 주고, 그 상한을 넘긴 에픽은
  # 마커를 못 봐 매 틱 코멘트를 하나씩 더 붙인다(PR#173 교훈, 같은 함정의 이슈 판).
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

  if [ "$marker" -eq 0 ]; then
    ctext="leaf 전부 종료로 자동 종료 — leaf $leaves_txt <!-- epic-sweep --><!-- bodat:worker -->"
    # 코멘트를 **먼저**, close 는 그다음. 반대로 하면 close 가 성공하고 코멘트가 실패했을 때
    # 닫힌 에픽에 근거가 없다(사람이 왜 닫혔는지 못 읽고, 다음 틱은 열린 에픽만 보므로
    # 영영 안 고친다). 이 순서의 실패(코멘트만 남고 안 닫힘)는 다음 틱이 마커를 보고
    # 코멘트를 건너뛴 뒤 close 만 재시도한다.
    if ! gh issue comment "$num" --repo "$repo" --body "$ctext" >/dev/null 2>&1; then
      emit_warn "$repo" "$num" "종료 근거 코멘트 실패 — 닫지 않는다(다음 틱 재시도)"
      rc=1
      return 0
    fi
  fi

  if ! gh issue close "$num" --repo "$repo" --reason completed >/dev/null 2>&1; then
    emit_warn "$repo" "$num" "에픽 close 실패 — 근거 코멘트는 남았다(다음 틱이 close 만 재시도)"
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
