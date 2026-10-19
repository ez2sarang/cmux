#!/usr/bin/env zsh
# t04_tabs_agents — 탭 spec(경로[<TAB>에이전트])·탭 이름·레이아웃·default·-a·picker 연동 단위 테스트 (P2-B2, 설계 §4·§10)
#   S1 _tabs_load  새 포맷 읽기 — 혼합·구포맷·`경로<TAB>claude`·미등록 에이전트·없는 경로·중복
#      _spec_parse — 구포맷 줄·TAB 줄·공백 경로·`·`가 든 경로(폴더 이름 alpha·codex 포함)·빈 에이전트, 왕복
#   S2 _tabs_save  claude는 경로만·비-claude는 TAB, 정규 spec 단위 중복 제거, 왕복, .bak 1회
#   S3 _tabs_append 정규 spec 단위 중복 제거(같은 경로·다른 에이전트 허용), .bak
#   S4 _tab_name · _tabs_sync_live 접미사 파싱 (`·` 경계, 같은 basename 다른 경로, 개명 탭) — zellij는 셸 함수 스텁
#   S5 default 우선순위 · 설정 파일(최상단 source — launch 포함) · cmux default 읽기/쓰기(다른 줄 보존·원자성)
#   S6 레이아웃 — claude 세션 레이아웃이 이전 구현(a1a07e9)과 바이트 동일, new-tab 생성기 = 렌더된 claude-tab.kdl,
#      에이전트별 cmux-tab-<a>.kdl 생성
#   S7 cmux -a / --agent / cmux <경로> (default, 마지막 사용 기억 미적용) — PATH의 가짜 zellij(기록 후 exit 1)로 콜드 경로만
#   S8 project-agents 기억 (_agent_remember)
#   S9 _pick env 구성 · _pick_flow 출력 파싱 · fzf 폴백 (_open_one/_open_many는 기록 스텁)
#   S10 도움말

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'chmod -R u+w -- "$U_TMP" 2>/dev/null; rm -rf -- "$U_TMP"' EXIT   # 읽기 전용 디렉토리 케이스가 중간에 끊겨도 지운다

mkdir -p "$U_TMP"/{home,bin,cfg,layouts}
export HOME="$U_TMP/home"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs"
export CMUX_CONFIG_FILE="$U_TMP/cfg/config" CMUX_PROJECT_AGENTS_FILE="$U_TMP/cfg/project-agents"
export CMUX_EXTRAS_FILE="$U_TMP/cfg/extras" CMUX_LAYOUTS_DIR="$U_TMP/layouts"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config" CODEX_HOME="$U_TMP/codex-home"
unset CMUX_AGENT CMUX_DEFAULT_AGENT
# PATH 맨 앞의 가짜 zellij — 호출만 기록하고 exit 1 (세션 없음 → 콜드 경로, 클라이언트 실행은 즉시 실패)
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
chmod +x "$U_TMP/bin/zellij"
for a in claude codex opencode; do ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-$a"; done
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude" CMUX_CODEX_BIN="$U_TMP/bin/fake-codex" CMUX_OPENCODE_BIN="$U_TMP/bin/fake-opencode"
export FAKE_AGENT_LOG="$U_TMP/fake-agent.log" FAKE_AGENT_SLEEP=0
print -r -- $'#!/bin/sh\nprintf "[bar]"' > "$U_TMP/bin/bar-stub"
chmod +x "$U_TMP/bin/bar-stub"
export CMUX_BAR_BIN="$U_TMP/bin/bar-stub"
export PATH="$U_TMP/bin:$PATH"

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }
DEV_ROOT="$U_TMP/dev"
EXTRAS_FILE="$U_TMP/cfg/extras"

T=$'\t'
A="$DEV_ROOT/alpha" B="$DEV_ROOT/beta" G="$DEV_ROOT/gamma" MP="$DEV_ROOT/my·proj"
X="$U_TMP/x/proj" Y="$U_TMP/y/proj"
mkdir -p "$A" "$B" "$G" "$MP" "$X" "$Y"
: > "$EXTRAS_FILE"

_file()  { cat "$TABS_FILE" 2>/dev/null; }
_lines() { print -r -l -- "$@"; }
# _cm [인자...] — cmux를 별도 프로세스로 실행 (디스패처 경유), stdout+stderr
_cm() { CMUX_SOURCE_ONLY= zsh "$CMUX_UNDER_TEST" "$@" 2>&1; }
TODAY="$(strftime '%Y%m%d' $EPOCHSECONDS)"

# ── S1 ────────────────────────────────────────────────
t_scenario S1 "_tabs_load — 새 포맷 읽기"
_lines "$A" "$B${T}codex" "" "$U_TMP/ghost${T}opencode" "$G${T}opencode" "$A${T}claude" "$B${T}codex" \
  "$X${T}bogus" "$A${T}codex" > "$TABS_FILE"
t_assert_eq "혼합: 순서 유지, 빈 줄·없는 경로·미등록 에이전트(줄 전체를 경로로 봄) 건너뜀, 같은 spec 1번" \
  "$(_lines "$A" "$B${T}codex" "$G${T}opencode" "$A${T}codex")" "$(_tabs_load)"
_lines "$B" "$A" > "$TABS_FILE"
t_assert_eq "구포맷(경로만) = claude" "$(_lines "$B" "$A")" "$(_tabs_load)"
_lines "$A${T}claude" "$A" > "$TABS_FILE"
t_assert_eq "'경로<TAB>claude' = '경로' (정규형, 중복 1번)" "$A" "$(_tabs_load)"
# _spec_parse — 모든 소비자가 쓰는 해석기: 구포맷 줄·TAB 줄·공백 경로·'·'가 든 경로
_sp() { _spec_parse "$1"; print -r -- "${reply[1]}|${reply[2]}|${#reply}"; }
SP="$U_TMP/with space/proj x" DOTDIR="$U_TMP/dot/alpha·codex"
mkdir -p "$SP" "$DOTDIR"
t_assert_eq "_spec_parse 구포맷(경로만) → claude" "$A|claude|2" "$(_sp "$A")"
t_assert_eq "_spec_parse 경로<TAB>codex" "$A|codex|2" "$(_sp "$A${T}codex")"
t_assert_eq "_spec_parse 경로<TAB>claude" "$A|claude|2" "$(_sp "$A${T}claude")"
t_assert_eq "_spec_parse 공백 경로" "$SP|claude|2" "$(_sp "$SP")"
t_assert_eq "_spec_parse 공백 경로<TAB>opencode" "$SP|opencode|2" "$(_sp "$SP${T}opencode")"
t_assert_eq "_spec_parse '·'가 든 경로(my·proj)" "$MP|claude|2" "$(_sp "$MP")"
t_assert_eq "_spec_parse '·'가 든 경로<TAB>codex" "$MP|codex|2" "$(_sp "$MP${T}codex")"
t_assert_eq "_spec_parse 폴더 이름이 'alpha·codex'(TAB 없음) → 경로 전체·claude" "$DOTDIR|claude|2" "$(_sp "$DOTDIR")"
t_assert_eq "_spec_parse 경로<TAB>(빈 에이전트) → claude" "$A|claude|2" "$(_sp "$A${T}")"
_lines "$SP" "$SP${T}opencode" "$MP${T}codex" "$DOTDIR" "$DOTDIR${T}codex" > "$TABS_FILE"
t_assert_eq "_tabs_load — 공백·'·' 경로 정규형 그대로" \
  "$(_lines "$SP" "$SP${T}opencode" "$MP${T}codex" "$DOTDIR" "$DOTDIR${T}codex")" "$(_tabs_load)"
rm -f -- "$TABS_FILE"
_tabs_save "$SP" "$SP${T}opencode" "$MP${T}codex" "$DOTDIR${T}codex"
t_assert_eq "_tabs_save → _tabs_load 왕복 (공백·'·' 경로)" \
  "$(_lines "$SP" "$SP${T}opencode" "$MP${T}codex" "$DOTDIR${T}codex")" "$(_tabs_load)"
_tab_name "$DOTDIR";       t_assert_eq "탭 이름: 폴더 'alpha·codex'의 claude 탭" "alpha·codex" "$REPLY"
_tab_name "$SP" opencode;  t_assert_eq "탭 이름: 공백 경로" "proj x·opencode" "$REPLY"

# ── S2 ────────────────────────────────────────────────
t_scenario S2 "_tabs_save — claude 경로만, 비-claude TAB, .bak 1회"
rm -f -- "$TABS_FILE" "$TABS_FILE".bak-*(N)
_tabs_save "$A" "$B${T}codex" "$A${T}claude" "$A${T}codex" "$B${T}codex" "" "$G${T}opencode"
t_assert_eq "claude 평문·나머지 TAB, 정규 spec 단위 중복 제거(같은 경로 다른 에이전트는 유지)" \
  "$(_lines "$A" "$B${T}codex" "$A${T}codex" "$G${T}opencode")" "$(_file)"
t_assert_eq "기록 파일이 없었으면 .bak 없음" "" "$(print -l -- "$TABS_FILE".bak-*(N))"
before="$(_file)"
_tabs_save "${(@f)$(_tabs_load)}"
t_assert_eq "왕복 (_tabs_load → _tabs_save) 내용 동일" "$before" "$(_file)"
_lines "$A" "$B" > "$TABS_FILE"
_tabs_save "$A" "$G"
t_assert_eq "claude만 → 구포맷과 동일, .bak 없음" "$(_lines "$A" "$G")|" "$(_file)|$(print -l -- "$TABS_FILE".bak-*(N))"
_lines "$A" "$B" "" > "$TABS_FILE"
cp -- "$TABS_FILE" "$U_TMP/orig"
_tabs_save "$A" "$B${T}codex"
t_assert_eq "비-claude 첫 기록 → .bak-<오늘> 생성" "$TABS_FILE.bak-$TODAY" "$(print -l -- "$TABS_FILE".bak-*(N))"
t_assert_true ".bak 내용 = 기록 직전 파일 (바이트 동일)" 'cmp -s "$U_TMP/orig" "$TABS_FILE.bak-$TODAY"'
_tabs_save "$G${T}opencode" "$A"
t_assert_true "이미 TAB 줄이 있는 파일 → .bak 그대로" 'cmp -s "$U_TMP/orig" "$TABS_FILE.bak-$TODAY"'
_tabs_save "$A"
_tabs_save "$A" "$B${T}opencode"
t_assert_true "그날 .bak이 이미 있으면 건너뜀 (덮어쓰지 않음)" 'cmp -s "$U_TMP/orig" "$TABS_FILE.bak-$TODAY"'
t_assert_eq ".bak 파일은 1개" 1 "$(print -l -- "$TABS_FILE".bak-*(N) | grep -c .)"

# ── S3 ────────────────────────────────────────────────
t_scenario S3 "_tabs_append — 정규 spec 단위 중복 제거"
TABS_FILE="$U_TMP/append/session-tabs"
_tabs_append "$A"
_tabs_append "$A${T}codex" "$A${T}claude" "$A${T}codex" "$B${T}opencode" "$B"
t_assert_eq "같은 경로 다른 에이전트 허용, 같은 spec 1번('경로<TAB>claude' = '경로')" \
  "$(_lines "$A" "$A${T}codex" "$B${T}opencode" "$B")" "$(_file)"
t_assert_eq "새 파일에 처음부터 쓴 경우 — 첫 줄이 claude라 .bak 생성(내용 = 경로 1줄)" "$A" "$(cat "$TABS_FILE.bak-$TODAY" 2>/dev/null)"
_lines "$G${T}claude" > "$TABS_FILE"
_tabs_append "$G"
t_assert_eq "손으로 쓴 '경로<TAB>claude' 줄이 있으면 claude 추가 안 함" "$G${T}claude" "$(_file)"
TABS_FILE="$U_TMP/append2/session-tabs"
_tabs_append "$B${T}codex"
t_assert_eq "빈 기록에 비-claude 추가 → .bak 없음(보존할 내용 없음)" "$B${T}codex|" "$(_file)|$(print -l -- "$TABS_FILE".bak-*(N))"
TABS_FILE="$CMUX_TABS_FILE"

# ── S4 ────────────────────────────────────────────────
t_scenario S4 "_tab_name · _tabs_sync_live 접미사 파싱"
_tab_name "$A";          t_assert_eq "claude(생략) → basename" "alpha" "$REPLY"
_tab_name "$A" claude;   t_assert_eq "claude → basename" "alpha" "$REPLY"
_tab_name "$A" codex;    t_assert_eq "codex → basename·codex (U+00B7)" "alpha·codex" "$REPLY"
_tab_name "$MP" opencode; t_assert_eq "이름에 ·가 있는 프로젝트" "my·proj·opencode" "$REPLY"

U_NAMES=""
zellij() {
  print -r -- "$*" >> "$U_TMP/stub-calls"
  if [[ "$1" == "list-sessions" ]]; then
    print -r -- "$SESSION_NAME [Created 1s ago] "
  elif [[ "$1 $2 $3 $4" == "-s $SESSION_NAME action query-tab-names" ]]; then
    [[ -n "$U_NAMES" ]] && print -r -- "$U_NAMES"
  fi
  return 0
}
_sync() {  # <탭 이름들(줄바꿈)> <기록 줄...> → 동기화 후 기록 내용
  U_NAMES="$1"; shift
  _lines "$@" > "$TABS_FILE"
  _tabs_sync_live 2> "$U_TMP/sync-err"
  _file
}
t_assert_eq "claude·codex 같은 프로젝트 2탭 + opencode — 그대로" "$(_lines "$A" "$A${T}codex" "$B${T}opencode")" \
  "$(_sync $'alpha\nalpha·codex\nbeta·opencode' "$A" "$A${T}codex" "$B${T}opencode")"
t_assert_eq "실제 탭 순서로 재정렬 (에이전트 유지)" "$(_lines "$B${T}opencode" "$A${T}codex" "$A")" \
  "$(_sync $'beta·opencode\nalpha·codex\nalpha' "$A" "$A${T}codex" "$B${T}opencode")"
t_assert_eq "닫힌 탭(alpha·codex)은 빠지고 같은 경로 claude 탭은 유지" "$A" \
  "$(_sync 'alpha' "$A" "$A${T}codex")"
t_assert_eq "기록에 없던 gamma·codex → 프로젝트 목록에서 경로 + 접미사 에이전트" "$(_lines "$A" "$G${T}codex")" \
  "$(_sync $'alpha\ngamma·codex' "$A")"
t_assert_eq "이름에 ·가 있고 접미사가 미등록(my·proj) → 이름 전체 = claude 탭" "$MP" "$(_sync 'my·proj' "$MP")"
t_assert_eq "my·proj·codex → my·proj + codex" "$(_lines "$MP" "$MP${T}codex")" \
  "$(_sync $'my·proj\nmy·proj·codex' "$MP")"
t_assert_eq "같은 basename 다른 경로 — 기록 순서대로 배정 (codex 2탭)" "$(_lines "$X${T}codex" "$Y${T}codex")" \
  "$(_sync $'proj·codex\nproj·codex' "$X${T}codex" "$Y${T}codex")"
t_assert_eq "같은 basename — 에이전트가 맞는 기록으로 배정" "$(_lines "$Y${T}codex" "$X")" \
  "$(_sync $'proj·codex\nproj' "$X" "$Y${T}codex")"
t_assert_eq "개명 탭 → 매핑된 것 먼저 + 기존 기록 병합" "$(_lines "$A${T}codex" "$A")" \
  "$(_sync $'alpha·codex\nrenamed' "$A" "$A${T}codex")"
t_assert_contains "병합 경고 (stderr)" "$(cat "$U_TMP/sync-err")" "경로를 알 수 없는 탭 1개"
t_assert_eq "접미사가 등록 에이전트지만 경로를 모름(zzz·codex) → 병합" "$(_lines "$A" "$B${T}codex")" \
  "$(_sync $'alpha\nzzz·codex' "$A" "$B${T}codex")"
t_assert_eq "미등록 접미사(alpha·bogus) → 이름 전체로 찾다 실패 → 병합" "$(_lines "$A" "$A${T}codex")" \
  "$(_sync $'alpha\nalpha·bogus' "$A" "$A${T}codex")"
t_assert_eq "구포맷 기록 + 새 이름 규칙" "$(_lines "$B" "$A")" "$(_sync $'beta\nalpha' "$A" "$B")"
unfunction zellij

# ── S5 ────────────────────────────────────────────────
t_scenario S5 "default 우선순위 · 설정 파일 · cmux default"
_dflt() { ( unset _cmux_default_agent; _default_agent; print -r -- "$REPLY|${_cmux_default_src%% — *}" ) 2>&1; }
t_assert_eq "env·설정 없음 → claude(기본값)" "claude|기본값" "$(_dflt)"
t_assert_eq "설정 CMUX_DEFAULT_AGENT=codex" "codex|설정 CMUX_DEFAULT_AGENT" "$(CMUX_DEFAULT_AGENT=codex _dflt)"
t_assert_eq "env CMUX_AGENT가 설정보다 우선" "opencode|환경변수 CMUX_AGENT" "$(CMUX_AGENT=opencode CMUX_DEFAULT_AGENT=codex _dflt)"
out="$(CMUX_AGENT=bogus _dflt)"
t_assert_contains "미등록 값 → 경고" "$out" "기본 에이전트 'bogus'(환경변수 CMUX_AGENT)는 등록되지 않았습니다 — claude를 씁니다"
t_assert_eq "미등록 값 → claude" "claude|기본값" "${out##*$'\n'}"
out="$( ( unset _cmux_default_agent; CMUX_DEFAULT_AGENT=zzz; _default_agent; _default_agent; print -r -- "$REPLY" ) 2>&1)"
t_assert_eq "경고는 프로세스당 1회" 1 "$(print -r -- "$out" | grep -c '등록되지 않았습니다')"

rm -f -- "$CMUX_CONFIG_FILE"
t_assert_eq "cmux default (설정 없음)" "기본 에이전트: claude  (기본값)" "$(_cm default)"
print -r -- "CMUX_DEFAULT_AGENT=opencode" > "$CMUX_CONFIG_FILE"
t_assert_eq "cmux default — 설정 파일을 맨 먼저 source" "기본 에이전트: opencode  (설정 CMUX_DEFAULT_AGENT — $CMUX_CONFIG_FILE)" "$(_cm default)"
t_assert_eq "cmux default — env CMUX_AGENT 우선" "기본 에이전트: codex  (환경변수 CMUX_AGENT)" "$(CMUX_AGENT=codex _cm default)"
print -r -l -- "CMUX_DEFAULT_AGENT=codex" 'if [[ ; then' > "$CMUX_CONFIG_FILE"
out="$(_cm default; print -r -- "rc=$?")"
t_assert_eq "구문 오류 설정 → 오류 무시하고 계속 (앞줄 값은 적용)" \
  "기본 에이전트: codex  (설정 CMUX_DEFAULT_AGENT — $CMUX_CONFIG_FILE)"$'\n'"rc=0" "$out"
print -r -- "CMUX_DEFAULT_AGENT=bogus" > "$CMUX_CONFIG_FILE"
out="$(_cm default)"
t_assert_contains "설정 값 미등록 → 경고" "$out" "기본 에이전트 'bogus'(설정 CMUX_DEFAULT_AGENT)는 등록되지 않았습니다"
t_assert_contains "설정 값 미등록 → claude" "$out" "기본 에이전트: claude  (기본값)"

# 쓰기
CFG2="$U_TMP/newcfg/sub/config"
out="$(CMUX_CONFIG_FILE="$CFG2" _cm default codex; print -r -- "rc=$?")"
t_assert_contains "파일·디렉토리 없음 → 생성, 확인 메시지" "$out" "기본 에이전트 = codex  (설정: $CFG2)"
t_assert_eq "새 설정 파일 내용" "CMUX_DEFAULT_AGENT=codex" "$(cat "$CFG2" 2>/dev/null)"
print -r -l -- "# cmux 설정" "CMUX_CODEX_PERM=auto" "  export CMUX_DEFAULT_AGENT=claude" "FOO=1" "CMUX_DEFAULT_AGENT=opencode" "# CMUX_DEFAULT_AGENT=x" > "$CMUX_CONFIG_FILE"
ino0="$(stat -f %i "$CMUX_CONFIG_FILE")"
_cm default opencode >/dev/null
t_assert_eq "기존 줄 교체(첫 위치), 중복 줄 제거, 다른 줄·주석 보존" \
  "$(_lines "# cmux 설정" "CMUX_CODEX_PERM=auto" "CMUX_DEFAULT_AGENT=opencode" "FOO=1" "# CMUX_DEFAULT_AGENT=x")" "$(cat "$CMUX_CONFIG_FILE")"
t_assert_true "원자적 교체 (tmp → mv: inode 바뀜, tmp 잔여 없음)" \
  '[[ "$(stat -f %i "$CMUX_CONFIG_FILE")" != "$ino0" && -z "$(print -l -- "$CMUX_CONFIG_FILE".tmp.*(N))" ]]'
print -r -l -- "FOO=1" > "$CMUX_CONFIG_FILE"
_cm default codex >/dev/null
t_assert_eq "줄이 없으면 끝에 추가" "$(_lines "FOO=1" "CMUX_DEFAULT_AGENT=codex")" "$(cat "$CMUX_CONFIG_FILE")"
sum0="$(md5 -q "$CMUX_CONFIG_FILE")"
out="$(_cm default nope; print -r -- "rc=$?")"
t_assert_contains "미등록 에이전트 → 오류 + 사용 가능 목록" "$out" "알 수 없는 에이전트: 'nope' (사용 가능: claude codex opencode)"
t_assert_contains "미등록 에이전트 → exit 1" "$out" "rc=1"
t_assert_eq "미등록 에이전트 → 파일 그대로" "$sum0" "$(md5 -q "$CMUX_CONFIG_FILE")"
out="$(CMUX_AGENT=claude _cm default opencode)"
t_assert_contains "env CMUX_AGENT가 다르면 우선 안내" "$out" "지금은 환경변수 CMUX_AGENT=claude 가 우선합니다"
mkdir -p "$U_TMP/real"; print -r -- "BAR=2" > "$U_TMP/real/config"; ln -s "$U_TMP/real/config" "$U_TMP/cfg/linked"
CMUX_CONFIG_FILE="$U_TMP/cfg/linked" _cm default codex >/dev/null
t_assert_eq "심볼릭 링크 설정 → 링크 유지, 대상 파일 갱신" "link|BAR=2 CMUX_DEFAULT_AGENT=codex" \
  "$([[ -L "$U_TMP/cfg/linked" ]] && print link)|$(cat "$U_TMP/real/config" | xargs)"
mkdir -p "$U_TMP/ro"; chmod 555 "$U_TMP/ro"
out="$(CMUX_CONFIG_FILE="$U_TMP/ro/config" _cm default codex; print -r -- "rc=$?")"
t_assert_contains "쓸 수 없는 디렉토리 → 오류·exit 1" "$out" "설정 파일을 쓰지 못했습니다: $U_TMP/ro/config"$'\n'"rc=1"
chmod 755 "$U_TMP/ro"

# 설정은 pane의 'cmux launch'에도 적용된다 (최상단 source)
LD="$U_TMP/ld"; mkdir -p "$LD"
: > "$FAKE_AGENT_LOG"
print -r -- "CMUX_CODEX_PERM=auto" > "$CMUX_CONFIG_FILE"
_cm launch "$LD" --agent codex >/dev/null
t_assert_eq "설정 CMUX_CODEX_PERM=auto → launch codex bypass" "fake-codex${T}$LD${T}resume --last --dangerously-bypass-approvals-and-sandbox" "$(tail -1 "$FAKE_AGENT_LOG")"
rm -f -- "$CMUX_CONFIG_FILE"
_cm launch "$LD" --agent codex >/dev/null
t_assert_eq "설정 없음 → launch codex safe" "fake-codex${T}$LD${T}resume --last -a never -s workspace-write" "$(tail -1 "$FAKE_AGENT_LOG")"
print -r -- "CMUX_DEFAULT_AGENT=codex" > "$CMUX_CONFIG_FILE"
_cm launch "$LD" >/dev/null
t_assert_eq "launch(--agent 없음)는 default와 무관하게 claude (설치된 claude 레이아웃 호환)" "fake-claude" "$(tail -1 "$FAKE_AGENT_LOG" | cut -f1)"
rm -f -- "$CMUX_CONFIG_FILE"

# ── S6 ────────────────────────────────────────────────
t_scenario S6 "레이아웃 — 세션(claude 바이트 동일)·new-tab 생성기·cmux-tab-<a>.kdl"
ZELLIJ_LAYOUTS_DIR="$U_TMP/layouts" SESSION_LAYOUT_FILE="$U_TMP/layouts/cmux-session.kdl" CMUX_BAR_BIN="$U_TMP/bin/bar-stub"
OLD_REV="${T_OLD_REV:-a1a07e9}"
mkdir -p "$U_TMP/old" "$U_TMP/oldlayouts"
if git -C "$T_REPO" show "$OLD_REV:bin/cmux" > "$U_TMP/old/cmux" 2>/dev/null \
   && git -C "$T_REPO" show "$OLD_REV:bin/cmux-agents.zsh" > "$U_TMP/old/cmux-agents.zsh" 2>/dev/null; then
  ( CMUX_LAYOUTS_DIR="$U_TMP/oldlayouts" CMUX_SOURCE_ONLY=1 source "$U_TMP/old/cmux"
    CMUX_SELF="$CMUX_UNDER_TEST" LAYOUT_FOCUS_DIR="$B" _make_layout "$A" "$B" "$MP" )
  LAYOUT_FOCUS_SPEC="$B" _make_layout "$A" "$B${T}claude" "$MP"
  # 상단 바 구조가 일부러 바뀌었다(zellij:tab-bar 플러그인 제거 + cmux-bar pane size 2→3, 탭 줄 토글 설계) —
  # 이전 구현 출력에 같은 변환만 적용하면 나머지(탭·포커스·본문·상태바)는 바이트 동일해야 한다.
  perl -0pe 's/        pane size=1 borderless=true \{\n            plugin location="zellij:tab-bar"\n        \}\n//; s/pane size=2( borderless=true \{\n            command)/pane size=3$1/' \
    "$U_TMP/oldlayouts/cmux-session.kdl" > "$U_TMP/oldlayouts/cmux-session.xform.kdl"
  t_assert_true "claude 전용 세션 레이아웃 = 이전 구현($OLD_REV) 출력에서 바 구조(tab-bar 제거·바 size 3)만 바꾼 것과 바이트 동일 (포커스 포함)" \
    'cmp -s "$U_TMP/oldlayouts/cmux-session.xform.kdl" "$SESSION_LAYOUT_FILE" && ! cmp -s "$U_TMP/oldlayouts/cmux-session.kdl" "$SESSION_LAYOUT_FILE"'
else
  t_skip "git show $OLD_REV 실패 — 이전 구현 비교 생략"
fi
LAYOUT_FOCUS_SPEC="$A${T}codex" _make_layout "$A" "$A${T}codex" "$B${T}opencode"
lay="$(cat "$SESSION_LAYOUT_FILE")"
t_assert_eq "탭 이름·순서" $'alpha\nalpha·codex\nbeta·opencode' "$(grep -o 'tab name="[^"]*"' <<< "$lay" | sed 's/tab name="//;s/"$//')"
t_assert_eq "포커스 = LAYOUT_FOCUS_SPEC 탭 하나" 'tab name="alpha·codex" cwd="'"$A"'" focus=true {' "$(grep 'tab name=.*focus=true' <<< "$lay" | sed 's/^ *//')"
t_assert_eq "launch 인자 (claude는 기존 그대로)" $'args "launch"\nargs "launch" "--agent" "codex"\nargs "launch" "--agent" "opencode"' \
  "$(grep 'args "launch"' <<< "$lay" | sed 's/^ *//')"
t_assert_eq "에이전트 pane 이름" $'claude\ncodex\nopencode' "$(grep -o 'focus=true name="[^"]*"' <<< "$lay" | sed 's/.*name="//;s/"$//')"
LAYOUT_FOCUS_SPEC= _make_layout "$B${T}codex" "$A"
t_assert_eq "LAYOUT_FOCUS_SPEC 없음 → 첫 탭 포커스" 'tab name="beta·codex"' "$(grep -o 'tab name="[^"]*" cwd="[^"]*" focus=true' "$SESSION_LAYOUT_FILE" | cut -d' ' -f1-2)"

sed -e "s|CMUX_BAR_BIN|$U_TMP/bin/bar-stub|g" -e "s|CMUX_BIN|$CMUX_SELF|g" "$T_REPO/zellij/layouts/claude-tab.kdl.tmpl" \
  | grep -v '^//' | grep -v '^$' > "$U_TMP/rendered-claude-tab.kdl"
t_assert_eq "new-tab 생성기(claude) = 렌더된 claude-tab.kdl (주석·빈 줄 제외)" "$(cat "$U_TMP/rendered-claude-tab.kdl")" "$(_kdl_tab_layout claude)"
t_assert_eq "new-tab 생성기(codex) = claude 것에서 pane 이름·launch 인자만 다름" \
  "$(sed -e 's/name="claude"/name="codex"/' -e 's/args "launch"$/args "launch" "--agent" "codex"/' "$U_TMP/rendered-claude-tab.kdl")" "$(_kdl_tab_layout codex)"
t_assert_not_contains "cmux-bar 없음 → bar pane 없음" "$(CMUX_BAR_BIN= _kdl_tab_layout codex)" "while true"
# 상단 바 규칙 (설계: 3행 고정) — cmux-bar 있으면 tab-bar 플러그인 없이 size=3 하나, 없으면 네이티브 tab-bar size=1 폴백
t_assert_not_contains "cmux-bar 있음 → new-tab 레이아웃에 zellij:tab-bar 없음" "$(_kdl_tab_layout codex)" "zellij:tab-bar"
t_assert_eq "cmux-bar 있음 → new-tab 레이아웃 바 pane = size=3" $'pane size=3 borderless=true {\npane size=2 borderless=true {' \
  "$(_kdl_tab_layout codex | grep -E 'pane size=[0-9] borderless' | sed 's/^ *//')"
t_assert_eq "cmux-bar 없음 → new-tab 레이아웃 = 네이티브 tab-bar size=1 폴백" $'pane size=1 borderless=true {\nplugin location="zellij:tab-bar"' \
  "$(CMUX_BAR_BIN= _kdl_tab_layout codex | grep -B1 'zellij:tab-bar' | sed 's/^ *//')"
LAYOUT_FOCUS_SPEC= _make_layout "$A"
t_assert_not_contains "cmux-bar 있음 → 세션 레이아웃에 zellij:tab-bar 없음" "$(cat "$SESSION_LAYOUT_FILE")" "zellij:tab-bar"
t_assert_contains "cmux-bar 있음 → 세션 레이아웃 바 pane = size=3 (default_tab_template 첫 pane)" \
  "$(grep -A1 'default_tab_template' "$SESSION_LAYOUT_FILE" | tail -1)" "pane size=3 borderless=true {"
CMUX_BAR_BIN= LAYOUT_FOCUS_SPEC= _make_layout "$A"
t_assert_contains "cmux-bar 없음 → 세션 레이아웃 = 네이티브 tab-bar size=1 폴백" \
  "$(grep -A2 'default_tab_template' "$SESSION_LAYOUT_FILE" | tail -2 | sed 's/^ *//' | paste -sd'|' -)" 'pane size=1 borderless=true {|plugin location="zellij:tab-bar"'
rm -f -- "$U_TMP"/layouts/cmux-tab-*(N)
_tab_layout claude
t_assert_eq "claude → 설치된 claude-tab, 파일 생성 없음" "claude-tab|" "$REPLY|$(print -l -- "$U_TMP"/layouts/cmux-tab-*(N))"
_tab_layout codex; rc=$?
t_assert_eq "codex → cmux-tab-codex (rc 0)" "cmux-tab-codex|0" "$REPLY|$rc"
t_assert_eq "생성 파일 내용 = 생성기 출력" "$(_kdl_tab_layout codex)" "$(cat "$U_TMP/layouts/cmux-tab-codex.kdl" 2>/dev/null)"
ino0="$(stat -f %i "$U_TMP/layouts/cmux-tab-codex.kdl")"
_tab_layout codex
t_assert_true "매번 원자적 덮어쓰기 (inode 바뀜, tmp 잔여 없음)" \
  '[[ "$(stat -f %i "$U_TMP/layouts/cmux-tab-codex.kdl")" != "$ino0" && -z "$(print -l -- "$U_TMP"/layouts/*.tmp.*(N))" ]]'
mkdir -p "$U_TMP/rolayouts"; chmod 555 "$U_TMP/rolayouts"
out="$(ZELLIJ_LAYOUTS_DIR="$U_TMP/rolayouts" _tab_layout opencode 2>&1; print -r -- "rc=$?")"
t_assert_contains "쓸 수 없는 레이아웃 디렉토리 → 경고·비0" "$out" "탭 레이아웃을 만들지 못했습니다: $U_TMP/rolayouts/cmux-tab-opencode.kdl"$'\n'"rc=1"
chmod 755 "$U_TMP/rolayouts"

# ── S7 ────────────────────────────────────────────────
t_scenario S7 "cmux -a / --agent / cmux <경로> (콜드 경로, 가짜 zellij)"
rm -f -- "$TABS_FILE" "$TABS_FILE".bak-*(N) "$CMUX_PROJECT_AGENTS_FILE" "$U_TMP/zellij-calls"
out="$(_cm -a bogus "$A"; print -r -- "rc=$?")"
t_assert_contains "미등록 에이전트 → 오류 + 사용 가능 목록" "$out" "알 수 없는 에이전트: 'bogus' (사용 가능: claude codex opencode)"
t_assert_contains "미등록 에이전트 → exit 1" "$out" "rc=1"
out="$(_cm -a; print -r -- "rc=$?")"
t_assert_contains "에이전트 생략 → 오류·exit 1" "$out" "사용법: cmux -a <에이전트> [경로]"$'\n'"rc=1"
out="$(_cm -a codex "$U_TMP/nope"; print -r -- "rc=$?")"
t_assert_contains "없는 경로 → 오류·exit 1" "$out" "디렉토리가 없습니다: $U_TMP/nope"$'\n'"rc=1"
t_assert_true "오류 경로는 zellij·기록 없음" '[[ ! -e "$U_TMP/zellij-calls" && ! -e "$TABS_FILE" ]]'
out="$(cd "$A" && _cm -a codex)"
t_assert_contains "경로 생략 → 현재 폴더, 탭 이름 alpha·codex" "$out" "프로젝트 열기: alpha·codex"
t_assert_eq "session-tabs = 현재 폴더<TAB>codex" "$A${T}codex" "$(_file)"
t_assert_eq "세션 레이아웃: codex launch" 'args "launch" "--agent" "codex"' "$(grep 'args "launch"' "$U_TMP/layouts/cmux-session.kdl" | sed 's/^ *//')"
t_assert_eq "zellij: 세션 확인 후 새 세션 (-s … -n 레이아웃)" \
  "list-sessions --no-formatting"$'\n'"-s $CMUX_SESSION -n $U_TMP/layouts/cmux-session.kdl" "$(cat "$U_TMP/zellij-calls")"
t_assert_eq "project-agents 기록" "$A${T}codex" "$(cat "$CMUX_PROJECT_AGENTS_FILE" 2>/dev/null)"
out="$(_cm --agent opencode "$B")"
t_assert_contains "--agent 동의어 + 이전 기록 함께 복원" "$out" "이전 세션 탭 1개도 함께 복원"
t_assert_eq "session-tabs = alpha·codex, beta·opencode" "$(_lines "$A${T}codex" "$B${T}opencode")" "$(_file)"
t_assert_eq "탭 이름 (세션 레이아웃)" $'alpha·codex\nbeta·opencode' "$(grep -o 'tab name="[^"]*"' "$U_TMP/layouts/cmux-session.kdl" | sed 's/tab name="//;s/"$//')"
out="$(_cm -a codex "$A")"
t_assert_eq "같은 spec 다시 → 중복 없이 맨 뒤로 (포커스)" "$(_lines "$B${T}opencode" "$A${T}codex")" "$(_file)"
# cmux <경로> = default 에이전트 (마지막 사용 기억은 적용하지 않음 — D5)
print -r -- "$G${T}opencode" >> "$CMUX_PROJECT_AGENTS_FILE"
rm -f -- "$TABS_FILE"
out="$(_cm "$G")"
t_assert_eq "cmux <경로> (default claude) → 경로만 기록, 기억(opencode) 무시" "$G" "$(_file)"
t_assert_contains "cmux <경로> → 탭 이름 = basename" "$out" "프로젝트 열기: gamma"
t_assert_eq "cmux <경로> claude → 세션 레이아웃 launch 인자 기존 그대로" 'args "launch"' "$(grep 'args "launch"' "$U_TMP/layouts/cmux-session.kdl" | sed 's/^ *//')"
rm -f -- "$TABS_FILE"
print -r -- "CMUX_DEFAULT_AGENT=codex" > "$CMUX_CONFIG_FILE"
out="$(_cm "$G")"
t_assert_eq "설정 default codex → cmux <경로>는 codex" "$G${T}codex" "$(_file)"
rm -f -- "$TABS_FILE"
out="$(_cm "$G" mytab)"
t_assert_contains "cmux <경로> <이름> → 지정 이름 유지" "$out" "프로젝트 열기: mytab"
rm -f -- "$CMUX_CONFIG_FILE"

# ── S8 ────────────────────────────────────────────────
t_scenario S8 "project-agents 기억 (_agent_remember)"
PROJECT_AGENTS_FILE="$U_TMP/pa/sub/project-agents"
_agent_remember "$A${T}codex"
t_assert_eq "파일·디렉토리 없음 → 생성" "$A${T}codex" "$(cat "$PROJECT_AGENTS_FILE" 2>/dev/null)"
print -r -l -- "/keep/one${T}claude" "$B${T}codex" "$A${T}opencode" "/keep/two${T}codex" "$B${T}opencode" > "$PROJECT_AGENTS_FILE"
_agent_remember "$B" "$G${T}opencode" "$G${T}codex"
t_assert_eq "같은 경로 줄 교체(제자리)·중복 줄 제거·다른 줄 보존·새 경로는 뒤에(같은 호출 안은 마지막 값)" \
  "$(_lines "/keep/one${T}claude" "$B${T}claude" "$A${T}opencode" "/keep/two${T}codex" "$G${T}codex")" "$(cat "$PROJECT_AGENTS_FILE")"
ln -s "$A" "$U_TMP/alias-alpha"
_agent_remember "$U_TMP/alias-alpha${T}claude"
t_assert_eq "심볼릭 링크 경로 → 실제 경로 줄을 교체" "$A${T}claude|" \
  "$(grep -F "$A" "$PROJECT_AGENTS_FILE")|$(grep -F alias-alpha "$PROJECT_AGENTS_FILE")"
t_assert_eq "tmp 잔여 없음" "" "$(print -l -- "${PROJECT_AGENTS_FILE}".tmp.*(N))"
mkdir -p "$U_TMP/pa-ro"; print -r -- "x${T}claude" > "$U_TMP/pa-ro/pa"; chmod 555 "$U_TMP/pa-ro"
out="$(PROJECT_AGENTS_FILE="$U_TMP/pa-ro/pa" _agent_remember "$A${T}codex" 2>&1; print -r -- "rc=$?")"
t_assert_eq "쓸 수 없음 → 조용히 rc 0, 파일 그대로" "rc=0|x${T}claude" "$out|$(cat "$U_TMP/pa-ro/pa")"
chmod 755 "$U_TMP/pa-ro"
PROJECT_AGENTS_FILE="$CMUX_PROJECT_AGENTS_FILE"

# ── S9 ────────────────────────────────────────────────
t_scenario S9 "_pick env · _pick_flow 파싱 · fzf 폴백"
# 스텁 picker: 받은 env를 기록하고 $U_TMP/picker-out 내용을 출력, exit ${STUB_RC:-0}
cat > "$U_TMP/bin/stub-picker" <<SH
#!/bin/sh
printf 'AGENTS=%s|DEFAULT=%s|PREFS=%s|ROOT=%s\n' "\$CMUX_PICKER_AGENTS" "\$CMUX_PICKER_DEFAULT_AGENT" "\$CMUX_PICKER_PREFS_FILE" "\$CMUX_ROOT" > "$U_TMP/picker-env"
cat "$U_TMP/picker-out" 2>/dev/null
exit \${STUB_RC:-0}
SH
chmod +x "$U_TMP/bin/stub-picker"
CMUX_PICKER_BIN="$U_TMP/bin/stub-picker"
: > "$U_TMP/picker-out"
_penv() { ( unset _cmux_default_agent; _pick >/dev/null; cat "$U_TMP/picker-env" ) 2>/dev/null; }
t_assert_eq "env 3종 + CMUX_ROOT (전부 설치·default claude)" \
  "AGENTS=claude codex opencode|DEFAULT=claude|PREFS=$CMUX_PROJECT_AGENTS_FILE|ROOT=$DEV_ROOT" "$(_penv)"
t_assert_eq "미설치 에이전트(opencode) 제외" "AGENTS=claude codex|DEFAULT=claude" "$(CMUX_OPENCODE_BIN=/nonexistent/opencode _penv | cut -d'|' -f1-2)"
t_assert_eq "default는 미설치여도 포함, 등록 순서 유지" "AGENTS=codex opencode|DEFAULT=codex" \
  "$(CMUX_CLAUDE_BIN=/nonexistent/claude CMUX_CODEX_BIN=/nonexistent/codex CMUX_AGENT=codex _penv | cut -d'|' -f1-2)"

# _pick_flow — _open_one/_open_many 기록 스텁
_open_one()  { print -r -- "one|$CMUX_FRESH|${(j:|:)@}" >> "$U_TMP/opened" }
_open_many() { print -r -- "many|$CMUX_FRESH|${(j:|:)@}" >> "$U_TMP/opened" }
_flow() {  # <picker 출력(줄바꿈)> → FLOW_OPENED(열기 기록) FLOW_OUT(화면) FLOW_RC
  print -r -- "$1" > "$U_TMP/picker-out"
  [[ -z "$1" ]] && : > "$U_TMP/picker-out"
  : > "$U_TMP/opened"
  ( unset _cmux_default_agent CMUX_FRESH; _pick_flow ) > "$U_TMP/flow-out" 2>&1
  FLOW_RC=$?
  FLOW_OUT="$(cat "$U_TMP/flow-out")"
  FLOW_OPENED="$(cat "$U_TMP/opened")"
}
_flow "$A"$'\n'"$B${T}codex"
t_assert_eq "경로 + 경로<TAB>codex → _open_many(spec), CMUX_FRESH=1" "many|1|$A${T}claude|$B${T}codex" "$FLOW_OPENED"
_flow "$G${T}opencode"
t_assert_eq "한 줄(경로<TAB>opencode) → _open_one" "one|1|$G${T}opencode" "$FLOW_OPENED"
CMUX_AGENT=codex _flow "$A"
t_assert_eq "default codex → 경로만 = codex" "one|1|$A${T}codex" "$FLOW_OPENED"
_flow "$G${T}bogus"
t_assert_eq "미등록 에이전트 줄 → default로 열기" "one|1|$G${T}claude" "$FLOW_OPENED"
t_assert_contains "미등록 에이전트 → 경고 1줄" "$FLOW_OUT" "알 수 없는 에이전트 'bogus' — 기본 에이전트(claude)로 엽니다: gamma"
_flow "$U_TMP/ghost${T}codex"$'\n'"$A"
t_assert_eq "없는 경로 줄은 건너뜀 (경로 부분만 검사)" "one|1|$A${T}claude" "$FLOW_OPENED"
t_assert_contains "없는 경로 → 경고" "$FLOW_OUT" "경로 없음 (건너뜀): $U_TMP/ghost"
t_assert_not_contains "없는 경로 경고는 경로만 표시 (TAB·에이전트 없음)" "$FLOW_OUT" "ghost${T}"
_flow ""
t_assert_eq "빈 출력(취소) → 열기 없음·exit 0" "|0" "$FLOW_OPENED|$FLOW_RC"
t_assert_contains "취소 → '취소됨'" "$FLOW_OUT" "취소됨"
STUB_RC=3 _flow ""
t_assert_eq "빈 출력 + picker 실패 → 열기 없음·exit 1" "|1" "$FLOW_OPENED|$FLOW_RC"
t_assert_contains "picker 실패 → 안내" "$FLOW_OUT" "프로젝트 선택기 실행 실패 (exit 3)"
# fzf 폴백 (picker 없음) — 스텁 fzf는 첫 줄을 고른다 → default 에이전트
fzf() { head -1 }
CMUX_PICKER_BIN= _flow ""
t_assert_eq "fzf 폴백 → default(claude)" "one|1|$A${T}claude" "$FLOW_OPENED"
CMUX_PICKER_BIN= CMUX_AGENT=codex _flow ""
t_assert_eq "fzf 폴백 → default(codex)" "one|1|$A${T}codex" "$FLOW_OPENED"
unfunction fzf _open_one _open_many

# ── S10 ───────────────────────────────────────────────
t_scenario S10 "도움말"
out="$(_cm -h)"
t_assert_contains "-a 항목" "$out" "cmux -a <에이전트> [경로]"
t_assert_contains "default 항목" "$out" "cmux default [에이전트]"
t_assert_contains "launch --agent 항목" "$out" "cmux launch [경로] --agent <에이전트>"
t_assert_contains "기존 launch 줄 유지" "$out" "cmux launch [경로] (내부용) Claude Code 실행 — 대화 기록 있으면 --continue"
t_assert_contains "설정 파일 안내" "$out" "설정:     $CMUX_CONFIG_FILE"
t_assert_contains "기본 에이전트 안내" "$out" "에이전트: claude codex opencode  — 기본 claude (기본값; 환경변수 CMUX_AGENT > 설정 > claude)"
t_assert_not_contains "sync/close-tab은 P2-C 몫 — 아직 없음" "$out" "close-tab"

t_summary
exit $?
