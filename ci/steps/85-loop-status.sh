#!/usr/bin/env bash
# 단계 10 — loop-status.sh 의 에픽 닫힌 leaf 조회 형태. `--state closed` 플래그 · `is:closed`
# 금지(gh 오파싱 실측 #236) · `--limit "$EPIC_CLOSED_LIMIT"`. 형태가 뒤집히면 닫힌 leaf
# 수가 통째로 틀리는데 출력은 멀쩡해 보인다.
#
# 실패 시: `  ✗ scripts/loop-status.sh 의 … 예상 형태가 아니다` 한 줄 + exit 1.
#
# 담은 블록 (원 bin/ci 577–619행 · 분류표 행 83 · 부행 83-a · #292 · #236 · #190 · #191):
#   • [#292] loop-status 에픽 닫힌 leaf 조회 — 검색 쿼리 형태·헤더 계약
#
# epic_of 1벌 축(83-b)은 ci/guards/single-definition.sh, 헤더 주석 계약 축(83-c)은
# ci/guards/prose-regression.sh 로 갔다 — 단계 3 이 부른다.
#
# 만료 조건: scripts/tests/loop-status.test.sh 가 gh 인자를 캡처해 이 조회 형태를
# 행동으로 물면 즉시(분류표 83-a 「ⓐ 후보」).
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "[#292] loop-status 에픽 닫힌 leaf 조회 — 검색 쿼리 형태·단일 epic_of·헤더 계약"
# ⑴ 상태는 **`--state closed` 플래그**로 준다. 쿼리 문자열의 `is:closed` 는 `gh` 가
#    오파싱한 실측 전례가 있다(#236 — resume-sweep.sh 가 같은 이유로 플래그로 옮겼다).
#    형태가 뒤집히면 조회가 열린 이슈까지 물어 닫힌 leaf 수가 통째로 틀린다.
#    검사 대상은 **코드 줄만**이다(양쪽 다). 헤더/인라인 주석이 이 조회 형태를 그대로
#    인용하므로, 주석까지 세면 **코드만 되돌려도 초록**이 된다(사전 리뷰 실측: `--state all`
#    이나 `--search` 절 삭제로 되돌린 사본이 이 블록을 통째로 통과했다). 반대로 `is:closed`
#    금지는 주석이 왜 안 쓰는지 설명하며 그 문자열을 인용하니 주석을 세면 자기 근거를 금지한다.
#    한 번만 뽑아 둘 다 이 변수로 본다 — 파일이 없으면 빈 문자열이라 아래 첫 검사가
#    바로 빨개진다(fail-closed).
#    `grep -q` 에는 **here-string** 으로 준다(`printf … | grep -q` 가 아니라): `$ls_code` 는
#    40KB 가 넘고 `-q` 는 첫 매치에서 끊으므로, 파이프 버퍼가 작게 잡힌 박스(pipe 메모리
#    압박)에서는 아직 못 쓴 뒤쪽을 들고 있던 printf 가 SIGPIPE(141) 로 죽고 `pipefail` 이
#    그것을 "매치 없음" 으로 읽는다 — 문자열이 실재하는 트리에서 이 줄이 빨갛게 뜬 실측
#    (local-ci 96bbde2c, #343). here-string 은 임시 파일이라 읽는 쪽이 먼저 끝나도 무해하다.
ls_code=$(grep -vE '^[[:space:]]*#' scripts/loop-status.sh || true)
grep -qF -- "--state closed --search '\"Epic #\" in:body'" <<<"$ls_code" \
  || { echo "  ✗ scripts/loop-status.sh 의 에픽 닫힌 leaf 조회(코드)가 예상 형태가 아니다(--state closed 플래그 + \"Epic #\" in:body)"; exit 1; }
if printf '%s\n' "$ls_code" | grep -nF -- 'is:closed'; then
  echo "  ✗ scripts/loop-status.sh 검색 쿼리(코드)에 is:closed 가 들어갔다 — gh 가 오파싱한다(#236). --state closed 플래그로"
  exit 1
fi
#    `--limit` 이 `EPIC_CLOSED_LIMIT` 로 전달되는지도 코드 줄에서 센다 — 리터럴 상한으로
#    되돌리면 창이 PR 이전으로 돌아가는데 상한 판정은 env 를 읽어 `capped` 도 안 뜬다.
grep -qF -- '--limit "$EPIC_CLOSED_LIMIT"' <<<"$ls_code" \
  || { echo "  ✗ scripts/loop-status.sh 의 에픽 닫힌 leaf 조회가 --limit \"\$EPIC_CLOSED_LIMIT\" 로 안 간다(#292)"; exit 1; }
# ⑵ `epic_of` 정규식은 이 파일에 **한 벌**뿐이어야 한다(이슈 #292 개발 계획 3항).
#    복제본이 생기면 두 계산기가 서로 다른 leaf 를 세고, 그 차이는 출력에 안 보인다.
#    `-F` 로 고정 문자열 비교한다 — 이 패턴 자체가 정규식 메타문자 덩어리라 BRE 로 적으면
#    이스케이프 하나가 어긋나도 **0벌**이 되어 가드가 조용히 통과한다(실제로 그렇게 틀렸다).
#    `set -e` 아래라 `grep -c` 가 0매치로 exit 1 하면 스크립트가 죽으므로 `|| true` 로 받는다.
#    성격 주의: 이건 **미래의 복제를 막는 불변식**이지 이 PR 의 되돌림 탐지기가 아니다 —
#    merge-base 에서도 이미 한 벌이었다(전체 되돌림 트리에서도 이 조항은 초록이다).
# ⑶ 헤더 주석 계약이 코드와 같은 조건을 광고하는지 (#191 — 코드만 좁히면 헤더가 옛
#    조건을 계속 가르친다). 닫힌 이슈 200건 절단 warn 은 없앴고, 새 자리는 EPIC_CLOSED_LIMIT 다.
#    이 루프는 **주석을 일부러 센다** — 헤더 동기화가 검사 대상이라서다. 코드 되돌림은
#    위 ⑴(코드 줄 전용)과 스위트가 맡는다. 둘을 같은 조항으로 섞지 마라.
#    닫힌 이슈(최근 200건) 절단 warn 이 되살아나면 빨강. **렌더된 문자열이 아니라 후보
#    목록의 항목**을 본다 — warn 문구는 `"목록 상한 200 도달 — 창 절단 가능(\(.what))"`
#    처럼 jq 보간으로 만들어지므로 `창 절단 가능(닫힌 이슈)` 리터럴은 **되돌린 트리에도
#    없다**(merge-base `19cba3c8:scripts/loop-status.sh:826,831` 실측 — 옛 코드도 보간형).
#    리터럴로 적으면 태어날 때부터 죽은 조항이 된다.

