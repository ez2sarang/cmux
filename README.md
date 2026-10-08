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
│   └── cmux-picker      # 커서 기반 피커 (Python)
├── zellij/
│   ├── config.kdl        # zellij 메인 설정
│   └── layouts/
│       ├── claude-project.kdl.tmpl   # 세션 레이아웃 템플릿
│       └── claude-tab.kdl.tmpl       # new-tab 레이아웃 템플릿
└── install.sh
```

## 문의

sales@com.dooray.com
