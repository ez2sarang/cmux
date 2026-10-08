#!/usr/bin/env zsh
# t05_agent_args — 에이전트 실행 인자 파일 (설계 §16) 단위 테스트 (CMUX_SOURCE_ONLY=1 source, zellij·실제 에이전트 없음)
#   R1 파일 경로 — CMUX_AGENT_ARGS_FILE / 기본값 $HOME/.config/cmux/agent-args / 파일 없음·디렉토리·빈 파일
#   R2 파서 — 공백·TAB 분리, 큰따옴표·작은따옴표·역슬래시·$'…'·빈 인자, 빈 인자 필드(인자 0개)
#   R3 확장 금지 — $(…)·백틱·$HOME·${…}·~·glob이 그 글자 그대로 (명령 미실행 증명)
#   R4 {dir} 치환 — 여러 번, 따옴표 안, 붙여 쓰기, 단독 {dir}
#   R5 무시되는 줄 — # 줄·빈 줄·필드 3개 미만·등록되지 않은 에이전트·절대경로 아닌 대상·다른 폴더·다른 에이전트·CRLF
#   R6 파싱 실패 — 닫히지 않은 따옴표·치환·끝 역슬래시·따옴표 밖 연산자 → 경고 1줄(!) + 없는 줄로 (앞 줄·* 줄로)
#   R7 매칭·우선순위 — 경로 > *(순서 무관, 합치지 않음) / 같은 대상 중복 마지막 승 / -ef(대소문자·심볼릭 링크·끝 /)
#   R8 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

# 격리: 홈·탭 기록·세션명·인자 파일. PATH 맨 앞의 가짜 zellij는 호출을 기록만 한다
mkdir -p "$U_TMP"/{home,bin,zdotdir,p}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs" CMUX_CONFIG_FILE="$U_TMP/cfg/config"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
AF="$U_TMP/agent-args"
export CMUX_AGENT_ARGS_FILE="$AF"
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
chmod +x "$U_TMP/bin/zellij"
export PATH="$U_TMP/bin:$PATH"
export CMUX_SOURCE_ONLY=1

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }

# ── 공용 도우미 ───────────────────────────────────────
T=$'\t'
P="$U_TMP/p/Proj"            # launch 폴더
Q="$U_TMP/p/other"           # 다른 폴더
mkdir -p "$P" "$Q"
# 임시 루트가 대소문자 무시 볼륨(APFS 기본)인가 — 대소문자 차이 매칭의 전제
[[ -d "$U_TMP/p/proj" ]] && U_CI=1 || U_CI=0
# _file <줄...> — 인자 파일을 그 줄들로 덮어쓴다
_file() { print -rl -- "$@" > "$AF"; }
# _ua <에이전트> <dir> — "rc=<rc> n=<개수> '인자' '인자' …" (경고 줄은 그 앞에 그대로, ANSI 색 제거)
_ua() {
  reply=()
  _agent_user_args "$1" "$2"
  local rc=$?
  (( rc )) && reply=()
  print -r -- "rc=$rc n=${#reply}${reply:+ }${(j: :)${(qq)reply[@]}}"
}
_uac() { _ua "$@" | sed $'s/\e\\[[0-9;]*m//g'; }
_q() { print -r -- "${(j: :)${(qq)@}}"; }   # 기대값: 인자들을 같은 형식으로
KIS="--cd {dir} --sandbox workspace-write --ask-for-approval on-request --add-dir /Users/ez2sarang/Documents/dev/ai/investments/data/rtbot/runs -c sandbox_workspace_write.network_access=true"

# ── R1 ────────────────────────────────────────────────
t_scenario R1 "파일 경로 — env / 기본값 / 파일 없음"
t_assert_eq "CMUX_AGENT_ARGS_FILE → AGENT_ARGS_FILE" "$AF" "$AGENT_ARGS_FILE"
t_assert_eq "env 없음 → \$HOME/.config/cmux/agent-args" "$HOME/.config/cmux/agent-args" \
  "$(unset CMUX_AGENT_ARGS_FILE; CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST"; print -r -- "$AGENT_ARGS_FILE")"
t_assert_eq "설정 파일에서 CMUX_AGENT_ARGS_FILE 지정 가능 (설정을 먼저 source)" "$U_TMP/from-config" \
  "$(unset CMUX_AGENT_ARGS_FILE; print -r -- "CMUX_AGENT_ARGS_FILE=$U_TMP/from-config" > "$U_TMP/cfg-x"
     CMUX_CONFIG_FILE="$U_TMP/cfg-x" CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST"; print -r -- "$AGENT_ARGS_FILE")"
rm -f -- "$AF"
t_assert_eq "파일 없음 → 비0·인자 없음" "rc=1 n=0" "$(_ua codex "$P")"
mkdir "$AF"
t_assert_eq "경로가 디렉토리 → 비0" "rc=1 n=0" "$(_ua codex "$P")"
rmdir "$AF"
: > "$AF"
t_assert_eq "빈 파일 → 비0" "rc=1 n=0" "$(_ua codex "$P")"
t_assert_eq "파일 없음·빈 파일 → 출력(경고) 없음" "" "$(rm -f -- "$AF"; _agent_user_args codex "$P")"

# ── R2 ────────────────────────────────────────────────
t_scenario R2 "파서 — 단어 분리·따옴표 제거"
_file "$P${T}codex${T}$KIS"
t_assert_eq "KIS codex 줄 → 10개 인자 ({dir} = launch 폴더)" \
  "rc=0 n=10 $(_q --cd "$P" --sandbox workspace-write --ask-for-approval on-request --add-dir /Users/ez2sarang/Documents/dev/ai/investments/data/rtbot/runs -c sandbox_workspace_write.network_access=true)" \
  "$(_ua codex "$P")"
_file "$P${T}codex${T}  -a   on-request${T}-s${T}${T}workspace-write  "
t_assert_eq "공백 여러 개·인자 필드 안 TAB = 구분자, 앞뒤 공백 무시" "rc=0 n=4 $(_q -a on-request -s workspace-write)" "$(_ua codex "$P")"
_file "$P${T}codex${T}\"a b\" 'c d' e\\ f \"g'h\" 'i\"j' k\"l m\"n"
t_assert_eq "큰따옴표·작은따옴표·역슬래시·섞어 쓰기" "rc=0 n=6 $(_q "a b" "c d" "e f" "g'h" 'i"j' "kl mn")" "$(_ua codex "$P")"
_file "$P${T}codex${T}\$'x\\ty' \"\" '' -c \"model=\\\"o3\\\"\""
t_assert_eq "\$'…' · 빈 인자 2개 · 큰따옴표 안 \\\" " "rc=0 n=5 $(_q "x${T}y" "" "" -c 'model="o3"')" "$(_ua codex "$P")"
_file "$P${T}codex${T}"
t_assert_eq "인자 필드가 빈 줄(TAB 2개) → 맞음·인자 0개" "rc=0 n=0" "$(_ua codex "$P")"
_file "$P${T}codex${T}   "
t_assert_eq "인자 필드가 공백뿐 → 맞음·인자 0개" "rc=0 n=0" "$(_ua codex "$P")"
_file "$P${T}codex${T}a #b c"
t_assert_eq "# 은 주석이 아니라 글자 (줄 맨 앞만 주석)" "rc=0 n=3 $(_q a '#b' c)" "$(_ua codex "$P")"

# ── R3 ────────────────────────────────────────────────
t_scenario R3 "확장 금지 — 명령·변수·백틱·~·glob이 그대로"
PWN="$U_TMP/pwned"
touch "$U_TMP/p/g1.c" "$U_TMP/p/g2.c"
_file "$P${T}codex${T}\$(touch $PWN) \"\$(touch $PWN)\" \`touch $PWN\` \$HOME \"\${HOME}\" ~ ~/x $U_TMP/p/*.c \$((1+2)) \$CMUX_SESSION"
t_assert_eq "모두 그 글자 그대로" \
  "rc=0 n=10 $(_q "\$(touch $PWN)" "\$(touch $PWN)" "\`touch $PWN\`" '$HOME' '${HOME}' '~' '~/x' "$U_TMP/p/*.c" '$((1+2))' '$CMUX_SESSION')" \
  "$(_ua codex "$P")"
t_assert_true "명령 치환·백틱이 실행되지 않음 (파일 생성 없음)" '[[ ! -e "$PWN" ]]'
_file "$P${T}codex${T}'\$(touch $PWN)' \"\`touch $PWN\`\""
t_assert_eq "따옴표 안 치환도 글자 그대로" "rc=0 n=2 $(_q "\$(touch $PWN)" "\`touch $PWN\`")" "$(_ua codex "$P")"
t_assert_true "여전히 파일 생성 없음" '[[ ! -e "$PWN" ]]'

# ── R4 ────────────────────────────────────────────────
t_scenario R4 "{dir} 치환"
_file "$P${T}codex${T}{dir} --cd {dir} --x={dir}/a \"{dir} b\" '{dir}' {dir}{dir} {dir}x x{dir} {DIR} {dir"
t_assert_eq "여러 번·따옴표 안·붙여 쓰기·단독 (대소문자 다른 {DIR}·닫히지 않은 {dir 은 그대로)" \
  "rc=0 n=11 $(_q "$P" --cd "$P" "--x=$P/a" "$P b" "$P" "$P$P" "${P}x" "x$P" '{DIR}' '{dir')" "$(_ua codex "$P")"
print -rl -- "*${T}codex${T}--cd={dir}" > "$AF"
t_assert_eq "* 줄의 {dir} = 그 launch 폴더" "rc=0 n=1 $(_q "--cd=$Q")" "$(_ua codex "$Q")"
mkdir -p "$U_TMP/p/sp ace\$x"
_file "*${T}codex${T}{dir}"
t_assert_eq "폴더 경로의 공백·\$ 는 다시 해석하지 않음 (한 인자)" "rc=0 n=1 $(_q "$U_TMP/p/sp ace\$x")" "$(_ua codex "$U_TMP/p/sp ace\$x")"

# ── R5 ────────────────────────────────────────────────
t_scenario R5 "무시되는 줄"
_file "#$P${T}codex${T}--commented" "" "   " "$P${T}codex" "$P" "$P${T}gemini${T}--g" "$P${T}${T}--noagent" \
  "p/Proj${T}codex${T}--rel" "~/x${T}codex${T}--tilde" "$Q${T}codex${T}--other" "$P${T}opencode${T}--oc"
t_assert_eq "# 줄·빈 줄·필드 3개 미만·gemini(미등록)·빈 에이전트·상대경로·~ 대상·다른 폴더 → 맞는 줄 없음" "rc=1 n=0" "$(_ua codex "$P")"
t_assert_eq "무시되는 줄은 경고도 없음" "" "$(_agent_user_args codex "$P")"
t_assert_eq "다른 에이전트 줄은 그 에이전트에만" "rc=0 n=1 $(_q --oc)" "$(_ua opencode "$P")"
t_assert_eq "미등록 에이전트로 조회해도 그 줄 무시" "rc=1 n=0" "$(_ua gemini "$P")"
print -rn -- "$P${T}codex${T}-a never"$'\r\n'"*${T}claude${T}--x"$'\r' > "$AF"
t_assert_eq "CRLF 줄 끝 → CR 제거" "rc=0 n=2 $(_q -a never)" "$(_ua codex "$P")"
t_assert_eq "마지막 줄 개행 없음(CR만)도 읽음" "rc=0 n=1 $(_q --x)" "$(_ua claude "$P")"
_file " #$P${T}codex${T}--sp" "$P ${T}codex${T}--trail" "$P${T}codex ${T}--agentsp"
t_assert_eq "대상·에이전트 필드의 공백은 그대로 비교 (맞지 않음)" "rc=1 n=0" "$(_ua codex "$P")"

# ── R6 ────────────────────────────────────────────────
t_scenario R6 "파싱 실패 → 경고 1줄 + 없는 줄로"
WARN_TAIL="번째 줄을 해석하지 못해 무시합니다 (닫히지 않은 따옴표, 따옴표 밖 ; | & < > ( ) 등)"
_w() { print -r -- "! 인자 파일 ${AF}의 $1${WARN_TAIL}"; }
typeset -A bad=(
  dq     'a "b c'
  sq     "a 'b c"
  cmd    'a $(b'
  param  'a ${b'
  bt     'a `b'
  bs     'a b\'
  semi   'a;b'
  pipe   'a | b'
  amp    'a && b'
  redir  'a >b'
  fd     'a 2>&1'
  paren  'a (b'
  rparen 'a )'
)
for k in dq sq cmd param bt bs semi pipe amp redir fd paren rparen; do
  _file "$P${T}codex${T}${bad[$k]}"
  t_assert_eq "실패($k: ${bad[$k]}) → 경고 1줄 + 맞는 줄 없음" "$(_w 1)"$'\n'"rc=1 n=0" "$(_uac codex "$P")"
done
_file "$P${T}codex${T}'a;b' \"c|d\" e\\>f '(g)' (h) ((i)) x=(1 2) ! { } [["
t_assert_eq "따옴표·역슬래시 안 연산자, 괄호 묶음(공백 포함 한 단어), ! { } [[ 는 글자 그대로 (모두 인자 자리)" \
  "rc=0 n=11 $(_q 'a;b' 'c|d' 'e>f' '(g)' '(h)' '((i))' 'x=(1 2)' '!' '{' '}' '[[')" "$(_uac codex "$P")"
_file "*${T}codex${T}--star" "$P${T}codex${T}--good" "$P${T}codex${T}--bad \"x"
t_assert_eq "나중 경로 줄이 깨짐 → 경고 + 앞의 경로 줄 (* 아님)" "$(_w 3)"$'\n'"rc=0 n=1 $(_q --good)" "$(_uac codex "$P")"
_file "*${T}codex${T}--star" "$P${T}codex${T}--bad 'x"
t_assert_eq "유일한 경로 줄이 깨짐 → 경고 + * 줄" "$(_w 2)"$'\n'"rc=0 n=1 $(_q --star)" "$(_uac codex "$P")"
_file "$Q${T}codex${T}--bad \"x" "*${T}opencode${T}'x"
t_assert_eq "후보가 아닌 깨진 줄(다른 폴더·다른 에이전트)은 경고 없음" "rc=1 n=0" "$(_uac codex "$P")"
_file "$P${T}codex${T}a \"b" "*${T}codex${T}c 'd"
t_assert_eq "깨진 후보 줄마다 1줄씩" "$(_w 1)"$'\n'"$(_w 2)"$'\n'"rc=1 n=0" "$(_uac codex "$P")"
out="$(_file "$P${T}codex${T}a \"b"; _agent_user_args codex "$P")"
t_assert_eq "경고는 _warn 형식 (노란 ! 접두)" "${(g::)_c_yellow}!${(g::)_c_reset} 인자 파일 ${AF}의 1${WARN_TAIL}" "$out"
# echo 해석된 형태 비교 — _warn은 echo로 색 코드를 낸다
t_assert_eq "경고 문자열 = _warn 출력" "$(_warn "인자 파일 ${AF}의 1${WARN_TAIL}")" "$out"

# ── R7 ────────────────────────────────────────────────
t_scenario R7 "매칭·우선순위"
_file "$P${T}codex${T}--path" "*${T}codex${T}--star"
t_assert_eq "경로 줄 > * 줄" "rc=0 n=1 $(_q --path)" "$(_ua codex "$P")"
_file "*${T}codex${T}--star" "$P${T}codex${T}--path"
t_assert_eq "순서 바꿔도 경로 줄 (합치지 않음)" "rc=0 n=1 $(_q --path)" "$(_ua codex "$P")"
_file "$P${T}codex${T}--path" "*${T}codex${T}--star"
t_assert_eq "다른 폴더 → * 줄" "rc=0 n=1 $(_q --star)" "$(_ua codex "$Q")"
t_assert_eq "* 줄도 에이전트가 같아야" "rc=1 n=0" "$(_ua opencode "$Q")"
_file "$P${T}codex${T}--p1" "*${T}codex${T}--s1" "$P${T}codex${T}--p2 x" "*${T}codex${T}--s2" "$P${T}codex${T}--p3"
t_assert_eq "같은 경로 중복 → 마지막 줄" "rc=0 n=1 $(_q --p3)" "$(_ua codex "$P")"
t_assert_eq "같은 * 중복 → 마지막 줄" "rc=0 n=1 $(_q --s2)" "$(_ua codex "$Q")"
_file "$P/${T}codex${T}--slash"
t_assert_eq "대상 끝 / → -ef로 같은 폴더" "rc=0 n=1 $(_q --slash)" "$(_ua codex "$P")"
ln -s "$P" "$U_TMP/p/link"
_file "$U_TMP/p/link${T}codex${T}--link"
t_assert_eq "대상이 심볼릭 링크 → -ef로 같은 폴더" "rc=0 n=1 $(_q --link)" "$(_ua codex "$P")"
_file "$P${T}codex${T}--real"
t_assert_eq "launch 폴더가 심볼릭 링크 경로 → -ef로 같은 폴더" "rc=0 n=1 $(_q --real)" "$(_ua codex "$U_TMP/p/link")"
_file "$U_TMP/p/missing${T}codex${T}--missing"
t_assert_eq "없는 대상 경로 → 맞지 않음" "rc=1 n=0" "$(_ua codex "$P")"
if (( U_CI )); then
  _file "${P:l}${T}codex${T}--lower"
  t_assert_eq "대소문자만 다른 대상 (대소문자 무시 볼륨) → 같은 폴더" "rc=0 n=1 $(_q --lower)" "$(_ua codex "$P")"
  _file "${P:l}${T}codex${T}--lower" "$P${T}codex${T}--exact"
  t_assert_eq "같은 폴더를 가리키는 두 경로 줄 → 마지막 줄" "rc=0 n=1 $(_q --exact)" "$(_ua codex "$P")"
else
  t_skip "대소문자 구분 볼륨 — 대소문자 차이 매칭 생략"
fi
_file "$U_TMP/p${T}codex${T}--parent"
t_assert_eq "상위 폴더 줄은 하위 폴더에 적용 안 됨" "rc=1 n=0" "$(_ua codex "$P")"

# ── R8 ────────────────────────────────────────────────
t_scenario R8 "실제 zellij 호출 0"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
