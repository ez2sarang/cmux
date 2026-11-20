#!/usr/bin/env zsh
# Click the real bar in an isolated session with Claude and Codex in the same directory.
source "${0:A:h}/../lib/harness.zsh"
t_live_snapshot
t_setup
export CMUX_BAR_BIN="$T_REPO/bin/cmux-bar" CMUX_TABBAR_STATE_FILE="$T_ROOT/cfg/rows" CMUX_BAR_CACHE_DIR="$T_ROOT/barcache"
print 1 > "$CMUX_TABBAR_STATE_FILE"
project="$CMUX_ROOT/project"
mkdir -p "$project"
codex="$project"$'\t'codex
print -rl -- "$project" "$codex" > "$CMUX_TABS_FILE"

_zj() { _t_guard && zellij -s "$T_SESSION" action "$@" }
_bar_id() {
  _zj list-panes --json | python3 -c 'import json, sys
for pane in json.load(sys.stdin):
    if pane["tab_name"] == sys.argv[1] and "cmux-bar;" in (pane.get("terminal_command") or ""):
        print(pane["id"]); break' "$1"
}
_click() {
  local pane="$(_bar_id "$1")"
  [[ "$pane" == <-> ]] || return 1
  t_wait_for '[[ "$(_zj dump-screen --pane-id "$pane")" == *"× Close"* ]]' 10 || return 1
  # Bar-local SGR press/release on the collapsed toolbar's second row.
  local -a bytes=(${=$(python3 -c 'import sys
x=sys.argv[1]; print(*f"\x1b[<0;{x};2M\x1b[<0;{x};2m".encode())' "$2")})
  _zj write --pane-id "$pane" "${bytes[@]}"
}

t_scenario C "Close → server shutdown → cold restart only restores the surviving agent"
t_cmux_bg 60
t_assert_true "both agents running" '(( $(t_agent_procs) == 2 ))' 20
_click project 22
t_assert_true "only Codex remains in the record after Close" '[[ "$(t_tabs_file)" == "$codex" ]]' 8
t_assert_eq "same-directory Codex tab still open" "project·codex" "$(_zj query-tab-names)"
# End the isolated server directly: cmux kill would sync on its own and mask the bug.
_t_guard && zellij delete-session "$T_SESSION" --force >/dev/null 2>&1
t_assert_true "test session stopped" '(( $(t_agent_procs) == 0 ))' 10
t_cmux_bg 60
t_assert_true "cold restart launches only Codex" '(( $(t_agent_launches codex "$project") == 2 && $(t_agent_launches claude "$project") == 1 ))' 15
t_assert_eq "only Codex restored" "project·codex" "$(_zj query-tab-names)"

t_scenario L "Closing the final tab leaves no restore entry"
_click "project·codex" 22
t_assert_true "last tab and record gone" '(( $(t_agent_procs) == 0 )) && [[ -f "$CMUX_TABS_FILE" && ! -s "$CMUX_TABS_FILE" ]]' 10
t_cmux 6
t_assert_true "empty restore opens picker" '[[ -s "$T_ROOT/picker-calls" ]]'
t_assert_eq "no agent relaunched" 0 "$(t_agent_procs)"
t_finish
exit $?
