#!/usr/bin/env zsh
# t02_tabs — 탭 기록 함수 현행 동작 특성화 (Phase 2 포맷 변경의 안전망)
#   T1 _tabs_load   구포맷(경로만) 읽기 — 빈 줄·없는 경로 건너뜀, 순서·공백 포함 경로 유지
#   T2 _tabs_save   덮어쓰기 — 순서 유지, 빈 인자 건너뜀, 상위 디렉토리 생성
#   T3 _tabs_append 없는 것만 뒤에 추가 — 줄 전체 일치로 중복 제거
#   T4 _tabs_sync_live 탭 이름(basename) → 경로 역추적 (zellij는 셸 함수 스텁)
#   T5 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

mkdir -p "$U_TMP"/{home,bin}
export HOME="$U_TMP/home"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs"
# PATH 맨 앞의 가짜 zellij — 스텁 함수가 빠졌을 때 실제 zellij로 새는 것을 기록
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
chmod +x "$U_TMP/bin/zellij"
export PATH="$U_TMP/bin:$PATH"

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }
DEV_ROOT="$U_TMP/dev"
EXTRAS_FILE="$U_TMP/extras"

A="$DEV_ROOT/alpha" B="$DEV_ROOT/beta" G="$DEV_ROOT/gamma"
SP="$U_TMP/with space/proj x"
X="$U_TMP/x/proj" Y="$U_TMP/y/proj" OA="$U_TMP/other/alpha" EXT="$U_TMP/ext/extproj"
mkdir -p "$A" "$B" "$G" "$SP" "$X" "$Y" "$OA" "$EXT"
print -r -- "$EXT" > "$EXTRAS_FILE"

_file() { cat "$TABS_FILE" 2>/dev/null; }
_lines() { print -r -l -- "$@"; }

# ── T1 ────────────────────────────────────────────────
t_scenario T1 "_tabs_load — 구포맷 읽기"
t_assert_eq "기록 파일 없음 → 빈 출력·rc 0" "rc=0" "$(_tabs_load; print -n "rc=$?")"
mkdir -p "${TABS_FILE:h}"
_lines "$B" "" "$U_TMP/ghost" "$SP" "$A" "" > "$TABS_FILE"
t_assert_eq "빈 줄·없는 경로 건너뜀, 순서·공백 경로 유지" "$(_lines "$B" "$SP" "$A")" "$(_tabs_load)"
t_assert_eq "읽기만 — 파일은 그대로" "$(_lines "$B" "" "$U_TMP/ghost" "$SP" "$A" "")" "$(_file)"

# ── T2 ────────────────────────────────────────────────
t_scenario T2 "_tabs_save — 덮어쓰기"
TABS_FILE="$U_TMP/new/dir/session-tabs"
_tabs_save "$A" "" "$SP" "$B"
t_assert_eq "상위 디렉토리 생성·순서 유지·빈 인자 건너뜀" "$(_lines "$A" "$SP" "$B")" "$(_file)"
_tabs_save "$G"
t_assert_eq "기존 내용 덮어쓰기" "$G" "$(_file)"
_tabs_save "$U_TMP/ghost"
t_assert_eq "없는 경로도 그대로 기록 (거르는 것은 _tabs_load)" "$U_TMP/ghost" "$(_file)"
_tabs_save
t_assert_true "인자 없음 → 빈 파일" '[[ -f "$TABS_FILE" && ! -s "$TABS_FILE" ]]'

# ── T3 ────────────────────────────────────────────────
t_scenario T3 "_tabs_append — 중복 제거 추가"
TABS_FILE="$U_TMP/append/session-tabs"
_tabs_append "$A"
t_assert_eq "파일 없으면 만들어 추가" "$A" "$(_file)"
_tabs_append "$B" "$A" "" "$B"
t_assert_eq "없는 것만 뒤에, 같은 호출 안 중복도 1번" "$(_lines "$A" "$B")" "$(_file)"
_tabs_append "$DEV_ROOT"
t_assert_eq "줄 전체 일치 — 접두어 경로는 별개" "$(_lines "$A" "$B" "$DEV_ROOT")" "$(_file)"

# ── T4 ────────────────────────────────────────────────
t_scenario T4 "_tabs_sync_live — 탭 이름 → 경로 역추적"
TABS_FILE="$U_TMP/sync/session-tabs"
mkdir -p "${TABS_FILE:h}"
U_ALIVE=1 U_NAMES=""
# zellij 스텁: list-sessions → 테스트 세션 한 줄(U_ALIVE일 때) / query-tab-names → U_NAMES
zellij() {
  print -r -- "$*" >> "$U_TMP/stub-calls"
  if [[ "$1" == "list-sessions" ]]; then
    (( U_ALIVE )) && print -r -- "$SESSION_NAME [Created 1s ago] "
  elif [[ "$1 $2 $3 $4" == "-s $SESSION_NAME action query-tab-names" ]]; then
    [[ -n "$U_NAMES" ]] && print -r -- "$U_NAMES"
  fi
  return 0
}
# _sync <탭 이름들(줄바꿈)> <기록 경로...> → 동기화 후 기록 내용
_sync() {
  U_NAMES="$1"; shift
  _lines "$@" > "$TABS_FILE"
  _tabs_sync_live 2> "$U_TMP/sync-err"
  _file
}

t_assert_eq "실제 탭 순서로 재정렬" "$(_lines "$B" "$A")" "$(_sync $'beta\nalpha' "$A" "$B")"
t_assert_eq "닫힌 탭은 기록에서 빠짐" "$A" "$(_sync 'alpha' "$A" "$B")"
t_assert_eq "기록에 없던 탭은 프로젝트 목록(DEV_ROOT)에서 찾음" "$(_lines "$A" "$G")" "$(_sync $'alpha\ngamma' "$A")"
t_assert_eq "등록 경로(EXTRAS_FILE)에서도 찾음" "$(_lines "$A" "$EXT")" "$(_sync $'alpha\nextproj' "$A")"
t_assert_eq "같은 이름 → 기록(우선) 순서대로 다른 경로" "$(_lines "$X" "$Y")" "$(_sync $'proj\nproj' "$X" "$Y")"
t_assert_eq "같은 이름이면 기록이 DEV_ROOT보다 우선" "$OA" "$(_sync 'alpha' "$OA")"
t_assert_eq "공백 포함 경로" "$(_lines "$SP" "$A")" "$(_sync $'proj x\nalpha' "$A" "$SP")"
t_assert_eq "이름 바꾼 탭 → 기존 기록과 병합 (매핑된 것 먼저)" "$(_lines "$B" "$A")" "$(_sync $'beta\nrenamed' "$A" "$B")"
t_assert_contains "병합 경고 (stderr)" "$(cat "$U_TMP/sync-err")" "경로를 알 수 없는 탭 1개"
t_assert_eq "기록의 없는 경로는 후보에서 빠짐" "$A" "$(_sync 'alpha' "$A" "$U_TMP/ghost")"
t_assert_eq "탭 이름 없음 → 기록 그대로" "$(_lines "$A" "$B")" "$(_sync '' "$A" "$B")"
t_assert_eq "모든 탭이 매핑 불가·기록 없음 → 기록 그대로(빈 파일 유지)" "" "$(_sync 'renamed')"
: > "$U_TMP/stub-calls"
U_ALIVE=0
t_assert_eq "세션 없음 → 기록 그대로" "$(_lines "$A" "$B")" "$(_sync $'beta\nalpha' "$A" "$B")"
t_assert_eq "세션 없음 → query-tab-names 호출 안 함" "list-sessions --no-formatting" "$(cat "$U_TMP/stub-calls")"
unfunction zellij

# ── T5 ────────────────────────────────────────────────
t_scenario T5 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
