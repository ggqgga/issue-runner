<!-- 이 파일은 **이슈 본문 전용** 템플릿이다 — 라벨을 여기 적지 마라(본문에 렌더된다).
     라벨은 발행 명령줄에서 준다: `gh issue create ... --label agent-ready --label "$priority"`
     + 레포 규약 라벨. `--label agent-ready` 가 빠지면 issue-runner 가 영원히 안 집는다
     (SKILL 6단계 '발행 명령' 절).
     **라벨은 명령줄, `Epic` 줄은 본문 첫 줄이다** — 이 둘을 바꿔 적지 마라. 에픽은
     라벨이 아니라 본문 `Epic #N` **전용 줄**로 잇는다(#260 loop-status 에픽 절이 그 줄로
     leaf 를 센다). 아래 `<EPIC_LINE>` 은 `$SCRIPTS/spinoff-inherit.sh` 가 낸 값으로 채운다 —
     `epic=N` 이면 `Epic #N` 한 줄, `epic=-` 이면 **빈 줄**.
     `<ORIGIN_LINE>` 은 `Spinoff of PR #<pr> (issue #<부모>)` 한 줄 — 어느 PR·이슈에서 왔는지
     기계와 사람이 같은 자리에서 읽는다(#411). 스크립트가 채우니 손으로 적지 마라. -->
<EPIC_LINE>
<ORIGIN_LINE>

## 배경
<BACKGROUND>

## 왜 필요한가
<REASON>

## 개발 계획
<PLAN>

## Test plan
<TEST_PLAN>

## 연관
<RELATED>
