# cmux-agents.zsh — 에이전트 어댑터 (bin/cmux가 source 한다. 단독 실행용 아님)
#
# 어댑터 훅: 에이전트마다 _ag_<이름>_<훅> 함수. 없으면 _agent_call이 _ag_default_<훅>을 쓴다.
#   bin               실행 파일 경로 → REPLY (못 찾으면 비0)
#   perm_args <prof>  권한 인자 (auto|safe) → reply 배열
#   has_history <dir> 그 디렉토리에 이어갈 대화가 있으면 0
#   resume_args       이어하기 인자 → reply 배열
#   fresh_args        새 대화 인자 → reply 배열
#   fastfail          이 시간(초) 안에 이어하기가 비0 종료하면 새 대화로 1회 재실행 → REPLY
#   label             표시 이름 → REPLY
# install.sh도 source 하므로(set -u) 미설정 변수는 기본값 문법으로 읽는다.

# 등록된 에이전트 — 기본 에이전트는 claude
CMUX_AGENTS=(claude)

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

# ── 기본 구현 ─────────────────────────────────────────
# 환경변수 CMUX_<이름>_BIN → PATH
_ag_default_bin() {
  local var="CMUX_${(U)1}_BIN"
  REPLY="${(P)var:-}"
  [[ -z "$REPLY" ]] && REPLY="$(command -v "$1" 2>/dev/null)"
  [[ -n "$REPLY" ]]
}
_ag_default_perm_args()   { reply=() }
_ag_default_has_history() { return 1 }
_ag_default_resume_args() { reply=() }
_ag_default_fresh_args()  { reply=() }
_ag_default_fastfail()    { REPLY=5 }
_ag_default_label()       { REPLY="$1" }

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

# 이어갈 대화형 세션: $CLAUDE_CONFIG_DIR/projects/<경로의 [^A-Za-z0-9]→-> /*.jsonl (논리·물리 경로 키 둘 다)
# sdk-cli 세션만 있는 폴더에서 'claude --continue'는 "No conversation found to continue"로
# rc=1 즉시 종료하므로 'claude -p' 요약 세션(collar-compact 등, entrypoint=sdk-cli)은 이력으로 치지 않는다.
# 판정은 파일마다 앞 30줄 안의 첫 "entrypoint" 키 — sdk-cli면 요약 세션. 키가 없거나 못 읽는 파일은 이력으로 본다.
# 파일 수와 무관하게 프로세스는 grep·awk 둘: grep이 파일마다 첫 실제 키를 "경로:줄:키"로 내고(본문 속
# \"entrypoint\"는 따옴표가 이스케이프돼 안 맞는다), awk가 최신 파일부터 보다 요약 세션이 아닌 파일을 처음 만나면 멈춘다.
# (awk 단독은 긴 첫 줄 때문에 sdk-cli 1000개에 ~0.4초 — grep은 ~0.17초)
_ag_claude_has_history() {
  local dir="${1:-$PWD}"
  local cfg="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  local -aU keys=("${dir//[^A-Za-z0-9]/-}" "${${dir:A}//[^A-Za-z0-9]/-}")
  local -a files=()
  local k
  for k in "${keys[@]}"; do
    files+=("$cfg/projects/$k"/*.jsonl(Nom))
  done
  (( ${#files} )) || return 1
  print -rN -- "${files[@]}" \
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
        END { exit !(found || i <= n) }' 3<<< "${(F)files}"
}

_ag_claude_resume_args() { reply=(--continue) }
# fresh_args: 기본 구현(인자 없음)
_ag_claude_fastfail()    { REPLY=5 }
