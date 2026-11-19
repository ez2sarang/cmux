#!/usr/bin/env zsh
# Platform routing and the Windows npm launcher; no real CLI, network, or zellij.
source "${0:A:h}/../lib/harness.zsh"

W_TMP="$(mktemp -d /tmp/cmuxu-windows.XXXXXX)" || exit 1
trap 'rm -rf -- "$W_TMP"' EXIT
export CMUX_AGENTS_D="$W_TMP/no-extensions"
unset CMUX_CODEX_BIN
source "$T_REPO/bin/cmux-agents.zsh"
W_LAUNCHER="$T_REPO/bin/cmux-codex-windows"
W_ZSH="$(command -v zsh)"

t_scenario W1 "OS routing and explicit overrides"
(
  OSTYPE=darwin23
  _ag_is_wsl
)
t_assert_eq "macOS is not WSL, even when WSL env is inherited" 1 $?

_ag_is_wsl() { return 0; }
_agent_call codex bin
t_assert_eq "WSL defaults to Windows npm launcher" "$W_LAUNCHER" "$REPLY"
CMUX_CODEX_BIN='/mnt/c/Users/Space User/npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/target/bin/codex.exe' _agent_call codex bin
t_assert_eq "legacy npm internal exe uses launcher" "$W_LAUNCHER" "$REPLY"
CMUX_CODEX_BIN=/custom/linux/codex _agent_call codex bin
t_assert_eq "explicit Linux CLI is preserved" /custom/linux/codex "$REPLY"
CMUX_CODEX_BIN=/custom/standalone/codex.exe _agent_call codex bin
t_assert_eq "standalone exe is preserved" /custom/standalone/codex.exe "$REPLY"
CMUX_CODEX_BIN=/custom/codex-windows _agent_call codex bin
t_assert_eq "user wrapper is preserved" /custom/codex-windows "$REPLY"

_ag_is_wsl() { return 1; }
CMUX_CODEX_BIN=/custom/mac/codex _agent_call codex bin
t_assert_eq "macOS/Linux override is preserved" /custom/mac/codex "$REPLY"
_ag_search_bin() { print -r -- "$@"; }
out="$(_agent_call codex bin)"
t_assert_contains "macOS/Linux retains Homebrew search" "$out" /opt/homebrew/bin/codex
t_assert_contains "macOS/Linux retains /usr/local search" "$out" /usr/local/bin/codex
t_assert_not_contains "macOS/Linux never picks Windows launcher" "$out" cmux-codex-windows

t_scenario W2 "Windows npm entrypoint, argument boundaries and exit status"
mkdir -p "$W_TMP"/{bin,empty} "$W_TMP/npm prefix/node_modules/@openai/codex/bin"
export W_NODE_LOG="$W_TMP/node-args" W_PATH_LOG="$W_TMP/path-args"
cat > "$W_TMP/bin/node.exe" <<'SH'
#!/bin/sh
printf '<%s>\n' "$@" > "$W_NODE_LOG"
exit "${W_NODE_EXIT:-0}"
SH
cat > "$W_TMP/bin/wslpath" <<'SH'
#!/bin/sh
printf '<%s>\n' "$@" > "$W_PATH_LOG"
[ "$1" = '-w' ] || exit 99
printf 'C:\\converted path\\codex.js\n'
SH
chmod +x "$W_TMP/bin/"*
touch "$W_TMP/npm prefix/codex.cmd" "$W_TMP/npm prefix/node_modules/@openai/codex/bin/codex.js"
W_PATH="$W_TMP/bin:$W_TMP/npm prefix"

PATH="$W_PATH" "$W_ZSH" "$W_LAUNCHER" resume --last -c 'model="a b"' 'literal $(no-command); & "quote"' ''
t_assert_eq "launcher succeeds" 0 $?
expected=$'<C:\\converted path\\codex.js>\n<resume>\n<--last>\n<-c>\n<model="a b">\n<literal $(no-command); & "quote">\n<>'
t_assert_eq "Node receives official JS path and original argv including empty arg" "$expected" "$(cat "$W_NODE_LOG")"
t_assert_eq "only the script path is converted to Windows" $'<-w>\n<'"$W_TMP/npm prefix/node_modules/@openai/codex/bin/codex.js"'>' "$(cat "$W_PATH_LOG")"
PATH="$W_PATH" W_NODE_EXIT=37 "$W_ZSH" "$W_LAUNCHER" --version
t_assert_eq "CLI exit code propagates" 37 $?

mkdir -p "$W_TMP/pinned npm/node_modules/@openai/codex/bin"
touch "$W_TMP/pinned npm/node_modules/@openai/codex/bin/codex.js"
W_PINNED="$W_TMP/pinned npm/node_modules/@openai/codex/vendor/target/bin/codex.exe"
PATH="$W_PATH" CMUX_CODEX_BIN="$W_PINNED" "$W_ZSH" "$W_LAUNCHER" --version
t_assert_eq "legacy pin keeps its npm prefix instead of PATH's other install" $'<-w>\n<'"$W_TMP/pinned npm/node_modules/@openai/codex/bin/codex.js"'>' "$(cat "$W_PATH_LOG")"

t_scenario W3 "missing dependencies fail before starting Codex"
rm -f -- "$W_NODE_LOG"
out="$(PATH="$W_TMP/empty" "$W_ZSH" "$W_LAUNCHER" 2>&1)"; rc=$?
t_assert_eq "missing Windows Node exits 127" 127 "$rc"
t_assert_contains "missing Node explains Windows/WSL requirement" "$out" 'Windows node.exe not found'
out="$(PATH="$W_TMP/bin" "$W_ZSH" "$W_LAUNCHER" 2>&1)"; rc=$?
t_assert_eq "missing Windows npm package exits 127" 127 "$rc"
t_assert_contains "missing npm package is actionable" "$out" 'Windows npm Codex launcher not found'
out="$(PATH="$W_PATH" CMUX_CODEX_BIN="$W_TMP/missing/node_modules/@openai/codex/vendor/target/bin/codex.exe" "$W_ZSH" "$W_LAUNCHER" 2>&1)"; rc=$?
t_assert_eq "broken pin does not silently select another npm install" 127 "$rc"
t_assert_true "dependency failure never executes Node" '[[ ! -e "$W_NODE_LOG" ]]'

t_summary
exit $?
