#!/usr/bin/env zsh
# cmux installer
#
# 사용법:
#   ./install.sh          기본 설치 (~/bin 또는 ~/.local/bin)
#   ./install.sh --force  기존 파일 덮어쓰기
#   ./install.sh --help   도움말

set -euo pipefail

# ── 색상 ──────────────────────────────────────────────
_c_cyan="\033[36m"
_c_green="\033[32m"
_c_yellow="\033[33m"
_c_red="\033[31m"
_c_reset="\033[0m"

_info() { echo "${_c_cyan}▶${_c_reset} $*" }
_ok()   { echo "${_c_green}✓${_c_reset} $*" }
_warn() { echo "${_c_yellow}!${_c_reset} $*" }
_err()  { echo "${_c_red}✗${_c_reset} $*" >&2 }

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --help|-h)
      echo "사용법: ./install.sh [--force]"
      echo ""
      echo "  --force   기존 파일 덮어쓰기"
      echo ""
      echo "설치 위치:"
      echo "  바이너리: ~/.local/bin/"
      echo "  zellij:   ~/.config/zellij/"
      exit 0
      ;;
  esac
done

SCRIPT_DIR="${0:A:h}"

# ── 의존성 확인 ───────────────────────────────────────
_info "의존성 확인 중..."

missing=()
command -v zellij >/dev/null 2>&1 || missing+=("zellij")
command -v python3 >/dev/null 2>&1 || missing+=("python3")

if [[ ${#missing[@]} -gt 0 ]]; then
  _err "필수 도구가 없습니다: ${missing[*]}"
  echo ""
  echo "설치 방법 (macOS):"
  echo "  brew install zellij"
  echo "  python3 는 macOS 기본 포함"
  exit 1
fi

# claude CLI 경로 탐색
CLAUDE_BIN=""
if [[ -x "/opt/homebrew/bin/claude" ]]; then
  CLAUDE_BIN="/opt/homebrew/bin/claude"
elif [[ -x "/usr/local/bin/claude" ]]; then
  CLAUDE_BIN="/usr/local/bin/claude"
elif command -v claude >/dev/null 2>&1; then
  CLAUDE_BIN="$(command -v claude)"
else
  _warn "claude CLI를 찾지 못했습니다. CMUX_CLAUDE_BIN 환경변수로 경로를 지정하세요."
  CLAUDE_BIN="claude"
fi

[[ -n "$CLAUDE_BIN" && "$CLAUDE_BIN" != "claude" ]] && _ok "Claude CLI: $CLAUDE_BIN"

# ── 설치 경로 설정 ─────────────────────────────────────
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

ZELLIJ_CONF_DIR="${HOME}/.config/zellij"
ZELLIJ_LAYOUTS_DIR="${ZELLIJ_CONF_DIR}/layouts"
mkdir -p "$ZELLIJ_LAYOUTS_DIR"

# ── 바이너리 설치 ─────────────────────────────────────
_install_bin() {
  local src="$1"
  local dst="$2"
  local name="$(basename "$dst")"

  if [[ -f "$dst" && "$FORCE" == "false" ]]; then
    _warn "$name 이미 존재합니다 (--force 로 덮어쓰기)"
    return 0
  fi

  cp "$src" "$dst"
  chmod +x "$dst"
  _ok "$name → $dst"
}

_info "바이너리 설치 중..."
_install_bin "${SCRIPT_DIR}/bin/cmux"        "${BIN_DIR}/cmux"
_install_bin "${SCRIPT_DIR}/bin/cmux-picker" "${BIN_DIR}/cmux-picker"

# ── zellij 설정 설치 ──────────────────────────────────
_info "zellij 레이아웃 설치 중..."

_install_layout() {
  local tmpl="$1"
  local dst="$2"

  if [[ -f "$dst" && "$FORCE" == "false" ]]; then
    _warn "$(basename "$dst") 이미 존재합니다 (--force 로 덮어쓰기)"
    return 0
  fi

  # CMUX_BAR_BIN, CLAUDE_BIN 플레이스홀더 치환
  local cmux_bar_path="${BIN_DIR}/cmux-bar"
  sed \
    -e "s|CMUX_BAR_BIN|${cmux_bar_path}|g" \
    -e "s|CLAUDE_BIN|${CLAUDE_BIN}|g" \
    "$tmpl" > "$dst"
  _ok "$(basename "${tmpl%.tmpl}") → $dst"
}

_install_layout \
  "${SCRIPT_DIR}/zellij/layouts/claude-project.kdl.tmpl" \
  "${ZELLIJ_LAYOUTS_DIR}/claude-project.kdl"

_install_layout \
  "${SCRIPT_DIR}/zellij/layouts/claude-tab.kdl.tmpl" \
  "${ZELLIJ_LAYOUTS_DIR}/claude-tab.kdl"

# ── zellij 메인 설정 (선택) ───────────────────────────
ZELLIJ_CONF="${ZELLIJ_CONF_DIR}/config.kdl"
if [[ -f "$ZELLIJ_CONF" && "$FORCE" == "false" ]]; then
  _warn "config.kdl 이미 존재합니다. 수동으로 병합하세요: ${SCRIPT_DIR}/zellij/config.kdl"
else
  cp "${SCRIPT_DIR}/zellij/config.kdl" "$ZELLIJ_CONF"
  _ok "config.kdl → $ZELLIJ_CONF"
fi

# ── PATH 확인 ─────────────────────────────────────────
echo ""
if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  _ok "PATH에 $BIN_DIR 포함되어 있습니다."
else
  _warn "$BIN_DIR 가 PATH에 없습니다."
  echo "   ~/.zshrc 또는 ~/.zprofile에 다음을 추가하세요:"
  echo ""
  echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
_ok "설치 완료! 'cmux' 를 실행하세요."
