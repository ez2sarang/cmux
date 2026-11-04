#!/usr/bin/env zsh
# t09_bridge — 지침 파일 연결(AGENTS.md ↔ CLAUDE.md) 단위 테스트 (CMUX_SOURCE_ONLY=1 source + 별도 프로세스 'cmux bridge', zellij·실제 에이전트 없음)
#   B1 _bridge_state — none / agents-only / claude-only / linked(@AGENTS.md · @./AGENTS.md · CLAUDE.md 언급 · 같은 파일 링크) / unlinked / unsafe(끊어진 링크·디렉토리)
#   B2 _bridge_launch <에이전트> — 실행하는 에이전트가 필요로 하는 파일만 자동 생성하고, 안내 한 줄도 같은 원칙(그 에이전트가 읽는 파일이 이미 있으면 조용):
#      (AGENTS.md만 | CLAUDE.md만) × (.collar 있음/없음) × (claude | codex | kimi) 12조합 매트릭스, 둘 다 있음(안내 유지)·연결됨·없음·unsafe 는 무변경, 두 번째 호출은 조용함
#   B3 cmux bridge --check — 기본이 check(쓰기 없음), 종료코드 0/10/2/3/1
#   B4 cmux bridge --apply — 생성 내용, 둘 다 있을 때 마커 블록(블록 밖 바이트 불변·개행 없는 끝·CRLF·빈 파일), 멱등, 모드 유지, 임시파일 잔여 없음, 공백 든 경로,
#      쓰기 불가 폴더 → 사용자용 한 줄 오류(rc 1)만, zsh 내부 오류문 새지 않음
#   B5 마커 손상(begin만·end만·중복·뒤집힘)·심볼릭 링크(다른 곳을 가리킴·끊어짐) → 무변경 + 비0
#   B6 _launch_agent 통합 — 연결이 collar-agents-sync보다 먼저(포인터 → collar 블록 순) · 쓰기 실패여도 launch 계속 · claude는 CLAUDE.md만(AGENTS.md를 만들지 않음)·kimi는 AGENTS.md만
#   B7 실제 collar-agents-sync와 순서·공존 (있을 때만)
#   B8 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

# 실제 collar-agents-sync (B7용) — PATH·HOME을 바꾸기 전에 찾는다
REAL_SYNC="$(command -v collar-agents-sync 2>/dev/null)"

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'chmod -R u+rwx -- "$U_TMP" 2>/dev/null; rm -rf -- "$U_TMP"' EXIT

mkdir -p "$U_TMP"/{home,bin,zdotdir,cfg}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs" CMUX_CONFIG_FILE="$U_TMP/cfg/config"
export CMUX_AGENT_ARGS_FILE="$U_TMP/cfg/agent-args"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
# 가짜 collar-agents-sync: 호출 시점의 AGENTS.md 첫 줄을 기록하고, 실제 sync처럼 AGENTS.md 최상단에 collar 블록을 넣는다(없으면 새로 만든다)
cat > "$U_TMP/bin/collar-agents-sync" <<'SH'
#!/bin/sh
first="none"
[ -f "$1/AGENTS.md" ] && first="$(head -1 "$1/AGENTS.md")"
printf '%s|first=%s\n' "$1" "$first" >> "${FAKE_SYNC_LOG:-/dev/null}"
[ -d "$1/.collar" ] || exit 0
tmp="$1/.AGENTS.md.fake-sync.$$"
{ printf '<!-- collar:begin v2 -->\nFAKE BLOCK\n<!-- collar:end -->\n'; if [ -f "$1/AGENTS.md" ]; then printf '\n'; cat "$1/AGENTS.md"; fi; } > "$tmp" && mv "$tmp" "$1/AGENTS.md"
exit 0
SH
chmod +x "$U_TMP/bin/zellij" "$U_TMP/bin/collar-agents-sync"
for a in claude codex opencode kimi; do ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-$a"; done
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude" CMUX_CODEX_BIN="$U_TMP/bin/fake-codex" CMUX_OPENCODE_BIN="$U_TMP/bin/fake-opencode" CMUX_KIMI_BIN="$U_TMP/bin/fake-kimi"
export PATH="$U_TMP/bin:$PATH"
export FAKE_AGENT_LOG="$U_TMP/fake.log" FAKE_AGENT_SLEEP=0 FAKE_SYNC_LOG="$U_TMP/sync.log"
: > "$FAKE_AGENT_LOG"; : > "$FAKE_SYNC_LOG"
export CMUX_SOURCE_ONLY=1

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }

# ── 공용 도우미 ───────────────────────────────────────
strip() { sed $'s/\e\\[[0-9;]*m//g'; }
# _cb <인자...> — cmux bridge 를 별도 프로세스로 (stdout+stderr, ANSI 제거) + 마지막 줄 "rc=<rc>"
_cb() { local out; out="$(CMUX_SOURCE_ONLY= zsh "$CMUX_UNDER_TEST" bridge "$@" 2>&1)"; local rc=$?; print -r -- "$out" | strip; print -r -- "rc=$rc"; }
_rc() { _cb "$@" | tail -1; }
# 프로젝트 만들기 (이름 → 경로 $B1/<이름>)
B1="$U_TMP/proj"
mkdir -p "$B1"
_mkp() { mkdir -p "$B1/$1"; [[ "$2" == collar ]] && mkdir -p "$B1/$1/.collar"; print -r -- "$B1/$1"; }
_nlines() { local -a l=("${(@f)1}"); print -r -- ${#l}; }
_sum() { md5 -q "$1" 2>/dev/null || print -r -- MISSING; }
# 디렉토리 전체 스냅샷 (이름·크기·내용 해시) — 무변경 확인용
_snap() { local f; for f in "$1"/*(DN) "$1"/.collar/*(DN); do print -r -- "${f:t} $(_sum "$f")"; done; print -r -- "ls:$(ls -A "$1" | tr '\n' ' ')"; }
CLAUDE_NEW=$'<!-- cmux:bridge -->\n<!-- 지침 원본은 AGENTS.md 입니다(codex·opencode·kimi 등과 공유). 아래 줄이 Claude Code에 그 내용을 불러옵니다. -->\n@AGENTS.md'
GRAY=$'\e[90m'

# ── B1 ────────────────────────────────────────────────
t_scenario B1 "_bridge_state 판정"
_st() { _bridge_state "$1"; print -r -- "$_br_state"; }
d="$(_mkp none)"
t_assert_eq "둘 다 없음 → none" none "$(_st "$d")"
d="$(_mkp ao)"; print -r -- "# a" > "$d/AGENTS.md"
t_assert_eq "AGENTS.md만 → agents-only" agents-only "$(_st "$d")"
d="$(_mkp co)"; print -r -- "# c" > "$d/CLAUDE.md"
t_assert_eq "CLAUDE.md만 → claude-only" claude-only "$(_st "$d")"
d="$(_mkp l1)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- $'# c\n@AGENTS.md' > "$d/CLAUDE.md"
t_assert_eq "CLAUDE.md에 @AGENTS.md → linked" linked "$(_st "$d")"
d="$(_mkp l2)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- $'# c\n@./AGENTS.md' > "$d/CLAUDE.md"
t_assert_eq "CLAUDE.md에 @./AGENTS.md → linked" linked "$(_st "$d")"
d="$(_mkp l3)"; print -r -- "읽을 것: CLAUDE.md 참고" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"
t_assert_eq "AGENTS.md가 CLAUDE.md를 언급 → linked" linked "$(_st "$d")"
d="$(_mkp l4)"; print -r -- "# c" > "$d/CLAUDE.md"; ln -s CLAUDE.md "$d/AGENTS.md"
t_assert_eq "AGENTS.md → CLAUDE.md 심볼릭 링크(같은 파일) → linked" linked "$(_st "$d")"
d="$(_mkp l5)"; print -r -- "# a" > "$d/AGENTS.md"; ln -s AGENTS.md "$d/CLAUDE.md"
t_assert_eq "CLAUDE.md → AGENTS.md 심볼릭 링크 → linked" linked "$(_st "$d")"
d="$(_mkp un)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c  agents? no" > "$d/CLAUDE.md"
t_assert_eq "둘 다 있고 서로 참조 없음 → unlinked ('AGENTS.md' 글자만으로는 연결 아님: @ 없음)" unlinked "$(_st "$d")"
d="$(_mkp un2)"; print -r -- "# a  mentions agents" > "$d/AGENTS.md"; print -r -- "agents.md 와 @AGENTS 는 아님" > "$d/CLAUDE.md"
t_assert_eq "비슷하지만 다른 글자(@AGENTS, agents.md) → unlinked" unlinked "$(_st "$d")"
d="$(_mkp dang)"; ln -s /nonexistent/xyz "$d/AGENTS.md"
t_assert_eq "AGENTS.md가 끊어진 링크 → unsafe ('없음'으로 보고 덮어쓰지 않는다)" unsafe "$(_st "$d")"
d="$(_mkp dirc)"; mkdir "$d/CLAUDE.md"; print -r -- a > "$d/AGENTS.md"
t_assert_eq "CLAUDE.md가 디렉토리 → unsafe" unsafe "$(_st "$d")"
d="$(_mkp noread)"; print -r -- a > "$d/AGENTS.md"; chmod 000 "$d/AGENTS.md"
t_assert_eq "읽을 수 없는 AGENTS.md → unsafe" unsafe "$(_st "$d")"
chmod 644 "$d/AGENTS.md"

# ── B2 ────────────────────────────────────────────────
t_scenario B2 "_bridge_launch — 네 가지 상태 × .collar 유무"
# _bl <프로젝트 경로> → stdout(배너 줄)만. 서브셸에서 cd.
_bl() { (cd "$1" && _bridge_launch "${2:-claude}") 2>&1 | strip; }   # <경로> [에이전트=claude]
# (a) AGENTS.md만
d="$(_mkp bl-ao-c collar)"; print -r -- "# a" > "$d/AGENTS.md"; sa="$(_sum "$d/AGENTS.md")"
out="$(_bl "$d")"
t_assert_eq "AGENTS.md만 + .collar → CLAUDE.md 신규 (내용 정확)" "$CLAUDE_NEW" "$(cat "$d/CLAUDE.md")"
t_assert_eq "AGENTS.md는 그대로" "$sa" "$(_sum "$d/AGENTS.md")"
t_assert_contains "안내 한 줄: 생성 + 커밋·ignore는 직접" "$out" "▶ 지침 연결: AGENTS.md 만 있어 CLAUDE.md(@AGENTS.md)를 만들었습니다 — 커밋·ignore는 직접 정하세요"
t_assert_eq "안내는 정확히 1줄" 1 "$(_nlines "$out")"
t_assert_eq "임시파일 잔여 없음" "AGENTS.md CLAUDE.md " "$(cd "$d/.." && ls -A bl-ao-c | grep -v '^.collar$' | tr '\n' ' ')"
t_assert_eq "두 번째 호출은 조용하고 파일 불변" "|$(_sum "$d/CLAUDE.md")" "$(_bl "$d")|$(_sum "$d/CLAUDE.md")"
t_assert_eq "원본 .git 같은 것은 건드리지 않음 (git add/commit 없음: .git 생성 안 함)" "no" "$([[ -e "$d/.git" ]] && print yes || print no)"
d="$(_mkp bl-ao-n)"; print -r -- "# a" > "$d/AGENTS.md"
out="$(_bl "$d")"
t_assert_true "AGENTS.md만 + .collar 없음 → 파일 생성 없음" '[[ ! -e "$d/CLAUDE.md" ]]'
t_assert_contains "안내 한 줄에 cmux bridge --apply <경로>" "$out" "▶ 지침 파일이 한쪽뿐입니다(AGENTS.md 만 있음) — 'cmux bridge --apply $d' 로 연결할 수 있습니다"
t_assert_eq "안내 1줄" 1 "$(_nlines "$out")"
t_assert_eq "AGENTS.md만 + .collar 없음 + codex → 조용 (codex 는 AGENTS.md 를 이미 읽는다)" "" "$(_bl "$d" codex)"
# (b) CLAUDE.md만
d="$(_mkp bl-co-c collar)"; print -r -- "# c" > "$d/CLAUDE.md"; sc="$(_sum "$d/CLAUDE.md")"
out="$(_bl "$d" codex)"
t_assert_contains "CLAUDE.md만 + .collar + codex → AGENTS.md 신규: 마커 + 포인터" "$(cat "$d/AGENTS.md")" $'<!-- cmux:bridge -->\n이 프로젝트의 지침은 ./CLAUDE.md 에 있습니다. 작업을 시작하기 전에 CLAUDE.md 를 처음부터 끝까지 읽고 그대로 따르세요.'
t_assert_contains "포인터에 임포트 문법 없음 안내" "$(cat "$d/AGENTS.md")" "AGENTS.md 에는 파일 불러오기 문법이 없어"
t_assert_eq "CLAUDE.md는 그대로" "$sc" "$(_sum "$d/CLAUDE.md")"
t_assert_contains "안내 한 줄" "$out" "▶ 지침 연결: CLAUDE.md 만 있어 AGENTS.md(CLAUDE.md 포인터)를 만들었습니다 — 커밋·ignore는 직접 정하세요"
t_assert_eq "두 번째 codex 호출은 조용하고 불변" "|$(_sum "$d/AGENTS.md")" "$(_bl "$d" codex)|$(_sum "$d/AGENTS.md")"
d="$(_mkp bl-co-n)"; print -r -- "# c" > "$d/CLAUDE.md"
out="$(_bl "$d" codex)"
t_assert_true "CLAUDE.md만 + .collar 없음 → 파일 생성 없음" '[[ ! -e "$d/AGENTS.md" ]]'
t_assert_contains "CLAUDE.md만 + .collar 없음 + codex → 안내 한 줄 (codex 는 CLAUDE.md 를 못 읽는다)" "$out" "▶ 지침 파일이 한쪽뿐입니다(CLAUDE.md 만 있음) — 'cmux bridge --apply $d' 로 연결할 수 있습니다"
t_assert_eq "CLAUDE.md만 + .collar 없음 + claude → 조용 (claude 는 CLAUDE.md 를 이미 읽는다)" "" "$(_bl "$d" claude)"
# (c) 둘 다 있음 — 어느 쪽이든 자동 수정 금지
d="$(_mkp bl-un-c collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"; s0="$(_snap "$d")"
out="$(_bl "$d")"
t_assert_eq "둘 다 + 서로 참조 없음 + .collar → 자동 수정 금지(무변경)" "$s0" "$(_snap "$d")"
t_assert_contains "안내 한 줄" "$out" "▶ AGENTS.md 와 CLAUDE.md 가 서로 참조하지 않습니다 — 'cmux bridge --apply $d' 로 연결할 수 있습니다"
d="$(_mkp bl-un-n)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"; s0="$(_snap "$d")"
out="$(_bl "$d")"
t_assert_eq "둘 다 + 참조 없음 + .collar 없음 → 무변경" "$s0" "$(_snap "$d")"
t_assert_contains "안내 한 줄" "$out" "▶ AGENTS.md 와 CLAUDE.md 가 서로 참조하지 않습니다"
d="$(_mkp bl-li-c collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- $'# c\n@AGENTS.md' > "$d/CLAUDE.md"; s0="$(_snap "$d")"
t_assert_eq "연결됨 → 출력 없음·무변경" "|$s0" "$(_bl "$d")|$(_snap "$d")"
d="$(_mkp bl-none-c collar)"; s0="$(_snap "$d")"
t_assert_eq "둘 다 없음 + .collar → 출력 없음·생성 없음" "|$s0" "$(_bl "$d")|$(_snap "$d")"
d="$(_mkp bl-dang collar)"; ln -s /nonexistent/xyz "$d/AGENTS.md"
t_assert_eq "끊어진 링크(unsafe) → 출력 없음·생성 없음" "|ls:AGENTS.md " "$(_bl "$d")|$(cd "$d" && print -r -- "ls:$(ls -A | grep -v '^.collar$' | tr '\n' ' ')")"
# (d) 매트릭스 — 자동 생성은 .collar 가 있고 '실행하는 에이전트가 필요로 하는 파일'일 때만, 안내도 같은 원칙:
#   claude → AGENTS.md만 있을 때 CLAUDE.md 가 필요 / 비-claude(codex·kimi) → CLAUDE.md만 있을 때 AGENTS.md 가 필요.
#   필요한데 .collar 가 없어 만들지 않았으면 안내(hint), 이 에이전트가 읽는 파일이 이미 있으면 조용(silent).
_mx() {   # <ao|co> <collar|nocollar> <에이전트> <기대: CLAUDE.md|AGENTS.md(그 파일 생성) | hint(안내만) | silent(조용)>
  local st="$1" cl="$2" ag="$3" want="$4" d out orig made sorig label
  d="$(_mkp "mx-$st-$cl-$ag" "$([[ $cl == collar ]] && print collar)")"
  [[ $st == ao ]] && orig=AGENTS.md || orig=CLAUDE.md
  print -r -- "# 원본" > "$d/$orig"; sorig="$(_sum "$d/$orig")"
  out="$(_bl "$d" "$ag")"
  label="${st:u}·${cl}·${ag}"
  made="$(ls -A "$d" | grep -v '^.collar$' | tr '\n' ' ' | sed 's/ $//')"
  case "$want" in
    silent)
      t_assert_eq "[$label] 쓰기 없음 (파일 그대로 $orig 하나)" "$orig" "$made"
      t_assert_eq "[$label] 출력 없음 (이 에이전트가 읽는 파일이 이미 있다)" "" "$out"
      ;;
    hint)
      t_assert_eq "[$label] 쓰기 없음 (파일 그대로 $orig 하나)" "$orig" "$made"
      t_assert_contains "[$label] 안내 한 줄" "$out" "▶ 지침 파일이 한쪽뿐입니다("
      t_assert_not_contains "[$label] '만들었습니다' 아님" "$out" "만들었습니다"
      t_assert_eq "[$label] 안내는 정확히 1줄" 1 "$(_nlines "$out")"
      ;;
    *)
      t_assert_eq "[$label] $want 만 새로 생성" "AGENTS.md CLAUDE.md" "$made"
      t_assert_contains "[$label] 생성 안내 한 줄" "$out" "▶ 지침 연결: "
      t_assert_true "[$label] $want 가 실제 생성됨" '[[ -f "$d/$want" ]]'
      t_assert_eq "[$label] 안내는 정확히 1줄" 1 "$(_nlines "$out")"
      ;;
  esac
  t_assert_eq "[$label] 원본 바이트 불변" "$sorig" "$(_sum "$d/$orig")"
}
#   .collar 있음                                  .collar 없음
_mx ao collar   claude CLAUDE.md;   _mx ao nocollar claude hint     # claude + AGENTS.md만: 읽지 못함 → 생성 / 안내
_mx ao collar   codex  silent;      _mx ao nocollar codex  silent   # 비-claude + AGENTS.md만: 이미 읽음 → 조용
_mx ao collar   kimi   silent;      _mx ao nocollar kimi   silent
_mx co collar   claude silent;      _mx co nocollar claude silent   # claude + CLAUDE.md만: 이미 읽음 → 조용 (재현: 예전엔 AGENTS.md 를 만들었다)
_mx co collar   codex  AGENTS.md;   _mx co nocollar codex  hint     # 비-claude + CLAUDE.md만: 읽지 못함 → 생성 / 안내
_mx co collar   kimi   AGENTS.md;   _mx co nocollar kimi   hint
# 둘 다 있음 / 연결됨 / 없음 / unsafe 는 에이전트와 무관하게 무변경 (claude·kimi 둘 다 확인)
for ag in claude kimi; do
  d="$(_mkp "mx-un-$ag" collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"; s0="$(_snap "$d")"
  out="$(_bl "$d" $ag)"
  t_assert_eq "[둘 다·참조 없음·$ag] 무변경" "$s0" "$(_snap "$d")"
  t_assert_contains "[둘 다·참조 없음·$ag] 안내만" "$out" "▶ AGENTS.md 와 CLAUDE.md 가 서로 참조하지 않습니다"
  d="$(_mkp "mx-li-$ag" collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "@AGENTS.md" > "$d/CLAUDE.md"; s0="$(_snap "$d")"
  t_assert_eq "[연결됨·$ag] 출력 없음·무변경" "|$s0" "$(_bl "$d" $ag)|$(_snap "$d")"
  d="$(_mkp "mx-none-$ag" collar)"; s0="$(_snap "$d")"
  t_assert_eq "[없음·$ag] 출력 없음·무변경" "|$s0" "$(_bl "$d" $ag)|$(_snap "$d")"
done
t_assert_eq "에이전트 인자 생략 = claude (AGENTS.md만 + .collar → CLAUDE.md)" "yes" "$(d="$(_mkp mx-default collar)"; print -r -- "# a" > "$d/AGENTS.md"; (cd "$d" && _bridge_launch >/dev/null 2>&1); [[ -f "$d/CLAUDE.md" ]] && print yes || print no)"
# 외부 프로세스 없이 순수 zsh: _bridge_launch 중 fork가 없다 (xtrace 없이 간접 확인 — 호출 시간이 매우 짧다)
d="$(_mkp bl-time collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"
t0=$EPOCHREALTIME; for i in {1..20}; do (cd "$d" && _bridge_launch >/dev/null); done; el=$(( EPOCHREALTIME - t0 ))
t_assert_true "launch 훅은 가볍다: 20회(서브셸 포함) ${el:0:5}초 < 2초" '(( el < 2 ))'

# ── B3 ────────────────────────────────────────────────
t_scenario B3 "cmux bridge --check (기본)"
d="$(_mkp ck-ao collar)"; print -r -- "# a" > "$d/AGENTS.md"; s0="$(_snap "$d")"
out="$(_cb "$d")"
t_assert_contains "기본은 check — 연결 필요 안내" "$out" "AGENTS.md 만 있음 — 'cmux bridge --apply $d' 로 연결할 수 있습니다"
t_assert_eq "연결 필요 → rc 10" "rc=10" "$(_rc "$d")"
t_assert_eq "check는 쓰기 없음 (.collar 있어도)" "$s0" "$(_snap "$d")"
t_assert_eq "--check 명시도 rc 10·무변경" "rc=10|$s0" "$(_rc --check "$d")|$(_snap "$d")"
t_assert_eq "경로 생략 = 현재 폴더" "rc=10" "$(cd "$d" && _rc --check)"
d="$(_mkp ck-co)"; print -r -- "# c" > "$d/CLAUDE.md"
t_assert_eq "CLAUDE.md만 → rc 10" "rc=10" "$(_rc "$d")"
d="$(_mkp ck-un)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"
out="$(_cb "$d")"
t_assert_contains "둘 다·참조 없음 → 안내" "$out" "AGENTS.md 와 CLAUDE.md 가 서로 참조하지 않습니다 — 'cmux bridge --apply $d' 로 연결할 수 있습니다"
t_assert_eq "둘 다·참조 없음 → rc 10" "rc=10" "$(_rc "$d")"
d="$(_mkp ck-li)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "@AGENTS.md" > "$d/CLAUDE.md"
out="$(_cb "$d")"
t_assert_contains "연결됨 → 이유와 함께 안내" "$out" "이미 연결됨 — CLAUDE.md 가 @AGENTS.md 로 AGENTS.md 를 불러옵니다: $d"
t_assert_eq "연결됨 → rc 0" "rc=0" "$(_rc "$d")"
d="$(_mkp ck-none)"
t_assert_contains "둘 다 없음 → 안내" "$(_cb "$d")" "연결할 지침 파일이 없습니다 (AGENTS.md·CLAUDE.md 둘 다 없음)"
t_assert_eq "둘 다 없음 → rc 0" "rc=0" "$(_rc "$d")"
t_assert_eq "없는 디렉토리 → rc 1" "rc=1" "$(_rc "$B1/no-such-dir")"
t_assert_contains "없는 디렉토리 → 메시지" "$(_cb "$B1/no-such-dir")" "디렉토리가 없습니다"
t_assert_eq "알 수 없는 옵션 → rc 1" "rc=1" "$(_rc --force "$d")"
t_assert_eq "경로 둘 → rc 1" "rc=1" "$(_rc "$d" "$B1")"
d="$(_mkp ck-dang)"; ln -s /nonexistent/xyz "$d/AGENTS.md"
t_assert_eq "끊어진 링크 → rc 3 (check)" "rc=3" "$(_rc "$d")"
t_assert_eq "끊어진 링크 → rc 3 (apply)" "rc=3" "$(_rc --apply "$d")"
t_assert_eq "끊어진 링크는 그대로 (CLAUDE.md도 안 만듦)" "ls:AGENTS.md " "$(_snap "$d" | tail -1)"

# ── B4 ────────────────────────────────────────────────
t_scenario B4 "cmux bridge --apply"
# AGENTS.md만 → CLAUDE.md 신규 ( .collar 와 무관 )
d="$(_mkp ap-ao)"; print -r -- "# a" > "$d/AGENTS.md"; sa="$(_sum "$d/AGENTS.md")"
out="$(_cb --apply "$d")"
t_assert_contains "생성 안내" "$out" "CLAUDE.md 생성(@AGENTS.md): $d/CLAUDE.md"
t_assert_eq "rc 0" "rc=0" "$(_rc --apply "$d")"
t_assert_eq "CLAUDE.md = 마커 + 주석 + @AGENTS.md (정확히 3줄)" "$CLAUDE_NEW" "$(cat "$d/CLAUDE.md")"
t_assert_eq "AGENTS.md 바이트 불변" "$sa" "$(_sum "$d/AGENTS.md")"
t_assert_eq "임시파일 잔여 없음" "AGENTS.md CLAUDE.md " "$(ls -A "$d" | tr '\n' ' ')"
sc="$(_sum "$d/CLAUDE.md")"; _cb --apply "$d" >/dev/null
t_assert_eq "멱등: 두 번째 apply 는 변화 없음" "$sc" "$(_sum "$d/CLAUDE.md")"
# CLAUDE.md만 → AGENTS.md 신규
d="$(_mkp ap-co)"; print -r -- "# c" > "$d/CLAUDE.md"; sc="$(_sum "$d/CLAUDE.md")"
out="$(_cb --apply "$d")"
t_assert_contains "생성 안내" "$out" "AGENTS.md 생성(CLAUDE.md 포인터): $d/AGENTS.md"
t_assert_contains "AGENTS.md 에 마커" "$(cat "$d/AGENTS.md")" "<!-- cmux:bridge -->"
t_assert_contains "AGENTS.md 에 CLAUDE.md 를 읽으라는 포인터" "$(cat "$d/AGENTS.md")" "./CLAUDE.md 에 있습니다"
t_assert_eq "CLAUDE.md 바이트 불변" "$sc" "$(_sum "$d/CLAUDE.md")"
sa="$(_sum "$d/AGENTS.md")"; _cb --apply "$d" >/dev/null
t_assert_eq "멱등" "$sa" "$(_sum "$d/AGENTS.md")"
# 둘 다 있고 참조 없음 → 양쪽 끝에 마커 블록. 블록 밖 바이트 불변(원본이 앞부분 그대로)
_prefix_ok() {   # <원본 사본> <새 파일> — 새 파일의 앞 N바이트(N=원본 크기)가 원본과 같은가
  local n; n=$(wc -c < "$1")
  head -c "$n" "$2" | cmp -s - "$1"
}
d="$(_mkp ap-un)"; printf '# a\nline2\n' > "$d/AGENTS.md"; printf '# c\nline2\n' > "$d/CLAUDE.md"
cp "$d/AGENTS.md" "$U_TMP/orig-a"; cp "$d/CLAUDE.md" "$U_TMP/orig-c"
out="$(_cb --apply "$d")"
t_assert_contains "연결 안내" "$out" "연결 블록 추가: CLAUDE.md(@AGENTS.md) · AGENTS.md(CLAUDE.md 포인터)"
t_assert_true "CLAUDE.md: 원본이 그대로 앞부분" '_prefix_ok "$U_TMP/orig-c" "$d/CLAUDE.md"'
t_assert_true "AGENTS.md: 원본이 그대로 앞부분" '_prefix_ok "$U_TMP/orig-a" "$d/AGENTS.md"'
t_assert_eq "CLAUDE.md 끝 = 빈 줄 + 마커 블록(@AGENTS.md) 그리고 end 마커로 끝남" \
  $'# c\nline2\n\n<!-- cmux:bridge begin -->\n<!-- cmux bridge: AGENTS.md 의 지침을 Claude Code에 불러옵니다 -->\n@AGENTS.md\n<!-- cmux:bridge end -->' "$(cat "$d/CLAUDE.md")"
t_assert_eq "AGENTS.md 의 블록 시작·끝 마커" "<!-- cmux:bridge begin -->|<!-- cmux:bridge end -->" \
  "$(grep -n 'cmux:bridge begin' "$d/AGENTS.md" | cut -d: -f2-)|$(tail -1 "$d/AGENTS.md")"
t_assert_contains "AGENTS.md 블록이 CLAUDE.md 를 읽으라고 함" "$(cat "$d/AGENTS.md")" "작업 전에 CLAUDE.md 를 처음부터 끝까지 읽고"
t_assert_eq "블록 뒤에 아무것도 없음 (파일이 end 마커 줄로 끝남)" "<!-- cmux:bridge end -->" "$(tail -1 "$d/CLAUDE.md")"
t_assert_eq "임시파일 잔여 없음" "AGENTS.md CLAUDE.md " "$(ls -A "$d" | tr '\n' ' ')"
sA="$(_sum "$d/AGENTS.md")"; sC="$(_sum "$d/CLAUDE.md")"
mA="$(zstat +mtime "$d/AGENTS.md")"
out="$(_cb --apply "$d")"
t_assert_contains "두 번째 apply → 이미 연결됨" "$out" "이미 연결됨"
t_assert_eq "멱등: 바이트·mtime 불변" "$sA|$sC|$mA" "$(_sum "$d/AGENTS.md")|$(_sum "$d/CLAUDE.md")|$(zstat +mtime "$d/AGENTS.md")"
t_assert_eq "블록 연결 뒤 check → rc 0" "rc=0" "$(_rc --check "$d")"
# 끝 개행 없는 파일 / CRLF / 빈 파일
d="$(_mkp ap-nonl)"; printf '# a no newline' > "$d/AGENTS.md"; printf '# c no newline' > "$d/CLAUDE.md"
cp "$d/AGENTS.md" "$U_TMP/orig-a"; cp "$d/CLAUDE.md" "$U_TMP/orig-c"
_cb --apply "$d" >/dev/null
t_assert_true "끝 개행 없는 CLAUDE.md: 원본 바이트가 앞부분" '_prefix_ok "$U_TMP/orig-c" "$d/CLAUDE.md"'
t_assert_true "끝 개행 없는 AGENTS.md: 원본 바이트가 앞부분" '_prefix_ok "$U_TMP/orig-a" "$d/AGENTS.md"'
t_assert_eq "끝 개행 없음 → 개행 하나 + 빈 줄 + 블록" $'# c no newline\n\n<!-- cmux:bridge begin -->' "$(head -3 "$d/CLAUDE.md")"
d="$(_mkp ap-crlf)"; printf '# a\r\nx\r\n' > "$d/AGENTS.md"; printf '# c\r\ny\r\n' > "$d/CLAUDE.md"
cp "$d/AGENTS.md" "$U_TMP/orig-a"; cp "$d/CLAUDE.md" "$U_TMP/orig-c"
_cb --apply "$d" >/dev/null
t_assert_true "CRLF 원본도 바이트 그대로 앞부분 (CLAUDE.md)" '_prefix_ok "$U_TMP/orig-c" "$d/CLAUDE.md"'
t_assert_true "CRLF 원본도 바이트 그대로 앞부분 (AGENTS.md)" '_prefix_ok "$U_TMP/orig-a" "$d/AGENTS.md"'
d="$(_mkp ap-empty)"; : > "$d/CLAUDE.md"; print -r -- "# a" > "$d/AGENTS.md"
_cb --apply "$d" >/dev/null
t_assert_eq "빈 CLAUDE.md → 빈 줄 없이 블록만" $'<!-- cmux:bridge begin -->\n<!-- cmux bridge: AGENTS.md 의 지침을 Claude Code에 불러옵니다 -->\n@AGENTS.md\n<!-- cmux:bridge end -->' "$(cat "$d/CLAUDE.md")"
# 모드 유지, 경로에 공백
d="$(_mkp 'ap mode')"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"; chmod 600 "$d/AGENTS.md"; chmod 640 "$d/CLAUDE.md"
_cb --apply "$d" >/dev/null
t_assert_eq "원 파일 모드 유지 (600 / 640) — 공백 든 경로" "600 640" "$(stat -f %Lp "$d/AGENTS.md") $(stat -f %Lp "$d/CLAUDE.md")"
t_assert_contains "블록이 실제로 추가됨(공백 경로)" "$(cat "$d/CLAUDE.md")" "<!-- cmux:bridge begin -->"
# .collar 유무와 무관 (apply 는 명시 실행)
d="$(_mkp ap-collar collar)"; print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"
_cb --apply "$d" >/dev/null
t_assert_contains ".collar 있는 프로젝트도 apply 가 연결" "$(cat "$d/CLAUDE.md")" "@AGENTS.md"
# 새로 만든 파일은 git 에 손대지 않는다
d="$(_mkp ap-git)"; git -C "$d" init -q 2>/dev/null; print -r -- "# a" > "$d/AGENTS.md"
_cb --apply "$d" >/dev/null
t_assert_eq "git add/commit 없음: 새 CLAUDE.md 는 untracked, 커밋 0" "?? AGENTS.md|?? CLAUDE.md|0" \
  "$(git -C "$d" status --short | sed -n 1p)|$(git -C "$d" status --short | sed -n 2p)|$(git -C "$d" rev-list --all --count 2>/dev/null || print 0)"

# 쓰기 불가 폴더 — zsh 내부 오류문(_bridge_create:3: permission denied …)이 새지 않고 사용자용 한 줄 오류(rc 1)만
_ro() {   # <이름> <ao|co|un> — 읽기 전용 폴더에서 apply → 출력·rc 확인, 파일 무변경
  local d out s0; d="$(_mkp "$1")"
  case "$2" in
    ao) print -r -- "# a" > "$d/AGENTS.md" ;;
    co) print -r -- "# c" > "$d/CLAUDE.md" ;;
    un) print -r -- "# a" > "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md" ;;
  esac
  s0="$(_snap "$d")"; chmod 555 "$d"
  out="$(_cb --apply "$d")"
  chmod 755 "$d"
  t_assert_eq "[쓰기 불가·$2] 출력은 사용자용 한 줄 + rc 줄 (2줄)" 2 "$(_nlines "$out")"
  t_assert_contains "[쓰기 불가·$2] 사용자용 오류 문구" "$out" "못했습니다: $d"
  t_assert_not_contains "[쓰기 불가·$2] zsh 내부 오류문 없음 (permission denied)" "$out" "permission denied"
  t_assert_not_contains "[쓰기 불가·$2] 함수 이름·줄 번호 노출 없음" "$out" "_bridge_"
  t_assert_eq "[쓰기 불가·$2] rc 1" "rc=1" "$(print -r -- "$out" | tail -1)"
  t_assert_eq "[쓰기 불가·$2] 파일·임시파일 무변경" "$s0" "$(_snap "$d")"
}
_ro ro-ao ao
_ro ro-co co
_ro ro-un un

# ── B5 ────────────────────────────────────────────────
t_scenario B5 "마커 손상 · 심볼릭 링크 → 무변경 + 비0"
_corrupt() {   # <이름> <CLAUDE.md 내용(printf 형식)> [AGENTS.md 내용]
  local d; d="$(_mkp "$1")"
  printf "$2" > "$d/CLAUDE.md"
  printf "${3:-# a\\n}" > "$d/AGENTS.md"
  print -r -- "$d"
}
for spec in "begin만|# c\n<!-- cmux:bridge begin -->\nx\n" "end만|# c\n<!-- cmux:bridge end -->\n" \
            "begin 둘|# c\n<!-- cmux:bridge begin -->\n<!-- cmux:bridge begin -->\nx\n<!-- cmux:bridge end -->\n" \
            "순서 뒤집힘|# c\n<!-- cmux:bridge end -->\nx\n<!-- cmux:bridge begin -->\n"; do
  name="${spec%%|*}"; body="${spec#*|}"
  d="$(_corrupt "mk-${name// /_}" "$body")"; s0="$(_snap "$d")"
  t_assert_eq "CLAUDE.md 마커 손상(${name}) → apply rc 2" "rc=2" "$(_rc --apply "$d")"
  t_assert_eq "CLAUDE.md 마커 손상(${name}) → 무변경(두 파일 해시·목록)" "$s0" "$(_snap "$d")"
  t_assert_eq "CLAUDE.md 마커 손상(${name}) → check 도 rc 2" "rc=2" "$(_rc --check "$d")"
done
d="$(_corrupt mk-agents $'# c\n' $'# a\n<!-- cmux:bridge begin -->\nonly begin\n')"; s0="$(_snap "$d")"
out="$(_cb --apply "$d")"
t_assert_contains "AGENTS.md 마커 손상 → 메시지" "$out" "AGENTS.md 의 cmux:bridge 마커가 깨져 있어 건드리지 않았습니다"
t_assert_eq "AGENTS.md 마커 손상 → rc 2·무변경" "rc=2|$s0" "$(_rc --apply "$d")|$(_snap "$d")"
d="$(_corrupt mk-ok $'# c\n<!-- cmux:bridge begin -->\n@AGENTS.md\n<!-- cmux:bridge end -->\n' $'# a\n')"
t_assert_eq "정상 마커 한 쌍(+ @AGENTS.md) → 연결됨 rc 0" "rc=0" "$(_rc --apply "$d")"
# 심볼릭 링크: 다른 곳을 가리키는 AGENTS.md / CLAUDE.md (둘 다 있고 참조 없음 → 두 파일 모두 쓰지 않는다)
mkdir -p "$U_TMP/elsewhere"; print -r -- "# real agents" > "$U_TMP/elsewhere/real-a.md"; print -r -- "# real claude" > "$U_TMP/elsewhere/real-c.md"
d="$(_mkp ln-a)"; ln -s "$U_TMP/elsewhere/real-a.md" "$d/AGENTS.md"; print -r -- "# c" > "$d/CLAUDE.md"
sr="$(_sum "$U_TMP/elsewhere/real-a.md")"; sc="$(_sum "$d/CLAUDE.md")"
out="$(_cb --apply "$d")"
t_assert_contains "AGENTS.md 심볼릭 링크 → 메시지" "$out" "AGENTS.md 가 심볼릭 링크라 건드리지 않았습니다"
t_assert_eq "AGENTS.md 링크 → rc 3" "rc=3" "$(_rc --apply "$d")"
t_assert_eq "링크 대상·CLAUDE.md 모두 무변경 (CLAUDE.md 에도 블록을 쓰지 않음)" "$sr|$sc|yes" "$(_sum "$U_TMP/elsewhere/real-a.md")|$(_sum "$d/CLAUDE.md")|$([[ -L "$d/AGENTS.md" ]] && print yes || print no)"
d="$(_mkp ln-c)"; print -r -- "# a" > "$d/AGENTS.md"; ln -s "$U_TMP/elsewhere/real-c.md" "$d/CLAUDE.md"
sr="$(_sum "$U_TMP/elsewhere/real-c.md")"; sa="$(_sum "$d/AGENTS.md")"
t_assert_eq "CLAUDE.md 링크 → rc 3" "rc=3" "$(_rc --apply "$d")"
t_assert_eq "링크 대상·AGENTS.md 모두 무변경" "$sr|$sa" "$(_sum "$U_TMP/elsewhere/real-c.md")|$(_sum "$d/AGENTS.md")"
# 한쪽만 있고 그 파일이 심볼릭 링크 — 새 파일 생성은 링크를 따라 쓰지 않으니 안전하다
d="$(_mkp ln-ao)"; ln -s "$U_TMP/elsewhere/real-a.md" "$d/AGENTS.md"; sr="$(_sum "$U_TMP/elsewhere/real-a.md")"
t_assert_eq "AGENTS.md(링크)만 있음 → CLAUDE.md 신규 생성 rc 0" "rc=0" "$(_rc --apply "$d")"
t_assert_eq "링크 대상 무변경" "$sr" "$(_sum "$U_TMP/elsewhere/real-a.md")"
t_assert_contains "새 CLAUDE.md 는 @AGENTS.md" "$(cat "$d/CLAUDE.md")" "@AGENTS.md"

# ── B6 ────────────────────────────────────────────────
t_scenario B6 "_launch_agent 통합 — 연결이 collar-agents-sync 보다 먼저"
LA="$U_TMP/la"
_launch() { (cd "$1" && _launch_agent "$2") 2>/dev/null; }
: > "$FAKE_SYNC_LOG"; : > "$FAKE_AGENT_LOG"
d="$LA/co-collar"; mkdir -p "$d/.collar"; print -r -- "# 규칙 원본" > "$d/CLAUDE.md"
out="$(_launch "$d" codex)"
t_assert_eq "sync 호출 시점에 AGENTS.md 포인터가 이미 있었다 (첫 줄 = cmux 마커)" "$d|first=<!-- cmux:bridge -->" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "최종 AGENTS.md = collar 블록 + 빈 줄 + 포인터" $'<!-- collar:begin v2 -->\nFAKE BLOCK\n<!-- collar:end -->\n\n<!-- cmux:bridge -->' "$(head -5 "$d/AGENTS.md")"
t_assert_contains "포인터 문구가 collar 블록 아래에 그대로" "$(cat "$d/AGENTS.md")" "이 프로젝트의 지침은 ./CLAUDE.md 에 있습니다."
t_assert_eq "안내 줄이 에이전트 배너보다 먼저" "1 2" "$(print -r -- "$out" | strip | grep -n '지침 연결\|▶ Codex' | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "codex 는 그대로 실행됨" "resume --last -a never -s workspace-write" "$(t_agent_args codex "$d")"
# AGENTS.md만 + claude → CLAUDE.md 생성 (claude 에서도 동작), sync 는 안 부름
: > "$FAKE_SYNC_LOG"
d="$LA/ao-claude"; mkdir -p "$d/.collar"; print -r -- "# 규칙 원본" > "$d/AGENTS.md"
out="$(_launch "$d" claude)"
t_assert_eq "claude launch 도 CLAUDE.md(@AGENTS.md) 생성" "$CLAUDE_NEW" "$(cat "$d/CLAUDE.md")"
t_assert_eq "claude 는 sync 를 부르지 않는다 (기존 동작)" "" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "claude 실행됨" "--dangerously-skip-permissions" "$(t_agent_args claude "$d")"
# .collar 없는 프로젝트 → 생성 없이 안내만 + 에이전트 실행 계속
d="$LA/co-nocollar"; mkdir -p "$d"; print -r -- "# c" > "$d/CLAUDE.md"
out="$(_launch "$d" kimi)"
t_assert_true ".collar 없음 → AGENTS.md 생성 없음" '[[ ! -e "$d/AGENTS.md" ]]'
t_assert_contains ".collar 없음 → 안내" "$(print -r -- "$out" | strip)" "'cmux bridge --apply $d' 로 연결할 수 있습니다"
t_assert_eq "안내 뒤에도 kimi 실행" "--yolo --continue" "$(t_agent_args kimi "$d")"
# claude 재현: .collar + CLAUDE.md만 → claude launch 는 AGENTS.md 를 만들지 않는다 (예전엔 만들어서 cmux -k 복원 때 프로젝트마다 untracked AGENTS.md 가 생겼다)
: > "$FAKE_SYNC_LOG"
d="$LA/co-claude"; mkdir -p "$d/.collar"; print -r -- "# 규칙 원본" > "$d/CLAUDE.md"
out="$(_launch "$d" claude)"
t_assert_true "claude + CLAUDE.md만 + .collar → AGENTS.md 생성 없음" '[[ ! -e "$d/AGENTS.md" ]]'
t_assert_eq "CLAUDE.md 그대로" "# 규칙 원본" "$(cat "$d/CLAUDE.md")"
t_assert_eq "claude 는 그대로 실행됨" "--dangerously-skip-permissions" "$(t_agent_args claude "$d")"
t_assert_eq "claude 는 sync 도 안 부름 → AGENTS.md 가 어떤 경로로도 안 생김" "" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "claude + CLAUDE.md만 → 안내도 없음 (claude 는 CLAUDE.md 를 이미 읽는다) — 배너만" "▶ Claude Code: 새로 시작" "$(print -r -- "$out" | strip)"
# 반대 방향: kimi(비-claude) + AGENTS.md만 + .collar → CLAUDE.md 를 만들지 않는다
d="$LA/ao-kimi"; mkdir -p "$d/.collar"; print -r -- "# 규칙 원본" > "$d/AGENTS.md"
out="$(_launch "$d" kimi)"
t_assert_true "kimi + AGENTS.md만 + .collar → CLAUDE.md 생성 없음" '[[ ! -e "$d/CLAUDE.md" ]]'
t_assert_eq "kimi 는 그대로 실행됨" "--yolo --continue" "$(t_agent_args kimi "$d")"
# 쓰기 실패(읽기 전용 폴더)여도 launch 는 계속, 오류 출력 없음 — 에이전트가 필요로 하는 방향(비-claude: CLAUDE.md만 → AGENTS.md / claude: AGENTS.md만 → CLAUDE.md)
d="$LA/ro"; mkdir -p "$d/.collar"; print -r -- "# c" > "$d/CLAUDE.md"; chmod 555 "$d"
out="$( (cd "$d" && _launch_agent opencode) 2>&1 )"
chmod 755 "$d"
t_assert_eq "읽기 전용 폴더 → AGENTS.md 못 만들어도 opencode 실행됨" 1 "$(t_agent_launches opencode "$d")"
t_assert_true "읽기 전용 폴더 → AGENTS.md 없음" '[[ ! -e "$d/AGENTS.md" ]]'
t_assert_not_contains "읽기 전용 폴더 → 오류 출력 없음" "$out" "permission denied"
t_assert_eq "임시파일 잔여 없음" "CLAUDE.md" "$(ls -A "$d" | grep -v '^.collar$' | tr '\n' ' ' | sed 's/ $//')"
d="$LA/ro2"; mkdir -p "$d/.collar"; print -r -- "# a" > "$d/AGENTS.md"; chmod 555 "$d"
out="$( (cd "$d" && _launch_agent claude) 2>&1 )"
chmod 755 "$d"
t_assert_eq "읽기 전용 폴더 → CLAUDE.md 못 만들어도 claude 실행됨" 1 "$(t_agent_launches claude "$d")"
t_assert_not_contains "읽기 전용 폴더(claude) → 오류 출력 없음" "$out" "permission denied"
t_assert_eq "임시파일 잔여 없음" "AGENTS.md" "$(ls -A "$d" | grep -v '^.collar$' | tr '\n' ' ' | sed 's/ $//')"

# ── B7 ────────────────────────────────────────────────
t_scenario B7 "실제 collar-agents-sync 와 공존 (있을 때만)"
if [[ -n "$REAL_SYNC" && -x "$REAL_SYNC" ]] && command -v python3 >/dev/null; then
  d="$(_mkp real-sync collar)"; print -r -- "# 프로젝트 지침" > "$d/CLAUDE.md"
  (cd "$d" && _bridge_launch codex) >/dev/null 2>&1
  "$REAL_SYNC" "$d" >/dev/null 2>&1; rc=$?
  t_assert_eq "실제 sync 가 포인터가 든 AGENTS.md 를 정상 처리 (rc 0)" 0 $rc
  t_assert_eq "AGENTS.md 최상단 = collar 블록" "<!-- collar:begin" "${$(head -1 "$d/AGENTS.md")[1,17]}"
  t_assert_contains "collar 블록 아래에 cmux 포인터가 그대로" "$(cat "$d/AGENTS.md")" $'<!-- collar:end -->\n\n<!-- cmux:bridge -->'
  s1="$(_sum "$d/AGENTS.md")"
  (cd "$d" && _bridge_launch codex) >/dev/null 2>&1; "$REAL_SYNC" "$d" >/dev/null 2>&1
  t_assert_eq "한 번 더 launch 해도 AGENTS.md 불변 (멱등)" "$s1" "$(_sum "$d/AGENTS.md")"
  t_assert_eq "연결 상태 = linked" "linked" "$(_st "$d")"
else
  t_skip "실제 collar-agents-sync 없음"
fi

# ── B8 ────────────────────────────────────────────────
t_scenario B8 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
