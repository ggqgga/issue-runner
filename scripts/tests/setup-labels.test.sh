#!/usr/bin/env bash
# setup-labels.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# #346: GitHub 라벨 `description` 상한은 **100자**다. 넘으면 `gh label create --force` 가
# validation 으로 실패하고, 이 스크립트는 `set -euo pipefail` 이라 그 뒤의 라벨·레포 설정이
# **전부 중단**된다(실측: hold:conflict 설명 138자 → 이후 라벨 미생성). 옵트인한 레포가
# 라벨 절반만 갖게 되고, 그 레포에서 `transition.sh` 의 `--add-label` 이 통째로 실패한다.
#
# 그래서 문구를 grep 으로 재는 대신 **스크립트를 실제로 돌린다**: 스텁이 GitHub 의 100자
# validation 을 흉내내 위반 시 비0 을 내고, 테스트는 SUT 가 끝까지 살아 라벨 세트를 다
# 만들었는지를 본다. 인자를 확장된 argv 로 받으므로 「설명이 한 줄 안에 닫혀 있어야 센다」
# 는 옛 grep 의 사각지대가 없다.
#
# 무는 것:
#   ⑴ 모든 `gh label create` 가 성공한다 = 설명이 전부 100자 이하다 (SUT exit 0)
#   ⑵ 라벨 세트가 **전부** 만들어진다 — 중간에 멎으면 개수가 준다
#   ⑶ 모든 라벨 생성에 `--description` 이 붙는다 (길이 검사가 전수인지의 근거)
#   ⑷ 음성 대조 — 상한을 낮춘 스텁에서는 실제로 빨강이 된다(픽스처가 공허하지 않다는 증거)
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/setup-labels.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

# gh 스텁 — `--description` 값이 $STUB_DESC_MAX 자를 넘으면 GitHub 처럼 실패하고(문자 기준 —
# 한글 설명이라 바이트로 재면 전부 빨갛다), **성공한 호출만** `--CALL--` 뒤에 argv 를 한 줄씩
# 남긴다(실패한 호출은 라벨을 만들지 못했으므로 세면 안 된다).
cat > "$tmp/stub/gh" <<'STUB'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--description" ]; then
    len=$(printf '%s' "$a" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
    if [ "$len" -gt "${STUB_DESC_MAX:-100}" ]; then
      echo "gh: validation failed — description is too long ($len)" >&2
      exit 1
    fi
  fi
  prev="$a"
done
{
  echo "--CALL--"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$STUB_LOG"
exit 0
STUB
chmod +x "$tmp/stub/gh"

# 로그에서 `label create` 호출 수 · `--description` 을 가진 호출 수를 센다.
count_calls() {  # count_calls <로그> → "<label create 수> <--description 가진 수>"
  awk '
    /^--CALL--$/ { if (n >= 2 && a1 == "label" && a2 == "create") { created++; if (hasdesc) withdesc++ }
                   i = 0; n = 0; hasdesc = 0; a1 = ""; a2 = ""; next }
    { n++; i++
      if (i == 1) a1 = $0
      if (i == 2) a2 = $0
      if ($0 == "--description") hasdesc = 1 }
    END { if (n >= 2 && a1 == "label" && a2 == "create") { created++; if (hasdesc) withdesc++ }
          printf "%d %d\n", created + 0, withdesc + 0 }
  ' "$1"
}

run_sut() {  # run_sut <로그> [상한] — RC 를 채운다
  : > "$1"
  RC=0
  STUB_LOG="$1" STUB_DESC_MAX="${2:-100}" PATH="$tmp/stub:$PATH" \
    bash "$SUT" o/r >/dev/null 2>"$tmp/err" || RC=$?
}

echo "── 라벨 세트 생성 (설명 100자 상한, #346) ─────────────────────────"

run_sut "$tmp/log"
counts=$(count_calls "$tmp/log")
created=${counts%% *}; withdesc=${counts##* }

# ⑴ 끝까지 살았다 = 설명이 전부 100자 이하다
[ "$RC" = 0 ] && ok \
  || bad "⑴ exit $RC — 설명이 100자를 넘어 gh 가 실패했고 set -e 로 뒤가 멈췄다: $(cat "$tmp/err")"

# ⑵ 라벨 세트가 전부 만들어졌다. 기대치 둘을 함께 건다:
#    ⓐ 스크립트가 정의한 `gh label create` 줄 수와 같다 — 중간에 멎으면 어긋난다.
#    ⓑ 하한 23. ⓐ 만 두면 기대치가 소스와 함께 움직여, 라벨 **정의를 지웠을 때** 둘 다
#      내려가 초록이 된다. 이 하한은 라벨을 의도적으로 뺄 때만 같이 내린다 — 「이 축 정리는
#      추가와 설명 변경만 한다」(#245)가 그 규율이고, 라벨을 더하는 쪽은 이 단언을 안 깬다.
defined=$(grep -c '^gh label create ' "$SUT")
{ [ "$created" = "$defined" ] && [ "$created" -ge 23 ]; } && ok \
  || bad "⑵ 라벨 생성 $created 건 (정의 $defined 건 · 하한 23) — 중간에 멎었거나 라벨 정의가 사라졌다"

# ⑶ 길이 검사가 전수인지의 근거 — 설명 없는 라벨이 있으면 그 라벨은 검사 밖이다
[ "$withdesc" = "$created" ] && ok \
  || bad "⑶ --description 없는 라벨 생성 $((created - withdesc)) 건 — 길이 검사가 전수가 아니다"

echo "── 음성 대조: 상한을 10자로 낮추면 빨강이어야 한다 ────────────────"

# ⑷ 스텁이 정말 무는지 — 상한을 낮추면 SUT 가 비0 으로 죽고 라벨 수가 준다.
#    (이 대조가 없으면 위 셋은 "스텁이 늘 0 을 낸다" 로도 초록이 된다.)
run_sut "$tmp/log2" 10
counts=$(count_calls "$tmp/log2")
created2=${counts%% *}
[ "$RC" != 0 ] && ok || bad "⑷ 상한 10자인데 exit 0 — 스텁의 validation 이 안 물었다"
[ "$created2" -lt "$defined" ] && ok || bad "⑷ 상한 10자인데 라벨이 $created2 건 다 만들어졌다"

echo "setup-labels.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
