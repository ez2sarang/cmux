# cmux-agents.zsh — 에이전트 어댑터 (bin/cmux가 source 한다. 단독 실행용 아님)
#
# 어댑터 훅: 에이전트마다 _ag_<이름>_<훅> 함수. 없으면 _agent_call이 _ag_default_<훅>을 쓴다.
#   bin                   실행 파일 경로 → REPLY (못 찾으면 비0)
#   default_perm          권한 프로파일 기본값(auto|safe) → REPLY. env CMUX_<이름>_PERM이 우선 (_agent_perm_profile)
#   perm_args <prof>      권한 인자 (auto|safe) → reply 배열
#   has_history <dir>     그 디렉토리에 이어갈 대화가 있으면 0 — REPLY에 배너용 짧은 설명(id·시각, 비어도 됨)
#   last_activity <dir>   그 디렉토리의 가장 최근 대화형 세션 활동 시각(epoch 초, 없으면 0) → REPLY (핸드오프 마커 유예 판정)
#   resume_args           이어하기 인자 → reply 배열
#   fresh_args            새 대화 인자 → reply 배열
#   compose <resume|fresh> <권한 인자...>  실행 인자 전체 → reply 배열 (기본: 권한 인자 + resume_args/fresh_args)
#   fastfail              이 시간(초) 안에 이어하기가 비0 종료하면 새 대화로 1회 재실행 → REPLY
#   label                 표시 이름 → REPLY
# 확장: ${CMUX_AGENTS_D:-~/.config/cmux/agents.d}/*.zsh 가 내장 정의 뒤에 source 된다 (맨 아래 _ag_load_extensions).
#   그 파일에서 CMUX_AGENTS+=(이름) 과 위 훅을 정의하면 새 에이전트가 등록된다 — 견본: doc/agents.d/grok.zsh.example
# install.sh도 source 하므로(set -u) 미설정 변수는 기본값 문법으로 읽는다.

zmodload zsh/datetime            # strftime, EPOCHSECONDS (bin/cmux의 핸드오프 마커 판정도 쓴다)
zmodload -F zsh/stat b:zstat     # zstat만 — 외부 stat 명령은 가리지 않는다

# 등록된 에이전트 — 기본 에이전트는 claude
CMUX_AGENTS=(claude codex opencode kimi)
typeset -g _CMUX_AGENTS_DIR="${${(%):-%x}:A:h}"

_agent_known() {
  [[ -n "$1" ]] && (( ${CMUX_AGENTS[(Ie)$1]} ))
}

# _agent_call <이름> <훅> [인자...]
_agent_call() {
  local name="$1" hook="$2"
  shift 2
  if (( $+functions[_ag_${name}_${hook}] )); then
    "_ag_${name}_${hook}" "$@"
  else
    "_ag_default_${hook}" "$name" "$@"
  fi
}

# _agent_perm_profile <이름> — 권한 프로파일 → REPLY. env CMUX_<이름>_PERM(auto|safe), 없으면 default_perm.
#   알 수 없는 값은 경고 1줄 후 기본값
_agent_perm_profile() {
  local var="CMUX_${(U)1}_PERM"
  _agent_call "$1" default_perm
  case "${(P)var:-}" in
    "") ;;
    auto|safe) REPLY="${(P)var}" ;;
    *) _warn "${var}='${(P)var}' — auto|safe 가 아니라 기본값(${REPLY})을 씁니다" ;;
  esac
}

# ── 공용 도우미 ───────────────────────────────────────
# _ag_search_bin <이름> <후보 경로...> — env CMUX_<이름>_BIN → 실행 가능한 첫 후보 → PATH (REPLY, 없으면 비0)
_ag_search_bin() {
  local name="$1" var="CMUX_${(U)1}_BIN" c
  shift
  REPLY="${(P)var:-}"
  [[ -n "$REPLY" ]] && return 0
  for c in "$@"; do
    [[ -f "$c" && -x "$c" ]] && { REPLY="$c"; return 0 }
  done
  REPLY="$(command -v "$name" 2>/dev/null)"
  [[ -n "$REPLY" ]]
}

# _ag_mtime <파일> — 수정 시각(epoch 초) → REPLY, 못 읽으면 0
_ag_mtime() {
  local -a m
  if zstat -A m +mtime -- "$1" 2>/dev/null; then REPLY="${m[1]}"; else REPLY=0; fi
}

# _ag_fmt_time <epoch> — 배너용 "MM-DD HH:MM" → REPLY
_ag_fmt_time() { strftime -s REPLY '%m-%d %H:%M' "$1" }

# ── 기본 구현 ─────────────────────────────────────────
# 환경변수 CMUX_<이름>_BIN → PATH
_ag_default_bin() {
  local var="CMUX_${(U)1}_BIN"
  REPLY="${(P)var:-}"
  [[ -z "$REPLY" ]] && REPLY="$(command -v "$1" 2>/dev/null)"
  [[ -n "$REPLY" ]]
}
_ag_default_default_perm()  { REPLY=auto }
_ag_default_perm_args()     { reply=() }
_ag_default_has_history()   { return 1 }
_ag_default_last_activity() { REPLY=0 }
_ag_default_resume_args()   { reply=() }
_ag_default_fresh_args()    { reply=() }
_ag_default_fastfail()      { REPLY=5 }
_ag_default_label()         { REPLY="$1" }
_ag_default_compose() {
  local name="$1" mode="$2"
  shift 2
  _agent_call "$name" "${mode}_args"
  reply=("$@" "${reply[@]}")
}

# ── claude ────────────────────────────────────────────
_ag_claude_label() { REPLY="Claude Code" }

# 바이너리 탐색: CMUX_CLAUDE_BIN 환경변수 → brew → which
_ag_claude_bin() {
  if [[ -n "${CMUX_CLAUDE_BIN:-}" ]]; then
    REPLY="$CMUX_CLAUDE_BIN"
  elif [[ -x "/opt/homebrew/bin/claude" ]]; then
    REPLY="/opt/homebrew/bin/claude"
  elif [[ -x "/usr/local/bin/claude" ]]; then
    REPLY="/usr/local/bin/claude"
  else
    REPLY="$(command -v claude 2>/dev/null)"
  fi
  [[ -n "$REPLY" ]]
}

# auto = 권한 확인 생략(현행 기본), safe = 플래그 없음
_ag_claude_perm_args() {
  if [[ "$1" == "auto" ]]; then
    reply=(--dangerously-skip-permissions)
  else
    reply=()
  fi
}

# 가장 최근 대화형 세션 파일 → REPLY (없으면 비0)
# 세션: $CLAUDE_CONFIG_DIR/projects/<경로의 [^A-Za-z0-9]→-> /*.jsonl (논리·물리 경로 키 둘 다, 합쳐서 최신순)
# sdk-cli 세션만 있는 폴더에서 'claude --continue'는 "No conversation found to continue"로
# rc=1 즉시 종료하므로 'claude -p' 요약 세션(collar-compact 등, entrypoint=sdk-cli)은 이력으로 치지 않는다.
# 판정은 파일마다 앞 30줄 안의 첫 "entrypoint" 키 — sdk-cli면 요약 세션. 키가 없거나 못 읽는 파일은 이력으로 본다.
# 파일 수와 무관하게 프로세스는 grep·awk 둘: grep이 파일마다 첫 실제 키를 "경로:줄:키"로 내고(본문 속
# \"entrypoint\"는 따옴표가 이스케이프돼 안 맞는다), awk가 최신 파일부터 보다 요약 세션이 아닌 파일을 처음 만나면 멈춘다.
# (awk 단독은 긴 첫 줄 때문에 sdk-cli 1000개에 ~0.4초 — grep은 ~0.17초)
_ag_claude_session_file() {
  local dir="${1:-$PWD}"
  local cfg="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  local -aU keys=("${dir//[^A-Za-z0-9]/-}" "${${dir:A}//[^A-Za-z0-9]/-}")
  local -a files=() m stamped=()
  local k f
  # 폴더는 키별 직접 경로로 연다 — 대소문자 무시 볼륨(APFS)에서 폴더 이름의 대소문자가 키와 달라도
  # (예: 키 …-totalviewer, 실제 폴더 …-totalViewer) OS가 찾는다. glob 대안 (a|b)는 디렉토리 목록을
  # 대소문자 구분으로 비교해 이런 폴더를 놓친다.
  if (( ${#keys} == 1 )); then
    files=("$cfg/projects/${keys[1]}"/*.jsonl(Nom))
  else
    # 논리·물리 키가 다르면 두 폴더 파일을 합쳐 mtime 최신순 (zstat은 내장 — 파일마다 fork 없음)
    for k in "${keys[@]}"; do
      for f in "$cfg/projects/$k"/*.jsonl(N); do
        zstat -A m +mtime -- "$f" 2>/dev/null || m=(0)
        stamped+=("${m[1]}"$'\t'"$f")
      done
    done
    files=("${(@)${(@On)stamped}#*$'\t'}")
  fi
  (( ${#files} )) || return 1
  REPLY="$(print -rN -- "${files[@]}" \
    | LC_ALL=C xargs -0 grep -m1 -n -o -H --line-buffered '"entrypoint"[[:space:]]*:[[:space:]]*"[^"]*"' -- 2>/dev/null \
    | LC_ALL=C awk -v list=/dev/fd/3 '
        BEGIN { while ((getline l < list) > 0) want[++n] = l; i = 1 }
        {
          match($0, /:[0-9]+:/)                                # "경로:줄:키"
          f = substr($0, 1, RSTART - 1); ln = substr($0, RSTART + 1, RLENGTH - 2) + 0
          if (f == prev) next                                  # 한 줄에 키가 둘이면 첫 것만
          prev = f
          if (f != want[i] || ln > 30) { found = 1; exit }     # 30줄 안에 키 없음 → 이력으로 본다
          if ($0 !~ /"sdk-cli"$/) { found = 1; exit }           # 첫 키가 sdk-cli가 아님 → 대화형 세션
          i++
        }
        END { if (found || i <= n) print want[i]; else exit 1 }' 3<<< "${(F)files}")"
  [[ -n "$REPLY" ]]
}

# 이어갈 대화형 세션이 있으면 0, REPLY = 그 세션의 마지막 활동 시각
_ag_claude_has_history() {
  _ag_claude_session_file "${1:-$PWD}" || return 1
  _ag_mtime "$REPLY"
  _ag_fmt_time "$REPLY"
}

# 마지막 활동 = 가장 최근 대화형 세션 파일의 mtime
_ag_claude_last_activity() {
  if _ag_claude_session_file "${1:-$PWD}"; then _ag_mtime "$REPLY"; else REPLY=0; fi
}

_ag_claude_resume_args() { reply=(--continue) }
# fresh_args: 기본 구현(인자 없음)
_ag_claude_fastfail()    { REPLY=5 }

# ── codex ─────────────────────────────────────────────
_ag_codex_label() { REPLY="Codex" }

_ag_is_wsl() {
  [[ "$OSTYPE" == linux* && -r /proc/sys/kernel/osrelease &&
     "${(L)$(</proc/sys/kernel/osrelease)}" == *microsoft* ]]
}

# Windows/Noctty → WSL: Windows npm 진입점을 사용해 업데이트 설치 정보 유지.
# macOS/Ghostty 및 일반 Linux: 기존 brew/nvm/bun/PATH 탐색 유지.
# 사용자 지정 실행 파일은 우선하되, npm 내부 codex.exe 직결만 정상 진입점으로 보정.
_ag_codex_bin() {
  if _ag_is_wsl && [[ -z "${CMUX_CODEX_BIN:-}" ||
       "${CMUX_CODEX_BIN:-}" == */node_modules/@openai/codex/*/codex.exe ]]; then
    REPLY="${_CMUX_AGENTS_DIR}/cmux-codex-windows"
    [[ -f "$REPLY" && -x "$REPLY" ]]
    return $?
  fi
  local -a nvm=("$HOME"/.nvm/versions/node/*/bin/codex(N-*om[1]))
  _ag_search_bin codex /opt/homebrew/bin/codex /usr/local/bin/codex "${nvm[@]}" "$HOME/.bun/bin/codex"
}

# 기본 safe — 가드 훅(설계 §2 ③)이 codex로 포팅되기 전까지 전면 우회를 기본으로 하지 않는다 (D6)
_ag_codex_default_perm() { REPLY=safe }
_ag_codex_perm_args() {
  if [[ "$1" == "auto" ]]; then
    reply=(--dangerously-bypass-approvals-and-sandbox)
  else
    reply=(-a never -s workspace-write)
  fi
}

# 이어하기는 codex가 판정한다(native): 'resume --last'는 cwd가 정확히 같은 대화형 세션만 고르고(exec 제외)
# 없으면 새 입력창으로 시작한다(S3 실측) → 이력 프로브 없이 항상 이어하기. '--all'(다른 폴더 세션까지)은 쓰지 않는다.
# 신규 폴더의 trust 프롬프트는 자동 처리하지 않는다(보안 결정을 cmux가 대신하지 않음 — S3).
_ag_codex_has_history() {
  _ag_codex_last_activity "${1:-$PWD}"
  if (( REPLY )); then _ag_fmt_time "$REPLY"; else REPLY="이력이 없으면 새 대화"; fi
  return 0
}
_ag_codex_resume_args() { reply=(resume --last) }
# 인자 순서: 서브커맨드 뒤에 권한 인자 — 'codex resume --last -a never -s workspace-write'
# (codex 0.159.3 실측: 'codex <권한> resume --last'도 파싱되지만 resume 서브커맨드 자신의 옵션으로 넘긴다)
_ag_codex_compose() {
  _agent_call codex "${1}_args"
  shift
  reply=("${reply[@]}" "$@")
}

# python 조각 (codex·opencode 공용): dir_matcher(d) → same(p) = 기록된 경로 p가 디렉토리 d와 같은 폴더인가.
#   정확 일치(d 또는 realpath(d))가 먼저. 아니면 폴더 이름(basename)이 대소문자 무시로 같은 기록만
#   os.path.samefile로 최종 확인한다 — 대소문자 무시 볼륨에서 대소문자만 다르게 기록된 경로(…/totalViewer vs
#   …/totalviewer)와 심볼릭 링크 경로로 기록된 것을 같은 폴더로 본다. 대소문자 구분 볼륨에선 samefile이 거짓이라
#   오탐이 없고, 이름이 다른 기록은 stat하지 않는다(목록 1000개·끊긴 볼륨에서도 빠르게).
_AG_PY_DIR_MATCHER='
import os
def dir_matcher(d):
    want = {d, os.path.realpath(d)}
    bases = {os.path.basename(w.rstrip("/")).lower() for w in want}
    def same(p):
        if not isinstance(p, str) or not p:
            return False
        if p in want:
            return True
        if os.path.basename(p.rstrip("/")).lower() not in bases:
            return False
        try:
            return os.path.samefile(p, d)
        except OSError:
            return False
    return same
'

# 마지막 활동: ${CODEX_HOME:-~/.codex}/sessions/**/rollout-*.jsonl 중 mtime 최신 40개만 본다.
# 첫 줄 session_meta의 payload.cwd가 dir와 같은 폴더(dir_matcher)이고 payload.source가 exec가 아닌 것 중 가장 최근 mtime.
# 포맷이 바뀌었거나 python3가 없으면 조용히 0.
_ag_codex_last_activity() {
  local dir="${1:-$PWD}"
  local -a files=("${CODEX_HOME:-$HOME/.codex}"/sessions/**/rollout-*.jsonl(N.om[1,40]))
  REPLY=0
  (( ${#files} )) && command -v python3 >/dev/null 2>&1 || return 0
  REPLY="$(python3 -c "$_AG_PY_DIR_MATCHER"'
import json, sys
same = dir_matcher(sys.argv[1])
for f in sys.argv[2:]:                      # mtime 최신순
    try:
        with open(f, encoding="utf-8") as fh:
            meta = json.loads(fh.readline())
        p = meta.get("payload") or {}
        if meta.get("type") == "session_meta" and same(p.get("cwd")) and p.get("source") != "exec":
            print(int(os.stat(f).st_mtime))
            break
    except Exception:
        pass
' "$dir" "${files[@]}" 2>/dev/null)"
  [[ "$REPLY" == <-> ]] || REPLY=0
}

# ── opencode ──────────────────────────────────────────
_ag_opencode_label() { REPLY="OpenCode" }

# 바이너리 탐색: CMUX_OPENCODE_BIN → nvm(가장 최근 mtime 하나) → bun → brew → /usr/local → PATH
_ag_opencode_bin() {
  local -a nvm=("$HOME"/.nvm/versions/node/*/bin/opencode(N-*om[1]))
  _ag_search_bin opencode "${nvm[@]}" "$HOME/.bun/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode
}

# 권한 플래그 없음 — 전역 설정(permission: allow)에 의존. auto/safe 모두 빈 배열 = 기본 구현

# 이어갈 세션: '<bin> --pure session list --format json -n 1000'(cwd=dir, 8초 제한)에서
# directory가 dir와 같은 폴더(dir_matcher — 정확 일치 우선, 대소문자·심볼릭 링크 차이는 samefile 확인)인 것 중
# updated(ms) 최대. 목록은 프로젝트 단위라 다른 directory가 섞인다(S4).
# 결과: _ag_opencode_sid(없으면 빈 값), _ag_opencode_updated(epoch 초, 없으면 0).
# 실패·시간 초과·파싱 오류·python3 없음은 조용히 "없음"(= 새 대화).
typeset -g _ag_opencode_sid="" _ag_opencode_updated=0
_ag_opencode_probe() {
  local dir="${1:-$PWD}" out
  _ag_opencode_sid="" _ag_opencode_updated=0
  _agent_call opencode bin || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  out="$(python3 -c "$_AG_PY_DIR_MATCHER"'
import json, subprocess, sys
b, d = sys.argv[1], sys.argv[2]
same = dir_matcher(d)
try:
    r = subprocess.run([b, "--pure", "session", "list", "--format", "json", "-n", "1000"], cwd=d,
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8)
    best = None
    for s in json.loads(r.stdout):
        u = s.get("updated")
        if s.get("id") and isinstance(u, (int, float)) and (best is None or u > best[1]) and same(s.get("directory")):
            best = (s["id"], u)
    if best:
        print(best[0], int(best[1]) // 1000)
except Exception:
    pass
' "$REPLY" "$dir" 2>/dev/null)"
  local -a f=(${=out})
  (( ${#f} == 2 )) && [[ "${f[2]}" == <-> ]] || return 1
  _ag_opencode_sid="${f[1]}" _ag_opencode_updated="${f[2]}"
}
_ag_opencode_has_history() {
  _ag_opencode_probe "${1:-$PWD}" || return 1
  REPLY="$_ag_opencode_sid"
}
_ag_opencode_last_activity() {
  _ag_opencode_probe "${1:-$PWD}"
  REPLY="$_ag_opencode_updated"
}
# 없는 id면 'opencode -s'가 rc=1로 즉시 끝난다(S4) → fastfail(기본 5초)로 새 대화 1회
_ag_opencode_resume_args() { reply=(-s "$_ag_opencode_sid") }

# ── kimi (Kimi Code CLI) ──────────────────────────────
_ag_kimi_label() { REPLY="Kimi Code" }

# 바이너리 탐색: CMUX_KIMI_BIN → ~/.kimi-code/bin/kimi(공식 설치 위치) → ~/.local/bin/kimi(심볼릭 링크) → PATH
_ag_kimi_bin() {
  _ag_search_bin kimi "$HOME/.kimi-code/bin/kimi" "$HOME/.local/bin/kimi"
}

# 기본 safe — 가드 훅이 없는 CLI는 전면 우회를 기본으로 하지 않는다 (codex와 같은 이유).
#   safe = --yolo (Ask When Needed: 일상 편집·명령은 자동, 위험 작업·질문·플랜은 확인)
#   auto = --auto (Never Ask: 전부 자동 결정, 플랜 모드의 플랜만 검토 대기)
# 'kimi --yolo --continue'·'kimi --auto --continue' 모두 인자 오류 없이 뜬다(2.4.1 실측). --prompt(비대화)와는 함께 못 쓰지만 cmux는 --prompt를 쓰지 않는다.
_ag_kimi_default_perm() { REPLY=safe }
_ag_kimi_perm_args() {
  if [[ "$1" == "auto" ]]; then
    reply=(--auto)
  else
    reply=(--yolo)
  fi
}

# 이어하기는 kimi가 판정한다(native, codex 방식) — 항상 '--continue'. 2.4.1 실측(2026-11-04, KIMI_CODE_HOME·HOME을 임시 폴더로 격리, pty,
# 로그인 전): 세션이 없는 폴더의 'kimi --continue'는 실패하지 않고 TUI가 살아서 "No sessions to continue under <폴더>; starting a
# fresh session." 한 줄을 보인 뒤 새 입력창으로 시작한다(14초 생존, 즉시 종료 없음) → opencode식 fastfail·이력 프로브 분기가 필요 없다.
#   · 처음 가는 폴더는 먼저 "Trust this folder?"가 뜬다 — cmux가 대신 답하지 않는다(codex trust 프롬프트와 같은 방침). 거기서 Exit 하면 rc=0이라
#     fastfail(rc 1~128만 재실행)에도 걸리지 않는다.
#   · 세션 저장은 ${KIMI_CODE_HOME:-~/.kimi-code}/sessions/<workDirKey>/<id>/ — 폴더 단위. 'kimi import-sessions'는 전역·무인자라 cmux가 부르지 않는다.
#   · 미확인: 로그인한 상태의 --continue 동작(세션 판정은 인증 이전이라 같다고 보지만 로그인 후 실측은 못 했다).
_ag_kimi_resume_args() { reply=(--continue) }
# fresh_args·fastfail: 기본 구현 (인자 없음 / 5초 — 'kimi' 자체가 5초 안에 오류로 죽을 때만 새 대화로 1회 재실행)

# 마지막 활동(배너 설명·핸드오프 마커 유예 판정용): 'kimi session list --cwd <dir> --json --limit 1'(8초 제한).
# --cwd는 기록된 workDir과 문자열 그대로 비교한다(실측: 심볼릭 링크 경로 /tmp/x는 못 찾고 realpath /private/tmp/x는 찾음) →
# 조회 전에 chdir해서 커널이 말하는 물리 경로(os.getcwd)를 넘긴다 — kimi가 세션을 기록할 때 쓰는 값과 같다.
# JSON 모양(2.4.1 실측): 최근 갱신순 배열 [{id, workDir, sessionDir, createdAt(ms), updatedAt(ms), archived, metadata}], 없으면 [].
# 필드명이 바뀌어도 죽지 않게 방어적으로 읽는다: 목록(또는 목록을 값으로 가진 객체)이 비어 있지 않으면 이력 있음, 시각은
# updatedAt/updated_at/updated/…를 차례로 시도하고 ms·초·ISO 문자열을 모두 받아 초로 바꾸며 못 읽으면 0.
# 결과: _ag_kimi_count(보관되지 않은 세션 수), _ag_kimi_updated(epoch 초, 없으면 0).
# 실패·시간 초과·파싱 오류·python3 없음은 조용히 "없음"(0 0).
typeset -g _ag_kimi_count=0 _ag_kimi_updated=0
_ag_kimi_probe() {
  local dir="${1:-$PWD}" out
  _ag_kimi_count=0 _ag_kimi_updated=0
  _agent_call kimi bin || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  out="$(python3 -I -c '
import json, os, subprocess, sys
from datetime import datetime, timezone
b, d = sys.argv[1], sys.argv[2]
def secs(v):
    if isinstance(v, bool):
        return 0
    if isinstance(v, str):
        s = v.strip()
        try:
            v = float(s)
        except ValueError:
            try:
                t = datetime.fromisoformat(s.replace("Z", "+00:00"))
            except ValueError:
                return 0
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            return int(t.timestamp())
    if isinstance(v, (int, float)) and v > 0:
        return int(v / 1000) if v > 1e11 else int(v)
    return 0
try:
    os.chdir(d)
    r = subprocess.run([b, "session", "list", "--cwd", os.getcwd(), "--json", "--limit", "1"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8)
    if r.returncode:
        sys.exit(0)
    data = json.loads(r.stdout)
    if isinstance(data, dict):
        data = next((v for v in data.values() if isinstance(v, list)), [])
    if not isinstance(data, list):
        sys.exit(0)
    items = [s for s in data if not (isinstance(s, dict) and s.get("archived") is True)]
    t = 0
    for s in items:
        if isinstance(s, dict):
            for k in ("updatedAt", "updated_at", "updated", "lastActiveAt", "last_active_at", "createdAt", "created_at", "created"):
                if secs(s.get(k)):
                    t = max(t, secs(s.get(k)))
                    break
    print(len(items), t)
except Exception:
    pass
' "$REPLY" "$dir" 2>/dev/null)"
  local -a f=(${=out})
  (( ${#f} == 2 )) && [[ "${f[1]}" == <-> && "${f[2]}" == <-> ]] || return 1
  _ag_kimi_count="${f[1]}" _ag_kimi_updated="${f[2]}"
}
_ag_kimi_last_activity() {
  _ag_kimi_probe "${1:-$PWD}"
  REPLY="$_ag_kimi_updated"
}
# native: 이력이 없어도 항상 0(= '--continue'로 시작, 없으면 kimi가 새 대화). 배너 설명만 프로브 결과를 쓴다.
_ag_kimi_has_history() {
  _ag_kimi_probe "${1:-$PWD}"
  if (( _ag_kimi_updated )); then
    _ag_fmt_time "$_ag_kimi_updated"
  elif (( _ag_kimi_count )); then
    REPLY="이력 있음"
  else
    REPLY="이력이 없으면 새 대화"
  fi
  return 0
}

# ── 확장점: agents.d ──────────────────────────────────
# ${CMUX_AGENTS_D:-$HOME/.config/cmux/agents.d}/*.zsh 를 위 내장 정의 뒤에 source 한다 — 새 CLI(grok 등)를 이 파일들로 붙인다.
# 파일에서 CMUX_AGENTS+=(이름) 으로 등록하고 _ag_<이름>_<훅> 함수(맨 위 목록)를 정의한다. 견본: doc/agents.d/grok.zsh.example
#   · 디렉토리나 *.zsh 가 없으면 아무 일도 하지 않는다(프로세스 생성 없음).
#   · 이름은 [a-z][a-z0-9_]* (함수·환경변수 CMUX_<이름>_BIN·탭 이름·레이아웃 파일명에 쓰이므로), 'default'는 쓸 수 없다. 어긴 이름은 경고 후 등록하지 않는다.
#   · 이미 등록된 이름(내장·앞선 파일)을 다시 등록하면 경고 후 무시한다 — 그 이름의 _ag_<이름>_* 함수도 파일을 읽기 전 상태로 되돌려 내장 어댑터를 덮어쓰지 못한다.
#   · 등록은 추가(+=)만 반영된다: CMUX_AGENTS=(…) 로 통째로 바꿔도 내장 에이전트는 사라지지 않는다.
#   · 문법 오류가 있는 파일은 `zsh -n` 으로 먼저 걸러 경고 1줄 후 통째로 건너뛴다(일부만 등록되는 일 없음) — cmux 전체가 죽지 않는다.
#   · 함수 안에서 source 되므로 파일이 상태 변수를 두려면 `typeset -g` 로 선언한다.
#   · install.sh(set -euo)도 이 파일을 source 하므로 어떤 경로로도 비0을 새게 하지 않는다.
_ag_load_extensions() {
  emulate -L zsh
  setopt extended_glob
  local dir="${CMUX_AGENTS_D:-${HOME:-}/.config/cmux/agents.d}" f n fn
  local -a files=("$dir"/*.zsh(N-.)) before added
  local -A saved
  (( ${#files} )) || return 0
  for f in "${files[@]}"; do
    if ! zsh -n -- "$f" 2>/dev/null; then
      print -u2 -r -- "! cmux: ${f} 문법 오류 — 이 에이전트 확장을 건너뜁니다"
      continue
    fi
    before=("${CMUX_AGENTS[@]}")
    saved=()
    for fn in ${(k)functions[(I)_ag_*]}; do saved[$fn]="${functions[$fn]}"; done
    source "$f"
    added=("${(@)CMUX_AGENTS[$(( ${#before} + 1 )),-1]}")
    CMUX_AGENTS=("${before[@]}")
    for n in "${added[@]}"; do
      if [[ "$n" != [a-z][a-z0-9_]# || "$n" == default ]]; then
        print -u2 -r -- "! cmux: ${f:t} — 에이전트 이름 '${n}' 은 [a-z][a-z0-9_]* 이어야 해서 등록하지 않습니다"
        continue
      fi
      if (( ${CMUX_AGENTS[(Ie)$n]} )); then
        print -u2 -r -- "! cmux: ${f:t} — 이미 등록된 에이전트 '${n}' 의 중복 등록을 무시합니다"
        for fn in ${(k)functions[(I)_ag_${n}_*]}; do
          if (( ${+saved[$fn]} )); then functions[$fn]="${saved[$fn]}"; else unfunction -- "$fn"; fi
        done
        continue
      fi
      CMUX_AGENTS+=("$n")
    done
  done
  return 0
}
_ag_load_extensions || true
