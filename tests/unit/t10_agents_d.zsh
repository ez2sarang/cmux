#!/usr/bin/env zsh
# t10_agents_d — 에이전트 확장점(agents.d) 단위 테스트 (별도 zsh 프로세스로 cmux-agents.zsh 를 source, zellij·실제 에이전트 없음)
#   D1 디렉토리 없음 / 빈 디렉토리 / *.zsh 아닌 파일 → 내장 정의 그대로, 출력 없음, 비0 새지 않음(install.sh 와 같은 set -euo pipefail)
#   D2 정상 파일 → 등록·훅(label·bin·perm_args·resume_args·has_history·compose)·CMUX_<이름>_PERM·typeset -g 상태
#   D3 문법 오류 파일 → 경고 1줄 + 그 파일 통째로 건너뜀(일부만 등록되지 않음), 다른 파일은 계속
#   D4 중복 이름 → 경고 + 무시 (내장 kimi 어댑터 함수를 덮어쓰지 못함, 앞선 파일이 이김)
#   D5 이름 규칙·CMUX_AGENTS 통째 교체·여러 이름 등록
#   D6 cmux 본체 연동 — -h 의 에이전트 목록, cmux default, 복원 기록(_tabs_load), _launch_agent, 문법 오류 파일이 있어도 cmux 동작
#   D7 견본 doc/agents.d/grok.zsh.example — .example 은 비활성, 복사하면 경고 없이 로드되고 아무 플래그도 지어내지 않는다
#   D8 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

mkdir -p "$U_TMP"/{home,bin,zdotdir,cfg}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs" CMUX_CONFIG_FILE="$U_TMP/cfg/config"
export CMUX_AGENT_ARGS_FILE="$U_TMP/cfg/agent-args"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
cat > "$U_TMP/bin/collar-agents-sync" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$U_TMP/bin/zellij" "$U_TMP/bin/collar-agents-sync"
for a in claude codex opencode kimi grok; do ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-$a"; done
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude" CMUX_KIMI_BIN="$U_TMP/bin/fake-kimi"
export PATH="$U_TMP/bin:$PATH"
export FAKE_AGENT_LOG="$U_TMP/fake.log" FAKE_AGENT_SLEEP=0
: > "$FAKE_AGENT_LOG"
LIB="${CMUX_UNDER_TEST:h}/cmux-agents.zsh"
BUILTIN="claude codex opencode kimi"

# ── 공용 도우미 ───────────────────────────────────────
# _lib <agents.d 경로> <zsh 코드> — 설치 스크립트처럼 set -euo pipefail 로 라이브러리를 source 한 뒤 코드를 실행. stdout+stderr 합쳐서 + "rc=N"
_lib() {
  local out; out="$(CMUX_AGENTS_D="$1" zsh -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$LIB" "$2" 2>&1)"
  print -r -- "$out"$'\n'"rc=$?"
}
# 같은 호출의 stdout 만 / stderr 만
_libo() { CMUX_AGENTS_D="$1" zsh -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$LIB" "$2" 2>/dev/null; }
_libe() { CMUX_AGENTS_D="$1" zsh -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$LIB" "$2" 2>&1 >/dev/null; }
AG='print -r -- "${CMUX_AGENTS[*]}"'
_nlines() { local -a l=("${(@f)1}"); print -r -- ${#l}; }
X="$U_TMP/x"

# ── D1 ────────────────────────────────────────────────
t_scenario D1 "디렉토리 없음 · 빈 디렉토리 · *.zsh 아닌 파일"
t_assert_eq "존재하지 않는 디렉토리 → 내장만, 경고 없음, rc 0 (set -euo pipefail 로 source)" "$BUILTIN"$'\n'"rc=0" "$(_lib "$U_TMP/nonexistent" "$AG")"
mkdir -p "$X/empty"
t_assert_eq "빈 디렉토리 → 내장만" "$BUILTIN"$'\n'"rc=0" "$(_lib "$X/empty" "$AG")"
mkdir -p "$X/other"; print -r -- 'CMUX_AGENTS+=(zzz)' > "$X/other/zzz.txt"; print -r -- 'CMUX_AGENTS+=(zzz)' > "$X/other/zzz.zsh.example"; print -r -- 'CMUX_AGENTS+=(zzz)' > "$X/other/.hidden.zsh"; mkdir "$X/other/dir.zsh"
t_assert_eq "*.zsh 가 아닌 파일·숨김 파일·디렉토리 → 무시" "$BUILTIN"$'\n'"rc=0" "$(_lib "$X/other" "$AG")"
t_assert_eq "CMUX_AGENTS_D 미설정 + 가짜 HOME → ~/.config/cmux/agents.d 없음 → 내장만" "$BUILTIN" \
  "$(env -u CMUX_AGENTS_D zsh -c 'set -euo pipefail; source "$1"; print -r -- "${CMUX_AGENTS[*]}"' _ "$LIB" 2>&1)"
mkdir -p "$HOME/.config/cmux/agents.d"; print -r -- 'CMUX_AGENTS+=(homed)' > "$HOME/.config/cmux/agents.d/homed.zsh"
t_assert_eq "CMUX_AGENTS_D 미설정 → 기본 위치 \$HOME/.config/cmux/agents.d 를 읽음" "$BUILTIN homed" \
  "$(env -u CMUX_AGENTS_D zsh -c 'set -euo pipefail; source "$1"; print -r -- "${CMUX_AGENTS[*]}"' _ "$LIB" 2>&1)"
rm -rf -- "$HOME/.config"
t_assert_eq "HOME 도 미설정 + set -u → 죽지 않고 내장만" "$BUILTIN" \
  "$(env -u CMUX_AGENTS_D -u HOME zsh -c 'set -euo pipefail; source "$1"; print -r -- "${CMUX_AGENTS[*]}"' _ "$LIB" 2>&1)"
t_assert_eq "내장 kimi 어댑터는 확장 로드 후에도 그대로" "Kimi Code|safe" \
  "$(_libo "$X/empty" '_agent_call kimi label; print -rn -- "$REPLY|"; _agent_call kimi default_perm; print -r -- "$REPLY"')"

# ── D2 ────────────────────────────────────────────────
t_scenario D2 "정상 파일 — 등록 · 훅 · 권한 env · 상태"
mkdir -p "$X/ok"
cat > "$X/ok/grok.zsh" <<'EOF'
CMUX_AGENTS+=(grok)
_ag_grok_label() { REPLY="Grok CLI" }
_ag_grok_bin() { _ag_search_bin grok /nonexistent/grok }
_ag_grok_default_perm() { REPLY=safe }
_ag_grok_perm_args() { if [[ "$1" == auto ]]; then reply=(--full-auto); else reply=(--ask); fi }
_ag_grok_resume_args() { reply=(--resume-last) }
_ag_grok_has_history() { _ag_grok_seen=1; REPLY="있음"; return 0 }
typeset -g _ag_grok_state="loaded"
EOF
t_assert_eq "등록됨 (내장 뒤에 추가) · 경고 없음 · rc 0" "$BUILTIN grok"$'\n'"rc=0" "$(_lib "$X/ok" "$AG")"
t_assert_eq "_agent_known grok" "0" "$(_libo "$X/ok" '_agent_known grok; print -r -- $?')"
t_assert_eq "label 훅" "Grok CLI" "$(_libo "$X/ok" '_agent_call grok label; print -r -- "$REPLY"')"
t_assert_eq "perm_args 훅 (auto|safe)" "--full-auto|--ask" "$(_libo "$X/ok" '_agent_call grok perm_args auto; print -rn -- "${reply[*]}|"; _agent_call grok perm_args safe; print -r -- "${reply[*]}"')"
t_assert_eq "compose 기본 구현: 권한 인자 + resume_args" "--ask --resume-last" "$(_libo "$X/ok" '_agent_call grok perm_args safe; _agent_call grok compose resume "${reply[@]}"; print -r -- "${reply[*]}"')"
t_assert_eq "fresh 는 훅이 없으면 기본(인자 없음) → 권한 인자만" "--ask" "$(_libo "$X/ok" '_agent_call grok perm_args safe; _agent_call grok compose fresh "${reply[@]}"; print -r -- "${reply[*]}"')"
t_assert_eq "has_history 훅" "0|있음" "$(_libo "$X/ok" '_agent_call grok has_history /tmp; print -r -- "$?|$REPLY"')"
t_assert_eq "정의하지 않은 훅은 기본 구현 (fastfail 5 · last_activity 0)" "5|0" "$(_libo "$X/ok" '_agent_call grok fastfail; print -rn -- "$REPLY|"; _agent_call grok last_activity /tmp; print -r -- "$REPLY"')"
t_assert_eq "typeset -g 로 둔 상태 변수는 살아남음" "loaded" "$(_libo "$X/ok" 'print -r -- "$_ag_grok_state"')"
t_assert_eq "권한 프로파일: 기본 safe / CMUX_GROK_PERM=auto 가 이김 / 잘못된 값은 경고 후 기본" "safe|auto" \
  "$(_libo "$X/ok" '_agent_perm_profile grok; print -rn -- "$REPLY|"; CMUX_GROK_PERM=auto _agent_perm_profile grok; print -r -- "$REPLY"')"
t_assert_contains "잘못된 CMUX_GROK_PERM 경고" "$(CMUX_GROK_PERM=yolo _libe "$X/ok" '_warn() { print -r -- "$*" >&2 }; _agent_perm_profile grok')" "CMUX_GROK_PERM='yolo' — auto|safe 가 아니라 기본값(safe)을 씁니다"
t_assert_eq "bin: 후보가 없으면 비0" "1" "$(_libo "$X/ok" 'PATH=/usr/bin:/bin; _agent_call grok bin && print -r -- 0 || print -r -- 1')"
t_assert_eq "bin: CMUX_GROK_BIN 이 최우선 (_ag_search_bin 재사용)" "/custom/grok" "$(_libo "$X/ok" 'CMUX_GROK_BIN=/custom/grok _agent_call grok bin; print -r -- "$REPLY"')"
# 여러 파일 — 이름순으로 등록
mkdir -p "$X/multi"; print -r -- 'CMUX_AGENTS+=(bbb)' > "$X/multi/b.zsh"; print -r -- 'CMUX_AGENTS+=(aaa ccc)' > "$X/multi/a.zsh"
t_assert_eq "여러 파일·여러 이름: 파일 이름순(glob 순)으로 등록" "$BUILTIN aaa ccc bbb" "$(_libo "$X/multi" "$AG")"

# ── D3 ────────────────────────────────────────────────
t_scenario D3 "문법 오류 파일 — 경고 1줄 후 계속"
mkdir -p "$X/bad"
cat > "$X/bad/a_broken.zsh" <<'EOF'
CMUX_AGENTS+=(broken)
_ag_broken_label() { REPLY="Broken"
EOF
print -r -- 'CMUX_AGENTS+=(fine)' > "$X/bad/b_fine.zsh"
out="$(_lib "$X/bad" "$AG")"
t_assert_eq "나머지 파일은 계속 로드, 문법 오류 파일의 이름은 등록되지 않음, rc 0" "$BUILTIN fine"$'\n'"rc=0" "$(print -r -- "$out" | grep -v '^!')"
t_assert_eq "경고는 정확히 1줄" 1 "$(print -r -- "$out" | grep -c '^!')"
t_assert_contains "경고 문구 (파일 경로 + 문법 오류 + 건너뜀)" "$out" "! cmux: $X/bad/a_broken.zsh 문법 오류 — 이 에이전트 확장을 건너뜁니다"
t_assert_eq "문법 오류 파일의 함수도 정의되지 않음 (파일 통째로 건너뜀)" "0" "$(_libo "$X/bad" 'print -r -- ${+functions[_ag_broken_label]}' | sed 's/^1$/1/')"
# 일부 문장은 멀쩡하고 뒤쪽에 문법 오류 → 앞쪽 등록도 일어나지 않아야 한다
cat > "$X/bad/a_broken.zsh" <<'EOF'
CMUX_AGENTS+=(half)
_ag_half_label() { REPLY="Half" }
if [[ -n x ]]; then
EOF
t_assert_eq "앞부분이 정상이어도 뒤에 문법 오류가 있으면 아무것도 등록되지 않음" "$BUILTIN fine" "$(_libo "$X/bad" "$AG")"
# 실행 중 오류(명령 없음)는 문법 오류가 아니다 — source 는 계속되고 cmux 는 죽지 않는다
mkdir -p "$X/rt"; printf 'CMUX_AGENTS+=(rt)\nnonexistent_command_xyz\n' > "$X/rt/rt.zsh"
t_assert_eq "실행 중 오류(문법은 정상) → 등록은 유지, rc 0" "$BUILTIN rt"$'\n'"rc=0" "$(_libo "$X/rt" "$AG; print -r -- rc=\$?")"
# cmux 본체는 문법 오류 파일이 있어도 동작한다
out="$(CMUX_AGENTS_D="$X/bad" zsh "$CMUX_UNDER_TEST" -h 2>&1)"
t_assert_contains "cmux -h 는 문법 오류 확장이 있어도 도움말을 낸다" "$out" "사용법: cmux"
t_assert_eq "cmux -h 에 경고 1줄" 1 "$(print -r -- "$out" | grep -c '문법 오류 — 이 에이전트 확장을 건너뜁니다')"
CMUX_AGENTS_D="$X/bad" zsh "$CMUX_UNDER_TEST" -h >/dev/null 2>&1
t_assert_eq "cmux -h rc 0" 0 $?

# ── D4 ────────────────────────────────────────────────
t_scenario D4 "중복 이름 — 경고 후 무시, 내장·앞선 파일 어댑터를 덮어쓰지 못함"
mkdir -p "$X/dup"
cat > "$X/dup/hijack.zsh" <<'EOF'
CMUX_AGENTS+=(kimi codex)
_ag_kimi_label() { REPLY="HIJACKED" }
_ag_kimi_fresh_args() { reply=(--hijack) }
_ag_kimi_perm_args() { reply=(--hijack-perm) }
_ag_codex_label() { REPLY="HIJACKED-codex" }
EOF
out="$(_lib "$X/dup" "$AG")"
t_assert_eq "내장 이름 중복 등록 → 목록은 그대로 (중복 항목 없음)" "$BUILTIN" "$(_libo "$X/dup" "$AG")"
t_assert_eq "경고 2줄 (kimi, codex 각 1줄)" 2 "$(print -r -- "$out" | grep -c '^!')"
t_assert_contains "경고 문구" "$out" "! cmux: hijack.zsh — 이미 등록된 에이전트 'kimi' 의 중복 등록을 무시합니다"
t_assert_eq "내장 label 보존" "Kimi Code|Codex" "$(_libo "$X/dup" '_agent_call kimi label; print -rn -- "$REPLY|"; _agent_call codex label; print -r -- "$REPLY"')"
t_assert_eq "내장 perm_args 보존 (safe → --yolo)" "--yolo" "$(_libo "$X/dup" '_agent_call kimi perm_args safe; print -r -- "${reply[*]}"')"
t_assert_eq "내장에 없던 훅(fresh_args)을 새로 정의했어도 제거됨 → 기본 구현(인자 없음)" "0" "$(_libo "$X/dup" '_agent_call kimi fresh_args; print -r -- "${#reply}"')"
# 두 확장 파일이 같은 이름 → 앞선(이름순) 파일이 이긴다
mkdir -p "$X/dup2"
printf 'CMUX_AGENTS+=(twin)\n_ag_twin_label() { REPLY="first" }\n' > "$X/dup2/a.zsh"
printf 'CMUX_AGENTS+=(twin)\n_ag_twin_label() { REPLY="second" }\n_ag_twin_bin() { REPLY=/x }\n' > "$X/dup2/b.zsh"
out="$(_lib "$X/dup2" "$AG")"
t_assert_eq "확장끼리 중복 → 한 번만 등록" "$BUILTIN twin" "$(_libo "$X/dup2" "$AG")"
t_assert_eq "앞선 파일의 정의가 이김 (label=first)·뒤 파일이 새로 만든 훅은 제거(bin 기본 구현 → PATH에 twin 없음 → 비0)" "first|1" \
  "$(_libo "$X/dup2" '_agent_call twin label; print -rn -- "$REPLY|"; PATH=/usr/bin:/bin; _agent_call twin bin && print -r -- 0 || print -r -- 1')"
t_assert_eq "확장끼리 중복 → 경고 1줄" 1 "$(print -r -- "$out" | grep -c '^!')"
# 같은 파일 안에서 같은 이름 두 번
mkdir -p "$X/dup3"; print -r -- 'CMUX_AGENTS+=(solo solo)' > "$X/dup3/s.zsh"
t_assert_eq "한 파일에서 같은 이름을 두 번 적어도 한 번만" "$BUILTIN solo" "$(_libo "$X/dup3" "$AG")"

# ── D5 ────────────────────────────────────────────────
t_scenario D5 "이름 규칙 · 통째 교체 시도"
mkdir -p "$X/names"
printf 'CMUX_AGENTS+=(Grok bad-name 9lives default has.dot ok_name2)\n' > "$X/names/n.zsh"
out="$(_lib "$X/names" "$AG")"
t_assert_eq "[a-z][a-z0-9_]* 가 아니거나 'default' 면 등록 안 함" "$BUILTIN ok_name2" "$(_libo "$X/names" "$AG")"
t_assert_eq "어긴 이름마다 경고 1줄 (5개)" 5 "$(print -r -- "$out" | grep -c '이어야 해서 등록하지 않습니다')"
mkdir -p "$X/replace"; printf 'CMUX_AGENTS=(only)\n' > "$X/replace/r.zsh"
t_assert_eq "CMUX_AGENTS=(…) 통째 교체를 해도 내장은 사라지지 않고 추가분도 반영되지 않음(+= 만 반영)" "$BUILTIN" "$(_libo "$X/replace" "$AG")"
mkdir -p "$X/unset"; printf 'unset CMUX_AGENTS\n' > "$X/unset/u.zsh"
t_assert_eq "CMUX_AGENTS 를 지워도 복원됨" "$BUILTIN" "$(_libo "$X/unset" "$AG")"

# ── D6 ────────────────────────────────────────────────
t_scenario D6 "cmux 본체 연동"
export CMUX_AGENTS_D="$X/ok"
export CMUX_GROK_BIN="$U_TMP/bin/fake-grok"
out="$(zsh "$CMUX_UNDER_TEST" -h 2>&1)"
t_assert_contains "-h 의 에이전트 목록에 grok" "$out" "에이전트: claude codex opencode kimi grok  — 기본 claude"
t_assert_contains "-h 의 확장 디렉토리 안내" "$out" "확장:     $X/ok/*.zsh"
zsh "$CMUX_UNDER_TEST" default grok >/dev/null 2>&1
t_assert_eq "cmux default grok → 설정 기록 (등록된 에이전트로 인정)" "CMUX_DEFAULT_AGENT=grok" "$(cat "$CMUX_CONFIG_FILE")"
rm -f -- "$CMUX_CONFIG_FILE"
out="$(zsh "$CMUX_UNDER_TEST" default nogrok 2>&1)"
t_assert_contains "미등록 이름 → 사용 가능 목록에 grok 포함" "$out" "알 수 없는 에이전트: 'nogrok' (사용 가능: claude codex opencode kimi grok)"
export CMUX_SOURCE_ONLY=1
CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패"; exit 1; }
mkdir -p "$U_TMP/pg" "$U_TMP/pg2"
T=$'\t'
print -rl -- "$U_TMP/pg${T}grok" "$U_TMP/pg2" > "$CMUX_TABS_FILE"
t_assert_eq "복원 기록(session-tabs): grok 줄을 그대로 읽음" "$U_TMP/pg${T}grok"$'\n'"$U_TMP/pg2" "$(_tabs_load)"
_tab_name /x/proj grok
t_assert_eq "탭 이름 proj·grok" "proj·grok" "$REPLY"
t_assert_contains "탭 레이아웃: launch --agent grok" "$(_kdl_tab_body grok)" 'args "launch" "--agent" "grok"'
: > "$FAKE_AGENT_LOG"
out="$( (cd "$U_TMP/pg" && _launch_agent grok) 2>&1 | sed $'s/\e\\[[0-9;]*m//g')"
t_assert_eq "_launch_agent grok: 확장 훅대로 인자 조립 (safe=--ask, 이력 있음 → --resume-last)" "--ask --resume-last" "$(t_agent_args grok "$U_TMP/pg")"
t_assert_contains "배너: 확장 label + has_history 설명" "$out" "▶ Grok CLI: 이전 대화 이어서 시작 [있음]"
unset CMUX_SOURCE_ONLY
export CMUX_AGENTS_D="/nonexistent/cmux-agents.d"

# ── D7 ────────────────────────────────────────────────
t_scenario D7 "견본 doc/agents.d/grok.zsh.example"
EX="$T_REPO/doc/agents.d/grok.zsh.example"
t_assert_true "견본 파일 존재" '[[ -f "$EX" ]]'
t_assert_true "견본은 문법이 올바름 (zsh -n)" 'zsh -n "$EX"'
mkdir -p "$X/ex"; cp "$EX" "$X/ex/"
t_assert_eq "확장자 .example → 비활성 (아무것도 등록되지 않음, 경고 없음)" "$BUILTIN"$'\n'"rc=0" "$(_lib "$X/ex" "$AG")"
mkdir -p "$X/ex2"; cp "$EX" "$X/ex2/grok.zsh"
t_assert_eq "grok.zsh 로 복사하면 경고 없이 grok 등록" "$BUILTIN grok"$'\n'"rc=0" "$(_lib "$X/ex2" "$AG")"
t_assert_eq "견본의 label" "Grok" "$(_libo "$X/ex2" '_agent_call grok label; print -r -- "$REPLY"')"
t_assert_eq "견본은 플래그를 지어내지 않는다: perm_args·resume_args·fresh_args 모두 빈 배열" "0|0|0|0" \
  "$(_libo "$X/ex2" '_agent_call grok perm_args auto; print -rn -- "${#reply}|"; _agent_call grok perm_args safe; print -rn -- "${#reply}|"; _agent_call grok resume_args; print -rn -- "${#reply}|"; _agent_call grok fresh_args; print -r -- "${#reply}"')"
t_assert_eq "견본 default_perm = safe" "safe" "$(_libo "$X/ex2" '_agent_call grok default_perm; print -r -- "$REPLY"')"
t_assert_contains "견본에 '공식 문서로 확인 후 채울 것' 자리표시자" "$(cat "$EX")" "공식 문서로 확인 후 채울 것"
t_assert_contains "견본이 채울 훅을 안내 (bin/perm_args/resume_args/has_history)" "$(cat "$EX")" "has_history"
t_assert_eq "견본에 실제 grok 플래그 문자열 없음 (--resume/--yolo/--full-auto 등)" "0" "$(grep -cE '^[^#]*(--resume|--yolo|--full-auto|--dangerously|--continue)' "$EX")"

# ── D8 ────────────────────────────────────────────────
t_scenario D8 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
