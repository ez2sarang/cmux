#!/usr/bin/env zsh
# t03_launch_agents — cmux launch <dir> --agent codex|opencode|claude (가짜 에이전트)
#   G1 격리 zellij 세션의 pane들 — codex(이력 무관 resume --last + safe 권한) / opencode(-s <id> · 이력 없음 · 없는 id → fastfail)
#      / claude 일치 마커 → 새로 시작 + 소비 / 다른 에이전트 마커 무시 / collar-agents-sync(비-claude·.collar 폴더만) / 배너
#   G2 마커 (터미널 창에서 차례로) — 소비 → 다음 launch는 일반 경로 / TTL 초과 / 유예 초과 / 다른 에이전트 마커 / 동시 launch 경합
#   G3 collar-agents-sync — 호출 인자 · 2초 타임박스(5초 걸리는 sync가 launch를 막지 않음) · exit 2 경고 · PATH에 없을 때 조용히
#   G4 권한 프로파일 env — CMUX_CODEX_PERM=auto / 잘못된 값 → 경고 + safe, 배너 문구

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

# 실제 ~/.codex·collar 설치본을 쓰지 않게: codex 세션 저장소와 collar-agents-sync를 임시 루트로
export CODEX_HOME="$T_ROOT/codex-home"
mkdir -p "$T_ROOT/syncbin"
cat > "$T_ROOT/syncbin/collar-agents-sync" <<'SH'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_SYNC_LOG"
[ -n "$FAKE_SYNC_SLEEP" ] && exec sleep "$FAKE_SYNC_SLEEP"
exit "${FAKE_SYNC_RC:-0}"
SH
chmod +x "$T_ROOT/syncbin/collar-agents-sync"
export PATH="$T_ROOT/syncbin:$PATH"
export FAKE_SYNC_LOG="$T_ROOT/sync.log"
: > "$FAKE_SYNC_LOG"
export FAKE_OPENCODE_LIST="$T_ROOT/oclist.json"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

PERM="--dangerously-skip-permissions"
SAFE="-a never -s workspace-write"
BYPASS="--dangerously-bypass-approvals-and-sandbox"

# ── 픽스처 ────────────────────────────────────────────
# _codex_rollout <cwd> <이름> — 대화형(cli) codex 세션 (첫 줄 session_meta)
_codex_rollout() {
  local f="$CODEX_HOME/sessions/2026/10/01/rollout-$2.jsonl"
  mkdir -p "${f:h}"
  print -r -- "{\"timestamp\":\"t\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$2\",\"cwd\":\"$1\",\"originator\":\"codex-tui\",\"source\":\"cli\"}}" > "$f"
}
# _transcript <프로젝트 경로> <파일 이름> <entrypoint> — claude 트랜스크립트
_transcript() {
  local d="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"
  mkdir -p "$d"
  print -r -l -- '{"type":"queue-operation","operation":"enqueue"}' "{\"type\":\"user\",\"entrypoint\":\"$3\",\"cwd\":\"$1\"}" > "$d/$2.jsonl"
}
# _marker <프로젝트 경로> <agent> <ts> — collar-handoff가 쓰는 형식 그대로
_marker() { mkdir -p "$1/.collar"; printf 'agent=%s\nhandoff=%s\nts=%s\n' "$2" "HANDOFF-2026-10-01.md" "$3" > "$1/.collar/restart-fresh"; }
_consumed_count() { print -l -- "$1"/.collar/.restart-fresh.consumed-<->(N) | grep -c .; }
_oce() { print -r -- "{\"id\":\"$1\",\"title\":\"t\",\"directory\":\"$2\",\"projectId\":\"p\",\"created\":1,\"updated\":$3}"; }

# ── zellij (harness.zsh 머리말의 #5632 규칙: 시작 마크 → t_zj_gate 뒤에만 소켓 조회) ──
# _zj_start <레이아웃 파일> — 격리 세션을 터미널 창(pty)에서 새로 띄운다 (t_cmux_bg와 같은 정리·마크 규칙)
_zj_start() {
  _t_guard || return 99
  _t_newlog zellij
  : > "$T_ZJ_MARK"
  python3 "$T_PTYRUN" --log "$T_LAST_LOG" --secs 120 -- zellij -s "$T_SESSION" -n "$1" 2> "$T_LAST_LOG.status" &
  T_CLIENT_PID=$!
  T_BG_PIDS+=($T_CLIENT_PID)
}
# _kdl_agent_tab <탭 이름> <디렉토리> <에이전트> — pane 하나(name="agent")가 'cmux launch <dir> --agent <a>' 실행
_kdl_agent_tab() {
  print -r -- "    tab name=\"$1\" cwd=\"$2\" {
        pane name=\"agent\" {
            command \"$CMUX_UNDER_TEST\"
            args \"launch\" \"$2\" \"--agent\" \"$3\"
        }
    }"
}
# 탭별 agent pane: "탭<TAB>exited<TAB>exit_status<TAB>pane id"
_agent_panes() {
  _t_guard 2>/dev/null || return 1
  t_zj_gate
  zellij -s "$T_SESSION" action list-panes -a -j 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and p.get("title") == "agent":
        print("\t".join(str(p.get(k)) for k in ("tab_name", "exited", "exit_status", "id")))'
}
_agent_states() { _agent_panes | cut -f2,3 | sort -u | tr '\t' ' '; }
# _screen <탭 이름> — 그 탭 agent pane의 화면 (dump-screen)
_screen() {
  local id
  id="$(_agent_panes | awk -F'\t' -v t="$1" '$1==t {print "terminal_" $4}')"
  [[ -n "$id" ]] || return 1
  _t_guard && t_zj_gate && zellij -s "$T_SESSION" action dump-screen -p "$id" --path "$T_ROOT/screen.txt" 2>/dev/null \
    && cat "$T_ROOT/screen.txt"
}
_assert_eventually() {  # <설명> <기대> <조회 명령(eval)> [초=10]
  local _ae_want="$2" _ae_cmd="$3" _ae_got=""
  t_wait_for '_ae_got="$(eval "$_ae_cmd")"; [[ "$_ae_got" == "$_ae_want" ]]' "${4:-10}"
  t_assert_eq "$1" "$_ae_want" "$_ae_got"
}

# ── 터미널 창(pty)에서 launch 한 번 ───────────────────
# _launch_pty <디렉토리> <에이전트> — 에이전트 실행 기록이 1회 늘 때까지 기다린 뒤 창을 닫는다(HUP).
#   결과: T_LAST_LOG(화면 로그), LP_ELAPSED(시작 → 실행 기록 확인까지 초)
_launch_pty() {
  local _lp_dir="$1" _lp_agent="$2" _lp_n0 _lp_t0
  _lp_n0="$(t_agent_launches "$_lp_agent" "$_lp_dir")"
  _lp_t0=$EPOCHREALTIME
  t_cmux_bg 30 launch "$_lp_dir" --agent "$_lp_agent"
  t_wait_for '(( $(t_agent_launches "$_lp_agent" "$_lp_dir") > _lp_n0 ))' 15
  LP_ELAPSED=$(( EPOCHREALTIME - _lp_t0 ))
  t_wait_for '(( $(t_agent_procs) >= 1 ))' 5
  t_hup
  t_wait_for '(( $(t_agent_procs) == 0 ))' 5
}
_last_args() { t_agent_args "$1" "$2" | tail -1; }

# ── G1 ────────────────────────────────────────────────
t_scenario G1 "격리 zellij pane — codex·opencode·claude 마커·sync·배너"
P="$T_ROOT/proj"
mkdir -p "$P"/{cx-hist,cx-none,oc-hist,oc-none,oc-bad,cl-mark,cx-other}
_codex_rollout "$P/cx-hist" r1
_print_list() { print -r -- "[${(j:,:)@}]" > "$FAKE_OPENCODE_LIST"; }
_print_list "$(_oce ses_hist "$P/oc-hist" 1790000000000)" "$(_oce ses_gone "$P/oc-bad" 1790000000000)" \
  "$(_oce ses_elsewhere "$P/oc-elsewhere" 1799999999999)"
_transcript "$P/cl-mark" a cli
_marker "$P/cl-mark" claude $EPOCHSECONDS
_marker "$P/cx-other" claude $EPOCHSECONDS
LAYOUT="$T_ROOT/layouts/t03-agents.kdl"
{
  print -r -- "layout {"
  _kdl_agent_tab cx-hist "$P/cx-hist" codex
  _kdl_agent_tab cx-none "$P/cx-none" codex
  _kdl_agent_tab oc-hist "$P/oc-hist" opencode
  _kdl_agent_tab oc-none "$P/oc-none" opencode
  _kdl_agent_tab oc-bad "$P/oc-bad" opencode
  _kdl_agent_tab cl-mark "$P/cl-mark" claude
  _kdl_agent_tab cx-other "$P/cx-other" codex
  print -r -- "}"
} > "$LAYOUT"
export FAKE_AGENT_FAIL_ON=ses_gone   # 없는 opencode 세션 id → 'opencode -s'가 rc=1로 즉시 끝나는 것 흉내
_zj_start "$LAYOUT"
unset FAKE_AGENT_FAIL_ON
t_assert_true "세션 준비 (session-metadata.kdl)" 't_session_ready' 20
t_assert_true "7개 pane 모두 에이전트 실행 중" '(( $(t_agent_procs) == 7 ))' 30
_assert_eventually "agent pane 7개 실행 중" "False None" _agent_states
t_assert_eq "codex 이력 있음 → resume --last + safe(기본)" "resume --last $SAFE" "$(t_agent_args codex "$P/cx-hist")"
t_assert_eq "codex 이력 없음 → 그래도 resume --last (codex가 새 대화로 시작)" "resume --last $SAFE" "$(t_agent_args codex "$P/cx-none")"
t_assert_eq "opencode 이력 → -s <id>" "-s ses_hist" "$(t_agent_args opencode "$P/oc-hist")"
t_assert_eq "opencode 이력 없음 → 플래그 없음" "" "$(t_agent_args opencode "$P/oc-none")"
t_assert_eq "opencode 이력 없음 → 1회" 1 "$(t_agent_launches opencode "$P/oc-none")"
t_assert_eq "opencode 없는 id → -s 즉시 실패 → 플래그 없이 재실행" "[-s ses_gone]"$'\n'"[]" \
  "$(t_agent_args opencode "$P/oc-bad" | sed 's/^/[/;s/$/]/')"
t_assert_eq "claude 일치 마커 → --continue 없이 새로 시작" "$PERM" "$(t_agent_args claude "$P/cl-mark")"
t_assert_eq "claude 마커 소비 → consumed 1개·마커 없음" "1|no" \
  "$(_consumed_count "$P/cl-mark")|$([[ -e "$P/cl-mark/.collar/restart-fresh" ]] && print yes || print no)"
t_assert_eq "codex는 claude용 마커 무시 → resume --last" "resume --last $SAFE" "$(t_agent_args codex "$P/cx-other")"
t_assert_eq "claude용 마커는 그대로" "agent=claude" "$(head -1 "$P/cx-other/.collar/restart-fresh")"
t_assert_eq "collar-agents-sync: .collar 있는 비-claude 폴더만 1회 (claude·.collar 없는 폴더 제외)" \
  "$P/cx-other|$P/cx-other" "$(cat "$FAKE_SYNC_LOG")"
strftime -s want '%m-%d %H:%M' "$(stat -f %m "$CODEX_HOME/sessions/2026/10/01/rollout-r1.jsonl")"
scr=""
t_wait_for 'scr="$(_screen cx-hist)"; [[ "$scr" == *"▶ Codex"* ]]' 10
t_assert_contains "pane 배너: codex 이어서 [마지막 활동 시각]" "$scr" "▶ Codex: 이전 대화 이어서 시작 [$want]"
t_wait_for 'scr="$(_screen cl-mark)"; [[ "$scr" == *"▶ Claude"* ]]' 10
t_assert_contains "pane 배너: claude 핸드오프 직후" "$scr" "▶ Claude Code: 핸드오프 직후 — 새로 시작"
t_wait_for 'scr="$(_screen oc-hist)"; [[ "$scr" == *"▶ OpenCode"* ]]' 10
t_assert_contains "pane 배너: opencode 이어서 [id]" "$scr" "▶ OpenCode: 이전 대화 이어서 시작 [ses_hist]"
t_wait_for 'scr="$(_screen oc-none)"; [[ "$scr" == *"▶ OpenCode"* ]]' 10
t_assert_contains "pane 배너: opencode 새로 시작" "$scr" "▶ OpenCode: 새로 시작"
_assert_eventually "탭 7개" $'cx-hist\ncx-none\noc-hist\noc-none\noc-bad\ncl-mark\ncx-other' t_tab_names
t_hup
t_cmux 30 kill
t_assert_true "세션 종료·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10

# ── G2 ────────────────────────────────────────────────
t_scenario G2 "마커 — 소비 후 일반 경로 / TTL·유예 초과 / 다른 에이전트 / 동시 launch 경합"
M="$T_ROOT/m1"
mkdir -p "$M"
_transcript "$M" a cli
_marker "$M" claude $EPOCHSECONDS
_launch_pty "$M" claude
t_assert_eq "일치 마커 → 새로 시작" "$PERM" "$(_last_args claude "$M")"
t_assert_contains "배너: 핸드오프 직후" "$(cat "$T_LAST_LOG")" "▶ Claude Code: 핸드오프 직후 — 새로 시작"
t_assert_eq "소비 → consumed 1개" 1 "$(_consumed_count "$M")"
_launch_pty "$M" claude
t_assert_eq "같은 마커 두 번째 launch → 일반 경로(이어하기)" "$PERM --continue" "$(_last_args claude "$M")"
t_assert_contains "배너: 이어서" "$(cat "$T_LAST_LOG")" "▶ Claude Code: 이전 대화 이어서 시작 ["
_marker "$M" claude $(( EPOCHSECONDS - 172801 - 5 ))
_launch_pty "$M" claude
t_assert_eq "TTL(48시간) 초과 → 이어하기" "$PERM --continue" "$(_last_args claude "$M")"
t_assert_true "TTL 초과 마커는 그대로" '[[ -f "$M/.collar/restart-fresh" ]]'
_marker "$M" claude $(( EPOCHSECONDS - 1000 ))
touch "$CLAUDE_CONFIG_DIR/projects/${M//[^A-Za-z0-9]/-}/a.jsonl"     # 핸드오프(ts) 뒤 1000초에 대화 활동
_launch_pty "$M" claude
t_assert_eq "유예(300초) 초과 활동 → 이어하기" "$PERM --continue" "$(_last_args claude "$M")"
t_assert_true "유예 초과 마커는 그대로" '[[ -f "$M/.collar/restart-fresh" ]]'
_marker "$M" opencode $EPOCHSECONDS
_launch_pty "$M" claude
t_assert_eq "다른 에이전트(opencode) 마커 → claude는 이어하기" "$PERM --continue" "$(_last_args claude "$M")"
t_assert_eq "다른 에이전트 마커는 그대로" "agent=opencode" "$(head -1 "$M/.collar/restart-fresh")"
t_assert_eq "consumed는 여전히 1개" 1 "$(_consumed_count "$M")"
# 같은 폴더·같은 에이전트 launch 2개가 동시에 마커를 본다 → 원자적 mv로 정확히 하나만 새로 시작
R="$T_ROOT/race"
mkdir -p "$R"
_transcript "$R" a cli
_marker "$R" claude $EPOCHSECONDS
t_cmux_bg 30 launch "$R" --agent claude; pid_a=$T_CLIENT_PID
t_cmux_bg 30 launch "$R" --agent claude; pid_b=$T_CLIENT_PID
t_assert_true "동시 launch 2개 → 에이전트 2회 실행" '(( $(t_agent_launches claude "$R") == 2 ))' 15
t_assert_eq "정확히 하나만 새로 시작, 하나는 이어하기" "$PERM"$'\n'"$PERM --continue" "$(t_agent_args claude "$R" | sort)"
t_assert_eq "consumed 1개·마커 없음" "1|no" "$(_consumed_count "$R")|$([[ -e "$R/.collar/restart-fresh" ]] && print yes || print no)"
t_wait_for '(( $(t_agent_procs) == 2 ))' 5
t_hup $pid_a; t_hup $pid_b
t_assert_true "창 닫기 → 에이전트 0" '(( $(t_agent_procs) == 0 ))' 5

# ── G3 ────────────────────────────────────────────────
t_scenario G3 "collar-agents-sync — 인자 · 2초 타임박스 · exit 2 경고 · PATH에 없음"
S="$T_ROOT/s1"
mkdir -p "$S/.collar"
: > "$FAKE_SYNC_LOG"
_launch_pty "$S" claude
t_assert_eq "claude → sync 호출 없음" "" "$(cat "$FAKE_SYNC_LOG")"
_launch_pty "$S" codex
t_assert_eq "codex → sync 1회, 인자·cwd = 프로젝트 폴더" "$S|$S" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "codex 인자 (sync 뒤 정상 실행)" "resume --last $SAFE" "$(_last_args codex "$S")"
FAKE_SYNC_SLEEP=5.4242 _launch_pty "$S" opencode
t_assert_true "5초 걸리는 sync → 2초 타임박스 뒤 실행 (실측 ${LP_ELAPSED:0:4}초)" '(( LP_ELAPSED >= 1.9 && LP_ELAPSED < 4.5 ))'
t_assert_eq "타임박스 → sync 프로세스 종료" 0 "$(ps -axo command= | grep -c '^sleep 5.4242$')"
t_assert_eq "타임박스 → 에이전트는 정상 실행" "" "$(_last_args opencode "$S")"
t_assert_not_contains "타임박스 → 경고 없음" "$(cat "$T_LAST_LOG")" "collar-agents-sync"
FAKE_SYNC_RC=2 _launch_pty "$S" codex
t_assert_contains "exit 2 → 경고 1줄" "$(cat "$T_LAST_LOG")" "AGENTS.md의 collar 블록 마커가 깨져 갱신하지 않았습니다 (collar-agents-sync exit 2)"
t_assert_eq "exit 2 → 에이전트는 정상 실행" "resume --last $SAFE" "$(_last_args codex "$S")"
n_sync="$(grep -c . "$FAKE_SYNC_LOG")"
nosync_path=()
for e in "${path[@]}"; do [[ -x "$e/collar-agents-sync" ]] || nosync_path+=("$e"); done
PATH="${(j.:.)nosync_path}" _launch_pty "$S" codex
t_assert_eq "PATH에 없음 → 호출 없음" "$n_sync" "$(grep -c . "$FAKE_SYNC_LOG")"
t_assert_not_contains "PATH에 없음 → 경고 없음" "$(cat "$T_LAST_LOG")" "collar"
t_assert_eq "PATH에 없음 → 에이전트는 정상 실행" "resume --last $SAFE" "$(_last_args codex "$S")"

# ── G4 ────────────────────────────────────────────────
t_scenario G4 "권한 프로파일 env · 배너"
C="$T_ROOT/c1"
mkdir -p "$C"
CMUX_CODEX_PERM=auto _launch_pty "$C" codex
t_assert_eq "CMUX_CODEX_PERM=auto → bypass" "resume --last $BYPASS" "$(_last_args codex "$C")"
t_assert_contains "배너: codex 이어서 (이력 없음 안내)" "$(cat "$T_LAST_LOG")" "▶ Codex: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"
CMUX_CODEX_PERM=yolo _launch_pty "$C" codex
t_assert_contains "잘못된 값 → 경고" "$(cat "$T_LAST_LOG")" "CMUX_CODEX_PERM='yolo' — auto|safe 가 아니라 기본값(safe)을 씁니다"
t_assert_eq "잘못된 값 → safe" "resume --last $SAFE" "$(_last_args codex "$C")"
CMUX_OPENCODE_PERM=safe _launch_pty "$C" opencode
t_assert_eq "opencode safe도 권한 플래그 없음" "" "$(_last_args opencode "$C")"
t_assert_contains "배너: opencode 새로 시작" "$(cat "$T_LAST_LOG")" "▶ OpenCode: 새로 시작"

t_finish
exit $?
