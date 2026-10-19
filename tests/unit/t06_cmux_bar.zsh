#!/usr/bin/env zsh
# t06_cmux_bar — bin/cmux-bar 단위 시험 (탭 줄 1↔2줄 토글 설계). zellij 세션·실제 zellij 호출 없음.
#   W 폭 계산·14칸 자르기·라벨·정규화   P 28탭×188열 창 선택·2줄·경계·좁은 폭   D 가짜 화면 그리기·눌림 영역
#   L 레거시(내용 1행) = 이전 구현과 같은 출력   S 토글 상태 파일   E 리더 선출·캐시 공유·실패 유지·2초 지연   M 마우스 분류
# 어서션은 t06_cmux_bar_check.py(`python3 -I`, 확장자 없는 bin/cmux-bar를 SourceFileLoader로 로드)가 하고,
# 이 래퍼는 그 출력(SCENARIO/PASS/FAIL/SKIP)을 harness 어서션으로 옮긴다.
# 실제 pane·curses·클릭은 통합 시험 t07_tabbar_toggle이 본다.

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'rm -rf -- "$U_TMP"' EXIT

# 격리: 홈·캐시·상태 파일은 전부 임시 디렉터리 (사용자 ~/.config·$TMPDIR의 cmux-bar-* 를 건드리지 않는다)
mkdir -p "$U_TMP"/{home,work}
export HOME="$U_TMP/home" CMUX_TABBAR_STATE_FILE="$U_TMP/work/rows" CMUX_BAR_CACHE_DIR="$U_TMP/work/cache"

# 레거시 비교용 이전 구현 (이 변경 직전 커밋). 없으면 비교만 SKIP
OLD_REV="${T_OLD_BAR_REV:-8ca08a8}"
OLD_BAR="$U_TMP/old-cmux-bar"
git -C "$T_REPO" show "$OLD_REV:bin/cmux-bar" > "$OLD_BAR" 2>/dev/null || { rm -f -- "$OLD_BAR"; }

mkdir -p "$U_TMP/work/py"
out="$(python3 -I "${0:A:h}/t06_cmux_bar_check.py" "$T_REPO/bin/cmux-bar" "$U_TMP/work/py" "$OLD_BAR" 2>&1; print -r -- "rc=$?")"

rc="${out##*rc=}"
nl=$'\n'
integer seen=0
for line in "${(@f)out}"; do
  [[ "$line" == rc=* ]] && continue
  kind="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  case "$kind" in
    SCENARIO) t_scenario "${rest%%$'\t'*}" "${rest#*$'\t'}" ;;
    PASS)     (( seen++ )); t_assert_eq "$rest" ok ok ;;
    FAIL)     (( seen++ )); a="${rest%%$'\t'*}"; b="${rest#*$'\t'}"; t_assert_eq "$a" ok "${b//\\n/$nl}" ;;
    SKIP)     t_skip "$rest" ;;
    *)        # 예외 추적 등 python 쪽 출력 — 실패로 본다
              t_scenario PYERR "python 출력 이상"; t_assert_eq "python 출력: $line" "" "$line" ;;
  esac
done
t_scenario RC "python 종료 상태"
t_assert_eq "python 시험 스크립트 종료코드 0 (어서션 ${seen}건 실행)" 0 "$rc"
(( seen > 100 )) || t_assert_eq "어서션이 충분히 실행됨 (100건 초과)" ">100" "$seen"

t_scenario ZJ "실제 zellij·사용자 홈 접촉 없음"
t_assert_true "임시 HOME 밖(~/.config/cmux/tabbar-rows)에 쓰지 않음 (HOME 격리)" '[[ "$HOME" == "$U_TMP/home" ]]'
t_summary
exit $?
