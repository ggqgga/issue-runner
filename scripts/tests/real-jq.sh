#!/usr/bin/env bash
# jq 스텁을 쓰는 격자(resume-sweep·epic-sweep)가 함께 source 하는 헬퍼 — 스텁이 넘길 진짜 jq 를 고른다.
# (#610) mise shim 은 비활성일 때 PATH 에서 다음 `jq` 를 찾아 넘기는데, 그게 PATH 맨 앞의 스텁이라
# 스텁↔shim 이 끝없이 돈다(m2 실측) — 그래서 shim 경로는 그대로 쓰지 않는다.
# (#614) 단 shim 을 버리기 전에 `mise which jq` 로 실바이너리를 풀어 본다 — jq 를 mise 로만 깐
# 박스는 PATH 의 jq 가 shim 하나뿐이다. mise 가 없거나 비활성이면 비0 → 다음 후보로.
# 진짜 jq 경로를 stdout 에 내고 0, 후보가 없으면 1.
pick_real_jq() {
  local c r
  for c in $(type -ap jq); do
    case "$c" in
      */mise/shims/*)
        r=$(mise which jq 2>/dev/null) || continue
        case "$r" in */mise/shims/*) continue ;; esac
        [ -x "$r" ] || continue
        echo "$r"; return 0 ;;
      *) echo "$c"; return 0 ;;
    esac
  done
  return 1
}
