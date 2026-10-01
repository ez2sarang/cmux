#!/usr/bin/env zsh
# t04_mixed_restore — claude·codex·opencode 혼재 탭 열기 → 기록 → 재시작·재부팅 복원 (R1, 설계 §4·§7)
#   M1 구포맷(경로만) session-tabs로 시작 → 무인자 cmux 복원 (claude)
#   M2 cmux -a codex <beta> — 살아 있는 세션에 attach 후 탭 추가, cmux-tab-codex.kdl, 기록 TAB 줄 + .bak
#   M3 cmux -a opencode <gamma> — 이력 없음 → 새로 시작
#   M4 cmux -a codex <alpha> — 같은 프로젝트에 claude·codex 2탭
#   M5 밖에서 cmux -k → 혼재 4탭 재생성: 탭 이름·pane 이름·에이전트별 argv·배너
#   M6 cmux kill → 기록 보존 → 무인자 cmux 복원
#   M6b 세션 안(ZELLIJ 경로)에서 cmux -a opencode <delta> — 터미널 pane에 입력
#   M7 구버전(a1a07e9) 롤백 — 혼재 기록에서 claude 탭만 복원 (비-claude 탭만 빠짐)
#   M8 구버전 롤백 — 새 버전이 쓴 claude 전용 기록을 그대로 복원
#   M9 비-claude 탭 닫기 → kill 동기화가 기록에서 뺀다 (탭 이름 `·` 접미사 파싱)
# 이력: alpha=claude 대화형 세션, beta=codex 대화형 롤아웃, gamma=opencode 세션(M5부터 목록에 나타남)

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

# 실제 ~/.codex를 읽지 않게 / opencode 세션 목록은 가짜 (fake-opencode --pure session list → 이 파일 내용)
export CODEX_HOME="$T_ROOT/codex-home"
export FAKE_OPENCODE_LIST="$T_ROOT/oclist.json"
print -r -- '[]' > "$FAKE_OPENCODE_LIST"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

T=$'\t'
ALPHA="$CMUX_ROOT/alpha" BETA="$CMUX_ROOT/beta" GAMMA="$CMUX_ROOT/gamma" DELTA="$CMUX_ROOT/delta"
mkdir -p "$ALPHA" "$BETA" "$GAMMA" "$DELTA"
PERM="--dangerously-skip-permissions"
SAFE="-a never -s workspace-write"
TODAY="$(strftime '%Y%m%d' $EPOCHSECONDS)"

# ── 픽스처 ────────────────────────────────────────────
_transcript() {  # <프로젝트 경로> <이름> <entrypoint> — claude 트랜스크립트
  local d="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"
  mkdir -p "$d"
  print -r -l -- '{"type":"queue-operation","operation":"enqueue"}' "{\"type\":\"user\",\"entrypoint\":\"$3\",\"cwd\":\"$1\"}" > "$d/$2.jsonl"
}
_codex_rollout() {  # <cwd> <이름> — 대화형(cli) codex 세션
  local f="$CODEX_HOME/sessions/2026/10/01/rollout-$2.jsonl"
  mkdir -p "${f:h}"
  print -r -- "{\"timestamp\":\"t\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$2\",\"cwd\":\"$1\",\"originator\":\"codex-tui\",\"source\":\"cli\"}}" > "$f"
}
_transcript "$ALPHA" a cli
_codex_rollout "$BETA" r1

# ── zellij 조회 (harness.zsh 머리말 #5632 규칙: t_zj_gate 뒤에만) ──
# 에이전트 pane: "탭<TAB>pane 이름<TAB>exited<TAB>exit_status<TAB>pane id"
_panes() {
  _t_guard 2>/dev/null || return 1
  t_zj_gate
  zellij -s "$T_SESSION" action list-panes -a -j 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and p.get("title") in ("claude", "codex", "opencode"):
        print("\t".join(str(p.get(k)) for k in ("tab_name", "title", "exited", "exit_status", "id")))'
}
_pane_map() { _panes | awk -F'\t' '{print $1 "=" $2}' | LC_ALL=C sort; }
_term_pane() {  # <탭 이름> — 그 탭 터미널 pane id
  _t_guard 2>/dev/null || return 1
  t_zj_gate
  zellij -s "$T_SESSION" action list-panes -a -j 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and p.get("title") == "terminal" and p.get("tab_name") == sys.argv[1]:
        print("terminal_%s" % p.get("id"))' "$1"
}
_screen() {  # <탭 이름> — 그 탭 에이전트 pane 화면
  local id
  id="$(_panes | awk -F'\t' -v t="$1" '$1==t {print "terminal_" $5}')"
  [[ -n "$id" ]] || return 1
  _t_guard && t_zj_gate && zellij -s "$T_SESSION" action dump-screen -p "$id" --path "$T_ROOT/screen.txt" 2>/dev/null \
    && cat "$T_ROOT/screen.txt"
}
_assert_eventually() {  # <설명> <기대> <조회 명령(eval)> [초=10]
  local _ae_want="$2" _ae_cmd="$3" _ae_got=""
  t_wait_for '_ae_got="$(eval "$_ae_cmd")"; [[ "$_ae_got" == "$_ae_want" ]]' "${4:-10}"
  t_assert_eq "$1" "$_ae_want" "$_ae_got"
}
_assert_banner() {  # <설명> <탭 이름> <배너 부분 문자열>  (eval 문자열 안에서는 위치 인자 대신 지역 변수)
  local _ab_tab="$2" _ab_want="$3" _ab_scr=""
  t_wait_for '_ab_scr="$(_screen "$_ab_tab")"; [[ "$_ab_scr" == *"$_ab_want"* ]]' 10
  t_assert_contains "$1" "$_ab_scr" "$_ab_want"
}
_launches() {  # 4탭 실행 횟수 "claude@alpha codex@beta opencode@gamma codex@alpha"
  print -r -- "$(t_agent_launches claude "$ALPHA") $(t_agent_launches codex "$BETA") $(t_agent_launches opencode "$GAMMA") $(t_agent_launches codex "$ALPHA")"
}
_close_client() {
  t_hup
  t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
}
# _add_tab <cmux 인자...> — 살아 있는 세션에 새 창으로 탭 추가 (백그라운드 탭 추가가 끝날 때까지)
_add_tab() {
  local -a _at_args=("$@")
  _close_client
  t_cmux_bg 120 "$@"
  t_assert_true "탭 추가 백그라운드 작업 종료" '(( $(t_cmux_procs "${_at_args[@]}") == 1 ))' 20
}

NAMES4=$'alpha\nbeta·codex\ngamma·opencode\nalpha·codex'
TABS4="$ALPHA"$'\n'"$BETA${T}codex"$'\n'"$GAMMA${T}opencode"$'\n'"$ALPHA${T}codex"
MAP4="$(print -r -l -- "alpha=claude" "beta·codex=codex" "gamma·opencode=opencode" "alpha·codex=codex" | LC_ALL=C sort)"

# ── M1 ────────────────────────────────────────────────
t_scenario M1 "구포맷 session-tabs로 시작 → 무인자 cmux 복원"
print -r -l -- "$ALPHA" "" "$CMUX_ROOT/ghost" > "$CMUX_TABS_FILE"
t_cmux_bg 120
t_assert_true "alpha claude 실행" '(( $(t_agent_launches claude "$ALPHA") == 1 ))' 30
_assert_eventually "탭 = alpha" "alpha" t_tab_names 20
t_assert_eq "alpha: --continue" "$PERM --continue" "$(t_agent_args claude "$ALPHA")"
t_assert_eq "session-tabs 재기록 = 경로만 (구포맷 그대로)" "$ALPHA" "$(t_tabs_file)"
t_assert_eq "project-agents = alpha claude" "$ALPHA${T}claude" "$(cat "$CMUX_PROJECT_AGENTS_FILE" 2>/dev/null)"
t_assert_true "claude만 → .bak 없음" '[[ -z "$(print -l -- "$CMUX_TABS_FILE".bak-*(N))" ]]'
TABS_BEFORE="$(t_tabs_file)"

# ── M2 ────────────────────────────────────────────────
t_scenario M2 "cmux -a codex <beta> — attach 후 탭 추가"
_add_tab -a codex "$BETA"
_assert_eventually "탭 = alpha, beta·codex" $'alpha\nbeta·codex' t_tab_names 20
t_assert_true "beta codex 실행" '(( $(t_agent_launches codex "$BETA") == 1 ))' 20
t_assert_eq "codex: resume --last + 권한 safe" "resume --last $SAFE" "$(t_agent_args codex "$BETA")"
t_assert_eq "session-tabs = alpha, beta<TAB>codex" "$ALPHA"$'\n'"$BETA${T}codex" "$(t_tabs_file)"
t_assert_eq ".bak-<오늘> = 직전 구포맷 기록" "$TABS_BEFORE" "$(cat "$CMUX_TABS_FILE.bak-$TODAY" 2>/dev/null)"
t_assert_true "cmux-tab-codex.kdl 생성 (codex launch 인자)" \
  'grep -qF "args \"launch\" \"--agent\" \"codex\"" "$CMUX_LAYOUTS_DIR/cmux-tab-codex.kdl"'
t_assert_eq "alpha claude 재실행 없음" 1 "$(t_agent_launches claude "$ALPHA")"
_assert_banner "pane 배너: codex 이어서" "beta·codex" "▶ Codex: 이전 대화 이어서 시작 ["

# ── M3 ────────────────────────────────────────────────
t_scenario M3 "cmux -a opencode <gamma> — 이력 없음 → 새로 시작"
_add_tab -a opencode "$GAMMA"
_assert_eventually "탭 3개" $'alpha\nbeta·codex\ngamma·opencode' t_tab_names 20
t_assert_true "gamma opencode 실행" '(( $(t_agent_launches opencode "$GAMMA") == 1 ))' 20
t_assert_eq "opencode 이력 없음 → 플래그 없음" "" "$(t_agent_args opencode "$GAMMA")"
_assert_banner "pane 배너: opencode 새로 시작" "gamma·opencode" "▶ OpenCode: 새로 시작"

# ── M4 ────────────────────────────────────────────────
t_scenario M4 "cmux -a codex <alpha> — 같은 프로젝트 claude·codex 2탭"
_add_tab -a codex "$ALPHA"
_assert_eventually "탭 4개 (이름·순서)" "$NAMES4" t_tab_names 20
t_assert_true "alpha codex 실행" '(( $(t_agent_launches codex "$ALPHA") == 1 ))' 20
t_assert_eq "alpha codex: resume --last + safe" "resume --last $SAFE" "$(t_agent_args codex "$ALPHA")"
t_assert_eq "session-tabs: claude 평문 + 나머지 TAB (4줄)" "$TABS4" "$(t_tabs_file)"
t_assert_eq "에이전트 프로세스 4개" 4 "$(t_agent_procs)"
_assert_eventually "탭별 에이전트 pane 이름" "$MAP4" _pane_map
t_assert_eq "project-agents (경로별 마지막 사용)" \
  "$ALPHA${T}codex"$'\n'"$BETA${T}codex"$'\n'"$GAMMA${T}opencode" "$(LC_ALL=C sort "$CMUX_PROJECT_AGENTS_FILE")"
t_assert_eq ".bak은 그대로 (1회)" "$TABS_BEFORE|1" "$(cat "$CMUX_TABS_FILE.bak-$TODAY")|$(print -l -- "$CMUX_TABS_FILE".bak-*(N) | grep -c .)"

# ── M5 ────────────────────────────────────────────────
t_scenario M5 "밖에서 cmux -k → 혼재 4탭 재생성"
# gamma의 opencode 세션이 생겼다고 가정 — 재시작 뒤에는 -s <id>로 이어간다
print -r -- "[{\"id\":\"ses_g\",\"title\":\"t\",\"directory\":\"$GAMMA\",\"projectId\":\"p\",\"created\":1,\"updated\":1790000000000}]" > "$FAKE_OPENCODE_LIST"
_close_client
t_cmux_bg 120 -k
t_assert_true "4탭 모두 재실행 (각 2회째)" '[[ "$(_launches)" == "2 2 2 2" ]]' 30
_assert_eventually "탭 4개 복원 (이름·순서)" "$NAMES4" t_tab_names 20
t_assert_true "이전 세션 에이전트 종료 (실행 중 4개)" '(( $(t_agent_procs) == 4 ))' 10
t_assert_eq "session-tabs 그대로 (동기화 후)" "$TABS4" "$(t_tabs_file)"
t_assert_eq "claude@alpha: --continue" "$PERM --continue" "$(t_agent_args claude "$ALPHA" | tail -1)"
t_assert_eq "codex@beta: resume --last + safe" "resume --last $SAFE" "$(t_agent_args codex "$BETA" | tail -1)"
t_assert_eq "opencode@gamma: -s <id>" "-s ses_g" "$(t_agent_args opencode "$GAMMA" | tail -1)"
t_assert_eq "codex@alpha: resume --last + safe" "resume --last $SAFE" "$(t_agent_args codex "$ALPHA" | tail -1)"
_assert_eventually "탭별 에이전트 pane 이름" "$MAP4" _pane_map
_assert_banner "배너: claude 이어서" "alpha" "▶ Claude Code: 이전 대화 이어서 시작 ["
_assert_banner "배너: codex 이어서 (롤아웃 시각)" "beta·codex" "▶ Codex: 이전 대화 이어서 시작 ["
_assert_banner "배너: opencode 이어서 [id]" "gamma·opencode" "▶ OpenCode: 이전 대화 이어서 시작 [ses_g]"
_assert_banner "배너: codex 이력 없음 안내" "alpha·codex" "▶ Codex: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"
t_assert_contains "복원 안내문" "$(cat "$T_LAST_LOG")" "이전 세션 복원: 4개 탭 (에이전트 대화 이어서)"
t_assert_eq "-k 터미널이 새 클라이언트" 1 "$(t_client_count)"

# ── M6 ────────────────────────────────────────────────
t_scenario M6 "cmux kill → 기록 보존 → 무인자 cmux 복원"
_close_client
t_cmux 30 kill
t_assert_eq "cmux kill 종료코드 0" "0" "$T_LAST_RC"
t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
t_assert_eq "session-tabs 보존" "$TABS4" "$(t_tabs_file)"
t_cmux_bg 120
t_assert_true "4탭 모두 재실행 (각 3회째)" '[[ "$(_launches)" == "3 3 3 3" ]]' 30
_assert_eventually "탭 4개 복원" "$NAMES4" t_tab_names 20
t_assert_eq "claude@alpha: --continue" "$PERM --continue" "$(t_agent_args claude "$ALPHA" | tail -1)"
t_assert_eq "codex@beta" "resume --last $SAFE" "$(t_agent_args codex "$BETA" | tail -1)"
t_assert_eq "opencode@gamma" "-s ses_g" "$(t_agent_args opencode "$GAMMA" | tail -1)"
t_assert_eq "codex@alpha" "resume --last $SAFE" "$(t_agent_args codex "$ALPHA" | tail -1)"
t_assert_true "picker 미호출" '[[ ! -e "$T_ROOT/picker-calls" ]]'

t_scenario M6b "세션 안에서 cmux -a opencode <delta> (ZELLIJ 경로 — new-tab -l cmux-tab-opencode)"
rm -f -- "$CMUX_LAYOUTS_DIR/cmux-tab-opencode.kdl"
term=""
t_wait_for 'term="$(_term_pane alpha)"; [[ -n "$term" ]]' 10
# pane의 셸은 zellij가 준 ZELLIJ* env를 가진다 → cmux가 'zellij action new-tab'(현재 세션 = 테스트 세션)을 쓴다
_type_inside() {
  _t_guard && t_zj_gate && zellij -s "$T_SESSION" action write-chars -p "$term" \
    "$CMUX_UNDER_TEST -a opencode $DELTA > $T_ROOT/inside.log 2>&1; print done >> $T_ROOT/inside.log"$'\r' 2>/dev/null
}
t_wait_for '_type_inside' 10
t_assert_true "세션 안 cmux 종료" '[[ "$(tail -1 "$T_ROOT/inside.log" 2>/dev/null)" == done ]]' 20
t_assert_true "delta opencode 실행" '(( $(t_agent_launches opencode "$DELTA") == 1 ))' 20
_assert_eventually "탭 5개 (delta·opencode 추가)" "$NAMES4"$'\ndelta·opencode' t_tab_names 20
t_assert_contains "세션 안 출력" "$(cat "$T_ROOT/inside.log" 2>/dev/null)" "프로젝트 열기: delta·opencode"
t_assert_eq "session-tabs 뒤에 delta<TAB>opencode" "$TABS4"$'\n'"$DELTA${T}opencode" "$(t_tabs_file)"
t_assert_true "cmux-tab-opencode.kdl 생성" 'grep -qF "args \"launch\" \"--agent\" \"opencode\"" "$CMUX_LAYOUTS_DIR/cmux-tab-opencode.kdl"'
t_assert_eq "기존 4탭 재실행 없음" "3 3 3 3" "$(_launches)"


# ── M7 ────────────────────────────────────────────────
OLD_REV="${T_OLD_REV:-a1a07e9}"
OLD="$T_ROOT/old/cmux"
mkdir -p "${OLD:h}"
if git -C "$T_REPO" show "$OLD_REV:bin/cmux" > "$OLD" 2>/dev/null \
   && git -C "$T_REPO" show "$OLD_REV:bin/cmux-agents.zsh" > "${OLD:h}/cmux-agents.zsh" 2>/dev/null; then
  chmod +x "$OLD"
  t_scenario M7 "구버전($OLD_REV) 롤백 — 혼재 기록에서 claude 탭만 복원"
  _close_client
  t_cmux 30 kill
  t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
  CMUX_UNDER_TEST="$OLD" t_cmux_bg 120
  t_assert_true "alpha claude 실행 (4회째)" '(( $(t_agent_launches claude "$ALPHA") == 4 ))' 30
  _assert_eventually "탭 = alpha (비-claude 탭만 빠짐)" "alpha" t_tab_names 20
  t_assert_eq "비-claude 에이전트 실행 없음" "4 3 3 3" "$(_launches)"
  t_assert_eq "구버전 claude: --continue" "$PERM --continue" "$(t_agent_args claude "$ALPHA" | tail -1)"
  t_assert_eq "구버전이 다시 쓴 기록 = claude 줄만 (TAB 줄은 구버전이 버림 — 알려진 손실)" "$ALPHA" "$(t_tabs_file)"
  t_assert_eq ".bak은 보존" "$TABS_BEFORE" "$(cat "$CMUX_TABS_FILE.bak-$TODAY")"

  t_scenario M8 "구버전 롤백 — 새 버전이 쓴 claude 전용 기록"
  _close_client
  t_cmux 30 kill
  t_assert_true "세션 없음" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
  t_cmux_bg 120 "$BETA"
  t_assert_true "beta claude 실행" '(( $(t_agent_launches claude "$BETA") == 1 ))' 30
  _assert_eventually "탭 = alpha, beta" $'alpha\nbeta' t_tab_names 20
  t_assert_eq "새 버전 기록 (claude 전용) = 경로만, TAB 없음" "$ALPHA"$'\n'"$BETA|0" "$(t_tabs_file)|$(grep -c $'\t' "$CMUX_TABS_FILE")"
  _close_client
  t_cmux 30 kill
  t_assert_true "세션 없음" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
  CMUX_UNDER_TEST="$OLD" t_cmux_bg 120
  t_assert_true "구버전: alpha·beta claude 실행" \
    '(( $(t_agent_launches claude "$ALPHA") == 6 && $(t_agent_launches claude "$BETA") == 2 ))' 30
  _assert_eventually "구버전이 같은 탭 복원 (alpha, beta)" $'alpha\nbeta' t_tab_names 20
  t_assert_eq "기록 그대로" "$ALPHA"$'\n'"$BETA" "$(t_tabs_file)"
else
  t_scenario M7 "구버전 롤백"
  t_skip "git show $OLD_REV 실패 — 롤백 실험 생략"
fi

# ── M9 ────────────────────────────────────────────────
t_scenario M9 "비-claude 탭 닫기 → kill 동기화가 기록에서 뺀다 (탭 이름 · 접미사 파싱)"
_close_client
t_cmux 30 kill
t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
N9_OPEN=$'alpha\nbeta·codex\ngamma·opencode\nalpha·codex'
N9_LEFT=$'alpha\nbeta·codex\nalpha·codex'
_close_gamma() {
  _t_guard && t_zj_gate && zellij -s "$T_SESSION" action go-to-tab-name "gamma·opencode" 2>/dev/null \
    && zellij -s "$T_SESSION" action close-tab 2>/dev/null
}
# _m9_try — 혼재 4탭 복원 → gamma·opencode 닫기 → 창 닫기 → cmux kill. 동기화가 기록을 썼으면 0.
#   기록 mtime을 2020년으로 돌려 두고 kill 뒤에도 그대로면 = 동기화가 쓰지 않음(1).
#   _tabs_sync_live는 zellij 조회(list-sessions/query-tab-names)가 실패하면 조용히 넘어간다(기존 동작, 견고화는 P2-C) —
#   전체 실행 중 드물게(실측 1/27) 일어나 그때만 1회 다시 시도한다. 동기화가 아예 안 도는 회귀는 두 번 다 실패한다.
_m9_try() {
  print -r -l -- "$ALPHA" "$BETA${T}codex" "$GAMMA${T}opencode" "$ALPHA${T}codex" > "$CMUX_TABS_FILE"
  t_cmux_bg 120
  t_assert_true "혼재 4탭 복원" '[[ "$(t_tab_names)" == "$N9_OPEN" ]]' 20
  t_wait_for '_close_gamma' 10
  t_assert_true "gamma·opencode 탭 닫힘" '[[ "$(t_tab_names)" == "$N9_LEFT" ]]' 10
  _close_client
  touch -t 202001010000 "$CMUX_TABS_FILE"
  t_cmux 30 kill
  t_wait_for 't_session_gone && (( $(t_agent_procs) == 0 ))' 10
  [[ "$(stat -f %Sm -t %Y "$CMUX_TABS_FILE")" != 2020 ]]
}
if ! _m9_try; then
  print -r -- "  진단: kill의 탭 동기화가 기록을 쓰지 않음 (zellij 조회 실패 추정 — P2-C 범위) — 1회 다시 시도"
  _m9_try
fi
t_assert_eq "기록 = 실제 탭 (닫은 gamma·opencode 제외, 에이전트 유지)" \
  "$ALPHA"$'\n'"$BETA${T}codex"$'\n'"$ALPHA${T}codex" "$(t_tabs_file)"
t_assert_not_contains "모든 탭 매핑 → 병합 경고 없음" "$(cat "$T_LAST_LOG")" "경로를 알 수 없는 탭"

t_finish
exit $?
