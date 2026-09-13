#!/usr/bin/env bash
# §N 포인터 실재 가드 — bin/ci 인라인의 「[#507] SKILL 의 rationale·conventions §N
# 포인터」 블록을 통째로 옮긴 것 (분류표 Plans/ci-guard-classification.md L6 절
# 대상 행 86, #507 · #451 · #453). 이슈 #507 은 이 가드의 부모가 처리한다.
#
# 무엇을 무는가 — SKILL·워커 템플릿의 `(근거: <루프>-rationale §N)` ·
# `references/loop-conventions.md §N` 포인터가 **실재하는 절**만 가리키는지.
# 포인터를 읽는 스크립트가 없어 다음 편집이 번호만 바꾸거나 절을 지워도
# 아무도 못 잡는다. 대상 문서의 절 번호 중복도 빨강이다(포인터가 두 자리를 가리킨다).
#
# 대상 문서 확장 (#541) — 기존 넷(loop-conventions · issue-runner/verify-runner/
# closeout-rationale, `## §N`)에 references/scripts-rationale.md 를 더했다. 그 파일은
# 절 헤더가 `### §N`(스크립트별 `## <이름>.sh` 절 아래 중첩)이고 §N 이 스크립트마다
# 다시 1부터 매겨진다 — 그래서 ⑴ 헤더 수준을 문서별로 고르고 ⑵ 번호 중복 검사는
# 네 문서만 돈다. 스캔 대상 파일 목록(SKILL*·skills/*/SKILL*·worker-template*)은
# 그대로라 기존 네 문서의 판정은 한 건도 안 바뀐다(현재 스캔 집합에 scripts-rationale
# 포인터가 0건이므로 확장은 오늘 아무 판정도 바꾸지 않는다 — 앞으로 그 문서를
# 가리켜도 헛빨강이 안 나게 하는 관용이다).
#
# 실패 시 — 파일:줄과 포인터 원문, 없는 절 번호를 찍고 exit 1. 포인터를 한 건도
# 못 찾아도 빨강(인용 형태가 바뀌었다는 뜻이다). 초록이면 검사한 포인터 수를 찍는다.
#
# 만료 조건: 블록 주석이 이미 적었다 — 포인터를 앵커 링크로 바꾸고 링크 검사기가
# 들어오면 지운다.
set -euo pipefail
cd "$(dirname "$0")/../.."

# 문서별 절 헤더 수준 — scripts-rationale.md 만 `### §N` 이다(#541).
sec_hdr() {
  case "$1" in
    scripts-rationale) printf '###' ;;
    *) printf '##' ;;
  esac
}
# 3단계(#451)로 근거 서사는 references/<루프>-rationale.md 로, 공용 규약은 references/loop-conventions.md 로
# 갔다. SKILL 문단 끝 `(근거: <루프>-rationale §N)` · `references/loop-conventions.md §N` · 영문판의
# `(rationale §N)` 이 그 절로 가는 유일한 실인데, 이 포인터를 읽는 스크립트가 없어 다음 편집이 번호만
# 바꾸거나 절을 지워도 아무도 못 잡는다(#453 구현 보고 · #452 는 손으로 검산했다).
# 검사: 네 문서의 `## §N` 헤더 집합 ⊇ 인용 집합. 없는 절이면 파일:줄·포인터를 찍고 exit 1.
# 문서명 없는 `rationale §N` 은 인용 파일의 자리로 루프를 정한다(루트 SKILL* → issue-runner,
# skills/<루프>/SKILL* → <루프>). 문서 파일이 아직 없는 루프(closeout, #453 진행 중)는 인용이 0건인 동안만
# 건너뛴다 — 인용이 생기면 그 문서도 있어야 한다.
# 허용 형태(실측 전수): `<문서명>[.md][`] §N` 과 `·` 로 잇는 나열 `§N·§M` 만 — `§3, §4`·`§3~§5`·대문자
# `Rationale` 은 형태 자체가 없으니 잡지 않는다. 새 형태를 쓰려면 sec_re 를 같이 넓혀라.
# 만료 조건: 포인터를 앵커 링크로 바꾸고 링크 검사기가 들어오면 지운다.
sec_re='(loop-conventions|([a-z-]+-)?rationale)(\.md)?`? §[0-9]+(·§[0-9]+)*'
sec_fail=0; sec_n=0
for doc in loop-conventions issue-runner-rationale verify-runner-rationale closeout-rationale scripts-rationale; do
  [ -f "references/$doc.md" ] || continue
  sec_hd=$(sec_hdr "$doc")
  sec_h=$(grep -oE "^$sec_hd §[0-9]+" "references/$doc.md" | sed "s/^$sec_hd §//")
  [ -n "$sec_h" ] || { echo "  ✗ references/$doc.md: '$sec_hd §N' 헤더가 0개 — 형식이 바뀌었으면 이 검사도 같이 옮겨라"; exit 1; }
  # 번호 중복 검사는 네 문서만 — scripts-rationale.md 는 §N 이 `## <스크립트>.sh` 절
  # 안에서 다시 1부터 매겨져 파일 전체로는 정상적으로 중복한다(#541).
  if [ "$doc" != scripts-rationale ]; then
    sec_d=$(printf '%s\n' "$sec_h" | sort -n | uniq -d | sed 's/^/§/' | tr '\n' ' ')
    [ -z "$sec_d" ] || { echo "  ✗ references/$doc.md: 절 번호 중복 — ${sec_d% }"; sec_fail=1; }
  fi
done
for f in SKILL.md SKILL.en.md skills/*/SKILL*.md references/worker-template*.md; do
  # 아래 `grep … || true` 는 미매치(exit 1)와 파일 부재(exit 2)를 같이 삼킨다 — 부재는 여기서 먼저 닫는다.
  [ -f "$f" ] || { echo "  ✗ $f 없음 — 인용 파일 목록이 실제 파일과 어긋났다"; exit 1; }
  case "$f" in
    SKILL*.md) sec_own=issue-runner-rationale ;;
    skills/*/SKILL*.md) sec_own="$(basename "$(dirname "$f")")-rationale" ;;
    *) sec_own="" ;;
  esac
  while IFS=: read -r ln m; do
    [ -n "$m" ] || continue
    sec_n=$((sec_n + 1))
    name=${m%% §*}; name=${name%\`}; name=${name%.md}
    case "$name" in
      rationale) doc="$sec_own" ;;
      *) doc="$name" ;;
    esac
    [ -n "$doc" ] || { echo "  ✗ $f:$ln: '$m' — 문서명 없는 rationale 포인터인데 파일 자리로 루프를 정할 수 없다"; sec_fail=1; continue; }
    [ -f "references/$doc.md" ] || { echo "  ✗ $f:$ln: '$m' → references/$doc.md 없음"; sec_fail=1; continue; }
    # 헤더 수준은 **포인터가 가리키는 문서**로 다시 고른다 — 위 수집 루프의 값이
    # 새어 들어오면 scripts-rationale 인용이 `## §N` 로 검사돼 헛빨강이 난다(#541).
    sec_hd=$(sec_hdr "$doc")
    for n in $(printf '%s' "${m#* }" | grep -oE '[0-9]+'); do
      grep -qE "^$sec_hd §$n( |$)" "references/$doc.md" \
        || { echo "  ✗ $f:$ln: '$m' — references/$doc.md 에 §$n 절 없음"; sec_fail=1; }
    done
  done < <(grep -noE "$sec_re" "$f" || true)
done
[ "$sec_n" -gt 0 ] || { echo "  ✗ §N 포인터를 한 건도 못 찾았다 — 인용 형태가 바뀌었으면 sec_re 를 같이 옮겨라"; exit 1; }
[ "$sec_fail" = 0 ] || exit 1
echo "  포인터 ${sec_n}건 검사"
