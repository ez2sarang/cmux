#!/usr/bin/env zsh
# t06_launch_agent_args — 에이전트 실행 인자 파일 (설계 §16) + cmux launch (가짜 에이전트, 터미널 창(pty)에서 차례로)
#   L1 경로 줄 → 'resume --last' 뒤에 사용자 인자 그대로 (권한 프로파일 -a never -s workspace-write 없음) + 배너 1줄 + argv 경계
#   L2 줄 없음 → 기존 argv·배너 불변 / * 폴백 / 경로 줄 > * / {dir} 여러 번
#   L3 새로 시작 경로 — codex 핸드오프 마커(fresh) · opencode 이력 없음 / fastfail(이어하기 rc=1 즉시) → 새로 다시도 같은 인자
#   L4 claude 기본 동작 불변 · claude 줄 / CMUX_CODEX_PERM=auto 와 줄 공존 → 줄이 이김 / 깨진 줄 → pane 경고 + 프로파일

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

# 실제 ~/.codex·collar 설치본을 쓰지 않게: codex 세션 저장소는 임시 루트로, collar-agents-sync는 PATH에서 뺀다
export CODEX_HOME="$T_ROOT/codex-home"
nosync=()
for e in "${path[@]}"; do [[ -x "$e/collar-agents-sync" ]] || nosync+=("$e"); done
export PATH="${(j.:.)nosync}"
export FAKE_OPENCODE_LIST="$T_ROOT/oclist.json"
print -r -- "[]" > "$FAKE_OPENCODE_LIST"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"
AF="$CMUX_AGENT_ARGS_FILE"

T=$'\t'
PERM="--dangerously-skip-permissions"
SAFE="-a never -s workspace-write"
BYPASS="--dangerously-bypass-approvals-and-sandbox"
RUNS="/Users/ez2sarang/Documents/dev/ai/investments/data/rtbot/runs"
KIS_LINE_ARGS="--cd {dir} --sandbox workspace-write --ask-for-approval on-request --add-dir $RUNS -c sandbox_workspace_write.network_access=true"

# ── 도우미 (t03_launch_agents와 같은 규칙) ─────────────
# _launch_pty <디렉토리> <에이전트> [실행 횟수=1] — 에이전트 실행 기록이 그만큼 늘 때까지 기다린 뒤 창을 닫는다(HUP).
_launch_pty() {
  local _lp_dir="$1" _lp_agent="$2" _lp_want="${3:-1}" _lp_n0
  _lp_n0="$(t_agent_launches "$_lp_agent" "$_lp_dir")"
  t_cmux_bg 30 launch "$_lp_dir" --agent "$_lp_agent"
  t_wait_for '(( $(t_agent_launches "$_lp_agent" "$_lp_dir") >= _lp_n0 + _lp_want ))' 15
  t_wait_for '(( $(t_agent_procs) >= 1 ))' 5
  t_hup
  t_wait_for '(( $(t_agent_procs) == 0 ))' 5
}
_last_args() { t_agent_args "$1" "$2" | tail -1; }
# 마지막 창 화면 로그 — 색 코드·CR 제거
_screen_log() { sed $'s/\e\\[[0-9;]*m//g; s/\r$//' "$T_LAST_LOG"; }
_marker() { mkdir -p "$1/.collar"; printf 'agent=%s\nhandoff=%s\nts=%s\n' "$2" "HANDOFF-2026-10-08.md" "$3" > "$1/.collar/restart-fresh"; }
_transcript() {
  local d="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"
  mkdir -p "$d"
  print -r -l -- '{"type":"queue-operation","operation":"enqueue"}' "{\"type\":\"user\",\"entrypoint\":\"cli\",\"cwd\":\"$1\"}" > "$d/a.jsonl"
}

P="$T_ROOT/proj"
mkdir -p "$P"/{kis,plain,star,multi,mark,oc,ff,cl,clh,perm,bad,argv}
K="$P/kis"
KIS_ARGV="--cd $K --sandbox workspace-write --ask-for-approval on-request --add-dir $RUNS -c sandbox_workspace_write.network_access=true"

# ── L1 ────────────────────────────────────────────────
t_scenario L1 "경로 줄 → resume --last 뒤에 사용자 인자 그대로 + 배너"
print -r -- "$K${T}codex${T}$KIS_LINE_ARGS" > "$AF"
_launch_pty "$K" codex
t_assert_eq "① argv = resume --last + 사용자 인자 ({dir} = 프로젝트 폴더)" "resume --last $KIS_ARGV" "$(_last_args codex "$K")"
t_assert_not_contains "① 권한 프로파일 -a never 없음" "$(_last_args codex "$K")" "-a never"
t_assert_eq "① 1회 실행" 1 "$(t_agent_launches codex "$K")"
scr="$(_screen_log)"
t_assert_contains "⑨ 배너 + 그 아래 사용자 인자 한 줄" "$scr" \
  "▶ Codex: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"$'\n'"  사용자 인자($AF): $KIS_ARGV"
t_assert_eq "⑨ 사용자 인자 줄은 정확히 1줄" 1 "$(print -r -- "$scr" | grep -c '사용자 인자(')"
t_assert_contains "⑨ 배너 색 = 회색(기존 배너와 같음)" "$(cat "$T_LAST_LOG")" $'\e[90m  사용자 인자('
# argv 경계 — 인자마다 [ ]로 기록하는 가짜 codex (공백 든 인자가 한 인자로 넘어가는지)
mkdir -p "$T_ROOT/argv-bin"
cat > "$T_ROOT/argv-bin/fake-codex" <<'SH'
#!/bin/sh
{ printf 'fake-codex\t%s\t' "$PWD"; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$FAKE_AGENT_LOG"
exec sleep "${FAKE_AGENT_SLEEP:-3600}"
SH
chmod +x "$T_ROOT/argv-bin/fake-codex"
A="$P/argv"
print -r -- "$A${T}codex${T}-c 'model=\"o3 mini\"' \"\$(touch $T_ROOT/pwned)\" --cd={dir}" > "$AF"
CMUX_CODEX_BIN="$T_ROOT/argv-bin/fake-codex" _launch_pty "$A" codex
t_assert_eq "① argv 경계 그대로 (따옴표 안 공백 = 한 인자, \$(…)는 글자 그대로)" \
  "[resume][--last][-c][model=\"o3 mini\"][\$(touch $T_ROOT/pwned)][--cd=$A]" "$(_last_args codex "$A")"
t_assert_true "① 명령 치환이 실행되지 않음" '[[ ! -e "$T_ROOT/pwned" ]]'
t_assert_contains "⑨ 배너는 인자마다 필요할 때만 따옴표" "$(_screen_log)" \
  "  사용자 인자($AF): -c 'model=\"o3 mini\"' '\$(touch $T_ROOT/pwned)' --cd=$A"

# ── L2 ────────────────────────────────────────────────
t_scenario L2 "줄 없음 → 불변 / * 폴백 / 경로 > * / {dir}"
print -r -- "$K${T}codex${T}$KIS_LINE_ARGS" > "$AF"
_launch_pty "$P/plain" codex
t_assert_eq "② 맞는 줄 없음 → 기존 argv (resume --last + safe)" "resume --last $SAFE" "$(_last_args codex "$P/plain")"
t_assert_not_contains "② 사용자 인자 배너 없음" "$(_screen_log)" "사용자 인자"
t_assert_contains "② 기존 배너 그대로" "$(_screen_log)" "▶ Codex: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"
rm -f -- "$AF"
_launch_pty "$P/plain" codex
t_assert_eq "② 파일 없음 → 기존 argv" "resume --last $SAFE" "$(_last_args codex "$P/plain")"
print -rl -- "$K${T}codex${T}--kis-only" "*${T}codex${T}-a on-request -s workspace-write" > "$AF"
_launch_pty "$P/star" codex
t_assert_eq "③ * 폴백" "resume --last -a on-request -s workspace-write" "$(_last_args codex "$P/star")"
_launch_pty "$K" codex
t_assert_eq "③ 경로 줄 > * 줄 (합치지 않음)" "resume --last --kis-only" "$(_last_args codex "$K")"
print -r -- "*${T}codex${T}--cd {dir} --add-dir={dir}/data '{dir} x'" > "$AF"
_launch_pty "$P/multi" codex
t_assert_eq "④ {dir} 여러 번 (* 줄 = 각 launch 폴더)" "resume --last --cd $P/multi --add-dir=$P/multi/data $P/multi x" \
  "$(_last_args codex "$P/multi")"

# ── L3 ────────────────────────────────────────────────
t_scenario L3 "새로 시작 경로 · fastfail"
print -rl -- "*${T}codex${T}$KIS_LINE_ARGS" "*${T}opencode${T}--model x/y --cd={dir}" > "$AF"
_marker "$P/mark" codex $EPOCHSECONDS
_launch_pty "$P/mark" codex
t_assert_eq "⑤ codex 핸드오프 마커 → 새로 시작에도 사용자 인자 (resume 없음)" \
  "--cd $P/mark --sandbox workspace-write --ask-for-approval on-request --add-dir $RUNS -c sandbox_workspace_write.network_access=true" \
  "$(_last_args codex "$P/mark")"
t_assert_contains "⑤ 배너: 핸드오프 직후 + 사용자 인자" "$(_screen_log)" \
  "▶ Codex: 핸드오프 직후 — 새로 시작"$'\n'"  사용자 인자($AF): --cd $P/mark "
_launch_pty "$P/oc" opencode
t_assert_eq "⑤ opencode 이력 없음(fresh) → 사용자 인자" "--model x/y --cd=$P/oc" "$(_last_args opencode "$P/oc")"
t_assert_contains "⑤ 배너: 새로 시작 + 사용자 인자" "$(_screen_log)" \
  "▶ OpenCode: 새로 시작"$'\n'"  사용자 인자($AF): --model x/y --cd=$P/oc"
FF="$P/ff"
FAKE_AGENT_FAIL_ON=resume _launch_pty "$FF" codex 2
t_assert_eq "⑥ fastfail → 새로 다시 실행에도 같은 사용자 인자" \
  "resume --last ${KIS_ARGV//$K/$FF}"$'\n'"${KIS_ARGV//$K/$FF}" "$(t_agent_args codex "$FF")"
t_assert_eq "⑥ 사용자 인자 줄은 1번만 (재실행 때 다시 찍지 않음)" 1 "$(_screen_log | grep -c '사용자 인자(')"

# ── L4 ────────────────────────────────────────────────
t_scenario L4 "claude 불변 · PERM=auto와 공존 · 깨진 줄"
print -rl -- "*${T}codex${T}--codex-only" "$P/cl${T}codex${T}--cl-codex" "*${T}opencode${T}--oc-only" > "$AF"
_launch_pty "$P/cl" claude
t_assert_eq "⑦ claude 줄 없음 → 기존 argv (이력 없음)" "$PERM" "$(_last_args claude "$P/cl")"
t_assert_not_contains "⑦ claude 사용자 인자 배너 없음" "$(_screen_log)" "사용자 인자"
_transcript "$P/clh"
_launch_pty "$P/clh" claude
t_assert_eq "⑦ claude 이력 있음 → 기존 argv (--continue)" "$PERM --continue" "$(_last_args claude "$P/clh")"
print -rl -- "*${T}codex${T}--codex-only" "$P/clh${T}claude${T}--model opus" > "$AF"
_launch_pty "$P/clh" claude
t_assert_eq "⑦ claude 줄이 있으면 권한 인자 대신 (claude도 같은 규칙)" "--model opus --continue" "$(_last_args claude "$P/clh")"
print -r -- "$P/perm${T}codex${T}-a on-request -s workspace-write" > "$AF"
CMUX_CODEX_PERM=auto _launch_pty "$P/perm" codex
t_assert_eq "⑧ CMUX_CODEX_PERM=auto + 줄 → 줄이 이김 (bypass 없음)" "resume --last -a on-request -s workspace-write" "$(_last_args codex "$P/perm")"
t_assert_not_contains "⑧ bypass 플래그 없음" "$(_last_args codex "$P/perm")" "$BYPASS"
CMUX_CODEX_PERM=auto _launch_pty "$P/plain" codex
t_assert_eq "⑧ 대조: 줄 없는 폴더는 PERM=auto 그대로" "resume --last $BYPASS" "$(_last_args codex "$P/plain")"
print -rl -- "$P/bad${T}codex${T}-c \"unterminated" > "$AF"
_launch_pty "$P/bad" codex
t_assert_contains "깨진 줄 → pane 경고 1줄 (! 접두)" "$(_screen_log)" \
  "! 인자 파일 ${AF}의 1번째 줄을 해석하지 못해 무시합니다 (닫히지 않은 따옴표, 따옴표 밖 ; | & < > ( ) 등)"
t_assert_eq "깨진 줄 → 무시하고 권한 프로파일" "resume --last $SAFE" "$(_last_args codex "$P/bad")"

t_finish
exit $?
