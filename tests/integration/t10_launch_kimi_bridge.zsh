#!/usr/bin/env zsh
# t10_launch_kimi_bridge — Kimi 어댑터 + 지침 파일 연결을 실제 'cmux launch'(터미널 창(pty), zellij 세션 없음)로 확인 (가짜 에이전트)
#   M1 kimi launch — 기본 safe/이어하기(--yolo --continue)·배너·CMUX_KIMI_PERM=auto·인자 파일 줄·fastfail(이어하기 즉시 실패 → 새 대화 1회)
#   M2 지침 파일 연결 — 실행하는 에이전트가 필요로 하는 파일만 자동 생성: .collar 있음 + kimi + CLAUDE.md만 → AGENTS.md 포인터 / claude + AGENTS.md만 → CLAUDE.md,
#      반대 방향(claude + CLAUDE.md만, kimi + AGENTS.md만)은 쓰기도 안내도 없음 — claude launch 가 AGENTS.md 를 만들던 회귀 재현,
#      안내 한 줄은 그 에이전트가 읽지 못하는데 만들지 않은 경우(.collar 없음: claude+AGENTS.md만, kimi+CLAUDE.md만)와 둘 다 있고 참조 없음일 때만, 둘 다 없음은 아무것도 없음
#   M3 순서 — collar-agents-sync 가 호출될 때 AGENTS.md 포인터가 이미 있고, 최종 AGENTS.md = collar 블록 + 빈 줄 + 포인터

source "${0:A:h}/../lib/harness.zsh"

t_live_snapshot
t_setup

export CODEX_HOME="$T_ROOT/codex-home"
# 이 머신의 실제 collar-agents-sync 대신 가짜 (호출 시점의 AGENTS.md 첫 줄을 기록하고 최상단에 collar 블록을 넣는다)
cat > "$T_ROOT/bin/collar-agents-sync" <<'SH'
#!/bin/sh
first="none"
[ -f "$1/AGENTS.md" ] && first="$(head -1 "$1/AGENTS.md")"
printf '%s|first=%s\n' "$1" "$first" >> "$FAKE_SYNC_LOG"
[ -d "$1/.collar" ] || exit 0
tmp="$1/.AGENTS.md.fake-sync.$$"
{ printf '<!-- collar:begin v2 -->\nFAKE BLOCK\n<!-- collar:end -->\n'; if [ -f "$1/AGENTS.md" ]; then printf '\n'; cat "$1/AGENTS.md"; fi; } > "$tmp" && mv "$tmp" "$1/AGENTS.md"
exit 0
SH
chmod +x "$T_ROOT/bin/collar-agents-sync"
export FAKE_SYNC_LOG="$T_ROOT/sync.log"
: > "$FAKE_SYNC_LOG"
export PATH="$T_ROOT/bin:$PATH"
print -r -- 'PS1="cmuxt> "' > "$ZDOTDIR/.zshrc"
AF="$CMUX_AGENT_ARGS_FILE"
T=$'\t'

_launch_pty() {
  local _lp_dir="$1" _lp_agent="$2" _lp_want="${3:-1}" _lp_n0
  _lp_n0="$(t_agent_launches "$_lp_agent" "$_lp_dir")"
  t_cmux_bg 30 launch "$_lp_dir" --agent "$_lp_agent"
  t_wait_for '(( $(t_agent_launches "$_lp_agent" "$_lp_dir") >= _lp_n0 + _lp_want ))' 15
  t_wait_for '(( $(t_agent_procs) >= 1 ))' 5
  t_hup
  t_wait_for '(( $(t_agent_procs) == 0 ))' 5
}
_last_args() { t_agent_args "$1" "$2" | tail -1; }
_screen_log() { sed $'s/\e\\[[0-9;]*m//g; s/\r$//' "$T_LAST_LOG"; }

P="$T_ROOT/proj"
mkdir -p "$P"/{k1,k2,k3,k4,co,ao,nc,un,cc,ka,ca,nn}

# ── M1 ────────────────────────────────────────────────
t_scenario M1 "kimi launch — 인자 · 배너 · PERM · 인자 파일 · fastfail"
_launch_pty "$P/k1" kimi
t_assert_eq "기본(safe) → --yolo --continue (kimi가 이력을 판정 — 프로브가 비어도 항상 이어하기)" "--yolo --continue" "$(_last_args kimi "$P/k1")"
t_assert_eq "1회 실행" 1 "$(t_agent_launches kimi "$P/k1")"
t_assert_contains "배너" "$(_screen_log)" "▶ Kimi Code: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"
t_assert_eq "이력 조회(session list)는 실행으로 세지 않고 --cwd 물리 경로·--json·--limit 1 로 호출" "session list --cwd $P/k1 --json --limit 1" \
  "$(grep '^fake-kimi-list' "$FAKE_AGENT_LOG" | tail -1 | cut -f3)"
CMUX_KIMI_PERM=auto _launch_pty "$P/k1" kimi
t_assert_eq "CMUX_KIMI_PERM=auto → --auto --continue" "--auto --continue" "$(_last_args kimi "$P/k1")"
print -r -- "$P/k2${T}kimi${T}--model m1 --add-dir {dir}/extra" > "$AF"
_launch_pty "$P/k2" kimi
t_assert_eq "인자 파일 줄 → 권한 인자 대신 (+ --continue)" "--model m1 --add-dir $P/k2/extra --continue" "$(_last_args kimi "$P/k2")"
t_assert_contains "사용자 인자 배너 줄" "$(_screen_log)" "  사용자 인자($AF): --model m1 --add-dir $P/k2/extra"
rm -f -- "$AF"
FAKE_AGENT_FAIL_ON=--continue _launch_pty "$P/k3" kimi 2
t_assert_eq "fastfail: --continue 즉시 실패 → 새 대화(권한 인자만) 1회" "--yolo --continue"$'\n'"--yolo" "$(t_agent_args kimi "$P/k3")"
# 마지막 활동이 핸드오프 마커 뒤(유예 초과)로 잡히면 마커를 소비하지 않는다 — 가짜 목록 사용
print -r -- "[{\"id\":\"s\",\"workDir\":\"$P/k4\",\"updatedAt\":$(( (EPOCHSECONDS + 2000) * 1000 ))}]" > "$T_ROOT/kimilist.json"
mkdir -p "$P/k4/.collar"; printf 'agent=kimi\nhandoff=HANDOFF-2026-11-04.md\nts=%s\n' $EPOCHSECONDS > "$P/k4/.collar/restart-fresh"
FAKE_KIMI_LIST="$T_ROOT/kimilist.json" _launch_pty "$P/k4" kimi
t_assert_eq "마지막 활동이 ts+유예 뒤 → 마커 무시·이어하기" "--yolo --continue" "$(_last_args kimi "$P/k4")"
t_assert_true "마커 그대로" '[[ -f "$P/k4/.collar/restart-fresh" ]]'

# ── M2 ────────────────────────────────────────────────
t_scenario M2 "지침 파일 연결 — launch 자동 / 안내만"
: > "$FAKE_SYNC_LOG"
mkdir -p "$P/co/.collar"; print -r -- "# 프로젝트 규칙" > "$P/co/CLAUDE.md"
_launch_pty "$P/co" kimi
scr="$(_screen_log)"
t_assert_contains ".collar + CLAUDE.md만 → 안내 한 줄" "$scr" "▶ 지침 연결: CLAUDE.md 만 있어 AGENTS.md(CLAUDE.md 포인터)를 만들었습니다 — 커밋·ignore는 직접 정하세요"
t_assert_contains "AGENTS.md 포인터 생성" "$(cat "$P/co/AGENTS.md")" "이 프로젝트의 지침은 ./CLAUDE.md 에 있습니다."
t_assert_eq "연결 안내가 에이전트 배너보다 먼저" "1 2" "$(print -r -- "$scr" | grep -n '지침 연결\|▶ Kimi Code' | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "CLAUDE.md 는 그대로" "# 프로젝트 규칙" "$(cat "$P/co/CLAUDE.md")"
t_assert_eq "kimi 는 그대로 실행됨" "--yolo --continue" "$(_last_args kimi "$P/co")"
mkdir -p "$P/ao/.collar"; print -r -- "# 프로젝트 규칙" > "$P/ao/AGENTS.md"
_launch_pty "$P/ao" claude
t_assert_eq ".collar + AGENTS.md만 + claude → CLAUDE.md = @AGENTS.md" $'<!-- cmux:bridge -->\n<!-- 지침 원본은 AGENTS.md 입니다(codex·opencode·kimi 등과 공유). 아래 줄이 Claude Code에 그 내용을 불러옵니다. -->\n@AGENTS.md' "$(cat "$P/ao/CLAUDE.md")"
t_assert_contains "claude 에서도 안내 한 줄" "$(_screen_log)" "▶ 지침 연결: AGENTS.md 만 있어 CLAUDE.md(@AGENTS.md)를 만들었습니다"
t_assert_eq "AGENTS.md 는 그대로 (claude 는 sync 를 부르지 않음)" "# 프로젝트 규칙" "$(cat "$P/ao/AGENTS.md")"
# 재현(MEDIUM): .collar + CLAUDE.md만 → claude 로 열어도 AGENTS.md 는 생기지 않는다 (cmux -k 로 탭 수십 개를 복원할 때 프로젝트마다 untracked AGENTS.md 가 생기던 문제)
mkdir -p "$P/cc/.collar"; print -r -- "# 규칙" > "$P/cc/CLAUDE.md"
n_sync="$(wc -l < "$FAKE_SYNC_LOG")"
_launch_pty "$P/cc" claude
t_assert_true "claude + CLAUDE.md만 + .collar → AGENTS.md 생성 없음" '[[ ! -e "$P/cc/AGENTS.md" ]]'
t_assert_eq "디렉토리에 CLAUDE.md(+.collar)뿐" "CLAUDE.md" "$(ls -A "$P/cc" | grep -v '^.collar$' | tr '\n' ' ' | sed 's/ $//')"
t_assert_not_contains "안내도 없음 (claude 는 CLAUDE.md 를 이미 읽는다)" "$(_screen_log)" "지침 파일이 한쪽뿐"
t_assert_not_contains "'지침 연결' 줄도 없음" "$(_screen_log)" "지침 연결"
t_assert_eq "claude 는 그대로 실행" "--dangerously-skip-permissions" "$(_last_args claude "$P/cc")"
t_assert_eq "claude 는 sync 를 부르지 않음" "$n_sync" "$(wc -l < "$FAKE_SYNC_LOG")"
# 반대 방향: kimi + AGENTS.md만 + .collar → CLAUDE.md 는 만들지 않는다 (kimi 는 AGENTS.md 를 읽는다). sync 는 호출돼 collar 블록을 AGENTS.md 에 넣는다(기존 동작)
mkdir -p "$P/ka/.collar"; print -r -- "# 규칙" > "$P/ka/AGENTS.md"
_launch_pty "$P/ka" kimi
t_assert_true "kimi + AGENTS.md만 + .collar → CLAUDE.md 생성 없음" '[[ ! -e "$P/ka/CLAUDE.md" ]]'
t_assert_not_contains "안내도 없음 (kimi 는 AGENTS.md 를 이미 읽는다)" "$(_screen_log)" "지침 파일이 한쪽뿐"
t_assert_eq "kimi 는 그대로 실행" "--yolo --continue" "$(_last_args kimi "$P/ka")"
print -r -- "# 규칙" > "$P/nc/CLAUDE.md"
_launch_pty "$P/nc" kimi
t_assert_true ".collar 없음 → AGENTS.md 생성 없음" '[[ ! -e "$P/nc/AGENTS.md" ]]'
t_assert_contains ".collar 없음 → 안내 한 줄" "$(_screen_log)" "▶ 지침 파일이 한쪽뿐입니다(CLAUDE.md 만 있음) — 'cmux bridge --apply $P/nc' 로 연결할 수 있습니다"
t_assert_eq ".collar 없음 → 에이전트는 그대로 실행" "--yolo --continue" "$(_last_args kimi "$P/nc")"
# .collar 없음 + claude + AGENTS.md만 → claude 는 AGENTS.md 를 읽지 못한다 → 쓰기 없이 안내 한 줄
print -r -- "# 규칙" > "$P/ca/AGENTS.md"
_launch_pty "$P/ca" claude
t_assert_true "claude + AGENTS.md만 + .collar 없음 → CLAUDE.md 생성 없음" '[[ ! -e "$P/ca/CLAUDE.md" ]]'
t_assert_contains "안내 한 줄" "$(_screen_log)" "▶ 지침 파일이 한쪽뿐입니다(AGENTS.md 만 있음) — 'cmux bridge --apply $P/ca' 로 연결할 수 있습니다"
# 둘 다 없음 → 아무것도 없음
_launch_pty "$P/nn" claude
t_assert_not_contains "둘 다 없음 → 지침 관련 줄 없음" "$(_screen_log)" "지침"
t_assert_eq "둘 다 없음 → 파일 생성 없음" "" "$(ls -A "$P/nn")"
mkdir -p "$P/un/.collar"; print -r -- "# a" > "$P/un/AGENTS.md"; print -r -- "# c" > "$P/un/CLAUDE.md"
s0="$(md5 -q "$P/un/AGENTS.md")$(md5 -q "$P/un/CLAUDE.md")"
_launch_pty "$P/un" claude
t_assert_eq "둘 다 있고 참조 없음 → 자동 수정 없음 (.collar 가 있어도)" "$s0" "$(md5 -q "$P/un/AGENTS.md")$(md5 -q "$P/un/CLAUDE.md")"
t_assert_contains "안내 한 줄" "$(_screen_log)" "▶ AGENTS.md 와 CLAUDE.md 가 서로 참조하지 않습니다 — 'cmux bridge --apply $P/un' 로 연결할 수 있습니다"

# ── M3 ────────────────────────────────────────────────
t_scenario M3 "순서 — 포인터 생성 → collar-agents-sync(collar 블록 삽입)"
t_assert_eq "co: sync 호출 시점에 AGENTS.md 첫 줄 = cmux 마커 (포인터가 먼저)" "$P/co|first=<!-- cmux:bridge -->" "$(grep -F "$P/co|" "$FAKE_SYNC_LOG" | head -1)"
t_assert_eq "co: 최종 AGENTS.md = collar 블록 + 빈 줄 + 포인터" $'<!-- collar:begin v2 -->\nFAKE BLOCK\n<!-- collar:end -->\n\n<!-- cmux:bridge -->' "$(head -5 "$P/co/AGENTS.md")"
t_assert_eq "claude 는 sync 호출 없음 (ao)" 0 "$(grep -cF "$P/ao|" "$FAKE_SYNC_LOG")"

t_finish
exit $?
