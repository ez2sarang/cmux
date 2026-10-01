#!/usr/bin/env zsh
# t31_picker_pty — cmux-picker를 진짜 pty(tests/lib/ptyrun.py)에서 키 입력으로 구동해 stdout·종료코드·화면을 검증
#   zellij·harness 미사용. 임시 CMUX_ROOT(alpha/beta/gamma) + 임시 HOME(~/.config/cmux/projects 격리) + env -i
#   I1 새 env 없음: Enter / 이동+Space×2+Enter → 경로만, 기준 picker(P_BASE_REV)와 출력·화면 동일
#   I2 에이전트 3개, a 1회 + Enter → 경로<TAB>codex · 배지 [codex] · 안내줄
#   I3 Tab(선택 기본 codex) + Space×2 + Enter → 둘 다 경로<TAB>codex
#   I4 default=codex, Tab×2(선택 기본 claude) → claude 항목은 경로<TAB>claude, a로 codex가 된 항목은 경로만
#   I5 prefs 기억 → 사전선택(논리·물리 경로 키), 미등록 에이전트 무시
#   I6 Esc / q / Ctrl+C → 빈 출력 exit 0
#   I7 등록 1개: a·Tab 무시 → 경로만, 화면은 기준 picker와 동일
#   I8 실패 경로 유지: 루트 없음 / 읽기 권한 없음(TCC 흉내) → stderr 경고 + exit 1
# 실패하면 임시 디렉토리(pty 로그 *.log, 렌더링한 마지막 화면 *.screen)를 남긴다. P_KEEP=1이면 항상 남긴다.
# 대상 교체(뮤테이션 확인 등): CMUX_PICKER_UNDER_TEST=/경로/cmux-picker

P_NAME="${${0:t}%.zsh}"
P_REPO="${0:A:h:h:h}"
P_PTYRUN="$P_REPO/tests/lib/ptyrun.py"
P_PICKER="${${CMUX_PICKER_UNDER_TEST:-$P_REPO/bin/cmux-picker}:A}"
P_BASE_REV="e229198"   # 에이전트 선택 도입 직전 picker — "새 env 없음 = 기존과 동일" 비교 기준
P_COLS=100 P_ROWS=14
P_PASS=0 P_FAIL=0 P_SKIP=0

P_TMP_L="$(mktemp -d /tmp/cmuxp.XXXXXX)" || exit 1   # 논리 경로 (/tmp/…)
P_TMP="${P_TMP_L:A}"                                  # 물리 경로 (/private/tmp/…)
_p_cleanup() {
  chmod -R u+rwx -- "$P_TMP" 2>/dev/null
  if (( P_FAIL > 0 )) || [[ -n "$P_KEEP" ]]; then
    print -r -- "로그 보존: $P_TMP  (*.log = pty 원본, *.screen = 마지막 화면, *.out/*.err/*.rc)"
  else
    rm -rf -- "$P_TMP"
  fi
}
trap _p_cleanup EXIT

_p_pass() { (( P_PASS++ )); print -r -- "  PASS  $1"; }
_p_fail() { (( P_FAIL++ )); print -r -- "  FAIL  $1"; [[ -n "$2" ]] && print -r -- "$2" | sed 's/^/          /'; return 0; }
p_skip()  { (( P_SKIP++ )); print -r -- "  SKIP  $1"; }
p_scenario() { print -r -- "── $1  $2"; }
p_eq() {
  if [[ "$3" == "$2" ]]; then _p_pass "$1"
  else _p_fail "$1" "기대: ${(qqqq)2}"$'\n'"실제: ${(qqqq)3}"; fi
}
p_has() {
  if [[ "$2" == *"$3"* ]]; then _p_pass "$1"
  else _p_fail "$1" "없음: ${(qqqq)3}"$'\n'"화면:"$'\n'"$2"; fi
}
p_lacks() {
  if [[ "$2" != *"$3"* ]]; then _p_pass "$1"
  else _p_fail "$1" "있으면 안 됨: ${(qqqq)3}"$'\n'"화면:"$'\n'"$2"; fi
}

# ── 화면 렌더러: pty 로그(ncurses 출력) → 마지막 화면 텍스트 ──
# picker가 쓰는 시퀀스(CUP·HPA·VPA·커서 이동·EL·ED·ECH·REP)만 해석한다. 색·모드 전환은 무시.
cat > "$P_TMP/screen.py" <<'PY'
import re
import sys
import unicodedata

data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
cols, rows = int(sys.argv[2]), int(sys.argv[3])
scr = [[" "] * cols for _ in range(rows)]
y = x = 0
saved = (0, 0)
last = " "


def clamp():
    global x, y
    y = max(0, min(rows - 1, y))
    x = max(0, min(cols - 1, x))


def blank(row, a, b):
    """[a, b) 칸을 지운다 — 넓은 문자의 반쪽만 걸치면 나머지 반쪽도 지운다(터미널 동작)."""
    a, b = max(0, a), min(cols, b)
    if a >= b:
        return
    if scr[row][a] == "" and a > 0:
        scr[row][a - 1] = " "
    if b < cols and scr[row][b] == "":
        scr[row][b] = " "
    for i in range(a, b):
        scr[row][i] = " "


def put(ch):
    global x, last
    w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    if x + w > cols:
        x = cols
        return
    blank(y, x, x + w)
    scr[y][x] = ch
    if w == 2:
        scr[y][x + 1] = ""
    x += w
    last = ch


tok = re.compile(r"\x1b\[([?>=]?)([0-9;]*)[ -/]*([@-~])|\x1b[()*+].|\x1b.|[\x00-\x1f]|[^\x00-\x1f\x1b]")
for mt in tok.finditer(data):
    s = mt.group(0)
    if mt.group(3):
        if mt.group(1):
            continue  # ?1049h 등 사설 모드
        ps = [int(p) if p else 0 for p in mt.group(2).split(";")] if mt.group(2) else []
        n = ps[0] if ps and ps[0] else 1
        f = mt.group(3)
        if f in "Hf":
            y = (ps[0] if ps and ps[0] else 1) - 1
            x = (ps[1] if len(ps) > 1 and ps[1] else 1) - 1
        elif f == "A":
            y -= n
        elif f == "B":
            y += n
        elif f == "C":
            x += n
        elif f == "D":
            x -= n
        elif f == "G":
            x = n - 1
        elif f == "d":
            y = n - 1
        elif f == "J":
            mode = ps[0] if ps else 0
            for r in range(rows):
                if mode >= 2 or (mode == 0 and r > y) or (mode == 1 and r < y):
                    blank(r, 0, cols)
            if mode == 0:
                blank(y, x, cols)
            elif mode == 1:
                blank(y, 0, x + 1)
        elif f == "K":
            mode = ps[0] if ps else 0
            blank(y, x if mode == 0 else 0, cols if mode != 1 else x + 1)
        elif f == "X":
            blank(y, x, x + n)
        elif f == "b":
            for _ in range(n):
                put(last)
        elif f == "P":
            del scr[y][x:x + n]
            scr[y].extend([" "] * (cols - len(scr[y])))
        elif f == "@":
            scr[y][x:x] = [" "] * n
            del scr[y][cols:]
        if f not in "b":
            clamp()
    elif s == "\r":
        x = 0
    elif s == "\n":
        y += 1
        clamp()
    elif s == "\b":
        x -= 1
        clamp()
    elif s == "\x1b7":
        saved = (y, x)
    elif s == "\x1b8":
        y, x = saved
    elif len(s) == 1 and s >= " ":
        put(s)
print("\n".join("".join(r).rstrip() for r in scr).rstrip("\n"))
PY

# ── 실행 ──────────────────────────────────────────────
# p_run <이름> <picker> [키...] — P_ROOT·P_ENV(KEY=VAL 배열)로 picker를 pty(P_COLS×P_ROWS)에서 실행.
#   키는 1.0초부터 0.35초 간격(ptyrun --send 이스케이프: \r Enter, \t Tab, \x1b Esc, \x03 Ctrl+C).
#   picker는 /dev/tty를 직접 열고 결과만 stdout으로 낸다 → stdout을 파일로 받는다.
#   sh의 'trap : INT'는 Ctrl+C 때 sh가 먼저 죽지 않고 picker 종료코드를 기록하게 한다(자식에겐 기본 동작으로 전달).
#   결과: P_OUT P_RC(기록 없으면 none) P_ERR P_SCREEN, 파일은 $P_TMP/<이름>.{log,out,err,rc,screen,pty}
p_run() {
  local name="$1" picker="$2"; shift 2
  local f="$P_TMP/$name" k
  typeset -F 2 t=1.0
  local -a sends=()
  for k in "$@"; do sends+=(--send "$t:$k"); (( t += 0.35 )); done
  env -i PATH="$PATH" HOME="$P_TMP/home" LANG=en_US.UTF-8 TERM=xterm-256color CMUX_ROOT="$P_ROOT" "${P_ENV[@]}" \
    python3 "$P_PTYRUN" --log "$f.log" --secs 10 --cols $P_COLS --rows $P_ROWS "${sends[@]}" -- \
    sh -c 'trap : INT; "$0" > "$1" 2> "$2"; echo $? > "$3"' "$picker" "$f.out" "$f.err" "$f.rc" 2> "$f.pty"
  P_OUT="$(cat "$f.out" 2>/dev/null)"
  P_RC="$(cat "$f.rc" 2>/dev/null || print none)"
  P_ERR="$(cat "$f.err" 2>/dev/null)"
  python3 "$P_TMP/screen.py" "$f.log" $P_COLS $P_ROWS > "$f.screen" 2>> "$f.pty"
  P_SCREEN="$(cat "$f.screen")"
}

mkdir -p "$P_TMP"/root/{alpha,beta,gamma} "$P_TMP/home"
R="$P_TMP/root"
P_ROOT="$R"
typeset -a P_ENV=()
TAB=$'\t'

P_BASE="$P_TMP/base-picker"
if git -C "$P_REPO" show "$P_BASE_REV:bin/cmux-picker" > "$P_BASE" 2>/dev/null; then
  chmod +x "$P_BASE"
else
  P_BASE=""
fi
print -r -- "대상 picker: $P_PICKER"
print -r -- "기준 picker: ${${P_BASE:+$P_BASE_REV:bin/cmux-picker}:-(없음 — 비교 SKIP)}"

# ── I1 ────────────────────────────────────────────────
p_scenario I1 "새 env 없음 → 경로만, 기준 picker와 출력·화면 동일"
P_ENV=()
p_run i1a "$P_PICKER" '\r'
i1a_out="$P_OUT" i1a_screen="$P_SCREEN"
p_eq "Enter → 첫 항목 경로만" "$R/alpha" "$P_OUT"
p_eq "exit 0" "0" "$P_RC"
p_has "임시 HOME·CMUX_ROOT 격리 — 프로젝트 3개만 표시" "$P_SCREEN" "프로젝트 선택 (3개)"
p_lacks "안내줄 없음(에이전트 1개)" "$P_SCREEN" "기본 에이전트"
p_lacks "배지 없음" "$P_SCREEN" "["
p_run i1b "$P_PICKER" l ' ' ' ' '\r'
i1b_out="$P_OUT" i1b_screen="$P_SCREEN"
p_eq "l + Space×2 + Enter → 두 경로, 경로만" "$R/beta"$'\n'"$R/gamma" "$P_OUT"
if [[ -n "$P_BASE" ]]; then
  p_run i1a-base "$P_BASE" '\r'
  p_eq "기준 picker와 출력 동일 (Enter)" "$P_OUT" "$i1a_out"
  p_eq "기준 picker와 화면 동일 (Enter)" "$P_SCREEN" "$i1a_screen"
  base_i1a_screen="$P_SCREEN"
  p_run i1b-base "$P_BASE" l ' ' ' ' '\r'
  p_eq "기준 picker와 출력 동일 (다중 선택)" "$P_OUT" "$i1b_out"
  p_eq "기준 picker와 화면 동일 (다중 선택)" "$P_SCREEN" "$i1b_screen"
else
  p_skip "기준 picker 비교 — git show $P_BASE_REV 실패"
fi

# ── I2 ────────────────────────────────────────────────
p_scenario I2 "에이전트 3개, a 1회 + Enter → 경로<TAB>codex"
P_ENV=(CMUX_PICKER_AGENTS="claude codex opencode")
p_run i2 "$P_PICKER" a '\r'
p_eq "출력 = 경로<TAB>codex" "$R/alpha${TAB}codex" "$P_OUT"
p_eq "exit 0" "0" "$P_RC"
p_has "커서 항목 배지 [codex]" "$P_SCREEN" "▶ alpha [codex] ◀"
p_eq "안내줄(row 1)에 선택 기본·키 안내" "  기본 에이전트: claude   a:에이전트 Tab:기본" "${${(@f)P_SCREEN}[2]}"
p_eq "타이틀은 기존과 같음" "cmux — 프로젝트 선택 (3개)" "$(print -r -- "${${(@f)P_SCREEN}[1]}" | sed 's/^ *//')"
p_has "기존 하단 키 안내 유지" "$P_SCREEN" "Space:선택   Enter:열기   Esc:취소"

# ── I3 ────────────────────────────────────────────────
p_scenario I3 "Tab(선택 기본 codex) + Space×2 + Enter → 둘 다 경로<TAB>codex"
p_run i3 "$P_PICKER" '\t' ' ' ' ' '\r'
p_eq "출력 = 두 항목 모두 경로<TAB>codex" "$R/alpha${TAB}codex"$'\n'"$R/beta${TAB}codex" "$P_OUT"
p_has "안내줄 선택 기본 = codex" "$P_SCREEN" "기본 에이전트: codex"
p_lacks "선택 기본과 같으면 배지 없음" "$P_SCREEN" "[codex]"
p_has "선택 개수 표시 유지" "$P_SCREEN" "● 2개"   # '선택'은 기존 picker도 우측 끝에서 잘린다(len 기준 배치)

# ── I4 ────────────────────────────────────────────────
p_scenario I4 "default=codex, Tab×2(선택 기본 claude) → default와 같은 것만 경로만"
P_ENV=(CMUX_PICKER_AGENTS="claude codex opencode" CMUX_PICKER_DEFAULT_AGENT=codex)
p_run i4 "$P_PICKER" '\t' '\t' ' ' a ' ' '\r'
p_eq "alpha(claude) → 경로<TAB>claude, beta(a로 codex = default) → 경로만" \
  "$R/alpha${TAB}claude"$'\n'"$R/beta" "$P_OUT"
p_has "안내줄 선택 기본 = claude" "$P_SCREEN" "기본 에이전트: claude"
p_has "beta 배지 [codex] (선택 기본 claude와 다름)" "$P_SCREEN" "● beta [codex] ●"
p_has "alpha 배지 없음" "$P_SCREEN" "● alpha ●"

# ── I5 ────────────────────────────────────────────────
p_scenario I5 "prefs 기억 → 사전선택 (논리·물리 경로 키), 미등록 무시"
# CMUX_ROOT를 논리 경로(/tmp/…)로 준다 — cmux는 기억을 realpath로 남기므로 물리 경로 키도 찾아야 한다
P_ROOT="$P_TMP_L/root"
print -r -- "$P_TMP_L/root/alpha${TAB}opencode"$'\n'"$P_TMP_L/root/beta${TAB}gemini"$'\n'"$P_TMP/root/gamma${TAB}codex" \
  > "$P_TMP/project-agents"
P_ENV=(CMUX_PICKER_AGENTS="claude codex opencode" CMUX_PICKER_PREFS_FILE="$P_TMP/project-agents")
p_run i5 "$P_PICKER" ' ' ' ' ' ' '\r'
p_eq "alpha=opencode(논리 키), beta=gemini 무시→경로만, gamma=codex(물리 키)" \
  "$P_TMP_L/root/alpha${TAB}opencode"$'\n'"$P_TMP_L/root/beta"$'\n'"$P_TMP_L/root/gamma${TAB}codex" "$P_OUT"
p_has "기억 배지 [opencode]" "$P_SCREEN" "alpha [opencode]"
p_has "기억 배지 [codex]" "$P_SCREEN" "gamma [codex]"
p_lacks "미등록 gemini 배지 없음" "$P_SCREEN" "[gemini]"
p_eq "prefs 파일 불변(읽기만)" "3" "$(grep -c . "$P_TMP/project-agents")"
P_ROOT="$R"

# ── I6 ────────────────────────────────────────────────
p_scenario I6 "Esc / q / Ctrl+C → 빈 출력 exit 0"
P_ENV=(CMUX_PICKER_AGENTS="claude codex opencode")
for name key in esc '\x1b' q q ctrlc '\x03'; do
  p_run "i6-$name" "$P_PICKER" a "$key"
  p_eq "a 후 $name → 빈 출력" "" "$P_OUT"
  p_eq "a 후 $name → exit 0" "0" "$P_RC"
  p_lacks "a 후 $name → 트레이스백 없음" "$P_ERR" "Traceback"
done

# ── I7 ────────────────────────────────────────────────
p_scenario I7 "등록 1개 → a·Tab 무시, 화면은 기준 picker와 동일"
print -r -- "$R/alpha${TAB}codex" > "$P_TMP/prefs-one"
P_ENV=(CMUX_PICKER_AGENTS=claude CMUX_PICKER_PREFS_FILE="$P_TMP/prefs-one")
p_run i7 "$P_PICKER" a '\t' '\r'
p_eq "a·Tab 후 Enter → 경로만 (미등록 codex 기억도 무시)" "$R/alpha" "$P_OUT"
p_lacks "안내줄 없음" "$P_SCREEN" "기본 에이전트"
if [[ -n "$base_i1a_screen" ]]; then
  p_eq "기준 picker 화면과 동일" "$base_i1a_screen" "$P_SCREEN"
else
  p_skip "기준 picker 화면 비교 — 기준 없음"
fi

# ── I8 ────────────────────────────────────────────────
p_scenario I8 "실패 경로 유지 — stderr 경고 + exit 1"
P_ENV=(CMUX_PICKER_AGENTS="claude codex")
P_ROOT="$P_TMP/없음"
p_run i8-missing "$P_PICKER"
p_eq "루트 없음 → exit 1" "1" "$P_RC"
p_has "루트 없음 → 경고" "$P_ERR" "표시할 프로젝트가 없습니다"
p_eq "루트 없음 → 출력 없음" "" "$P_OUT"
mkdir -p "$P_TMP/locked/alpha"
chmod 000 "$P_TMP/locked"
P_ROOT="$P_TMP/locked"
p_run i8-perm "$P_PICKER"
chmod 755 "$P_TMP/locked"
p_eq "읽기 권한 없음 → exit 1" "1" "$P_RC"
p_has "읽기 권한 없음 → TCC 경고" "$P_ERR" "macOS TCC 차단 추정"
P_ROOT="$R"

print -r -- ""
print -r -- "RESULT $P_NAME pass=$P_PASS fail=$P_FAIL skip=$P_SKIP"
(( P_FAIL == 0 ))
