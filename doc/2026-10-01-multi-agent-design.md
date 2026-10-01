# cmux 멀티 에이전트 설계 (2026-10-01)

claude 외 codex / opencode / gemini(/ aider)를 같은 형태(탭별 자동 시작 · `cmux -k`/재부팅 후 복원 · 대화 이어가기 · picker 선택)로
구동하고, collar를 에이전트 중립 코어로 삼아 AGENTS.md 브리지·`/collar-handoff`를 공유한다.
근거 표기: **실측**(이 머신에서 실행) / **소스** / **문서** / **추정**. 구현 중 실측이 이 문서와 다르면 실측이 이긴다 — 문서를 고쳐라.

## 0. 불변 원칙 (위반 금지)
1. **라이브 zellij 세션 `claude`(탭 17개)와 그 안의 작업을 절대 건드리지 않는다.** 테스트는 항상 별도 세션명(`CMUX_SESSION=cmuxt…`)·격리 env로만. `zellij` 호출은 항상 `-s <테스트세션>` 명시. `ZELLIJ*` env 제거.
2. 하위호환: 기존 `~/.config/cmux/session-tabs`(경로만 한 줄씩)·기존 설치 레이아웃·세션명 `claude`·기본 에이전트 claude가 새 코드에서 그대로 동작.
3. 설치본(`~/.local/bin/*`) 교체는 **원자적 `mv`**(임시파일→같은 디렉토리 `mv`)만. `cp` 덮어쓰기 금지(실행 중인 zsh 프로세스가 같은 inode를 읽는다). 새 파일을 먼저, 그것을 쓰는 cmux는 나중에.
4. collar의 `~/.collar/bin/collar-*`는 **레포 `bin/*`를 가리키는 심볼릭 링크**(실측) → collar 메인 작업트리 수정은 즉시 전 프로젝트에 반영된다. collar는 격리 worktree에서 개발·테스트한 뒤 검증된 diff만 메인에 반영한다. 실행 중인 collar 스크립트(`.compact-lock`, `ps`)가 없을 때만.
5. 위험 동작(`cmux -k`로 라이브 세션 재시작, 전역 설정 파일 수정)은 백업 후, 의도를 명시하고 수행.

## 1. 승인된 요구·결정
| 코드 | 내용 |
|---|---|
| R1 | 재부팅 후 `cmux -k`(또는 `cmux`)로 이전 화면 복원 유지 — claude/codex 혼재 탭 포함 |
| R2 | 최종 UI = picker에서 에이전트 선택. `cmux -a codex <경로>`는 중간 단계로 허용. default 설정 가능, 현재 default = claude |
| R3 | collar 기반 호환: AGENTS.md에 collar 컨텍스트 브리지를 자동 탑재 |
| R4 | `/collar-handoff`를 codex/opencode/gemini에서도 사용 |
| D1 | 수동 `collar-handoff` 성공 후에만 fresh 시작 마커 (§6) |
| D2 | collar-compact의 `claude -p` 요약 세션 오염 수정 (§11), collar 커밋 `[DISCLOSED]` |
| D3 | AGENTS.md 블록 갱신 트리거 = `cmux launch`(비-claude 시작 전)만. 자가치유 통합은 후속 |
| D4 | 중립 전역 AGENTS 3개(`~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, `~/.gemini/GEMINI.md`) 수동 ~20줄 — 이미 있으면 덮어쓰지 말고 관리 블록만 삽입 |
| D5 | 프로젝트별 마지막 사용 에이전트 기억 ON (picker 사전선택 전용, `cmux <경로>`엔 자동 적용 안 함) |
| D6 | codex 기본 권한 = safe(`-a never -s workspace-write`). 가드 훅(③)이 포팅되기 전까지 전면 우회를 기본으로 하지 않는다. `CMUX_CODEX_PERM=auto`로 전환 가능. ③ 가드 포팅은 이번 범위 밖 |

## 2. 계층 모델
① 지식·절차(`.collar/*`, AGENTS.md, 스킬) — 이번 범위 / ② 실행(SessionStart 주입, 추출기) — 이번 범위 / ③ 강제(가드 훅·위임) — CLI별 독립 설정, **이번 범위 밖**.

## 3. 아키텍처 (순수 zsh, 신규 의존성 금지)
- `bin/cmux`(코어) + `bin/cmux-agents.zsh`(어댑터, `source`) + 선택 `~/.config/cmux/agents.conf`(선언형 추가). 설치: 둘 다 `~/.local/bin`. 테스트용 `CMUX_SOURCE_ONLY=1`이면 함수 정의만 로드하고 디스패처 실행 전에 `return`.
- 어댑터 훅(에이전트당 `_ag_<name>_<hook>`, 없으면 기본 구현): `bin`(경로 탐색: `CMUX_<A>_BIN` → brew/`~/.local/bin`/`~/.nvm/versions/node/*/bin`/`~/.bun/bin` → `command -v`), `perm_args <profile>`(auto|safe), `resume_mode`(native|probe|none), `has_history <dir>`, `resume_args`, `fresh_args`, `label`, `fastfail`(초).
- `cmux launch [dir] --agent <a>`: cd → 어댑터 해석 → 마커 확인 → 자식으로 실행(**exec 아님**) → `rc≠0 && SECONDS<fastfail`이면 fresh 인자로 1회 재실행. 바이너리 없음/인증 실패면 pane에 사유 1줄 + `exec zsh -i`(탭·나머지 복원은 계속). 재개 시 pane 첫 줄에 `재개: <agent> <id/시각>` 배너.
- `agents.conf` 한 줄: `name|bin후보(콜론구분)|perm_args|resume_args|fresh_args|fastfail`. 커스텀 probe는 `_ag_<name>_has_history` 함수.
- **구현된 훅 규약(P2-A, `bin/cmux-agents.zsh` 머리말이 기준)**: `bin`→`REPLY` / `default_perm`→`REPLY`(기본 auto, codex safe) / `perm_args <auto|safe>`→`reply` / `has_history <dir>`→rc 0이면 이어하기, `REPLY`=배너용 설명(id·시각, 비어도 됨) / `last_activity <dir>`→`REPLY`=가장 최근 **대화형** 세션 활동 epoch 초(없으면 0, 마커 유예 판정용) / `resume_args`·`fresh_args`→`reply` / `compose <resume|fresh> <권한 인자…>`→`reply`=실행 인자 전체(기본: 권한 인자 + resume_args/fresh_args, codex는 서브커맨드 뒤에 권한 인자) / `fastfail`·`label`→`REPLY`. `resume_mode` 훅은 두지 않았다 — native 재개(codex)는 `has_history`가 항상 0을 돌려주는 것으로 표현한다. 프로파일은 `_agent_perm_profile <a>`: env `CMUX_<대문자 a>_PERM`(auto|safe) > `default_perm`, 그 외 값은 경고 1줄 후 기본값. 공용 도우미 `_ag_search_bin <이름> <후보…>`(env → `-f && -x`인 첫 후보 → `command -v`).
- **구현된 `_launch_agent` 순서(P2-A)**: 실행 파일 확인(없으면 사유 + `exec zsh -i`) → 비-claude면 `_collar_agents_sync`(§8) → 권한 프로파일·인자 조립 → `_handoff_marker_consume`(§6, 소비 시 fresh) → 아니면 `has_history` → 배너 1줄(회색 `\e[90m`, stdout = pane 터미널): `▶ <label>: 이전 대화 이어서 시작 [<설명>]` / `▶ <label>: 핸드오프 직후 — 새로 시작` / `▶ <label>: 새로 시작` → 실행(자식) + fastfail(`1≤rc≤128`이고 fastfail초 안이면 fresh 1회). 배너와 마커 소비는 claude에도 동일 적용.

## 4. 데이터 포맷
- `session-tabs`: 줄당 `경로` 또는 `경로<TAB>에이전트`. TAB 없음 = claude. **`_tabs_save`/`_tabs_append`는 claude 항목을 `경로`만(구포맷과 동일)으로, 비-claude 항목만 `경로<TAB>에이전트`로 기록**한다 — 구버전 cmux로 롤백해도 claude 탭 복원이 깨지지 않게(구버전은 TAB 줄을 `[[ -d ]]` 실패로 조용히 버림 → 비-claude 탭만 빠짐, 실측 t04_mixed_restore M7·M8). dedupe는 정규화된 spec 단위(같은 경로 + 같은 에이전트만 중복). 설치본·레포본 동시 교체 필수.
  - **구현(P2-B2)**: `_tabs_load`는 정리된 **정규형 = 기록 줄 형식**(claude `경로` / 그 외 `경로<TAB>에이전트`, 없는 경로·빈 줄 건너뜀, 같은 spec 1번 — 손으로 쓴 `경로<TAB>claude`도 `경로`)을 출력하고, 모든 소비자는 `_spec_parse <spec>`(→ `reply=(경로 에이전트)`)로 해석한다. 처음 설계의 "`경로<TAB>claude`로 정규화 출력"은 기존 특성화 테스트 t02 T1(경로만 출력 고정)과 충돌해 채택하지 않았다. TAB 뒤가 등록 에이전트가 아니면 줄 전체를 경로로 본다(대개 없는 경로라 건너뜀 — 구버전과 대칭).
  - `.bak`: 비-claude 줄을 쓰기 직전, 기존 파일이 비어 있지 않고 TAB 줄이 없으면(= 아직 구포맷) `session-tabs.bak-<YYYYMMDD>`로 복사. 그날 백업이 이미 있으면 건너뜀(덮어쓰지 않음).
- 탭 이름: claude = `name`(현행 그대로), 그 외 `name·codex`(`_tab_name <경로> <에이전트>`). `_tabs_sync_live`는 마지막 `·` 뒤 토큰이 **등록된 에이전트명일 때만** 분리, 아니면 통째로 이름(사용자가 개명한 탭은 현행대로 unmapped→기록 병합). 후보 = 기록(같은 basename·같은 에이전트, 우선) → 프로젝트 목록(basename 일치 + 이름의 에이전트), 이미 배정된 spec은 건너뜀.
- default 에이전트: `~/.config/cmux/config`(zsh source, `CMUX_DEFAULT_AGENT=claude`), env `CMUX_AGENT` 우선, `cmux default [agent]`로 조회·설정.
  - **구현(P2-B2)**: 설정 파일(`CMUX_CONFIG_FILE`, 기본 `~/.config/cmux/config`)은 `bin/cmux` **최상단**에서 모든 서브커맨드(pane의 `cmux launch` 포함)가 있을 때만 source한다(오류·출력 stderr 무시) → `CMUX_CODEX_PERM=auto` 같은 값이 zellij 서버 env를 바꾸지 않아도 pane에 적용된다. 단순 source이므로 **같은 이름의 env 값보다 설정 파일이 이긴다** — 일회성 default 덮어쓰기는 `CMUX_AGENT`. 우선순위 `CMUX_AGENT` > `CMUX_DEFAULT_AGENT` > claude, 미등록 값은 stderr 경고 1줄(프로세스당 1회) 후 claude. `cmux default <a>`는 등록 확인 후 `CMUX_DEFAULT_AGENT=` 줄(앞에 `export` 허용)의 첫 줄을 교체·나머지 같은 키 줄 제거·다른 줄 보존·없으면 끝에 추가, 원자적(같은 디렉토리 tmp→mv), 파일·디렉토리 생성, 심볼릭 링크면 대상 파일을 갱신. `cmux launch`(인자 `--agent` 없음)는 default와 무관하게 **항상 claude** — 설치된 `claude-tab.kdl`/`claude-project.kdl`이 `args "launch"`만 쓰기 때문.
- 마지막 사용 기억: `~/.config/cmux/project-agents`(`경로<TAB>에이전트`). **구현(P2-B2)**: `CMUX_PROJECT_AGENTS_FILE`. 탭을 실제로 열 때마다(콜드 레이아웃·attach 후 new-tab 성공·세션 안 new-tab 성공, 복원 포함) 기록. 경로 키는 실제 경로(`:A`) — picker가 논리·물리 경로 둘 다 찾는다. 같은 경로 줄은 제자리 교체(중복 줄 제거), 원자적, 실패는 조용히(탭 열기는 계속). `cmux <경로>`에는 적용하지 않는다(D5).
- 테스트 격리 env(P2-B2 추가): `CMUX_CONFIG_FILE`, `CMUX_PROJECT_AGENTS_FILE`, `CMUX_EXTRAS_FILE`(등록 경로 — 전에는 env로 못 바꿨다).
- 같은 프로젝트에 서로 다른 에이전트 2개 동시 허용(탭 이름 접미사로 충돌 없음), 같은 에이전트 2개는 금지(중복 제거).

## 5. 에이전트 어댑터 명세
| | claude | codex 0.159.3 | opencode 1.18.32 | gemini 0.59.0 | aider |
|---|---|---|---|---|---|
| 권한(auto) | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | 플래그 없음(전역 `permission: allow`에 의존) | `--yolo --skip-trust` | `--yes-always` |
| 권한(safe, codex 기본) | — | `-a never -s workspace-write` | — | — | — |
| 이력 프로브 | `$CLAUDE_CONFIG_DIR/projects/<cwd를 [^A-Za-z0-9]→- 치환>/*.jsonl`(논리·물리경로) **단 `entrypoint=sdk-cli` 파일은 제외** | 없음(native: cwd 정확일치 필터, 없으면 StartFresh — 소스) | `opencode --pure session list --format json -n 100`에서 `directory==$PWD`인 최신 id(실측 필드 `id,directory,projectId,updated`) | 없음(native `-r latest`, 세션 없으면 경고 후 새 세션 — main 소스, 0.59.0 태그 미확인) | `.aider.chat.history.md`(추정) |
| 이어하기 | **`--continue` 유지**(S2 실측: 2.1.286의 `--continue`는 더 최신인 sdk-cli 세션을 **건너뛰고** 대화형 세션을 재개한다). 단 sdk-cli만 있는 폴더에선 `No conversation found to continue`로 **rc=1 즉시 종료** → probe가 sdk-cli를 제외해야 하고 fastfail 안전망 필수 | `resume --last` (`--all` 절대 금지) | 프로브 성공 시 `-s <id>`, 없으면 플래그 없음 | `-r latest` | `--restore-chat-history` |
| 새 시작 | 플래그 없음 | 플래그 없음 | 플래그 없음 | 플래그 없음 | 플래그 없음 |
| 함정 | 같은 폴더 최신 세션 우선 | VS Code 발 세션도 cwd 같으면 재개(실측 `source:vscode`); trust 프롬프트 미검증; `exec` 세션은 `resume --last`에서 제외 | 구 세션 `session.path` NULL; `-c`의 global 프로젝트 혼재 가능성(→ id 고정으로 회피) | **이 계정은 인증 단계에서 `IneligibleTierError`(실측)** → untested 표기 | 모델/키 설정 미확인 |
| 바이너리(실측) | `/opt/homebrew/bin/claude` | `/opt/homebrew/bin/codex` | `~/.nvm/versions/node/v24.14.1/bin/opencode` | 같은 nvm `gemini` | `/opt/homebrew/bin/aider` |

zellij 서버 PATH는 대화형 셸에서 서버를 띄운 덕에 지금은 nvm bin을 포함(실측)하지만 보장이 아니다 → 어댑터는 절대경로 후보 + nvm glob 폴백.

**P2-A 구현 결과 (2026-10-01)**
| | codex | opencode |
|---|---|---|
| 바이너리 탐색 | `CMUX_CODEX_BIN` → `/opt/homebrew/bin/codex` → `/usr/local/bin/codex` → `~/.nvm/versions/node/*/bin/codex`(링크 대상 mtime 최신 하나) → `~/.bun/bin/codex` → `command -v` | `CMUX_OPENCODE_BIN` → nvm(같은 규칙) → `~/.bun/bin/opencode` → `/opt/homebrew/bin/opencode` → `/usr/local/bin/opencode` → `command -v` |
| 권한 | 기본 **safe** `-a never -s workspace-write`, `CMUX_CODEX_PERM=auto` → `--dangerously-bypass-approvals-and-sandbox` | auto/safe 모두 플래그 없음 |
| 실행 인자 | 이어하기 `codex resume --last <권한…>` / 새로 `codex <권한…>`. **순서 실측**(0.159.3, `--help` 파싱만): `codex resume --last -a never -s workspace-write --help`·`codex -a never -s workspace-write resume --last --help`·`--dangerously-bypass…` 두 순서 모두 rc=0. 파서는 `--help`가 있어도 인자를 검증한다(`--bogus-flag` → rc=2 "unexpected argument", `-a nope` → rc=2 "invalid value"). `codex resume --help`가 `-a/-s/--dangerously-bypass…`를 자기 옵션으로 나열 → resume 서브커맨드 뒤 순서 채택(루트 옵션 병합에 기대지 않음) | 이어하기 `opencode -s <id>` / 새로 플래그 없음 |
| 이력 판정 | 프로브 없음 — `has_history`는 항상 0(native `resume --last`, 이력 없으면 codex가 새 입력창). 배너 설명 = `last_activity` 시각 또는 "이력이 없으면 새 대화" | python3(표준 라이브러리) 1회: `<bin> --pure session list --format json -n 1000`(cwd=dir, `subprocess` timeout 8초) → `directory`가 dir 또는 realpath(dir)인 항목 중 `updated` 최대의 `id`. 실패·시간 초과·깨진 JSON·python3 없음 → 이력 없음(조용히). 실측 키(1.18.32, `-n 3`): `created,directory,id,projectId,title,updated`(ms) |
| last_activity | `${CODEX_HOME:-~/.codex}/sessions/**/rollout-*.jsonl` 중 mtime 최신 40개, 첫 줄 `type=session_meta`의 `payload.cwd`가 dir(논리·물리)이고 `payload.source != "exec"`인 것의 mtime(최신순 첫 일치). 실측 첫 줄 ~20KB, `source` 값 `cli`/`vscode`/`exec` | 위 목록의 `updated`/1000(내림) |
| fastfail | 5초 | 5초(없는 id → rc=1 즉시 종료 → 새 대화 1회) |
| trust 프롬프트 | 자동 처리 안 함(S3 결정) | — |

claude: `has_history`/`last_activity`는 같은 grep+awk 스캔(`_ag_claude_session_file`)이 "가장 최근 대화형 세션 파일"을 돌려주게 바꿨다 — 논리·물리 경로 키 두 폴더를 한 glob(`(키1|키2)/*.jsonl(Nom)`)으로 합쳐 최신순 정렬. `has_history`의 배너 설명 = 그 파일 mtime(`MM-DD HH:MM`), `last_activity` = 그 mtime.

## 6. 핸드오프 인식 재개 (D1)
- 기본은 재개(재부팅/크래시 복원). **수동 `collar-handoff` 성공 시에만** `.collar/restart-fresh` 마커를 쓴다(`collar-handoff` L106 `.compact-lock` touch 옆). 내용(**구현됨: 한 줄에 키 하나**, 줄 단위로 파싱할 것): `agent=<name>` / `handoff=<HANDOFF 파일명 또는 ->` / `ts=<epoch 초>`. 쓰기는 `.collar/.restart-fresh.tmp.$$` → `mv`(원자적). `COLLAR_AGENT`(기본 claude)는 영문·숫자·`_`·`-`만 허용(아니면 마커 미작성+경고). 자동 경로(SessionEnd 안전망·워치독·밀도 자동 handoff)는 **절대** 마커를 쓰지 않는다.
- `cmux launch`는 해당 에이전트와 `agent=`가 일치할 때만 소비: TTL 48h 이내 && 그 에이전트의 최신 대화형 트랜스크립트 mtime ≤ 마커 `ts` + **유예 `CMUX_HANDOFF_GRACE`(기본 300초)** (핸드오프 *뒤에 실제로 대화를 이어갔다면* 무시 — 핸드오프가 최신이 아니므로 이어하기가 맞다). **유예가 필요한 이유(설계 결함 정정)**: `collar-handoff` 명령의 출력이 마커를 쓴 *직후* 트랜스크립트에 기록되므로 "mtime ≤ 마커 mtime"은 정상 흐름에서도 항상 거짓이다 → resume 플래그를 생략하고 fresh 시작(SessionStart 주입에 맡김). 소비는 `mv`(원자적)로 `.collar/.restart-fresh.consumed-<ts>` 보존. 같은 프로젝트의 다른 에이전트 탭은 영향 없음.
- **구현(P2-A, `bin/cmux`)**: 판정은 순수 함수 `_handoff_marker_due <agent> <dir> <now>`(줄 단위 `agent=`/`ts=`만 읽음, 마지막 값 우선, `ts`는 숫자만, 그 외 키·빈 줄 무시) — 조건 `agent==에이전트` && `now - ts ≤ 172800` && `last_activity(dir) ≤ ts + 유예`(경계 포함, `CMUX_HANDOFF_GRACE`가 숫자가 아니면 300). 깨진·빈 마커·CRLF·디렉토리는 조용히 무시, 미래 `ts`(시계 차)는 TTL 안으로 본다. 소비 `_handoff_marker_consume <agent>` = 판정 후 `mv .collar/restart-fresh .collar/.restart-fresh.consumed-<now>`; **mv 실패 = 다른 pane이 먼저 소비 → 마커 없음과 같이 일반 경로**. 실측(테스트): 동시 소비 8개 중 정확히 1개 성공, 같은 폴더 동시 launch 2개 → fresh 1·이어하기 1.
- collar-handoff 안내 문구: cmux 환경에서는 "`cmux -k`" 안내를 추가(claude `-c` 금지 경고는 유지).

## 7. 혼재 재부팅 복원 견고성 (R1)
- `session-tabs` 동기화가 kill/restart 직전에만 일어나 stale 위험 → `cmux sync`(= `_tabs_sync_live`) 서브커맨드 추가: ① `_run_client`가 클라이언트 생존 중 60초마다 백그라운드 sync(클라이언트와 함께 종료) ② attach마다 1회 ③ `cmux-bar`의 Close/Quit이 `zellij action close-tab`/`quit` 직행(실측 cmux-bar L34-36)이라 sync를 우회 → `cmux close-tab`/`cmux kill` 경유로 교체.
- `cmux-bar`(`~/.local/bin/cmux-bar`, 3966B, python)는 현재 **레포 밖**(실측). 레포 `bin/`에 편입하고 install.sh가 설치. 각 탭이 1초마다 새 프로세스로 실행하므로 교체는 원자적 mv, 먼저 테스트 세션에서 검증.
- 에이전트 바이너리 없음/인증 실패: 그 탭만 사유+셸, 나머지 복원 계속.

## 8. AGENTS.md 브리지 (R3, D3)
- 파일 **상단**에 `<!-- collar:begin v1 -->…<!-- collar:end -->` 블록 삽입, 기존 본문 불변. 신규 `collar-agents-sync <dir>`(collar 레포 bin, 멱등, 블록만 교체, `.collar` 없으면 no-op). `cmux launch`가 비-claude 에이전트 시작 전 2초 타임박스·fail-soft로 호출.
- 블록 내용: 컨텍스트 로드 순서(`.collar/project-facts.md` → `session-compact.md` → 최신 `HANDOFF-*.md`(48h)), `collar-handoff`/`collar-remember` 셸 명령, 완료 3단계(STARTED/TESTED/VERIFIED), 오류 발견 시 보고 우선·`[DISCLOSED]`, 범위 충실, "존재하지 않는 파일(doc/GOAL.md 등)은 무시". **제외**: AskUserQuestion/Agent()/run_in_background, haiku·sonnet·opus 라우팅, 훅·OMC·`/compact`, `@import`.
- 기존 속 빈 AGENTS.md(`{{`/TODO 잔재)는 이번엔 블록 삽입만. GEMINI.md는 불필요(`context.fileName` 배열로 AGENTS.md 지정 가능). 문서 기준 opencode는 AGENTS.md가 있으면 CLAUDE.md를 읽지 않는다 → 속 빈 AGENTS.md가 opencode에서 프로젝트 규칙을 가린다(가장 급함).
- collar 자동 전파 설계(2026-09-28)는 CLAUDE.md/AGENTS.md를 명시적으로 범위 밖으로 둔다 → 자가치유 통합은 하지 않는다.

## 9. collar-compact 다중 에이전트화 (R4)
- 변경 지점(실측 줄): L225-226 `SLUG/TRANSCRIPT_DIR`, L234 python 인자, L380 `extract_file`(Claude 파서), L459 `all_files` 탐색. "소스 어댑터" 1곳으로 묶는다: `COLLAR_AGENT`(기본 auto=cwd 기준 최신 활동)별 `discover()→[(path,mtime)]`, `parse(path)→[(ts,role,text)]`. 체인 로직(최대 2개·45분 간격)은 그대로.
- 병합 라벨 `[claude][U]`/`[codex][A]`. HANDOFF 헤더에 `작성 에이전트/세션 id/트랜스크립트 경로` 1줄. 요약 LLM은 에이전트와 독립(현행 `claude -p` → `gemini -p` 폴백), 폴백에 `codex exec`는 추정 플래그라 실측 후에만.
- 스키마(실측, 키만): **codex** rollout jsonl 줄=`{timestamp,type,payload,ordinal}`, 대화=`response_item.payload.type=="message"`, `role` user/assistant/**developer(주입 지시, 제외)**, `content[].type` input_text/output_text, 도구=function_call/custom_tool_call(+_output), reasoning 버림, cwd=`session_meta.payload.cwd`; `migrate-rollouts`로 sqlite 전환 중 → 파일 없으면 폴백 자리만. **gemini** `~/.gemini/tmp/<이름>/chats/*.json` = `{sessionId,projectHash,startTime,lastUpdated,kind,messages[]}`, message=`{id,type:user|gemini,content,timestamp,thoughts,toolCalls,...}`, 경로→이름 매핑 `~/.gemini/projects.json` + `tmp/<이름>/.project_root`. **opencode** `opencode --pure export <id>` → `{info:{id,directory,projectID,path,...},messages:[{info:{role,time},parts:[{type:text|tool|reasoning|step-start|step-finish}]}]}`(step-*/reasoning 제외).
- 타 에이전트 `/collar-handoff` 래퍼 등록은 **추출기 어댑터 완료 후**에만(순서가 바뀌면 틀린 트랜스크립트로 HANDOFF 생성). 그 전엔 `COLLAR_AGENT≠claude`면 거부 메시지.
- 래퍼(문서 기준, 미실측): codex `~/.codex/prompts/collar-handoff.md`(frontmatter description + "셸에서 `collar-handoff`를 실행하고 출력 전문을 보여준 뒤 멈춰라"), gemini `~/.gemini/commands/collar-handoff.toml`(`prompt="""!{collar-handoff}…"""`), opencode `~/.config/opencode/commands/collar-handoff.md`(`` !`collar-handoff` ``). 각 래퍼는 자기 에이전트를 안다 → `COLLAR_AGENT`를 명시.
- 에이전트 셸 도구 타임아웃(핸드오프 1~3분) 위험 → cmux 각 탭의 터미널 pane에서 직접 `collar-handoff` 실행하는 경로도 문서화.
- 시작 컨텍스트 주입(문서 기준, 미실측): **codex** `~/.codex/hooks.json`(Claude 동형 포맷, SessionStart는 평문 stdout 수용 → `10-session-ctx.sh` 무수정), 훅 정의 해시 신뢰 승인 필요(`/hooks`, `--dangerously-bypass-hook-trust`). **gemini** `~/.gemini/settings.json` `hooks`, JSON만 허용 → `collar-dispatcher-json.sh` 래퍼. **opencode** `opencode.json` `instructions:[".collar/project-facts.md",".collar/session-compact.md"]`(HANDOFF glob 금지). 타 에이전트엔 **SessionStart만** 등록(다른 collar 훅은 에이전트 게이트 전엔 오동작: destructive-guard 형식, task-guard의 Agent() 탐지, session-monitor가 Claude 파서로 codex 트랜스크립트 읽음).

## 10. picker (R2, D5)
- 출력: `경로` 또는 `경로<TAB>에이전트`(비기본만 — 구버전 호환). fzf 폴백은 `cut -f2` 유지.
- 키(현행 h/j/k/l/방향/Space/Enter/Esc/q와 충돌 없게 `bin/cmux-picker` 확인): `a` = 커서 항목 에이전트 순환(`[codex]` 배지), `Tab` = 이번 선택의 기본 에이전트 순환(타이틀 표시). 사전선택 = `project-agents` 기억 > default.
- `cmux -a <agent> <경로>`, `cmux default [agent]`. `_open_one/_open_many/_attach_then_add_tabs/_restore_tabs/_kdl_tab/_make_layout`가 spec(경로+에이전트)을 다루도록 일반화. 새 탭 레이아웃은 에이전트 인자를 내장(`args "launch" "--agent" "<a>"`)한 `cmux-tab-<agent>.kdl`을 같은 생성기에서 런타임 생성(`new-tab -l <이름> --layout-dir`). `--layout-string`은 Phase 0 S1 통과 시 대안. 기존 `claude-tab.kdl`/`claude-project.kdl` 설치 유지, 세션명 `claude` 유지, pane `name`만 에이전트명으로, 문구 "Claude 대화 이어서"→"에이전트 대화 이어서". config.kdl `unbind "Ctrl o"` 유지.

**P2-B2 구현 결과 (2026-10-01)**
| 항목 | 구현 |
|---|---|
| 레이아웃 | 탭 본문(에이전트 pane 65% / 파일트리 / 터미널)은 `_kdl_tab_body <a>` 하나 — 세션 레이아웃 `_kdl_tab`(8칸 들여쓰기)과 new-tab 레이아웃 `_kdl_tab_layout <a>`(탭바·cmux-bar·본문·상태바, `claude-tab.kdl.tmpl`과 같은 구조)이 같이 쓴다. claude는 `args "launch"`·pane `name="claude"` 그대로 → claude 전용 세션 레이아웃이 이전 구현(a1a07e9)과 **바이트 동일**, `_kdl_tab_layout claude` = 렌더된 `claude-tab.kdl`(주석·빈 줄 제외) — 단위 t04 S6이 고정. new-tab: claude는 설치된 `claude-tab`, 그 외는 `_tab_layout <a>`가 `ZELLIJ_LAYOUTS_DIR/cmux-tab-<a>.kdl`을 매번 원자적(tmp→mv)으로 다시 써서 `-l cmux-tab-<a> --layout-dir`. 생성 실패면 그 탭만 경고 후 건너뜀 |
| `cmux -a <a> [경로]` | `--agent` 동의어. 미등록이면 오류+사용 가능 목록 exit 1, 경로 생략 시 `$PWD`(realpath), `_open_one 경로<TAB>a`. `cmux <경로> [이름]`은 default 에이전트(마지막 사용 기억 미적용) |
| picker 연동 | `_pick`이 `CMUX_PICKER_AGENTS`(등록 순서, 실행 파일이 실제로 있는 것 = `bin` 훅 + `command -v`, default는 항상 포함)·`CMUX_PICKER_DEFAULT_AGENT`·`CMUX_PICKER_PREFS_FILE`(=`PROJECT_AGENTS_FILE`)를 넘긴다. `_pick_flow`는 줄을 `경로[<TAB>에이전트]`로 나눠 경로 부분만 `[[ -d ]]`, 에이전트가 없으면 default, 미등록이면 경고 1줄 후 default. default 해석(잘못된 값 경고)은 picker 출력 캡처 밖에서 1회. fzf 폴백은 경로만 → 전부 default |
| 복원 안내문 | "이전 세션 복원: N개 탭 (에이전트 대화 이어서)" |
| 도움말 | `-a`·`default`·`launch --agent` 줄과 에이전트·default 출처·설정 파일 안내 추가(기존 줄 유지, sync/close-tab은 P2-C) |
| 테스트 | 단위 `t04_tabs_agents`(S1~S10), 통합 `t04_mixed_restore`(M1~M8 + M6b 세션 안 `-a` + M6c 비-claude 탭 닫은 뒤 kill 동기화), `t05_pick_flow`(P1~P4). 롤백 실측: 혼재 기록 → 구버전은 claude 탭만 복원·비-claude 실행 0·기록을 claude 줄만으로 다시 씀(.bak 보존), 새 버전의 claude 전용 기록 → 구버전이 그대로 복원 |

## 11. 오염 문제 (D2)
- **실측**: `~/.claude/projects/-Users-ez2sarang-Documents-dev-ai-cmux/`에 `entrypoint=sdk-cli` 37줄 jsonl 2개(13:02, 13:14) — collar-compact(L1023 `"$CLAUDE_BIN" -p …`, cwd=호출 디렉토리)의 요약 호출이 프로젝트 세션 폴더에 요약 세션을 남긴다. collar-compact에 `sdk-cli`/`entrypoint` 필터 0건. 자동 압축(SessionEnd/워치독)이 대화 종료 직후 돌면 요약 세션이 "가장 최신"이 되는 창이 실제로 존재했다(13:01 대화 → 13:02 요약 세션).
- 수정(collar): ① `-p`/폴백 LLM 호출을 스크래치 디렉토리(`$COMPACT_TMPDIR`)에서 실행 ② 추출기에서 첫 줄들의 `entrypoint=="sdk-cli"` 파일 제외 ③ 같은 패턴(`claude -p/--print`를 프로젝트 cwd에서 실행)이 다른 collar 스크립트/훅에 있는지 감사. 수정(cmux): claude 이력 probe(`launch`의 `*.jsonl` 존재 확인)가 `entrypoint=="sdk-cli"` 파일을 제외하도록 — `--continue` 자체는 유지.
- **S2 실측 결과(2026-10-01, claude 2.1.286, 임시 폴더, haiku)**: (a) 대화형 세션(entrypoint=cli) + 더 나중의 `claude -p` 세션(entrypoint=sdk-cli)이 같은 프로젝트 폴더에 공존하면 `claude --continue`는 **대화형 세션을 재개**한다(sdk-cli를 건너뜀) → 처음 우려한 "요약 세션을 집는다"는 **사실이 아님**. (b) 폴더에 sdk-cli 세션만 있으면 `claude --continue`는 `No conversation found to continue`를 출력하고 **rc=1로 즉시 종료** → 현행 `cmux launch`는 `*.jsonl`이 하나라도 있으면 `--continue`를 붙이므로(sdk-cli 구분 없음) 그런 폴더에서 **claude pane이 즉시 닫히는 실제 버그 경로**. (c) `claude -p`는 현재 버전에서 프로젝트 폴더에 sdk-cli 세션을 남긴다(09-07 메모의 "-p는 최상위 트랜스크립트를 안 남긴다"는 현재 사실이 아님).
- 따라서 `--resume <id>` 전환은 **하지 않는다**(불필요·위험). cmux 수정 = probe에서 sdk-cli 제외 + fastfail 안전망(`--continue` 실패 시 fresh 1회).
- 신뢰 폴더 대화상자: 신규 폴더에서 claude는 "Quick safety check"를 띄우며 **기본 선택이 "No, exit"**(Enter만 누르면 종료, rc=1). cmux가 처음 여는 새 프로젝트에서는 사용자가 한 번 응답해야 하는 정상 동작 — 다른 에이전트의 trust 프롬프트(codex 등)도 같은 범주로 취급한다.

## 12. 테스트 규칙
- cmux: `zsh -n`, 함수 단위(`CMUX_SOURCE_ONLY=1`), 가짜 에이전트(`tests/bin/fake-agent`: 인자·cwd 기록 후 sleep) + 격리 zellij 세션 + pty 드라이버(`tests/lib/ptyrun.py`)로 통합. env 훅: `CMUX_SESSION`, `CMUX_TABS_FILE`, `CMUX_LAYOUTS_DIR`, `CLAUDE_CONFIG_DIR`, `CMUX_<A>_BIN`. 매 테스트 전후 라이브 세션 무손상 확인(세션 생존, 탭 수·이름 동일). shellcheck 미설치 → `zsh -n`/`bash -n`으로 대체하고 명시.
- collar: 격리 worktree에서 `collar-test --fast` 기준선 대비 회귀 0, 새 단위 테스트(픽스처 3포맷 포함). 가짜 `claude`는 `CLAUDE_PATH`로 주입.
- 실제 에이전트 스모크(Phase 0/3)는 임시 디렉토리에서만, 프롬프트는 사소하게, 끝나면 프로세스 정리.
- 검증은 작성자와 분리: executor 작성 → 메인(테스트 실행) + verifier 독립 검토.
- 커밋: conventional commits, 수정 계열은 `[DISCLOSED]`, 관련 파일만 스테이징(`.claude/settings.json`, `.collar/` untracked 건드리지 않음). push는 전 Phase 검증 후, push 직전 미푸시 커밋(cmux 6·collar 10, 이전 작업분 포함) 비밀값 스캔.

## 13. Phase 계획과 레포 경계
| Phase | cmux | collar |
|---|---|---|
| 0 스파이크 | S1 `--layout-string`+attached 클라이언트, S2 `claude --continue`↔sdk-cli, S3 codex trust/재개, S4 opencode `-s`·list 지연, S5 gemini(인증 막힘 확인), 탭 이름 `·` 보존 | — |
| 1 | 어댑터 분리(동작 불변), `CMUX_SOURCE_ONLY`, claude 이력 probe에서 sdk-cli 제외(`--continue` 유지)+fastfail 안전망, install.sh 원자 설치·죽은 CLAUDE_BIN 블록 제거·cmux-bar 편입, 테스트 인프라 | `-p` 스크래치 실행 + 추출기 sdk-cli 제외 + 동일 패턴 감사 |
| 2 | codex·opencode 어댑터, `경로<TAB>에이전트` 포맷, 탭 이름 접미사, `-a`, picker 프로토콜·키, default 설정, 마커 소비, `cmux sync`, cmux-bar 버튼 | 마커 생성, `collar-agents-sync`, handoff 안내 문구 |
| 2.5 | — | 추출기 어댑터(codex→opencode→gemini) + 픽스처/테스트 |
| 3 | gemini·aider 어댑터, `agents.conf`, README/help | 래퍼 3종, 주입(codex hooks.json·gemini JSON 래퍼·opencode instructions), 중립 전역 AGENTS 3개 |
| 4 | 원자 설치 + 설치본 검증 + push | 메인 반영 + push |
| 별도(이번 범위 밖) | — | ③ 가드 훅 어댑터 |

## 14. Phase 0 스파이크 결과 (실측, 2026-10-01)
| # | 질문 | 결과 |
|---|---|---|
| S1 | 클라이언트가 붙은 격리 세션에서 `new-tab --layout-string`·`-l <파일> --layout-dir`가 동작하는가? 탭 이름 `·` 보존? | 둘 다 탭 생성 성공(rc=0). 탭 이름 `probe·codex` **그대로 보존**. 클라이언트가 없을 때의 `new-tab`은 rc=2로 실패하고 탭이 생기지 않음(기존 퀴크 재확인) → attach 후 추가 경로 유지. 결정: 증명된 파일 기반(`-l <이름> --layout-dir`)을 쓴다. `--layout-string`은 대안으로만 남김 |
| S2 | `claude --continue`가 sdk-cli 요약 세션을 집는가? | **아니오**(대화형 세션을 재개). 단 sdk-cli만 있으면 `No conversation found to continue` rc=1 즉시 종료 → §11 |
| S3 | codex `resume --last`의 trust 프롬프트·재개 동작 | (a) **빈/신규 임시 폴더**: trust 프롬프트 없이 새 입력창으로 정상 시작(`--dangerously-bypass…` 유무 무관). (b) **cli 이력 있는 폴더(collar)**: 5월 `cli` 세션 롤아웃의 mtime이 방금 시각으로 갱신 = 기존 대화형 세션을 재개. 같은 cwd의 더 최신 `exec` 세션 4개는 **건너뜀**(대화형만 선택). (c) **codex config에 신뢰 미등록 폴더(opencode)**: "Folder access … Trust this folder? › 1. Trust and continue / 2. Back" 프롬프트가 뜬다(기본 선택 = Trust). → 신규 프로젝트 첫 실행의 사용자 응답 1회는 정상 동작으로 취급, **자동 trust 주입(`-c projects."…".trust_level`)은 하지 않는다**(보안 결정을 cmux가 대신하지 않음). 부작용: 재개 확인 시 기존 롤아웃 mtime 갱신 |
| S4 | opencode `-s`·list 지연 | `opencode --pure session list --format json -n 100` = **0.55s**, 키 `created,directory,id,projectId,title,updated`(project 스코프라 한 프로젝트에 여러 `directory`가 섞임: freeOpenCode 폴더에서 61건·3개 디렉토리). `directory==$PWD` 필터 후 `updated` 최대 id 선택 가능. 구현 시 `-n`은 넉넉히(예: 1000) 하고 논리/물리 경로 둘 다 비교. `opencode -s <실제 id>` = 해당 세션 열림(제목 표시, 오류 0). `-s <없는 id>` = `Error: Session not found: …` **rc=1 즉시 종료** |
| S5 | gemini 실제 실패 양상 | 비대화형 `gemini --list-sessions`는 `IneligibleTierError`로 크래시하지만, **TUI(`gemini -r latest --yolo --skip-trust`)는 크래시하지 않고** "No previous sessions found for this project." 경고(→ 새 세션) 후 인증 메뉴("1. Sign in with Google / 2. Use Gemini API Key / 3. Vertex AI", Google 쪽은 "no longer supported" 메시지)에서 사용자 선택을 기다린다 → 탭은 정상 시작되고 API 키/Vertex로 인증하면 사용 가능. 어댑터는 untested 표기 유지 |

## 15. zellij 0.45.1 업스트림 조사 (2026-10-01, 웹·gh API, 출처는 이슈 번호)
- 최신 안정판 = **0.45.1**(2026-08-28), Homebrew stable도 동일 → 올릴 버전 없음. 문제 1·3의 수정 PR은 미머지, 수정은 서버 쪽이라 새 바이너리로 **새로 띄운 세션에만** 효과. 업그레이드는 하지 않는다(라이브 17탭 서버 보호). 소켓/메타데이터 경로는 `contract_version_1` 아래 버전 무관 공유(0.44.0+).
- 우리 문제 ↔ 업스트림: ① detached/무클라이언트 세션 `new-tab` 탭 폐기 = **#5594**(PR #5612 open) ② `delete-session --force` rc=2 / `kill-session` rc=1 = **설계**(종료 요청만 보내고 응답을 안 기다린 뒤 `session_info/<이름>`을 지우다 이미 없으면 exit 2 — "이미 죽었다" 신호이지 실패가 아님) ③ 같은 이름 재생성 시 무출력 정지·세션 미생성(~3%, 부하 시 증가) = **#5632**(PR #5638 open): 새 서버가 첫 클라이언트를 초기화하기 전에 다른 zellij CLI가 소켓에 접속했다 끊으면 서버 panic. `list-sessions`/`attach`/`-s <새이름>`/`delete-session`/`kill-session`/`action list-clients·query-tab-names`가 모두 `get_sessions()`로 모든 소켓에 접속→끊음. 서버 로그 `$TMPDIR/zellij-$UID/zellij-log/zellij.log`의 `lib.rs:1462` panic으로 확정 가능 ④ 1행 pane 미표시 = #5548(size=2 유지).
- 실측 확인(로컬): 서버 준비 신호 = `~/Library/Caches/org.Zellij-Contributors.Zellij/contract_version_1/session_info/<이름>/session-metadata.kdl`, 소켓 = `$TMPDIR/zellij-$(id -u)/contract_version_1/<이름>`, 서버 프로세스 = `zellij --server <소켓경로>`.
- P1 verifier 플레이크율: t00_baseline 변경 후 11/104(10.6%) vs HEAD 복사본 9/92(9.8%) — 변경과 무관, 20건 모두 "세션 생성·attach 정지" 유형(4병렬 시 ~25%).
- **코드 완화 방침(P2에 반영)**: (a) 새 세션 시작 후 `session-metadata.kdl`이 생길 때까지 소켓을 건드리는 zellij 호출(list-sessions/list-clients/query-tab-names/attach)을 하지 않는다(파일 존재 폴링은 안전), 그 후에도 폴링 ≥0.3s (b) 종료 확인은 코드가 아니라 **상태**로: 소켓 파일 부재 + `zellij --server …/<이름>` 프로세스 부재, `delete-session`의 rc=2·`kill-session`의 rc=1은 성공으로 취급 (c) 옛 세션 소멸 확인 후에만 같은 이름 재생성 (d) 복원 탭은 처음 띄우는 레이아웃(-n)에 모두 넣어 무클라이언트 `new-tab`을 피한다(기존 cold start 경로), 살아 있는 세션 추가는 attach 후 new-tab(기존) (e) 테스트는 병렬 실행하지 않는다(zellij 인프라 실패로 위음성/위양성).
- 별도 발견(결정 필요, **변경하지 않음**): `zellij/config.kdl`의 `use_kitty_keyboard_protocol false`는 zellij에 없는 키(실제 옵션 `support_kitty_keyboard_protocol`) → 현재 설정은 적용되지 않고 있을 가능성이 높다. 고치면 키 입력 처리(Ghostty Alt 조합 등)가 바뀔 수 있고 라이브 세션에 영향.
- P1 verifier 개선 권고(P2 반영): claude probe를 jsonl마다 `head` fork 대신 **단일 프로세스(awk, `FNR<=30`·첫 entrypoint 줄까지, `nextfile`)** 로, 5줄 창을 약 30줄까지 확장; fastfail은 `1<=rc<=128`만(신호 종료는 재실행 안 함); 테스트 공백 보강(이스케이프된 `\"entrypoint\": \"sdk-cli\"` 텍스트가 있는 cli 파일, `~/.local/bin` 어댑터 폴백).
