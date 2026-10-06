# 훅 입력 명령에서 "어느 디렉터리에 대한 명령인가"를 푸는 한 자리 (#586)
# shellcheck shell=bash
#
# 소비처 둘: hooks/local-ci.sh(push 한 레포 ROOT) · hooks/guard-ci-root.sh(테스트·커밋·삭제 대상).
# 두 훅이 같은 명령 문자열을 서로 다르게 읽으면 "CI 는 A 에 걸렸는데 가드는 B 를 본다"가 된다.
# 해석은 의도적으로 좁다 — 명령 **선두**의 `cd <경로> &&|;` 한 번만 인정한다(`(cd x && …)`·
# `cd a && cd b` 는 해석하지 않고 cwd 로 떨어진다). 셸 파서를 흉내 내지 않는다.

# lead_cd_path <cmd> — 선두 `cd <경로> &&|;` 의 경로(따옴표 벗김, 전개 전). 없으면 빈 출력.
lead_cd_path() {
  printf '%s' "$1" \
    | sed -n -E 's/^[[:space:]]*cd[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^;&|[:space:]]+))[[:space:]]*(&&|;).*/\2\3\4/p' \
    | head -1
}

# resolve_path <path> <base> — `~` 전개, 상대경로는 base 기준. 존재 여부는 보지 않는다.
resolve_path() {
  case "$1" in
    \~|\~/*) printf '%s' "$HOME${1#\~}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$2/$1" ;;
  esac
}

# git_c_path <cmd> — 첫 `git -C <경로>` 의 경로(따옴표 벗김, 전개 전). 없으면 빈 출력.
git_c_path() {
  printf '%s' "$1" \
    | sed -n -E 's/.*git[[:space:]]+-C[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:];|&]+)).*/\2\3\4/p' | head -1
}

# worktree_rm_path <cmd> — `git worktree remove [-옵션…] <경로>` 의 경로. 없으면 빈 출력.
worktree_rm_path() {
  printf '%s' "$1" \
    | sed -n -E 's/.*worktree[[:space:]]+remove([[:space:]]+-[^[:space:]]+)*[[:space:]]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^-[:space:];|&'"'"'"][^[:space:];|&]*)).*/\3\4\5/p' \
    | head -1
}
