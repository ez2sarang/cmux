#!/usr/bin/env zsh
# t07_agent_state — 탭별 에이전트 상태 배지·cmux status/jump 의 zsh 쪽 단위 시험 (zellij 세션 없음, 실제 에이전트 없음)
#   H 훅 이벤트 → 상태 매핑 (AskUserQuestion·Notification 종류 포함) · 출력 없음/exit 0 · stdin 소비
#   E 환경변수 누락·이상 값 → 아무것도 안 함
#   A 원자적 쓰기 (rename 교체·임시 파일 잔여 없음) · 파일 형식
#   S SessionStart 정리 · SessionEnd 삭제
#   R 롤업 우선순위 · stale(working 300초) · 12시간 무시 · 이상한 파일 무시 · 특수문자 탭 이름
#   P bin/cmux-bar 의 read_agent_states 와 cmux-agent-state rollup 이 같은 결과를 낸다 (두 구현 대조)
#   L _launch_agent — CMUX_TAB_NAME export · claude만 --settings(resume·fresh·fastfail 재실행) · 끄기/실행 파일 없음이면 argv 그대로 · 경로 인용
#   J cmux status / cmux jump (PATH의 가짜 zellij — list-tabs JSON을 돌려주고 go-to-tab-by-id 호출을 기록)
# 훅은 합성 JSON을 stdin으로 넣어 시험한다. 실제 claude·codex·zellij·사용자 홈은 건드리지 않는다.

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

mkdir -p "$U_TMP"/{home,bin,zdotdir,p,cfg}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs" CMUX_CONFIG_FILE="$U_TMP/cfg/config"
export CMUX_AGENT_ARGS_FILE="$U_TMP/cfg/agent-args" CMUX_PROJECT_AGENTS_FILE="$U_TMP/cfg/project-agents" CMUX_EXTRAS_FILE="$U_TMP/cfg/projects"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
export CMUX_AGENT_STATE_DIR="$U_TMP/state"
unset CMUX_AGENT CMUX_DEFAULT_AGENT CMUX_CLAUDE_PERM CMUX_AGENT_STATE_BIN
STATE_BIN="${CMUX_UNDER_TEST:h}/cmux-agent-state"
BAR_BIN="${CMUX_UNDER_TEST:h}/cmux-bar"
SESS="cmuxu$$"

# PATH 맨 앞의 가짜 zellij: 호출을 기록, `list-tabs --json`은 $ZJ_TABS 파일 내용(없으면 실패), go-to-tab-by-id는 성공(ZJ_GOFAIL=1이면 실패)
ZJ_LOG="$U_TMP/zellij-calls"
cat > "$U_TMP/bin/zellij" <<EOF
#!/bin/sh
echo "\$*" >> "$ZJ_LOG"
case "\$*" in
  *"list-tabs --json"*) [ -n "\$ZJ_TABS" ] && [ -f "\$ZJ_TABS" ] && { cat "\$ZJ_TABS"; exit 0; }; exit 1 ;;
  *"go-to-tab-by-id"*) [ "\$ZJ_GOFAIL" = 1 ] && exit 1; exit 0 ;;
esac
exit 1
EOF
chmod +x "$U_TMP/bin/zellij"
export PATH="$U_TMP/bin:$PATH"

# ── 도우미 ────────────────────────────────────────────
# _hook <세션> <pane> <탭> <이벤트> [payload] — 훅 실행. 결과: HK_OUT(출력 전부) HK_RC
_hook() {
  local pl='{}'
  (( $# >= 5 )) && pl="$5"
  HK_OUT="$(print -r -- "$pl" | env CMUX_TAB_NAME="$3" ZELLIJ_SESSION_NAME="$1" ZELLIJ_PANE_ID="$2" "$STATE_BIN" hook "$4" 2>&1)"
  HK_RC=$?
}
_f() { print -r -- "$CMUX_AGENT_STATE_DIR/${1//\//_}/$2"; }                  # <세션> <pane> → 상태 파일 경로
_field() { sed -n "s/^$3=//p" "$(_f "$1" "$2")" 2>/dev/null | head -1; }     # <세션> <pane> <키> → 값
_state() { _field "$1" "$2" state; }
# _put <세션> <pane> <상태> <ts> <탭> — 상태 파일 직접 작성(고정 ts 시험용)
_put() { mkdir -p "${$(_f "$1" "$2"):h}"; print -r -- "state=$3"$'\n'"ts=$4"$'\n'"tab=$5" > "$(_f "$1" "$2")"; }
_rollup() { "$STATE_BIN" rollup "$1" 2>&1; }
_roll_state() { _rollup "$1" | awk -F'\t' -v t="$2" '$1==t {print $2}'; }       # <세션> <탭> → 롤업 상태
NOW=$EPOCHSECONDS

# ── H ─────────────────────────────────────────────────
t_scenario H "훅 이벤트 → 상태 (설계 \"상태 매핑 확정\")"
typeset -A MAP=(
  SessionStart idle  UserPromptSubmit working  PermissionRequest blocked
  PostToolUse working  PostToolUseFailure working  Stop idle  StopFailure idle
)
local ev p=1
for ev in ${(k)MAP}; do
  (( p++ ))
  _hook h1 $p alpha $ev '{"hook_event_name":"x"}'
  t_assert_eq "$ev → ${MAP[$ev]}" "${MAP[$ev]}" "$(_state h1 $p)"
  t_assert_eq "$ev: 출력 없음·exit 0" "0|" "$HK_RC|$HK_OUT"
done
_hook h1 20 alpha PreToolUse '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
t_assert_eq "PreToolUse(Bash) → working (심박)" working "$(_state h1 20)"
_hook h1 21 alpha PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}'
t_assert_eq "PreToolUse(AskUserQuestion) → blocked" blocked "$(_state h1 21)"
_hook h1 22 alpha PreToolUse '{"tool_name": "AskUserQuestion", "tool_input": {}}'
t_assert_eq "PreToolUse(AskUserQuestion, 공백 있는 JSON) → blocked" blocked "$(_state h1 22)"
_hook h1 23 alpha PreToolUse '{"tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"AskUserQuestion\""}}'
t_assert_eq "본문 속 문구(이스케이프)는 속지 않는다 → working" working "$(_state h1 23)"
_hook h1 24 alpha PreToolUse ''
t_assert_eq "PreToolUse 빈 payload → working" working "$(_state h1 24)"
_hook h1 30 alpha Notification '{"notification_type":"permission_prompt","message":"x"}'
t_assert_eq "Notification permission_prompt → blocked" blocked "$(_state h1 30)"
_hook h1 31 alpha Notification '{"message":"x","notification_type":"elicitation_dialog"}'
t_assert_eq "Notification elicitation_dialog → blocked" blocked "$(_state h1 31)"
_hook h1 32 alpha Notification '{"notification_type":"idle_prompt"}'
t_assert_eq "Notification idle_prompt → idle" idle "$(_state h1 32)"
_put h1 33 working $NOW alpha
_hook h1 33 alpha Notification '{"notification_type":"auth_success"}'
t_assert_eq "Notification 그 밖의 종류 → 상태 변경 없음 (working 유지)" working "$(_state h1 33)"
_hook h1 34 alpha Notification '{}'
t_assert_eq "Notification 종류 없음 → 파일을 만들지 않는다" "no" "$([[ -e "$(_f h1 34)" ]] && print yes || print no)"
_hook h1 35 alpha NoSuchEvent '{}'
t_assert_eq "알 수 없는 이벤트 → 파일 없음·출력 없음·exit 0" "no|0|" "$([[ -e "$(_f h1 35)" ]] && print yes || print no)|$HK_RC|$HK_OUT"
_hook h1 36 alpha Notification '{"notification_type":"permission_prompt"}'
_hook h1 36 alpha PostToolUse '{}'
t_assert_eq "blocked 뒤 PostToolUse → working (같은 pane 파일 갱신)" working "$(_state h1 36)"
_hook h1 37 alpha Stop '{}'
t_assert_eq "탭 이름·ts가 파일에 기록됨 (tab=alpha, ts는 시험 시작 이후)" "alpha|1" "$(_field h1 37 tab)|$(( $(_field h1 37 ts) >= NOW ))"
# stdin 소비: 큰 payload(300KB)에도 SIGPIPE 없이 끝난다
big="$({ printf '{"tool_name":"Bash","tool_input":{"x":"'; head -c 300000 /dev/zero | tr '\0' 'x'; printf '"}}'; } )"
HK_OUT="$({ print -r -- "$big"; print -r -- "WRITER-DONE" >&2; } 2>"$U_TMP/writer.err" | env CMUX_TAB_NAME=alpha ZELLIJ_SESSION_NAME=h1 ZELLIJ_PANE_ID=38 "$STATE_BIN" hook PreToolUse 2>&1)"
t_assert_eq "큰 payload(300KB): 작성자가 끝까지 쓰고(SIGPIPE 없음) 훅은 출력 없이 종료, 상태 working" "WRITER-DONE|working|" "$(cat "$U_TMP/writer.err")|$(_state h1 38)|$HK_OUT"
# PermissionRequest 훅은 결정 JSON을 내면 권한 흐름이 바뀐다 → 모든 이벤트에서 stdout이 비어야 한다 (위 루프의 출력 없음 단언 + 아래)
_hook h1 39 alpha PermissionRequest '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
t_assert_eq "PermissionRequest: stdout·stderr 완전히 비어 있음" "" "$HK_OUT"

# ── E ─────────────────────────────────────────────────
t_scenario E "환경변수 누락·이상 값 → 아무 출력 없이 exit 0, 파일 없음"
rm -rf "$CMUX_AGENT_STATE_DIR"
_e() { # <CMUX_TAB_NAME> <ZELLIJ_SESSION_NAME> <ZELLIJ_PANE_ID> <설명> — 변수를 비우거나 이상한 값으로
  local out rc
  out="$(print -r -- '{"tool_name":"Bash"}' | env CMUX_TAB_NAME="$1" ZELLIJ_SESSION_NAME="$2" ZELLIJ_PANE_ID="$3" "$STATE_BIN" hook PreToolUse 2>&1)"; rc=$?
  t_assert_eq "$4 → 출력 없음·exit 0" "0|" "$rc|$out"
}
_e "" sx 5 "CMUX_TAB_NAME 없음"
_e tab "" 5 "ZELLIJ_SESSION_NAME 없음"
_e tab sx "" "ZELLIJ_PANE_ID 없음"
_e tab sx abc "ZELLIJ_PANE_ID 숫자 아님"
_e tab sx "../x" "ZELLIJ_PANE_ID 경로 문자"
_e tab ".." 5 "세션 이름 .."
_e "  " sx 5 "탭 이름이 공백뿐"
t_assert_eq "env 없이 stdin을 소비하고도 아무 파일도 만들지 않음 (상태 디렉터리 자체가 없음)" "no" "$([[ -e "$CMUX_AGENT_STATE_DIR" ]] && print yes || print no)"
out="$(env -u CMUX_TAB_NAME -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID "$STATE_BIN" hook Stop </dev/null 2>&1)"; rc=$?
t_assert_eq "env 전부 없음 + 빈 stdin → 출력 없음·exit 0" "0|" "$rc|$out"
out="$(env CMUX_TAB_NAME=a ZELLIJ_SESSION_NAME=x/y ZELLIJ_PANE_ID=1 "$STATE_BIN" hook Stop </dev/null 2>&1)"
t_assert_eq "세션 이름의 / 는 _ 로 (x_y 디렉터리)" "yes" "$([[ -f "$CMUX_AGENT_STATE_DIR/x_y/1" ]] && print yes || print no)"
out="$(env CMUX_TAB_NAME=a ZELLIJ_SESSION_NAME=x ZELLIJ_PANE_ID=1 "$STATE_BIN" bogus 2>&1)"; rc=$?
t_assert_eq "알 수 없는 서브커맨드 → 사용법·exit 2" 2 "$rc"
out="$(env CMUX_TAB_NAME=a ZELLIJ_SESSION_NAME=x ZELLIJ_PANE_ID=1 "$STATE_BIN" set zzz 2>&1)"; rc=$?
t_assert_eq "set 에 이상한 상태 → exit 2·파일 없음" "2|no" "$rc|$([[ -e "$CMUX_AGENT_STATE_DIR/x/1" ]] && print yes || print no)"
env CMUX_TAB_NAME=a ZELLIJ_SESSION_NAME=x ZELLIJ_PANE_ID=1 "$STATE_BIN" set blocked
t_assert_eq "set blocked → 파일 기록" blocked "$(_state x 1)"

# ── A ─────────────────────────────────────────────────
t_scenario A "원자적 쓰기 · 파일 형식"
rm -rf "$CMUX_AGENT_STATE_DIR"
_hook a1 7 "my tab" UserPromptSubmit
ino1="$(ls -i "$(_f a1 7)" | awk '{print $1}')"
_hook a1 7 "my tab" Stop
ino2="$(ls -i "$(_f a1 7)" | awk '{print $1}')"
t_assert_eq "같은 pane 재기록은 임시 파일 rename 교체 (inode가 바뀜 — 제자리 덮어쓰기 아님)" "differ" "$([[ "$ino1" != "$ino2" ]] && print differ || print same)"
t_assert_eq "디렉터리에 임시 파일 잔여 없음 (숫자 이름 파일만)" "7" "$(ls -A "$CMUX_AGENT_STATE_DIR/a1" | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "파일 형식: state= / ts= / tab= 3줄" "state=idle|ts=<n>|tab=my tab" "$(sed -e 's/^ts=[0-9]*$/ts=<n>/' "$(_f a1 7)" | tr '\n' '|' | sed 's/|$//')"
_hook a1 8 $'line1\nline2\tx' Stop
t_assert_eq "탭 이름의 줄바꿈·TAB은 공백으로 (한 줄 형식 보호)" "line1 line2 x" "$(_field a1 8 tab)"
t_assert_eq "그 파일은 정확히 3줄" 3 "$(wc -l < "$(_f a1 8)" | tr -d ' ')"
# 읽기 쪽이 임시 파일(점 파일)을 무시한다
print -r -- "state=blocked"$'\n'"ts=$NOW"$'\n'"tab=ghost" > "$CMUX_AGENT_STATE_DIR/a1/.9.tmp.1"
t_assert_eq "롤업은 .tmp 파일을 무시" "no" "$([[ -n "$(_roll_state a1 ghost)" ]] && print yes || print no)"

# ── S ─────────────────────────────────────────────────
t_scenario S "SessionStart 정리 · SessionEnd 삭제"
rm -rf "$CMUX_AGENT_STATE_DIR"
_hook s1 80 zz Stop; _hook s1 81 zz Notification '{"notification_type":"permission_prompt"}'; _hook s1 82 other Stop
_hook s2 80 zz Stop                                      # 다른 세션의 같은 이름 탭
_hook s1 83 zz SessionStart
t_assert_eq "SessionStart: 같은 세션·같은 탭 이름의 다른 pane 파일(80,81) 삭제" "no|no" "$([[ -e "$(_f s1 80)" ]] && print yes || print no)|$([[ -e "$(_f s1 81)" ]] && print yes || print no)"
t_assert_eq "다른 탭(82)·다른 세션(s2/80)은 그대로" "yes|yes" "$([[ -e "$(_f s1 82)" ]] && print yes || print no)|$([[ -e "$(_f s2 80)" ]] && print yes || print no)"
t_assert_eq "자기 pane(83)은 idle 로 생성" idle "$(_state s1 83)"
_hook s1 83 zz UserPromptSubmit; _hook s1 83 zz SessionStart
t_assert_eq "같은 pane 의 SessionStart(/clear 등)는 자기 파일을 지우지 않고 idle 로" idle "$(_state s1 83)"
_hook s1 83 zz SessionEnd
t_assert_eq "SessionEnd: 이 pane 파일 삭제 (출력 없음·exit 0)" "no|0|" "$([[ -e "$(_f s1 83)" ]] && print yes || print no)|$HK_RC|$HK_OUT"
t_assert_eq "SessionEnd 는 다른 pane 파일을 건드리지 않음" yes "$([[ -e "$(_f s1 82)" ]] && print yes || print no)"
_hook s1 99 zz SessionEnd
t_assert_eq "없는 파일의 SessionEnd 도 조용히 exit 0" "0|" "$HK_RC|$HK_OUT"

# ── R ─────────────────────────────────────────────────
t_scenario R "롤업 — 우선순위 · stale · 12시간 무시 · 이상한 파일 · 특수 문자"
rm -rf "$CMUX_AGENT_STATE_DIR"
NOW=$EPOCHSECONDS     # 경계 시험은 ±10초 여유 (실행 중 시계가 흘러도 뒤집히지 않게)
_put r 1 working $(( NOW - 10 )) a;   _put r 2 blocked $(( NOW - 5 )) a;    _put r 3 idle $(( NOW - 1 )) a
_put r 4 working $(( NOW - 20 )) b;   _put r 5 idle $(( NOW - 1 )) b
_put r 6 idle $(( NOW - 30 )) c
_put r 7 working $(( NOW - 290 )) d
_put r 8 working $(( NOW - 310 )) e
_put r 9 working $(( NOW - 400 )) f;  _put r 10 idle $(( NOW - 2 )) f
_put r 11 blocked $(( NOW - 43200 + 100 )) g
_put r 12 blocked $(( NOW - 43200 - 100 )) h
_put r 13 working $(( NOW + 500 )) i
_put r 14 blocked $(( NOW - 3 )) 'x]*y';  _put r 15 idle $(( NOW - 3 )) '한글·codex'
_put r 16 blocked zzz bad1; _put r 17 bogus $NOW bad2; _put r 18 blocked $NOW ''
print -r -- "garbage" > "$(_f r 19)"
print -r -- "state=idle"$'\n'"ts=$NOW"$'\n'"tab=last"$'\n'"state=blocked" > "$(_f r 20)"
print -r -- "state=blocked"$'\n'"ts=$NOW"$'\n'"tab=nonnum" > "$CMUX_AGENT_STATE_DIR/r/abc"
t_assert_eq "blocked > working > idle" "blocked|working|idle" "$(_roll_state r a)|$(_roll_state r b)|$(_roll_state r c)"
t_assert_eq "working 290초 전 → working / 310초 전 → idle (300초 넘게 갱신 없으면 stale; 정확한 300초 경계는 cmux-bar 시험이 고정 시각으로 본다)" "working|idle" "$(_roll_state r d)|$(_roll_state r e)"
t_assert_eq "stale working + 최근 idle → idle" idle "$(_roll_state r f)"
t_assert_eq "11시간 전 blocked → 유지 / 12시간 넘은 blocked → 무시(탭 없음)" "blocked|no" "$(_roll_state r g)|$([[ -n "$(_roll_state r h)" ]] && print yes || print no)"
t_assert_eq "미래 ts(시계 어긋남)는 나이 0 → working" working "$(_roll_state r i)"
t_assert_eq "특수 문자·한글 탭 이름도 그대로 묶인다 (] * 한글 ·)" "blocked|idle" "$(_roll_state r 'x]*y')|$(_roll_state r '한글·codex')"
t_assert_eq "이상한 파일(ts 숫자 아님·상태 모름·탭 없음·형식 아님·파일명 숫자 아님)은 무시: 롤업 탭은 정확히 11개" 11 "$(_rollup r | grep -c .)"
t_assert_eq "무시된 파일의 탭 이름(bad1·bad2·nonnum)이 롤업에 없다" "no|no|no" \
  "$([[ -n "$(_roll_state r bad1)" ]] && print yes || print no)|$([[ -n "$(_roll_state r bad2)" ]] && print yes || print no)|$([[ -n "$(_roll_state r nonnum)" ]] && print yes || print no)"
t_assert_eq "같은 키가 두 번 나오면 마지막 줄이 이긴다 (state=idle … state=blocked → blocked)" blocked "$(_roll_state r last)"
t_assert_eq "롤업 출력 형식: 탭<TAB>상태<TAB>ts (ts = 이긴 상태 파일 중 최신)" "a|blocked|$(( NOW - 5 ))" "$(_rollup r | awk -F'\t' '$1=="a" {print $1 "|" $2 "|" $3}')"
out="$("$STATE_BIN" rollup nosuchsession 2>&1)"; rc=$?
t_assert_eq "없는 세션 rollup → 빈 출력·exit 0" "|0" "$out|$rc"
t_assert_eq "롤업은 읽기 전용: 12시간 넘은 파일을 지우지 않는다" yes "$([[ -e "$(_f r 12)" ]] && print yes || print no)"

# ── P ─────────────────────────────────────────────────
t_scenario P "두 구현 대조 — cmux-bar read_agent_states vs cmux-agent-state rollup"
_py_states() {
  python3 -I -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cb", sys.argv[1])
spec = importlib.util.spec_from_loader("cb", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
for k, v in sorted(m.read_agent_states(sys.argv[2], prune=False).items()):
    print("%s\t%s" % (k, v))' "$BAR_BIN" "$1"
}
zs="$(_rollup r | cut -f1,2 | LC_ALL=C sort)"
ps="$(_py_states r | LC_ALL=C sort)"
t_assert_eq "R 시나리오 픽스처: 두 구현의 {탭: 상태}가 완전히 같다 ($(print -r -- "$zs" | grep -c .)개 탭)" "$zs" "$ps"
t_assert_eq "대조 대상이 비어 있지 않고 4종 상태 경로(blocked/working/idle + 무시)를 모두 지났다" "yes" "$([[ "$zs" == *blocked* && "$zs" == *working* && "$zs" == *idle* ]] && print yes || print no)"
_hook p 1 'a/b' Stop; _hook p 2 'sp ace' PreToolUse '{"tool_name":"AskUserQuestion"}'
t_assert_eq "슬래시·공백 든 탭 이름·세션 'p' 대조" "$(_rollup p | cut -f1,2 | LC_ALL=C sort)" "$(_py_states p | LC_ALL=C sort)"
env CMUX_TAB_NAME=t ZELLIJ_SESSION_NAME='sl/ash' ZELLIJ_PANE_ID=1 "$STATE_BIN" set working
t_assert_eq "세션 이름의 / → _ 디렉터리 규칙도 두 구현이 같다" "$("$STATE_BIN" rollup 'sl/ash' | cut -f1,2)" "$(_py_states 'sl/ash')"

# ── L ─────────────────────────────────────────────────
t_scenario L "_launch_agent — CMUX_TAB_NAME export · claude만 --settings 훅"
export CMUX_SOURCE_ONLY=1
CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }
REC="$U_TMP/rec.log"
cat > "$U_TMP/bin/rec-agent" <<'EOF'
#!/bin/sh
# 인자(한 줄에 하나)와 CMUX_TAB_NAME 을 기록. FAKE_FAIL_ON 인자가 있으면 곧바로 exit 1
{ printf 'TAB=%s\n' "$CMUX_TAB_NAME"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; echo END; } >> "$REC"
for a in "$@"; do [ "$a" = "$FAKE_FAIL_ON" ] && exit 1; done
exit 0
EOF
chmod +x "$U_TMP/bin/rec-agent"
export REC CMUX_CLAUDE_BIN="$U_TMP/bin/rec-agent" CMUX_CODEX_BIN="$U_TMP/bin/rec-agent" CMUX_OPENCODE_BIN="$U_TMP/bin/rec-agent"
P1="$U_TMP/p/Proj"; P2="$U_TMP/p/hist"; mkdir -p "$P1" "$P2"
# P2 에는 이어갈 대화가 있다 (claude 트랜스크립트, entrypoint=cli)
hk="$CLAUDE_CONFIG_DIR/projects/${P2//[^A-Za-z0-9]/-}"; mkdir -p "$hk"
print -r -l -- '{"type":"queue-operation","operation":"enqueue"}' "{\"type\":\"user\",\"entrypoint\":\"cli\",\"cwd\":\"$P2\"}" > "$hk/s.jsonl"
_collar_agents_sync() { :; }
# _run <env 할당...> -- <dir> <agent> — 서브셸에서 실행, 기록 파일을 비운 뒤 실행
_run() { : > "$REC"; local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift; ( (( ${#e} )) && export "${e[@]}"; cd "$1" && _launch_agent "$2" >/dev/null 2>&1 ); }
# _args <n번째 실행> → ARG 줄들을 공백으로 (n번째 END 구간)
_args() { awk -v n="$1" '/^END$/ {c++; next} c==n-1 && /^ARG=/ {sub(/^ARG=/,""); print}' "$REC"; }
_tab()  { awk -v n="$1" '/^END$/ {c++; next} c==n-1 && /^TAB=/ {sub(/^TAB=/,""); print}' "$REC"; }
_runs() { grep -c '^END$' "$REC"; }

_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$STATE_BIN" -- "$P1" claude
t_assert_eq "claude 새 대화: 실행 1회, 권한 인자 + --settings <JSON> (기존 권한 인자 순서 그대로)" "1|--dangerously-skip-permissions|--settings" \
  "$(_runs)|$(_args 1 | sed -n 1p)|$(_args 1 | sed -n 2p)"
t_assert_eq "인자는 정확히 3개 (권한, --settings, JSON)" 3 "$(_args 1 | grep -c .)"
t_assert_eq "CMUX_TAB_NAME = 폴더 basename (claude)" "Proj" "$(_tab 1)"
_args 1 | sed -n 3p > "$U_TMP/settings.json"
check_json="$(python3 -I - "$U_TMP/settings.json" "$STATE_BIN" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
hooks = d["hooks"]
want = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]
ok = list(hooks) == want and list(d) == ["hooks"]
for ev in want:
    groups = hooks[ev]
    if len(groups) != 1 or list(groups[0]) != ["hooks"] or len(groups[0]["hooks"]) != 1:
        ok = False
        continue
    h = groups[0]["hooks"][0]
    ok = ok and h["type"] == "command" and h["timeout"] == 5 and "async" not in h and shlex.split(h["command"]) == [sys.argv[2], "hook", ev]
print("ok" if ok else "bad:%r" % d)
PY
)"
t_assert_eq "--settings JSON: 이벤트 10개, 각 {type:command, timeout:5, async 없음}, 명령 = <state 절대경로> hook <이벤트> (sh 인용 해석)" ok "$check_json"
# 공백·작은따옴표·백슬래시가 든 경로
SP="$U_TMP/sp ace'dir\\x"; mkdir -p "$SP"; cp "$STATE_BIN" "$SP/cmux-agent-state"; chmod +x "$SP/cmux-agent-state"
_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$SP/cmux-agent-state" -- "$P1" claude
_args 1 | sed -n 3p > "$U_TMP/settings2.json"
cmd="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"][0]["command"])' "$U_TMP/settings2.json")"
rm -rf "$CMUX_AGENT_STATE_DIR"
print -r -- '{}' | env CMUX_TAB_NAME=quoted ZELLIJ_SESSION_NAME=qs ZELLIJ_PANE_ID=4 sh -c "$cmd"
t_assert_eq "공백·'·\\ 가 든 설치 경로: JSON 명령을 sh -c 로 실제 실행하면 훅이 동작 (상태 파일 기록)" "idle|quoted" "$(_state qs 4)|$(_field qs 4 tab)"
# 이어하기 + fastfail 재실행: 두 argv 모두 --settings
_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$STATE_BIN" FAKE_FAIL_ON=--continue -- "$P2" claude
t_assert_eq "이어하기 실패 → 새 대화 재실행: 총 2회" 2 "$(_runs)"
t_assert_eq "1회차(resume): 권한 + --continue + --settings" "--dangerously-skip-permissions|--continue|--settings" "$(_args 1 | sed -n 1,3p | paste -sd'|' -)"
t_assert_eq "2회차(fresh, fastfail 재실행): 권한 + --settings (--continue 없음)" "--dangerously-skip-permissions|--settings" "$(_args 2 | sed -n 1,2p | paste -sd'|' -)"
t_assert_eq "두 실행의 --settings JSON 이 같다" "$(_args 1 | sed -n 4p)" "$(_args 2 | sed -n 3p)"
t_assert_eq "두 실행 모두 CMUX_TAB_NAME=hist" "hist|hist" "$(_tab 1)|$(_tab 2)"
_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$STATE_BIN" CMUX_CLAUDE_PERM=safe -- "$P1" claude
t_assert_eq "권한 프로파일 safe(권한 인자 없음): 인자는 --settings JSON 만 — 권한 로직은 건드리지 않는다" "--settings" "$(_args 1 | sed -n 1p)"
# 끄기·실행 파일 없음: 기존 argv 한 글자도 안 바뀐다
_run CMUX_STATE_HOOKS=0 CMUX_AGENT_STATE_BIN="$STATE_BIN" -- "$P2" claude
t_assert_eq "CMUX_STATE_HOOKS=0: argv = 권한 + --continue 그대로 (--settings 없음)" "--dangerously-skip-permissions|--continue" "$(_args 1 | paste -sd'|' -)"
t_assert_eq "CMUX_STATE_HOOKS=0 이어도 CMUX_TAB_NAME 은 export" hist "$(_tab 1)"
: > "$REC"
( CMUX_STATE_HOOKS=1; CMUX_AGENT_STATE_BIN=/nonexistent/cmux-agent-state; CMUX_SELF="$U_TMP/nowhere/cmux"; cd "$P2" && _launch_agent claude >/dev/null 2>&1 )
t_assert_eq "cmux-agent-state 실행 파일이 없으면: argv 그대로 (기존 4개 위치 모두 없음)" "--dangerously-skip-permissions|--continue" "$(_args 1 | paste -sd'|' -)"
: > "$REC"
( CMUX_STATE_HOOKS=1; CMUX_AGENT_STATE_BIN="$U_TMP/p"; cd "$P1" && CMUX_SELF="$U_TMP/nowhere/cmux" _launch_agent claude >/dev/null 2>&1 )
t_assert_eq "CMUX_AGENT_STATE_BIN 이 디렉터리(실행 불가)면 무시 (다른 위치도 없을 때 argv 그대로)" "--dangerously-skip-permissions" "$(_args 1 | paste -sd'|' -)"
# 다른 에이전트: CMUX_TAB_NAME 만, 훅(--settings) 없음
_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$STATE_BIN" -- "$P1" codex
t_assert_eq "codex: CMUX_TAB_NAME=Proj·codex, --settings 없음" "Proj·codex|0" "$(_tab 1)|$(_args 1 | grep -c -- '--settings')"
_run CMUX_STATE_HOOKS=1 CMUX_AGENT_STATE_BIN="$STATE_BIN" -- "$P1" opencode
t_assert_eq "opencode: CMUX_TAB_NAME=Proj·opencode, --settings 없음" "Proj·opencode|0" "$(_tab 1)|$(_args 1 | grep -c -- '--settings')"
unset CMUX_SOURCE_ONLY

# ── J ─────────────────────────────────────────────────
t_scenario J "cmux status / cmux jump (가짜 zellij)"
rm -rf "$CMUX_AGENT_STATE_DIR"; : > "$ZJ_LOG"
_tabs_json() { # <활성 위치(1부터, 0이면 없음)> — 탭 5개: alpha beta gamma delta 한글탭 (tab_id 10..14, position 0..4)
  local act="$1" i
  local -a names=(alpha beta gamma delta 한글탭) parts=()
  for i in {1..5}; do
    parts+=("{\"position\":$(( i - 1 )),\"name\":\"${names[i]}\",\"tab_id\":$(( i + 9 )),\"active\":$( (( i == act )) && print true || print false )}")
  done
  print -r -- "[${(j:,:)parts}]"
}
export ZJ_TABS="$U_TMP/tabs.json"
_cmux() { env CMUX_STATE_HOOKS=0 LANG=en_US.UTF-8 zsh "$CMUX_UNDER_TEST" "$@" 2>&1; }
_tabs_json 2 > "$ZJ_TABS"
_hook "$SESS" 1 alpha PermissionRequest; _hook "$SESS" 2 gamma UserPromptSubmit; _hook "$SESS" 3 delta Stop; _hook "$SESS" 4 한글탭 PermissionRequest
export CMUX_AGENT_STATE_BIN="$STATE_BIN"
out="$(_cmux status)"; rc=$?
print -r -- "$out" | sed 's/^/    | /'
lines=("${(@f)out}")
t_assert_eq "status: 종료코드 0" 0 $rc
t_assert_eq "status: 머리줄에 탭·상태·경과" yes "$([[ "${lines[1]}" == "탭"*"상태"*"경과" ]] && print yes || print no)"
t_assert_eq "status: 행 순서 blocked(탭 순서) → working → idle → 기록 없음(-)" "alpha|한글탭|gamma|delta|beta" \
  "${${lines[3]%% *}}|${${lines[4]%% *}}|${${lines[5]%% *}}|${${lines[6]%% *}}|${${lines[7]%% *}}"
t_assert_eq "status: 상태 열" "blocked|blocked|working|idle|-" "$(print -rl -- "${lines[@]:2}" | awk '{print $2}' | paste -sd'|' -)"
t_assert_eq "status: 경과 열 (N초) / 기록 없는 탭은 상태·경과 모두 -" "yes|yes" \
  "$([[ "${lines[3]}" =~ '^alpha +blocked +[0-9]+초$' ]] && print yes || print no)|$([[ "${lines[7]}" =~ '^beta +- +-$' ]] && print yes || print no)"
t_assert_eq "status: 한글(넓은 글자) 탭 이름도 열이 맞는다 (alpha 뒤 공백 3 / 한글탭 뒤 공백 2)" "yes|yes" \
  "$([[ "${lines[3]}" == "alpha   blocked "* ]] && print yes || print no)|$([[ "${lines[4]}" == "한글탭  blocked "* ]] && print yes || print no)"
t_assert_eq "status: zellij 호출은 -s <테스트 세션> action list-tabs --json 1회뿐" "-s $SESS action list-tabs --json" "$(cat "$ZJ_LOG")"

: > "$ZJ_LOG"
out="$(_cmux jump)"; rc=$?                                        # 활성 = beta(2) → 다음 blocked = 한글탭(id 14)
t_assert_eq "jump (활성 beta): 한글탭(id 14)으로 이동" "0|-s $SESS action list-tabs --json|-s $SESS action go-to-tab-by-id 14" "$rc|$(sed -n 1p "$ZJ_LOG")|$(sed -n 2p "$ZJ_LOG")"
t_assert_contains "jump: 이동한 탭 이름 1줄 출력" "$out" "한글탭"
_tabs_json 5 > "$ZJ_TABS"; : > "$ZJ_LOG"; out="$(_cmux jump)"
t_assert_eq "jump (활성 한글탭=마지막): 끝에서 처음으로 순환 → alpha(id 10)" "-s $SESS action go-to-tab-by-id 10" "$(sed -n 2p "$ZJ_LOG")"
_tabs_json 1 > "$ZJ_TABS"; : > "$ZJ_LOG"; out="$(_cmux jump)"
t_assert_eq "jump (활성 alpha): 현재 탭 다음부터 → 한글탭(id 14)" "-s $SESS action go-to-tab-by-id 14" "$(sed -n 2p "$ZJ_LOG")"
_tabs_json 0 > "$ZJ_TABS"; : > "$ZJ_LOG"; out="$(_cmux jump)"
t_assert_eq "jump (활성 표시 없음 = 클라이언트 없음): 처음부터 → alpha(id 10)" "-s $SESS action go-to-tab-by-id 10" "$(sed -n 2p "$ZJ_LOG")"
_hook "$SESS" 4 한글탭 Stop
_tabs_json 1 > "$ZJ_TABS"; : > "$ZJ_LOG"; out="$(_cmux jump)"; rc=$?
t_assert_eq "jump (blocked가 현재 탭 alpha 하나뿐): 이동하지 않고 '이미 blocked 탭입니다: alpha' 한 줄·exit 0" "0|이미 blocked 탭입니다: alpha|0" "$rc|$out|$(grep -c go-to-tab "$ZJ_LOG")"
_hook "$SESS" 1 alpha Stop; _hook "$SESS" 4 한글탭 PermissionRequest
_tabs_json 5 > "$ZJ_TABS"; : > "$ZJ_LOG"; out="$(_cmux jump)"; rc=$?
t_assert_eq "jump (blocked가 현재 탭 한글탭 하나뿐, 마지막 탭): 이동 없음·한 줄" "0|이미 blocked 탭입니다: 한글탭|0" "$rc|$out|$(grep -c go-to-tab "$ZJ_LOG")"
_hook "$SESS" 1 alpha PermissionRequest
: > "$ZJ_LOG"; out="$(_cmux jump)"
t_assert_eq "jump (현재 한글탭 + 다른 blocked alpha 있음): 기존대로 순환해 alpha(id 10)로 이동" "-s $SESS action go-to-tab-by-id 10" "$(sed -n 2p "$ZJ_LOG")"
_hook "$SESS" 4 한글탭 Stop
_hook "$SESS" 1 alpha Stop
: > "$ZJ_LOG"; out="$(_cmux jump)"; rc=$?
t_assert_eq "jump (blocked 없음): '대기 중인 탭이 없습니다' 1줄·exit 0·탭 이동 호출 없음" "0|대기 중인 탭이 없습니다|0" "$rc|$out|$(grep -c go-to-tab "$ZJ_LOG")"
_hook "$SESS" 1 alpha PermissionRequest
unset ZJ_TABS; : > "$ZJ_LOG"; out="$(_cmux jump)"; rc=$?
t_assert_eq "list-tabs 실패: exit 1·안내·탭 이동 호출 없음" "1|yes|0" "$rc|$([[ "$out" == *"탭 목록을 가져오지 못했습니다"* ]] && print yes || print no)|$(grep -c go-to-tab "$ZJ_LOG")"
out="$(_cmux status)"; rc=$?
t_assert_eq "status: list-tabs 실패 → exit 1" 1 $rc
export ZJ_TABS="$U_TMP/tabs.json" ZJ_GOFAIL=1; _tabs_json 2 > "$ZJ_TABS"
out="$(_cmux jump)"; rc=$?
t_assert_eq "go-to-tab-by-id 실패 → exit 1·안내" "1|yes" "$rc|$([[ "$out" == *"탭 이동에 실패했습니다"* ]] && print yes || print no)"
unset ZJ_GOFAIL
# 실행 파일이 없는 환경: 임시 사본(cmux + cmux-agents.zsh 만, 옆에 state 없음)을 HOME 격리로 실행
mkdir -p "$U_TMP/nostate" "$U_TMP/emptyhome"
cp "$CMUX_UNDER_TEST" "$U_TMP/nostate/cmux"; cp "${CMUX_UNDER_TEST:h}/cmux-agents.zsh" "$U_TMP/nostate/cmux-agents.zsh"
out="$(env -u CMUX_AGENT_STATE_BIN HOME="$U_TMP/emptyhome" zsh "$U_TMP/nostate/cmux" status 2>&1)"; rc=$?
t_assert_eq "status: cmux-agent-state 없음 → exit 1·안내" "1|yes" "$rc|$([[ "$out" == *"cmux-agent-state 실행 파일을 찾지 못했습니다"* ]] && print yes || print no)"
out="$(_cmux --help)"
t_assert_eq "--help 에 status·jump 한 줄씩" "yes|yes" "$([[ "$out" == *"cmux status "* ]] && print yes || print no)|$([[ "$out" == *"cmux jump "* ]] && print yes || print no)"
t_assert_eq "모든 zellij 호출이 가짜(PATH 맨 앞)였고 -s 테스트 세션만 겨냥" "0" "$(grep -vc "^-s $SESS action " "$ZJ_LOG")"

t_summary
exit $?
