#!/usr/bin/env zsh
# t08_kimi_adapter — Kimi Code(kimi) 어댑터 단위 테스트 (CMUX_SOURCE_ONLY=1 source, zellij·실제 kimi 없음 — 가짜 kimi·가짜 홈만)
#   K1 등록·훅 기본값 (label·default_perm·fastfail·_agent_known)
#   K2 bin 탐색 우선순위 (CMUX_KIMI_BIN → ~/.kimi-code/bin/kimi → ~/.local/bin/kimi → PATH)
#   K3 권한 프로파일 (safe=--yolo / auto=--auto, CMUX_KIMI_PERM·잘못된 값) + compose (--continue는 권한 인자 뒤)
#   K4 has_history·last_activity — 가짜 'session list --json' (실측 모양 · ms/초/ISO · 필드명 변형 · 빈 목록·깨진 JSON·rc≠0·시간 초과·python3 없음·심볼릭 링크 → 물리 경로 --cwd)
#   K5 _launch_agent kimi — 인자 · 배너 · 마커 · 인자 파일 · fastfail
#   K6 탭 이름·spec 파싱·복원 기록·레이아웃이 새 에이전트 이름을 그대로 받는다
#   K7 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'chmod -R u+rwx -- "$U_TMP" 2>/dev/null; rm -rf -- "$U_TMP"' EXIT

mkdir -p "$U_TMP"/{home,bin,zdotdir,emptybin,cfg}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs" CMUX_CONFIG_FILE="$U_TMP/cfg/config"
export CMUX_AGENT_ARGS_FILE="$U_TMP/cfg/agent-args"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
unset CMUX_KIMI_PERM CMUX_HANDOFF_GRACE KIMI_CODE_HOME
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
# 가짜 collar-agents-sync: 호출만 기록 (이 머신의 실제 collar-agents-sync가 임시 폴더에 AGENTS.md를 만들지 않게)
print -r -- $'#!/bin/sh\nprintf "%s|%s\\n" "$PWD" "$*" >> "${FAKE_SYNC_LOG:-/dev/null}"\nexit 0' > "$U_TMP/bin/collar-agents-sync"
chmod +x "$U_TMP/bin/zellij" "$U_TMP/bin/collar-agents-sync"
export FAKE_SYNC_LOG="$U_TMP/sync.log"
for a in claude codex opencode kimi; do ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-$a"; done
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude" CMUX_CODEX_BIN="$U_TMP/bin/fake-codex" CMUX_OPENCODE_BIN="$U_TMP/bin/fake-opencode"
export CMUX_KIMI_BIN="$U_TMP/bin/fake-kimi"
export PATH="$U_TMP/bin:$PATH"
export FAKE_AGENT_LOG="$U_TMP/fake.log" FAKE_AGENT_SLEEP=0
: > "$FAKE_AGENT_LOG"
export CMUX_SOURCE_ONLY=1

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }

# ── 공용 도우미 ───────────────────────────────────────
NOW=$EPOCHSECONDS
PERM_SAFE="--yolo"
PERM_AUTO="--auto"
_r() { _agent_call "$1" "$2"; print -r -- "$REPLY"; }
# 가짜 kimi 'session list' 출력 파일 — 줄 단위로 JSON 조각을 넘기면 배열로 감싼다
export FAKE_KIMI_LIST="$U_TMP/kimilist.json"
_klist() { print -r -- "[${(j:,:)@}]" > "$FAKE_KIMI_LIST"; }
# 실측한 항목 모양: {id, workDir, sessionDir, createdAt(ms), updatedAt(ms), archived, metadata}
_kent() { print -r -- "{\"id\":\"$1\",\"workDir\":\"$2\",\"sessionDir\":\"/x/$1\",\"createdAt\":$3,\"updatedAt\":$3,\"archived\":false,\"metadata\":{}}"; }
# _khh <디렉토리> → "rc|REPLY|count|updated"
_khh() {
  local rc
  _ag_kimi_has_history "$1"; rc=$?
  print -r -- "$rc|$REPLY|$_ag_kimi_count|$_ag_kimi_updated"
}
_kla() { REPLY=x; _ag_kimi_last_activity "$1"; print -r -- "$REPLY"; }
U_LIST_SLEEP="30.$$"
_sleep_procs() { ps -axo command= | grep -cxF "sleep $1"; }
_fmt() { strftime '%m-%d %H:%M' "$1"; }

# ── K1 ────────────────────────────────────────────────
t_scenario K1 "등록·훅 기본값"
t_assert_eq "등록 에이전트 (kimi는 opencode 뒤)" "claude codex opencode kimi" "${CMUX_AGENTS[*]}"
t_assert_eq "_agent_known kimi / kimix" "0 1" "$(_agent_known kimi; print -n "$? "; _agent_known kimix; print -n $?)"
t_assert_eq "label" "Kimi Code" "$(_r kimi label)"
t_assert_eq "default_perm = safe (가드 훅 없는 CLI — codex와 같다)" "safe" "$(_r kimi default_perm)"
t_assert_eq "fastfail 기본 5초" "5" "$(_r kimi fastfail)"
t_assert_eq "resume_args = --continue" "--continue" "$(_agent_call kimi resume_args; print -r -- "${reply[*]}")"
t_assert_eq "fresh_args = 없음" "0" "$(_agent_call kimi fresh_args; print -r -- "${#reply}")"

# ── K2 ────────────────────────────────────────────────
t_scenario K2 "bin 탐색 우선순위"
_mkexe() { mkdir -p "${1:h}"; print -r -- '#!/bin/sh' > "$1"; chmod +x "$1"; }
CMUX_KIMI_BIN=/custom/kimi _agent_call kimi bin
t_assert_eq "CMUX_KIMI_BIN 최우선" "/custom/kimi" "$REPLY"
export CMUX_KIMI_BIN=
PATH="$U_TMP/emptybin" _agent_call kimi bin; rc=$?
t_assert_true "공식 설치 위치·링크·PATH 어디에도 없으면 비0 (가짜 홈 + 빈 PATH — 이 머신의 실제 kimi가 새지 않게)" '(( rc == 1 ))'
_mkexe "$U_TMP/pathbin/kimi"
PATH="$U_TMP/pathbin:$PATH" _agent_call kimi bin
t_assert_eq "후보 없으면 PATH" "$U_TMP/pathbin/kimi" "$REPLY"
_mkexe "$HOME/.local/bin/kimi"
PATH="$U_TMP/pathbin:$PATH" _agent_call kimi bin
t_assert_eq "~/.local/bin/kimi 가 PATH보다 앞" "$HOME/.local/bin/kimi" "$REPLY"
_mkexe "$HOME/.kimi-code/bin/kimi"
PATH="$U_TMP/pathbin:$PATH" _agent_call kimi bin
t_assert_eq "~/.kimi-code/bin/kimi 가 ~/.local/bin 보다 앞" "$HOME/.kimi-code/bin/kimi" "$REPLY"
chmod -x "$HOME/.kimi-code/bin/kimi"
_agent_call kimi bin
t_assert_eq "실행 불가 파일은 건너뜀" "$HOME/.local/bin/kimi" "$REPLY"
export CMUX_KIMI_BIN="$U_TMP/bin/fake-kimi"

# ── K3 ────────────────────────────────────────────────
t_scenario K3 "권한 프로파일 · compose"
_prof() { _agent_perm_profile "$1" >/dev/null; print -r -- "$REPLY"; }
t_assert_eq "kimi 기본 safe / CMUX_KIMI_PERM=auto / safe" "safe auto safe" \
  "$(_prof kimi) $(CMUX_KIMI_PERM=auto _prof kimi) $(CMUX_KIMI_PERM=safe _prof kimi)"
out="$(CMUX_KIMI_PERM=yolo _agent_perm_profile kimi; print -r -- "REPLY=$REPLY")"
t_assert_contains "잘못된 값 → 경고 1줄" "$out" "CMUX_KIMI_PERM='yolo' — auto|safe 가 아니라 기본값(safe)을 씁니다"
t_assert_contains "잘못된 값 → 기본값" "$out" "REPLY=safe"
_pa() { _agent_call "$1" perm_args "$2"; print -r -- "${#reply}:${reply[*]}"; }
t_assert_eq "perm_args safe → --yolo" "1:$PERM_SAFE" "$(_pa kimi safe)"
t_assert_eq "perm_args auto → --auto" "1:$PERM_AUTO" "$(_pa kimi auto)"
_cmp() { _agent_call "$1" perm_args "$3"; _agent_call "$1" compose "$2" "${reply[@]}"; print -r -- "${#reply}:${reply[*]}"; }
t_assert_eq "resume × safe → 권한 인자 뒤 --continue" "2:--yolo --continue" "$(_cmp kimi resume safe)"
t_assert_eq "resume × auto" "2:--auto --continue" "$(_cmp kimi resume auto)"
t_assert_eq "fresh × safe → 권한 인자만" "1:--yolo" "$(_cmp kimi fresh safe)"
t_assert_eq "fresh × auto" "1:--auto" "$(_cmp kimi fresh auto)"

# ── K4 ────────────────────────────────────────────────
t_scenario K4 "has_history·last_activity — 가짜 session list"
KD="$U_TMP/kd"
mkdir -p "$KD"/{a,b,c}
ln -s "$KD" "$U_TMP/kdlink"
T0=1793777920
_klist "$(_kent session_a1 "$KD/a" ${T0}649)"
t_assert_eq "실측 모양 항목(ms) → 이력 있음, 배너 = 시각" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
t_assert_eq "조회 인자 = session list --cwd <물리 경로> --json --limit 1" "session list --cwd $KD/a --json --limit 1" \
  "$(grep '^fake-kimi-list' "$FAKE_AGENT_LOG" | tail -1 | cut -f3)"
t_assert_eq "조회의 cwd = 그 폴더" "$KD/a" "$(grep '^fake-kimi-list' "$FAKE_AGENT_LOG" | tail -1 | cut -f2)"
t_assert_eq "목록 조회는 에이전트 실행으로 기록되지 않음" 0 "$(t_agent_launches kimi "$KD/a")"
t_assert_eq "last_activity = updatedAt/1000" "$T0" "$(_kla "$KD/a")"
_khh "$U_TMP/kdlink/a" >/dev/null
t_assert_eq "심볼릭 링크 경로로 물어도 --cwd 는 물리 경로 (kimi는 --cwd를 문자열 그대로 비교한다 — 실측)" "session list --cwd $KD/a --json --limit 1" \
  "$(grep '^fake-kimi-list' "$FAKE_AGENT_LOG" | tail -1 | cut -f3)"
# 시각 표현 변형: 초 epoch, 숫자 문자열, ISO 문자열(Z·오프셋·소수초), 필드명 변형
_k1() { print -r -- "[$1]" > "$FAKE_KIMI_LIST"; }
_k1 "{\"id\":\"s\",\"updatedAt\":$T0}"
t_assert_eq "updatedAt 초 epoch" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updatedAt\":\"${T0}649\"}"
t_assert_eq "updatedAt 숫자 문자열(ms)" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
ISO="$(TZ=UTC strftime '%Y-%m-%dT%H:%M:%S' $T0)"
_k1 "{\"id\":\"s\",\"updatedAt\":\"${ISO}.649Z\"}"
t_assert_eq "ISO 문자열 (소수초 + Z)" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updated_at\":\"${ISO}+00:00\"}"
t_assert_eq "updated_at + ISO (+00:00)" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updated\":${T0}000}"
t_assert_eq "updated 필드 (ms)" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"createdAt\":${T0}000}"
t_assert_eq "갱신 시각 필드가 없으면 createdAt 으로" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updatedAt\":$(( T0 + 100 ))000,\"createdAt\":${T0}000}"
t_assert_eq "updatedAt 이 createdAt 보다 우선" "0|$(_fmt $(( T0 + 100 )))|1|$(( T0 + 100 ))" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updatedAt\":$(( T0 + 5 ))000},{\"id\":\"t\",\"updatedAt\":$(( T0 + 50 ))000},{\"id\":\"u\",\"updatedAt\":${T0}000}"
t_assert_eq "여러 항목이면 시각 최대" "0|$(_fmt $(( T0 + 50 )))|3|$(( T0 + 50 ))" "$(_khh "$KD/a")"
_k1 '{"id":"s","note":"no time fields"}'
t_assert_eq "시각을 못 읽으면 시각 0, 목록은 비어 있지 않으니 '이력 있음'" "0|이력 있음|1|0" "$(_khh "$KD/a")"
t_assert_eq "시각 0 → last_activity 0" 0 "$(_kla "$KD/a")"
_k1 '{"id":"s","updatedAt":"어제"}'
t_assert_eq "해석 못 하는 시각 문자열 → 시각 0" "0|이력 있음|1|0" "$(_khh "$KD/a")"
_k1 '{"id":"s","updatedAt":true}'
t_assert_eq "불리언 시각 → 시각 0" "0|이력 있음|1|0" "$(_khh "$KD/a")"
print -r -- "{\"sessions\":[{\"id\":\"s\",\"updatedAt\":${T0}000}]}" > "$FAKE_KIMI_LIST"
t_assert_eq "목록을 값으로 가진 객체({sessions:[…]})도 받는다" "0|$(_fmt $T0)|1|$T0" "$(_khh "$KD/a")"
_k1 "{\"id\":\"s\",\"updatedAt\":${T0}000,\"archived\":true}"
t_assert_eq "archived:true 만 있으면 이력 없음으로" "0|이력이 없으면 새 대화|0|0" "$(_khh "$KD/a")"
_klist
t_assert_eq "빈 목록 → 이력 없음 (native라 rc는 0, 배너 문구만 다름)" "0|이력이 없으면 새 대화|0|0" "$(_khh "$KD/a")"
t_assert_eq "빈 목록 → last_activity 0" 0 "$(_kla "$KD/a")"
print -r -- '[{"id":"s","updatedAt":' > "$FAKE_KIMI_LIST"
t_assert_eq "깨진 JSON → 없음" "0|이력이 없으면 새 대화|0|0" "$(_khh "$KD/a")"
print -r -- '"just a string"' > "$FAKE_KIMI_LIST"
t_assert_eq "배열도 객체도 아닌 JSON → 없음" "0|이력이 없으면 새 대화|0|0" "$(_khh "$KD/a")"
print -r -- 'No sessions found.' > "$FAKE_KIMI_LIST"
t_assert_eq "텍스트 출력(No sessions found.) → 없음" "0|이력이 없으면 새 대화|0|0" "$(_khh "$KD/a")"
_klist "$(_kent session_a1 "$KD/a" ${T0}649)"
t_assert_eq "목록이 있어도 조회 rc≠0 이면 없음" "0|이력이 없으면 새 대화|0|0" "$(FAKE_KIMI_LIST_RC=1 _khh "$KD/a")"
t_assert_eq "판정 중 stderr 출력 없음" "" "$(_ag_kimi_has_history "$KD/a" 2>&1 >/dev/null; print -r -- '[' > "$FAKE_KIMI_LIST"; _ag_kimi_has_history "$KD/a" 2>&1 >/dev/null)"
( unset FAKE_KIMI_LIST; _khh "$KD/a" ) > "$U_TMP/khh.out"
t_assert_eq "조회 출력 없음 → 없음" "0|이력이 없으면 새 대화|0|0" "$(cat "$U_TMP/khh.out")"
# 앞선 성공 결과가 남아 있어도 다음 판정이 실패하면 비운다
_klist "$(_kent session_a1 "$KD/a" ${T0}649)"
_ag_kimi_has_history "$KD/a"; FAKE_KIMI_LIST_RC=1 _ag_kimi_has_history "$KD/a"
t_assert_eq "실패한 판정은 이전 결과를 비움" "0|0" "$_ag_kimi_count|$_ag_kimi_updated"
# python3 없음 → 조회 자체를 하지 않는다
n0="$(grep -c '^fake-kimi-list' "$FAKE_AGENT_LOG")"
t_assert_eq "python3 없음 → 없음" "0|이력이 없으면 새 대화|0|0" "$(PATH="$U_TMP/emptybin" _khh "$KD/a")"
t_assert_eq "python3 없음 → 목록 조회 안 함" "$n0" "$(grep -c '^fake-kimi-list' "$FAKE_AGENT_LOG")"
t_assert_eq "kimi 실행 파일 없음 → 없음" "0|이력이 없으면 새 대화|0|0" "$(CMUX_KIMI_BIN="$U_TMP/emptybin/nope" _khh "$KD/a")"
# 프로젝트 폴더에 json.py 가 있어도 영향받지 않는다 (python3 -I)
print -r -- 'raise SystemExit("hijacked")' > "$KD/b/json.py"
_klist "$(_kent session_b "$KD/b" ${T0}000)"
t_assert_eq "폴더 안 json.py 무시 (python3 -I)" "0|$(_fmt $T0)|1|$T0" "$(cd "$KD/b" && _khh "$KD/b")"
# 시간 초과: 조회가 끝나지 않으면 8초에 끊고 없음 (조회 프로세스도 종료)
t0=$EPOCHREALTIME
res="$(FAKE_KIMI_LIST_SLEEP=$U_LIST_SLEEP _khh "$KD/a")"
el=$(( EPOCHREALTIME - t0 ))
t_assert_eq "시간 초과 → 없음" "0|이력이 없으면 새 대화|0|0" "$res"
t_assert_true "시간 초과 → 8초 근처에서 끊음 (실측 ${el%.*}초)" '(( el >= 7.5 && el < 11 ))'
t_assert_true "시간 초과 → 조회 프로세스 종료" '(( $(_sleep_procs $U_LIST_SLEEP) == 0 ))' 3

# ── K5 ────────────────────────────────────────────────
t_scenario K5 "_launch_agent kimi — 인자 · 배너 · 마커 · 인자 파일 · fastfail"
LA="$U_TMP/la"
mkdir -p "$LA"/{plain,hist,mark,mark2,ff,uargs,both}/.collar
: > "$FAKE_AGENT_LOG"
_launch() { (cd "$1" && _launch_agent kimi) 2>/dev/null; }
GRAY=$'\e[90m'
_klist
out="$(_launch "$LA/plain")"
t_assert_eq "기본(safe) → --yolo --continue (이력 프로브가 비어도 항상 이어하기 — kimi가 판정)" "--yolo --continue" "$(t_agent_args kimi "$LA/plain")"
t_assert_eq "배너 (stdout, 회색)" "${GRAY}▶ Kimi Code: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"$'\e[0m' "$out"
_klist "$(_kent session_h "$LA/hist" ${T0}000)"
out="$(_launch "$LA/hist")"
t_assert_contains "이력 있음 → 배너에 시각" "$out" "▶ Kimi Code: 이전 대화 이어서 시작 [$(_fmt $T0)]"
CMUX_KIMI_PERM=auto _launch "$LA/plain" >/dev/null
t_assert_eq "CMUX_KIMI_PERM=auto → --auto --continue" "--auto --continue" "$(t_agent_args kimi "$LA/plain" | tail -1)"
# 핸드오프 마커: kimi용이고 마지막 활동이 ts+유예 이내면 새로 시작(--continue 없이) + 소비
_mk() { print -r -- "agent=${1}"$'\n'"handoff=HANDOFF-2026-11-04.md"$'\n'"ts=${2}"; }
_klist "$(_kent session_m "$LA/mark" $(( (NOW - 100) * 1000 )))"
_mk kimi $NOW > "$LA/mark/.collar/restart-fresh"
out="$(_launch "$LA/mark")"
t_assert_eq "마커 → --continue 없이 권한 인자만" "--yolo" "$(t_agent_args kimi "$LA/mark")"
t_assert_contains "핸드오프 배너" "$out" "▶ Kimi Code: 핸드오프 직후 — 새로 시작"
t_assert_true "마커 소비됨" '[[ ! -e "$LA/mark/.collar/restart-fresh" && -n "$(print -l "$LA"/mark/.collar/.restart-fresh.consumed-*(N))" ]]'
# 유예 초과(핸드오프 뒤에도 대화) → 마커 무시, 이어하기
_klist "$(_kent session_m2 "$LA/mark2" $(( (NOW + 1000) * 1000 )))"
_mk kimi $NOW > "$LA/mark2/.collar/restart-fresh"
_launch "$LA/mark2" >/dev/null
t_assert_eq "마지막 활동이 ts+유예 뒤 → 이어하기" "--yolo --continue" "$(t_agent_args kimi "$LA/mark2")"
t_assert_true "유예 초과 → 마커 그대로" '[[ -f "$LA/mark2/.collar/restart-fresh" ]]'
_mk claude $NOW > "$LA/plain/.collar/restart-fresh"
_launch "$LA/plain" >/dev/null
t_assert_eq "다른 에이전트(claude) 마커는 kimi가 소비하지 않음" "--yolo --continue" "$(t_agent_args kimi "$LA/plain" | tail -1)"
rm -f -- "$LA/plain/.collar/restart-fresh"
# 인자 파일(~/.config/cmux/agent-args): 줄이 권한 인자를 통째로 대신, --continue는 cmux가 붙인다
T=$'\t'
print -r -- "*${T}kimi${T}--model m1 --add-dir {dir}/extra" > "$CMUX_AGENT_ARGS_FILE"
AGENT_ARGS_FILE="$CMUX_AGENT_ARGS_FILE"
out="$(_launch "$LA/uargs")"
t_assert_eq "인자 파일 kimi 줄 → 권한 인자 대신 (+ --continue)" "--model m1 --add-dir $LA/uargs/extra --continue" "$(t_agent_args kimi "$LA/uargs")"
t_assert_contains "배너 아래 사용자 인자 줄" "$out" "  사용자 인자($CMUX_AGENT_ARGS_FILE): --model m1 --add-dir $LA/uargs/extra"
CMUX_KIMI_PERM=auto _launch "$LA/uargs" >/dev/null
t_assert_eq "CMUX_KIMI_PERM=auto + 줄 → 줄이 이김 (--auto 없음)" "--model m1 --add-dir $LA/uargs/extra --continue" "$(t_agent_args kimi "$LA/uargs" | tail -1)"
print -r -- "*${T}codex${T}--only-codex" > "$CMUX_AGENT_ARGS_FILE"
_launch "$LA/both" >/dev/null
t_assert_eq "다른 에이전트(codex) 줄은 kimi에 적용되지 않음" "--yolo --continue" "$(t_agent_args kimi "$LA/both")"
rm -f -- "$CMUX_AGENT_ARGS_FILE"
# fastfail: 이어하기 인자로 즉시 죽으면 새 대화로 1회
: > "$FAKE_AGENT_LOG"
FAKE_AGENT_FAIL_ON=--continue _launch "$LA/ff"
t_assert_eq "--continue 즉시 실패 → 권한 인자만으로 재실행 1회" "--yolo --continue"$'\n'"--yolo" "$(t_agent_args kimi "$LA/ff")"
# .collar 폴더에 AGENTS.md도 CLAUDE.md도 없으면 지침 연결은 아무것도 만들지 않는다
t_assert_eq "둘 다 없으면 파일 생성 없음" "" "$(print -l "$LA/ff"/{AGENTS,CLAUDE}.md(N))"

# ── K6 ────────────────────────────────────────────────
t_scenario K6 "탭 이름 · spec · 복원 기록 · 레이아웃"
_tab_name /x/proj kimi
t_assert_eq "_tab_name → 프로젝트·kimi" "proj·kimi" "$REPLY"
_spec_parse "/x/proj${T}kimi"
t_assert_eq "_spec_parse → (경로 kimi)" "/x/proj kimi" "${reply[*]}"
mkdir -p "$U_TMP/p1" "$U_TMP/p2"
print -rl -- "$U_TMP/p1${T}kimi" "$U_TMP/p2" "$U_TMP/p2${T}kimi" > "$CMUX_TABS_FILE"
t_assert_eq "_tabs_load: kimi 줄은 에이전트 그대로, 다른 폴더/같은 폴더 claude·kimi 공존" \
  "$U_TMP/p1${T}kimi"$'\n'"$U_TMP/p2"$'\n'"$U_TMP/p2${T}kimi" "$(_tabs_load)"
t_assert_contains "_kdl_tab_body kimi → launch --agent kimi" "$(_kdl_tab_body kimi)" 'args "launch" "--agent" "kimi"'
t_assert_contains "_kdl_tab_body kimi → pane 이름 = kimi" "$(_kdl_tab_body kimi)" 'name="kimi"'
t_assert_eq "알 수 없는 에이전트 줄은 경로로 취급(건너뜀)" "" "$(print -r -- "$U_TMP/p1${T}kimix" > "$CMUX_TABS_FILE"; _tabs_load)"
t_assert_eq "launch --agent nope → 오류에 kimi 포함" 1 \
  "$(CMUX_SOURCE_ONLY= zsh "$CMUX_UNDER_TEST" launch "$U_TMP/p1" --agent nope 2>&1 | grep -c '사용 가능: claude codex opencode kimi')"

# ── K7 ────────────────────────────────────────────────
t_scenario K7 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
