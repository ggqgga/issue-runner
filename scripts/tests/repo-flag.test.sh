#!/usr/bin/env bash
# repo-flag.sh · repo-dir.sh 픽스처 테스트 — 네트워크 무접속(둘 다 repos.conf 만 읽는다).
#
# #109: repos.conf 한 줄은 `<owner/repo> <절대경로> [flag ...]` 다. 두 스크립트가 같은
# 줄을 서로 다른 자리에서 읽으므로(플래그는 3필드 이후, 경로는 2필드) 파싱이 어긋나면
# "플래그를 켰는데 안 켜진다"·"경로만 주려다 플래그가 붙는다" 가 조용히 난다. 무는 것:
#   ⑴ 3번째 이후 필드만 플래그다 — 경로(2필드)가 플래그로 읽히면 안 된다
#   ⑵ `#` 로 시작하는 줄은 주석이라 매칭 대상이 아니다
#   ⑶ conf 에 없는 레포·conf 파일 자체 부재는 **off**(기본 안전값 — 시크릿 심링크가
#      의도 없이 켜지는 쪽으로 실수하지 않는다)
#   ⑷ 경로 자리 `-` 는 "기본 경로 해석으로 폴백" 이다(플래그만 주는 줄) — repo-dir.sh 가
#      `-` 를 경로로 쓰면 워크트리가 `./-/…` 에 생긴다
#   ⑸ conf 매핑이 없는 레포는 $ISSUE_RUNNER_PROJECTS_ROOT/<repo-name> 로 해석된다
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLAG="$DIR/repo-flag.sh"
RDIR="$DIR/repo-dir.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

cat > "$tmp/repos.conf" <<'EOF'
# acme/commented /x link-secrets
acme/plain /path/to/plain
acme/flagged /path/to/flagged link-secrets
acme/multi /path/to/multi other-flag link-secrets
acme/dashpath - link-secrets
EOF

# 경로 해석 기준점 — 존재하지 않는 디렉토리를 쓴다(repo-dir.sh 는 존재할 때만 pwd -P 로
# 정규화하므로, 존재하지 않으면 문자열 그대로 나와 macOS /tmp→/private 심링크와 무관해진다).
ROOT="$tmp/projects"

rflag() {  # rflag <repo> — RC 를 채운다
  ISSUE_RUNNER_REPOS_CONF="$tmp/repos.conf" bash "$FLAG" "$1" link-secrets >/dev/null 2>&1
  RC=$?
}
rdir() {  # rdir <conf> <repo> — OUT/RC 를 채운다
  OUT=$(ISSUE_RUNNER_REPOS_CONF="$1" ISSUE_RUNNER_PROJECTS_ROOT="$ROOT" bash "$RDIR" "$2" 2>/dev/null)
  RC=$?
}

echo "── repo-flag.sh repos.conf 플래그 파싱 ────────────────────────────"

# ① 플래그가 있는 줄 → 0
rflag acme/flagged
[ "$RC" = 0 ] && ok || bad "① 플래그 있는 줄을 못 읽음 rc=$RC"

# ② 플래그가 여럿인 줄의 **뒤쪽** 플래그도 읽는다(3필드만 보면 놓친다)
rflag acme/multi
[ "$RC" = 0 ] && ok || bad "② 플래그 2개 중 뒤쪽을 못 읽음 rc=$RC"

# ③ 플래그가 없는 줄 → 1 (경로 필드를 플래그로 읽으면 여기가 0 이 된다)
rflag acme/plain
[ "$RC" != 0 ] && ok || bad "③ 플래그 없는 줄이 통과했다"

# ④ 주석 줄은 매칭 대상이 아니다
rflag acme/commented
[ "$RC" != 0 ] && ok || bad "④ 주석 줄이 통과했다"

# ⑤ conf 에 없는 레포 → off
rflag acme/absent
[ "$RC" != 0 ] && ok || bad "⑤ conf 에 없는 레포가 통과했다"

# ⑥ conf 파일 자체가 없으면 전부 off (기본 안전값)
RC=0
ISSUE_RUNNER_REPOS_CONF="$tmp/nope.conf" bash "$FLAG" acme/flagged link-secrets >/dev/null 2>&1 || RC=$?
[ "$RC" != 0 ] && ok || bad "⑥ conf 부재인데 통과했다"

echo "── repo-dir.sh 경로 해석 ─────────────────────────────────────────"

# ⑦ 경로 자리 `-` → 기본 경로 해석으로 폴백(플래그만 주는 줄)
rdir "$tmp/repos.conf" acme/dashpath
{ [ "$RC" = 0 ] && [ "$OUT" = "$ROOT/dashpath" ]; } && ok \
  || bad "⑦ '-' 경로 폴백 실패 rc=$RC out=[$OUT] 기대=[$ROOT/dashpath]"

# ⑧ conf 에 매핑이 있으면 그 경로를 그대로 낸다(폴백이 매핑을 먹으면 안 된다)
rdir "$tmp/repos.conf" acme/plain
[ "$OUT" = "/path/to/plain" ] && ok || bad "⑧ conf 매핑 경로가 아니다: [$OUT]"

# ⑨ conf 매핑이 없는 레포 → $ISSUE_RUNNER_PROJECTS_ROOT/<repo-name>
rdir "$tmp/nope.conf" owner/some-repo
{ [ "$RC" = 0 ] && [ "$OUT" = "$ROOT/some-repo" ]; } && ok \
  || bad "⑨ 기본 경로 해석 실패 rc=$RC out=[$OUT] 기대=[$ROOT/some-repo]"

echo "repo-flag.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
