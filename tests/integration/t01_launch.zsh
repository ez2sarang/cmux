#!/usr/bin/env zsh
# t01_launch — cmux launch(에이전트 pane 진입점): 이력 판정·fastfail 폴백·실행 파일 없음·--agent
#   L1 이력 판정 — cli / sdk-cli만 / cli+더 최신 sdk-cli / 이력 없음 → --continue 유무 (4탭 복원)
#   L2 fastfail — --continue가 곧바로 실패(rc=1) → --continue 없이 1회 재실행 → 에이전트 생존
#   L3 재실행은 1회만, 이어하기가 아니었으면 재실행 없음 (둘 다 실패해도 탭 유지)
#   L4 실행 파일 없음 → pane에 사유 1줄 + 셸(zsh -i)로 생존, 모든 탭 복원
#   L5 --agent — 알 수 없는 이름은 실행 전 오류·exit 1 / claude 명시는 정상, 창 닫기(HUP)에 에이전트도 종료

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

P_CLI="$CMUX_ROOT/p-cli"     # 대화형(cli) 세션
P_SDK="$CMUX_ROOT/p-sdk"     # 'claude -p' 요약(sdk-cli) 세션만
P_MIX="$CMUX_ROOT/p-mix"     # cli + 더 최신 sdk-cli
P_NONE="$CMUX_ROOT/p-none"   # 이력 없음
mkdir -p "$P_CLI" "$P_SDK" "$P_MIX" "$P_NONE"

# 가짜 트랜스크립트 — 실제 파일처럼 앞쪽 줄에 entrypoint가 있다
_transcript() {  # <프로젝트 경로> <파일 이름> <entrypoint>
  local d="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"
  mkdir -p "$d"
  print -r -l -- '{"type":"queue-operation","operation":"enqueue"}' \
    "{\"type\":\"user\",\"entrypoint\":\"$3\",\"cwd\":\"$1\"}" > "$d/$2.jsonl"
}
_transcript "$P_CLI" a cli
_transcript "$P_SDK" s sdk-cli
_transcript "$P_MIX" a cli
touch -t 202601010000 "$CLAUDE_CONFIG_DIR/projects/${P_MIX//[^A-Za-z0-9]/-}/a.jsonl"
_transcript "$P_MIX" s sdk-cli

# pane 셸(zsh -i)의 첫 실행 마법사 방지 + 식별용 프롬프트
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

# zellij를 직접 부르는 곳은 harness의 t_zj_gate 뒤에 둔다 (zellij 0.45.1 #5632 — harness.zsh 머리말)
# 탭별 claude pane: "탭<TAB>exited<TAB>exit_status<TAB>실행 중 명령<TAB>pane id"
_claude_panes() {
  _t_guard 2>/dev/null || return 1
  t_zj_gate
  zellij -s "$T_SESSION" action list-panes -a -j 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:  # 세션이 아직 준비 전이면 빈 출력
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and p.get("title") == "claude":
        print("\t".join(str(p.get(k)) for k in ("tab_name", "exited", "exit_status", "pane_command", "id")))'
}
# claude pane들의 (exited, exit_status) 종류 — 모두 같으면 한 줄. 예: "False None"(실행 중) / "True 1"(rc=1로 종료)
_claude_states() { _claude_panes | cut -f2,3 | sort -u | tr '\t' ' '; }
# claude pane들의 포그라운드 명령 종류
_claude_cmds() { _claude_panes | cut -f4 | sort -u; }
_pane_id() { _claude_panes | awk -F'\t' -v t="$1" '$1==t {print "terminal_" $5}'; }

# _assert_eventually <설명> <기대> <조회 명령(eval)> [초=10]
#   기대값이 나올 때까지 폴링하고, 마지막으로 본 값으로 비교한다 (부하 중 zellij 조회가 잠깐 빈 값을 줄 수 있다)
_assert_eventually() {
  local _ae_want="$2" _ae_cmd="$3" _ae_got=""
  t_wait_for '_ae_got="$(eval "$_ae_cmd")"; [[ "$_ae_got" == "$_ae_want" ]]' "${4:-10}"
  t_assert_eq "$1" "$_ae_want" "$_ae_got"
}

# _start_session — 세션을 새로 띄우고 서버 초기화(session-metadata.kdl)를 파일로 확인
_start_session() {
  t_cmux_bg 120
  t_assert_true "세션 준비 (session-metadata.kdl)" 't_session_ready' 20
}

# 다음 시나리오 준비: 창 닫기 → 세션 종료(상태 기반 확인) → 탭 기록 지정
_reset() {  # <탭 경로...>
  t_hup
  t_cmux 30 kill
  t_assert_true "이전 세션 종료·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
  print -r -l -- "$@" > "$CMUX_TABS_FILE"
}

PERM="--dangerously-skip-permissions"

# ── L1 ────────────────────────────────────────────────
t_scenario L1 "이력 판정 — cli / sdk-cli만 / cli+최신 sdk-cli / 없음"
print -r -l -- "$P_CLI" "$P_SDK" "$P_MIX" "$P_NONE" > "$CMUX_TABS_FILE"
_start_session
t_assert_true "4탭 모두 에이전트 실행 중" '(( $(t_agent_procs) == 4 ))' 30
_assert_eventually "탭 4개 (기록 순서)" $'p-cli\np-sdk\np-mix\np-none' t_tab_names
# 가짜 에이전트는 기록한 뒤 sleep으로 바뀌므로, 위 프로세스 4개 확인 뒤에는 기록이 확정돼 있다
t_assert_eq "cli 세션 → --continue" "$PERM --continue" "$(t_agent_args claude "$P_CLI")"
t_assert_eq "sdk-cli 세션만 → --continue 없음" "$PERM" "$(t_agent_args claude "$P_SDK")"
t_assert_eq "cli + 더 최신 sdk-cli → --continue" "$PERM --continue" "$(t_agent_args claude "$P_MIX")"
t_assert_eq "이력 없음 → --continue 없음" "$PERM" "$(t_agent_args claude "$P_NONE")"
_assert_eventually "claude pane 4개 실행 중" "False None" _claude_states

# ── L2 ────────────────────────────────────────────────
t_scenario L2 "fastfail — --continue 즉시 실패 → --continue 없이 1회 재실행"
_reset "$P_CLI"
export FAKE_AGENT_FAIL_ON=--continue
_start_session
unset FAKE_AGENT_FAIL_ON
t_assert_true "p-cli 실행 2회 추가 (총 3회)" '(( $(t_agent_launches claude "$P_CLI") == 3 ))' 30
t_assert_true "재실행된 에이전트 생존" '(( $(t_agent_procs) == 1 ))' 10
args=("${(@f)$(t_agent_args claude "$P_CLI")}")
t_assert_eq "1차: --continue (실패)" "$PERM --continue" "${args[2]}"
t_assert_eq "2차: --continue 없이" "$PERM" "${args[3]}"
_assert_eventually "claude pane 실행 중" "False None" _claude_states
_assert_eventually "탭 유지" "p-cli" t_tab_names

# ── L3 ────────────────────────────────────────────────
t_scenario L3 "재실행은 1회만 · 이어하기가 아니었으면 재실행 없음"
_reset "$P_CLI" "$P_NONE"
export FAKE_AGENT_FAIL_ON="$PERM"   # 모든 실행이 곧바로 실패
_start_session
unset FAKE_AGENT_FAIL_ON
# pane이 끝난(cmux launch 종료) 뒤의 실행 횟수가 최종값이다
_assert_eventually "claude pane 2개 모두 종료 (rc=1)" "True 1" _claude_states 30
t_assert_eq "p-cli: 이어하기 1회 + 새 대화 1회 (총 5회)" 5 "$(t_agent_launches claude "$P_CLI")"
args=("${(@f)$(t_agent_args claude "$P_CLI")}")
t_assert_eq "p-cli 4회째: --continue" "$PERM --continue" "${args[4]}"
t_assert_eq "p-cli 5회째: --continue 없이" "$PERM" "${args[5]}"
t_assert_eq "p-none: 재실행 없음 (총 2회)" 2 "$(t_agent_launches claude "$P_NONE")"
_assert_eventually "탭 유지 (p-cli, p-none)" $'p-cli\np-none' t_tab_names

# ── L4 ────────────────────────────────────────────────
t_scenario L4 "실행 파일 없음 → 사유 + 셸로 생존, 모든 탭 복원"
_reset "$P_CLI" "$P_NONE"
n_before="$(t_agent_launches claude "$P_CLI") $(t_agent_launches claude "$P_NONE")"
export CMUX_CLAUDE_BIN="$T_ROOT/bin/no-such-claude"
_start_session
export CMUX_CLAUDE_BIN="$T_ROOT/bin/fake-claude"
_assert_eventually "탭 2개 복원" $'p-cli\np-none' t_tab_names 20
t_wait_for '[[ "$(_claude_states)" == "False None" && "$(_claude_cmds)" == "zsh -i" ]]' 20
t_assert_true "claude pane 2개 모두 셸(zsh -i) 실행 중" '[[ "$(_claude_states)" == "False None" && "$(_claude_cmds)" == "zsh -i" ]]'
NOTFOUND_MSG="Claude Code 실행 파일을 찾지 못했습니다 (환경변수 CMUX_CLAUDE_BIN 로 지정)"
pid_cli=""
t_wait_for 'pid_cli="$(_pane_id p-cli)"; [[ -n "$pid_cli" ]]' 10
_dump_cli() { _t_guard && t_zj_gate && zellij -s "$T_SESSION" action dump-screen -p "$pid_cli" --path "$T_ROOT/screen-cli.txt" 2>/dev/null; }
t_wait_for '_dump_cli && [[ "$(cat "$T_ROOT/screen-cli.txt" 2>/dev/null)" == *"$NOTFOUND_MSG"* ]]' 10
t_assert_contains "pane에 사유 출력" "$(cat "$T_ROOT/screen-cli.txt" 2>/dev/null)" "$NOTFOUND_MSG"
# 셸이 실제로 입력을 받는지 — 명령을 보내 파일을 쓰게 한다 (zellij 호출이 실패하면 성공할 때까지 재시도)
_type_cli() { _t_guard && t_zj_gate && zellij -s "$T_SESSION" action write-chars -p "$pid_cli" "print -r -- \$PWD > $T_ROOT/shell-alive"$'\r' 2>/dev/null; }
t_wait_for '_type_cli' 10
t_assert_true "셸이 명령 실행 (cwd = p-cli)" '[[ "$(cat "$T_ROOT/shell-alive" 2>/dev/null)" == "$P_CLI" ]]' 10
t_assert_eq "에이전트 실행 없음" "$n_before" "$(t_agent_launches claude "$P_CLI") $(t_agent_launches claude "$P_NONE")"
t_assert_eq "session-tabs 유지" "$P_CLI"$'\n'"$P_NONE" "$(t_tabs_file)"

# ── L5 ────────────────────────────────────────────────
t_scenario L5 "--agent — 알 수 없는 이름은 실행 전 오류 / claude 명시는 정상"
t_hup
t_cmux 30 kill
t_assert_true "세션 종료·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
n_none="$(t_agent_launches claude "$P_NONE")"
t_cmux 10 launch --agent nope "$P_NONE"
t_assert_eq "알 수 없는 에이전트 → exit 1" 1 "$T_LAST_RC"
t_assert_contains "오류 메시지" "$(cat "$T_LAST_LOG")" "알 수 없는 에이전트: 'nope' (사용 가능: claude)"
t_cmux 10 launch "$P_NONE" --agent
t_assert_eq "--agent 값 없음 → exit 1" 1 "$T_LAST_RC"
t_assert_eq "오류일 때 에이전트 실행 없음" "$n_none" "$(t_agent_launches claude "$P_NONE")"
# 고정 시간 창 대신: 에이전트가 뜬 것을 확인한 뒤 창을 닫는다
t_cmux_bg 60 launch "$P_NONE" --agent claude
t_assert_true "--agent claude 실행 1회" '(( $(t_agent_launches claude "$P_NONE") == n_none + 1 ))' 10
t_assert_true "--agent claude 에이전트 실행 중" '(( $(t_agent_procs) == 1 ))' 10
t_hup
t_assert_eq "--agent claude → 창을 닫을 때까지 실행" "hup" "$(_t_status_rc "$T_LAST_LOG.status")"
t_assert_eq "--agent claude 인자" "$PERM" "$(t_agent_args claude "$P_NONE" | tail -1)"
t_assert_true "창 닫기(HUP) → 에이전트(자식 프로세스)도 종료" '(( $(t_agent_procs) == 0 ))' 5

t_finish
exit $?
