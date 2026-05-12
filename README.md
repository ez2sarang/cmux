# cmux

Claude Code 멀티 프로젝트 워크스페이스 매니저.

`cmux` 하나로 여러 AI 프로젝트를 zellij 탭으로 열고, 각 탭에서 Claude Code가 자동 시작됩니다.

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
cmux                 # 프로젝트 선택 (Space: 다중선택, Enter: 열기)
cmux /path/to/proj   # 경로 직접 열기
cmux add [경로]      # DEV_ROOT 외 경로 등록
cmux rm              # 등록 경로 제거
cmux list            # 프로젝트 목록
cmux -l              # zellij 세션 목록
cmux -k              # 세션 종료
```

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

> 세션이 살아있으면 다음에 `cmux` 실행 시 picker 없이 바로 재연결됩니다.

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
