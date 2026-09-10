production 배포 후 UI 회귀를 Chrome 스모크로 대조하라. 배포 이슈 본문의 검증 항목을
한 건씩 chrome-devtools MCP 로 production 을 직접 구동해 통과·실패를 판정한다.

**구동 절차** — chrome-devtools MCP 도구를 ToolSearch 로 로드한 뒤:
0. **진입 정리(멱등 — 크래시 재개 방어):** `list_pages` 로 이전 틱이 정리 전에 죽어
   남긴 스모크 페이지가 있으면 `close_page` 로 먼저 닫는다.
1. `navigate_page` 로 베이스 URL `<VERIFY_URL>` 에 진입한다.
2. 아래 검증 항목 각각에 대해 `take_snapshot`/`evaluate_script` 로 화면을 대조해
   항목별 pass/fail 을 산출한다. 항목이 산문("상단 인프라 탭 → /infra 렌더")이면
   LLM 해석으로 대상 경로/요소를 정하고 실제 렌더를 확인한다.
3. 데이터 0 화면은 빈 상태까지만 실증 가능 — 결과에 "구조/빈 상태 확인"과
   "실 데이터 렌더 확인"을 구분 표기한다.
4. **정리(공통 종료 — 누수 방지):** 판정 산출 후, 이 스모크가 연 페이지를 `close_page`
   로 반드시 닫는다(pass·fail 어느 경로든 예외 없이). 프로덕션 페이지엔 클라이언트
   폴러가 살아 있어 좌존 탭이 CPU 를 스핀하며 누적된다 — 남기지 마라. 브라우저를 아예
   안 열었으면(degrade) 정리 대상 없음(단 도달 불가 판정용 `navigate_page` 로 에러 탭이
   열렸으면 그 탭도 close 한다).

**저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 도구가 세션에 없거나
(헤드리스/크론 환경) `<VERIFY_URL>` 이 도달 불가면, 스모크를 건너뛰고
`스모크 skip: <사유>` 로 보고한다 (누락 은폐 금지 — 사람-보고 폴백 경로로 넘긴다).

**skip 하기 전에 주소부터 의심하라.** 크롬이 `ERR_ADDRESS_UNREACHABLE` 을 내는데 같은
호스트를 `curl` 은 200 으로 받으면, 그건 서버가 죽은 게 아니라 **그 주소만 크롬에서
안 열리는 것**이다(2026-09-10 BoDAT 개발 맥북의 Chrome 실측 — 박스마다 다를 수 있다:
미니의 LAN 주소·mDNS 이름은 크롬에서만 막히고
Tailscale 주소·루프백은 정상. DNS 도 권한도 아니다). 이때는 `스모크 skip` 이 아니라
같은 박스의 다른 주소로 한 번 더 시도한다 — ① 그 레포의 원격 접근용 주소(BoDAT 은
테일넷 IP) ② SSH 터널. **둘 다 실패했을 때만** 도달 불가로 판정한다.

⚠️ **터널은 성공을 확인하고 써라 — 안 그러면 남의 서버를 프로덕션으로 판정한다.**
고정 포트를 쓰면 이미 그 포트를 물고 있는 dev 서버·다른 터널이 응답해 버리고, 스모크는
그걸 통과로 적으며 closeout 은 그 초록으로 배포 이슈를 닫는다(거짓 초록). 그래서
**포트를 매번 새로 뽑고**, `ExitOnForwardFailure=yes` 로 포워딩 실패 시 ssh 가 죽게 하고,
열자마자 한 번 찔러 확인한다:

**로컬 포트 충돌과 원격 도달 불가는 다른 것이다.** 뽑은 포트를 이미 누가 물고 있으면
`ExitOnForwardFailure=yes` 덕에 ssh 가 죽는데, 그걸 "도달 불가" 로 적으면 멀쩡한 경로를
버리게 된다 — 바인드 실패면 **다른 포트로 재시도**하고, 정리는 `pkill` 이 아니라 **이
호출이 만든 control socket** 으로만 한다(같은 포트를 쓰는 남의 터널을 끊지 않게).

```bash
CTL=$(mktemp -u /tmp/smoke-tun-XXXXXX.sock); ERR=$(mktemp); PORT=""
for _try in 1 2 3 4 5; do
  P=$(( 39000 + RANDOM % 1000 ))
  if ssh -f -N -M -S "$CTL" -o ExitOnForwardFailure=yes \
       -L "127.0.0.1:$P:127.0.0.1:<원격포트>" <호스트별칭> 2>"$ERR"; then
    PORT=$P; break                      # 바인드 성공
  fi
  grep -qi 'bind\|address already in use' "$ERR" || break   # 바인드 문제가 아니면 재시도 무의미
done
if [ -n "$PORT" ] && curl -fsS --connect-timeout 3 --max-time 10 \
     "http://127.0.0.1:$PORT/up" -o /dev/null; then
  echo "tunnel ok on $PORT"            # ← 스모크 URL 은 http://127.0.0.1:$PORT
else
  echo "tunnel unreachable"            # 5회 다 충돌 · 원격 무응답 · 응답 지연(10초 초과)
  ssh -S "$CTL" -O exit <호스트별칭> 2>/dev/null || true   # 실패 경로는 여기서 즉시 정리
fi
rm -f "$ERR"
```

**`tunnel ok` 면 터널을 열어 둔 채 크롬 스모크를 끝까지 밟는다** — 프로브 직후에 끊으면
정작 확인하려던 화면을 못 본다(확인한 건 `/up` 뿐). 정리는 스모크가 끝난 뒤,
**통과·실패·중단 어느 경로에서든** 한 번:

```bash
ssh -S "$CTL" -O exit <호스트별칭> 2>/dev/null || true   # 스모크 종료 후 공통 정리
```

`tunnel unreachable` 이 찍혔을 때만 도달 불가다 — 바인드 충돌은 위 루프가 이미 걸러냈고,
무응답·지연은 `--max-time` 이 10초에서 끊어 같은 결론으로 모은다(closeout 이 매달리지 않게).
정리는 control socket(`-O exit`)으로만 한다 — 포트 문자열로 넓게 `pkill` 하면 같은 포트를
쓰던 남의 터널까지 끊는다. `<호스트별칭>`·`<원격포트>` 는 그 레포의 배포 절차 문서에서
찾는다(BoDAT = `bodat-mini`(사무실 LAN)·`bodat-remote`(외부) · 3000). **통로를 못 찾으면
지어내지 말고** `스모크 skip: 터널 통로 미상(<레포>)` 로 보고한다.

**출력 계약.** 검증 항목별로 한 줄씩 `pass`/`fail`/`skip` 과 근거를 적고, 끝에
요약 `스모크: <통과수>/<전체수> 통과`(또는 `스모크 skip: <사유>`)를 낸다.
read-only — 직접 수정하지 않는다.

--- 검증 URL ---
<VERIFY_URL>

--- 검증 항목 (배포 이슈 `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
