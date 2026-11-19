#!/usr/bin/env zsh
# t07_tabbar_toggle — 직접 그리는 탭 줄(bin/cmux-bar)의 1줄↔3줄 토글 (격리 zellij 세션, 실제 cmux-bar)
#   G 레이아웃 geometry — 바 pane 높이 4(내용 3)·tab-bar 플러그인 없음
#   C 접힘: 탭 줄 1 + 툴바 1 (탭 16개가 한 줄에 안 들어간다) · 활성 탭 SGR 색
#   T 토글(바 pane에 t 키) → 펼침: 탭 2줄(전부 보임)·아이콘 → 다시 접힘 · 상태 파일 값
#   X 상태 공유 — 다른 탭의 바도 같은 상태 파일로 그려지고, 활성 탭 표시가 따라온다 · 리더 1개(락·캐시)
#   K (가능하면) 바 pane에 SGR 마우스 입력 바이트를 써서 토글 버튼·탭 이름 클릭 동작 확인
#   L 레거시 — 옛 구조(size=2 바 pane, 위에 네이티브 tab-bar)의 탭에서 새 cmux-bar가 예외 없이 툴바만 그린다
# 격리: CMUX_TABBAR_STATE_FILE / CMUX_BAR_CACHE_DIR 를 임시 루트로. 라이브 세션 claude는 조회만(harness).
# 마우스 휠·실제 클릭의 화면 좌표는 헤드리스로 못 본다 — K는 입력 바이트 주입으로 ncurses 마우스 경로만 확인한다.

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

export CMUX_TABBAR_STATE_FILE="$T_ROOT/cfg/tabbar-rows"
export CMUX_BAR_CACHE_DIR="$T_ROOT/barcache"
# 실제 cmux-bar로 레이아웃을 다시 렌더링 (install.sh와 같은 sed 규칙·순서). harness 기본은 스텁이다.
export CMUX_BAR_BIN="$T_REPO/bin/cmux-bar"
mkdir -p "${CMUX_TABBAR_STATE_FILE:h}"
print -r -- 1 > "$CMUX_TABBAR_STATE_FILE"
for tmpl in "$T_REPO"/zellij/layouts/*.kdl.tmpl; do
  sed -e "s|CMUX_BAR_BIN|$CMUX_BAR_BIN|g" -e "s|CMUX_BIN|$CMUX_UNDER_TEST|g" "$tmpl" > "$T_ROOT/layouts/${${tmpl:t}%.tmpl}"
done
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

# 탭 16개: 긴 영문 14개(14칸 초과 → …로 잘림, 앞 13칸은 서로 다름) + 한글 1 + 짧은 1
typeset -a NAMES=()
local i
for i in {01..14}; do NAMES+=("p${i}-longprojectname"); done
NAMES+=("한글프로젝트이름이길다" "kis")
: > "$CMUX_TABS_FILE"
local n
for n in "${NAMES[@]}"; do mkdir -p "$CMUX_ROOT/$n"; print -r -- "$CMUX_ROOT/$n" >> "$CMUX_TABS_FILE"; done

# ── 도우미 (zellij 호출은 t_zj_gate 뒤, 항상 -s 테스트 세션) ──────────
_z() { _t_guard 2>/dev/null || return 1; t_zj_gate; zellij -s "$T_SESSION" "$@"; }
# 탭 이름 → 그 탭의 cmux-bar pane (terminal_<id>)
_barpane() {
  _z action list-panes -a -j 2>/dev/null | python3 -I -c '
import json, sys
try:
    panes = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for p in panes:
    if not p.get("is_plugin") and "cmux-bar" in (p.get("pane_command") or "") and p.get("tab_name") == sys.argv[1]:
        print("terminal_%d" % p["id"])' "$1"
}
_dump()      { _z action dump-screen --pane-id "$1" 2>/dev/null; }
_dump_ansi() { _z action dump-screen -a --pane-id "$1" 2>/dev/null; }
_row()       { _dump "$1" | sed -n "${2}p"; }       # _row <pane> <1|2>
# 활성 탭 SGR(검정 글자 30 + 청록 배경 46) 구간의 글자 — 색 쌍 적용 확인용
_active_label() {
  _dump_ansi "$1" | python3 -I -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"\x1b\[30m\x1b\[46m(?:\x1b\[[0-9;]*m)*([^\x1b]*)\x1b\[m", s)
print(m.group(1) if m else "")'
}
# 화면 줄을 보고서용으로 출력
_show() { print -r -- "$(_dump "$1")" | sed 's/^/    | /'; }
_state() { cat "$CMUX_TABBAR_STATE_FILE" 2>/dev/null; }

# ── 세션 시작 ──────────────────────────────────────────
t_cmux_bg 180
t_scenario G "레이아웃 geometry — 바 pane 4행(내용 3행), tab-bar 플러그인 없음"
t_assert_true "세션 준비" 't_session_ready' 30
t_assert_true "탭 16개" '(( $(t_tab_count) == 16 ))' 30
T1="${NAMES[1]}"
t_assert_true "첫 탭 바 pane 찾음" '[[ -n "$(_barpane "$T1")" ]]' 20
BAR1="$(_barpane "$T1")"
geom="$(_z action list-panes -a -j | python3 -I -c '
import json, sys
panes = json.load(sys.stdin)
bars = [p for p in panes if not p.get("is_plugin") and "cmux-bar" in (p.get("pane_command") or "")]
tabbar = [p for p in panes if p.get("is_plugin") and "tab-bar" in (p.get("title") or "")]
status = [p for p in panes if p.get("is_plugin") and "status-bar" in (p.get("title") or "")]
print("bars=%d rows=%s content=%s tabbar_plugins=%d status_plugins=%d" % (
    len(bars), sorted(set(p["pane_rows"] for p in bars)), sorted(set(p["pane_content_rows"] for p in bars)), len(tabbar), len(status)))')"
t_assert_eq "바 pane 16개 모두 pane_rows=4·pane_content_rows=3, tab-bar 플러그인 0, status-bar 16" \
  "bars=16 rows=[4] content=[3] tabbar_plugins=0 status_plugins=16" "$geom"
t_assert_not_contains "렌더한 claude-tab 레이아웃에 zellij:tab-bar 없음" "$(cat "$T_ROOT/layouts/claude-tab.kdl")" "zellij:tab-bar"

t_scenario C "접힘(기본): 0행 = 탭 1줄 + ▾, 1행 = 툴바"
t_assert_eq "초기 상태 파일 = 접힘" "1" "$(_state)"
# 시작 2초 동안은 …만 (list-tabs 지연, #5632) — 그 뒤 탭이 그려진다
t_assert_true "탭 줄이 그려짐 (첫 탭 라벨)" '[[ "$(_row "$BAR1" 1)" == *"p01-longproje…"* ]]' 25
print -r -- "  [접힘 dump-screen — 탭 16개, 활성 = 첫 탭]"; _show "$BAR1"
R1="$(_row "$BAR1" 1)"; R2="$(_row "$BAR1" 2)"
t_assert_true "0행 오른쪽 끝 토글 ▾" '[[ "$R1" == *" ▾" ]]'
t_assert_true "0행에 탭 여러 개, 한 줄에 다 안 들어가 숨김 표시 N›" '[[ "$R1" == *"p02-longproje…"* && "$R1" == *"›"* ]]'
t_assert_true "0행에 툴바 글자 없음" '[[ "$R1" != *Picker* && "$R1" != *"cmux │"* ]]'
t_assert_true "1행 = 툴바 (cmux │ ◉ Picker │ × Close │ ⏻ Quit │ … 세션명)" '[[ "$R2" == " cmux │ ◉ Picker │ × Close │ ⏻ Quit  │"* && "$R2" == *"$T_SESSION" ]]'
t_assert_true "1행에 탭 이름 없음" '[[ "$R2" != *longproj* ]]'
t_assert_eq "활성 탭(첫 탭)이 색 쌍(검정 글자+청록 배경, SGR 30·46)으로 그려짐" " p01-longproje… " "$(_active_label "$BAR1")"
t_assert_true "한글 이름은 14칸 잘림 규칙으로 (…) 뒤쪽 탭은 숨김" '[[ "$R1" != *"한글프로젝트"* ]]'

t_scenario T "토글: 바 pane에 t 키 → 펼침(탭 2줄) → 다시 t → 접힘"
_z action send-keys --pane-id "$BAR1" t >/dev/null 2>&1
t_assert_true "상태 파일 = 2" '[[ "$(_state)" == 2 ]]' 5
t_assert_true "펼침: 0행 오른쪽 끝 토글 ▴" '[[ "$(_row "$BAR1" 1)" == *" ▴" ]]' 5
print -r -- "  [펼침 dump-screen — 같은 탭 16개]"; _show "$BAR1"
R1="$(_row "$BAR1" 1)"; R2="$(_row "$BAR1" 2)"
t_assert_true "펼침: 1행 오른쪽 끝 축약 아이콘 ◉ │ × │ ⏻" '[[ "$R2" == *"◉ │ × │ ⏻" ]]'
t_assert_true "펼침: 1행에도 탭 (한글 이름은 14칸 잘림 한글프로젝트…, kis)" '[[ "$R2" == *"한글프로젝트…"* && "$R2" == *" kis"* ]]'
t_assert_true "펼침: 0행 탭 + 1행 탭으로 16개 전부 (숨김 표시 없음)" '[[ "$R1" != *"›"* && "$R2" != *"›"* && "$R1" != *"‹"* && "$R2" != *"‹"* && "$R1" == *"p01-longproje…"* && "$R1" == *"p12-longproje…"* ]]'
t_assert_true "펼침: 툴바 문구(Picker) 없음" '[[ "$R1$R2" != *Picker* ]]'
t_assert_eq "펼침: 활성 탭 색 유지" " p01-longproje… " "$(_active_label "$BAR1")"
_z action send-keys --pane-id "$BAR1" t >/dev/null 2>&1
t_assert_true "다시 t: 상태 파일 = 1" '[[ "$(_state)" == 1 ]]' 5
t_assert_true "다시 접힘: 0행 ▾ + 1행 툴바" '[[ "$(_row "$BAR1" 1)" == *" ▾" && "$(_row "$BAR1" 2)" == *"Picker"* ]]' 5

t_scenario X "상태 공유 — 다른 탭 바도 같은 상태, 활성 표시 추종, 리더 1개"
T8="${NAMES[8]}"
t_assert_true "8번째 탭 바 pane 찾음" '[[ -n "$(_barpane "$T8")" ]]' 10
BAR8="$(_barpane "$T8")"
_z action go-to-tab 8 >/dev/null 2>&1
t_assert_true "8번째 탭이 접힘 상태로 같은 모양 (토글 ▾, 툴바 1행)" '[[ "$(_row "$BAR8" 1)" == *" ▾" && "$(_row "$BAR8" 2)" == *"Picker"* ]]' 10
t_assert_true "활성 탭 표시가 8번째로 따라옴 (≤ 수 초)" '[[ "$(_active_label "$BAR8")" == " p08-longproje… " ]]' 10
# 다른 탭에서 파일로 펼침 → 두 탭 모두 즉시 반영
print -r -- 2 > "$CMUX_TABBAR_STATE_FILE"
t_assert_true "상태 파일 쓰기 → 8번째 탭 펼침 (0행 ▴ + 1행 아이콘)" '[[ "$(_row "$BAR8" 1)" == *" ▴" && "$(_row "$BAR8" 2)" == *"◉ │ × │ ⏻" ]]' 5
t_assert_true "같은 때 첫 탭 바도 펼침 (상태 공유)" '[[ "$(_row "$BAR1" 1)" == *" ▴" && "$(_row "$BAR1" 2)" == *"◉ │ × │ ⏻" ]]' 5
print -r -- "  [펼침 — 8번째 탭의 바]"; _show "$BAR8"
print -r -- 1 > "$CMUX_TABBAR_STATE_FILE"
t_assert_true "상태 파일 1 → 8번째 탭 접힘 복귀" '[[ "$(_row "$BAR8" 1)" == *" ▾" && "$(_row "$BAR8" 2)" == *"Picker"* ]]' 5
R1="$(_row "$BAR8" 1)"
t_assert_true "접힘에서 활성(8번째)이 창 안: 라벨 p08 보임·왼쪽 숨김 ‹N 표시" '[[ "$R1" == *"p08-longproje…"* ]]'
# 리더 1개: 락 디렉터리의 pid = 살아 있는 cmux-bar, 캐시에 탭 16개
LOCKPID="$(cat "$CMUX_BAR_CACHE_DIR"/tabs-"$T_SESSION".lock/pid 2>/dev/null)"
t_assert_true "리더 락 pid 파일 + 살아 있는 cmux-bar 프로세스" '[[ -n "$LOCKPID" ]] && ps -o command= -p "$LOCKPID" | grep -q "cmux-bar"'
t_assert_eq "캐시 파일에 탭 16개 (리더가 1초 주기로 기록)" 16 "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CMUX_BAR_CACHE_DIR/tabs-$T_SESSION.json" 2>/dev/null)"
t_assert_eq "락 디렉터리 1개 (리더 1개)" 1 "$(print -l "$CMUX_BAR_CACHE_DIR"/*.lock(N) | grep -c .)"

t_scenario K "마우스 입력 바이트 주입 — 토글 버튼·탭 이름 클릭 (SGR 1006)"
# 바 pane(--pane-id)에 xterm SGR 마우스 눌림(ESC [ < 0 ; 열 ; 행 M)을 써서 ncurses 마우스 경로를 탄다.
# 열은 화면에서 찾는다 (1-기준). 토글 = 0행 오른쪽 끝, 탭 = 라벨 위치.
# 눌림(M) 뒤에 뗌(m)까지 보낸다 — 실제 터미널처럼. 뗌이 없으면 ncurses가 버튼이 계속 눌린 걸로 보고 다음 눌림을 무시한다.
_mouse_bytes() { python3 -I -c 'import sys; print(" ".join(str(b) for b in ("\x1b[<0;%s;%sM\x1b[<0;%s;%sm" % (sys.argv[1], sys.argv[2], sys.argv[1], sys.argv[2])).encode()))' "$1" "$2"; }
W=200
_z action write --pane-id "$BAR8" ${=$(_mouse_bytes $(( W - 1 )) 1)} >/dev/null 2>&1
if t_wait_for '[[ "$(_state)" == 2 ]]' 5; then
  t_assert_true "토글 버튼(0행 오른쪽 끝) 클릭 → 상태 파일 2·펼침 ▴" '[[ "$(_row "$BAR8" 1)" == *" ▴" ]]' 5
  _z action write --pane-id "$BAR8" ${=$(_mouse_bytes $(( W - 1 )) 1)} >/dev/null 2>&1
  t_assert_true "한 번 더 클릭 → 접힘 복귀 (상태 1)" '[[ "$(_state)" == 1 && "$(_row "$BAR8" 1)" == *" ▾" ]]' 5
  # 탭 이름 클릭: 접힘 0행에서 p03 라벨의 열을 찾아 클릭 → 활성 탭이 3번째로
  COL="$(_row "$BAR8" 1 | python3 -I -c '
import sys
s = sys.stdin.read().rstrip("\n")
i = s.find("p03-longproje")
print(i + 3 if i >= 0 else "")')"
  if [[ -n "$COL" ]]; then
    _z action write --pane-id "$BAR8" ${=$(_mouse_bytes "$COL" 1)} >/dev/null 2>&1
    t_assert_true "탭 이름(p03) 클릭 → 그 탭으로 이동 (list-tabs 활성)" '[[ "$(_z action list-tabs --json 2>/dev/null | python3 -I -c "import json,sys; print([t[\"name\"] for t in json.load(sys.stdin) if t[\"active\"]][0])")" == "${NAMES[3]}" ]]' 8
  else
    t_skip "p03 라벨을 8번째 탭 접힘 0행에서 못 찾음 — 탭 클릭 확인 생략"
  fi
else
  t_skip "마우스 바이트 주입이 토글에 닿지 않음(5초) — 클릭 경로는 미확인 (단위 시험 classify_mouse로 대체)"
fi
_z action go-to-tab 1 >/dev/null 2>&1

t_scenario L "레거시 — 옛 구조(size=2 바 pane + 위의 네이티브 tab-bar) 탭에서 새 cmux-bar"
print -r -- "layout {
    pane size=1 borderless=true {
        plugin location=\"zellij:tab-bar\"
    }
    pane size=2 borderless=true {
        command \"/bin/zsh\"
        args \"-c\" \"while true; do $CMUX_BAR_BIN; sleep 1; done\"
    }
    pane {
        command \"/bin/sleep\"
        args \"$FAKE_AGENT_SLEEP\"
    }
    pane size=2 borderless=true {
        plugin location=\"zellij:status-bar\"
    }
}" > "$T_ROOT/layouts/legacy-tab.kdl"
_z action new-tab --layout "$T_ROOT/layouts/legacy-tab.kdl" --name legacy-tab --cwd "$CMUX_ROOT" >/dev/null 2>&1
t_assert_true "레거시 탭 생성 (탭 17개)" '(( $(t_tab_count) == 17 ))' 15
t_assert_true "레거시 탭 바 pane 찾음" '[[ -n "$(_barpane legacy-tab)" ]]' 15
BARL="$(_barpane legacy-tab)"
geomL="$(_z action list-panes -a -j | python3 -I -c '
import json, sys
for p in json.load(sys.stdin):
    if p.get("tab_name") == "legacy-tab" and not p.get("is_plugin") and "cmux-bar" in (p.get("pane_command") or ""):
        print("rows=%s content=%s" % (p["pane_rows"], p["pane_content_rows"]))')"
t_assert_eq "레거시 바 pane 내용 1행 (size=2)" "rows=2 content=1" "$geomL"
t_assert_true "레거시: 툴바만 그린다 (cmux │ Picker │ Close │ Quit │ … 세션명)" '[[ "$(_row "$BARL" 1)" == " cmux │ ◉ Picker │ × Close │ ⏻ Quit  │"* && "$(_row "$BARL" 1)" == *"$T_SESSION" ]]' 15
print -r -- "  [레거시 dump-screen]"; _show "$BARL"
sleep 3   # 레거시 바가 2초 지연·캐시 폴링 구간을 지나도 계속 그리는지 (예외로 죽지 않음)
RL="$(_dump "$BARL")"
t_assert_true "레거시: 3초 뒤에도 툴바 그대로·토글/탭 글자·Traceback 없음" '[[ "$RL" == *"Picker"* && "$RL" != *"▾"* && "$RL" != *"▴"* && "$RL" != *longproj* && "$RL" != *Traceback* ]]'
t_assert_true "레거시: 바 프로세스가 살아 있다 (pane 안 cmux-bar python)" 'pgrep -f "[Pp]ython.* ${CMUX_BAR_BIN}\$" >/dev/null'
# 레거시 바가 상태 파일·캐시를 건드리지 않는다: 토글해도 레거시 탭은 그대로
print -r -- 2 > "$CMUX_TABBAR_STATE_FILE"
sleep 1
t_assert_true "레거시: 상태 파일이 2여도 툴바 1행 그대로" '[[ "$(_row "$BARL" 1)" == *"Picker"* && "$(_dump "$BARL")" != *"▴"* ]]'
print -r -- 1 > "$CMUX_TABBAR_STATE_FILE"

t_finish
exit $?
