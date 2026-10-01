#!/usr/bin/env zsh
# t01_agents — 어댑터·launch 단위 테스트 (CMUX_SOURCE_ONLY=1 source, zellij·실제 에이전트 없음)
#   U1 source-only 로드: 함수 정의만, 디스패처·부작용(파일 쓰기·zellij 호출) 없음 / 어댑터 파일 없음 → 오류
#   U2 _ag_claude_bin 탐색 우선순위 (CMUX_CLAUDE_BIN → brew → /usr/local → PATH)
#   U3 _ag_claude_has_history: cli / sdk-cli만 / cli+최신 sdk-cli / 빈 폴더 / 논리·물리 경로 키 /
#      앞 30줄 안의 첫 "entrypoint" 키 / 본문 속 이스케이프된 텍스트 무시 / 키 없는 파일 / 파일 여러 개
#   U4 _agent_known · _agent_call 기본 구현
#   U5 _launch_agent: 인자 조합 · fastfail 재실행(1회만 · 이어하기일 때만 · 빠른 실패일 때만 · 신호 종료 제외) · 실행 파일 없음
#   U6 (PATH의 가짜 zellij로) 실제 zellij 호출 0

# 어서션 함수만 쓴다 — t_setup/t_finish(zellij 세션)는 쓰지 않는다
source "${0:A:h}/../lib/harness.zsh"

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

# 격리: 홈·탭 기록·세션명. PATH 맨 앞의 가짜 zellij는 호출을 기록만 한다(실제 zellij 호출 0 확인용)
mkdir -p "$U_TMP"/{home,bin,zdotdir}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
chmod +x "$U_TMP/bin/zellij"
export PATH="$U_TMP/bin:$PATH"
ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-claude"
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude"
export CMUX_SOURCE_ONLY=1

# ── U1 ────────────────────────────────────────────────
t_scenario U1 "CMUX_SOURCE_ONLY=1 source — 함수만 로드, 디스패처·부작용 없음"
out="$(source "$CMUX_UNDER_TEST" -h 2>&1; print -r -- "rc=$? after-source")"
t_assert_eq "source 후 계속 실행 (-h 디스패처 미실행·출력 없음)" "rc=0 after-source" "$out"
source "$CMUX_UNDER_TEST"
t_assert_eq "주요 함수 로드" "function function function function function function function" \
  "$(whence -w _launch_agent _agent_call _agent_known _ag_claude_has_history _tabs_load _tabs_append _tabs_sync_live | awk '{print $2}' | xargs)"
t_assert_eq "어댑터 = 대상 cmux 옆 cmux-agents.zsh" "${CMUX_UNDER_TEST:h}/cmux-agents.zsh" "$CMUX_AGENTS_LIB"
# P2-A: 등록 에이전트 확장 (claude → claude codex opencode)
t_assert_eq "등록 에이전트 = claude" "claude codex opencode" "${CMUX_AGENTS[*]}"
t_assert_eq "CLAUDE_BIN = CMUX_CLAUDE_BIN" "$CMUX_CLAUDE_BIN" "$CLAUDE_BIN"
t_assert_eq "홈에 파일 생성 없음" "" "$(ls -A "$HOME")"
t_assert_true "탭 기록 디렉토리 생성 없음" '[[ ! -e "$U_TMP/cfg" ]]'
t_assert_true "zellij 호출 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'
out="$(zsh "$CMUX_UNDER_TEST" -h 2>&1)"
t_assert_contains "env가 있어도 실행(source 아님)이면 디스패처 동작" "$out" "사용법: cmux"

mkdir -p "$U_TMP/lonely"
cp "$CMUX_UNDER_TEST" "$U_TMP/lonely/cmux"
out="$(source "$U_TMP/lonely/cmux" 2>&1; print -r -- "rc=$?")"
t_assert_contains "어댑터 없음 (source) → 오류" "$out" "에이전트 어댑터 파일이 없습니다"
t_assert_contains "어댑터 없음 (source) → return 1" "$out" "rc=1"
# 옆에 어댑터가 없으면 설치 위치(~/.local/bin/cmux-agents.zsh)로 폴백
mkdir -p "$HOME/.local/bin"
cp "${CMUX_UNDER_TEST:h}/cmux-agents.zsh" "$HOME/.local/bin/cmux-agents.zsh"
out="$(source "$U_TMP/lonely/cmux" 2>&1; print -r -- "rc=$? lib=$CMUX_AGENTS_LIB $(whence -w _ag_claude_has_history)")"
t_assert_eq "어댑터 폴백 (~/.local/bin) → 로드" \
  "rc=0 lib=$HOME/.local/bin/cmux-agents.zsh _ag_claude_has_history: function" "$out"
rm -f -- "$HOME/.local/bin/cmux-agents.zsh"
out="$(CMUX_SOURCE_ONLY= zsh "$U_TMP/lonely/cmux" -h 2>&1; print -r -- "rc=$?")"
t_assert_contains "어댑터 없음 (실행) → exit 1, 도움말 대신 오류" "$out" $'설치하세요)\nrc=1'

# ── U2 ────────────────────────────────────────────────
t_scenario U2 "_ag_claude_bin 탐색 우선순위"
CMUX_CLAUDE_BIN=/custom/claude _agent_call claude bin
t_assert_eq "CMUX_CLAUDE_BIN이 최우선 (brew보다 앞)" "/custom/claude" "$REPLY"
if [[ -x /opt/homebrew/bin/claude ]]; then
  CMUX_CLAUDE_BIN= _agent_call claude bin
  t_assert_eq "비어 있으면 brew" "/opt/homebrew/bin/claude" "$REPLY"
  t_skip "/usr/local·PATH 폴백 — 이 머신은 brew claude가 있어 도달 불가"
elif [[ -x /usr/local/bin/claude ]]; then
  CMUX_CLAUDE_BIN= _agent_call claude bin
  t_assert_eq "비어 있으면 /usr/local" "/usr/local/bin/claude" "$REPLY"
  t_skip "PATH 폴백 — 이 머신은 /usr/local/bin/claude가 있어 도달 불가"
else
  mkdir -p "$U_TMP/pathbin"
  print -r -- '#!/bin/sh' > "$U_TMP/pathbin/claude"
  chmod +x "$U_TMP/pathbin/claude"
  CMUX_CLAUDE_BIN= PATH="$U_TMP/pathbin:$PATH" _agent_call claude bin
  t_assert_eq "비어 있으면 PATH" "$U_TMP/pathbin/claude" "$REPLY"
  CMUX_CLAUDE_BIN= PATH="$U_TMP/bin" _agent_call claude bin
  t_assert_eq "어디에도 없으면 비0" "1" "$?"
fi

# ── U3 ────────────────────────────────────────────────
t_scenario U3 "_ag_claude_has_history — sdk-cli 세션 제외"
# _pdir <프로젝트 경로> — 그 경로의 트랜스크립트 폴더를 만들고 REPLY로 돌려준다
_pdir() { REPLY="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"; mkdir -p "$REPLY"; }
# _mk <프로젝트 경로> <파일 이름> <entrypoint | - (entrypoint 없는 '{}')> [touch -t 시각]
_mk() {
  _pdir "$1"
  if [[ "$3" == "-" ]]; then
    print -r -- '{}' > "$REPLY/$2.jsonl"
  else
    print -r -l -- '{"type":"queue-operation"}' "{\"type\":\"user\",\"entrypoint\":\"$3\"}" > "$REPLY/$2.jsonl"
  fi
  [[ -n "$4" ]] && touch -t "$4" "$REPLY/$2.jsonl"
  return 0
}
_hh() { _ag_claude_has_history "$1" && print yes || print no; }
D="$U_TMP/p"
mkdir -p "$D"/{cli,sdk,mix,mix2,empty,none,plain,l6,l30,l31,spaced,clifirst,sdkfirst,escaped,mid,many}
_mk "$D/cli" a cli
_mk "$D/sdk" s1 sdk-cli; _mk "$D/sdk" s2 sdk-cli
_mk "$D/mix" a cli 202601010000;   _mk "$D/mix" s sdk-cli
_mk "$D/mix2" s sdk-cli 202601010000; _mk "$D/mix2" a cli
_pdir "$D/empty"
_mk "$D/plain" x -
# 앞 30줄 안의 첫 "entrypoint" 키로 판정 — 6·30번째 줄의 sdk-cli는 보고, 31번째 줄은 안 본다
_filler() { repeat $1 print -r -- '{}'; }
_pdir "$D/l6";  { _filler 5;  print -r -- '{"entrypoint":"sdk-cli"}'; } > "$REPLY/x.jsonl"
_pdir "$D/l30"; { _filler 29; print -r -- '{"entrypoint":"sdk-cli"}'; } > "$REPLY/x.jsonl"
_pdir "$D/l31"; { _filler 30; print -r -- '{"entrypoint":"sdk-cli"}'; } > "$REPLY/x.jsonl"
_pdir "$D/spaced"; print -r -l -- '{"type":"queue-operation"}' '{"type":"user", "entrypoint" : "sdk-cli"}' > "$REPLY/s.jsonl"
# 첫 키만 본다
_pdir "$D/clifirst"; print -r -l -- '{"entrypoint":"cli"}' '{"entrypoint":"sdk-cli"}' > "$REPLY/x.jsonl"
_pdir "$D/sdkfirst"; print -r -l -- '{"entrypoint":"sdk-cli"}' '{"entrypoint":"cli"}' > "$REPLY/x.jsonl"
# 본문 텍스트 속 이스케이프된 \"entrypoint\": \"sdk-cli\" 는 키가 아니다 (실제 키는 다음 줄의 cli)
_pdir "$D/escaped"
print -r -l -- '{"type":"queue-operation"}' '{"message":{"content":"예: \"entrypoint\": \"sdk-cli\" 인 파일"}}' \
  '{"type":"user","entrypoint":"cli"}' > "$REPLY/x.jsonl"
# 키 없는 파일이 sdk-cli 파일들 사이에 있어도 이력으로 본다 (최신 → 오래된 순: sdk-cli, 키 없음, sdk-cli)
_mk "$D/mid" s1 sdk-cli 202601010000; _mk "$D/mid" x - 202601010100; _mk "$D/mid" s2 sdk-cli
# 파일 50개: 최신 sdk-cli 49개 + 가장 오래된 cli 1개
_pdir "$D/many"
for i in {1..49}; do print -r -l -- '{"x":1}' '{"entrypoint":"sdk-cli"}' > "$REPLY/s$i.jsonl"; done
print -r -- '{"entrypoint":"cli"}' > "$REPLY/a.jsonl"; touch -t 202601010000 "$REPLY/a.jsonl"
t_assert_eq "cli 세션 → 있음" yes "$(_hh "$D/cli")"
t_assert_eq "sdk-cli 세션만 → 없음" no "$(_hh "$D/sdk")"
t_assert_eq "cli + 더 최신 sdk-cli → 있음" yes "$(_hh "$D/mix")"
t_assert_eq "sdk-cli + 더 최신 cli → 있음" yes "$(_hh "$D/mix2")"
t_assert_eq "빈 프로젝트 폴더 → 없음" no "$(_hh "$D/empty")"
t_assert_eq "프로젝트 폴더 없음 → 없음" no "$(_hh "$D/none")"
t_assert_eq "entrypoint 없는 파일('{}') → 있음 (기준선 B1 형태)" yes "$(_hh "$D/plain")"
t_assert_eq "6번째 줄의 sdk-cli → 없음 (30줄 창)" no "$(_hh "$D/l6")"
t_assert_eq "30번째 줄의 sdk-cli → 없음" no "$(_hh "$D/l30")"
t_assert_eq "31번째 줄은 안 봄 → 있음" yes "$(_hh "$D/l31")"
t_assert_eq "공백 있는 \"entrypoint\" : \"sdk-cli\" → 없음" no "$(_hh "$D/spaced")"
t_assert_eq "첫 키 cli (다음 줄 sdk-cli) → 있음" yes "$(_hh "$D/clifirst")"
t_assert_eq "첫 키 sdk-cli (다음 줄 cli) → 없음" no "$(_hh "$D/sdkfirst")"
t_assert_eq "본문 속 이스케이프된 \"entrypoint\" 텍스트는 키 아님 → 있음" yes "$(_hh "$D/escaped")"
t_assert_eq "sdk-cli 사이의 키 없는 파일 → 있음" yes "$(_hh "$D/mid")"
t_assert_eq "sdk-cli 49개 + 가장 오래된 cli → 있음" yes "$(_hh "$D/many")"
t_assert_eq "판정 중 stderr 출력 없음" "" "$(_ag_claude_has_history "$D/many" 2>&1 >/dev/null; _ag_claude_has_history "$D/sdk" 2>&1 >/dev/null)"
t_assert_eq "인자 없으면 \$PWD" yes "$(cd "$D/cli" && _ag_claude_has_history && print yes || print no)"

# 논리 경로(심볼릭 링크) vs 물리 경로 — 키를 둘 다 본다
mkdir -p "$U_TMP/real"/{phys,logi,both}
ln -s "$U_TMP/real" "$U_TMP/link"
_mk "$U_TMP/real/phys" a cli                       # 물리 경로 키에만 cli
_mk "$U_TMP/link/logi" a cli                       # 논리 경로 키에만 cli
_mk "$U_TMP/link/both" s sdk-cli; _mk "$U_TMP/real/both" s sdk-cli
t_assert_eq "논리 경로로 물어도 물리 경로 키의 cli → 있음" yes "$(_hh "$U_TMP/link/phys")"
t_assert_eq "논리 경로 키의 cli → 있음" yes "$(_hh "$U_TMP/link/logi")"
t_assert_eq "물리 경로로 물으면 논리 키는 모름 → 없음" no "$(_hh "$U_TMP/real/logi")"
t_assert_eq "두 키 모두 sdk-cli만 → 없음" no "$(_hh "$U_TMP/link/both")"

# ── U4 ────────────────────────────────────────────────
t_scenario U4 "_agent_known · _agent_call 기본 구현"
t_assert_eq "_agent_known claude/nope/빈 값" "0 1 1" \
  "$(_agent_known claude; print -n "$? "; _agent_known nope; print -n "$? "; _agent_known ""; print -n $?)"
_agent_call claude perm_args auto; t_assert_eq "claude perm_args auto" "--dangerously-skip-permissions" "${reply[*]}"
_agent_call claude perm_args safe; t_assert_eq "claude perm_args safe → 없음" "0" "${#reply}"
_agent_call claude resume_args;    t_assert_eq "claude resume_args" "--continue" "${reply[*]}"
reply=(stale); _agent_call claude fresh_args
t_assert_eq "claude fresh_args → 기본 구현(없음)" "0" "${#reply}"
_agent_call claude fastfail; t_assert_eq "claude fastfail" "5" "$REPLY"
_agent_call claude label;    t_assert_eq "claude label" "Claude Code" "$REPLY"
_agent_call zzz label;       t_assert_eq "미등록 기본 label = 이름" "zzz" "$REPLY"
_agent_call zzz has_history "$D/cli"; t_assert_eq "기본 has_history → 없음(1)" "1" "$?"
CMUX_ZZZ_BIN=/p/zzz _agent_call zzz bin; t_assert_eq "기본 bin = CMUX_<이름>_BIN" "/p/zzz" "$REPLY"
_agent_call zzz bin; t_assert_eq "기본 bin 못 찾으면 비0" "1" "$?"

# ── U5 ────────────────────────────────────────────────
t_scenario U5 "_launch_agent — 인자 · fastfail 재실행 · 실행 파일 없음"
export FAKE_AGENT_LOG="$U_TMP/fake.log" FAKE_AGENT_SLEEP=0
: > "$FAKE_AGENT_LOG"
_launch() { (cd "$1" && _launch_agent claude); }   # <디렉토리> — 서브셸(종료코드만 받는다)
PERM="--dangerously-skip-permissions"

_launch "$D/cli";  t_assert_eq "cli → rc 0" 0 $?
t_assert_eq "cli → perm + --continue, 1회" "$PERM --continue" "$(t_agent_args claude "$D/cli")"
_launch "$D/sdk";  t_assert_eq "sdk-cli만 → perm만, 1회" "$PERM" "$(t_agent_args claude "$D/sdk")"

: > "$FAKE_AGENT_LOG"
FAKE_AGENT_FAIL_ON=--continue _launch "$D/cli"
t_assert_eq "--continue 즉시 실패 → 재실행 성공 rc 0" 0 $?
t_assert_eq "재실행은 --continue 없이" "$PERM --continue"$'\n'"$PERM" "$(t_agent_args claude "$D/cli")"

: > "$FAKE_AGENT_LOG"
FAKE_AGENT_FAIL_ON="$PERM" _launch "$D/cli"
t_assert_eq "둘 다 실패 → 최종 rc 1" 1 $?
t_assert_eq "재실행은 1회만 (총 2회)" 2 "$(t_agent_launches claude "$D/cli")"
FAKE_AGENT_FAIL_ON="$PERM" _launch "$D/none"
t_assert_eq "이어하기 아님 → 실패 rc 1 그대로" 1 $?
t_assert_eq "이어하기 아님 → 재실행 없음 (1회)" 1 "$(t_agent_launches claude "$D/none")"

: > "$FAKE_AGENT_LOG"
( _ag_claude_fastfail() { REPLY=0 }; FAKE_AGENT_FAIL_ON=--continue _launch "$D/cli" )
t_assert_eq "fastfail=0(느린 실패) → rc 1 그대로" 1 $?
t_assert_eq "느린 실패 → 재실행 없음 (1회)" 1 "$(t_agent_launches claude "$D/cli")"

: > "$FAKE_AGENT_LOG"
FAKE_AGENT_FAIL_ON=--continue FAKE_AGENT_FAIL_SIGNAL=KILL _launch "$D/cli"
t_assert_eq "이어하기가 신호로 끝남 → rc 137 그대로" 137 $?
t_assert_eq "신호 종료(rc>128) → 재실행 없음 (1회)" 1 "$(t_agent_launches claude "$D/cli")"

# 실행 파일 없음 → 사유 출력 후 exec zsh -i (stdin=/dev/null이라 셸은 바로 끝난다)
: > "$FAKE_AGENT_LOG"
print -r -- 'print -r -- "zsh-i $PWD" >> "'"$U_TMP"'/zsh-i.log"' > "$ZDOTDIR/.zshrc"
out="$(CMUX_CLAUDE_BIN="$U_TMP/bin/no-such-claude" _launch "$D/cli" </dev/null 2>&1)"
t_assert_contains "실행 파일 없음 → 사유 1줄" "$out" "Claude Code 실행 파일을 찾지 못했습니다 (환경변수 CMUX_CLAUDE_BIN 로 지정)"
t_assert_eq "실행 파일 없음 → 같은 cwd에서 zsh -i" "zsh-i $D/cli" "$(cat "$U_TMP/zsh-i.log" 2>/dev/null)"
t_assert_eq "실행 파일 없음 → 에이전트 실행 없음" "" "$(cat "$FAKE_AGENT_LOG")"
out="$(CMUX_CLAUDE_BIN="$U_TMP/home" _launch "$D/cli" </dev/null 2>&1)"
t_assert_contains "디렉토리(실행 불가) → 실행 파일 없음 처리" "$out" "실행 파일을 찾지 못했습니다"

# ── U6 ────────────────────────────────────────────────
t_scenario U6 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
