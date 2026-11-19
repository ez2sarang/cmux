# tests/lib/harness.zsh — cmux 통합 테스트 공용 함수. 테스트 스크립트 최상위에서 source 한다.
#
# 안전 규칙
#   - 라이브 세션(T_LIVE_SESSION)은 조회(list-sessions / query-tab-names)만 한다.
#   - zellij 호출은 항상 -s "$T_SESSION"(cmuxt<pid>) 명시. ZELLIJ* env는 source 시점에 제거한다.
#   - cmux 실행 전 _t_guard가 CMUX_SESSION=cmuxt<숫자>를 확인한다 (기본값 'claude'로 새는 것 차단).
#   - 사용자 홈 설정은 쓰지 않는다 — CMUX_TABS_FILE / CMUX_CONFIG_FILE / CMUX_PROJECT_AGENTS_FILE / CMUX_EXTRAS_FILE / CMUX_AGENT_ARGS_FILE /
#     CMUX_AGENT_STATE_DIR / CMUX_LAYOUTS_DIR / CLAUDE_CONFIG_DIR / ZDOTDIR 를 임시 루트(T_ROOT)로 격리(+ CMUX_STATE_HOOKS=0). 예외: zellij가 세션마다 만드는 캐시(session_info/<테스트세션>)는 정리 때 지운다.
#   - zellij 0.45.1 #5632: 새 서버가 첫 클라이언트를 초기화하기 전에 다른 zellij CLI가 소켓에 붙었다 끊으면
#     서버가 panic하고(zellij.log: zellij-server/src/lib.rs:1462) 세션을 만들던 클라이언트는 화면 없이 멈춘다.
#     list-sessions·action …·delete-session 은 모두 소켓을 건드리므로, 새 세션이 생길 수 있는 cmux 실행 뒤에는
#     session-metadata.kdl이 그 뒤에 쓰일 때까지 zellij를 부르지 않고(t_zj_gate), 생존·소멸은 상태
#     (서버 프로세스·소켓·session_info)로 판정하며, 폴링은 0.3초 간격이다. 테스트를 병렬로 돌리지 않는다.
#
# 흐름: t_live_snapshot → t_setup → (t_scenario / t_cmux / t_cmux_bg / t_hup / t_assert_*) → t_finish
# t_finish = t_teardown(테스트 세션·프로세스·임시 루트 정리) → t_live_check → t_summary(실패 시 비0)

zmodload zsh/datetime

# ZELLIJ* 제거 — 라이브 세션 pane 안에서 실행돼도 'zellij action'이 라이브 세션을 겨냥하지 못하게
for _t_v in ${(k)parameters[(I)ZELLIJ*]}; do unset "$_t_v"; done
unset _t_v

# 상태 훅 주입(--settings, bin/cmux의 _state_hook_args)은 시험에서 기본으로 끈다 — claude argv를 정확 비교하는 기존 시험이 그대로 통과하게.
# 상태 배지 시험(unit t07_agent_state · integration t09_state_badge)만 CMUX_STATE_HOOKS=1 로 켠다.
export CMUX_STATE_HOOKS=0
# 에이전트 확장 디렉토리(agents.d)도 실제 ~/.config/cmux/agents.d 가 시험에 새지 않게 존재하지 않는 경로로 — agents.d 시험만 직접 지정한다
export CMUX_AGENTS_D="/nonexistent/cmux-agents.d"

typeset -r T_LIVE_SESSION="claude"   # 라이브 세션 이름 — 조회만, 절대 변경 금지
T_REPO="${${(%):-%x}:A:h:h:h}"
T_PTYRUN="$T_REPO/tests/lib/ptyrun.py"
# 테스트 대상 cmux (뮤테이션 확인 등에서 /tmp 복사본으로 교체 가능)
CMUX_UNDER_TEST="${${CMUX_UNDER_TEST:-$T_REPO/bin/cmux}:A}"

T_TEST_NAME="${T_TEST_NAME:-${${ZSH_ARGZERO:t}%.zsh}}"
T_ROOT="" T_SESSION="" T_SEQ=0 T_LAST_LOG="" T_LAST_RC="" T_CLIENT_PID=""
typeset -ga T_BG_PIDS=()
T_PASS=0 T_FAIL=0 T_SKIP=0
T_SCENARIO="pre"
typeset -ga T_SCENARIOS=(pre)
typeset -gA T_SC_PASS=() T_SC_FAIL=() T_SC_DESC=()
T_TORN_DOWN=0 T_LEFTOVER_COUNT=0
T_LIVE_PRESENT=0 T_LIVE_BEFORE=""
# zellij 상태 경로 (t_setup에서 세션명으로 채운다)
T_ZJ_LOG="${TMPDIR%/}/zellij-$UID/zellij-log/zellij.log"
T_ZJ_SOCK="" T_ZJ_INFO="" T_ZJ_MARK="" T_ZJ_PANIC0=0

trap 't_teardown' EXIT
trap 't_teardown; exit 130' INT TERM HUP

# ── 안전장치 ──────────────────────────────────────────
_t_guard() {
  if [[ "$T_SESSION" != cmuxt<-> || "$CMUX_SESSION" != "$T_SESSION" || "$T_SESSION" == "$T_LIVE_SESSION" ]]; then
    print -u2 -r -- "harness: 안전장치 — 테스트 세션명 이상 (T_SESSION='$T_SESSION' CMUX_SESSION='$CMUX_SESSION')"
    return 1
  fi
  if [[ -n "${(k)parameters[(I)ZELLIJ*]}" ]]; then
    print -u2 -r -- "harness: 안전장치 — ZELLIJ* env 잔존"
    return 1
  fi
  return 0
}

# ── zellij 접촉 규칙 (#5632) ──────────────────────────
_t_server_pids() { pgrep -f "zellij --server .*/${T_SESSION}\$"; }
t_server_up()    { [[ -n "$(_t_server_pids)" && -S "$T_ZJ_SOCK" ]]; }
t_server_gone()  { [[ -z "$(_t_server_pids)" && ! -e "$T_ZJ_SOCK" ]]; }
# 서버 초기화 완료 — 마지막 시작 마크 뒤에 session-metadata.kdl이 쓰였다 (소켓을 건드리지 않는 파일 확인)
t_session_ready() {
  local meta="$T_ZJ_INFO/session-metadata.kdl"
  [[ -e "$meta" ]] && { [[ ! -e "$T_ZJ_MARK" ]] || [[ "$meta" -nt "$T_ZJ_MARK" ]]; }
}
# zellij.log의 서버 초기화 panic(#5632) 누적 건수 — 공유 로그라 다른 프로세스 것도 포함될 수 있다
t_zj_panics() { local n; n=$(grep -c 'zellij-server/src/lib.rs:1462' "$T_ZJ_LOG" 2>/dev/null); print -r -- "${n:-0}"; }

# _t_zj_mark <cmux 인자...> — 이 cmux 실행이 새 세션을 만들 수 있으면 시작 마크를 남긴다
_t_zj_mark() {
  case "$1" in
    kill|-K|--kill|launch|-l|--list-sessions|list|-h|--help|add|rm|remove) return 0 ;;
    -k|--restart|restart) ;;              # 기존 세션을 죽이고 새로 만든다
    *) t_server_up && return 0 ;;         # 살아 있는 세션에 붙는 경우 — 초기화 구간 없음
  esac
  : > "$T_ZJ_MARK"
}

# t_zj_gate — 시작 마크가 있으면 서버 초기화(t_session_ready)까지 파일만 보며 기다린 뒤 마크를 지운다.
#   소켓을 건드리는 zellij 호출 앞에 둔다. 20초 안에 준비되지 않으면 진단 한 줄을 남기고 진행한다.
t_zj_gate() {
  [[ -n "$T_ZJ_MARK" && -e "$T_ZJ_MARK" ]] || return 0
  if ! t_wait_for 't_session_ready' 20; then
    print -r -- "  진단: 세션이 20초 안에 준비되지 않음 — zellij 서버 초기화 panic(lib.rs:1462, #5632) 테스트 시작 뒤 +$(( $(t_zj_panics) - T_ZJ_PANIC0 ))건"
  fi
  rm -f -- "$T_ZJ_MARK"
  return 0
}

# ── 준비 ──────────────────────────────────────────────
t_setup() {
  T_ROOT="$(mktemp -d /tmp/cmuxt.XXXXXX)" || { print -u2 "harness: mktemp 실패"; exit 1; }
  # /tmp → /private/tmp: cmux가 기록하는 realpath·pane PWD와 같은 표기로 통일
  T_ROOT="${T_ROOT:A}"
  T_SESSION="cmuxt$$"
  export CMUX_SESSION="$T_SESSION"
  _t_guard || exit 1
  T_ZJ_SOCK="${TMPDIR%/}/zellij-$UID/contract_version_1/$T_SESSION"
  T_ZJ_INFO="$HOME/Library/Caches/org.Zellij-Contributors.Zellij/contract_version_1/session_info/$T_SESSION"
  T_ZJ_MARK="$T_ROOT/zj-start-mark"
  T_ZJ_PANIC0="$(t_zj_panics)"
  if [[ -n "$(t_session_line)" ]]; then
    print -u2 -r -- "harness: 같은 이름의 이전 테스트 세션 잔존 — 삭제: $T_SESSION"
    zellij delete-session "$T_SESSION" --force >/dev/null 2>&1
  fi

  mkdir -p "$T_ROOT"/{bin,cfg,layouts,claude-config,proj,logs,zdotdir}
  local a
  for a in claude codex opencode kimi gemini; do
    ln -s "$T_REPO/tests/bin/fake-agent" "$T_ROOT/bin/fake-$a"
  done
  # cmux-bar 스텁 — 실제 cmux-bar는 키 입력으로 close-tab/quit을 실행하므로 테스트에서 배제
  print -r -- $'#!/bin/sh\nprintf "[cmux-bar stub]"' > "$T_ROOT/bin/cmux-bar-stub"
  # picker 스텁 — 호출만 기록하고 빈 출력(=취소). 의도치 않은 대화형 picker 대기 방지
  print -r -- $'#!/bin/sh\necho picker >> "'"$T_ROOT"$'/picker-calls"' > "$T_ROOT/bin/cmux-picker-stub"
  chmod +x "$T_ROOT/bin/cmux-bar-stub" "$T_ROOT/bin/cmux-picker-stub"

  # 레이아웃: install.sh와 같은 sed 규칙·순서 (CMUX_BAR_BIN → CMUX_BIN)
  local tmpl
  for tmpl in "$T_REPO"/zellij/layouts/*.kdl.tmpl; do
    sed -e "s|CMUX_BAR_BIN|$T_ROOT/bin/cmux-bar-stub|g" \
        -e "s|CMUX_BIN|$CMUX_UNDER_TEST|g" \
        "$tmpl" > "$T_ROOT/layouts/${${tmpl:t}%.tmpl}"
  done

  export CMUX_ROOT="$T_ROOT/proj"
  export CMUX_TABS_FILE="$T_ROOT/cfg/session-tabs"
  # 사용자 설정·마지막 사용 기억·등록 경로도 임시 루트로 (cmux가 맨 먼저 source하는 설정 파일 포함)
  export CMUX_CONFIG_FILE="$T_ROOT/cfg/config"
  export CMUX_PROJECT_AGENTS_FILE="$T_ROOT/cfg/project-agents"
  export CMUX_EXTRAS_FILE="$T_ROOT/cfg/projects"
  export CMUX_AGENT_ARGS_FILE="$T_ROOT/cfg/agent-args"
  export CMUX_AGENT_STATE_DIR="$T_ROOT/cfg/agent-state"
  unset CMUX_AGENT CMUX_DEFAULT_AGENT
  export CMUX_LAYOUTS_DIR="$T_ROOT/layouts"
  export CMUX_BAR_BIN="$T_ROOT/bin/cmux-bar-stub"
  export CMUX_PICKER_BIN="$T_ROOT/bin/cmux-picker-stub"
  export CLAUDE_CONFIG_DIR="$T_ROOT/claude-config"
  export CMUX_CLAUDE_BIN="$T_ROOT/bin/fake-claude"
  export CMUX_CODEX_BIN="$T_ROOT/bin/fake-codex"
  export CMUX_OPENCODE_BIN="$T_ROOT/bin/fake-opencode"
  export CMUX_KIMI_BIN="$T_ROOT/bin/fake-kimi"
  export CMUX_GEMINI_BIN="$T_ROOT/bin/fake-gemini"
  export FAKE_AGENT_LOG="$T_ROOT/fake-agent.log"
  # 실행별 고유값 — 남은 가짜 에이전트(exec sleep)를 pgrep으로 식별
  export FAKE_AGENT_SLEEP="$(( 900000 + $$ ))"
  # pane의 zsh(-i 포함)가 사용자 ~/.zshrc·history를 읽고 쓰지 않게
  export ZDOTDIR="$T_ROOT/zdotdir"
  : > "$FAKE_AGENT_LOG"
  print -r -- "테스트 세션: $T_SESSION  임시 루트: $T_ROOT  대상: $CMUX_UNDER_TEST"
}

# ── cmux 실행 (pty = 터미널 창) ───────────────────────
_t_newlog() {
  (( T_SEQ++ ))
  local tag="${${1:-noarg}:t}"
  T_LAST_LOG="$T_ROOT/logs/$(printf %02d $T_SEQ)-${tag//[^A-Za-z0-9_-]/_}.log"
}

# ptyrun stderr 마지막 줄 → cmux 종료코드 / "hup"
_t_status_rc() {
  local line
  line="$(grep '^ptyrun:' "$1" 2>/dev/null | tail -1)"
  case "$line" in
    *"exited rc="*) print -r -- "${line##*rc=}" ;;
    *hup*)          print -r -- "hup" ;;
    *)              print -r -- "?" ;;
  esac
}

# t_cmux <초> [인자...] — cmux를 터미널 창에서 실행, 끝나거나 <초>가 지나면 창을 닫는다(HUP).
#   결과: T_LAST_LOG(화면 출력 로그), T_LAST_RC(cmux 종료코드 또는 "hup")
t_cmux() {
  local secs="$1"; shift
  _t_guard || return 99
  _t_newlog "$@"
  _t_zj_mark "$@"
  python3 "$T_PTYRUN" --log "$T_LAST_LOG" --secs "$secs" -- "$CMUX_UNDER_TEST" "$@" 2> "$T_LAST_LOG.status"
  local rc=$?
  T_LAST_RC="$(_t_status_rc "$T_LAST_LOG.status")"
  return $rc
}

# t_cmux_bg <초> [인자...] — 백그라운드 터미널 창(최대 <초>). T_CLIENT_PID에 기록, t_hup으로 닫는다.
t_cmux_bg() {
  local secs="$1"; shift
  _t_guard || return 99
  _t_newlog "$@"
  _t_zj_mark "$@"
  python3 "$T_PTYRUN" --log "$T_LAST_LOG" --secs "$secs" -- "$CMUX_UNDER_TEST" "$@" 2> "$T_LAST_LOG.status" &
  T_CLIENT_PID=$!
  T_BG_PIDS+=($T_CLIENT_PID)
}

# t_hup [pid] — 터미널 창 닫기 (SIGTERM → ptyrun이 master fd를 닫아 SIGHUP 전달). 기본: 마지막 창
t_hup() {
  local pid="${1:-$T_CLIENT_PID}"
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  T_BG_PIDS=("${(@)T_BG_PIDS:#$pid}")
  [[ "$pid" == "$T_CLIENT_PID" ]] && T_CLIENT_PID=""
  return 0
}

# ── 상태 조회 (항상 -s 테스트 세션) ───────────────────
# 소켓을 건드리는 조회는 t_zj_gate 뒤에. 생존·소멸은 상태로 판정한다 (#5632)
t_session_line()  { t_zj_gate; zellij list-sessions --no-formatting 2>/dev/null | grep -E "^${T_SESSION}( |\$)" | head -1; }
t_session_alive() { t_server_up; }
# 실행 중도 부활 대기(EXITED)도 아님 — 서버 프로세스·소켓·session_info 모두 없음
t_session_gone()  { t_server_gone && [[ ! -e "$T_ZJ_INFO" ]]; }
t_tab_names()     { _t_guard 2>/dev/null || return 1; t_zj_gate; zellij -s "$T_SESSION" action query-tab-names 2>/dev/null; }
t_tab_count()     { local n; n="$(t_tab_names)"; [[ -z "$n" ]] && print 0 || print ${#${(f)n}}; }
t_client_count()  { _t_guard 2>/dev/null || return 1; t_zj_gate; zellij -s "$T_SESSION" action list-clients 2>/dev/null | tail -n +2 | grep -c .; }
t_tabs_file()     { cat "$CMUX_TABS_FILE" 2>/dev/null; }
# 실행 중인 가짜 에이전트 수 (pane에서 exec sleep 중인 것)
t_agent_procs()   { pgrep -f "^sleep ${FAKE_AGENT_SLEEP}\$" 2>/dev/null | grep -c .; }
# t_cmux_procs [인자...] — 명령줄이 정확히 "zsh <대상 cmux> 인자..."인 프로세스 수
#   (_attach_then_add_tabs의 백그라운드 서브셸은 같은 명령줄의 fork — 끝났는지 확인용)
t_cmux_procs()    { pgrep -f "^zsh ${CMUX_UNDER_TEST}${*:+ $*}\$" 2>/dev/null | grep -c .; }
# t_agent_args <agent> <dir> — 가짜 에이전트 기록 중 해당 에이전트·cwd의 인자 필드(시간순)
t_agent_args()    { awk -F'\t' -v a="fake-$1" -v d="$2" '$1==a && $2==d {print $3}' "$FAKE_AGENT_LOG" 2>/dev/null; }
# t_agent_launches <agent> <dir> — 실행 횟수
t_agent_launches() { t_agent_args "$@" | grep -c ''; }

# t_wait_for <조건(eval 문자열)> <초> — 조건이 참이 될 때까지 0.3초 간격 폴링. 참 0 / 시간 초과 1
t_wait_for() {
  local _tw_cond="$1" _tw_deadline=$(( EPOCHREALTIME + ${2:-10} ))
  while true; do
    eval "$_tw_cond" && return 0
    (( EPOCHREALTIME >= _tw_deadline )) && return 1
    sleep 0.3
  done
}

# ── 어서션 ────────────────────────────────────────────
# t_scenario <ID(공백 없음)> <설명>
t_scenario() {
  T_SCENARIO="$1"
  T_SCENARIOS+=("$1")
  T_SC_DESC[$1]="$2"
  print -r -- "── $1  $2"
}
_t_pass() {
  (( T_PASS++ ))
  T_SC_PASS[$T_SCENARIO]=$(( ${T_SC_PASS[$T_SCENARIO]:-0} + 1 ))
  print -r -- "  PASS  $1"
}
_t_fail() {
  (( T_FAIL++ ))
  T_SC_FAIL[$T_SCENARIO]=$(( ${T_SC_FAIL[$T_SCENARIO]:-0} + 1 ))
  print -r -- "  FAIL  $1"
  [[ -n "$2" ]] && print -r -- "$2" | sed 's/^/          /'
  return 0
}
t_skip() { (( T_SKIP++ )); print -r -- "  SKIP  $1"; }

# t_assert_eq <설명> <기대> <실제>
t_assert_eq() {
  if [[ "$3" == "$2" ]]; then _t_pass "$1"
  else _t_fail "$1" "기대: ${(qqqq)2}"$'\n'"실제: ${(qqqq)3}"; fi
}
# t_assert_contains <설명> <전체> <부분>
t_assert_contains() {
  if [[ "$2" == *"$3"* ]]; then _t_pass "$1"
  else _t_fail "$1" "없음: ${(qqqq)3}"$'\n'"전체: ${(qqqq)2}"; fi
}
# t_assert_not_contains <설명> <전체> <부분>
t_assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then _t_pass "$1"
  else _t_fail "$1" "있으면 안 됨: ${(qqqq)3}"$'\n'"전체: ${(qqqq)2}"; fi
}
# t_assert_file_has_line <설명> <파일> <줄> — 줄 전체 일치
t_assert_file_has_line() {
  if grep -qxF -- "$3" "$2" 2>/dev/null; then _t_pass "$1"
  else _t_fail "$1" "줄 없음: ${(qqqq)3}"$'\n'"파일($2): ${(qqqq)$(cat "$2" 2>/dev/null)}"; fi
}
# t_assert_true <설명> <조건(eval)> [대기초] — 대기초가 있으면 그 시간까지 폴링
t_assert_true() {
  if t_wait_for "$2" "${3:-0}"; then _t_pass "$1"
  else _t_fail "$1" "조건 거짓(${3:-0}초): $2"; fi
}

# ── 라이브 세션 보호 ──────────────────────────────────
_t_live_line() { zellij list-sessions --no-formatting 2>/dev/null | grep -E "^${T_LIVE_SESSION}( |\$)" | head -1; }

t_live_snapshot() {
  local l
  l="$(_t_live_line)"
  if [[ -z "$l" || "$l" == *EXITED* ]]; then
    T_LIVE_PRESENT=0
    print -r -- "라이브 세션 '$T_LIVE_SESSION' 없음 — 라이브 보호 검사는 SKIP"
    return 0
  fi
  T_LIVE_PRESENT=1
  T_LIVE_BEFORE="$(zellij -s "$T_LIVE_SESSION" action query-tab-names 2>/dev/null)"
  print -r -- "라이브 세션 '$T_LIVE_SESSION' 스냅샷: 탭 ${#${(f)T_LIVE_BEFORE}}개"
}

t_live_check() {
  t_scenario LIVE "라이브 세션 '$T_LIVE_SESSION' 무손상"
  if (( ! T_LIVE_PRESENT )); then
    t_skip "라이브 세션 없음"
    return 0
  fi
  local l after
  l="$(_t_live_line)"
  t_assert_true "라이브 세션 생존" '[[ -n "$l" && "$l" != *EXITED* ]]'
  after="$(zellij -s "$T_LIVE_SESSION" action query-tab-names 2>/dev/null)"
  t_assert_eq "라이브 탭 수 동일" "${#${(f)T_LIVE_BEFORE}}" "${#${(f)after}}"
  t_assert_eq "라이브 탭 이름·순서 동일" "$T_LIVE_BEFORE" "$after"
}

# ── 정리 ──────────────────────────────────────────────
# 임시 루트 경로 / 고유 sleep 값 / 테스트 세션 이름을 명령줄에 가진 프로세스
_t_leftovers() {
  [[ -n "$T_ROOT" ]] || return 0
  {
    pgrep -fl -- "$T_ROOT"
    pgrep -fl -- "^sleep ${FAKE_AGENT_SLEEP}\$"
    pgrep -fl -- "${T_SESSION}([^0-9]|\$)"
  } 2>/dev/null | sort -u
}

t_teardown() {
  (( T_TORN_DOWN )) && return 0
  T_TORN_DOWN=1
  [[ -n "$T_ROOT" && -d "$T_ROOT" ]] || return 0

  local pid
  for pid in "${T_BG_PIDS[@]}"; do t_hup "$pid"; done

  if _t_guard 2>/dev/null; then
    t_zj_gate
    zellij delete-session "$T_SESSION" --force >/dev/null 2>&1
    t_wait_for 't_server_gone' 10
    # zellij가 세션마다 남기는 메타데이터 캐시 — 자기 세션 이름 경로만
    local cache="$HOME/Library/Caches/org.Zellij-Contributors.Zellij/contract_version_1/session_info/$T_SESSION"
    [[ -d "$cache" ]] && rm -rf -- "$cache"
  fi

  t_wait_for '[[ -z "$(_t_leftovers)" ]]' 5
  local -a left
  left=("${(@f)$(_t_leftovers)}")
  left=("${(@)left:#}")
  T_LEFTOVER_COUNT=${#left}
  if (( T_LEFTOVER_COUNT )); then
    print -u2 -r -- "harness: 잔여 프로세스 ${T_LEFTOVER_COUNT}개 — 종료(TERM):"
    print -u2 -l -r -- "${left[@]}"
    local line
    for line in "${left[@]}"; do kill -TERM "${line%% *}" 2>/dev/null; done
  fi

  if (( T_FAIL )); then
    print -r -- "── 실패 진단"
    print -r -- "session-tabs:"; t_tabs_file | sed 's/^/    /'
    print -r -- "fake-agent.log:"; sed 's/^/    /' "$FAKE_AGENT_LOG" 2>/dev/null
    print -r -- "zellij 서버 초기화 panic(zellij.log lib.rs:1462, #5632): 이 테스트 동안 +$(( $(t_zj_panics) - T_ZJ_PANIC0 ))건 (공유 로그 — 다른 프로세스 것 포함 가능)"
    print -r -- "pty 로그: $T_ROOT/logs (T_KEEP=1 이면 보존)"
  fi

  if [[ -n "$T_KEEP" ]]; then
    print -r -- "T_KEEP=1 — 임시 루트 보존: $T_ROOT"
  else
    rm -rf -- "$T_ROOT"
  fi
}

t_summary() {
  print -r -- ""
  print -r -- "== 요약: $T_TEST_NAME"
  local sc
  for sc in "${T_SCENARIOS[@]}"; do
    (( ${T_SC_PASS[$sc]:-0} + ${T_SC_FAIL[$sc]:-0} )) || continue
    printf '  %-9s PASS %2d  FAIL %2d  %s\n' "$sc" "${T_SC_PASS[$sc]:-0}" "${T_SC_FAIL[$sc]:-0}" "${T_SC_DESC[$sc]}"
  done
  print -r -- "RESULT $T_TEST_NAME pass=$T_PASS fail=$T_FAIL skip=$T_SKIP"
  (( T_FAIL == 0 ))
}

# t_finish — 정리(테스트 세션 삭제·잔여 확인) 후 라이브 확인, 요약. 반환값을 exit 코드로 쓴다.
t_finish() {
  t_scenario TEARDOWN "테스트 세션·프로세스 정리"
  t_teardown
  t_assert_eq "테스트 세션 제거됨" "" "$(t_session_line)"
  t_assert_eq "잔여 프로세스 0" 0 "$T_LEFTOVER_COUNT"
  t_live_check
  t_summary
}
