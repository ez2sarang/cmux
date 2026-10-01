#!/usr/bin/env zsh
# t05_pick_flow — cmux pick ↔ picker 프로토콜 (R2, 설계 §10): 스텁 picker가 받은 env를 기록하고 정해진 줄을 낸다
#   P1 세션 없음 — `경로` + `경로<TAB>codex` → 새 구성(이전 기록 대체), 각 탭 에이전트, env 3종 + CMUX_ROOT
#   P2 세션 살아 있음 — 미설치 에이전트(opencode) env 제외, 미등록 에이전트 줄 → 경고 후 default, attach 후 탭 추가
#   P3 설정 default=codex — env DEFAULT=codex, `경로`만 = codex
#   P4 취소(빈 출력, exit 0) → 탭·기록 변화 없음 · picker 실패(exit 3, 빈 출력) → exit 1 안내

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

export CODEX_HOME="$T_ROOT/codex-home"
export FAKE_OPENCODE_LIST="$T_ROOT/oclist.json"
print -r -- '[]' > "$FAKE_OPENCODE_LIST"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

T=$'\t'
ALPHA="$CMUX_ROOT/alpha" BETA="$CMUX_ROOT/beta" GAMMA="$CMUX_ROOT/gamma" DELTA="$CMUX_ROOT/delta"
mkdir -p "$ALPHA" "$BETA" "$GAMMA" "$DELTA"
PERM="--dangerously-skip-permissions"
SAFE="-a never -s workspace-write"

# 스텁 picker — 받은 env 한 줄을 picker-env에 덧붙이고 picker-out 내용을 출력, exit ${STUB_RC:-0}
PICKER_ENV="$T_ROOT/picker-env" PICKER_OUT="$T_ROOT/picker-out"
cat > "$T_ROOT/bin/stub-picker" <<SH
#!/bin/sh
printf 'AGENTS=%s|DEFAULT=%s|PREFS=%s|ROOT=%s\n' "\$CMUX_PICKER_AGENTS" "\$CMUX_PICKER_DEFAULT_AGENT" "\$CMUX_PICKER_PREFS_FILE" "\$CMUX_ROOT" >> "$PICKER_ENV"
cat "$PICKER_OUT" 2>/dev/null
exit \${STUB_RC:-0}
SH
chmod +x "$T_ROOT/bin/stub-picker"
export CMUX_PICKER_BIN="$T_ROOT/bin/stub-picker"

_assert_eventually() {  # <설명> <기대> <조회 명령(eval)> [초=10]
  local _ae_want="$2" _ae_cmd="$3" _ae_got=""
  t_wait_for '_ae_got="$(eval "$_ae_cmd")"; [[ "$_ae_got" == "$_ae_want" ]]' "${4:-10}"
  t_assert_eq "$1" "$_ae_want" "$_ae_got"
}
_close_client() {
  t_hup
  t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
}
_last_env() { tail -1 "$PICKER_ENV" 2>/dev/null; }

# ── P1 ────────────────────────────────────────────────
t_scenario P1 "세션 없음 — 경로 + 경로<TAB>codex → 새 구성"
print -r -- "$GAMMA" > "$CMUX_TABS_FILE"          # 이전 기록 — picker로 고른 구성이 대체해야 한다
print -r -l -- "$ALPHA" "$BETA${T}codex" > "$PICKER_OUT"
t_cmux_bg 120 pick
t_assert_true "alpha claude·beta codex 실행" \
  '(( $(t_agent_launches claude "$ALPHA") == 1 && $(t_agent_launches codex "$BETA") == 1 ))' 30
_assert_eventually "탭 = alpha, beta·codex" $'alpha\nbeta·codex' t_tab_names 20
t_assert_eq "picker env: 등록·설치 에이전트, default claude, 기억 파일, CMUX_ROOT" \
  "AGENTS=claude codex opencode|DEFAULT=claude|PREFS=$CMUX_PROJECT_AGENTS_FILE|ROOT=$CMUX_ROOT" "$(_last_env)"
t_assert_eq "picker 1회 호출" 1 "$(grep -c . "$PICKER_ENV")"
t_assert_eq "alpha: claude (이력 없음)" "$PERM" "$(t_agent_args claude "$ALPHA")"
t_assert_eq "beta: codex resume --last + safe" "resume --last $SAFE" "$(t_agent_args codex "$BETA")"
t_assert_eq "beta에 claude 실행 없음" 0 "$(t_agent_launches claude "$BETA")"
t_assert_eq "session-tabs = 새 구성 (이전 gamma 대체)" "$ALPHA"$'\n'"$BETA${T}codex" "$(t_tabs_file)"
t_assert_eq "project-agents" "$ALPHA${T}claude"$'\n'"$BETA${T}codex" "$(cat "$CMUX_PROJECT_AGENTS_FILE" 2>/dev/null)"
t_assert_eq "gamma 실행 없음" 0 "$(t_agent_launches claude "$GAMMA")"

# ── P2 ────────────────────────────────────────────────
t_scenario P2 "세션 살아 있음 — 미설치 에이전트 제외, 미등록 에이전트 줄 → default"
_close_client
print -r -- "$GAMMA${T}bogus" > "$PICKER_OUT"
CMUX_OPENCODE_BIN="$T_ROOT/bin/no-such-opencode" t_cmux_bg 120 pick
t_assert_true "gamma claude 실행 (default)" '(( $(t_agent_launches claude "$GAMMA") == 1 ))' 20
_assert_eventually "탭 = alpha, beta·codex, gamma" $'alpha\nbeta·codex\ngamma' t_tab_names 20
t_assert_true "탭 추가 백그라운드 작업 종료" '(( $(t_cmux_procs pick) == 1 ))' 20
t_assert_eq "미설치 opencode는 picker env에서 제외" "AGENTS=claude codex|DEFAULT=claude" "$(_last_env | cut -d'|' -f1-2)"
t_assert_contains "미등록 에이전트 → 경고 1줄" "$(cat "$T_LAST_LOG")" "알 수 없는 에이전트 'bogus' — 기본 에이전트(claude)로 엽니다: gamma"
t_assert_eq "session-tabs 뒤에 gamma (claude 평문)" "$ALPHA"$'\n'"$BETA${T}codex"$'\n'"$GAMMA" "$(t_tabs_file)"
t_assert_eq "기존 탭 재실행 없음" "1 1" "$(t_agent_launches claude "$ALPHA") $(t_agent_launches codex "$BETA")"

# ── P3 ────────────────────────────────────────────────
t_scenario P3 "설정 default=codex — env DEFAULT=codex, 경로만 줄 = codex"
_close_client
print -r -- "CMUX_DEFAULT_AGENT=codex" > "$CMUX_CONFIG_FILE"
print -r -- "$DELTA" > "$PICKER_OUT"
t_cmux_bg 120 pick
t_assert_true "delta codex 실행" '(( $(t_agent_launches codex "$DELTA") == 1 ))' 20
_assert_eventually "탭 = …, delta·codex" $'alpha\nbeta·codex\ngamma\ndelta·codex' t_tab_names 20
t_assert_true "탭 추가 백그라운드 작업 종료" '(( $(t_cmux_procs pick) == 1 ))' 20
t_assert_eq "picker env DEFAULT=codex" "AGENTS=claude codex opencode|DEFAULT=codex" "$(_last_env | cut -d'|' -f1-2)"
t_assert_eq "delta: codex resume --last + safe" "resume --last $SAFE" "$(t_agent_args codex "$DELTA")"
t_assert_eq "delta에 claude 실행 없음" 0 "$(t_agent_launches claude "$DELTA")"
t_assert_eq "session-tabs 뒤에 delta<TAB>codex" "$ALPHA"$'\n'"$BETA${T}codex"$'\n'"$GAMMA"$'\n'"$DELTA${T}codex" "$(t_tabs_file)"
rm -f -- "$CMUX_CONFIG_FILE"

# ── P4 ────────────────────────────────────────────────
t_scenario P4 "취소·실패 — 탭·기록 변화 없음"
TABS_NOW="$(t_tabs_file)"
: > "$PICKER_OUT"
n_env="$(grep -c . "$PICKER_ENV")"
t_cmux 30 pick
t_assert_eq "취소 → exit 0" "0" "$T_LAST_RC"
t_assert_contains "취소 → '취소됨'" "$(cat "$T_LAST_LOG")" "취소됨"
t_assert_eq "picker 호출됨" $(( n_env + 1 )) "$(grep -c . "$PICKER_ENV")"
STUB_RC=3 t_cmux 30 pick
t_assert_eq "picker 실패(exit 3, 빈 출력) → exit 1" "1" "$T_LAST_RC"
t_assert_contains "실패 안내" "$(cat "$T_LAST_LOG")" "프로젝트 선택기 실행 실패 (exit 3)"
_assert_eventually "탭 그대로" $'alpha\nbeta·codex\ngamma\ndelta·codex' t_tab_names 10
t_assert_eq "session-tabs 그대로" "$TABS_NOW" "$(t_tabs_file)"
t_assert_eq "에이전트 4개 그대로 실행 중" 4 "$(t_agent_procs)"
t_hup

t_finish
exit $?
