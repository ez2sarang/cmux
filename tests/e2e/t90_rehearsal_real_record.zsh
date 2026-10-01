#!/usr/bin/env zsh
# t90_rehearsal_real_record — 실데이터 전체 규모 복원 리허설 (수동 실행 전용 — tests/run.zsh는 tests/e2e를 돌리지 않는다)
#   라이브 세션 'claude'를 끄고 'cmux -k'로 복원하기 전에, 같은 시나리오를 격리 세션 cmuxt<pid>에서 끝까지 돌린다.
#   실제: 탭 기록(~/.config/cmux/session-tabs의 복사본), zellij, HEAD의 cmux 설치본(임시 폴더, 원자적 배치·install과 같은
#         레이아웃 렌더링), 대화 이력(~/.claude·~/.codex·opencode 세션 목록 — 읽기만).
#   가짜: 에이전트 실행 파일(tests/bin/fake-agent, tests/bin/fake-opencode)과 collar-agents-sync(호출 기록)뿐.
#   R0 준비·오라클   R1 콜드 복원(기록 17탭, 무인자 cmux)   R2 혼재 추가(-a codex·opencode·codex)
#   R3 크래시(창 닫기 → 테스트 세션 zellij 서버만 SIGKILL)   R4 밖에서 cmux -k   R5 cmux kill → 무인자 cmux
#   R6 구버전(~/.config/cmux/backup-20261001) 롤백   R7 불변·정리(라이브 세션·실환경 무변경, 잔여 0)
# 판정 기준(오라클)은 cmux 코드와 따로 python3로 계산한다 — claude: 경로 키(논리·물리)의 *.jsonl마다 앞 30줄 안의 첫
#   entrypoint, sdk-cli가 아닌 파일이 하나라도 있으면 --continue. opencode: 실제 'opencode --pure session list'의 같은
#   directory 중 updated 최대 id. 구버전(설치본): jsonl이 하나라도 있으면 --continue.
# 선택 env
#   RH_UPTO=R1                   그 시나리오까지만 돌리고 정리 (뮤테이션 확인용)
#   RH_REV=<커밋>                설치할 리비전 (기본 HEAD — 회귀가 있던 커밋을 넣어 리허설이 잡는지 확인)
#   RH_MUTANT=sdkcli-off|sdkcli-invert   설치본 cmux-agents.zsh의 sdk-cli 판정을 없앤/뒤집은 뮤턴트
#   RH_SDKCLI_ONLY=<탭 이름>     그 프로젝트는 실제 sdk-cli 트랜스크립트만 보이는 CLAUDE_CONFIG_DIR 오버레이(심볼릭 링크)
#   T_KEEP=1                     임시 루트 보존 (실패 진단)

source "${0:A:h}/../lib/harness.zsh"

T=$'\t'
PERM="--dangerously-skip-permissions"
SAFE="-a never -s workspace-write"
TODAY="$(strftime '%Y%m%d' $EPOCHSECONDS)"
DEV="$HOME/Documents/dev/ai"
REAL_TABS="$HOME/.config/cmux/session-tabs"
REAL_EXTRAS="$HOME/.config/cmux/projects"
BACKUP="$HOME/.config/cmux/backup-20261001"
REAL_CLAUDE_CFG="$HOME/.claude"
UPTO="${RH_UPTO:-R7}"
REV="${RH_REV:-HEAD}"
typeset -a R2_SPECS=("$DEV/cmux${T}codex" "$DEV/freeOpenCode${T}opencode" "$DEV/investments${T}codex")
typeset -a ORDER=(R1 R2 R3 R4 R5 R6)
typeset -gA ORA_HIST ORA_N ORA_WHY ORA_ANY OC_SID OC_WHY ACT OKF SECS PANIC
typeset -ga PATHS SPECS20 LIVE_PIDS0
RH_T0=$EPOCHREALTIME

# ── 공용 ──────────────────────────────────────────────
# _sp <spec> → reply=(경로 에이전트) — spec = `경로` 또는 `경로<TAB>에이전트`
_sp() { if [[ "$1" == *$'\t'* ]]; then reply=("${1%$'\t'*}" "${1##*$'\t'}"); else reply=("$1" claude); fi }
# _tname <spec> → REPLY = 기대 탭 이름 (claude = basename, 그 외 basename·에이전트)
_tname() { _sp "$1"; if [[ "${reply[2]}" == claude ]]; then REPLY="${reply[1]:t}"; else REPLY="${reply[1]:t}·${reply[2]}"; fi }
_names() { local s; for s; do _tname "$s"; print -r -- "$REPLY"; done }
_upto() { [[ "$UPTO" == "$1" ]] }
_secs() { printf '%.1f' "$1" }

# 가짜 에이전트 기록 (fake-agent.log: "fake-<에이전트><TAB>cwd<TAB>인자")
_log_n() { awk 'END { print NR }' "$FAKE_AGENT_LOG" 2>/dev/null }
# _launch_since <off> [정규식=claude|codex|opencode] — off 줄 뒤 실행 수 (목록 조회 fake-opencode-list 제외)
_launch_since() { awk -F'\t' -v o="$1" -v re="^fake-(${2:-claude|codex|opencode})\$" 'NR > o && $1 ~ re { c++ } END { print c + 0 }' "$FAKE_AGENT_LOG" }
_count_since()  { _sp "$2"; awk -F'\t' -v o="$1" -v a="fake-${reply[2]}" -v d="${reply[1]}" 'NR > o && $1 == a && $2 == d { c++ } END { print c + 0 }' "$FAKE_AGENT_LOG" }
_args_since()   { _sp "$2"; awk -F'\t' -v o="$1" -v a="fake-${reply[2]}" -v d="${reply[1]}" 'NR > o && $1 == a && $2 == d { print $3 }' "$FAKE_AGENT_LOG" }

# ── 프로세스 (ps 기반) ────────────────────────────────
# 라이브 세션 서버: 명령줄 "…/zellij --server …/contract_version_1/claude"
_live_server_pids() {
  local line; local -a w
  for line in "${(@f)$(ps -axo pid=,command=)}"; do
    w=(${=line})
    [[ "${w[2]:t}" == zellij && "${w[3]}" == --server && "${w[4]:t}" == "$T_LIVE_SESSION" ]] && print -r -- "${w[1]}"
  done
}
# 테스트 세션 서버: 명령줄이 정확히 "<…/zellij> --server <T_ZJ_SOCK>"
_test_server_pids() {
  local line; local -a w
  for line in "${(@f)$(ps -axo pid=,command=)}"; do
    w=(${=line})
    (( ${#w} == 4 )) && [[ "${w[2]:t}" == zellij && "${w[3]}" == --server && "${w[4]}" == "$T_ZJ_SOCK" ]] && print -r -- "${w[1]}"
  done
}
# 다른 cmux 테스트(run.zsh·tests/*/tNN·cmuxt 서버) — 이 스크립트 자신·조상·자손은 제외
_others_running() {
  local line p n
  local -a w anc
  local -A pp
  local out="$(ps -axo pid=,ppid=,command=)"
  for line in "${(@f)out}"; do w=(${=line}); pp[${w[1]}]="${w[2]}"; done
  p=$$ n=0
  while [[ -n "$p" && "$p" != (0|1) ]] && (( n++ < 64 )); do anc+=("$p"); p="${pp[$p]}"; done
  for line in "${(@f)out}"; do
    w=(${=line})
    (( ${anc[(Ie)${w[1]}]} )) && continue
    p="${w[1]}" n=0
    while [[ -n "$p" && "$p" != (0|1|$$) ]] && (( n++ < 64 )); do p="${pp[$p]}"; done
    [[ "$p" == $$ ]] && continue
    # 실행 파일·첫 인자만 본다 (다른 프로세스의 프롬프트 텍스트 등에 경로가 들어 있어도 걸리지 않게)
    if [[ "${w[3]:t}" == zsh && "${w[4]}" == ((*/|)tests/run.zsh|*tests/(integration|unit|e2e)/t[0-9]*.zsh) ]] \
       || [[ "${w[3]:t}" == zellij && "${w[4]}" == --server && "${w[5]:t}" == cmuxt<-> ]]; then
      print -r -- "$line"
    fi
  done
}
# 테스트 서버만 SIGKILL — 세션명 cmuxt<숫자>·소켓 경로 일치·프로세스 1개·라이브 서버와 그 자손이 아님을 모두 확인한 뒤
_kill_test_server() {
  if [[ "$T_SESSION" != cmuxt<-> || "$T_SESSION" == "$T_LIVE_SESSION" || "${T_ZJ_SOCK:t}" != "$T_SESSION" ]]; then
    print -u2 -r -- "rehearsal: 안전장치 — 세션명/소켓 경로 이상 ($T_SESSION, $T_ZJ_SOCK)"
    return 1
  fi
  local -a pids live
  pids=("${(@f)$(_test_server_pids)}"); pids=("${(@)pids:#}")
  live=("${(@f)$(_live_server_pids)}" "${LIVE_PIDS0[@]}"); live=("${(@)live:#}")
  if (( ${#pids} != 1 )); then
    print -u2 -r -- "rehearsal: 안전장치 — 테스트 서버 프로세스가 ${#pids}개"
    return 1
  fi
  local a="${pids[1]}" n=0
  while [[ -n "$a" && "$a" != (0|1) ]] && (( n++ < 64 )); do
    if (( ${live[(Ie)$a]} )); then
      print -u2 -r -- "rehearsal: 안전장치 — 대상 ${pids[1]}이 라이브 서버($a) 계열"
      return 1
    fi
    a="$(ps -o ppid= -p "$a" 2>/dev/null)"; a="${a// /}"
  done
  kill -KILL "${pids[1]}"
}
# 소켓 상태: none(파일 없음) / stale(연결 거부) / live — 서버 프로세스가 없을 때만 부른다 (#5632: 초기화 중 서버 접속 금지)
_sock_state() {
  [[ -e "$T_ZJ_SOCK" ]] || { print none; return 0 }
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("live")
except ConnectionRefusedError:
    print("stale")
except OSError as e:
    print("err%d" % e.errno)' "$T_ZJ_SOCK"
}

# ── 오라클 (cmux 코드와 독립) ─────────────────────────
# _oracle_claude <설정 폴더> <경로...> → 줄마다 "경로<TAB>hist|none<TAB>jsonl 수<TAB>분포<TAB>jsonl 있음(0|1)"
_oracle_claude() {
  python3 - "$@" <<'PY'
import glob, json, os, re, sys
cfg, paths = sys.argv[1], sys.argv[2:]
rx = re.compile(r'"entrypoint"\s*:\s*"([^"\\]*)"')
def first_entrypoint(f):
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 30:
                    return None
                try:
                    o = json.loads(line)
                except ValueError:          # 쓰는 중인 마지막 줄 등 — 이스케이프되지 않은 키만
                    m = rx.search(line)
                    if m:
                        return m.group(1)
                    continue
                if isinstance(o, dict) and "entrypoint" in o:
                    return str(o["entrypoint"])
    except OSError:
        pass
    return None
for p in paths:
    keys = {re.sub(r"[^A-Za-z0-9]", "-", k) for k in (p, os.path.realpath(p))}
    files = sorted({f for k in keys for f in glob.glob(os.path.join(cfg, "projects", k, "*.jsonl"))})
    kinds = {}
    for f in files:
        e = first_entrypoint(f) or "(키없음)"
        kinds[e] = kinds.get(e, 0) + 1
    hist = any(k != "sdk-cli" for k in kinds)
    why = " ".join("%s=%d" % kv for kv in sorted(kinds.items())) or "jsonl없음"
    # 대소문자 무시 볼륨: 실제 폴더 이름이 키와 대소문자만 다르면 표시 (cmux가 정확한 이름 비교로 놓치는 경우)
    try:
        real = [n for n in os.listdir(os.path.join(cfg, "projects")) if n.lower() in {k.lower() for k in keys} and n not in keys]
    except OSError:
        real = []
    if real:
        why += " (실제 폴더 %s — 키와 대소문자 다름)" % ",".join(real)
    print("%s\t%s\t%d\t%s\t%d" % (p, "hist" if hist else "none", len(files), why, 1 if files else 0))
PY
}
# _sdkcli_files <프로젝트 키 폴더> — 앞 30줄 안 첫 entrypoint가 sdk-cli인 jsonl (오버레이용)
_sdkcli_files() {
  python3 - "$1" <<'PY'
import glob, json, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    with open(f, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= 30:
                break
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict) and "entrypoint" in o:
                if o["entrypoint"] == "sdk-cli":
                    print(f)
                break
PY
}
# _oracle_opencode <폴더> → "id<TAB>근거" (실제 opencode 읽기 전용 목록 조회, 같은 directory 중 updated 최대)
_oracle_opencode() {
  python3 - "$REAL_OPENCODE" "$1" <<'PY'
import json, os, subprocess, sys
b, d = sys.argv[1], sys.argv[2]
try:
    r = subprocess.run([b, "--pure", "session", "list", "--format", "json", "-n", "1000"], cwd=d,
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    rows = json.loads(r.stdout or b"[]")
except Exception as e:
    print("\t조회 실패 %s" % type(e).__name__)
    sys.exit(0)
want = {d, os.path.realpath(d)}
c = [s for s in rows if isinstance(s, dict) and s.get("directory") in want and s.get("id")]
c.sort(key=lambda s: s.get("updated") or 0, reverse=True)
print("%s\t목록 %d개 중 이 폴더 %d개%s" % (c[0]["id"] if c else "", len(rows), len(c),
      " · 최신 updated=%s" % c[0].get("updated") if c else ""))
PY
}
# _oracle_refresh <라벨> — claude 오라클 재계산(라이브 세션이 트랜스크립트를 계속 쓰므로 복원 직전마다). 바뀌면 알린다.
_oracle_refresh() {
  local line p changed=""
  local -a f
  for line in "${(@f)$(_oracle_claude "$CLAUDE_CONFIG_DIR" "${PATHS[@]}")}"; do
    f=("${(@ps:\t:)line}")
    p="${f[1]}"
    [[ -n "${ORA_HIST[$p]}" && "${ORA_HIST[$p]}" != "${f[2]}" ]] && changed+=" ${p:t}(${ORA_HIST[$p]}→${f[2]})"
    ORA_HIST[$p]="${f[2]}" ORA_N[$p]="${f[3]}" ORA_WHY[$p]="${f[4]}" ORA_ANY[$p]="${f[5]}"
  done
  [[ -n "$changed" ]] && print -r -- "  참고: 오라클 변화($1):$changed — 실행 시점 값으로 판정"
  return 0
}
_oracle_oc_refresh() {
  local s r
  for s in "${R2_SPECS[@]}"; do
    _sp "$s"
    [[ "${reply[2]}" == opencode ]] || continue
    r="$(_oracle_opencode "${reply[1]}")"
    OC_SID[${reply[1]}]="${r%%$'\t'*}" OC_WHY[${reply[1]}]="${r#*$'\t'}"
  done
}
# _want <spec> [old] → REPLY = 기대 argv (old: 구버전 설치본 규칙)
_want() {
  _sp "$1"
  local p="${reply[1]}"
  case "${reply[2]}" in
    claude)
      if [[ -n "$2" ]]; then [[ "${ORA_ANY[$p]}" == 1 ]] && REPLY="$PERM --continue" || REPLY="$PERM"
      else [[ "${ORA_HIST[$p]}" == hist ]] && REPLY="$PERM --continue" || REPLY="$PERM"; fi ;;
    codex)    REPLY="resume --last $SAFE" ;;
    opencode) [[ -n "${OC_SID[$p]}" ]] && REPLY="-s ${OC_SID[$p]}" || REPLY="" ;;
    *)        REPLY="?" ;;
  esac
}
# _want_banner <spec> → REPLY = 에이전트 pane 배너(부분 문자열)
_want_banner() {
  _sp "$1"
  local p="${reply[1]}"
  case "${reply[2]}" in
    claude)   [[ "${ORA_HIST[$p]}" == hist ]] && REPLY="▶ Claude Code: 이전 대화 이어서 시작 [" || REPLY="▶ Claude Code: 새로 시작" ;;
    codex)    REPLY="▶ Codex: 이전 대화 이어서 시작 [" ;;
    opencode) [[ -n "${OC_SID[$p]}" ]] && REPLY="▶ OpenCode: 이전 대화 이어서 시작 [${OC_SID[$p]}]" || REPLY="▶ OpenCode: 새로 시작" ;;
  esac
}

# ── zellij 조회 (harness.zsh 머리말 #5632 규칙: t_zj_gate 뒤에만) ──
# 에이전트 pane: "탭<TAB>pane 이름<TAB>pane id"
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
        print("\t".join(str(p.get(k)) for k in ("tab_name", "title", "id")))'
}
_pane_map() { _panes | awk -F'\t' '{ print $1 "=" $2 }' | LC_ALL=C sort }
_want_map() { local s; for s; do _tname "$s"; _sp "$s"; print -r -- "$REPLY=${reply[2]}"; done | LC_ALL=C sort }
_screen() {  # <탭 이름> — 그 탭 에이전트 pane 화면
  local id
  id="$(_panes | awk -F'\t' -v t="$1" '$1 == t { print "terminal_" $3 }')"
  [[ -n "$id" ]] || return 1
  _t_guard && t_zj_gate && zellij -s "$T_SESSION" action dump-screen -p "$id" --path "$T_ROOT/screen.txt" 2>/dev/null \
    && cat "$T_ROOT/screen.txt"
}
_assert_eventually() {  # <설명> <기대> <조회 명령(eval)> [초=20]
  local _ae_want="$2" _ae_cmd="$3" _ae_got=""
  t_wait_for '_ae_got="$(eval "$_ae_cmd")"; [[ "$_ae_got" == "$_ae_want" ]]' "${4:-20}"
  t_assert_eq "$1" "$_ae_want" "$_ae_got"
}
_assert_banner() {  # <설명> <탭 이름> <배너 부분 문자열>
  local _ab_tab="$2" _ab_want="$3" _ab_scr=""
  t_wait_for '_ab_scr="$(_screen "$_ab_tab")"; [[ "$_ab_scr" == *"$_ab_want"* ]]' 10
  t_assert_contains "$1" "$_ab_scr" "$_ab_want"
}
_close_client() {
  t_hup
  t_assert_true "클라이언트 0개" '(( $(t_client_count) == 0 ))' 10
}
_live_same() {  # <라벨> — 라이브 세션 탭 이름·순서와 서버 PID가 시작 때와 같다
  if (( ! T_LIVE_PRESENT )); then t_skip "라이브 세션 없음 ($1)"; return 0; fi
  local now
  t_zj_gate
  now="$(zellij -s "$T_LIVE_SESSION" action query-tab-names 2>/dev/null)"
  t_assert_eq "라이브 '$T_LIVE_SESSION' 탭 이름·순서 동일 ($1)" "$T_LIVE_BEFORE" "$now"
  t_assert_eq "라이브 서버 PID 동일 ($1)" "${(j: :)LIVE_PIDS0}" "${(j: :)${(@f)$(_live_server_pids)}}"
}
# _oc_list_calls <폴더> — fake-opencode가 실제 opencode로 넘긴 목록 조회(그 cwd, cmux 어댑터 인자) 수
_oc_list_calls() {
  awk -F'\t' -v d="$1" '$1 == "fake-opencode-list" && $2 == d && $3 == "--pure session list --format json -n 1000" { c++ } END { print c + 0 }' "$FAKE_AGENT_LOG"
}
_panic_mark() { PANIC[$1]=$(t_zj_panics) }
_panic_check() { PANIC[$1]=$(( $(t_zj_panics) - ${PANIC[$1]:-0} )); t_assert_eq "zellij 서버 초기화 panic(lib.rs:1462) 증가 0" 0 "${PANIC[$1]}" }

# _check_args <라벨> <off> <new|old> <spec...> — off 뒤 각 탭 정확히 1회·argv = 기대. 결과는 표용으로 ACT/OKF에.
_check_args() {
  local label="$1" off="$2" mode="$3" s got n want ok k
  local -i cont=0 perm=0 ncl=0
  shift 3
  for s in "$@"; do
    _want "$s" ${${mode:#new}:+old}; want="$REPLY"
    n=$(_count_since "$off" "$s")
    got="$(_args_since "$off" "$s")"
    _tname "$s"
    t_assert_eq "$label ${REPLY}: 1회 실행·argv" "1|$want" "$n|$got"
    [[ "$n|$got" == "1|$want" ]] && ok=1 || ok=0
    k="$label|$s"    # 첨자에 '|'를 직접 쓰면 대입이 파이프로 파싱된다 — 변수로
    ACT[$k]="${got:-(없음)}"
    (( n != 1 )) && ACT[$k]="×$n: ${(j:; :)${(f)got}}"
    OKF[$k]=$ok
    _sp "$s"
    if [[ "${reply[2]}" == claude ]]; then
      (( ncl++ ))
      [[ "$got" == *"$PERM"* ]] && (( perm++ ))
      [[ ( "$got" == *--continue* && "$want" == *--continue* ) || ( "$got" != *--continue* && "$want" != *--continue* ) ]] && (( n == 1 )) && (( cont++ ))
    fi
  done
  if (( ncl )); then
    t_assert_eq "$label claude: $PERM 포함" "$ncl/$ncl" "$perm/$ncl"
    t_assert_eq "$label claude: --continue 유무 = 오라클(${mode})" "$ncl/$ncl" "$cont/$ncl"
  fi
}
_check_banners() {  # <라벨> <spec...>
  local label="$1" s
  shift
  for s in "$@"; do
    _want_banner "$s"; local wb="$REPLY"
    _tname "$s"
    _assert_banner "$label 배너 $REPLY" "$REPLY" "$wb"
  done
}
# _wait_launches <off> <개수> <정규식> <시작 EPOCHREALTIME> → 걸린 초(시간 초과면 -1)를 REPLY에
_wait_launches() {
  local _wl_off="$1" _wl_n="$2" _wl_re="$3" _wl_t0="$4"
  if t_wait_for '(( $(_launch_since $_wl_off "$_wl_re") >= _wl_n ))' 240; then
    REPLY="$(_secs $(( EPOCHREALTIME - _wl_t0 )))"
  else
    REPLY=-1
  fi
}

# _add_tab <spec> — 살아 있는 세션에 새 창으로 'cmux -a <에이전트> <경로>' (t04 _add_tab과 같은 순서)
_add_tab() {
  local _at_spec="$1" _at_off
  _sp "$1"
  local -a _at_args=(-a "${reply[2]}" "${reply[1]}")
  _close_client
  _at_off=$(_log_n)
  t_cmux_bg 900 "${_at_args[@]}"
  t_assert_true "cmux ${_at_args[*]}: 에이전트 실행" '(( $(_count_since $_at_off "$_at_spec") >= 1 ))' 60
  t_assert_true "cmux ${_at_args[*]}: 탭 추가 백그라운드 작업 종료" '(( $(t_cmux_procs "${_at_args[@]}") == 1 ))' 30
}

# ── 실환경 상태 (R7 비교용 — 임시 루트 밖, 읽기만) ────
_real_env_state() {
  local f p
  for f in "$HOME"/.config/cmux/**/*(ND.) "$HOME"/.config/zellij/**/*(ND.) "$HOME"/.local/bin/cmux*(N); do
    print -r -- "md5 $f$T$(md5 -q -- "$f")"
  done
  print -r -- "ls ~/.config/cmux$T${(j:,:)${(@f)$(print -rl -- "$HOME"/.config/cmux/*(DN:t))}}"
  print -r -- "ls ~/.config/zellij/layouts$T${(j:,:)${(@f)$(print -rl -- "$HOME"/.config/zellij/layouts/*(DN:t))}}"
  print -r -- "ls ~/.local/bin(cmux*)$T${(j:,:)${(@f)$(print -rl -- "$HOME"/.local/bin/cmux*(DN:t))}}"
  for p in "${PATHS[@]}"; do
    print -r -- "ls $p$T${(j:,:)${(@f)$(print -rl -- "$p"/*(DN:t))}}"
    for f in "$p"/AGENTS.md "$p"/CLAUDE.md; do [[ -f "$f" ]] && print -r -- "md5 $f$T$(md5 -q -- "$f")"; done
    print -r -- "marker $p/.collar$T${(j:,:)${(@f)$(print -rl -- "$p"/.collar/(.|)restart-fresh*(DN:t))}}"
  done
  print -r -- "keys ~/.claude/projects$T$(print -rl -- "$REAL_CLAUDE_CFG"/projects/*(N/:t) | md5 -q)"
}

# ══ R0 준비 ═══════════════════════════════════════════
print -r -- "== R0 사전 점검"
busy="$(_others_running)"
if [[ -n "$busy" ]]; then
  print -r -- "다른 cmux 테스트/세션이 실행 중 — 끝난 뒤 다시 실행하세요 (zellij #5632, 순차 실행 규칙):"
  print -r -- "$busy" | cut -c1-200 | sed 's/^/  /'
  exit 3
fi
[[ -r "$REAL_TABS" ]] || { print -u2 -r -- "실제 탭 기록 없음: $REAL_TABS"; exit 3; }
PATHS=("${(@f)$(awk 'NF' "$REAL_TABS")}")
for p in "${PATHS[@]}" "${R2_SPECS[@]%%$'\t'*}"; do
  if [[ -e "$p/.collar/restart-fresh" ]]; then
    print -r -- "중단: $p/.collar/restart-fresh 마커가 있다 — launch가 실제 프로젝트 폴더에서 소비(mv)하게 된다"
    exit 4
  fi
done
# 실제 opencode (PATH를 바꾸기 전에 — 어댑터와 같은 nvm 우선 규칙)
typeset -a _oc=("$HOME"/.nvm/versions/node/*/bin/opencode(N-*om[1]))
REAL_OPENCODE="${_oc[1]:-$(command -v opencode 2>/dev/null)}"
LIVE_PIDS0=("${(@f)$(_live_server_pids)}"); LIVE_PIDS0=("${(@)LIVE_PIDS0:#}")
REAL_STATE0="$(_real_env_state)"

t_live_snapshot
t_setup
print -r -- "라이브 서버 PID: ${LIVE_PIDS0[*]:-없음}  실제 opencode: ${REAL_OPENCODE:-없음}"

# 설치 환경 재현: 대상 리비전(RH_REV, 기본 HEAD)의 bin/* → 임시 설치 폴더 (같은 폴더 tmp → mv, 원자적)
INST="$T_ROOT/install"
mkdir -p "$INST"
for f in cmux cmux-agents.zsh cmux-picker cmux-bar; do
  git -C "$T_REPO" show "$REV:bin/$f" > "$INST/.$f.tmp.$$" || { print -u2 "git show $REV:bin/$f 실패"; exit 1; }
  if [[ "$f" == cmux-agents.zsh && -n "$RH_MUTANT" ]]; then
    case "$RH_MUTANT" in
      sdkcli-off)    sed -i '' 's|if (\$0 !~ /"sdk-cli"\$/) { found = 1; exit }|found = 1; exit|' "$INST/.$f.tmp.$$" ;;
      sdkcli-invert) sed -i '' 's|if (\$0 !~ /"sdk-cli"\$/)|if ($0 ~ /"sdk-cli"$/)|' "$INST/.$f.tmp.$$" ;;
      *) print -u2 "RH_MUTANT 값: sdkcli-off | sdkcli-invert"; exit 1 ;;
    esac
    if git -C "$T_REPO" show "$REV:bin/$f" | cmp -s - "$INST/.$f.tmp.$$" || ! zsh -n "$INST/.$f.tmp.$$"; then
      print -u2 "뮤턴트 적용 실패 ($RH_MUTANT)"; exit 1
    fi
    print -r -- "뮤턴트 $RH_MUTANT:"
    git -C "$T_REPO" show "$REV:bin/$f" | diff - "$INST/.$f.tmp.$$" | sed 's/^/  /'
  fi
  [[ "$f" == cmux-agents.zsh ]] && chmod 644 "$INST/.$f.tmp.$$" || chmod 755 "$INST/.$f.tmp.$$"
  mv -f -- "$INST/.$f.tmp.$$" "$INST/$f"
done
CMUX_UNDER_TEST="$INST/cmux"
print -r -- "대상 교체 → 임시 설치본: $CMUX_UNDER_TEST ($REV = $(git -C "$T_REPO" rev-parse --short "$REV")${RH_MUTANT:+, 뮤턴트 $RH_MUTANT})"
# 레이아웃: install과 같은 sed 규칙·순서 (CMUX_BAR_BIN → 설치본 cmux-bar, CMUX_BIN → 설치본 cmux)
for tmpl in ${(f)"$(git -C "$T_REPO" ls-tree --name-only "$REV" zellij/layouts/ | grep '\.kdl\.tmpl$')"}; do
  git -C "$T_REPO" show "$REV:$tmpl" \
    | sed -e "s|CMUX_BAR_BIN|$INST/cmux-bar|g" -e "s|CMUX_BIN|$INST/cmux|g" > "$CMUX_LAYOUTS_DIR/${${tmpl:t}%.tmpl}"
done
unset CMUX_BAR_BIN    # 설치본처럼 cmux 옆의 cmux-bar를 찾게 (picker는 대화형이라 harness 스텁 유지 — 호출 0 확인)
# 실제 데이터 (읽기만)
cp -p -- "$REAL_TABS" "$CMUX_TABS_FILE"
[[ -f "$REAL_EXTRAS" ]] && cp -p -- "$REAL_EXTRAS" "$CMUX_EXTRAS_FILE"
REC0="$(cat "$CMUX_TABS_FILE")"
export CMUX_ROOT="$DEV"
export CLAUDE_CONFIG_DIR="$REAL_CLAUDE_CFG"
unset CODEX_HOME
export CMUX_OPENCODE_BIN="$T_REPO/tests/bin/fake-opencode"
export FAKE_OPENCODE_REAL_BIN="$REAL_OPENCODE"
# PATH 맨 앞: collar-agents-sync(실제는 프로젝트 AGENTS.md를 쓴다) → 호출 기록만, 실제 에이전트 이름 → 호출되면 기록 후 실패
mkdir -p "$T_ROOT/fakepath"
print -r -- $'#!/bin/sh\nprintf "%s\\t%s\\n" "$PWD" "$*" >> "'"$T_ROOT"$'/sync-calls"\nexit 0' > "$T_ROOT/fakepath/collar-agents-sync"
for a in claude codex opencode gemini; do
  print -r -- $'#!/bin/sh\nprintf "%s\\t%s\\t%s\\n" "$(basename "$0")" "$PWD" "$*" >> "'"$T_ROOT"$'/unexpected-calls"\nexit 1' > "$T_ROOT/fakepath/$a"
done
chmod +x "$T_ROOT"/fakepath/*
export PATH="$T_ROOT/fakepath:$PATH"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"

# 오버레이: 지정한 프로젝트는 실제 sdk-cli 트랜스크립트만 보이게 (나머지는 실제 폴더 링크) — 심볼릭 링크만, 실제 파일 무변경
if [[ -n "$RH_SDKCLI_ONLY" ]]; then
  OV="$T_ROOT/claude-overlay"
  mkdir -p "$OV/projects"
  ov_linked=0
  typeset -aU ov_keys
  for p in "${PATHS[@]}"; do
    ov_keys=("${p//[^A-Za-z0-9]/-}" "${${p:A}//[^A-Za-z0-9]/-}")
    for key in "${ov_keys[@]}"; do
      src="$REAL_CLAUDE_CFG/projects/$key"
      [[ -d "$src" && ! -e "$OV/projects/$key" ]] || continue
      if [[ "${p:t}" == "$RH_SDKCLI_ONLY" ]]; then
        mkdir -p "$OV/projects/$key"
        for f in ${(f)"$(_sdkcli_files "$src")"}; do ln -s "$f" "$OV/projects/$key/${f:t}" && (( ov_linked++ )); done
      else
        ln -s "$src" "$OV/projects/$key"
      fi
    done
  done
  (( ov_linked )) || { print -u2 "오버레이: $RH_SDKCLI_ONLY 의 sdk-cli 트랜스크립트 없음"; exit 1; }
  export CLAUDE_CONFIG_DIR="$OV"
  print -r -- "오버레이: $RH_SDKCLI_ONLY 는 실제 sdk-cli jsonl ${ov_linked}개만 보임 (CLAUDE_CONFIG_DIR=$OV)"
fi

t_scenario R0 "준비 — 실제 기록 복사·설치본·오라클"
t_assert_eq "다른 cmux 테스트 실행 없음" "" "$busy"
t_assert_eq "기록 경로 ${#PATHS}개 모두 존재 (없는 경로 목록)" "" "$(for p in "${PATHS[@]}"; do [[ -d "$p" ]] || print -r -- "$p"; done)"
t_assert_true "R2 대상 3개가 기록에 있음" '(( ${PATHS[(Ie)$DEV/cmux]} && ${PATHS[(Ie)$DEV/freeOpenCode]} && ${PATHS[(Ie)$DEV/investments]} ))'
t_assert_true "실제 opencode 실행 파일 (가짜 아님)" '[[ -x "$REAL_OPENCODE" && "${REAL_OPENCODE:A}" != "$T_REPO"/* ]]'
for f in cmux cmux-agents.zsh cmux-picker cmux-bar; do
  if [[ -n "$RH_MUTANT" && "$f" == cmux-agents.zsh ]]; then
    t_assert_true "설치본 $f = 뮤턴트 $RH_MUTANT ($REV와 다름)" \
      '[[ "$(git -C "$T_REPO" rev-parse "$REV:bin/cmux-agents.zsh")" != "$(git hash-object "$INST/cmux-agents.zsh")" ]]'
  else
    t_assert_eq "설치본 $f = $REV" "$(git -C "$T_REPO" rev-parse "$REV:bin/$f")" "$(git hash-object "$INST/$f")"
  fi
done
t_assert_true "레이아웃 렌더링 (설치본 경로)" 'grep -qF "command \"$INST/cmux\"" "$CMUX_LAYOUTS_DIR/claude-tab.kdl" && grep -qF "$INST/cmux-bar" "$CMUX_LAYOUTS_DIR/claude-tab.kdl"'
t_assert_eq "테스트 세션 없음 (서버 프로세스·소켓)" "|none" "$(_test_server_pids)|$(_sock_state)"
_oracle_refresh R0
_oracle_oc_refresh
SPECS20=("${PATHS[@]}" "${R2_SPECS[@]}")
NAMES17="$(_names "${PATHS[@]}")"
NAMES20="$(_names "${SPECS20[@]}")"
typeset -a ora_h=("${(@M)${(@v)ORA_HIST}:#hist}")
print -r -- "오라클: claude 이력 있음 ${#ora_h}/${#PATHS} · opencode(freeOpenCode) id='${OC_SID[$DEV/freeOpenCode]}' (${OC_WHY[$DEV/freeOpenCode]})"
_live_same R0

# ══ R1 콜드 복원 ══════════════════════════════════════
_r1() {
  t_scenario R1 "콜드 복원 — 세션 없음 + 실제 기록 ${#PATHS}탭, 무인자 cmux"
  _panic_mark R1
  local off=$(_log_n) t0=$EPOCHREALTIME
  t_cmux_bg 900
  _wait_launches $off ${#PATHS} claude $t0; SECS[R1]="$REPLY"
  t_assert_true "${#PATHS}탭 claude 실행 완료 (${SECS[R1]}초)" '[[ "${SECS[R1]}" != -1 ]]'
  _assert_eventually "탭 ${#PATHS}개 이름·순서 = 기록" "$NAMES17" t_tab_names 30
  _check_args R1 $off new "${PATHS[@]}"
  t_assert_eq "비-claude 실행 없음" 0 "$(_launch_since $off 'codex|opencode')"
  t_assert_true "가짜 에이전트 프로세스 ${#PATHS}개" '(( $(t_agent_procs) == ${#PATHS} ))' 10
  _assert_eventually "탭별 에이전트 pane" "$(_want_map "${PATHS[@]}")" _pane_map
  t_assert_eq "기록 재기록 = 원본과 같음 (claude 평문 ${#PATHS}줄)" "$REC0" "$(t_tabs_file)"
  REC_R1="$(t_tabs_file)"
  t_assert_true "claude만 → .bak 없음" '[[ -z "$(print -l -- "$CMUX_TABS_FILE".bak-*(N))" ]]'
  t_assert_contains "복원 안내문" "$(cat "$T_LAST_LOG")" "이전 세션 복원: ${#PATHS}개 탭"
  t_assert_true "picker 미호출" '[[ ! -e "$T_ROOT/picker-calls" ]]'
  _panic_check R1
  _live_same "R1 뒤"
}

# ══ R2 혼재 추가 ══════════════════════════════════════
_r2() {
  t_scenario R2 "혼재 추가 — 살아 있는 세션에 cmux -a codex/opencode/codex"
  _panic_mark R2
  _oracle_oc_refresh
  local off=$(_log_n) s
  for s in "${R2_SPECS[@]}"; do _add_tab "$s"; done
  _assert_eventually "탭 ${#SPECS20}개 이름·순서" "$NAMES20" t_tab_names 30
  _check_args R2 $off new "${R2_SPECS[@]}"
  t_assert_eq "기존 ${#PATHS}탭 claude 재실행 없음" 0 "$(_launch_since $off claude)"
  t_assert_eq "기록 = claude ${#PATHS}줄(평문) + 비-claude 3줄(TAB)" "$REC0"$'\n'"${(F)R2_SPECS}" "$(t_tabs_file)"
  t_assert_eq "기록 TAB 줄 3개" 3 "$(grep -c $'\t' "$CMUX_TABS_FILE")"
  t_assert_eq ".bak-<오늘> 1개 = 직전 구포맷 기록" "1|$REC0" \
    "$(print -l -- "$CMUX_TABS_FILE".bak-*(N) | grep -c .)|$(cat "$CMUX_TABS_FILE.bak-$TODAY" 2>/dev/null)"
  t_assert_eq "collar-agents-sync(가짜) 호출 = 비-claude 3탭 폴더" \
    "$(for s in "${R2_SPECS[@]}"; do _sp "$s"; print -r -- "${reply[1]}$T${reply[1]}"; done)" "$(cat "$T_ROOT/sync-calls" 2>/dev/null)"
  t_assert_true "opencode 세션 목록 조회 → 실제 opencode 위임 (freeOpenCode)" '(( $(_oc_list_calls "$DEV/freeOpenCode") >= 1 ))'
  _check_banners R2 "${R2_SPECS[@]}"
  _panic_check R2
  _live_same "R2 뒤"
}

# ══ R3 크래시 ═════════════════════════════════════════
_r3() {
  t_scenario R3 "크래시 — 창 닫기(HUP) 뒤 테스트 세션 zellij 서버만 SIGKILL"
  _panic_mark R3
  REC_R2="$(t_tabs_file)"
  _close_client
  _live_same "R3 전"    # 크래시 뒤에는 zellij CLI를 부르지 않는다 (list-sessions가 죽은 소켓을 치워 -k의 출발 상태가 바뀐다)
  local -a pids=("${(@f)$(_test_server_pids)}"); pids=("${(@)pids:#}")
  t_assert_eq "테스트 서버 프로세스 1개 (명령줄 '…/zellij --server $T_ZJ_SOCK')" 1 "${#pids}"
  _kill_test_server; local krc=$?
  t_assert_eq "SIGKILL 전송 (가드 통과)" 0 "$krc"
  t_assert_true "테스트 서버 프로세스 소멸 (ps)" '[[ -z "$(_test_server_pids)" ]]' 10
  t_assert_true "가짜 에이전트 0 (pane 프로세스도 종료)" '(( $(t_agent_procs) == 0 ))' 15
  R3_SOCK="$(_sock_state)"
  t_assert_true "소켓: 없음 또는 죽은 소켓(stale) — SIGKILL은 소켓 파일을 못 지운다 (실제 '$R3_SOCK')" '[[ "$R3_SOCK" == (none|stale) ]]'
  t_assert_eq "기록 그대로 (크래시 시점엔 동기화 없음)" "$REC_R2" "$(t_tabs_file)"
  t_assert_eq "라이브 서버 PID 동일 (R3)" "${(j: :)LIVE_PIDS0}" "${(j: :)${(@f)$(_live_server_pids)}}"
  _panic_check R3
}

# ══ R4 cmux -k ════════════════════════════════════════
_r4() {
  t_scenario R4 "밖에서 cmux -k → ${#SPECS20}탭 복원"
  _panic_mark R4
  _oracle_refresh R4
  _oracle_oc_refresh
  local off=$(_log_n) t0=$EPOCHREALTIME
  t_cmux_bg 900 -k
  _wait_launches $off ${#SPECS20} 'claude|codex|opencode' $t0; SECS[R4]="$REPLY"
  t_assert_true "${#SPECS20}탭 에이전트 실행 완료 (${SECS[R4]}초)" '[[ "${SECS[R4]}" != -1 ]]'
  _assert_eventually "탭 ${#SPECS20}개 복원 (이름·순서)" "$NAMES20" t_tab_names 30
  _check_args R4 $off new "${SPECS20[@]}"
  t_assert_true "가짜 에이전트 프로세스 ${#SPECS20}개" '(( $(t_agent_procs) == ${#SPECS20} ))' 10
  _assert_eventually "탭별 에이전트 pane" "$(_want_map "${SPECS20[@]}")" _pane_map
  t_assert_eq "기록 불변" "$REC_R2" "$(t_tabs_file)"
  t_assert_eq ".bak 1개 그대로" "1|$REC0" "$(print -l -- "$CMUX_TABS_FILE".bak-*(N) | grep -c .)|$(cat "$CMUX_TABS_FILE.bak-$TODAY" 2>/dev/null)"
  t_assert_contains "복원 안내문" "$(cat "$T_LAST_LOG")" "이전 세션 복원: ${#SPECS20}개 탭 (에이전트 대화 이어서)"
  t_assert_eq "-k 터미널이 새 클라이언트" 1 "$(t_client_count)"
  t_assert_true "새 서버 가동 (프로세스 + 소켓)" '[[ -n "$(_test_server_pids)" && -S "$T_ZJ_SOCK" ]]'
  t_assert_eq "collar-agents-sync 누적 6회 (R2 3 + R4 3)" 6 "$(grep -c '' "$T_ROOT/sync-calls" 2>/dev/null)"
  _check_banners R4 "${SPECS20[@]}"
  _panic_check R4
  _live_same "R4 뒤"
}

# ══ R5 kill → 무인자 cmux ═════════════════════════════
_r5() {
  t_scenario R5 "cmux kill → 기록 보존 → 무인자 cmux 복원"
  _panic_mark R5
  _close_client
  t_cmux 60 kill
  t_assert_eq "cmux kill 종료코드 0" "0" "$T_LAST_RC"
  t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 15
  t_assert_eq "기록 보존 (동기화 = 같은 내용)" "$REC_R2" "$(t_tabs_file)"
  _oracle_refresh R5
  _oracle_oc_refresh
  local off=$(_log_n) t0=$EPOCHREALTIME
  t_cmux_bg 900
  _wait_launches $off ${#SPECS20} 'claude|codex|opencode' $t0; SECS[R5]="$REPLY"
  t_assert_true "${#SPECS20}탭 에이전트 실행 완료 (${SECS[R5]}초)" '[[ "${SECS[R5]}" != -1 ]]'
  _assert_eventually "탭 ${#SPECS20}개 복원 (이름·순서)" "$NAMES20" t_tab_names 30
  _check_args R5 $off new "${SPECS20[@]}"
  _assert_eventually "탭별 에이전트 pane" "$(_want_map "${SPECS20[@]}")" _pane_map
  t_assert_eq "기록 불변" "$REC_R2" "$(t_tabs_file)"
  t_assert_true "picker 미호출" '[[ ! -e "$T_ROOT/picker-calls" ]]'
  _check_banners R5 "${SPECS20[@]}"
  _panic_check R5
  _live_same "R5 뒤"
}

# ══ R6 구버전 롤백 ════════════════════════════════════
_r6() {
  OLD="$T_ROOT/old/cmux"
  mkdir -p "${OLD:h}"
  local f
  for f in cmux cmux-bar cmux-picker; do
    cp -p -- "$BACKUP/$f" "${OLD:h}/.$f.tmp.$$" && mv -f -- "${OLD:h}/.$f.tmp.$$" "${OLD:h}/$f"
  done
  t_scenario R6 "구버전(설치본 백업) 롤백 — 혼재 기록에서 claude ${#PATHS}탭만"
  _panic_mark R6
  t_assert_eq "구버전 = 지금 설치본 cmux (md5)" "$(md5 -q "$HOME/.local/bin/cmux")" "$(md5 -q "$OLD")"
  t_assert_true "구버전 옆에 어댑터 없음" '[[ ! -e "${OLD:h}/cmux-agents.zsh" ]]'
  _close_client
  t_cmux 60 kill
  t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 15
  _oracle_refresh R6
  local off=$(_log_n) t0=$EPOCHREALTIME
  CMUX_UNDER_TEST="$OLD" t_cmux_bg 900
  _wait_launches $off ${#PATHS} claude $t0; SECS[R6]="$REPLY"
  t_assert_true "구버전: claude ${#PATHS}탭 실행 (${SECS[R6]}초)" '[[ "${SECS[R6]}" != -1 ]]'
  _assert_eventually "탭 = claude ${#PATHS}개 (비-claude 3탭만 빠짐)" "$NAMES17" t_tab_names 30
  _check_args R6 $off old "${PATHS[@]}"
  t_assert_eq "비-claude 실행 0 (알려진 한계)" 0 "$(_launch_since $off 'codex|opencode')"
  t_assert_eq "구버전이 다시 쓴 기록 = claude ${#PATHS}줄 (TAB 3줄 손실 — 알려진 한계)" "$REC0" "$(t_tabs_file)"
  t_assert_eq ".bak 보존" "$REC0" "$(cat "$CMUX_TABS_FILE.bak-$TODAY" 2>/dev/null)"

  t_scenario R6b "구버전 — 새 버전이 쓴 claude 전용 기록(R1)을 그대로 복원"
  _close_client
  CMUX_UNDER_TEST="$OLD" t_cmux 60 kill
  t_assert_true "세션 없음·에이전트 0" 't_session_gone && (( $(t_agent_procs) == 0 ))' 15
  print -r -- "$REC_R1" > "$CMUX_TABS_FILE"
  off=$(_log_n) t0=$EPOCHREALTIME
  CMUX_UNDER_TEST="$OLD" t_cmux_bg 900
  _wait_launches $off ${#PATHS} claude $t0; SECS[R6b]="$REPLY"
  t_assert_true "구버전: claude ${#PATHS}탭 실행 (${SECS[R6b]}초)" '[[ "${SECS[R6b]}" != -1 ]]'
  _assert_eventually "탭 ${#PATHS}개 (이름·순서)" "$NAMES17" t_tab_names 30
  _check_args R6b $off old "${PATHS[@]}"
  t_assert_eq "기록 그대로" "$REC_R1" "$(t_tabs_file)"
  _panic_check R6
  _live_same "R6 뒤"
}

# ══ 보고 표 ═══════════════════════════════════════════
_print_report() {
  local i=0 p s line verdict c k
  print -r -- ""
  print -r -- "== 오라클 (CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR, 앞 30줄 안 첫 entrypoint)"
  print -r -- "| # | 탭 | jsonl | entrypoint 분포 | 기대(새 버전) | 기대(구버전) |"
  print -r -- "|---|---|---|---|---|---|"
  for p in "${PATHS[@]}"; do
    (( i++ ))
    print -r -- "| $i | ${p:t} | ${ORA_N[$p]} | ${ORA_WHY[$p]} | $( [[ ${ORA_HIST[$p]} == hist ]] && print -- --continue || print -- '없음(새로)') | $( [[ ${ORA_ANY[$p]} == 1 ]] && print -- --continue || print -- '없음') |"
  done
  for s in "${R2_SPECS[@]}"; do
    _sp "$s"; [[ "${reply[2]}" == opencode ]] || continue
    print -r -- "| - | ${reply[1]:t}·opencode | - | ${OC_WHY[${reply[1]}]} | ${OC_SID[${reply[1]}]:+-s ${OC_SID[${reply[1]}]}} | - |"
  done
  print -r -- ""
  print -r -- "== 탭별 argv — 기대 / 실제 (가짜 에이전트 기록, 시나리오마다 정확히 1회)"
  print -r -- "| # | 탭 | 에이전트 | 기대 argv | R1 | R2 | R4 | R5 | 판정 |"
  print -r -- "|---|---|---|---|---|---|---|---|---|"
  i=0
  for s in "${SPECS20[@]}"; do
    (( i++ ))
    _want "$s"; local want="$REPLY"
    _tname "$s"; local tn="$REPLY"
    _sp "$s"
    verdict="일치"
    local -a cols=()
    for c in R1 R2 R4 R5; do
      k="$c|$s"
      if (( ${+ACT[$k]} )); then
        cols+=("$( [[ "${ACT[$k]}" == "${want:-(없음)}" ]] && print -- = || print -r -- "${ACT[$k]}")")
        [[ "${OKF[$k]}" == 1 ]] || verdict="**불일치**"
      else
        cols+=("-")
      fi
    done
    print -r -- "| $i | $tn | ${reply[2]} | ${want:-(없음)} | ${(j: | :)cols} | $verdict |"
  done
  print -r -- "('=' = 기대와 같음)"
  k="R6|${PATHS[1]}"
  if (( ${+ACT[$k]} )); then
    print -r -- ""
    print -r -- "== 구버전 롤백 — 기대 / 실제"
    print -r -- "| # | 탭 | 구버전 기대 | R6(혼재 기록) | R6b(새 버전 claude 기록) | 판정 |"
    print -r -- "|---|---|---|---|---|---|"
    i=0
    for s in "${PATHS[@]}"; do
      (( i++ ))
      _want "$s" old; local wo="$REPLY" k6="R6|$s" k6b="R6b|$s"
      verdict="일치"
      [[ "${OKF[$k6]}" == 1 && "${OKF[$k6b]}" == 1 ]] || verdict="**불일치**"
      print -r -- "| $i | ${s:t} | $wo | $( [[ "${ACT[$k6]}" == "$wo" ]] && print = || print -r -- "${ACT[$k6]}") | $( [[ "${ACT[$k6b]}" == "$wo" ]] && print = || print -r -- "${ACT[$k6b]}") | $verdict |"
    done
    print -r -- "| - | cmux·codex / freeOpenCode·opencode / investments·codex | 실행 없음 | 실행 0 | - | 알려진 한계 |"
  fi
  print -r -- ""
  print -r -- "== 소요 시간 (시작 → 모든 탭 에이전트 실행 기록)"
  for c in R1 R4 R5 R6 R6b; do (( ${+SECS[$c]} )) && print -r -- "  $c: ${SECS[$c]}초"; done
  print -r -- "== zellij 서버 초기화 panic(lib.rs:1462) 증가 (공유 로그)"
  for c in R1 R2 R3 R4 R5 R6; do (( ${+PANIC[$c]} )) && print -r -- "  $c: +${PANIC[$c]}"; done
  print -r -- "  R3 크래시 직후 소켓 상태: ${R3_SOCK:--}"
}

# ══ 실행 ══════════════════════════════════════════════
for sc in "${ORDER[@]}"; do
  "_${(L)sc}"
  _upto "$sc" && break
done

t_scenario R7a "정리 전 — 실제 에이전트 호출 0"
t_assert_eq "실제 claude/codex/opencode/gemini 이름 호출 없음 (PATH shim)" "" "$(cat "$T_ROOT/unexpected-calls" 2>/dev/null)"
t_assert_eq "에이전트 실행은 모두 가짜 (기록 첫 칸)" "" \
  "$(awk -F'\t' '$1 !~ /^fake-(claude|codex|opencode|opencode-list)$/' "$FAKE_AGENT_LOG")"
_print_report

t_scenario TEARDOWN "테스트 세션·프로세스·임시 루트 정리"
t_teardown
t_assert_eq "테스트 세션 제거됨 (list-sessions)" "" "$(t_session_line)"
t_assert_eq "잔여 프로세스 0 (harness)" 0 "$T_LEFTOVER_COUNT"
t_live_check

t_scenario R7 "불변 — 라이브 세션·실환경 무변경, 잔여 0"
t_assert_eq "라이브 서버 PID 동일" "${(j: :)LIVE_PIDS0}" "${(j: :)${(@f)$(_live_server_pids)}}"
# ps 출력을 먼저 받아 둔다 — awk 자신의 명령줄(-v 값)이 걸리지 않게
psout="$(ps -axo pid=,command=)"
left="$(print -r -- "$psout" | awk -v r="$T_ROOT" -v s="sleep $FAKE_AGENT_SLEEP" -v n="$T_SESSION" \
  'index($0, r) || substr($0, index($0, $2)) == s || $0 ~ (n "([^0-9]|$)")')"
t_assert_eq "잔여 프로세스 0 (ps: 임시 루트·고유 sleep·세션명)" "" "$left"
t_assert_eq "테스트 서버·소켓·session_info 없음" "||" \
  "$(_test_server_pids)|$([[ -e "$T_ZJ_SOCK" ]] && print sock)|$([[ -e "$T_ZJ_INFO" ]] && print info)"
if [[ -n "$T_KEEP" ]]; then t_skip "T_KEEP — 임시 루트 보존: $T_ROOT"
else t_assert_true "임시 루트 제거" '[[ ! -e "$T_ROOT" ]]'; fi
REAL_STATE1="$(_real_env_state)"
t_assert_eq "실환경 무변경 (~/.config/cmux·zellij, ~/.local/bin/cmux*, 프로젝트 최상위·AGENTS/CLAUDE.md·마커, ~/.claude/projects 키)" \
  "" "$(diff <(print -r -- "$REAL_STATE0") <(print -r -- "$REAL_STATE1"))"
t_assert_eq "~/.local/bin 설치본 = 백업 md5-installed.txt" \
  "$(LC_ALL=C sort "$BACKUP/md5-installed.txt" 2>/dev/null)" "$(md5 -q "$HOME"/.local/bin/{cmux,cmux-bar,cmux-picker} 2>/dev/null | LC_ALL=C sort)"
t_assert_eq "실제 탭 기록 = 백업과 같음" "$(md5 -q "$BACKUP/session-tabs")" "$(md5 -q "$REAL_TABS")"
print -r -- "  비교 항목 $(print -r -- "$REAL_STATE0" | grep -c '') 개 · 총 소요 $(_secs $(( EPOCHREALTIME - RH_T0 )))초"

t_summary
rc=$?
(( rc == 0 )) && print -r -- "ALL PASS" || print -r -- "FAILED"
exit $rc
