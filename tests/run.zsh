#!/usr/bin/env zsh
# cmux 테스트 러너 — zsh tests/run.zsh [unit|integration|all]   (기본 all)
# 순서: 구문검사 → 단위(tests/unit/t*.zsh) → 통합(tests/integration/t*.zsh). 하나라도 실패하면 비0 종료.
# shellcheck는 미설치 — zsh -n / sh -n / python ast로 구문만 검사한다.

# 라이브 zellij 세션 pane 안에서 실행해도 zellij 명령이 라이브 세션을 겨냥하지 못하게
for _v in ${(k)parameters[(I)ZELLIJ*]}; do unset "$_v"; done
unset _v

REPO="${0:A:h:h}"
MODE="${1:-all}"
case "$MODE" in
  unit|integration|all) ;;
  *) print -u2 "사용법: zsh tests/run.zsh [unit|integration|all]"; exit 2 ;;
esac

typeset -a summary
fail=0

_record() {  # <이름> <rc> [상세]
  if (( $2 == 0 )); then summary+=("PASS  $1${3:+  $3}")
  else summary+=("FAIL  $1${3:+  $3}"); fail=1; fi
}

# ── 구문검사 ──────────────────────────────────────────
print "== 구문검사"
syntax_rc=0
for f in "$REPO/bin/cmux" "$REPO/bin/cmux-agents.zsh" "$REPO"/tests/**/*.zsh(N); do
  zsh -n "$f" || { print -u2 "  구문 오류: $f"; syntax_rc=1; }
done
if [[ -n "$CMUX_UNDER_TEST" && "${CMUX_UNDER_TEST:A}" != "$REPO/bin/cmux" ]]; then
  for f in "$CMUX_UNDER_TEST" "${CMUX_UNDER_TEST:A:h}/cmux-agents.zsh"(N); do
    zsh -n "$f" || { print -u2 "  구문 오류: $f"; syntax_rc=1; }
  done
fi
sh -n "$REPO/tests/bin/fake-agent" || syntax_rc=1
for f in "$REPO/tests/lib/ptyrun.py" "$REPO/bin/cmux-bar"; do
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || syntax_rc=1
done
_record "구문검사 (zsh -n / sh -n / python ast)" $syntax_rc

# 테스트 파일 하나 실행 → RESULT 줄 파싱
_run_file() {
  local f="$1" out rc result
  print "\n== ${f:t}"
  out="$(zsh "$f" 2>&1)"
  rc=$?
  print -r -- "$out"
  result="$(print -r -- "$out" | grep '^RESULT ' | tail -1)"
  [[ -z "$result" && $rc -eq 0 ]] && rc=1   # RESULT 줄 없이 끝나면(중도 종료) 실패
  _record "${f:t}" $rc "${result#RESULT * }"
}

# ── 단위 ──────────────────────────────────────────────
# 단위 테스트는 CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST"로 함수 정의만 로드한다 (zellij 세션 없음)
if [[ "$MODE" == (unit|all) ]]; then
  typeset -a units=("$REPO"/tests/unit/t*.zsh(N))
  if (( ${#units} == 0 )); then
    print "\n== 단위: 테스트 없음 (0개)"
  else
    for f in "${units[@]}"; do _run_file "$f"; done
  fi
fi

# ── 통합 ──────────────────────────────────────────────
if [[ "$MODE" == (integration|all) ]]; then
  if ! command -v zellij >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    _record "통합 (zellij/python3 없음)" 1
  else
    for f in "$REPO"/tests/integration/t*.zsh(N); do _run_file "$f"; done
  fi
fi

print "\n== 전체 요약 ($MODE)"
print -l -- "${summary[@]}" | sed 's/^/  /'
(( fail == 0 )) && print "ALL PASS" || print "FAILED"
exit $fail
