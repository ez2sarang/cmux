#!/usr/bin/env zsh
# t09_state_badge — 탭별 에이전트 상태 배지 + cmux status / cmux jump (격리 zellij 세션 cmuxt<pid>, 실제 cmux-bar, 가짜 에이전트)
#   I 종단간 주입 — cmux launch 가 CMUX_TAB_NAME 을 export 하고 claude 에 --settings 훅을 붙인다 (가짜 claude 가 JSON 의 훅 명령을
#     합성 payload 로 실제 실행 → 상태 파일이 임시 CMUX_AGENT_STATE_DIR 에 생긴다). 실제 claude 훅 발화는 시험하지 않는다.
#   B 배지 — 바 pane 의 dump-screen 에 working `~` / blocked `!` 가 해당 탭 이름 옆에 보이고, idle 이면 사라진다 (blocked `!` 는 빨간 배경 SGR)
#   F cmux status 표(실제 list-tabs --json 파싱) · cmux jump 가 blocked 탭으로 전환 (list-tabs 의 active 로 확인; 마우스 클릭 없음)
# 격리: CMUX_AGENT_STATE_DIR(harness) · CMUX_TABBAR_STATE_FILE · CMUX_BAR_CACHE_DIR 를 임시 루트로. 라이브 세션 claude 는 조회만(harness).

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

export CMUX_STATE_HOOKS=1                       # harness 기본(0)을 이 시험에서만 켠다
export CMUX_TABBAR_STATE_FILE="$T_ROOT/cfg/tabbar-rows"
export CMUX_BAR_CACHE_DIR="$T_ROOT/barcache"
STATE_BIN="${CMUX_UNDER_TEST:h}/cmux-agent-state"
export CMUX_BAR_BIN="${CMUX_UNDER_TEST:h}/cmux-bar"
for tmpl in "$T_REPO"/zellij/layouts/*.kdl.tmpl; do
  sed -e "s|CMUX_BAR_BIN|$CMUX_BAR_BIN|g" -e "s|CMUX_BIN|$CMUX_UNDER_TEST|g" "$tmpl" > "$T_ROOT/layouts/${${tmpl:t}%.tmpl}"
done
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

# 가짜 claude: --settings JSON 에서 FAKE_HOOK_EVENTS 의 훅 명령을 꺼내 합성 payload 로 실행(claude 가 훅을 발화하는 흉내) → 기록 → sleep
export HOOKLOG="$T_ROOT/hookagent.log"
export FAKE_HOOK_EVENTS="SessionStart UserPromptSubmit"
cat > "$T_ROOT/bin/fake-claude-hooks" <<'EOF'
#!/bin/sh
settings=""; prev=""
for a in "$@"; do [ "$prev" = "--settings" ] && settings="$a"; prev="$a"; done
ran=""
if [ -n "$settings" ]; then
  for ev in $FAKE_HOOK_EVENTS; do
    cmd="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' "$settings" "$ev")"
    printf '{}' | sh -c "$cmd" && ran="$ran $ev"
  done
fi
printf 'tab=%s settings=%s ran=%s\n' "$CMUX_TAB_NAME" "$([ -n "$settings" ] && echo yes || echo no)" "$ran" >> "$HOOKLOG"
exec sleep "${FAKE_AGENT_SLEEP:-3600}"
EOF
chmod +x "$T_ROOT/bin/fake-claude-hooks"
export CMUX_CLAUDE_BIN="$T_ROOT/bin/fake-claude-hooks"

typeset -a NAMES=(alpha beta)
: > "$CMUX_TABS_FILE"
local n
for n in "${NAMES[@]}"; do mkdir -p "$CMUX_ROOT/$n"; print -r -- "$CMUX_ROOT/$n" >> "$CMUX_TABS_FILE"; done

# ── 도우미 (zellij 호출은 t_zj_gate 뒤, 항상 -s 테스트 세션) ──────────
_z() { _t_guard 2>/dev/null || return 1; t_zj_gate; zellij -s "$T_SESSION" "$@"; }
_barpane() {   # 탭 이름 → 그 탭의 cmux-bar pane (terminal_<id>)
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
_row1()      { _dump "$1" | sed -n 1p; }
_active_tab() { _z action list-tabs --json 2>/dev/null | python3 -I -c '
import json, sys
try:
    tabs = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
print(",".join(t["name"] for t in tabs if t.get("active")))'; }
_pane_of() { local f; for f in "$CMUX_AGENT_STATE_DIR/$T_SESSION"/<->(N); do [[ "$(sed -n 's/^tab=//p' "$f")" == "$1" ]] && { print -r -- "${f:t}"; return 0 }; done; return 1 }   # 탭 → 그 탭 상태 파일의 pane id
# ! 앞에 붙은 SGR 묶음에 41(빨간 배경)과 37(흰 글자)이 모두 있으면 ok (dump-screen -a 출력이 SGR 을 나눠 내든 합쳐 내든 숫자 집합으로 본다)
cat > "$T_ROOT/bangsgr.py" <<'PY'
import re, sys
s = sys.stdin.read()
for m in re.finditer(r"((?:\x1b\[[0-9;]*m)+)!", s):
    nums = set()
    for g in re.findall(r"\x1b\[([0-9;]*)m", m.group(1)):
        nums.update(g.split(";"))
    if {"41", "37"} <= nums:
        print("ok")
        break
else:
    print("no")
PY
_bang_ok() { _dump_ansi "$1" | python3 -I "$T_ROOT/bangsgr.py"; }   # <pane> → ok | no
_hookev() { print -r -- '{}' | env CMUX_TAB_NAME="$1" ZELLIJ_SESSION_NAME="$T_SESSION" ZELLIJ_PANE_ID="$2" "$STATE_BIN" hook "$3"; }   # <탭> <pane> <이벤트>
_sfield() { sed -n "s/^$2=//p" "$CMUX_AGENT_STATE_DIR/$T_SESSION/$1" 2>/dev/null | head -1; }
_cmux() { _t_guard || return 99; t_zj_gate; zsh "$CMUX_UNDER_TEST" "$@" 2>&1; }

# ── 세션 시작 ──────────────────────────────────────────
t_cmux_bg 180
t_scenario I "종단간 주입 — CMUX_TAB_NAME export · claude --settings 훅 · 상태 파일"
t_assert_true "세션 준비" 't_session_ready' 30
t_assert_true "탭 2개 (alpha, beta)" '(( $(t_tab_count) == 2 ))' 30
t_assert_true "가짜 claude 2개 실행·훅 실행 기록" '(( ${$(grep -c . "$HOOKLOG" 2>/dev/null):-0} == 2 ))' 40
print -r -- "  [가짜 claude 기록]"; sort "$HOOKLOG" | sed 's/^/    | /'
t_assert_eq "각 탭의 claude 가 CMUX_TAB_NAME 을 받고 --settings 로 SessionStart·UserPromptSubmit 훅을 실행" \
  "tab=alpha settings=yes ran= SessionStart UserPromptSubmit"$'\n'"tab=beta settings=yes ran= SessionStart UserPromptSubmit" "$(sort "$HOOKLOG")"
t_assert_true "상태 파일 2개 (세션 디렉터리, 숫자 이름)" '(( $(print -l "$CMUX_AGENT_STATE_DIR/$T_SESSION"/<->(N) | grep -c .) == 2 ))' 5
PA="$(_pane_of alpha)"; PB="$(_pane_of beta)"
t_assert_true "pane id 가 서로 다른 숫자 (alpha=$PA, beta=$PB)" '[[ "$PA" == <-> && "$PB" == <-> && "$PA" != "$PB" ]]'
t_assert_eq "alpha 상태 파일: working, tab=alpha" "working|alpha" "$(_sfield "$PA" state)|$(_sfield "$PA" tab)"
t_assert_eq "beta 상태 파일: working, tab=beta" "working|beta" "$(_sfield "$PB" state)|$(_sfield "$PB" tab)"

t_scenario B "배지 — 바 pane dump-screen 의 ~ / !"
t_assert_true "alpha 탭 바 pane 찾음" '[[ -n "$(_barpane alpha)" ]]' 20
t_assert_true "beta 탭 바 pane 찾음" '[[ -n "$(_barpane beta)" ]]' 20
BARA="$(_barpane alpha)"; BARB="$(_barpane beta)"
t_assert_true "둘 다 working → 탭 이름 옆에 ~ (' alpha~ beta~': 상태 배지는 끝 패딩 칸을 대신 차지; 시작 2초 뒤 첫 조회 + 1초 주기)" '[[ "$(_row1 "$BARA")" == " alpha~ beta~"* ]]' 30
print -r -- "  [alpha 탭의 바 0행]"; print -r -- "    | $(_row1 "$BARA")"
COL_W="${#${$(_row1 "$BARA")%%beta*}}"     # working 일 때 beta 라벨이 시작하는 열 (폭 불변 확인용)
_hookev beta "$PB" PermissionRequest
t_assert_true "beta 를 blocked 로 → ' beta!' (alpha~ 유지, beta 위치 그대로) — 두 탭의 바 모두 반영" \
  '[[ "$(_row1 "$BARA")" == " alpha~ beta!"* && "$(_row1 "$BARB")" == " alpha~ beta!"* ]]' 20
print -r -- "  [alpha 탭의 바 0행]"; print -r -- "    | $(_row1 "$BARA")"
t_assert_true "! 는 빨간 배경(SGR 41) + 흰 글자(37) 로 그려진다 (alpha 바에서 보는 비활성 beta 의 배지)" '[[ "$(_bang_ok "$BARA")" == ok ]]' 10
_hookev alpha "$PA" Stop
t_assert_true "alpha 를 idle 로 → 배지 사라짐 (' alpha  beta!') — 폭 불변: beta 라벨 시작 열이 working 일 때와 같다" '[[ "$(_row1 "$BARA")" == " alpha  beta!"* && "${#${$(_row1 "$BARA")%%beta*}}" == "$COL_W" ]]' 20
_hookev alpha "$PA" UserPromptSubmit
t_assert_true "다시 working → ' alpha~ beta!' — 이번에도 beta 시작 열 그대로" '[[ "$(_row1 "$BARA")" == " alpha~ beta!"* && "${#${$(_row1 "$BARA")%%beta*}}" == "$COL_W" ]]' 20

t_scenario F "cmux status / cmux jump"
out="$(_cmux status)"; rc=$?
print -r -- "$out" | sed 's/^/    | /'
lines=("${(@f)out}")
t_assert_eq "status: 종료코드 0·머리줄" "0|yes" "$rc|$([[ "${lines[1]}" == "탭"*"상태"*"경과" ]] && print yes || print no)"
t_assert_eq "status: beta(blocked) 가 alpha(working) 보다 먼저, 상태 열" "beta|blocked|alpha|working" "${${lines[3]}%% *}|$(print -r -- "${lines[3]}" | awk '{print $2}')|${${lines[4]}%% *}|$(print -r -- "${lines[4]}" | awk '{print $2}')"
t_assert_eq "시작 시 활성 탭 = alpha (첫 탭, 클라이언트 붙음)" alpha "$(_active_tab)"
out="$(_cmux jump)"; rc=$?
t_assert_eq "jump: exit 0, 출력에 beta" "0|yes" "$rc|$([[ "$out" == *beta* ]] && print yes || print no)"
t_assert_true "jump 후 활성 탭 = beta (blocked 탭으로 전환)" '[[ "$(_active_tab)" == beta ]]' 10
t_assert_true "활성 탭 beta 의 ! 도 빨간 배경 + 흰 글자 (beta 바 pane)" '[[ "$(_bang_ok "$BARB")" == ok ]]' 10
out="$(_cmux jump)"
t_assert_eq "blocked 가 현재 탭(beta) 하나뿐이면 이동하지 않고 '이미 blocked 탭입니다: beta' 한 줄" "이미 blocked 탭입니다: beta" "$out"
t_assert_true "탭 이동 없음 (활성 beta 유지)" '[[ "$(_active_tab)" == beta ]]' 10
_hookev beta "$PB" Stop
print -r -- '{"notification_type":"permission_prompt"}' | env CMUX_TAB_NAME=alpha ZELLIJ_SESSION_NAME="$T_SESSION" ZELLIJ_PANE_ID="$PA" "$STATE_BIN" hook Notification
t_assert_true "alpha 를 Notification(permission_prompt) 으로 blocked → 바에 alpha!" '[[ "$(_row1 "$BARB")" == *" alpha!"* ]]' 20
out="$(_cmux jump)"
t_assert_true "jump: beta(현재) 다음 → 끝에서 처음으로 순환해 alpha 로 전환" '[[ "$(_active_tab)" == alpha ]]' 10
_hookev alpha "$PA" Stop
out="$(_cmux jump)"; rc=$?
t_assert_eq "blocked 없음: '대기 중인 탭이 없습니다'·exit 0" "0|대기 중인 탭이 없습니다" "$rc|$out"
t_assert_eq "탭 이동 없음 (활성 alpha 유지)" alpha "$(_active_tab)"
_hookev alpha "$PA" SessionEnd
out="$(_cmux status)"
lines=("${(@f)out}")
t_assert_true "SessionEnd 로 alpha 파일 삭제 → status 에서 alpha 는 '-' (기록 없음)" '[[ "$out" =~ "alpha +- +-" ]]'

t_finish
exit $?
