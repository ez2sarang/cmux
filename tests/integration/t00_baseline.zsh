#!/usr/bin/env zsh
# t00_baseline — 현행 bin/cmux 동작 특성화(기준선). 이후 리팩터가 이 동작을 깨지 않았음을 증명한다.
#   B1 cmux <alpha> cold start
#   B2 터미널 닫기(HUP) 후 서버 생존 → cmux <beta>가 살아있는 세션에 attach 후 탭 추가
#   B3 밖에서 cmux -k → 세션 재생성, 같은 탭 복원, 각 탭 launch 재실행
#   B4 cmux kill → 세션 없음·기록 보존 → 무인자 cmux가 복원
#   B5 구포맷(경로만) session-tabs 읽기
# 탭 추가는 항상 cmux의 실제 경로(클라이언트가 붙은 뒤 new-tab)를 탄다 — zellij 0.45.1은
# 클라이언트 없는 세션의 new-tab을 조용히 버린다.

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

ALPHA="$CMUX_ROOT/alpha"
BETA="$CMUX_ROOT/beta"
mkdir -p "$ALPHA" "$BETA"
# alpha에만 Claude 대화 이력 — cmux launch는 projects/<cwd 치환 키>/*.jsonl 존재로 --continue를 붙인다
mkdir -p "$CLAUDE_CONFIG_DIR/projects/${ALPHA//[^A-Za-z0-9]/-}"
print -r -- '{}' > "$CLAUDE_CONFIG_DIR/projects/${ALPHA//[^A-Za-z0-9]/-}/x.jsonl"

NAMES_AB=$'alpha\nbeta'
TABS_AB="$ALPHA"$'\n'"$BETA"

# ── B1 ────────────────────────────────────────────────
t_scenario B1 "cmux <alpha> cold start"
t_cmux_bg 120 "$ALPHA"
t_assert_true "세션 생성" 't_session_alive' 20
t_assert_true "alpha에서 fake-claude 실행" '(( $(t_agent_launches claude "$ALPHA") >= 1 ))' 20
t_assert_eq "탭 = alpha" "alpha" "$(t_tab_names)"
args="$(t_agent_args claude "$ALPHA" | tail -1)"
t_assert_contains "alpha: --dangerously-skip-permissions" "$args" "--dangerously-skip-permissions"
t_assert_contains "alpha(jsonl 이력 있음): --continue" "$args" "--continue"
t_assert_eq "session-tabs = alpha 경로" "$ALPHA" "$(t_tabs_file)"
t_assert_eq "alpha launch 1회" 1 "$(t_agent_launches claude "$ALPHA")"

# ── B2 ────────────────────────────────────────────────
t_scenario B2 "HUP 후 서버 생존 → cmux <beta> 탭 추가"
t_hup
t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
t_assert_true "서버 생존" 't_session_alive'
t_assert_eq "탭 유지 (alpha)" "alpha" "$(t_tab_names)"
t_assert_eq "alpha 에이전트 프로세스 생존" 1 "$(t_agent_procs)"
t_cmux_bg 120 "$BETA"
t_assert_true "탭 2개 (alpha, beta 순)" '[[ "$(t_tab_names)" == "$NAMES_AB" ]]' 20
t_assert_true "beta에서 fake-claude 실행" '(( $(t_agent_launches claude "$BETA") >= 1 ))' 20
t_assert_true "탭 추가 백그라운드 작업 종료" '(( $(t_cmux_procs "$BETA") == 1 ))' 10
args="$(t_agent_args claude "$BETA" | tail -1)"
t_assert_contains "beta: --dangerously-skip-permissions" "$args" "--dangerously-skip-permissions"
t_assert_not_contains "beta(이력 없음): --continue 없음" "$args" "--continue"
t_assert_eq "session-tabs = alpha, beta" "$TABS_AB" "$(t_tabs_file)"
t_assert_eq "attach는 alpha를 재실행하지 않음" 1 "$(t_agent_launches claude "$ALPHA")"
t_assert_eq "클라이언트 1개" 1 "$(t_client_count)"

# ── B3 ────────────────────────────────────────────────
t_scenario B3 "밖에서 cmux -k → 재생성·복원·launch 재실행"
t_hup
t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
t_cmux_bg 120 -k
t_assert_true "alpha launch 재실행 (2회째)" '(( $(t_agent_launches claude "$ALPHA") == 2 ))' 30
t_assert_true "beta launch 재실행 (2회째)" '(( $(t_agent_launches claude "$BETA") == 2 ))' 30
t_assert_true "탭 2개 복원 (alpha, beta 순)" '[[ "$(t_tab_names)" == "$NAMES_AB" ]]' 10
t_assert_true "이전 세션 에이전트 종료 (실행 중 2개)" '(( $(t_agent_procs) == 2 ))' 10
t_assert_contains "alpha: --continue" "$(t_agent_args claude "$ALPHA" | tail -1)" "--continue"
t_assert_not_contains "beta: --continue 없음" "$(t_agent_args claude "$BETA" | tail -1)" "--continue"
t_assert_eq "session-tabs = alpha, beta" "$TABS_AB" "$(t_tabs_file)"
t_assert_eq "-k 터미널이 새 클라이언트" 1 "$(t_client_count)"

# ── B4 ────────────────────────────────────────────────
t_scenario B4 "cmux kill → 기록 보존 → 무인자 cmux 복원"
t_hup
t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
t_cmux 30 kill
t_assert_eq "cmux kill 종료코드 0" "0" "$T_LAST_RC"
# 안내 문구는 검사하지 않는다 — zellij 0.45.1에선 실제로 종료해도 "세션이 없거나 이미 종료됨"이 뜬다 (tests/README.md 발견)
t_assert_true "세션 없음" 't_session_gone' 10
t_assert_true "에이전트 프로세스 0" '(( $(t_agent_procs) == 0 ))' 10
t_assert_eq "session-tabs 보존 (alpha, beta)" "$TABS_AB" "$(t_tabs_file)"
t_cmux_bg 120
t_assert_true "alpha launch 3회째" '(( $(t_agent_launches claude "$ALPHA") == 3 ))' 30
t_assert_true "beta launch 3회째" '(( $(t_agent_launches claude "$BETA") == 3 ))' 30
t_assert_eq "탭 복원 (alpha, beta 순)" "$NAMES_AB" "$(t_tab_names)"
t_assert_contains "alpha: --continue" "$(t_agent_args claude "$ALPHA" | tail -1)" "--continue"
t_assert_not_contains "beta: --continue 없음" "$(t_agent_args claude "$BETA" | tail -1)" "--continue"
t_assert_true "picker 미호출" '[[ ! -e "$T_ROOT/picker-calls" ]]'

# ── B5 ────────────────────────────────────────────────
t_scenario B5 "구포맷(경로만) session-tabs 읽기"
t_hup
t_cmux 30 kill
t_assert_true "세션 없음" 't_session_gone' 10
# 경로만 한 줄씩 + 빈 줄 + 없는 경로 — 기록 순서(beta, alpha)대로 복원돼야 한다
print -r -l -- "$BETA" "" "$CMUX_ROOT/ghost" "$ALPHA" > "$CMUX_TABS_FILE"
t_cmux_bg 120
t_assert_true "beta launch 4회째" '(( $(t_agent_launches claude "$BETA") == 4 ))' 30
t_assert_true "alpha launch 4회째" '(( $(t_agent_launches claude "$ALPHA") == 4 ))' 30
t_assert_eq "기록 순서대로 복원 (beta, alpha) — 빈 줄·없는 경로 건너뜀" $'beta\nalpha' "$(t_tab_names)"
t_assert_eq "session-tabs 재기록 (beta, alpha)" "$BETA"$'\n'"$ALPHA" "$(t_tabs_file)"
t_assert_contains "alpha: --continue" "$(t_agent_args claude "$ALPHA" | tail -1)" "--continue"
t_assert_true "picker 미호출" '[[ ! -e "$T_ROOT/picker-calls" ]]'
t_hup

t_finish
exit $?
