#!/usr/bin/env zsh
# Desktop entrypoint and instruction bridge: temporary HOME, no real terminal/agent.
source "${0:A:h}/../lib/harness.zsh"
D_TMP="$(mktemp -d /tmp/cmuxu-desktop.XXXXXX)" || exit 1
trap 'rm -rf -- "$D_TMP"' EXIT
D_ZSH="$(command -v zsh)"
export HOME="$D_TMP/home" ZDOTDIR="$D_TMP/zdotdir"
export CMUX_CONFIG_FILE="$D_TMP/config" CMUX_AGENTS_D="$D_TMP/extensions"
export D_LOG="$D_TMP/desktop.log"
mkdir -p "$HOME/.local/bin" "$D_TMP/project with spaces" "$ZDOTDIR"
cat > "$HOME/.local/bin/cmux" <<'SH'
#!/bin/sh
printf 'cmux cwd=<%s>\n' "$PWD" >> "$D_LOG"
printf 'arg=<%s>\n' "$@" >> "$D_LOG"
SH
cat > "$HOME/.local/bin/zsh" <<'SH'
#!/bin/sh
printf 'shell=<%s>\n' "$*" >> "$D_LOG"
SH
chmod +x "$HOME/.local/bin/"*
print -r -- "export CMUX_ROOT=${(q)D_TMP}/'project with spaces'" > "$CMUX_CONFIG_FILE"

t_scenario D "Noctty entrypoint reads configured root and preserves arguments"
"$D_ZSH" "$T_REPO/bin/cmux-desktop" -a codex 'literal $(no-command); & x' ''
t_assert_eq "desktop exits through the shell" 0 $?
t_assert_contains "configured project directory" "$(cat "$D_LOG")" "cmux cwd=<$D_TMP/project with spaces>"
t_assert_contains "arguments and empty argument preserved" "$(cat "$D_LOG")" $'arg=<-a>\narg=<codex>\narg=<literal $(no-command); & x>\narg=<>'
t_assert_contains "detach leaves interactive shell" "$(cat "$D_LOG")" 'shell=<-i>'
: > "$D_LOG"
CMUX_CONFIG_FILE="$D_TMP/missing" CMUX_ROOT="$D_TMP/absent" "$D_ZSH" "$T_REPO/bin/cmux-desktop" 2>/dev/null
t_assert_eq "missing project directory fails" 1 $?
t_assert_eq "missing directory does not start cmux" "" "$(cat "$D_LOG")"

t_scenario B "bridge: creation by agent, original bytes, idempotence and unsafe paths"
export CMUX_SOURCE_ONLY=1 CMUX_CONFIG_FILE="$D_TMP/no-config"
source "$CMUX_UNDER_TEST"
mkdir -p "$D_TMP/agents/.collar" "$D_TMP/claude/.collar" "$D_TMP/both" "$D_TMP/unsafe"
print -r -- 'Original AGENTS instructions' > "$D_TMP/agents/AGENTS.md"
print -r -- 'Original CLAUDE instructions' > "$D_TMP/claude/CLAUDE.md"
(cd "$D_TMP/agents" && _bridge_launch codex)
t_assert_true "Codex does not create unneeded CLAUDE.md" '[[ ! -e "$D_TMP/agents/CLAUDE.md" ]]'
(cd "$D_TMP/agents" && _bridge_launch claude) >/dev/null
t_assert_contains "Claude receives AGENTS import" "$(cat "$D_TMP/agents/CLAUDE.md")" '@AGENTS.md'
(cd "$D_TMP/claude" && _bridge_launch claude)
t_assert_true "Claude does not create unneeded AGENTS.md" '[[ ! -e "$D_TMP/claude/AGENTS.md" ]]'
(cd "$D_TMP/claude" && _bridge_launch codex) >/dev/null
t_assert_contains "Codex receives CLAUDE pointer" "$(cat "$D_TMP/claude/AGENTS.md")" './CLAUDE.md'
print -rn -- 'original a without newline' > "$D_TMP/both/AGENTS.md"
print -rn -- 'original c without newline' > "$D_TMP/both/CLAUDE.md"
_bridge_cmd --check "$D_TMP/both" >/dev/null
t_assert_eq "check reports connection needed" 10 $?
_bridge_cmd --apply "$D_TMP/both" >/dev/null
t_assert_eq "apply succeeds" 0 $?
a="$(cat "$D_TMP/both/AGENTS.md")" c="$(cat "$D_TMP/both/CLAUDE.md")"
t_assert_true "original bytes retained as prefix" '[[ "$a" == "original a without newline"* && "$c" == "original c without newline"* ]]'
_bridge_cmd --apply "$D_TMP/both" >/dev/null
t_assert_eq "repeat apply leaves AGENTS unchanged" "$a" "$(cat "$D_TMP/both/AGENTS.md")"
t_assert_eq "repeat apply leaves CLAUDE unchanged" "$c" "$(cat "$D_TMP/both/CLAUDE.md")"
print -r -- '<!-- cmux:bridge begin -->' >> "$D_TMP/both/AGENTS.md"
_bridge_cmd --apply "$D_TMP/both" >/dev/null 2>&1
t_assert_eq "malformed markers are rejected" 2 $?
ln -s "$D_TMP/absent" "$D_TMP/unsafe/AGENTS.md"
_bridge_cmd --apply "$D_TMP/unsafe" >/dev/null 2>&1
t_assert_eq "dangling symlink is rejected" 3 $?
t_assert_true "unsafe directory stays untouched" '[[ ! -e "$D_TMP/unsafe/CLAUDE.md" ]]'

t_scenario K "Kimi and extension fallbacks"
_agent_call kimi perm_args safe
t_assert_eq "Kimi safe flags" --yolo "${reply[*]}"
_agent_call kimi perm_args auto
t_assert_eq "Kimi auto flags" --auto "${reply[*]}"
_agent_call kimi resume_args
t_assert_eq "Kimi resumes natively" --continue "${reply[*]}"
mkdir -p "$CMUX_AGENTS_D/not-a-file.zsh"
print -r -- 'CMUX_AGENTS+=(example)' > "$CMUX_AGENTS_D/example.zsh"
_ag_load_extensions
t_assert_true "extension registers and directories are skipped" '_agent_known example'
t_assert_eq "built-in adapter preserved" 'Claude Code' "$(_agent_call claude label; print -r -- "$REPLY")"
t_summary
exit $?
