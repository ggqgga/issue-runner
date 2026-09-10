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

**로컬 포트 충돌과 원격 도달 불가는 다른 것이다 — 가르는 축은 "몇 번 실패했나" 가 아니라
"어느 쪽 문제인가" 다.** 뽑은 포트를 이미 누가 물고 있으면(바인드 충돌)
`ExitOnForwardFailure=yes` 덕에 ssh 가 죽는데, 이건 **로컬 문제**다 — 바인드 실패면
**다른 포트로 재시도**하고, 5회 전부 바인드 충돌이면 전용 문자열로 갈라 보고한다(아래
`tunnel port exhausted` — **로컬 문제, 도달 불가 아님**). 반대로 ssh 가 **비-바인드
사유**(호스트 다운·인증 실패·DNS·라우팅)로 실패하면 그건 **원격/경로 문제**이므로 재시도해도
의미가 없다 — 곧장 `tunnel unreachable` 로 보고한다(새 문자열을 만들지 않는다. 바인드는 됐는데
프로브가 무응답·10초 초과인 경우와 같은 문자열로 합류시킨다 — 둘 다 원격 쪽 문제라서다).
정리는 `pkill` 이 아니라 **이 호출이 만든 control socket** 으로만 한다(같은 포트를 쓰는
남의 터널을 끊지 않게).

**control socket 경로는 변수 전달에 기대지 않는다 — 포트에서 고정 유도한다.** 터널을 여는
스니펫과 "스모크가 끝난 뒤 정리" 스니펫은 **서로 다른 Bash 호출**이라 셸 변수(`CTL`)가
둘 사이에 살아남지 않는다. 그래서 소켓 경로를 `mktemp` 무작위값이 아니라 **바인드에 성공한
포트 번호로 고정 유도**한다(`/tmp/smoke-tun-<포트>.sock`) — 포트는 터널 스니펫 출력에
그대로 찍히므로, 정리 스니펫이 그 숫자만으로 같은 경로를 재구성해 쓸 수 있다.

⚠️ **경로가 포트로만 고정되므로, "바인드 성공"과 "이 소켓을 우리가 소유함"은 같은 말이
아니다.** 앞 회차가 정리 전에 죽어 소켓 파일만 남았는데 그 포트가 풀렸거나, 다른 master 가
그 경로를 이미 쥐고 있으면 — OpenSSH 는 `ControlSocket ... already exists, disabling
multiplexing` 을 찍고 **비-multiplex 로 넘어가 포워딩 자체는 성공시킬 수 있다.** 이걸 그대로
`PORT=$P; CTL=$C` 로 받으면 정리 단계의 `-O exit` 이 **남의 살아있는 master 를 끊고**, 정작
이번에 연 터널은 CTL 을 못 들고 있어 누수된다(#170). 그래서 소켓 경로를 쓰기 전·쓴 직후 두
지점에서 `-O check` 로 소유권을 확인한다:

- **시작 전(잔재 소켓 처리):** 이번 포트의 경로가 이미 파일로 존재하면, 곧장 `ssh -M` 을
  걸지 않고 먼저 `-O check` 한다 — 죽었으면(check 실패) 크래시 잔재이므로 지우고 이번
  시도에서 계속 쓰고, 살아있으면(check 성공) **남의 master** 이므로 이 포트는 포기하고
  다음 포트로 넘어간다(바인드를 시도조차 하지 않는다 — 건드리면 그게 곧 남의 연결에
  손대는 것이다).
- **바인드 직후(소유권 확인):** `ssh -M` 이 성공을 리턴해도 그걸 곧장 성공으로 받지 않고
  같은 경로에 `-O check` 를 한 번 더 한다. 이게 성공해야 **우리가 방금 만든 살아있는
  master** 라는 뜻이고, 그래야만 `PORT`/`CTL` 을 채택한다. 실패하면(위에서 말한 비-multiplex
  폴백) 소유하지 못한 소켓을 CTL 로 들고 가지 않고 — 로컬 문제로 취급해 다음 포트로
  재시도한다(5회 다 이 경로면 바인드 충돌과 같은 `tunnel port exhausted` 로 합류 — 아래
  세 갈래 분류는 바뀌지 않는다).

```bash
ERR=$(mktemp); PORT=""; CTL=""; ALL_BIND=1
for _try in 1 2 3 4 5; do
  P=$(( 39000 + RANDOM % 1000 ))
  C="/tmp/smoke-tun-$P.sock"          # 소켓 경로 = 포트로 고정 유도(변수 전달에 안 기댐)
  if [ -e "$C" ]; then
    # 잔재 소켓 처리(크래시 재개 방어) — 이 포트를 시도하기 전에 먼저 소유권을 본다.
    if ssh -S "$C" -O check <호스트별칭> >/dev/null 2>&1; then
      continue                        # 살아있는 남의 master — 건드리지 않고 다음 포트로
    else
      rm -f "$C"                      # 죽은 잔재 — 지우고 이 포트에서 계속
    fi
  fi
  if ssh -f -N -M -S "$C" -o ExitOnForwardFailure=yes \
       -L "127.0.0.1:$P:127.0.0.1:<원격포트>" <호스트별칭> 2>"$ERR"; then
    # 바인드 성공을 곧장 믿지 않는다 — ControlPath 가 이미 살아있는(남의) master 를 물고
    # 있으면 OpenSSH 는 "ControlSocket ... already exists, disabling multiplexing" 을
    # 찍고 비-multiplex 로 넘어가 여기서도 성공을 리턴할 수 있다. 우리가 방금 만든 살아있는
    # master 인지 -O check 로 확인한 뒤에만 채택한다.
    if ssh -S "$C" -O check <호스트별칭> >/dev/null 2>&1; then
      PORT=$P; CTL=$C; break          # 소유권 확인됨 — 진짜 성공
    else
      continue                        # 소유 못 한 소켓(비-multiplex 폴백) — CTL 로 들고 가지 않는다
    fi
  fi
  # ExitOnForwardFailure=yes 가 바인드 실패 시 내는 stderr 는 "bind: Address already in
  # use" 류 — 이 grep 에 걸린다. 걸리지 않는(=비-바인드) 실패 예: "Could not resolve
  # hostname"(DNS) · "Connection refused"/"No route to host"(호스트 다운·라우팅) ·
  # "Permission denied"(인증 실패). 그런 실패는 포트를 바꿔 재시도해도 소용없으므로 즉시 break.
  grep -qi 'bind\|address already in use' "$ERR" || { ALL_BIND=0; break; }   # 원격/경로 문제
done
if [ -z "$PORT" ] && [ "$ALL_BIND" = 1 ]; then
  echo "tunnel port exhausted"        # 5회 전부 바인드 충돌(또는 소유권 미확인) — 로컬 문제, 도달 불가 아님
elif [ -z "$PORT" ]; then
  echo "tunnel unreachable"           # 비-바인드 ssh 실패(호스트 다운·인증·DNS·라우팅) — 원격/경로 문제
elif curl -fsS --connect-timeout 3 --max-time 10 \
     "http://127.0.0.1:$PORT/up" -o /dev/null; then
  echo "tunnel ok on $PORT, control socket $CTL"   # ← 스모크 URL 은 http://127.0.0.1:$PORT
else
  echo "tunnel unreachable"           # 바인드는 됐지만 원격 무응답 · 응답 지연(10초 초과)
  ssh -S "$CTL" -O exit <호스트별칭> 2>/dev/null || echo "control socket 정리 실패: $CTL"
fi
rm -f "$ERR"
```

위 루프의 `-O check` 는 **이번 호출이 소유한 살아있는 master 인지**만 판정한다 — 소켓이
아예 없는 것(잔재 없음, 정상 진행) · check 자체 실행 실패(위 두 지점 모두 실패로 취급해
안전 쪽으로 접는다: 시작 전이면 지우고 계속, 바인드 직후면 CTL 로 채택하지 않고 재시도) ·
살아있는 남의 master(건드리지 않고 넘어간다) 는 각각 다른 의미이므로 종료코드를 뭉뚱그려
`|| true` 로 삼키지 않는다.

**`tunnel ok` 면 터널을 열어 둔 채 크롬 스모크를 끝까지 밟는다** — 프로브 직후에 끊으면
정작 확인하려던 화면을 못 본다(확인한 건 `/up` 뿐). `CTL` 은 위 루프가 이미 `-O check` 로
소유를 확인한 뒤에만 채택한 값이므로, 정리 시점에 `-O exit` 을 걸어도 남의 master 를 끊을
위험은 없다 — 다만 스모크가 오래 걸려 그 사이 master 가 죽었을 수는 있으니(정상 종료·크래시
불문) 아래 `-S` 존재 확인은 그대로 남겨 둔다. 정리는 스모크가 끝난 뒤,
**통과·실패·중단 어느 경로에서든** 한 번 — 위 출력에 찍힌 포트 번호로 같은 경로를
재구성해서 쓴다(변수가 아니라 숫자를 옮겨 적는다):

```bash
CTL="/tmp/smoke-tun-<PORT>.sock"   # <PORT> = 터널 스니펫 출력의 포트 번호(예: "tunnel ok on 39441"→39441)
if [ -S "$CTL" ]; then
  ssh -S "$CTL" -O exit <호스트별칭> 2>/dev/null || echo "control socket 정리 실패: $CTL"
else
  echo "control socket 없음(경로 불일치 또는 이미 정리됨): $CTL"   # 조용히 넘어가지 않는다
fi
```

`tunnel unreachable` 이 찍혔을 때만 도달 불가다 — 5회 전부 바인드 충돌은 위 루프가 이미 걸러
`tunnel port exhausted` 로 따로 갈렸고(로컬 문제로 분류, skip 사유일 뿐 도달 불가 판정에 넣지
않는다), 그 외의 실패 경로 둘 — ① ssh 가 비-바인드 사유로 실패 ② 바인드는 됐지만 원격
무응답·지연(`--max-time` 이 10초에서 끊음, closeout 이 매달리지 않게) — 은 둘 다 원격/경로
쪽 문제이므로 같은 문자열로 합류한다.
정리는 control socket(`-O exit`)으로만 한다 — 포트 문자열로 넓게 `pkill` 하면 같은 포트를
쓰던 남의 터널까지 끊는다. 소켓을 못 찾으면(`-S` 실패) `|| true` 로 삼키지 말고 그 사실을
적는다. `<호스트별칭>`·`<원격포트>` 는 그 레포의 배포 절차 문서에서 찾는다(BoDAT =
`bodat-mini`(사무실 LAN)·`bodat-remote`(외부) · 3000). **통로를 못 찾으면 지어내지 말고**
`스모크 skip: 터널 통로 미상(<레포>)` 로 보고한다.

**출력 계약.** 검증 항목별로 한 줄씩 `pass`/`fail`/`skip` 과 근거를 적고, 끝에
요약 `스모크: <통과수>/<전체수> 통과`(또는 `스모크 skip: <사유>`)를 낸다.
read-only — 직접 수정하지 않는다.

--- 검증 URL ---
<VERIFY_URL>

--- 검증 항목 (배포 이슈 `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
