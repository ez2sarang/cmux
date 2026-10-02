# cmux 실데이터 리허설 (수동 실행 — `tests/run.zsh`는 이 폴더를 돌리지 않는다)

- 실행: `zsh tests/e2e/t90_rehearsal_real_record.zsh` (약 3~5분). 다른 cmux 테스트(`run.zsh`·`tests/*/tNN`·`cmuxt` 서버)가 돌고 있으면 시작하지 않고 exit 3, 기록된 폴더에 `.collar/restart-fresh` 마커가 있으면 exit 4로 끝난다(launch가 실제 폴더에서 마커를 소비하게 되므로).
- 목적: 라이브 세션 `claude`를 끄고 `cmux -k`로 복원하기 전에, 같은 흐름을 격리 세션 `cmuxt<pid>`에서 실제 데이터로 끝까지 돌려 본다. 실제 데이터는 탭 기록(`~/.config/cmux/session-tabs` 복사본), zellij, HEAD의 `bin/*`(임시 폴더에 tmp→mv로 설치, 레이아웃은 install과 같은 sed 규칙), `~/.claude`·`~/.codex`·opencode 세션 목록(읽기만)이다. 가짜는 에이전트 실행 파일(`tests/bin/fake-agent`, `tests/bin/fake-opencode` — 목록 조회만 실제 opencode에 넘김)과 PATH 맨 앞의 `collar-agents-sync`(호출만 기록), 그리고 picker 스텁뿐이다.
- 시나리오: R0 준비·오라클 → R1 콜드 복원(무인자 `cmux`) → R2 `cmux -a codex|opencode|codex` 혼재 추가 → R3 창을 닫은 뒤 테스트 서버만 SIGKILL → R4 밖에서 `cmux -k` → R5 `cmux kill` 뒤 무인자 `cmux` → R6 구버전(`~/.config/cmux/backup-20261001/cmux`) 롤백 → R7 불변·정리.
- 판정 기준(오라클)은 cmux 코드와 따로 python3로 계산한다. claude는 앞 30줄 안의 첫 `entrypoint`가 sdk-cli가 아닌 jsonl이 있으면 `--continue`, opencode는 실제 `opencode --pure session list`에서 같은 directory의 최신 id, 구버전은 jsonl이 하나라도 있으면 `--continue`다. 라이브 세션이 트랜스크립트를 계속 쓰므로 복원 직전마다 다시 계산하고, 값이 바뀌면 `참고: 오라클 변화`를 출력한다.
- PASS 조건: 끝 줄이 `ALL PASS`이고 `RESULT … fail=0`이어야 한다. 출력 아래쪽에 오라클 표, 탭별 기대/실제 argv 표(R1·R2·R4·R5, 구버전 R6·R6b), 소요 시간, `lib.rs:1462` panic 증가 수, R3 직후 소켓 상태가 나온다.
- 불변 검사: 라이브 `claude` 세션의 탭 이름·순서와 서버 PID가 시나리오마다 같아야 한다. 잔여 프로세스·테스트 세션·임시 루트는 0이어야 한다. `~/.config/cmux`·`~/.config/zellij`·`~/.local/bin/cmux*`(백업 `md5-installed.txt`와 대조), 프로젝트 최상위 항목·`AGENTS.md`·`CLAUDE.md`·마커, `~/.claude/projects` 키 목록이 시작 때와 같아야 한다.
- 뮤테이션 확인: `RH_UPTO=R1 RH_MUTANT=sdkcli-off|sdkcli-invert`(설치본 어댑터의 sdk-cli 판정을 없애거나 뒤집는다). 실데이터에 sdk-cli 세션만 있는 탭이 없으면 `RH_SDKCLI_ONLY=<탭 이름>`을 함께 준다. 그 프로젝트는 실제 sdk-cli jsonl만 보이는 `CLAUDE_CONFIG_DIR` 오버레이(심볼릭 링크)를 쓴다. 지난 커밋을 확인하려면 `RH_REV=<커밋>`을 쓴다(기본 HEAD).
- 진단: `T_KEEP=1`이면 임시 루트(`/private/tmp/cmuxt.*` — pty 로그 `logs/`, `fake-agent.log`, `sync-calls`)가 남는다. 실패하면 harness가 기록 파일·가짜 에이전트 기록·panic 건수를 출력한다.
- 안전: 라이브 세션은 조회만 한다(`query-tab-names`). zellij는 항상 `-s cmuxt<pid>`로 부르고 #5632 게이트(`t_zj_gate`)를 거친다. SIGKILL은 명령줄이 정확히 `…/zellij --server <소켓>/cmuxt<pid>`인 프로세스 1개에만 보내며, 라이브 서버이거나 그 자손이면 거부한다.

## t91_live_restore.py — 라이브 세션 실복원 (수동 E2E)

- **경고: `run`을 `--dry-run` 없이 실행하면 라이브 zellij 세션 `claude`의 서버를 실제로 종료한다**(SIGTERM → 안 죽으면 SIGKILL, 남은 옛 pane 프로세스 정리). 그 뒤 가상 터미널(`tests/lib/ptyrun.py`)에서 `cmux -k`로 복원한다. 모든 탭의 에이전트가 다시 시작되므로, 작업 중인 탭이 없는지 먼저 확인한다.
- `verify`(읽기 전용): `python3 -B tests/e2e/t91_live_restore.py verify`. 지금 떠 있는 세션의 탭 이름·순서, 탭마다 에이전트 프로세스가 1개인지, `--continue` 여부를 탭 기록(`~/.config/cmux/session-tabs`)·transcript 오라클과 대조한다. 출력에 나온 서버 PID를 `run`에 넘긴다. `--agent-bin`을 주지 않으면 claude 경로를 `cmux -h`로 알아낸다.
- 연습: `python3 -B tests/e2e/t91_live_restore.py run --dry-run --expect-server-pid <PID> --out /tmp/cmux-live-restore/dryrun`. 종료·복원은 하지 않고 종료 전 단계만 거친다.
- 실제 실행: `python3 -B tests/e2e/t91_live_restore.py run --yes --daemonize --expect-server-pid <PID>`(선택: `--inject-tab <탭> --inject-text "<프롬프트>"`).
  - 필수 옵션: `--yes --daemonize --expect-server-pid`.
  - `--expect-server-pid`가 없으면 rc 2로 끝난다.
  - 이 스크립트가 서버의 자손(zellij pane 안)인데 `--daemonize`가 없으면 rc 2로 끝난다. 서버와 같이 죽지 않도록 setsid로 분리하기 위해서다.
  - 실제 종료는 세션 `claude`와 기본 탭 기록에서만 허용한다.
- 리포트: `--out` 폴더(기본 `/tmp/cmux-live-restore/<시각>`)에 다음 파일이 생긴다.
  - `REPORT.md`: 진행 중에 갱신되고, 끝나면 `FINAL`이 표시된다. 종료 시점 작업 중 탭(추정), 직접 정리한 프로세스의 명령별 집계, 복원 후 탭별 검증, `~/.config/cmux/project-agents` 전후 md5, 사용자 조치가 담긴다.
  - `DONE`: rc
  - `helper.log`: 데몬 로그
  - `client.log`·`ptyrun.out`: 가상 터미널 출력
- 끝난 뒤: Ghostty 등 기존 터미널의 zellij 클라이언트는 끊긴다. 프롬프트에서 `cmux`를 입력해 다시 붙는다. 롤백 방법은 `~/.config/cmux/backup-20261001/ROLLBACK.txt`에 있다.
- 수정 배경(2026-10-02): 첫 실제 실행에서 서버를 종료한 뒤 `ps` 출력의 비UTF-8 바이트 때문에 UnicodeDecodeError가 나서 `cmux -k`까지 가지 못했다. 예외 repr에 ps 출력 전체가 실려 REPORT.md가 6.5MB가 됐다. 이제 출력은 replace로 디코딩한다. 종료 후 `cmux -k` 직전까지의 확인 실패는 WARN으로 남기고 복원을 계속한다. 리포트 상세는 500자로 자른다.
