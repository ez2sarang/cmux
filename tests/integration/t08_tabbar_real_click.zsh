#!/usr/bin/env zsh
# t08_tabbar_real_click — 진짜 마우스 클릭(zellij 클라이언트 입력)으로 보는 cmux-bar: click-through·포커스 복귀·키 제거
#   t07은 바 pane에 입력 바이트를 직접 주입(zellij action write --pane-id)해서, 포커스 없는 pane의 첫 클릭이
#   앱에 전달되지 않는 zellij 동작과 클릭이 남기는 포커스를 못 잡았다. 여기서는 ptyrun --send 로 zellij 클라이언트
#   입력에 SGR 마우스 눌림+뗌을 보낸다 (= 터미널에서 실제로 클릭한 것과 같은 경로).
#   A  mouse_click_through true  — 클릭 1회: 탭 전환 + 출발 탭 바 pane 포커스 해제·본문 pane 포커스 / 토글 버튼 클릭 + 포커스 복귀
#   B  mouse_click_through false — 클릭 1회: 전환 안 됨(바만 포커스) / 2회: 전환 + 출발 탭 본문 포커스 복귀
#   K  x·q·X·Q 키를 바 pane에 보내도 세션·탭이 그대로 (p·t만 남김)
#   W  휠 위/아래 (이 python의 curses에 BUTTON5가 있는지에 따라 아래 동작 여부를 고정)
#   L  레거시(내용 1행) 바는 캐시 디렉터리를 만들지 않는다 (스트립 모드는 만든다)
# 격리 세션 cmuxt<pid>만 쓴다. 클릭 시각은 ptyrun --send 의 고정 시각이고, 결과 확인은 t_wait_for 로 상태를 기다린다.

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

export CMUX_TABBAR_STATE_FILE="$T_ROOT/cfg/tabbar-rows"
export CMUX_BAR_CACHE_DIR="$T_ROOT/barcache"
BAR_BIN="$T_REPO/bin/cmux-bar"
SLEEPV="$FAKE_AGENT_SLEEP"
LAYOUT="$T_ROOT/layouts/click3.kdl"
{
  print -r -- 'layout {'
  print -r -- '    default_tab_template {'
  print -r -- '        pane size=3 borderless=true {'
  print -r -- '            command "/bin/zsh"'
  print -r -- "            args \"-c\" \"while true; do $BAR_BIN; sleep 1; done\""
  print -r -- '        }'
  print -r -- '        children'
  print -r -- '    }'
  local t
  for t in alpha beta gamma; do
    print -r -- "    tab name=\"$t\" cwd=\"$CMUX_ROOT\" $([[ $t == alpha ]] && print -r -- 'focus=true') {"
    print -r -- "        pane name=\"claude\" focus=true {"
    print -r -- '            command "/bin/sleep"'
    print -r -- "            args \"$SLEEPV\""
    print -r -- '        }'
    print -r -- '    }'
  done
  print -r -- '}'
} > "$LAYOUT"

# 설정 파일 2개 (click-through 켬/끔). 사용자 ~/.config/zellij/config.kdl 은 --config 로 대체되어 읽히지 않는다.
mkcfg() { # <true|false> <경로>
  print -r -- "mouse_mode true
mouse_click_through $1
show_startup_tips false
session_serialization false" > "$2"
}
mkcfg true  "$T_ROOT/cfg/zj-ct-true.kdl"
mkcfg false "$T_ROOT/cfg/zj-ct-false.kdl"

# ── 도우미 ─────────────────────────────────────────────
_z() { _t_guard 2>/dev/null || return 1; t_zj_gate; zellij -s "$T_SESSION" "$@"; }
# SGR 마우스 눌림+뗌 (열·행은 1-기준). ptyrun --send 의 \x1b 해석은 python unicode_escape.
_click_arg() { print -r -- "$1:\\x1b[<0;$2;$3M\\x1b[<0;$2;$3m"; }
_key_arg()   { print -r -- "$1:$2"; }
_start() { # <config> <ptyrun --send 인자...>
  local cfg="$1"; shift
  local -a sends=()
  local s; for s in "$@"; do sends+=(--send "$s"); done
  : > "$T_ZJ_MARK"
  python3 "$T_PTYRUN" --log "$T_ROOT/logs/click-$(basename $cfg).log" --secs 90 "${sends[@]}" -- \
    zellij --config "$cfg" -s "$T_SESSION" -n "$LAYOUT" 2> "$T_ROOT/logs/click.status" &
  T_CLIENT_PID=$!
  T_BG_PIDS+=($T_CLIENT_PID)
}
_stop_session() {
  t_hup
  t_zj_gate
  zellij delete-session "$T_SESSION" --force >/dev/null 2>&1
  t_wait_for 't_session_gone' 15
  rm -rf -- "$CMUX_BAR_CACHE_DIR"
  rm -f -- "$CMUX_TABBAR_STATE_FILE"
}
_active_tab() {
  _z action list-tabs --json 2>/dev/null | python3 -I -c '
import json, sys
try:
    print(([t["name"] for t in json.load(sys.stdin) if t["active"]] or [""])[0])
except ValueError:
    print("")'
}
_tabnames() { _z action list-tabs --json 2>/dev/null | python3 -I -c '
import json, sys
try:
    print(",".join(t["name"] for t in json.load(sys.stdin)))
except ValueError:
    print("")'; }
# 탭의 포커스 상태 "bar=<True|False> body=<True|False>"
_focus() {
  _z action list-panes -a -j 2>/dev/null | python3 -I -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
bar = body = "?"
for p in panes:
    if p.get("tab_name") != sys.argv[1] or p.get("is_plugin"):
        continue
    if "cmux-bar" in (p.get("terminal_command") or "") or "cmux-bar" in (p.get("title") or ""):
        bar = p.get("is_focused")
    elif p.get("title") == "claude":
        body = p.get("is_focused")
print("bar=%s body=%s" % (bar, body))' "$1"
}
_barpane() {
  _z action list-panes -a -j 2>/dev/null | python3 -I -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and "cmux-bar" in ((p.get("terminal_command") or "") + (p.get("title") or "")) and p.get("tab_name") == sys.argv[1]:
        print("terminal_%d" % p["id"])' "$1"
}
_row() { _z action dump-screen --pane-id "$1" 2>/dev/null | sed -n "${2}p"; }
_state() { cat "$CMUX_TABBAR_STATE_FILE" 2>/dev/null; }
_report() { print -r -- "    [$1] 활성=$(_active_tab) 탭=$(_tabnames) alpha:{$(_focus alpha)} beta:{$(_focus beta)} 상태파일='$(_state)'"; }

# 바 라벨 위치: " alpha "(1-기준 열 1~7) " beta "(8~13) " gamma "(14~20). beta 이름 위 = 열 10. 토글 = 0행 오른쪽 끝(열 199)
BETA_X=10
TOGGLE_X=199

t_scenario D1 "레포 zellij/config.kdl: mouse_click_through true + zellij가 유효한 설정으로 읽음"
t_assert_true "config.kdl에 mouse_click_through true" 'grep -q "^mouse_click_through true" "$T_REPO/zellij/config.kdl"'
t_assert_contains "zellij --config <레포 config> setup --check = Well defined (세션 접촉 없음)" "$(zellij --config "$T_REPO/zellij/config.kdl" setup --check 2>&1)" "[CONFIG FILE]: Well defined."

# ═══ A ═ click-through 켬 ═══════════════════════════════
t_scenario A "mouse_click_through true: 진짜 클릭 1회에 탭 전환 + 포커스 복귀, 토글 클릭 + 포커스 복귀"
A_START=$EPOCHSECONDS
_start "$T_ROOT/cfg/zj-ct-true.kdl" "$(_click_arg 12 $BETA_X 1)" "$(_click_arg 18 $TOGGLE_X 1)" "$(_key_arg 26 t)"
t_assert_true "세션 준비" 't_session_ready' 30
t_assert_true "탭 3개 (alpha beta gamma)" '[[ "$(_tabnames)" == "alpha,beta,gamma" ]]' 30
t_assert_true "시작: alpha 활성, 본문 pane 포커스·바 pane 포커스 없음" '[[ "$(_active_tab)" == alpha && "$(_focus alpha)" == "bar=False body=True" ]]' 30
_report "클릭 전"
t_assert_true "바가 탭 줄을 그림 (클릭 12초 전에 준비)" '[[ "$(_row "$(_barpane alpha)" 1)" == *" beta "* ]]' 15
# ① 클릭 1회 → 전환 + 출발 탭(alpha) 바 포커스 해제·본문 포커스
t_assert_true "① 클릭 1회로 beta로 전환 (click-through)" '[[ "$(_active_tab)" == beta ]]' 40
t_assert_true "① 출발 탭 alpha: 바 pane 포커스 해제·본문 pane 포커스 복귀" '[[ "$(_focus alpha)" == "bar=False body=True" ]]' 10
_report "① 클릭 후"
t_assert_true "① 도착 탭 beta: 본문 포커스·바 포커스 없음" '[[ "$(_focus beta)" == "bar=False body=True" ]]' 5
# ③ 토글 버튼 클릭(0행 오른쪽 끝) → 상태 파일 2 + 포커스 복귀
t_assert_true "③ 토글 버튼 클릭 → 상태 파일 = 2" '[[ "$(_state)" == 2 ]]' 30
t_assert_true "③ 토글 클릭 뒤 beta 포커스 복귀 (바 해제·본문)" '[[ "$(_focus beta)" == "bar=False body=True" ]]' 10
t_assert_true "③ beta 바가 펼침(▴)으로 그려짐" '[[ "$(_row "$(_barpane beta)" 1)" == *" ▴" ]]' 10
_report "③ 토글 클릭 후"
# 실제 키 입력: 26초에 클라이언트로 t를 보낸다. 바가 포커스를 갖고 있으면 상태가 다시 1로 뒤집힌다 → 2 그대로여야 한다
t_wait_for '(( EPOCHSECONDS - A_START >= 30 ))' 45
t_assert_true "③ 26초 키 t 이후에도 상태 파일 = 2 (키가 바가 아닌 본문 pane으로 감 = 클릭 뒤 포커스 복귀의 실제 키 증거)" '[[ "$(_state)" == 2 ]]'
_stop_session

# ═══ B ═ click-through 끔 ═══════════════════════════════
t_scenario B "mouse_click_through false: 첫 클릭은 포커스 이동에만 쓰이고 2번째에 전환, 출발 탭 본문 포커스 복귀"
_start "$T_ROOT/cfg/zj-ct-false.kdl" "$(_click_arg 12 $BETA_X 1)" "$(_key_arg 17 t)" "$(_click_arg 22 $BETA_X 1)"
t_assert_true "세션 준비" 't_session_ready' 30
t_assert_true "탭 3개" '[[ "$(_tabnames)" == "alpha,beta,gamma" ]]' 30
t_assert_true "시작: alpha 활성·본문 포커스" '[[ "$(_active_tab)" == alpha && "$(_focus alpha)" == "bar=False body=True" ]]' 30
_report "클릭 전"
# ② 1회 클릭: 전환 안 됨, alpha 바 pane만 포커스
t_assert_true "② 클릭 1회 후 alpha 바 pane이 포커스를 가짐 (첫 클릭은 포커스 이동에만)" '[[ "$(_focus alpha)" == "bar=True body=False" ]]' 40
_report "② 클릭 1회 후"
t_assert_eq "② 클릭 1회로는 전환 안 됨 (alpha 그대로)" alpha "$(_active_tab)"
# 키 t(17초)는 바가 포커스를 가졌으므로 바에 전달 → 상태 파일 2 (실제 키 경로로도 바 포커스 확인)
t_assert_true "② 17초 키 t가 바 pane으로 전달됨 (상태 파일 = 2) — 바가 실제 키보드 포커스를 가짐" '[[ "$(_state)" == 2 ]]' 15
# 2회 클릭(22초): 전환 + 출발 탭 본문 포커스 복귀
t_assert_true "② 클릭 2회로 beta로 전환" '[[ "$(_active_tab)" == beta ]]' 30
t_assert_true "② 출발 탭 alpha: 바 포커스 해제·본문 포커스 복귀" '[[ "$(_focus alpha)" == "bar=False body=True" ]]' 10
_report "② 클릭 2회 후"

# ═══ K ═ x·q 키 제거 ═════════════════════════════════════
t_scenario K "바 pane에 x·q·X·Q 키 — 세션·탭 그대로 (t는 순서 장벽으로 사용)"
BARB="$(_barpane beta)"
t_assert_true "beta 바 pane 찾음" '[[ -n "$BARB" ]]' 10
state_before="$(_state)"      # 2 (② 17초 키 t) — 펼침 상태
tabs_before="$(_tabnames)"
_z action send-keys --pane-id "$BARB" q x Q X >/dev/null 2>&1
_z action send-keys --pane-id "$BARB" t >/dev/null 2>&1       # 같은 pty 순서 → t가 처리됐으면 앞의 q x Q X도 처리된 것
t_assert_true "장벽 t 처리됨 (상태 파일 2 → 1)" '[[ "$(_state)" == 1 ]]' 10
t_assert_true "세션 생존" 't_session_alive'
t_assert_eq "탭 목록 그대로 (close-tab 안 됨)" "$tabs_before" "$(_tabnames)"
t_assert_eq "탭 3개" 3 "$(t_tab_count)"
_report "K 키 q x Q X 후"

# ═══ W ═ 휠 ══════════════════════════════════════════════
t_scenario W "마우스 휠 (SGR 64=위, 65=아래) — 이 python의 curses 지원에 따라"
HAS_B5="$(python3 -I -c 'import curses; print(int(hasattr(curses, "BUTTON5_PRESSED")))')"
_wheel() { # <64|65>
  _z action write --pane-id "$BARB" ${=$(python3 -I -c 'import sys; print(" ".join(str(b) for b in ("\x1b[<%s;10;1M\x1b[<%s;10;1m" % (sys.argv[1], sys.argv[1])).encode()))' "$1")} >/dev/null 2>&1
}
t_assert_eq "(전제) 활성 = beta" beta "$(_active_tab)"
_wheel 64
t_assert_true "휠 위 → 이전 탭(alpha)" '[[ "$(_active_tab)" == alpha ]]' 10
BARA="$(_barpane alpha)"
_z action go-to-tab 2 >/dev/null 2>&1
t_assert_true "(복귀) beta" '[[ "$(_active_tab)" == beta ]]' 10
_wheel 65
_z action send-keys --pane-id "$BARB" t >/dev/null 2>&1       # 장벽: 휠 아래 이벤트가 처리된 뒤 확인
t_assert_true "장벽 t 처리됨 (상태 1 → 2)" '[[ "$(_state)" == 2 ]]' 10
if [[ "$HAS_B5" == 1 ]]; then
  t_assert_true "휠 아래 → 다음 탭(gamma) (이 python은 BUTTON5 있음)" '[[ "$(_active_tab)" == gamma ]]' 10
else
  t_assert_eq "휠 아래 → 동작 없음: 이 python(/usr/bin/python3)의 curses에 BUTTON5_PRESSED가 없다 (활성 beta 그대로)" beta "$(_active_tab)"
fi
print -r -- "    [휠] python=$(python3 -I -c 'import sys; print(sys.executable)') BUTTON5=$HAS_B5 활성=$(_active_tab)"
_stop_session

# ═══ L ═ 레거시는 캐시 디렉터리를 만들지 않는다 ═══════════
t_scenario L "레거시(내용 1행) 바는 캐시 디렉터리를 만들지 않고, 스트립(내용 2행)은 만든다"
for rows in 1 2; do
  CMUX_BAR_CACHE_DIR="$T_ROOT/lc$rows" python3 "$T_PTYRUN" --log "$T_ROOT/logs/lc$rows.log" --secs 1.5 --rows $rows --cols 80 -- "$BAR_BIN" 2>/dev/null
done
t_assert_true "레거시(1행): 툴바를 그림" 'grep -q Picker "$T_ROOT/logs/lc1.log"'
t_assert_true "레거시(1행): 캐시 디렉터리 없음" '[[ ! -e "$T_ROOT/lc1" ]]'
t_assert_true "스트립(2행): 캐시 디렉터리 생성" '[[ -d "$T_ROOT/lc2" ]]'

t_finish
exit $?
