#!/usr/bin/env zsh
# t30_picker_unit — cmux-picker 에이전트 선택 로직 단위 테스트 (curses·tty·zellij 없음)
#   bin/cmux-picker를 importlib로 모듈 로드(__main__ 아님 → main() 미실행)해 순수 함수만 호출한다.
#   P0 로드: 구문·import 부작용 없음
#   P1 env 파싱: 에이전트 목록(중복 제거·빈값=claude) / default 보정 / prefs(미등록·형식 오류 무시, 마지막 줄 우선, 없는·못 읽는 파일)
#   P2 유효 에이전트 우선순위: 명시 > 기억(논리·물리 경로) > 선택 기본
#   P3 배지 문자열 / 출력 직렬화(default와 같으면 경로만)
#   P4 키 → 상태 전이(a: 항목 순환, Tab: 선택 기본 순환, 그 외 키·등록 1개면 무변화)
#   P5 새 env 없음 → 구버전과 같은 출력(경로만)
# 대상 교체(뮤테이션 확인 등): CMUX_PICKER_UNDER_TEST=/경로/cmux-picker

# harness.zsh(zellij 세션 로직)는 쓰지 않는다 — 어서션은 이 파일의 최소 정의만
P_NAME="${${0:t}%.zsh}"
P_REPO="${0:A:h:h:h}"
P_PICKER="${${CMUX_PICKER_UNDER_TEST:-$P_REPO/bin/cmux-picker}:A}"
P_PASS=0 P_FAIL=0

P_TMP="$(mktemp -d /tmp/cmuxp.XXXXXX)" || exit 1
P_TMP="${P_TMP:A}"
trap 'chmod -R u+rwx -- "$P_TMP" 2>/dev/null; rm -rf -- "$P_TMP"' EXIT

_p_pass() { (( P_PASS++ )); print -r -- "  PASS  $1"; }
_p_fail() { (( P_FAIL++ )); print -r -- "  FAIL  $1"; [[ -n "$2" ]] && print -r -- "          $2"; return 0; }

print -r -- "대상 picker: $P_PICKER"

# ── P0 구문 ───────────────────────────────────────────
print -r -- "── P0  구문·로드"
if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$P_PICKER" 2>"$P_TMP/ast.err"; then
  _p_pass "python ast 구문"
else
  _p_fail "python ast 구문" "$(cat "$P_TMP/ast.err")"
fi

# ── P0~P5: python이 'SC/PASS/FAIL<TAB>…' 줄을 내고 여기서 집계한다 ──
python3 - "$P_PICKER" "$P_TMP" > "$P_TMP/py.out" 2> "$P_TMP/py.err" <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

picker_path, tmp = sys.argv[1], sys.argv[2]


def sc(sid, desc):
    print(f"SC\t{sid}\t{desc}")


def eq(desc, expected, actual):
    if expected == actual:
        print(f"PASS\t{desc}")
    else:
        print(f"FAIL\t{desc}\t기대: {expected!r} / 실제: {actual!r}")


loader = importlib.machinery.SourceFileLoader("cmux_picker", picker_path)
spec = importlib.util.spec_from_loader("cmux_picker", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
eq("모듈 로드 — 순수 함수·클래스 존재", True, all(hasattr(m, n) for n in (
    "parse_agents", "parse_prefs", "compute_effective_agent", "next_agent",
    "agent_badge", "serialize_selection", "AgentChoice", "KEY_TAB")))

# ── P1 ───────────────────────────────────────────────
sc("P1", "env 파싱 — 에이전트 목록 · default 보정 · prefs")
eq("AGENTS 없음/빈값 → [claude]", (["claude"], ["claude"]), (m.parse_agents(""), m.parse_agents("   ")))
eq("AGENTS 공백 구분·순서 유지", ["claude", "codex", "opencode"], m.parse_agents(" claude  codex opencode "))
eq("AGENTS 중복 제거(첫 위치)", ["codex", "claude"], m.parse_agents("codex claude codex"))

c = m.AgentChoice.from_env({})
eq("env 전혀 없음 → claude 하나·default claude·비활성",
   (["claude"], "claude", "claude", False), (c.agents, c.default, c.base, c.enabled))
c = m.AgentChoice.from_env({"CMUX_PICKER_AGENTS": "claude codex", "CMUX_PICKER_DEFAULT_AGENT": "  "})
eq("DEFAULT 공백 → claude, 2개 → 활성", ("claude", "claude", True), (c.default, c.base, c.enabled))
c = m.AgentChoice.from_env({"CMUX_PICKER_AGENTS": "claude codex opencode", "CMUX_PICKER_DEFAULT_AGENT": "codex"})
eq("DEFAULT=codex(등록됨) → 선택 기본 codex", ("codex", "codex"), (c.default, c.base))
c = m.AgentChoice.from_env({"CMUX_PICKER_AGENTS": "codex opencode", "CMUX_PICKER_DEFAULT_AGENT": "gemini"})
eq("DEFAULT 미등록 → 선택 기본은 목록 첫 항목, 출력 기준 default는 그대로",
   ("gemini", "codex"), (c.default, c.base))

agents = ["claude", "codex", "opencode"]
prefs_file = os.path.join(tmp, "project-agents")
with open(prefs_file, "w", encoding="utf-8") as f:
    f.write("/p/a\tcodex\n"
            "/p/b\tgemini\n"            # 미등록 → 무시
            "탭 없는 줄\n"
            "\n"
            "\topencode\n"              # 경로 없음 → 무시
            "/p/c\topencode\n"
            "/p/c\tcodex\n"             # 같은 경로 → 마지막 줄
            "/p/e\tcodex\n"
            "/p/e\tgemini\n"            # 마지막 줄이 미등록 → 기억 없음
            "/p/f\topencode\r\n")       # CRLF
eq("prefs 파싱 — 미등록·형식 오류 무시, 마지막 줄 우선, CRLF",
   {"/p/a": "codex", "/p/c": "codex", "/p/f": "opencode"}, m.parse_prefs(prefs_file, agents))
eq("prefs 경로 미지정 → {}", {}, m.parse_prefs("", agents))
eq("prefs 파일 없음 → {}", {}, m.parse_prefs(os.path.join(tmp, "없음"), agents))
locked = os.path.join(tmp, "locked")
with open(locked, "w") as f:
    f.write("/p/a\tcodex\n")
os.chmod(locked, 0)
eq("prefs 읽기 권한 없음 → {} (예외 없음)", {}, m.parse_prefs(locked, agents))
with open(os.path.join(tmp, "binary"), "wb") as f:
    f.write(b"/p/a\t\xff\xfe\n")
eq("prefs UTF-8 아님 → {} (예외 없음)", {}, m.parse_prefs(os.path.join(tmp, "binary"), agents))
eq("prefs 파일은 읽기만 (내용 불변)", True, open(prefs_file, encoding="utf-8").read().startswith("/p/a\tcodex\n"))

# ── P2 ───────────────────────────────────────────────
sc("P2", "유효 에이전트 우선순위 — 명시 > 기억 > 선택 기본")
eq("기억 없음 → 선택 기본", "claude", m.compute_effective_agent("/p/z", {}, {}, "claude"))
eq("기억 > 선택 기본", "codex", m.compute_effective_agent("/p/a", {}, {"/p/a": "codex"}, "claude"))
eq("명시 > 기억", "opencode",
   m.compute_effective_agent("/p/a", {"/p/a": "opencode"}, {"/p/a": "codex"}, "claude"))
eq("명시가 선택 기본과 같아도 명시 유지", "claude",
   m.compute_effective_agent("/p/a", {"/p/a": "claude"}, {"/p/a": "codex"}, "opencode"))
real = os.path.join(tmp, "real")
os.makedirs(os.path.join(real, "proj"))
os.symlink(real, os.path.join(tmp, "link"))
eq("기억이 물리 경로로 기록돼도 논리 경로 항목에 적용", "codex",
   m.compute_effective_agent(os.path.join(tmp, "link", "proj"), {},
                             {os.path.realpath(os.path.join(real, "proj")): "codex"}, "claude"))

# ── P3 ───────────────────────────────────────────────
sc("P3", "배지 문자열 · 출력 직렬화")
eq("선택 기본과 다르면 [codex]", "[codex]", m.agent_badge("codex", "claude"))
eq("선택 기본과 같으면 배지 없음", "", m.agent_badge("claude", "claude"))
eq("default와 같으면 경로만, 다르면 경로<TAB>에이전트",
   ["/p/a", "/p/b\tcodex", "/p/c\topencode"],
   m.serialize_selection(["/p/a", "/p/b", "/p/c"],
                         {"/p/a": "claude", "/p/b": "codex", "/p/c": "opencode"}.get, "claude"))
eq("빈 선택(취소) → 빈 출력", [], m.serialize_selection([], lambda p: "claude", "claude"))
c = m.AgentChoice(["claude", "codex"], "codex", {"/p/b": "claude"})
eq("default=codex — codex 항목은 경로만, claude 항목은 경로<TAB>claude",
   ["/p/a", "/p/b\tclaude"], c.output_lines(["/p/a", "/p/b"]))
c = m.AgentChoice(["codex", "opencode"], "gemini", {})
eq("default 미등록 — 선택 기본 항목도 경로<TAB>에이전트(cmux가 default로 오해하지 않게)",
   ["/p/a\tcodex"], c.output_lines(["/p/a"]))

# ── P4 ───────────────────────────────────────────────
sc("P4", "키 → 상태 전이")
eq("KEY_TAB = 9", 9, m.KEY_TAB)
c = m.AgentChoice(["claude", "codex", "opencode"], "claude", {})
c.on_key(ord("a"), "/p/a")
eq("a 1회 → 커서 항목 codex(명시)·배지 [codex]", ("codex", {"/p/a": "codex"}, "[codex]"),
   (c.effective("/p/a"), c.explicit, c.badge("/p/a")))
eq("a는 커서 항목만 바꾼다", ("claude", ""), (c.effective("/p/b"), c.badge("/p/b")))
c.on_key(ord("a"), "/p/a")
c.on_key(ord("a"), "/p/a")
eq("a 3회 → 한 바퀴 돌아 claude(명시로 남음)·배지 없음", ("claude", {"/p/a": "claude"}, ""),
   (c.effective("/p/a"), c.explicit, c.badge("/p/a")))
c.on_key(m.KEY_TAB, "/p/a")
eq("Tab → 선택 기본 codex: 명시 없는 항목은 codex·배지 없음", ("codex", "codex", ""),
   (c.base, c.effective("/p/b"), c.badge("/p/b")))
eq("Tab 후 명시 claude 항목은 배지 [claude]", ("claude", "[claude]"), (c.effective("/p/a"), c.badge("/p/a")))
c.on_key(ord("a"), "/p/b")
eq("선택 기본 codex에서 a → opencode", "opencode", c.effective("/p/b"))
c.on_key(m.KEY_TAB, "/p/a")
c.on_key(m.KEY_TAB, "/p/a")
eq("Tab 3회 → 선택 기본이 한 바퀴 돌아 claude", "claude", c.base)
before = (c.base, dict(c.explicit))
for k in (ord("h"), ord("j"), ord("k"), ord("l"), ord("q"), ord(" "), 10, 13, 27, -1, ord("A")):
    c.on_key(k, "/p/c")
eq("그 외 키(hjklq·Space·Enter·Esc·대문자 A 등) → 무변화", before, (c.base, c.explicit))
c = m.AgentChoice(["claude", "codex", "opencode"], "claude", {"/p/a": "opencode"})
c.on_key(ord("a"), "/p/a")
eq("기억 opencode 항목에서 a → 다음 claude(명시)", ("claude", {"/p/a": "claude"}),
   (c.effective("/p/a"), c.explicit))
eq("기억값 표시: opencode 항목 배지 [opencode]", "[opencode]",
   m.AgentChoice(["claude", "codex", "opencode"], "claude", {"/p/a": "opencode"}).badge("/p/a"))
c = m.AgentChoice(["claude"], "claude", {})
c.on_key(ord("a"), "/p/a")
c.on_key(m.KEY_TAB, "/p/a")
eq("등록 1개 → a·Tab 무시", ("claude", {}, "claude"), (c.base, c.explicit, c.effective("/p/a")))
eq("next_agent: 목록에 없는 현재값 → 첫 항목", "claude", m.next_agent(["claude", "codex"], "gemini"))

sc("PERF", "탐색 중 파일시스템 재조회 없음 · 기억 없음도 캐시 · Tab/a 동작 유지")
from unittest.mock import patch
with patch.object(m.os.path, "realpath", wraps=os.path.realpath) as resolve:
    c = m.AgentChoice(["claude", "codex"], "claude", {})
    c.badge("/p/no-prefs")
    eq("기억 파일이 비었으면 realpath 호출 없음", 0, resolve.call_count)
linked = os.path.join(tmp, "link", "proj")
with patch.object(m.os.path, "realpath", wraps=os.path.realpath) as resolve:
    c = m.AgentChoice(["claude", "codex"], "claude", {os.path.join(real, "proj"): "codex"})
    for _ in range(5):
        c.badge(linked)
        c.badge("/p/no-memory")
    eq("여러 번 그려도 물리 경로 조회는 항목당 1회", 2, resolve.call_count)
    c.on_key(m.KEY_TAB, "/p/no-memory")
    eq("기억 없음 캐시는 Tab으로 바뀐 기본값을 따른다", "codex", c.effective("/p/no-memory"))
    c.on_key(ord("a"), linked)
    eq("명시 변경은 캐시된 기억보다 우선", "claude", c.effective(linked))
    eq("Tab/a/출력 확인에도 경로 재조회 없음", 2, resolve.call_count)

# ── P5 ───────────────────────────────────────────────
sc("P5", "새 env 없음 → 구버전과 같은 출력")
c = m.AgentChoice.from_env({})
eq("env 없음 → 경로만", ["/x/a", "/x/b"], c.output_lines(["/x/a", "/x/b"]))
with open(os.path.join(tmp, "prefs-only"), "w", encoding="utf-8") as f:
    f.write("/x/a\tcodex\n")
c = m.AgentChoice.from_env({"CMUX_PICKER_PREFS_FILE": os.path.join(tmp, "prefs-only")})
eq("prefs만 있고 AGENTS 없음 → 미등록 codex 무시, 경로만", ["/x/a"], c.output_lines(["/x/a"]))
PY
py_rc=$?

while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    SC)   print -r -- "── $a  $b" ;;
    PASS) _p_pass "$a" ;;
    FAIL) _p_fail "$a" "$b" ;;
    *)    print -r -- "  (출력) $kind${a:+	$a}${b:+	$b}" ;;
  esac
done < "$P_TMP/py.out"
if (( py_rc != 0 )); then
  _p_fail "python 단위 테스트 실행 (rc=$py_rc)" "$(tail -5 "$P_TMP/py.err")"
fi

print -r -- ""
print -r -- "RESULT $P_NAME pass=$P_PASS fail=$P_FAIL skip=0"
(( P_FAIL == 0 ))
