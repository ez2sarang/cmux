#!/usr/bin/env zsh
# t03_adapters — codex·opencode 어댑터 + 핸드오프 마커 + collar-agents-sync 단위 테스트
#   (CMUX_SOURCE_ONLY=1 source, zellij·실제 에이전트 없음 — 가짜 에이전트·가짜 홈만)
#   A1 등록·훅 기본값 (label·default_perm·fastfail·last_activity)
#   A2 bin 탐색 우선순위 (_ag_search_bin / codex / opencode — 가짜 홈·PATH)
#   A3 권한 프로파일 (CMUX_<A>_PERM 오버라이드·기본값·잘못된 값) + perm_args
#   A4 인자 조립 compose (codex 서브커맨드 뒤 권한 인자 / claude·opencode 기본 순서)
#   A5 opencode has_history·last_activity (가짜 'session list' JSON: 디렉토리 일치·불일치·논리/물리·대소문자 차이(samefile)·
#      updated 최대·빈 목록·깨진 JSON·시간 초과·python3 없음)
#   A6 codex last_activity·has_history (rollout 첫 줄 session_meta: cwd(대소문자 차이 포함)·source·최신 40개 창·CODEX_HOME)
#   A7 claude last_activity·has_history 배너 설명 (sdk-cli 제외, 논리·물리 키를 합쳐 최신순, 세션 폴더 대소문자 차이)
#   A8 마커 판정 _handoff_marker_due (TTL·유예 경계 ±1초, 에이전트 불일치, 깨진 파일)
#   A9 마커 소비 _handoff_marker_consume (원자적 mv, 두 번째는 일반 경로, mv 실패, 동시 소비 경합)
#   A10 _collar_agents_sync (.collar·PATH 조건, 인자, 출력 버림, exit 2/3 경고, 2초 타임박스)
#   A11 _launch_agent — codex·opencode·claude 인자·배너·마커·fastfail·sync 호출
#   A12 (PATH의 가짜 zellij로) 실제 zellij 호출 0

source "${0:A:h}/../lib/harness.zsh"   # 어서션 함수만 사용

U_TMP="$(mktemp -d /tmp/cmuxu.XXXXXX)" || exit 1
U_TMP="${U_TMP:A}"
trap 'chmod -R u+rwx -- "$U_TMP" 2>/dev/null; rm -rf -- "$U_TMP"' EXIT

# 격리: 홈·탭 기록·세션명·claude/codex 설정. PATH 맨 앞의 가짜 zellij·collar-agents-sync는 호출을 기록만 한다
mkdir -p "$U_TMP"/{home,bin,zdotdir,emptybin}
export HOME="$U_TMP/home" ZDOTDIR="$U_TMP/zdotdir"
export CMUX_SESSION="cmuxu$$" CMUX_TABS_FILE="$U_TMP/cfg/session-tabs"
export CLAUDE_CONFIG_DIR="$U_TMP/claude-config"
unset CODEX_HOME CMUX_CLAUDE_PERM CMUX_CODEX_PERM CMUX_OPENCODE_PERM CMUX_HANDOFF_GRACE
print -r -- $'#!/bin/sh\necho "$*" >> "'"$U_TMP"$'/zellij-calls"\nexit 1' > "$U_TMP/bin/zellij"
# 가짜 collar-agents-sync: "PWD|인자" 기록, stdout·stderr에 한 줄씩(버려지는지 확인), FAKE_SYNC_SLEEP·FAKE_SYNC_RC
cat > "$U_TMP/bin/collar-agents-sync" <<'SH'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" >> "${FAKE_SYNC_LOG:-/dev/null}"
echo SYNC-STDOUT
echo SYNC-STDERR >&2
[ -n "$FAKE_SYNC_SLEEP" ] && exec sleep "$FAKE_SYNC_SLEEP"
exit "${FAKE_SYNC_RC:-0}"
SH
chmod +x "$U_TMP/bin/zellij" "$U_TMP/bin/collar-agents-sync"
export PATH="$U_TMP/bin:$PATH"
export FAKE_SYNC_LOG="$U_TMP/sync.log"
for a in claude codex opencode; do ln -s "$T_REPO/tests/bin/fake-agent" "$U_TMP/bin/fake-$a"; done
export CMUX_CLAUDE_BIN="$U_TMP/bin/fake-claude" CMUX_CODEX_BIN="$U_TMP/bin/fake-codex" CMUX_OPENCODE_BIN="$U_TMP/bin/fake-opencode"
export FAKE_AGENT_LOG="$U_TMP/fake.log" FAKE_AGENT_SLEEP=0
: > "$FAKE_AGENT_LOG"
export CMUX_SOURCE_ONLY=1

CMUX_SOURCE_ONLY=1 source "$CMUX_UNDER_TEST" || { print -u2 "source 실패: $CMUX_UNDER_TEST"; exit 1; }

# ── 공용 도우미 ───────────────────────────────────────
# _set_mtime <파일> <epoch 초>
_set_mtime() { local t; strftime -s t '%Y%m%d%H%M.%S' "$2"; touch -t "$t" "$1"; }
# PATH에서 collar-agents-sync가 있는 디렉토리를 뺀 값 (실제 collar 설치본도 제외)
_path_without_sync() {
  local -a p=()
  local e
  for e in "${path[@]}"; do [[ -x "$e/collar-agents-sync" ]] || p+=("$e"); done
  print -r -- "${(j.:.)p}"
}
# 임시 루트가 대소문자 무시 볼륨(APFS 기본)인가 — 대소문자 차이 회귀 테스트의 전제
mkdir -p "$U_TMP/CaseProbe"
[[ -d "$U_TMP/caseprobe" ]] && U_CI=1 || U_CI=0
rmdir "$U_TMP/CaseProbe"
# 끊긴 프로세스 확인용 sleep 값은 이 실행만의 고유값(초.<PID>) — 동시에 도는 다른 테스트 실행의
# 같은 명령줄을 세지 않게. 종료 확인은 상한 있는 폴링(t_assert_true … 3초)으로 한다
U_LIST_SLEEP="30.$$" U_SYNC_SLEEP="5.$$"
# _sleep_procs <초 값> — 명령줄이 정확히 "sleep <값>"인 프로세스 수
_sleep_procs() { ps -axo command= | grep -cxF "sleep $1"; }
NOW=$EPOCHSECONDS
SAFE="-a never -s workspace-write"
BYPASS="--dangerously-bypass-approvals-and-sandbox"
PERM="--dangerously-skip-permissions"

# ── A1 ────────────────────────────────────────────────
t_scenario A1 "등록·훅 기본값"
t_assert_eq "등록 에이전트" "claude codex opencode kimi" "${CMUX_AGENTS[*]}"
t_assert_eq "_agent_known codex/opencode/gemini" "0 0 1" \
  "$(_agent_known codex; print -n "$? "; _agent_known opencode; print -n "$? "; _agent_known gemini; print -n $?)"
_r() { _agent_call "$1" "$2"; print -r -- "$REPLY"; }
t_assert_eq "label" "Claude Code|Codex|OpenCode|Kimi Code" "$(_r claude label)|$(_r codex label)|$(_r opencode label)|$(_r kimi label)"
t_assert_eq "default_perm (claude=auto, codex=safe, opencode=auto, kimi=safe)" "auto|safe|auto|safe" \
  "$(_r claude default_perm)|$(_r codex default_perm)|$(_r opencode default_perm)|$(_r kimi default_perm)"
t_assert_eq "fastfail 5초" "5|5|5|5" "$(_r claude fastfail)|$(_r codex fastfail)|$(_r opencode fastfail)|$(_r kimi fastfail)"
REPLY=x; _agent_call zzz last_activity /nowhere
t_assert_eq "미등록 기본 last_activity = 0" 0 "$REPLY"

# ── A2 ────────────────────────────────────────────────
t_scenario A2 "bin 탐색 우선순위"
B="$U_TMP/bins"
mkdir -p "$B"/{dir,pathbin}
print -r -- '#!/bin/sh' > "$B/exe1"; print -r -- '#!/bin/sh' > "$B/exe2"; print -r -- 'x' > "$B/noexec"
chmod +x "$B/exe1" "$B/exe2" "$B/dir"
print -r -- '#!/bin/sh' > "$B/pathbin/zzz"; chmod +x "$B/pathbin/zzz"
CMUX_ZZZ_BIN=/env/zzz _ag_search_bin zzz "$B/exe1"
t_assert_eq "_ag_search_bin: env가 최우선" "/env/zzz" "$REPLY"
_ag_search_bin zzz "$B/none" "$B/dir" "$B/noexec" "$B/exe2" "$B/exe1"
t_assert_eq "_ag_search_bin: 없음·디렉토리·실행 불가 건너뛰고 첫 실행 파일" "$B/exe2" "$REPLY"
PATH="$B/pathbin:$PATH" _ag_search_bin zzz "$B/none"
t_assert_eq "_ag_search_bin: 후보 없으면 PATH" "$B/pathbin/zzz" "$REPLY"
_ag_search_bin zzz "$B/none"
t_assert_eq "_ag_search_bin: 어디에도 없으면 비0" 1 $?

# 가짜 홈의 nvm(두 버전)·bun — 실행 파일은 실제 nvm처럼 lib 쪽을 가리키는 심볼릭 링크
_mkexe() { mkdir -p "${1:h}"; print -r -- '#!/bin/sh' > "$1"; chmod +x "$1"; }
for a in codex opencode; do
  _mkexe "$HOME/.nvm/versions/node/v1/lib/$a.js"; _mkexe "$HOME/.nvm/versions/node/v2/lib/$a.js"
  mkdir -p "$HOME/.nvm/versions/node/v1/bin" "$HOME/.nvm/versions/node/v2/bin"
  ln -s "../lib/$a.js" "$HOME/.nvm/versions/node/v1/bin/$a"
  ln -s "../lib/$a.js" "$HOME/.nvm/versions/node/v2/bin/$a"
  _set_mtime "$HOME/.nvm/versions/node/v1/lib/$a.js" $(( NOW - 100 ))
  _set_mtime "$HOME/.nvm/versions/node/v2/lib/$a.js" $(( NOW - 50 ))
  _mkexe "$HOME/.bun/bin/$a"
  _mkexe "$B/pathbin/$a"
done
NVM="$HOME/.nvm/versions/node"

CMUX_CODEX_BIN=/custom/codex _agent_call codex bin
t_assert_eq "codex: CMUX_CODEX_BIN 최우선" "/custom/codex" "$REPLY"
if [[ -x /opt/homebrew/bin/codex ]]; then
  CMUX_CODEX_BIN= _agent_call codex bin
  t_assert_eq "codex: 비어 있으면 brew (nvm·bun보다 앞)" "/opt/homebrew/bin/codex" "$REPLY"
  t_skip "codex /usr/local·nvm·bun·PATH 폴백 — 이 머신은 brew codex가 있어 도달 불가 (같은 메커니즘은 opencode·_ag_search_bin에서 검증)"
elif [[ -x /usr/local/bin/codex ]]; then
  CMUX_CODEX_BIN= _agent_call codex bin
  t_assert_eq "codex: 비어 있으면 /usr/local" "/usr/local/bin/codex" "$REPLY"
  t_skip "codex nvm·bun·PATH 폴백 — /usr/local/bin/codex가 있어 도달 불가"
else
  CMUX_CODEX_BIN= _agent_call codex bin
  t_assert_eq "codex: brew 없으면 nvm 중 가장 최근 mtime (v2)" "$NVM/v2/bin/codex" "$REPLY"
  _set_mtime "$NVM/v1/lib/codex.js" $(( NOW - 10 ))
  CMUX_CODEX_BIN= _agent_call codex bin
  t_assert_eq "codex: 버전 이름이 아니라 mtime (v1이 더 최근)" "$NVM/v1/bin/codex" "$REPLY"
  mv "$NVM" "$U_TMP/nvm-off"
  CMUX_CODEX_BIN= _agent_call codex bin
  t_assert_eq "codex: nvm 없으면 bun" "$HOME/.bun/bin/codex" "$REPLY"
  mv "$HOME/.bun/bin/codex" "$U_TMP/bun-codex-off"
  CMUX_CODEX_BIN= PATH="$B/pathbin:$PATH" _agent_call codex bin
  t_assert_eq "codex: 그다음 PATH" "$B/pathbin/codex" "$REPLY"
  mv "$U_TMP/nvm-off" "$NVM"; mv "$U_TMP/bun-codex-off" "$HOME/.bun/bin/codex"
fi

CMUX_OPENCODE_BIN=/custom/opencode _agent_call opencode bin
t_assert_eq "opencode: CMUX_OPENCODE_BIN 최우선" "/custom/opencode" "$REPLY"
CMUX_OPENCODE_BIN= _agent_call opencode bin
t_assert_eq "opencode: nvm 중 가장 최근 mtime (v2, 심볼릭 링크 대상 기준)" "$NVM/v2/bin/opencode" "$REPLY"
_set_mtime "$NVM/v1/lib/opencode.js" $(( NOW - 10 ))
CMUX_OPENCODE_BIN= _agent_call opencode bin
t_assert_eq "opencode: 버전 이름이 아니라 mtime (v1이 더 최근)" "$NVM/v1/bin/opencode" "$REPLY"
mv "$NVM" "$U_TMP/nvm-off"
CMUX_OPENCODE_BIN= _agent_call opencode bin
t_assert_eq "opencode: nvm 없으면 bun" "$HOME/.bun/bin/opencode" "$REPLY"
mv "$HOME/.bun/bin/opencode" "$U_TMP/bun-opencode-off"
if [[ -x /opt/homebrew/bin/opencode || -x /usr/local/bin/opencode ]]; then
  t_skip "opencode brew·/usr/local·PATH 폴백 — 이 머신에 설치돼 있어 PATH 단계 도달 불가"
else
  CMUX_OPENCODE_BIN= PATH="$B/pathbin:$PATH" _agent_call opencode bin
  t_assert_eq "opencode: brew·/usr/local 없으면 PATH" "$B/pathbin/opencode" "$REPLY"
  CMUX_OPENCODE_BIN= PATH="$U_TMP/emptybin" _agent_call opencode bin
  t_assert_eq "opencode: 어디에도 없으면 비0" 1 $?
fi
mv "$U_TMP/nvm-off" "$NVM"; mv "$U_TMP/bun-opencode-off" "$HOME/.bun/bin/opencode"

# ── A3 ────────────────────────────────────────────────
t_scenario A3 "권한 프로파일 — env 오버라이드·기본값·잘못된 값"
_prof() { _agent_perm_profile "$1" >/dev/null; print -r -- "$REPLY"; }
t_assert_eq "claude 기본 auto / CMUX_CLAUDE_PERM=safe" "auto safe" "$(_prof claude) $(CMUX_CLAUDE_PERM=safe _prof claude)"
t_assert_eq "codex 기본 safe / auto / safe" "safe auto safe" \
  "$(_prof codex) $(CMUX_CODEX_PERM=auto _prof codex) $(CMUX_CODEX_PERM=safe _prof codex)"
t_assert_eq "opencode 기본 auto / CMUX_OPENCODE_PERM=safe" "auto safe" "$(_prof opencode) $(CMUX_OPENCODE_PERM=safe _prof opencode)"
t_assert_eq "빈 값 → 기본값" "safe" "$(CMUX_CODEX_PERM= _prof codex)"
out="$(CMUX_CODEX_PERM=yolo _agent_perm_profile codex; print -r -- "REPLY=$REPLY")"
t_assert_contains "잘못된 값 → 경고 1줄" "$out" "CMUX_CODEX_PERM='yolo' — auto|safe 가 아니라 기본값(safe)을 씁니다"
t_assert_contains "잘못된 값 → 기본값" "$out" "REPLY=safe"
t_assert_eq "잘못된 값 경고는 1줄" 2 "${#${(f)out}}"
out="$(CMUX_CLAUDE_PERM=AUTO _agent_perm_profile claude; print -r -- "REPLY=$REPLY")"
t_assert_contains "대문자 AUTO도 잘못된 값 → claude 기본 auto" "$out" $'기본값(auto)을 씁니다\nREPLY=auto'
_pa() { _agent_call "$1" perm_args "$2"; print -r -- "${#reply}:${reply[*]}"; }
t_assert_eq "codex perm_args auto" "1:$BYPASS" "$(_pa codex auto)"
t_assert_eq "codex perm_args safe" "4:$SAFE" "$(_pa codex safe)"
t_assert_eq "opencode perm_args auto/safe → 없음" "0:|0:" "$(_pa opencode auto)|$(_pa opencode safe)"

# ── A4 ────────────────────────────────────────────────
t_scenario A4 "인자 조립 compose"
# _cmp <에이전트> <resume|fresh> <프로파일> → "개수:인자"
_cmp() { _agent_call "$1" perm_args "$3"; _agent_call "$1" compose "$2" "${reply[@]}"; print -r -- "${#reply}:${reply[*]}"; }
t_assert_eq "codex resume × auto → 서브커맨드 뒤 권한 인자" "3:resume --last $BYPASS" "$(_cmp codex resume auto)"
t_assert_eq "codex resume × safe" "6:resume --last $SAFE" "$(_cmp codex resume safe)"
t_assert_eq "codex fresh × auto → 권한 인자만" "1:$BYPASS" "$(_cmp codex fresh auto)"
t_assert_eq "codex fresh × safe" "4:$SAFE" "$(_cmp codex fresh safe)"
t_assert_eq "claude resume × auto → 권한 인자 뒤 --continue (현행 순서)" "2:$PERM --continue" "$(_cmp claude resume auto)"
t_assert_eq "claude resume × safe" "1:--continue" "$(_cmp claude resume safe)"
t_assert_eq "claude fresh × auto" "1:$PERM" "$(_cmp claude fresh auto)"
_ag_opencode_sid="ses_abc"
t_assert_eq "opencode resume → -s <id>" "2:-s ses_abc" "$(_cmp opencode resume auto)"
t_assert_eq "opencode fresh → 없음" "0:" "$(_cmp opencode fresh safe)"
_ag_opencode_sid=""
_agent_call zzz compose resume --p1 --p2
t_assert_eq "기본 compose = 권한 인자 + resume_args(없음)" "2:--p1 --p2" "${#reply}:${reply[*]}"

# ── A5 ────────────────────────────────────────────────
t_scenario A5 "opencode has_history·last_activity — 가짜 session list"
OC="$U_TMP/oc"
mkdir -p "$OC"/{a,b,c}
ln -s "$OC" "$U_TMP/oclink"
export FAKE_OPENCODE_LIST="$U_TMP/oclist.json"
_oce() { print -r -- "{\"id\":\"$1\",\"title\":\"t\",\"directory\":\"$2\",\"projectId\":\"p\",\"created\":1,\"updated\":$3}"; }
_oclist() { print -r -- "[${(j:,:)@}]" > "$FAKE_OPENCODE_LIST"; }
# _ohh <디렉토리> → "rc|REPLY|sid|updated" (REPLY는 성공일 때만 의미가 있다 — 실패면 빈 칸으로)
_ohh() {
  local rc
  _ag_opencode_has_history "$1"; rc=$?
  (( rc )) && REPLY=""
  print -r -- "$rc|$REPLY|$_ag_opencode_sid|$_ag_opencode_updated"
}
_ola() { REPLY=x; _ag_opencode_last_activity "$1"; print -r -- "$REPLY"; }

_oclist "$(_oce ses_a1 "$OC/a" 1790000000000)"
t_assert_eq "directory 일치 → 그 id" "0|ses_a1|ses_a1|1790000000" "$(_ohh "$OC/a")"
t_assert_eq "목록 조회 인자·cwd" "fake-opencode-list	$OC/a	--pure session list --format json -n 1000" \
  "$(grep '^fake-opencode-list' "$FAKE_AGENT_LOG" | tail -1)"
t_assert_eq "목록 조회는 에이전트 실행으로 기록되지 않음" 0 "$(t_agent_launches opencode "$OC/a")"
t_assert_eq "directory 불일치(같은 프로젝트의 다른 폴더) → 없음" "1|||0" "$(_ohh "$OC/b")"
_oclist "$(_oce ses_old "$OC/a" 1790000000000)" "$(_oce ses_other "$OC/b" 1799999999999)" \
  "$(_oce ses_new "$OC/a" 1790000500999)" "$(_oce ses_mid "$OC/a" 1790000300000)"
t_assert_eq "같은 directory 중 updated 최대 (다른 폴더의 더 큰 값은 무시)" "0|ses_new|ses_new|1790000500" "$(_ohh "$OC/a")"
t_assert_eq "last_activity = updated(ms)/1000 내림" 1790000500 "$(_ola "$OC/a")"
t_assert_eq "last_activity 없음 → 0" 0 "$(_ola "$OC/c")"
_oclist "$(_oce ses_phys "$OC/a" 1790000000000)"
t_assert_eq "논리 경로(심볼릭 링크)로 물어도 물리 경로 기록 → 있음" "0|ses_phys|ses_phys|1790000000" "$(_ohh "$U_TMP/oclink/a")"
_oclist "$(_oce ses_logi "$U_TMP/oclink/a" 1790000000000)"
t_assert_eq "논리 경로 기록 + 논리 경로로 물음 → 있음" "0|ses_logi|ses_logi|1790000000" "$(_ohh "$U_TMP/oclink/a")"
t_assert_eq "논리 경로 기록 + 물리 경로로 물음 → 같은 폴더(samefile) → 있음" "0|ses_logi|ses_logi|1790000000" "$(_ohh "$OC/a")"
# 기록된 directory의 대소문자가 실제 폴더 이름과 다름 (대소문자 무시 볼륨에서 같은 폴더)
mkdir -p "$OC/caseproj" "$OC/other/caseproj"
if (( U_CI )); then
  _oclist "$(_oce ses_case "$OC/CaseProj" 1790000000000)"
  t_assert_eq "대소문자만 다른 directory 기록 → 같은 폴더 → 있음" "0|ses_case|ses_case|1790000000" "$(_ohh "$OC/caseproj")"
  _oclist "$(_oce ses_exact "$OC/caseproj" 1790000000000)" "$(_oce ses_case "$OC/CASEPROJ" 1790000100000)"
  t_assert_eq "정확 일치·대소문자 차이 기록이 섞이면 같은 폴더 중 updated 최대" "0|ses_case|ses_case|1790000100" "$(_ohh "$OC/caseproj")"
else
  t_skip "대소문자 차이 directory — 임시 루트가 대소문자 구분 볼륨"
  t_skip "대소문자 차이 + 정확 일치 혼합"
fi
_oclist "$(_oce ses_twin "$OC/other/CaseProj" 1799999999999)" "$(_oce ses_near "$OC/CaseProjX" 1799999999999)"
t_assert_eq "이름이 같아도 다른 폴더(samefile 거짓)·이름이 다른 기록 → 없음" "1|||0" "$(_ohh "$OC/caseproj")"
_oclist "$(_oce ses_gone "$OC/gone/CaseProj" 1799999999999)"
t_assert_eq "없는 경로 기록 → 없음 (오류 없이)" "1|||0" "$(_ohh "$OC/caseproj")"
_oclist
t_assert_eq "빈 목록 → 없음" "1|||0" "$(_ohh "$OC/a")"
print -r -- '[{"id":"ses_x","directory":' > "$FAKE_OPENCODE_LIST"
t_assert_eq "깨진 JSON → 없음" "1|||0" "$(_ohh "$OC/a")"
print -r -- '{"id":"ses_x","directory":"'"$OC/a"'","updated":1}' > "$FAKE_OPENCODE_LIST"
t_assert_eq "리스트가 아닌 JSON → 없음" "1|||0" "$(_ohh "$OC/a")"
print -r -- "[{\"directory\":\"$OC/a\",\"updated\":5},{\"id\":\"\",\"directory\":\"$OC/a\",\"updated\":6},{\"id\":\"ses_s\",\"directory\":\"$OC/a\",\"updated\":\"7\"},$(_oce ses_ok "$OC/a" 1000)]" > "$FAKE_OPENCODE_LIST"
t_assert_eq "id 없음·빈 id·updated 문자열 항목은 건너뜀" "0|ses_ok|ses_ok|1" "$(_ohh "$OC/a")"
t_assert_eq "판정 중 stderr 출력 없음" "" "$(_ag_opencode_has_history "$OC/a" 2>&1 >/dev/null; print -r -- '[' > "$FAKE_OPENCODE_LIST"; _ag_opencode_has_history "$OC/a" 2>&1 >/dev/null)"
( unset FAKE_OPENCODE_LIST; _ohh "$OC/a" ) > "$U_TMP/ohh.out"
t_assert_eq "조회 출력 없음 → 없음" "1|||0" "$(cat "$U_TMP/ohh.out")"
# 앞선 성공 결과(sid)가 남아 있어도 다음 판정이 실패하면 비운다
_oclist "$(_oce ses_a1 "$OC/a" 1790000000000)"
_ag_opencode_has_history "$OC/a"; _ag_opencode_has_history "$OC/b"
t_assert_eq "실패한 판정은 이전 sid를 비움" "|0" "$_ag_opencode_sid|$_ag_opencode_updated"
# python3 없음 → 조회 자체를 하지 않는다
n0="$(grep -c '^fake-opencode-list' "$FAKE_AGENT_LOG")"
t_assert_eq "python3 없음 → 없음" "1|||0" "$(PATH="$U_TMP/emptybin" _ohh "$OC/a")"
t_assert_eq "python3 없음 → 목록 조회 안 함" "$n0" "$(grep -c '^fake-opencode-list' "$FAKE_AGENT_LOG")"
t_assert_eq "python3 없음 → last_activity 0" 0 "$(PATH="$U_TMP/emptybin" _ola "$OC/a")"
t_assert_eq "opencode 실행 파일 없음 → 없음" "1|||0" "$(CMUX_OPENCODE_BIN="$U_TMP/emptybin/nope" _ohh "$OC/a")"
# 시간 초과: 조회가 끝나지 않으면 8초에 끊고 없음 (조회 프로세스도 종료)
t0=$EPOCHREALTIME
res="$(FAKE_OPENCODE_LIST_SLEEP=$U_LIST_SLEEP _ohh "$OC/a")"
el=$(( EPOCHREALTIME - t0 ))
t_assert_eq "시간 초과 → 없음" "1|||0" "$res"
t_assert_true "시간 초과 → 8초 근처에서 끊음 (실측 ${el%.*}초)" '(( el >= 7.5 && el < 11 ))'
t_assert_true "시간 초과 → 조회 프로세스 종료" '(( $(_sleep_procs $U_LIST_SLEEP) == 0 ))' 3

# ── A6 ────────────────────────────────────────────────
t_scenario A6 "codex last_activity·has_history — rollout session_meta"
CX="$U_TMP/cx"
mkdir -p "$CX"/{a,b,c}
ln -s "$CX" "$U_TMP/cxlink"
SESS="$HOME/.codex/sessions"
# _rollout <파일 이름> <cwd> <source> <mtime epoch> — 첫 줄에 session_meta, 긴 base_instructions 안에 가짜 "cwd" 텍스트
_rollout() {
  local f="$SESS/2026/10/01/rollout-$1.jsonl"
  mkdir -p "${f:h}"
  print -r -l -- "{\"timestamp\":\"t\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$1\",\"base_instructions\":{\"text\":\"예: \\\"cwd\\\": \\\"/fake\\\"\"},\"cwd\":\"$2\",\"originator\":\"codex-tui\",\"source\":\"$3\"}}" \
    '{"type":"response_item","payload":{}}' > "$f"
  _set_mtime "$f" "$4"
}
_cla() { REPLY=x; _ag_codex_last_activity "$1"; print -r -- "$REPLY"; }
t_assert_eq "sessions 폴더 없음 → 0" 0 "$(_cla "$CX/a")"
_rollout r1 "$CX/a" cli $(( NOW - 1000 ))
t_assert_eq "cwd 일치 cli → 그 mtime" $(( NOW - 1000 )) "$(_cla "$CX/a")"
_rollout r2 "$CX/a" exec $(( NOW - 500 ))
t_assert_eq "더 최신 exec 세션은 제외 → cli mtime" $(( NOW - 1000 )) "$(_cla "$CX/a")"
_rollout r3 "$CX/b" cli $(( NOW - 400 ))
t_assert_eq "다른 cwd의 더 최신 세션은 무시" $(( NOW - 1000 )) "$(_cla "$CX/a")"
_rollout r4 "$CX/a" vscode $(( NOW - 300 ))
t_assert_eq "vscode 세션도 대화형 → 그 mtime" $(( NOW - 300 )) "$(_cla "$CX/a")"
mkdir -p "$SESS/2026/10/01"
print -r -- 'not json' > "$SESS/2026/10/01/rollout-broken.jsonl"; _set_mtime "$SESS/2026/10/01/rollout-broken.jsonl" $(( NOW - 200 ))
print -r -- "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"$CX/a\",\"source\":\"cli\"}}" > "$SESS/2026/10/01/rollout-notmeta.jsonl"
_set_mtime "$SESS/2026/10/01/rollout-notmeta.jsonl" $(( NOW - 150 ))
t_assert_eq "깨진 첫 줄·session_meta 아닌 첫 줄은 건너뜀" $(( NOW - 300 )) "$(_cla "$CX/a")"
t_assert_eq "논리 경로로 물어도 물리 cwd 기록 → 일치" $(( NOW - 300 )) "$(_cla "$U_TMP/cxlink/a")"
t_assert_eq "판정 중 stderr 출력 없음" "" "$(_ag_codex_last_activity "$CX/a" 2>&1 >/dev/null)"
t_assert_eq "python3 없음 → 0" 0 "$(PATH="$U_TMP/emptybin" _cla "$CX/a")"
# cwd 기록의 대소문자가 실제 폴더 이름과 다름 / 이름은 같지만 다른 폴더
mkdir -p "$CX/caseproj" "$CX/other/caseproj"
_rollout r6 "$CX/other/caseproj" cli $(( NOW - 240 ))
t_assert_eq "이름(caseproj)만 같은 다른 폴더의 기록 → 0" 0 "$(_cla "$CX/caseproj")"
if (( U_CI )); then
  _rollout r5 "$CX/CaseProj" cli $(( NOW - 250 ))
  t_assert_eq "대소문자만 다른 cwd 기록 → 같은 폴더 → 그 mtime (이름만 같은 다른 폴더의 더 최신 기록은 무시)" \
    $(( NOW - 250 )) "$(_cla "$CX/caseproj")"
else
  t_skip "대소문자 차이 cwd — 임시 루트가 대소문자 구분 볼륨"
fi
# has_history: 프로브 없이 항상 0 (native resume --last), REPLY = 마지막 활동 시각 또는 안내
strftime -s want '%m-%d %H:%M' $(( NOW - 300 ))
REPLY=""; _agent_call codex has_history "$CX/a"
t_assert_eq "codex has_history → 0, REPLY = 마지막 활동 시각" "0|$want" "$?|$REPLY"
REPLY=""; _agent_call codex has_history "$U_TMP/emptybin"
t_assert_eq "codex 이력 없어도 has_history → 0 (codex가 새 대화로 시작)" "0|이력이 없으면 새 대화" "$?|$REPLY"
# 최신 40개 창: c의 오래된 세션보다 최신인 무관 세션이 39개면 보고(40번째), 40개면 안 본다
rm -rf -- "$SESS"
_rollout c-old "$CX/c" cli $(( NOW - 5000 ))
for i in {1..39}; do _rollout "n$i" "$CX/b" cli $(( NOW - 4000 + i )); done
t_assert_eq "최신 40개 안(39번째 뒤) → 찾음" $(( NOW - 5000 )) "$(_cla "$CX/c")"
_rollout n40 "$CX/b" cli $(( NOW - 3000 ))
t_assert_eq "최신 40개 밖 → 0" 0 "$(_cla "$CX/c")"
# CODEX_HOME 우선
mkdir -p "$U_TMP/codexhome"
( SESS="$U_TMP/codexhome/sessions"; _rollout h1 "$CX/c" cli $(( NOW - 60 )) )
t_assert_eq "CODEX_HOME이 있으면 그 아래 sessions" $(( NOW - 60 )) "$(CODEX_HOME="$U_TMP/codexhome" _cla "$CX/c")"
t_assert_eq "CODEX_HOME이 없으면 ~/.codex (40개 밖 → 0)" 0 "$(_cla "$CX/c")"
rm -rf -- "$HOME/.codex"

# ── A7 ────────────────────────────────────────────────
t_scenario A7 "claude last_activity·has_history 배너 설명"
CL="$U_TMP/cl"
mkdir -p "$CL"/{a,sdk,none} "$U_TMP/clreal"/{x,y}
ln -s "$U_TMP/clreal" "$U_TMP/cllink"
# _tr <프로젝트 경로> <파일 이름> <entrypoint> <mtime epoch>
_tr() {
  local d="$CLAUDE_CONFIG_DIR/projects/${1//[^A-Za-z0-9]/-}"
  mkdir -p "$d"
  print -r -l -- '{"type":"queue-operation"}' "{\"type\":\"user\",\"entrypoint\":\"$3\"}" > "$d/$2.jsonl"
  _set_mtime "$d/$2.jsonl" "$4"
}
_lla() { REPLY=x; _ag_claude_last_activity "$1"; print -r -- "$REPLY"; }
_tr "$CL/a" old cli $(( NOW - 900 )); _tr "$CL/a" cur cli $(( NOW - 700 )); _tr "$CL/a" sum sdk-cli $(( NOW - 100 ))
t_assert_eq "가장 최근 대화형(cli) 세션 mtime — 더 최신 sdk-cli는 제외" $(( NOW - 700 )) "$(_lla "$CL/a")"
strftime -s want '%m-%d %H:%M' $(( NOW - 700 ))
REPLY=""; _ag_claude_has_history "$CL/a"
t_assert_eq "has_history → 0, REPLY = 그 세션의 마지막 활동 시각" "0|$want" "$?|$REPLY"
_tr "$CL/sdk" s sdk-cli $(( NOW - 100 ))
t_assert_eq "sdk-cli만 → 0" 0 "$(_lla "$CL/sdk")"
t_assert_eq "이력 없음 → 0" 0 "$(_lla "$CL/none")"
# 논리·물리 경로 키를 합쳐 최신순: 더 최신 쪽이 어느 키에 있든 그것
_tr "$U_TMP/cllink/x" logi cli $(( NOW - 50 )); _tr "$U_TMP/clreal/x" phys cli $(( NOW - 80 ))
t_assert_eq "논리 키 쪽이 더 최신 → 그 mtime" $(( NOW - 50 )) "$(_lla "$U_TMP/cllink/x")"
_tr "$U_TMP/cllink/y" logi cli $(( NOW - 80 )); _tr "$U_TMP/clreal/y" phys cli $(( NOW - 50 ))
t_assert_eq "물리 키 쪽이 더 최신 → 그 mtime" $(( NOW - 50 )) "$(_lla "$U_TMP/cllink/y")"
_tr "$U_TMP/cllink/y" logi2 sdk-cli $(( NOW - 10 ))
t_assert_eq "합친 목록에서도 sdk-cli 제외" $(( NOW - 50 )) "$(_lla "$U_TMP/cllink/y")"
# 두 폴더가 시각상 엇갈림 — 논리: cli -60·sdk -20 / 물리: cli -40·sdk -30 → 합친 최신순으로 물리의 -40
# (폴더를 차례로 보면 논리 폴더의 cli -60을 먼저 고른다)
mkdir -p "$U_TMP/clreal/z"
_tr "$U_TMP/cllink/z" lc cli $(( NOW - 60 )); _tr "$U_TMP/cllink/z" ls sdk-cli $(( NOW - 20 ))
_tr "$U_TMP/clreal/z" pc cli $(( NOW - 40 )); _tr "$U_TMP/clreal/z" ps sdk-cli $(( NOW - 30 ))
t_assert_eq "두 키 폴더의 파일을 합쳐 최신순 (엇갈린 시각)" $(( NOW - 40 )) "$(_lla "$U_TMP/cllink/z")"
# 회귀(2026-10-01 실데이터 totalviewer): 세션 폴더 이름의 대소문자가 cwd 키와 다름 —
# 대소문자 무시 볼륨에서는 claude가 그 폴더를 쓰므로 이력이 있다
mkdir -p "$CL/casedir" "$CL/casesdk"
if (( U_CI )); then
  _tr "$CL/CaseDir" s1 cli $(( NOW - 600 ))                 # 세션 폴더 …-CaseDir, 프로젝트 폴더 casedir
  t_assert_eq "세션 폴더 대소문자가 키와 다름 → 이력 있음" $(( NOW - 600 )) "$(_lla "$CL/casedir")"
  REPLY=""; _ag_claude_has_history "$CL/casedir"
  t_assert_eq "세션 폴더 대소문자가 키와 다름 → has_history 0" 0 $?
  _tr "$CL/CaseSdk" s1 sdk-cli $(( NOW - 600 ))
  t_assert_eq "대소문자 다른 세션 폴더에 sdk-cli만 → 0 (스캔은 그대로)" 0 "$(_lla "$CL/casesdk")"
else
  t_skip "세션 폴더 대소문자 차이 — 임시 루트가 대소문자 구분 볼륨"
fi

# ── A8 ────────────────────────────────────────────────
t_scenario A8 "마커 판정 _handoff_marker_due — TTL·유예 경계, 에이전트 불일치, 깨진 파일"
MD="$U_TMP/md"
mkdir -p "$MD/.collar"
N=1790000000
# 판정용 가짜 에이전트 stub: last_activity = STUB_LA, 물어본 디렉토리를 기록
_ag_stub_last_activity() { print -r -- "$1" > "$U_TMP/stub-la-arg"; REPLY=$STUB_LA; }
# _due <마커 내용(print -r -- 그대로)> <last_activity> [에이전트=stub] → yes/no
_due() {
  print -rn -- "$1" > "$MD/.collar/restart-fresh"
  STUB_LA="$2"
  _handoff_marker_due "${3:-stub}" "$MD" $N && print yes || print no
}
_mk() { print -r -- "agent=${1}"$'\n'"handoff=HANDOFF-2026-10-01.md"$'\n'"ts=${2}"; }   # <agent> <ts> (끝 줄바꿈 없음)
t_assert_eq "agent 일치·방금·활동 없음 → 소비" yes "$(_due "$(_mk stub $N)"$'\n' 0)"
t_assert_eq "last_activity는 그 디렉토리로 묻는다" "$MD" "$(cat "$U_TMP/stub-la-arg")"
t_assert_eq "TTL: 정확히 48시간(172800초) 전 → 소비" yes "$(_due "$(_mk stub $(( N - 172800 )))" 0)"
t_assert_eq "TTL: 48시간 + 1초 전 → 무시" no "$(_due "$(_mk stub $(( N - 172801 )))" 0)"
t_assert_eq "유예: 활동 = ts + 300 → 소비" yes "$(_due "$(_mk stub $(( N - 1000 )))" $(( N - 700 )))"
t_assert_eq "유예: 활동 = ts + 301 → 무시 (핸드오프 뒤 대화를 이어감)" no "$(_due "$(_mk stub $(( N - 1000 )))" $(( N - 699 )))"
t_assert_eq "유예: 활동이 ts보다 앞섬 → 소비" yes "$(_due "$(_mk stub $(( N - 1000 )))" $(( N - 5000 )))"
t_assert_eq "CMUX_HANDOFF_GRACE=10: ts + 10 → 소비" yes "$(CMUX_HANDOFF_GRACE=10 _due "$(_mk stub $N)" $(( N + 10 )))"
t_assert_eq "CMUX_HANDOFF_GRACE=10: ts + 11 → 무시" no "$(CMUX_HANDOFF_GRACE=10 _due "$(_mk stub $N)" $(( N + 11 )))"
t_assert_eq "CMUX_HANDOFF_GRACE=0: ts → 소비, ts + 1 → 무시" "yes no" \
  "$(CMUX_HANDOFF_GRACE=0 _due "$(_mk stub $N)" $N) $(CMUX_HANDOFF_GRACE=0 _due "$(_mk stub $N)" $(( N + 1 )))"
t_assert_eq "CMUX_HANDOFF_GRACE=abc → 기본 300 (ts+300 소비, ts+301 무시)" "yes no" \
  "$(CMUX_HANDOFF_GRACE=abc _due "$(_mk stub $N)" $(( N + 300 ))) $(CMUX_HANDOFF_GRACE=abc _due "$(_mk stub $N)" $(( N + 301 )))"
t_assert_eq "에이전트 불일치(agent=claude) → 무시" no "$(_due "$(_mk claude $N)" 0)"
t_assert_eq "에이전트 이름 접두어 일치(agent=stubx) → 무시" no "$(_due "$(_mk stubx $N)" 0)"
t_assert_eq "빈 파일 → 무시" no "$(_due "" 0)"
t_assert_eq "ts 없음 → 무시" no "$(_due "agent=stub" 0)"
t_assert_eq "ts 숫자 아님 → 무시" no "$(_due $'agent=stub\nts=12a' 0)"
t_assert_eq "ts 빈 값 → 무시" no "$(_due $'agent=stub\nts=' 0)"
t_assert_eq "agent 없음 → 무시" no "$(_due "ts=$N" 0)"
t_assert_eq "'agent = stub'(공백) → 무시" no "$(_due "agent = stub"$'\n'"ts=$N" 0)"
t_assert_eq "CRLF 줄끝 → 무시" no "$(_due "agent=stub"$'\r\n'"ts=$N"$'\r\n' 0)"
t_assert_eq "한 줄에 모두(구분자 공백) → 무시" no "$(_due "agent=stub handoff=- ts=$N" 0)"
t_assert_eq "키 순서 바뀜·모르는 줄 섞임 → 소비" yes "$(_due "ts=$N"$'\nfoo=bar\n\nhandoff=-\n'"agent=stub" 0)"
t_assert_eq "미래 ts(시계 차) → 소비" yes "$(_due "$(_mk stub $(( N + 100 )))" 0)"
rm -f -- "$MD/.collar/restart-fresh"; mkdir "$MD/.collar/restart-fresh"
t_assert_eq "마커가 디렉토리 → 무시" no "$(_handoff_marker_due stub "$MD" $N && print yes || print no)"
rmdir "$MD/.collar/restart-fresh"
t_assert_eq "마커 없음 → 무시" no "$(_handoff_marker_due stub "$MD" $N && print yes || print no)"
t_assert_eq ".collar 없음 → 무시" no "$(_handoff_marker_due stub "$U_TMP/emptybin" $N && print yes || print no)"
t_assert_eq "판정은 마커를 건드리지 않음 (읽기만)" "$(_mk stub $N)" "$(_due "$(_mk stub $N)" 0 >/dev/null; cat "$MD/.collar/restart-fresh")"

# ── A9 ────────────────────────────────────────────────
t_scenario A9 "마커 소비 _handoff_marker_consume — 원자적 mv · 경합"
MC="$U_TMP/mc"
mkdir -p "$MC/.collar"
_marker() { _mk "${1:-claude}" "${2:-$EPOCHSECONDS}" > "$MC/.collar/restart-fresh"; }   # 이력 없는 claude → 활동 0
_consumed() { print -l -- "$MC"/.collar/.restart-fresh.consumed-*(N) | grep -c .; }
_marker claude
content="$(cat "$MC/.collar/restart-fresh")"
( cd "$MC" && _handoff_marker_consume claude ); rc=$?
t_assert_eq "일치 → 소비 rc 0" 0 $rc
t_assert_true "마커 사라짐" '[[ ! -e "$MC/.collar/restart-fresh" ]]'
cf=("$MC"/.collar/.restart-fresh.consumed-<->(N))
t_assert_eq "consumed-<epoch> 1개로 보존 (내용 그대로)" "1|$content" "${#cf}|$(cat "${cf[1]}" 2>/dev/null)"
t_assert_true "consumed 이름의 epoch = 소비 시각(±5초)" '(( ${${cf[1]:t}#.restart-fresh.consumed-} >= NOW && ${${cf[1]:t}#.restart-fresh.consumed-} <= EPOCHSECONDS + 5 ))'
( cd "$MC" && _handoff_marker_consume claude )
t_assert_eq "두 번째 → 마커 없음 rc 1" 1 $?
_marker codex
( cd "$MC" && _handoff_marker_consume claude )
t_assert_eq "다른 에이전트 마커 → rc 1" 1 $?
t_assert_eq "다른 에이전트 마커는 그대로" "agent=codex" "$(head -1 "$MC/.collar/restart-fresh")"
( cd "$MC" && _handoff_marker_consume codex )
t_assert_eq "그 에이전트(codex)는 소비" 0 $?
# mv 실패(=다른 pane이 이미 소비) → 마커 없음과 같다
_marker claude
chmod 555 "$MC/.collar"
( cd "$MC" && _handoff_marker_consume claude ) 2> "$U_TMP/mv.err"
rc=$?
chmod 755 "$MC/.collar"
t_assert_eq "mv 실패 → rc 1 (일반 경로)" 1 $rc
t_assert_eq "mv 실패 → stderr 출력 없음" "" "$(cat "$U_TMP/mv.err")"
t_assert_true "mv 실패 → 마커는 그대로" '[[ -f "$MC/.collar/restart-fresh" ]]'
# 동시 소비 경합: 8개 pane이 같은 마커를 동시에 소비 → 정확히 1개만 성공
rm -f -- "$MC"/.collar/.restart-fresh.consumed-*(N)
_marker claude
for i in {1..8}; do ( cd "$MC" && _handoff_marker_consume claude; print -r -- $? > "$U_TMP/race.$i" ) & done
wait
t_assert_eq "동시 8개 → 성공(rc 0) 정확히 1개" 1 "$(cat "$U_TMP"/race.* | grep -cx 0)"
t_assert_eq "동시 8개 → consumed 파일 1개·마커 없음" "1|no" "$(_consumed)|$([[ -e "$MC/.collar/restart-fresh" ]] && print yes || print no)"

# ── A10 ───────────────────────────────────────────────
t_scenario A10 "_collar_agents_sync — 조건·인자·출력·경고·2초 타임박스"
SY="$U_TMP/sy"
mkdir -p "$SY/with/.collar" "$SY/without"
_sync() { ( cd "$1" && _collar_agents_sync 2>&1; print -r -- "rc=$?" ); }
: > "$FAKE_SYNC_LOG"
t_assert_eq ".collar 없음 → 호출 안 함" "rc=0" "$(_sync "$SY/without")"
t_assert_eq ".collar 없음 → 기록 없음" "" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "PATH에 없음 → 조용히 통과" "rc=0" "$(PATH="$(_path_without_sync)" _sync "$SY/with")"
t_assert_eq "PATH에 없음 → 호출 없음" "" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "성공 → 출력 없음 (stdout·stderr 버림)" "rc=0" "$(_sync "$SY/with")"
t_assert_eq "인자 = 프로젝트 폴더, cwd도 그 폴더" "$SY/with|$SY/with" "$(cat "$FAKE_SYNC_LOG")"
t_assert_eq "exit 1 → 조용히 통과" "rc=0" "$(FAKE_SYNC_RC=1 _sync "$SY/with")"
out="$(FAKE_SYNC_RC=2 _sync "$SY/with")"
t_assert_contains "exit 2 → 경고 1줄" "$out" "AGENTS.md의 collar 블록 마커가 깨져 갱신하지 않았습니다 (collar-agents-sync exit 2)"
t_assert_eq "exit 2 → 경고 1줄 + rc 0" 2 "${#${(f)out}}"
out="$(FAKE_SYNC_RC=3 _sync "$SY/with")"
t_assert_contains "exit 3 → 경고 1줄" "$out" "AGENTS.md가 심볼릭 링크라 collar 블록을 갱신하지 않았습니다 (collar-agents-sync exit 3)"
t0=$EPOCHREALTIME
out="$(FAKE_SYNC_SLEEP=$U_SYNC_SLEEP _sync "$SY/with")"
el=$(( EPOCHREALTIME - t0 ))
t_assert_eq "5초 걸리는 sync → 조용히 통과" "rc=0" "$out"
t_assert_true "타임박스 2초(+α) 뒤 진행 (실측 ${el:0:4}초)" '(( el >= 1.9 && el < 3.5 ))'
t_assert_true "타임박스 → sync 프로세스 종료" '(( $(_sleep_procs $U_SYNC_SLEEP) == 0 ))' 3

# ── A11 ───────────────────────────────────────────────
t_scenario A11 "_launch_agent — 인자 · 배너 · 마커 · fastfail · sync"
LA="$U_TMP/la"
mkdir -p "$LA"/{cx,cxm/.collar,ocy,ocn,ocbad,cl/.collar}
: > "$FAKE_AGENT_LOG"; : > "$FAKE_SYNC_LOG"
# _launch <디렉토리> <에이전트> — 서브셸, stdout만(배너) 받는다
_launch() { (cd "$1" && _launch_agent "$2") 2>/dev/null; }
GRAY=$'\e[90m'
out="$(_launch "$LA/cx" codex)"
t_assert_eq "codex 기본(safe) → resume --last + safe 인자" "resume --last $SAFE" "$(t_agent_args codex "$LA/cx")"
t_assert_eq "codex 배너 (stdout, 회색)" "${GRAY}▶ Codex: 이전 대화 이어서 시작 [이력이 없으면 새 대화]"$'\e[0m' "$out"
CMUX_CODEX_PERM=auto _launch "$LA/cx" codex >/dev/null
t_assert_eq "CMUX_CODEX_PERM=auto → bypass" "resume --last $BYPASS" "$(t_agent_args codex "$LA/cx" | tail -1)"
: > "$FAKE_AGENT_LOG"
FAKE_AGENT_FAIL_ON=resume _launch "$LA/cx" codex >/dev/null
t_assert_eq "codex resume 즉시 실패 → 새 대화(권한 인자만) 1회" "resume --last $SAFE"$'\n'"$SAFE" "$(t_agent_args codex "$LA/cx")"
t_assert_eq "sync: .collar 없는 폴더 → 호출 없음" "" "$(cat "$FAKE_SYNC_LOG")"

_oclist "$(_oce ses_y "$LA/ocy" 1790000000000)" "$(_oce ses_gone "$LA/ocbad" 1790000000000)"
out="$(_launch "$LA/ocy" opencode)"
t_assert_eq "opencode 이력 → -s <id>" "-s ses_y" "$(t_agent_args opencode "$LA/ocy")"
t_assert_contains "opencode 배너 [id]" "$out" "▶ OpenCode: 이전 대화 이어서 시작 [ses_y]"
out="$(_launch "$LA/ocn" opencode)"
t_assert_eq "opencode 이력 없음 → 인자 없음" "" "$(t_agent_args opencode "$LA/ocn")"
t_assert_eq "opencode 이력 없음 → 실행 1회" 1 "$(t_agent_launches opencode "$LA/ocn")"
t_assert_contains "opencode 새로 시작 배너" "$out" "▶ OpenCode: 새로 시작"
FAKE_AGENT_FAIL_ON=ses_gone _launch "$LA/ocbad" opencode >/dev/null
t_assert_eq "없는 id → -s 즉시 실패 → 플래그 없이 1회 (총 2회)" "[-s ses_gone]"$'\n'"[]" "$(t_agent_args opencode "$LA/ocbad" | sed 's/^/[/;s/$/]/')"

# claude: cli 이력이 있어도 일치 마커(방금) → 새로 시작 + 소비, 다음 launch는 이어하기
_tr "$LA/cl" a cli $(( EPOCHSECONDS - 10 ))
_mk claude $EPOCHSECONDS > "$LA/cl/.collar/restart-fresh"
out="$(_launch "$LA/cl" claude)"
t_assert_eq "claude 마커 → --continue 없이" "$PERM" "$(t_agent_args claude "$LA/cl")"
t_assert_contains "핸드오프 배너" "$out" "▶ Claude Code: 핸드오프 직후 — 새로 시작"
t_assert_true "마커 소비됨" '[[ ! -e "$LA/cl/.collar/restart-fresh" && -n "$(print -l "$LA"/cl/.collar/.restart-fresh.consumed-*(N))" ]]'
out="$(_launch "$LA/cl" claude)"
t_assert_eq "두 번째 launch → 이어하기" "$PERM --continue" "$(t_agent_args claude "$LA/cl" | tail -1)"
t_assert_contains "이어하기 배너 [시각]" "$out" "▶ Claude Code: 이전 대화 이어서 시작 ["
t_assert_eq "claude는 .collar가 있어도 sync 호출 없음" "" "$(cat "$FAKE_SYNC_LOG")"
# claude: 유예 초과(핸드오프 뒤 대화) → 마커 무시하고 이어하기
_mk claude $(( EPOCHSECONDS - 1000 )) > "$LA/cl/.collar/restart-fresh"
_launch "$LA/cl" claude >/dev/null
t_assert_eq "유예 초과 → 이어하기" "$PERM --continue" "$(t_agent_args claude "$LA/cl" | tail -1)"
t_assert_true "유예 초과 → 마커 그대로" '[[ -f "$LA/cl/.collar/restart-fresh" ]]'

# codex: 일치 마커 → resume 없이 권한 인자만, sync는 마커 판정 전에 1회
_mk codex $EPOCHSECONDS > "$LA/cxm/.collar/restart-fresh"
out="$(_launch "$LA/cxm" codex)"
t_assert_eq "codex 마커 → resume 없이" "$SAFE" "$(t_agent_args codex "$LA/cxm")"
t_assert_contains "codex 핸드오프 배너" "$out" "▶ Codex: 핸드오프 직후 — 새로 시작"
t_assert_eq "codex는 .collar 폴더면 sync 1회 (인자 = 폴더)" "$LA/cxm|$LA/cxm" "$(cat "$FAKE_SYNC_LOG")"
_mk claude $EPOCHSECONDS > "$LA/cxm/.collar/restart-fresh"
_launch "$LA/cxm" codex >/dev/null
t_assert_eq "다른 에이전트(claude) 마커 → codex는 이어하기" "resume --last $SAFE" "$(t_agent_args codex "$LA/cxm" | tail -1)"
t_assert_eq "다른 에이전트 마커는 그대로" "agent=claude" "$(head -1 "$LA/cxm/.collar/restart-fresh")"
t_assert_eq "배너는 stderr로 가지 않음" "" "$( (cd "$LA/ocn" && _launch_agent opencode) 2>&1 >/dev/null)"

# ── A12 ───────────────────────────────────────────────
t_scenario A12 "실제 zellij 호출 없음"
t_assert_true "가짜 zellij 기록 없음" '[[ ! -e "$U_TMP/zellij-calls" ]]'

t_summary
exit $?
