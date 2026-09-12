# 루프 판정 술어 — **한 자리** (#426 · 플랜 1단계)
#
# 사용: jq -L "$SCRIPT_DIR/lib" '... include "loop"; <필터>'
#   `include "loop";` 는 필터의 **첫 문장**이어야 한다(주석은 앞에 와도 된다).
#   `-L` 은 **절대경로**로 준다 — 소비처는 임의의 cwd 에서 불린다(루프 세션 cwd·워크트리·
#   테스트 임시 디렉터리). 상대경로면 그 순간 include 가 조용히 실패하고, 그 스크립트의
#   판정이 통째로 빈 값이 된다.
#
# ── 규율: 코멘트끼리는 인덱스, 코멘트 vs 커밋은 시각 ────────────────────────
# 두 판정 축이 있고 **섞으면 안 된다**.
#   ⑴ 코멘트 A 와 코멘트 B 중 어느 것이 나중인가 → **배열 인덱스**(`last_index`).
#      `createdAt` 은 초 단위라 같은 초에 연달아 달린 두 코멘트의 선후를 못 가른다
#      (반송 마커와 그 직후 판정이 실제로 그 모양이다 — #196·#218). GitHub 이 돌려주는
#      코멘트 배열의 순서가 곧 게시 순서이므로 인덱스가 유일하게 결정론적인 축이다.
#   ⑵ 코멘트와 **커밋**(head) 중 어느 것이 나중인가 → **시각**(ISO8601 → epoch).
#      두 대상이 같은 배열에 살지 않으므로 인덱스 축이 아예 없다. 그래서 `머지 판정: ✅`
#      의 신선도(#171)와 1단계 마커의 신선도(#271)는 시각으로 잰다 — 그리고 시각을
#      **못 얻으면 판정하지 않는다**(증명 실패는 통과가 아니다).
# 두 축을 섞은 판이 실제로 사고를 냈다(finish-classify 는 createdAt, bounce-state 는
# 인덱스로 같은 질문에 답하고 있었다). 새 술어를 더할 때 이 문단이 어느 축인지 먼저 정하라.
#
# ── 왜 타입 가드를 안 넣는가 ────────────────────────────────────────────────
# 아래 접두 술어들은 입력이 문자열이 아니면 **에러**다(`startswith` 가 던진다). 일부러다:
# 소비처 몇 곳(closeout-eligible 의 긍정 게이트)이 그 에러를 `2>/dev/null` + 빈 출력으로
# 받아 **fail-closed**(후보 탈락)로 쓴다. 술어에 `(type=="string") and …` 를 넣으면 그
# 자리가 조용히 fail-open 이 된다. 방어가 필요한 자리는 소비처가 `.body // ""` 로 감싼다
# (reconcile 이 그렇게 한다).

# ── 판정 코멘트 (`머지 판정: <기호>` / `Merge verdict: <기호>`) ──────────────
# 기호까지 **정확히** 무는 술어다. 한/영 워커가 섞여 있어 두 접두를 다 본다.
def is_verdict_ok:      startswith("머지 판정: ✅") or startswith("Merge verdict: ✅");
def is_verdict_pending: startswith("머지 판정: 🔄") or startswith("Merge verdict: 🔄");
def is_verdict_hold:    startswith("머지 판정: ⚠")  or startswith("Merge verdict: ⚠");
def is_verdict_any:     is_verdict_ok or is_verdict_pending or is_verdict_hold;

# 기호 **없이** 접두만 보는 술어. "판정 코멘트가 한 건이라도 있는가"(#396 no_verdict)와
# "마지막 판정성 코멘트가 무엇인가"(reconcile 반쯤 이동)를 재는 자리가 쓴다 —
# 기호 술어와 다른 질문이므로 합치지 마라(`머지 판정: ` 뒤에 우리가 모르는 기호가 온
# 코멘트도 "판정 코멘트는 있다" 쪽에 세어야 한다).
def has_verdict_prefix:  startswith("머지 판정") or startswith("Merge verdict");
def has_verifier_prefix: startswith("검증자 리뷰") or startswith("Verifier review");

# 1단계 마감 검증 마커(closeout ③-1). 한글 접두 하나뿐이다 — 이 코멘트를 내는 자리가
# closeout SKILL 한/영 모두에서 한글 문안을 쓴다.
def has_closeout_prefix: startswith("마감 검증");
def is_closeout_ok:      startswith("마감 검증: ✅");

# ── 머신 코멘트 판정 (#72) ──────────────────────────────────────────────────
# 센티널 `<!-- bodat:worker -->` 는 **위치 무관**(contains)이다 — 워커가 마지막 줄에 정확히
# 못 둬도 머신으로 인식하는 쪽이 robust 하다. 마지막-줄 강제로 바꾸지 마라(#72 false-positive
# 재발). 레거시 3접두는 마커 도입 이전 PR 을 위한 **동결 폴백**이고 더 키우지 않는다.
#
# ⚠ 한글 접두만이다 — 영문(`Merge verdict`/`Verifier review`)을 넣지 않는다. 넣으면 마커
# 없는 영문 코멘트가 새로 "머신" 으로 세어져 미해결 사람 리뷰 수가 **줄고**, 그만큼 머지
# 게이트가 열린다(합집합이 이 자리에선 fail-open 방향이다). 종전 동작 그대로 동결 (#426).
def is_machine:
  contains("<!-- bodat:worker -->")
  or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증");

# ── 반송 코멘트 접두 (#212) ─────────────────────────────────────────────────
# 콜론을 요구하지 않는다 — 워커가 남기는 `재디스패치 attempt 3 — …` 같은 변형이 리터럴
# 불일치로 빠져나가면 fail-open 이다(bounce-state.sh 머리 주석 ⒜⒝⒞). 영문 판은 없다:
# 반송 코멘트를 내는 자리는 `bounce-comment.sh` 하나뿐이고 그 본문은 한글이다.
#
# ⚠ `bounce-state.sh` 의 **마커 판정 문법**(구분자·조사·표식 어휘 3갈래)은 여기 없다.
# 그것은 접두 매칭이 아니라 접두 **뒤에 오는 글자**로 반송/산문을 가르는 판정기이고,
# 뮤테이션 테스트(MUT-1·2·A·V)가 그 줄 형태를 앵커로 물고 있다. 접두 집합만 공유한다.
def is_bounce: startswith("재검증 실패") or startswith("재디스패치");

# ── 마지막 매칭 인덱스 ──────────────────────────────────────────────────────
# last_index(f) — 배열에서 `f` 가 참인 **마지막** 원소의 인덱스. 없으면 `null`.
# `null` 을 그대로 낸다(빈 문자열이 아니다) — 셸로 꺼내는 소비처는 `// empty` 를 붙여
# "없음" 을 빈 출력으로 받고, jq 안에서 쓰는 소비처는 `== null` 로 가른다.
# **존재 검사로 대신하지 마라**: `✅ 가 있는가` 는 그 뒤에 온 더 늦은 `⚠` 를 못 본다
# (#218 attempt 3 이 밟은 함정 — 먼저 참이 된 분기에서 빠져나온다).
def last_index(f): [ to_entries[] | select(.value | f) | .key ] | last;

# ── 라벨 집합 ───────────────────────────────────────────────────────────────
# 입력은 **라벨 이름 하나**(is_*) 또는 **이름 배열**(*_labels). 라벨 경계는 배열이지
# 쉼표가 아니다 (#266) — 이어 붙인 문자열에서 찾으면 쉼표를 품은 라벨명이 쪼개진다.
def is_human_stop_label: . == "needs-human";        # 사람이 직접 세운 정지 (#244)
def is_hold_label:       startswith("hold:");       # 기계 정지 — **접두** 판별(사유가 늘어도 안 깨진다)
def is_stop_label:       is_human_stop_label or is_hold_label;
# 소유(점유) 라벨 — "이 PR/이슈를 지금 누가 들고 있는가". `flow:agent-ready` 는 대기 칸이라
# 소유가 아니다(reconcile 의 반쯤 이동 판정이 그 예외를 쓴다).
def is_owner_label:      (startswith("flow:") and . != "flow:agent-ready") or . == "verifying" or . == "harvesting";
# 다운스트림 레인 4벌 — 이슈에 미러된 이 라벨들이 있으면 구현은 끝났고 소유가 넘어갔다.
# 정확 일치다(`verified`·`verifying-x` 는 안 걸린다). claim-issue·eligible-issues 공용.
def is_downstream_label: . == "flow:verify" or . == "verifying" or . == "flow:ready" or . == "harvesting";
def stop_labels:  map(select(is_stop_label));
def hold_labels:  map(select(is_hold_label));
def owner_labels: map(select(is_owner_label));
def stage_labels: map(select(startswith("flow:")));

# ── 레포 짧은 이름 ──────────────────────────────────────────────────────────
# `owner/repo` → repo 부분 소문자. `issue-runner` 만 `runner` 특례(화면 폭).
def short_repo:
  (split("/") | last) as $r
  | if $r == "issue-runner" or $r == "Issue-Runner" then "runner" else ($r | ascii_downcase) end;
