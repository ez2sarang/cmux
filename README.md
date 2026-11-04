# cmux

Claude Code 멀티 프로젝트 워크스페이스 매니저.

`cmux` 하나로 여러 AI 프로젝트를 zellij 탭으로 열고, 각 탭에서 Claude Code가 자동 시작됩니다.

## 왜 zellij인가?

tmux, screen 등 여러 터미널 멀티플렉서 중 zellij를 선택한 이유:

**선언적 레이아웃 (KDL)**
레이아웃을 코드로 정의할 수 있습니다. `cmux`는 프로젝트 목록을 받아 탭 블록이 담긴 `.kdl` 파일을 동적으로 생성합니다. tmux는 스크립트로 비슷한 일을 할 수 있지만, 레이아웃 자체를 선언하는 문법이 없어 복잡해집니다.

**실행 중 탭 추가**
`zellij action new-tab -l <layout>` 한 줄로 살아있는 세션에 탭을 동적으로 추가할 수 있습니다. zellij 안에서 `cmux`를 실행하면 picker에서 고른 프로젝트들이 현재 세션에 탭으로 붙습니다.

**외부 CLI 제어**
`zellij action` 명령으로 세션 밖에서 탭 전환, 이름 지정, 명령 실행 등을 제어할 수 있습니다. cmux의 세션 감지(`zellij list-sessions`)와 자동 reattach가 이 덕분에 가능합니다.

**세션 유지**
`Ctrl+b`로 세션을 종료하지 않고 detach할 수 있습니다. 다음에 `cmux`를 실행하면 picker 없이 바로 이전 작업 환경으로 돌아옵니다. 터미널 앱(Ghostty 등)을 그냥 닫아도 zellij 서버와 각 탭의 Claude Code는 살아 있으므로 같은 방법으로 돌아옵니다.

**세션이 죽어도 이어가기**
zellij 서버가 크래시하거나 `cmux -k`로 재시작해도 작업을 이어갈 수 있습니다. cmux는 열려 있는 프로젝트 탭 목록을 `~/.config/cmux/session-tabs`에 기록해 두고, 세션이 없는 상태에서 `cmux`를 실행하면 같은 탭을 같은 순서로 다시 만듭니다. 각 탭의 Claude Code는 `cmux launch`를 통해 시작되며, 그 디렉토리에 이전 대화 기록이 있으면 `claude --continue`로 가장 최근 대화를 재개합니다(기록이 없으면 새로 시작). 단, 같은 디렉토리에서 더 나중에 다른 Claude 세션을 실행했다면 그 세션이 재개됩니다. 기록을 무시하고 새 구성을 고르려면 `cmux pick`을 사용하세요.

**내장 상태 바 + 탭 바**
별도 설정 없이 탭 목록과 단축키 안내가 표시됩니다. Claude Code 같은 TUI 앱과 함께 쓸 때 화면 구성이 자연스럽습니다.

## 화면 구성

```
┌──────────────────────────────────────────────────────┐
│  프로젝트A  │  프로젝트B  │  프로젝트C  │  ...       │  ← 탭 바
├──────────────────────────────────────────────────────┤
│                          │  파일트리 (eza)            │
│  Claude Code (65%)       ├────────────────────────── │
│                          │  터미널 (zsh)              │
├──────────────────────────────────────────────────────┤
│  [N] 모드   Ctrl+b: detach   ...                     │  ← 상태 바
└──────────────────────────────────────────────────────┘
```

## 의존성

| 도구 | 용도 |
|------|------|
| [zellij](https://zellij.dev) | 터미널 멀티플렉서 |
| [Claude Code](https://claude.ai/code) | AI 코딩 CLI |
| Python 3 | cmux-picker (내장 의존성 없음) |
| [eza](https://eza.rocks) | 파일트리 표시 (선택) |

### macOS 설치

```zsh
brew install zellij eza
# Claude Code: https://claude.ai/code
```

## 설치

```zsh
git clone https://github.com/ez2sarang/cmux.git
cd cmux
./install.sh
```

설치 위치:
- 바이너리: `~/.local/bin/cmux`, `~/.local/bin/cmux-picker`
- zellij 레이아웃: `~/.config/zellij/layouts/`
- zellij 설정: `~/.config/zellij/config.kdl`

PATH에 `~/.local/bin`이 없다면 `~/.zshrc`에 추가:

```zsh
export PATH="$HOME/.local/bin:$PATH"
```

## 사용법

```zsh
cmux                 # 세션 연결 → 없으면 이전 탭 복원 → 기록 없으면 프로젝트 선택
cmux pick            # 기록 무시하고 프로젝트 선택 (Space: 다중선택, Enter: 열기)
cmux /path/to/proj   # 경로 직접 열기 (세션이 살아 있으면 탭으로 추가)
cmux add [경로]      # DEV_ROOT 외 경로 등록
cmux rm              # 등록 경로 제거
cmux list            # 프로젝트 목록
cmux -l              # zellij 세션 목록
cmux -k              # 세션 재시작 — 같은 탭 복원 + 각 탭 Claude 대화 이어서 (세션 안/밖 모두)
cmux kill            # 세션 종료만 (탭 기록 보존 → 다음 cmux가 복원)
cmux status          # 탭별 에이전트 상태 표 (blocked → working → idle 순, 기록 없는 탭은 -)
cmux jump            # 다음 blocked(입력 대기) 탭으로 이동 — 현재 탭 다음부터 끝에서 처음으로 순환
cmux bridge [--check|--apply] [경로]   # AGENTS.md ↔ CLAUDE.md 지침 파일 연결 (아래 "에이전트와 지침 파일")
```

`cmux -k`를 세션 안(터미널 pane)에서 실행하면 세션이 종료된 직후 같은 터미널에서 자동으로 같은 탭이 다시 만들어집니다. 이 자동 복원은 `cmux`로 세션을 열었을 때 동작하며, `zellij attach`로 직접 붙은 경우에는 셸에서 `cmux`를 한 번 더 실행하면 됩니다. 세션이 죽은 상태에서 `cmux <경로>`를 실행하면 이전 탭들도 함께 복원되고 지정한 경로가 새 탭으로 추가됩니다(기록을 버리고 새로 시작하려면 `cmux pick`).

### 피커 조작

| 키 | 동작 |
|----|------|
| `←` `→` `h` `l` | 좌우 이동 |
| `↑` `↓` `k` `j` | 위아래 행 이동 |
| `Space` | 선택 토글 (다중 선택) |
| `Enter` | 열기 |
| `Esc` / `q` | 취소 |

### 상단 탭 줄 (1줄 ↔ 2줄 토글)

상단 3행은 `cmux-bar`가 직접 그립니다(zellij 기본 `tab-bar` 플러그인은 1줄 전용이라 쓰지 않음). 높이는 항상 3행이고, 안에서 모양만 바뀝니다.

| 상태 | 0행 | 1행 |
|------|-----|-----|
| 접힘(기본) | 탭 1줄 + 오른쪽 끝 `▾` | 툴바(`cmux │ ◉ Picker │ × Close │ ⏻ Quit │ … 세션명`) |
| 펼침 | 탭 줄 + 오른쪽 끝 `▴` | 탭 줄 이어서 + 오른쪽 끝 축약 아이콘 `◉ │ × │ ⏻` |

- 토글: `▾`/`▴` 클릭 또는 바 pane에서 `t` 키. 상태는 `~/.config/cmux/tabbar-rows`(`1` 또는 `2`, 환경변수 `CMUX_TABBAR_STATE_FILE`)에 저장돼 **모든 탭의 바가 0.5초 안에 함께 바뀝니다**(재시작 불필요).
- 탭 이름 클릭 = 그 탭으로 이동, 마우스 휠 위 = 이전 탭. **휠 아래(다음 탭)는 이 머신의 `python3`(`/usr/bin/python3` → Xcode 의 Python 3.9.6, ncurses 6.0 마우스 버전 1 빌드)에 `BUTTON5_PRESSED`가 없어 동작하지 않습니다**(`tests/integration/t08_tabbar_real_click.zsh`에서 휠 위는 이전 탭으로 이동, 휠 아래는 활성 탭 그대로임을 실측; 탭 이름 클릭이나 휠 위로 이동). 이름은 14칸에서 `…`로 자르고(한글 2칸 계산), 벨 알림 탭은 `*`. 다 안 들어가면 활성 탭이 보이는 창만 그리고 가장자리에 숨은 개수(`‹3` `4›`)를 표시합니다.
- **바 pane의 키는 `p`(피커)와 `t`(토글)뿐입니다. `x`(탭 닫기)·`q`(세션 종료) 키는 일부러 없앴습니다** — Close/Quit은 `× Close`·`⏻ Quit` 버튼 클릭으로만 합니다. 클릭한 바는 자기 탭의 본문(에이전트) pane으로 포커스를 돌려놓습니다(탭 전환 전에 수행; Picker 클릭은 새 floating pane이 포커스를 가져가므로 제외). 포커스를 바에 남겨 두면 나중에 그 탭에서 친 키가 바로 들어가기 때문입니다. (이동은 `focus-next-pane` 반복 — zellij 0.45.1의 `focus-pane-id`는 `mouse_click_through true`에서 클릭이 준 키보드 포커스를 옮기지 못함을 실측. 포커스 확인은 작은 `zellij action list-clients` 응답으로 하고, 바 프로세스가 목표 pane과 이동 횟수를 기억해 두 번째 클릭부터는 큰 `list-panes` 조회 없이 이동합니다. 이동 뒤 확인이 틀리면 기억을 버리고 `list-panes`로 교정하고, 확인 자체를 판단할 수 없으면(`list-clients` 실패·형식 이상) 기억은 유지한 채 `list-panes` 기반의 기존 경로로 처리합니다. 단일 클라이언트 접속을 전제로 합니다 — 여러 클라이언트가 붙어 있으면 "아무 클라이언트에서든 포커스"로 판단합니다.)
- 첫 클릭부터 동작하려면 zellij `mouse_click_through true`가 필요합니다(레포 `zellij/config.kdl`에 포함; 서버 시작 때만 읽힘 → 이미 떠 있는 세션은 `cmux -k` 후부터, 사용자 `~/.config/zellij/config.kdl`에는 직접 병합). 이 설정이 없으면 포커스 없는 pane의 첫 클릭은 포커스 이동에만 쓰이고 탭 이동은 두 번 클릭해야 합니다.
- 탭 목록은 세션당 한 바(리더)만 1초마다 `zellij action list-tabs --json`으로 조회해 `$TMPDIR/cmux-bar-$UID/tabs-<세션>.json`(`CMUX_BAR_CACHE_DIR`)에 쓰고 나머지는 파일만 읽습니다. 바 시작 직후 2초 동안은 zellij CLI를 부르지 않으며(zellij 서버 초기화 충돌 회피), 그 사이 3초 미만의 신선한 캐시가 있으면 그 탭 목록을 바로 그리고 없으면 `…`만 그립니다.
- **에이전트 상태 배지**: 탭 라벨의 오른쪽 패딩 칸을 대신 차지해 에이전트 상태가 붙습니다(폭 불변 — working↔idle이 바뀌어도 오른쪽 탭이 밀리지 않음; 벨 `*`만 예전처럼 한 칸을 더함) — blocked `!`(흰 글자·빨간 배경, 권한 요청·질문 대기) > 벨 `*` > working `~` > 없음(idle). cmux가 띄우는 claude에 `--settings` 훅(`bin/cmux-agent-state hook <이벤트>`, 전역 settings는 건드리지 않고 병합됨)을 붙이고, 훅이 `~/.config/cmux/agent-state/<세션>/<pane_id>`(`CMUX_AGENT_STATE_DIR`)에 상태를 원자적으로 씁니다. 리더 바가 1초 `list-tabs` 직후 이 디렉터리를 읽어 캐시에 실어 모든 바가 그립니다. 탭은 `CMUX_TAB_NAME`(cmux가 export한 탭 이름)으로 묶이고, 탭 안 여러 파일은 blocked > working > idle로 합칩니다. `~`는 300초 넘게 갱신이 없으면 idle로 보고(ESC 중단은 Stop 훅이 오지 않음), 12시간 넘은 파일은 무시합니다. 끄기: `CMUX_STATE_HOOKS=0`. 한계: 탭을 수동으로 이름 바꾸면 매칭되지 않고, 같은 이름의 탭 둘은 합쳐지며, 권한 거부 직후에는 다음 도구 호출·Stop까지 blocked가 남습니다. codex/opencode/gemini는 훅 없이 `CMUX_TAB_NAME`만 export합니다(보류).
- **레거시 모드**: 바 pane의 내용이 1행뿐이면(옛 레이아웃으로 만든 탭 — 위에 네이티브 `tab-bar`가 따로 있음) 예전처럼 툴바 1행만 그립니다. 새 구조는 설치된 레이아웃을 다시 설치(`install.sh --force`)한 뒤 새로 만든 탭/세션부터 적용됩니다(`cmux`가 직접 만드는 세션·`cmux-tab-<에이전트>` 레이아웃은 즉시 새 구조).

### zellij 내 단축키

| 키 | 동작 |
|----|------|
| `Ctrl+b` / `Ctrl+ㅠ` | 세션 유지하고 detach |
| `Ctrl+Shift+Left/Right` | 탭 순서 좌/우로 이동 |
| `Ctrl+Shift+O` | zellij Session 모드 |

**Claude Code 단축키** (zellij 충돌 해소 후 사용 가능):

| 키 | 동작 |
|----|------|
| `Ctrl+O` | 트랜스크립트 보기 토글 (app:toggleTranscript) |
| `Ctrl+T` | 할 일 목록 토글 — zellij Tab 모드와 충돌 주의 |
| `Ctrl+G` | 외부 에디터 열기 |
| `Ctrl+R` | 이전 명령 검색 |

> **zellij 충돌 노트**: `Ctrl+O`는 zellij 기본값(Session 모드)을 `unbind` 처리하여 Claude Code로 패스스루됩니다. zellij Session 모드는 `Ctrl+Shift+O`로 사용하세요.
>
> 세션이 살아있으면 다음에 `cmux` 실행 시 picker 없이 바로 재연결됩니다. 세션이 죽었으면 마지막 탭 구성을 그대로 복원하고 각 탭의 Claude 대화를 이어갑니다.

### 에이전트와 지침 파일

`cmux -a <에이전트> [경로]`(또는 피커)로 탭마다 다른 CLI를 쓸 수 있습니다. 내장: `claude`(기본) · `codex` · `opencode` · `kimi`(Kimi Code). 탭 이름은 `프로젝트·에이전트`, 세션 복원(`session-tabs`)도 에이전트를 기억합니다.

| 에이전트 | 실행 파일 탐색 | 권한 기본(`CMUX_<이름>_PERM`) | 이어하기 |
|----------|----------------|------------------------------|----------|
| kimi | `CMUX_KIMI_BIN` → `~/.kimi-code/bin/kimi` → `~/.local/bin/kimi` → PATH | safe=`--yolo`(Ask When Needed), auto=`--auto`(Never Ask) | `--continue` — 세션이 없는 폴더에서는 kimi가 "No sessions to continue …; starting a fresh session." 하고 새 대화로 시작(2.4.1 실측) |

- **Kimi 메모**: 처음 가는 폴더는 kimi가 "Trust this folder?"를 먼저 묻습니다 — cmux는 대신 답하지 않습니다. 시작 배너의 `[MM-DD HH:MM]`은 `kimi session list --cwd <폴더> --json --limit 1`(8초 제한)의 마지막 갱신 시각이고, 못 읽으면 `[이력이 없으면 새 대화]`입니다. `kimi import-sessions`(다른 CLI 세션 가져오기)는 전역 명령이라 cmux가 부르지 않습니다. **미확인**: Kimi Code가 프로젝트의 `AGENTS.md`를 읽는지(문서에는 전역 `~/.kimi-code/AGENTS.md`·`~/.agents/AGENTS.md`만 있고, 로그인이 필요해 실측하지 못했습니다) — 그래서 아래 연결은 어느 쪽이든 동작하는 포인터 방식입니다.
- **지침 파일 연결**: Claude Code는 `CLAUDE.md`만(`@경로` 임포트 지원), codex는 `AGENTS.md`만, opencode는 `AGENTS.md` 우선(없으면 `CLAUDE.md`)을 읽습니다. 어느 CLI로 열든 같은 지침을 보게 하려고 cmux가 시작할 때 현재 폴더를 살핍니다(순수 zsh 파일 검사, 실패해도 시작은 계속). **자동 생성은 `.collar/`가 있는 프로젝트에서, 지금 실행하는 에이전트가 필요로 하는 파일 한 방향만** 합니다 — claude는 `AGENTS.md`만 있을 때 `CLAUDE.md`를, 그 밖의 에이전트(codex·opencode·kimi 등)는 `CLAUDE.md`만 있을 때 `AGENTS.md`를 만듭니다. 반대 방향은 그 에이전트가 이미 자기 파일을 읽으니 쓰지 않아서, 예를 들어 `cmux -k`로 탭 수십 개를 복원해도 claude 탭 때문에 프로젝트마다 `AGENTS.md`가 새로 생기지 않습니다. 양방향 연결은 `cmux bridge --apply`로 명시합니다.

| 상태 | `.collar/` 있음 — claude 시작 | `.collar/` 있음 — 비-claude 시작 | `.collar/` 없음 — claude 시작 | `.collar/` 없음 — 비-claude 시작 | `cmux bridge --apply` |
|------|------|------|------|------|------|
| `AGENTS.md`만 | `CLAUDE.md` 신규 생성(`@AGENTS.md` + 마커 `<!-- cmux:bridge -->`) | 쓰기·안내 없음(AGENTS.md를 이미 읽음) | 안내 한 줄만 | 쓰기·안내 없음 | `CLAUDE.md` 생성 |
| `CLAUDE.md`만 | 쓰기·안내 없음(CLAUDE.md를 이미 읽음) | `AGENTS.md` 신규 생성("CLAUDE.md를 처음부터 끝까지 읽어라" 포인터 + 마커) — 그 뒤 `collar-agents-sync`가 최상단에 collar 블록 삽입 | 쓰기·안내 없음 | 안내 한 줄만 | `AGENTS.md` 생성 |
| 둘 다, 서로 참조 | 연결됨 — 아무것도 안 함 | 연결됨 | 연결됨 | 연결됨 | 연결됨 |
| 둘 다, 참조 없음 | 안내 한 줄만(자동 수정 없음) | 안내 한 줄만 | 안내 한 줄만 | 안내 한 줄만 | `CLAUDE.md` 끝에 `@AGENTS.md`, `AGENTS.md` 끝에 CLAUDE.md 포인터를 마커 블록(`<!-- cmux:bridge begin -->…<!-- cmux:bridge end -->`)으로 추가 |
| 둘 다 없음 | 아무것도 안 함 | 아무것도 안 함 | 아무것도 안 함 | 아무것도 안 함 | 안내만 |

  **안내 한 줄도 같은 원칙**입니다: 지금 실행하는 에이전트가 읽는 파일이 이미 있으면 조용합니다(claude는 `CLAUDE.md`, 그 밖은 `AGENTS.md`). 안내는 그 에이전트가 읽지 못하는 파일인데 `.collar/`가 없어 만들지 않은 경우와, 둘 다 있지만 서로 가리키지 않아 어느 에이전트에게나 실제 공백인 경우에만 나옵니다(`cmux bridge --apply <경로>`로 연결). `cmux bridge --check`는 에이전트와 무관하게 상태 전체를 보여줍니다.

  참조 판정은 단순 규칙입니다: `CLAUDE.md`에 `@AGENTS.md`(또는 `@./AGENTS.md`)가 있거나 `AGENTS.md`에 `CLAUDE.md` 문자열이 있거나 두 파일이 같은 파일(심볼릭 링크)이면 연결됨. `cmux bridge`는 기본이 `--check`(쓰기 없음)이며 종료코드는 0 연결됨·할 일 없음·적용 성공 / 10 연결 필요 / 2 마커 손상(무변경) / 3 심볼릭 링크 등 안전하지 않음(무변경) / 1 사용법·입출력 오류입니다. 이미 있는 파일은 블록 밖 바이트를 건드리지 않고(원본 + 블록 추가만), 쓰기는 같은 폴더 임시파일 → `mv`로 원자적이며 원 파일 모드를 유지하고, 다시 실행해도 변하지 않습니다. 새 파일은 `git add`/커밋/ignore를 하지 않으니 사용자가 정하세요.
- **새 CLI 붙이기(확장점)**: `~/.config/cmux/agents.d/*.zsh`(환경변수 `CMUX_AGENTS_D`)가 있으면 내장 정의 뒤에 source 됩니다. 파일에서 `CMUX_AGENTS+=(이름)`과 `_ag_<이름>_<훅>` 함수(`bin`·`perm_args`·`resume_args`·`has_history` 등, 목록은 `bin/cmux-agents.zsh` 맨 위)를 정의하면 새 에이전트가 등록됩니다. 이미 있는 이름의 중복 등록은 경고 후 무시되고(내장 어댑터를 덮어쓰지 못함), 문법 오류 파일은 경고 1줄 후 건너뜁니다. 견본(활성화되지 않음): `doc/agents.d/grok.zsh.example` — Grok은 바이너리·접근권·플래그를 확인하지 못해 어댑터를 만들지 않았고, 견본에는 공식 문서로 확인 후 채울 자리만 있습니다.

## 설정

### 프로젝트 루트 변경

기본값: `~/Documents/dev/ai`

```zsh
# ~/.zshrc
export CMUX_ROOT="/your/project/root"
```

### Claude CLI 경로

`/opt/homebrew/bin/claude` → `/usr/local/bin/claude` 순으로 자동 탐색.
다른 경로라면:

```zsh
export CMUX_CLAUDE_BIN="/custom/path/to/claude"
```

### 프로젝트별 에이전트 실행 인자

`~/.config/cmux/agent-args`(환경변수 `CMUX_AGENT_ARGS_FILE`로 변경)에 `대상<TAB>에이전트<TAB>인자`를 한 줄씩 적으면, 그 폴더의 그 에이전트는 권한 프로파일(`CMUX_<A>_PERM`) 인자 대신 이 인자로 시작합니다. 대상은 절대경로 또는 `*`(모든 폴더, 경로 줄이 우선), 인자 안의 `{dir}`은 프로젝트 폴더로 바뀝니다.
인자는 따옴표만 벗기고 어떤 확장(`$VAR`·`$(…)`·`~`·glob)도 하지 않습니다. 예: `/path/KIS<TAB>codex<TAB>--sandbox workspace-write --ask-for-approval on-request -c sandbox_workspace_write.network_access=true`
줄에는 **플래그만** 적습니다 — 이어하기 인자(codex `resume --last`, claude `--continue`, opencode `-s <id>`)는 cmux가 붙이므로 `resume --last`를 넣으면 중복됩니다. 구분자는 반드시 TAB이고(공백은 조용히 무시), 적용되면 시작 배너 아래에 `사용자 인자(…)` 줄이 보입니다. 위험 인자(`--dangerously-bypass-approvals-and-sandbox` 등)도 검사하지 않고 그대로 넘기며, `*` 줄은 모든 폴더의 기본 권한(safe)보다 우선합니다.
추가 예: `printf '%s\t%s\t%s\n' /path/KIS codex '--cd {dir} --sandbox workspace-write --ask-for-approval on-request' >> ~/.config/cmux/agent-args`
자세한 규칙: `doc/2026-10-01-multi-agent-design.md` §16

## 파일 구성

```
cmux/
├── bin/
│   ├── cmux             # 메인 스크립트 (zsh)
│   ├── cmux-bar         # 상단 탭 줄 + 툴바, 1↔2줄 토글 (Python curses)
│   ├── cmux-agent-state # 에이전트 상태 훅·롤업 (zsh) — 탭 배지, cmux status/jump
│   └── cmux-picker      # 커서 기반 피커 (Python)
├── doc/
│   └── agents.d/grok.zsh.example   # 새 에이전트 CLI 등록 견본 (~/.config/cmux/agents.d/ 로 복사해 채움)
├── zellij/
│   ├── config.kdl        # zellij 메인 설정
│   └── layouts/
│       ├── claude-project.kdl.tmpl   # 세션 레이아웃 템플릿
│       └── claude-tab.kdl.tmpl       # new-tab 레이아웃 템플릿
└── install.sh
```

## 문의

sales@com.dooray.com
