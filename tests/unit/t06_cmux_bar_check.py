#!/usr/bin/env python3
"""t06_cmux_bar_check — bin/cmux-bar 순수 함수 단위 시험 (zsh 래퍼 t06_cmux_bar.zsh가 `python3 -I`로 실행).

사용: python3 -I t06_cmux_bar_check.py <bin/cmux-bar 경로> <임시 디렉터리> [이전 cmux-bar 경로(레거시 비교용)]
출력(탭 구분): SCENARIO\t<ID>\t<설명> / PASS\t<설명> / FAIL\t<설명>\t<상세>
zellij를 실제로 부르지 않는다(가짜 fetch). 동시성은 리더 선출 경합 1회(프로세스 6개)만 본다 — 부하 시험 아님.
"""
import curses
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time

BAR_PATH, TMP = sys.argv[1], sys.argv[2]
OLD_BAR_PATH = sys.argv[3] if len(sys.argv) > 3 else ""


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


bar = load(BAR_PATH, "cmux_bar_under_test")
curses.color_pair = lambda n: n << 8          # initscr/start_color 없이 속성 값만 만든다 (신·구 모듈 공용)

# 안전장치: 이 시험은 실제 zellij를 절대 부르지 않는다. ZELLIJ* env가 없어도 세션이 하나뿐이면 `zellij action`이 그 세션
# (사용자 라이브 세션일 수 있음)을 겨냥하므로, 가짜로 바꾸지 않은 경로가 zellij를 부르면 막고 기록한다 (끝에서 0건 단언).
REAL_ZELLIJ = []
_sp_run, _sp_popen = subprocess.run, subprocess.Popen


def _is_zellij(cmd):
    return isinstance(cmd, (list, tuple)) and bool(cmd) and os.path.basename(str(cmd[0])) == "zellij"


def _guard_run(cmd, *a, **kw):
    if _is_zellij(cmd):
        REAL_ZELLIJ.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 1, b"", b"")
    return _sp_run(cmd, *a, **kw)


def _guard_popen(cmd, *a, **kw):
    if _is_zellij(cmd):
        REAL_ZELLIJ.append(list(cmd))
        cmd = ["/usr/bin/false"]
    return _sp_popen(cmd, *a, **kw)


subprocess.run, subprocess.Popen = _guard_run, _guard_popen


def scenario(sid, desc):
    print("SCENARIO\t%s\t%s" % (sid, desc))


def check(desc, ok, detail=""):
    if ok:
        print("PASS\t%s" % desc)
    else:
        print("FAIL\t%s\t%s" % (desc, detail.replace("\n", "\\n")))


def eq(desc, want, got):
    check(desc, want == got, "기대: %r\n실제: %r" % (want, got))


def raises_nothing(desc, fn):
    try:
        fn()
    except Exception as e:  # noqa: BLE001 — 어떤 예외든 실패
        check(desc, False, "예외: %s: %s" % (type(e).__name__, e))
        return None
    check(desc, True)
    return True


def tab(name, active=False, tid=0, bell=False):
    return {"name": name, "active": active, "id": tid, "bell": bell}


# ── 가짜 화면 ─────────────────────────────────────────────────────────────

class FakeScr:
    """curses stdscr 흉내: 호출 기록 + 셀 격자(2칸 글자는 다음 칸이 ''). 마지막 줄 끝 칸 쓰기는 실제처럼 오류(글자는 써짐)."""

    def __init__(self, h, w):
        self.h, self.w = h, w
        self.calls = []
        self.grid = [[" "] * w for _ in range(h)]

    def getmaxyx(self):
        return (self.h, self.w)

    def erase(self):
        self.calls.append(("erase",))
        self.grid = [[" "] * self.w for _ in range(self.h)]

    def refresh(self):
        self.calls.append(("refresh",))

    def addstr(self, y, x, text, attr=0):
        self.calls.append(("addstr", y, x, text, attr))
        if y < 0 or y >= self.h or x < 0 or x >= self.w:
            raise curses.error("out of range")
        cx = x
        for ch in text:
            cw = bar.char_width(ch)
            if cw == 0:
                continue
            if cx + cw > self.w:
                raise curses.error("overflow")
            self.grid[y][cx] = ch
            if cw == 2:
                self.grid[y][cx + 1] = ""
            cx += cw
        if y == self.h - 1 and cx >= self.w:
            raise curses.error("bottom-right")

    def line(self, y):
        return "".join(self.grid[y])

    def cells(self, y, x0, x1):
        return "".join(self.grid[y][x0:x1 + 1])


def mk_tabs(names, active=None, bells=()):
    return [tab(n, i == active, 100 + i, i in bells) for i, n in enumerate(names)]


NAMES28 = ["proj-alpha-%02d" % i for i in range(28)]
MIXED28 = [("한글프로젝트이름-%02d" % i) if i % 3 == 0 else ("project-alpha-long-name-%02d" % i) if i % 3 == 1 else "p%d" % i
           for i in range(28)]


def widths_of(tabs):
    return [bar.str_width(bar.tab_label(t)) for t in tabs]


# ── W: 폭·이름·라벨 ────────────────────────────────────────────────────────
scenario("W", "폭 계산 · 14칸 자르기 · 라벨 · 탭 목록 정규화")
eq("ASCII 1칸", [1, 1], [bar.char_width("a"), bar.char_width("*")])
eq("한글 2칸", 2, bar.char_width("한"))
eq("전각 영문 2칸", 2, bar.char_width("Ａ"))
eq("반각 가타카나 1칸", 1, bar.char_width("ｱ"))
eq("이모지 2칸", 2, bar.char_width("🚀"))
eq("결합문자(U+0301)·ZWJ·변형선택자 0칸", [0, 0, 0], [bar.char_width("́"), bar.char_width("‍"), bar.char_width("️")])
eq("한글a = 5칸", 5, bar.str_width("한글a"))
eq("e+결합문자 = 1칸", 1, bar.str_width("é"))
eq("14칸 이하는 그대로 (ASCII 14)", "a" * 14, bar.truncate_name("a" * 14))
eq("한글 7자(14칸)는 그대로", "가" * 7, bar.truncate_name("가" * 7))
eq("ASCII 15칸 → 13자 + …", "a" * 13 + "…", bar.truncate_name("a" * 15))
eq("한글 8자 → 6자 + … (13칸, 2칸 글자를 반으로 자르지 않는다)", "가" * 6 + "…", bar.truncate_name("가" * 8))
eq("한글 섞임: 가a가a… 14칸 초과 시 …로 끝", True, bar.truncate_name("가a" * 8).endswith("…") and bar.str_width(bar.truncate_name("가a" * 8)) <= 14)
eq("결합문자 20개도 14칸 이하", True, bar.str_width(bar.truncate_name("é" * 20)) <= 14)
eq("빈 이름", "", bar.truncate_name(""))
eq("사용자 지정 최대 폭", "abc…", bar.truncate_name("abcdefgh", 4))
eq("라벨: 앞뒤 공백 1칸", " alpha ", bar.tab_label(tab("alpha")))
eq("라벨: 벨 알림은 이름 뒤 *", " alpha* ", bar.tab_label(tab("alpha", bell=True)))
eq("라벨: 긴 이름은 14칸 + 앞뒤 공백", 16, bar.str_width(bar.tab_label(tab("x" * 40))))
eq("라벨: 긴 이름 + 벨 = 17칸", 17, bar.str_width(bar.tab_label(tab("x" * 40, bell=True))))
eq("라벨: 한글 이름 폭", 6, bar.str_width(bar.tab_label(tab("한글"))))
norm = bar.normalize_tabs([
    {"position": 2, "name": "c", "active": False, "tab_id": 7, "has_bell_notification": True},
    {"position": 0, "name": "a\nb", "active": True, "tab_id": 3},
    {"position": 1, "name": 5, "tab_id": "x"},
    "junk", None,
])
eq("정규화: position 순·제어문자 공백·형식 이상은 기본값·비dict 무시",
   [("a b", True, 3, False), ("", False, None, False), ("c", False, 7, True)],
   [(t["name"], t["active"], t["id"], t["bell"]) for t in norm])
eq("정규화: 목록이 아니면 빈 목록", [[], [], []], [bar.normalize_tabs(None), bar.normalize_tabs({}), bar.normalize_tabs("x")])
eq("활성 탭 없음 → 0번", 0, bar.active_index(mk_tabs(["a", "b"])))
eq("활성 탭 위치", 1, bar.active_index(mk_tabs(["a", "b"], active=1)))

# ── P: 창 선택·줄 나누기 ───────────────────────────────────────────────────
scenario("P", "28탭 × 188열 창 선택 · 2줄 · 경계 · 아주 좁은 폭")


def plan_ok(plan, widths, caps, active, n):
    """계획의 불변식 위반 목록 (빈 목록이면 정상)."""
    bad = []
    if n and not (plan["lo"] <= active <= plan["hi"]):
        bad.append("활성 탭 %d가 창 [%d,%d] 밖" % (active, plan["lo"], plan["hi"]))
    placed = [idx for line in plan["lines"] for idx, _, _ in line]
    if n and placed != list(range(plan["lo"], plan["hi"] + 1)) and not (plan["lo"] == plan["hi"] == active and placed == [active]):
        bad.append("배치 순서 이상: %r" % placed)
    left = plan["left"]
    right = plan["right"]
    lw = bar.str_width(left[0]) if left else 0
    rw = bar.str_width(right[0]) if right else 0
    if n and (plan["lo"] > 0) != bool(left):
        bad.append("왼쪽 숨김 표시 불일치")
    if n and (plan["hi"] < n - 1) != bool(right):
        bad.append("오른쪽 숨김 표시 불일치")
    if left and left[0] != "‹%d" % plan["lo"]:
        bad.append("왼쪽 표시 글자 %r" % (left[0],))
    if right and right[0] != "%d›" % (n - 1 - plan["hi"]):
        bad.append("오른쪽 표시 글자 %r" % (right[0],))
    for li, line in enumerate(plan["lines"]):
        end = caps[li] - (rw if (li == len(caps) - 1 and right) else 0)
        start = lw if (li == 0 and left) else 0
        prev = start
        for idx, x, w in line:
            if x < prev:
                bad.append("겹침/역순 line%d idx%d x%d<%d" % (li, idx, x, prev))
            if x + w > max(end, w if plan["lo"] == plan["hi"] else 0) and not (plan["lo"] == plan["hi"] and w <= caps[0]):
                bad.append("영역 초과 line%d idx%d %d+%d>%d" % (li, idx, x, w, end))
            prev = x + w
    if right:
        last_end = max([x + w for _, x, w in plan["lines"][-1]] + [0])
        if right[1] < last_end:
            bad.append("오른쪽 표시가 마지막 줄 탭과 겹침")
        if right[1] + rw != caps[-1]:
            bad.append("오른쪽 표시가 영역 끝에 붙지 않음")
    return bad


for label, names in (("균일 이름", NAMES28), ("한글·긴 이름 섞임", MIXED28)):
    tabs = mk_tabs(names)
    ws = widths_of(tabs)
    for rows in (1, 2):
        caps = bar.strip_caps(188, rows)
        bad = []
        shown = []
        for a in range(len(tabs)):
            p = bar.plan_tabs(ws, a, caps)
            bad += ["active=%d: %s" % (a, b) for b in plan_ok(p, ws, caps, a, len(tabs))]
            shown.append(p["hi"] - p["lo"] + 1)
        check("%s, 188열, %s: 활성 탭 0~27 모두 창에 포함·영역 안·표시 일치" % (label, "접힘(1줄)" if rows == 1 else "펼침(2줄)"), not bad, "; ".join(bad[:5]))
        check("%s, 188열, %s: 28개 전부는 안 들어간다(숨김 표시가 생김)" % (label, "접힘" if rows == 1 else "펼침"), min(shown) < 28 or rows == 2, str(shown))
    p1 = bar.plan_tabs(ws, 13, bar.strip_caps(188, 1))
    p2 = bar.plan_tabs(ws, 13, bar.strip_caps(188, 2))
    check("%s: 펼침(2줄)이 접힘(1줄)보다 탭을 더 보여준다" % label, (p2["hi"] - p2["lo"]) > (p1["hi"] - p1["lo"]), "%r vs %r" % ((p1["lo"], p1["hi"]), (p2["lo"], p2["hi"])))

tabs = mk_tabs(NAMES28)
ws = widths_of(tabs)
caps1, caps2 = bar.strip_caps(188, 1), bar.strip_caps(188, 2)
eq("캡: 접힘은 토글(3칸) 뺀 185 한 줄", [185], caps1)
eq("캡: 펼침은 0행 토글(3칸)·1행 아이콘(11칸) 뺀 [185, 177]", [185, 177], caps2)
p = bar.plan_tabs(ws, 13, caps1)
check("균형 확장: 가운데 활성 탭은 좌우 개수 차이가 1 이하", abs((13 - p["lo"]) - (p["hi"] - 13)) <= 1, "lo=%d hi=%d" % (p["lo"], p["hi"]))
p = bar.plan_tabs(ws, 0, caps1)
check("맨 앞 활성: 왼쪽 숨김 없음·오른쪽 'N›'", p["lo"] == 0 and p["left"] is None and p["right"] and p["right"][0] == "%d›" % (27 - p["hi"]), repr(p["right"]))
p = bar.plan_tabs(ws, 27, caps1)
check("맨 뒤 활성: 오른쪽 숨김 없음·왼쪽 '‹N'", p["hi"] == 27 and p["right"] is None and p["left"] and p["left"][0] == "‹%d" % p["lo"], repr(p["left"]))
p = bar.plan_tabs(ws, 13, caps2)
check("펼침: 0행이 가득 차면 1행으로 이어진다 (탭이 두 줄에 모두 있음)", len(p["lines"][0]) > 0 and len(p["lines"][1]) > 0, repr([len(l) for l in p["lines"]]))
first_line1 = p["lines"][1][0]
used0 = max(x + w for _, x, w in p["lines"][0])
check("펼침: 0행의 남은 칸에 다음 탭이 못 들어갈 때만 1행으로 넘어간다", used0 + (ws[first_line1[0]]) > caps2[0], "used0=%d next=%d cap=%d" % (used0, ws[first_line1[0]], caps2[0]))
# 전부 들어가는 경우
small = mk_tabs(["a", "bb", "ccc"])
sw = widths_of(small)
p = bar.plan_tabs(sw, 1, caps1)
check("3탭(전부 들어감): 숨김 표시 없음·0행에 전부", p["lo"] == 0 and p["hi"] == 2 and not p["left"] and not p["right"] and len(p["lines"][0]) == 3, repr(p))
p = bar.plan_tabs(sw, 1, caps2)
check("3탭 펼침: 0행에 전부, 1행은 비어 있음", len(p["lines"][0]) == 3 and p["lines"][1] == [], repr(p["lines"]))
eq("탭 배치: 앞에서부터 이어 붙인다 (x 0,3,7)", [0, 3, 7], [x for _, x, _ in bar.plan_tabs(sw, 0, caps1)["lines"][0]])
# 탭 0·1개
p = bar.plan_tabs([], 0, caps1)
check("탭 0개: 예외 없이 빈 계획", p["lines"] == [[]] and p["lo"] > p["hi"], repr(p))
p = bar.plan_tabs([], 0, caps2)
check("탭 0개(펼침): 빈 2줄", p["lines"] == [[], []], repr(p))
p = bar.plan_tabs([7], 0, caps1)
check("탭 1개: 그 탭만, 숨김 없음", p["lines"][0] == [(0, 0, 7)] and not p["left"] and not p["right"], repr(p))
check("활성 번호가 범위 밖(-1, 99)이어도 클램프", all(bar.plan_tabs(sw, a, caps1)["lo"] <= 2 for a in (-1, 99)))
# 아주 좁은 폭
exc = []
inv = []
for w in range(0, 25):
    for rows in (1, 2):
        caps = bar.strip_caps(w, rows)
        for nm in ([], ["a"], NAMES28, MIXED28):
            tt = mk_tabs(nm)
            wsn = widths_of(tt)
            for a in (0, len(tt) // 2, max(len(tt) - 1, 0)):
                try:
                    p = bar.plan_tabs(wsn, a, caps)
                except Exception as e:  # noqa: BLE001
                    exc.append("w=%d rows=%d n=%d: %s" % (w, rows, len(tt), e))
                    continue
                if tt:
                    ac = min(max(a, 0), len(tt) - 1)
                    if not (p["lo"] <= ac <= p["hi"]):
                        inv.append("w=%d rows=%d n=%d a=%d 활성 탭이 창 밖" % (w, rows, len(tt), a))
                    for line in p["lines"]:
                        for idx, x, tw in line:
                            if x < 0 or tw > max(caps[0], 0) + 0 and p["lo"] == p["hi"]:
                                inv.append("w=%d 음수 x 또는 폭 초과" % w)
check("폭 0~24 × 접힘/펼침 × 탭 0/1/28개: plan_tabs 예외 없음", not exc, "; ".join(exc[:3]))
check("폭 0~24: 활성 탭은 (잘리더라도) 항상 창에 포함", not inv, "; ".join(inv[:3]))
check("활성 탭이 영역보다 넓으면 영역 폭으로 잘라 보여준다", bar.plan_tabs([40, 5], 0, [10])["lines"][0] == [(0, 0, 10)], repr(bar.plan_tabs([40, 5], 0, [10])))

# ── D: 그리기 (가짜 화면) ──────────────────────────────────────────────────
scenario("D", "스트립 모드 그리기 — 접힘/펼침 · 토글 위치 · 클릭 영역 · 레거시")
tabs = mk_tabs(NAMES28, active=13, bells={13, 14})
for rows in (1, 2):
    scr = FakeScr(2, 188)
    hits = []
    bar.SESSION = "cmuxt123"
    bar.draw_strip(scr, rows, tabs, False, hits)
    r0, r1 = scr.line(0), scr.line(1)
    tag = "접힘" if rows == 1 else "펼침"
    check("%s: 0행 오른쪽 끝에 토글 %s" % (tag, "▾" if rows == 1 else "▴"), r0.endswith(" ▾ " if rows == 1 else " ▴ ") and bar.str_width(r0) == 188, repr(r0[-8:]))
    if rows == 1:
        check("접힘: 1행은 툴바(cmux │ Picker │ Close │ Quit + 세션명)", r1.startswith(" cmux │ ◉ Picker │ × Close │ ⏻ Quit  │") and r1.rstrip().endswith("cmuxt123"), repr(r1[:60]))
        check("접힘: 탭은 0행에만", "proj-alpha-1" in r0 and "proj-alpha" not in r1)
    else:
        check("펼침: 1행 오른쪽 끝에 축약 아이콘 ' ◉ │ × │ ⏻ '", r1.endswith(" ◉ │ × │ ⏻ "), repr(r1[-14:]))
        check("펼침: 0·1행 모두 탭 (툴바 글자 없음)", "proj-alpha" in r0 and "proj-alpha" in r1 and "Picker" not in r1 and "cmux │" not in r1)
    act_name = "proj-alpha-13*"
    check("%s: 활성 탭(벨 *)이 화면에 보인다" % tag, act_name in r0 + r1, "")
    check("%s: 숨김 개수 표시 ‹N / N›" % tag, "‹" in r0 and "›" in (r0 if rows == 1 else r1), "%r %r" % (r0[:6], (r0 if rows == 1 else r1)[-20:]))
    toggles = [h for h in hits if h[3][0] == "toggle"]
    eq("%s: 토글 눌림 영역 = 0행 오른쪽 끝 3칸" % tag, [(0, 185, 187)], [(h[0], h[1], h[2]) for h in toggles])
    tab_hits = [h for h in hits if h[3][0] == "tab"]
    ok = True
    why = ""
    for y, x0, x1, (_, tid) in tab_hits:
        label = bar.tab_label(tabs[tid - 100])
        if scr.cells(y, x0, x1) != label:
            ok, why = False, "tid=%d %r != %r" % (tid, scr.cells(y, x0, x1), label)
            break
    check("%s: 탭 클릭 영역이 화면에 그려진 라벨과 정확히 일치" % tag, ok and len(tab_hits) > 5, why)
    mid = tab_hits[3]
    eq("%s: 탭 영역 한가운데 클릭 → 그 탭 id" % tag, ("tab", mid[3][1]), bar.classify_mouse(bar.BTN_CLICK, (mid[1] + mid[2]) // 2, mid[0], hits))
    eq("%s: 토글 영역 클릭 → toggle" % tag, ("toggle", None), bar.classify_mouse(bar.BTN_CLICK, 186, 0, hits))
    acts = {h[3][1]: h for h in hits if h[3][0] == "action"}
    check("%s: Picker/Close/Quit 눌림 영역 존재" % tag, set(acts) == {"picker", "close", "quit"}, repr(sorted(acts)))
    if rows == 1:
        check("접힘: 툴바 눌림 영역은 1행", all(h[0] == 1 for h in acts.values()))
    else:
        check("펼침: 아이콘 눌림 영역은 1행 오른쪽 11칸 안 (각 3칸)", all(h[0] == 1 and h[1] >= 177 and h[2] - h[1] == 2 for h in acts.values()), repr(acts))
    eq("%s: 마지막 호출은 refresh" % tag, ("refresh",), scr.calls[-1])

# 세 번째 줄의 탭 배치와 클릭도 확인한다.
scr = FakeScr(3, 80)
hits = []
bar.draw_strip(scr, 3, tabs, False, hits)
third_row = [hit for hit in hits if hit[0] == 2 and hit[3][0] == "tab"]
check("펼침 3줄: 세 번째 줄에 탭과 클릭 영역이 있다", bool(third_row) and "proj-alpha" in scr.line(2), repr(scr.line(2)))
if third_row:
    hit = third_row[0]
    eq("세 번째 줄 탭 클릭 → 해당 탭 id", hit[3], bar.classify_mouse(bar.BTN_CLICK, hit[1], 2, hits))
eq("3줄 폭: 토글·아이콘 제외, 마지막 줄은 전체 폭", [77, 69, 80], bar.strip_caps(80, 3))

# 한글 이름이 깨지지 않는다 (2칸 글자 정렬)
kt = mk_tabs(["한글프로젝트", "alpha", "베타"], active=0)
scr = FakeScr(2, 60)
hits = []
bar.draw_strip(scr, 1, kt, False, hits)
th = [h for h in hits if h[3][0] == "tab"]
check("한글 이름: 눌림 영역 폭 = 라벨 폭(14, 7, 6)", [h[2] - h[1] + 1 for h in th] == [14, 7, 6], repr(th))
check("한글 이름: 화면 셀과 라벨 일치", all(scr.cells(h[0], h[1], h[2]) == bar.tab_label(kt[h[3][1] - 100]) for h in th))
# 플레이스홀더 · 탭 없음
for tabs_in, ph, desc in ((None, True, "시작 직후(…)"), ([], False, "탭 0개")):
    scr = FakeScr(2, 80)
    hits = []
    bar.draw_strip(scr, 1, tabs_in, ph, hits)
    check("%s: 0행 앞에 … 만 그리고 툴바·토글은 유지" % desc, scr.line(0).startswith(" … ") and scr.line(0).rstrip().endswith("▾") and "Picker" in scr.line(1) and not [h for h in hits if h[3][0] == "tab"], repr(scr.line(0)[:20]))
# 아주 좁은 화면
bad = []
for w in range(1, 30):
    for rows in (1, 2):
        for tabs_in in (None, [], mk_tabs(["a"], active=0), tabs):
            try:
                bar.draw_strip(FakeScr(2, w), rows, tabs_in, False, [])
            except Exception as e:  # noqa: BLE001
                bad.append("w=%d rows=%d: %s %s" % (w, rows, type(e).__name__, e))
check("폭 1~29 × 접힘/펼침 × 탭 없음/0/1/28개 draw_strip 예외 없음", not bad, "; ".join(bad[:3]))
bad = []
for h in (3, 4):
    try:
        bar.draw_strip(FakeScr(h, 100), 2, tabs, False, [])
    except Exception as e:  # noqa: BLE001
        bad.append(str(e))
check("pane이 3~4행이어도 예외 없음 (탭 줄은 0~1행만)", not bad, "; ".join(bad))

# 레거시: 이전 구현과 같은 출력
scenario("L", "레거시 모드(내용 1행) — 이전 구현과 같은 그리기 · 예외 없음")
if OLD_BAR_PATH and os.path.exists(OLD_BAR_PATH):
    old = load(OLD_BAR_PATH, "cmux_bar_old")
    same = True
    why = ""
    for sess in ("", "cmuxt123", "claude"):
        for w in (1, 2, 5, 8, 12, 20, 30, 40, 45, 60, 100, 188):
            old.SESSION = bar.SESSION = sess
            a = FakeScr(1, w)
            b = FakeScr(1, w)
            oranges = []
            nhits = []
            old.draw(a, oranges)
            bar.draw_legacy(b, nhits)
            if a.calls != b.calls:
                same, why = False, "sess=%r w=%d\n구: %r\n신: %r" % (sess, w, a.calls, b.calls)
                break
            if [(s, e, ac) for s, e, ac in oranges] != [(h[1], h[2], h[3][1]) for h in nhits] or any(h[0] != 0 for h in nhits):
                same, why = False, "sess=%r w=%d 눌림 영역 다름 %r vs %r" % (sess, w, oranges, nhits)
                break
        if not same:
            break
    check("draw_legacy = 이전 draw (addstr·erase·refresh 호출 순서·좌표·글자·속성, 눌림 영역: 세션 3종 × 폭 12종)", same, why)
else:
    print("SKIP\t이전 cmux-bar 없음 — 레거시 비교 생략")
bar.SESSION = "cmuxt123"
bad = []
for w in range(1, 40):
    try:
        bar.draw_legacy(FakeScr(1, w), [])
    except Exception as e:  # noqa: BLE001
        bad.append("w=%d %s" % (w, e))
check("레거시: 폭 1~39 예외 없음", not bad, "; ".join(bad[:3]))
scr = FakeScr(1, 80)
bar.draw_legacy(scr, [])
check("레거시: 탭 줄·토글 글자 없음 (툴바만)", "▾" not in scr.line(0) and "▴" not in scr.line(0) and scr.line(0).startswith(" cmux │"), repr(scr.line(0)[:40]))

# ── S: 토글 상태 파일 ──────────────────────────────────────────────────────
scenario("S", "토글 상태 파일 읽기/쓰기")
sf = os.path.join(TMP, "state", "tabbar-rows")
eq("파일 없음 → 펼침", 2, bar.read_rows(sf))
os.makedirs(os.path.dirname(sf))
for content, want in (("1", 1), ("2", 2), ("2\n", 2), (" 2 \n", 2), ("", 1), ("abc", 1), ("3", 1), ("22", 1), ("0", 1)):
    with open(sf, "w") as f:
        f.write(content)
    eq("내용 %r → %d" % (content, want), want, bar.read_rows(sf))
os.unlink(sf)
os.mkdir(sf)
eq("디렉터리가 있어도 1 (예외 없음)", 1, bar.read_rows(sf))
os.rmdir(sf)
check("write_rows(2) 성공", bar.write_rows(sf, 2))
eq("write_rows(2) 내용", "2\n", open(sf).read())
check("write_rows(1) 성공", bar.write_rows(sf, 1))
eq("write_rows(1) 내용", "1\n", open(sf).read())
eq("임시 파일 잔여 없음 (os.replace)", ["tabbar-rows"], sorted(os.listdir(os.path.dirname(sf))))
eq("toggle 1→2", 2, bar.toggle_rows(sf))
eq("toggle 2→1", 1, bar.toggle_rows(sf))
os.unlink(sf)
nested = os.path.join(TMP, "new", "dir", "rows")
eq("상위 디렉터리가 없어도 토글이 만든다", 1, bar.toggle_rows(nested))
eq("쓸 수 없는 경로: write_rows False·예외 없음", False, bar.write_rows("/dev/null/x/rows", 2))
eq("쓸 수 없는 경로: toggle은 실제 상태(1)를 돌려준다", 1, bar.toggle_rows("/dev/null/x/rows"))
os.environ["CMUX_TABBAR_STATE_FILE"] = "/x/y"
eq("state_path: env 우선", "/x/y", bar.state_path())
del os.environ["CMUX_TABBAR_STATE_FILE"]
os.environ["HOME"] = "/h"
eq("state_path: 기본 $HOME/.config/cmux/tabbar-rows", "/h/.config/cmux/tabbar-rows", bar.state_path())
os.environ["CMUX_BAR_CACHE_DIR"] = "/c"
eq("cache_dir_path: env 우선", "/c", bar.cache_dir_path())
del os.environ["CMUX_BAR_CACHE_DIR"]
os.environ["TMPDIR"] = "/t/"
eq("cache_dir_path: 기본 $TMPDIR/cmux-bar-<uid>", "/t/cmux-bar-%d" % os.getuid(), bar.cache_dir_path())
eq("cache_paths: 세션명 정리(/ → _)", ("/c/tabs-a_b.json", "/c/tabs-a_b.lock"), bar.cache_paths("/c", "a/b"))
eq("cache_paths: 세션명 없음", "/c/tabs-nosession.json", bar.cache_paths("/c", "")[0])
# run_hit 토글 (zellij 호출 없음)
sf2 = os.path.join(TMP, "state2", "rows")
eq("run_hit(toggle) → 1", 1, bar.run_hit(("toggle", None), None, sf2))
eq("run_hit(toggle) 한 번 더 → 2", 2, bar.run_hit(("toggle", None), None, sf2))

# ── E: 리더 선출 · 탭 목록 공유 ────────────────────────────────────────────
scenario("E", "리더 선출(mkdir 락·pid·생존 확인) · 캐시 공유 · 실패 시 유지 · 2초 지연")
cd = os.path.join(TMP, "cache")
os.makedirs(cd)
cf, ld = bar.cache_paths(cd, "s1")
now = time.time()
eq("첫 후보가 리더", True, bar.elect_leader(ld, cf, 111, now))
eq("같은 pid 재호출도 리더", True, bar.elect_leader(ld, cf, 111, now))
eq("둘째 후보는 팔로워 (보유자 111 생존)", False, bar.elect_leader(ld, cf, 222, now, alive=lambda p: True))
eq("pid 파일 내용", "111", open(os.path.join(ld, "pid")).read().strip())
eq("보유자가 죽었으면 인수", True, bar.elect_leader(ld, cf, 222, now, alive=lambda p: p != 111))
eq("인수 뒤 pid 파일 = 222", "222", open(os.path.join(ld, "pid")).read().strip())
eq("인수 잔재(.dead.*) 정리됨", [], [n for n in os.listdir(cd) if ".dead." in n])
# 보유자 생존이지만 하트비트·캐시가 낡음
old_t = now - 10
os.utime(os.path.join(ld, "pid"), (old_t, old_t))
eq("보유자 생존 + 하트비트 낡음(10초) → 인수", True, bar.elect_leader(ld, cf, 333, now, alive=lambda p: True))
with open(cf, "w") as f:
    f.write("[]")
eq("보유자 생존 + 캐시 신선 → 팔로워", False, bar.elect_leader(ld, cf, 444, now, alive=lambda p: True))
os.utime(cf, (old_t, old_t))
os.utime(os.path.join(ld, "pid"), (old_t, old_t))
eq("보유자 생존 + 캐시·하트비트 모두 3초 이상 낡음 → 인수", True, bar.elect_leader(ld, cf, 444, now, alive=lambda p: True))
# pid 파일 없는 락
os.unlink(os.path.join(ld, "pid"))
eq("pid 파일 없는 젊은 락 → 건드리지 않는다", False, bar.elect_leader(ld, cf, 555, time.time(), alive=lambda p: True))
os.utime(ld, (old_t, old_t))
eq("pid 파일 없는 오래된 락 → 인수", True, bar.elect_leader(ld, cf, 555, time.time(), alive=lambda p: True))
shutil.rmtree(cd)
os.makedirs(cd)

# 실제 프로세스 6개가 동시에 선출을 시도한다 (경합 1회) → 정확히 1개만 리더
race_dir = os.path.join(TMP, "race")
os.makedirs(race_dir)
go_at = time.time() + 1.0
child = (
    "import importlib.machinery as m, importlib.util as u, os, sys, time\n"
    "l = m.SourceFileLoader('b', sys.argv[1]); s = u.spec_from_loader('b', l); b = u.module_from_spec(s); l.exec_module(b)\n"
    "cf, ld = b.cache_paths(sys.argv[2], 'race')\n"
    "while time.time() < float(sys.argv[3]): pass\n"
    "print(int(b.elect_leader(ld, cf, os.getpid(), time.time())))\n"
    "time.sleep(0.5)\n"                    # 승자가 살아 있는 동안 다른 후보가 판단하게 둔다
)
procs = [subprocess.Popen([sys.executable, "-I", "-c", child, BAR_PATH, race_dir, str(go_at)], stdout=subprocess.PIPE) for _ in range(6)]
outs = [p.communicate()[0].decode().strip() for p in procs]
eq("동시 선출 6프로세스 1회: 리더는 정확히 1개", 1, outs.count("1"))
eq("동시 선출: 나머지 5개는 팔로워", 5, outs.count("0"))
shutil.rmtree(race_dir)


class Fetcher:
    def __init__(self, tabs_raw):
        self.raw = tabs_raw
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.raw


RAW = [
    {"position": 1, "name": "beta", "active": False, "tab_id": 11, "has_bell_notification": True},
    {"position": 0, "name": "alpha", "active": True, "tab_id": 10},
]
cd = os.path.join(TMP, "cache2")
fa, fb = Fetcher(RAW), Fetcher(RAW)
lead = bar.TabSource("s2", cd, fetch=fa, pid=os.getpid())
foll = bar.TabSource("s2", cd, fetch=fb, pid=os.getpid() + 1_000_000)
t0 = time.time()
lead.poll(1.0, t0)
foll.poll(1.0, t0)
eq("시작 2초 전: zellij 조회 0회·탭 목록 없음(…)", (0, 0, None, None), (fa.calls, fb.calls, lead.tabs, foll.tabs))
check("시작 2초 전: 락도 만들지 않는다", not os.path.exists(lead.lock_dir))
lead.poll(2.1, t0 + 1.1)
eq("2초 뒤 리더: 조회 1회", 1, fa.calls)
check("리더가 캐시 파일을 원자적으로 썼다 (tmp 잔여 없음)", os.path.exists(lead.cache_file) and not [n for n in os.listdir(cd) if ".tmp." in n], repr(os.listdir(cd)))
eq("리더의 탭 목록 (position 순, id·벨 정규화)", [("alpha", True, 10, False), ("beta", False, 11, True)], [(t["name"], t["active"], t["id"], t["bell"]) for t in lead.tabs])
ch = foll.poll(2.1, t0 + 1.1)
eq("팔로워: 조회 0회, 캐시에서 같은 목록을 읽음", (0, lead.tabs, True), (fb.calls, foll.tabs, ch))
lead.poll(2.5, t0 + 1.5)
foll.poll(2.5, t0 + 1.5)
eq("1초 이내 재호출: 리더 조회 늘지 않음", 1, fa.calls)
lead.poll(3.2, t0 + 2.2)
eq("1초 지나면 리더 재조회 (총 2회)", 2, fa.calls)
eq("팔로워는 계속 0회", 0, fb.calls)
# 조회 실패: 마지막 캐시 유지, 폭주 없음
fa.raw = None
before = lead.tabs
lead.poll(4.5, t0 + 3.5)
calls_after_fail = fa.calls
eq("조회 실패: 마지막 탭 목록 유지", before, lead.tabs)
eq("조회 실패: 리더 조회 1회 시도(총 3회)", 3, calls_after_fail)
for k in range(8):
    lead.poll(4.6 + k * 0.1, t0 + 3.6 + k * 0.1)
eq("조회 실패 직후 0.8초 동안 재시도 폭주 없음(총 3회 유지, 백오프)", 3, fa.calls)
check("실패 백오프가 커진다 (다음 조회 ≥ 2초 뒤)", lead.next_fetch - (t0 + 3.5) >= 2.0, "next_fetch-now=%.2f" % (lead.next_fetch - (t0 + 3.5)))
foll.poll(4.7, t0 + 3.7)
eq("조회 실패 중에도 팔로워는 리더를 인수하지 않는다 (캐시 mtime을 리더가 갱신)", (False, 0), (foll.is_leader, fb.calls))
eq("조회 실패 중 팔로워 탭 목록 유지", before, foll.tabs)
# 리더 죽음 → 팔로워 인수
dead = subprocess.Popen([sys.executable, "-I", "-c", "pass"])
dead.wait()
cd3 = os.path.join(TMP, "cache3")
fz = Fetcher(RAW)
zombie = bar.TabSource("s3", cd3, fetch=Fetcher(RAW), pid=dead.pid)
zombie.poll(2.1, t0)                     # 리더가 되어 한 번 조회·캐시 기록 (이후 프로세스는 죽은 것으로 취급)
check("(준비) 죽은 pid가 리더로 기록됨", os.path.exists(zombie.cache_file) and open(zombie.pid_file).read().strip() == str(dead.pid))
fy = bar.TabSource("s3", cd3, fetch=fz, pid=os.getpid())
fy.poll(2.2, t0 + 0.1)
eq("신선한 캐시 + 보유자 죽음: 캐시 나이 1.5초 전에는 확인하지 않는다 (조회 0회)", (False, 0), (fy.is_leader, fz.calls))
fy.poll(2.2 + 2.0, t0 + 2.1)
eq("캐시 1.5초 이상 낡고 보유자 pid 죽음 → 팔로워가 인수·조회", (True, 1), (fy.is_leader, fz.calls))
fy.close()
check("리더 close(): 락 반납", not os.path.exists(fy.lock_dir))
# 시작 직후 낡은 캐시는 쓰지 않는다 / 2초 뒤엔 폴백으로 쓴다
cd4 = os.path.join(TMP, "cache4")
os.makedirs(cd4)
cf4, ld4 = bar.cache_paths(cd4, "s4")
with open(cf4, "w") as f:
    json.dump(RAW, f)
os.utime(cf4, (t0 - 100, t0 - 100))
st = bar.TabSource("s4", cd4, fetch=Fetcher(None), pid=os.getpid())
st.poll(0.5, t0)
eq("시작 2초 전: 낡은(100초) 캐시는 안 쓴다", None, st.tabs)
st.poll(2.5, t0 + 2.0)
eq("2초 뒤: 낡은 캐시를 폴백으로 읽는다 (조회가 실패해도 그리는 데이 문제 없음)", 2, len(st.tabs or []))
# 캐시 디렉터리를 못 쓰는 경우
blocker = os.path.join(TMP, "blocker")
open(blocker, "w").close()
fn = Fetcher(RAW)
nu = bar.TabSource("s5", os.path.join(blocker, "sub"), fetch=fn, pid=os.getpid())
eq("캐시 디렉터리 불가: usable False", False, nu.usable)
nu.poll(1.0, t0)
eq("캐시 디렉터리 불가: 2초 전 조회 없음", 0, fn.calls)
nu.poll(2.5, t0 + 1.5)
eq("캐시 디렉터리 불가: 2초 뒤 혼자 조회해 그린다", (1, 2), (fn.calls, len(nu.tabs or [])))
nu.poll(3.0, t0 + 2.0)
eq("캐시 디렉터리 불가: 3초 간격(폭주 없음)", 1, fn.calls)

# ── M: 마우스 분류 ─────────────────────────────────────────────────────────
scenario("M", "마우스 이벤트 분류")
H = [(0, 2, 9, ("tab", 5)), (0, 10, 20, ("tab", 6)), (0, 185, 187, ("toggle", None)), (1, 0, 5, ("action", "picker"))]
eq("클릭: 탭 영역", ("tab", 5), bar.classify_mouse(bar.BTN_CLICK, 5, 0, H))
eq("클릭: 영역 경계(양끝 포함)", [("tab", 5), ("tab", 5), ("tab", 6)], [bar.classify_mouse(bar.BTN_CLICK, x, 0, H) for x in (2, 9, 10)])
eq("클릭: 영역 밖", [None, None], [bar.classify_mouse(bar.BTN_CLICK, 1, 0, H), bar.classify_mouse(bar.BTN_CLICK, 21, 0, H)])
eq("클릭: 다른 행", [None, ("action", "picker")], [bar.classify_mouse(bar.BTN_CLICK, 5, 2, H), bar.classify_mouse(bar.BTN_CLICK, 5, 1, H)])
eq("클릭: 토글 3칸 모두", [("toggle", None)] * 3, [bar.classify_mouse(bar.BTN_CLICK, x, 0, H) for x in (185, 186, 187)])
eq("버튼 상태가 클릭이 아니면(이동 등) 무시", None, bar.classify_mouse(getattr(curses, "REPORT_MOUSE_POSITION", 1 << 27) & ~bar.BTN_CLICK, 5, 0, H))
eq("휠 위 → 이전 탭", ("nav", "go-to-previous-tab"), bar.classify_mouse(bar.BTN_WHEEL_UP, 50, 1, H))
if bar.BTN_WHEEL_DOWN:
    eq("휠 아래 → 다음 탭", ("nav", "go-to-next-tab"), bar.classify_mouse(bar.BTN_WHEEL_DOWN, 50, 1, H))
else:
    print("SKIP\t이 python의 curses에는 BUTTON5(휠 아래)가 없다 (ncurses 마우스 버전 1 빌드) — 휠 아래 분류 생략")
eq("마우스 마스크에 눌림만 (뗌·이동 없음)", 0, bar.MOUSE_MASK & (getattr(curses, "BUTTON1_RELEASED", 0) | getattr(curses, "REPORT_MOUSE_POSITION", 0)))

# ── K: 키 ──────────────────────────────────────────────────────────────────
scenario("K", "바 pane 키 — p·t만, x·q 없음 (일부러 제거)")
eq("p → 피커", ("action", "picker"), bar.classify_key(ord("p")))
eq("t/T → 토글", [("toggle", None), ("toggle", None)], [bar.classify_key(ord("t")), bar.classify_key(ord("T"))])
eq("x·X·q·Q → 동작 없음 (탭 닫기·세션 종료 키 제거)", [None] * 4, [bar.classify_key(ord(c)) for c in "xXqQ"])
eq("다른 키(엔터·숫자·p 대문자)도 없음", [None] * 3, [bar.classify_key(10), bar.classify_key(ord("1")), bar.classify_key(ord("P"))])
eq("바가 먹는 키는 p·t·T 셋뿐", sorted([ord("p"), ord("t"), ord("T")]), sorted(bar.KEY_ACTIONS))
eq("버튼 Close/Quit은 키 없음, Picker만 p", [("picker", "p"), ("close", None), ("quit", None)], [(a, k) for _, k, a in bar.BUTTONS])

# ── F: 클릭 뒤 포커스 복귀 대상 ────────────────────────────────────────────
scenario("F", "포커스 복귀 대상 선택 (pick_focus_target)")


def pane(pid, title, x, y, tab=1, focused=False, plugin=False, floating=False, sel=True, supp=False):
    return {"id": pid, "title": title, "pane_x": x, "pane_y": y, "tab_id": tab, "is_focused": focused,
            "is_plugin": plugin, "is_floating": floating, "is_selectable": sel, "is_suppressed": supp}


BASE = [
    pane(5, "/bin/zsh -c while true...", 0, 1, focused=True),        # 바 (자기)
    pane(6, "terminal", 122, 27),
    pane(7, "claude", 0, 4),
    pane(8, "files", 122, 4),
    pane(5, "zellij:status-bar", 0, 47, plugin=True, sel=False),     # 플러그인 — 같은 id 5여도 자기가 아니다
    pane(9, "claude", 0, 4, tab=2),                                  # 다른 탭
]
eq("에이전트 이름(claude) pane 우선 — 더 위·왼쪽인 files보다도", 7, bar.pick_focus_target(BASE, "5"))
eq("my_id가 정수여도 동작", 7, bar.pick_focus_target(BASE, 5))
no_agent = [p for p in BASE if p["title"] != "claude" or p["tab_id"] == 2]
eq("에이전트 이름 없으면 가장 위·왼쪽 (files y4 x122 < terminal y27)", 8, bar.pick_focus_target(no_agent, "5"))
eq("codex 이름도 에이전트로 본다", 12, bar.pick_focus_target([BASE[0], BASE[1], pane(12, "codex", 50, 9)], "5"))
unfocused = [dict(BASE[0], is_focused=False)] + BASE[1:]
eq("자기 pane이 포커스 상태가 아니면 아무것도 안 한다 (None)", None, bar.pick_focus_target(unfocused, "5"))
eq("자기 pane을 못 찾으면 None", None, bar.pick_focus_target(BASE, "99"))
eq("ZELLIJ_PANE_ID가 비었거나 숫자 아님 → None", [None, None, None], [bar.pick_focus_target(BASE, ""), bar.pick_focus_target(BASE, "x"), bar.pick_focus_target(BASE, None)])
eq("목록이 이상하면 None", [None, None], [bar.pick_focus_target(None, "5"), bar.pick_focus_target([None, 3], "5")])
only_self = [BASE[0], BASE[4], BASE[5]]
eq("본문 후보가 없으면(자기뿐·다른 탭·플러그인) None", None, bar.pick_focus_target(only_self, "5"))
excluded = [BASE[0], pane(20, "claude", 0, 2, floating=True), pane(21, "claude", 0, 2, sel=False), pane(22, "claude", 0, 2, supp=True),
            pane(23, "claude", 0, 2, plugin=True), pane(24, "files", 122, 4)]
eq("플로팅·selectable 아님·숨김·플러그인 pane은 제외 → 남은 files", 24, bar.pick_focus_target(excluded, "5"))
eq("같은 y면 x가 작은 쪽", 31, bar.pick_focus_target([BASE[0], pane(30, "files", 60, 4), pane(31, "files", 10, 4)], "5"))

# restore_focus: focus-next-pane 반복으로 목표 pane에 포커스 (focus-pane-id는 click-through에서 실제 포커스를 못 옮김, 실측)
# 포커스 확인은 list-clients(작은 응답), 목표·이동 횟수는 바 프로세스 메모리 캐시 — 캐시 미스일 때만 list-panes(큰 응답) 1회.
# 클릭 직후 자기 pane이 아직 포커스가 없으면 기다렸다가 복귀 / 끝내 없으면 아무것도 안 함
scenario("F2", "restore_focus 호출 순서 — list-clients 확인 · 이동 횟수 캐시 · 검증 실패/판단 불가 폴백 · A3 낙관적 갱신")
LC_HEADER = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"


class FakeZellij:
    """가짜 zellij — 탭 하나의 pane 고리 [(id, title, x, y)] (= focus-next-pane 순서) 와 포커스 인덱스.

    calls: 부른 zellij 명령 이름 순서. 바 = id 5.
    focus_after: 바가 클릭 포커스를 받기 전까지의 포커스 조회(list-panes·list-clients) 횟수 — 그동안 포커스는 pre(본문) pane.
    clients: list-clients 응답 각본(호출마다 하나씩, 다 쓰면 "ok"): ok | fail(종료코드 1) | timeout | garbage | header(헤더만)
    panes_fail: list-panes 조회 실패(None).  goto_rc: go-to-tab-by-id 종료코드(정수) 또는 "timeout".
    """

    def __init__(self, ring, focus_idx, focus_after=0, pre=7, clients=(), panes_fail=False, goto_rc=0, raw_tabs=None):
        self.ring, self.idx = list(ring), focus_idx
        self.focus_after, self.pre, self.queries = focus_after, pre, 0
        self.clients, self.panes_fail, self.goto_rc, self.raw_tabs = list(clients), panes_fail, goto_rc, raw_tabs
        self.calls = []

    def focused_id(self):
        pid = self.ring[self.idx][0]
        return self.pre if (pid == 5 and self.queries <= self.focus_after) else pid

    def json(self, args, timeout):
        self.calls.append(args[0])
        self.queries += 1
        if self.panes_fail:
            return None
        foc = self.focused_id()
        return [pane(pid, title, x, y, focused=(pid == foc)) for pid, title, x, y in self.ring]

    def run(self, cmd, **kw):
        act = cmd[2] if len(cmd) > 2 else "?"
        self.calls.append(act)
        if act == "focus-next-pane":
            self.idx = (self.idx + 1) % len(self.ring)
            return subprocess.CompletedProcess(cmd, 0)
        if act == "list-clients":
            self.queries += 1
            mode = self.clients.pop(0) if self.clients else "ok"
            if mode == "timeout":
                raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
            out = {"ok": LC_HEADER + "1          terminal_%d      /bin/sleep 600\n" % self.focused_id(),
                   "fail": "", "garbage": "Error: no such action\n", "header": LC_HEADER}[mode]
            return subprocess.CompletedProcess(cmd, 1 if mode == "fail" else 0, out.encode(), b"")
        self.calls[-1] = "UNEXPECTED:" + act
        return subprocess.CompletedProcess(cmd, 1)

    def popen(self, *args):
        self.calls.append(args[0])
        rc = self.goto_rc

        class P:
            def wait(self, timeout=None):
                if rc == "timeout":
                    raise subprocess.TimeoutExpired(["zellij"], timeout)
                return rc
        return P()

    def fetch_tabs(self):
        self.calls.append("list-tabs")
        return self.raw_tabs

    def focus(self):
        return self.ring[self.idx][0]

    def n(self, name):
        return self.calls.count(name)


real_json, real_run, real_zaction = bar._zellij_json, bar.subprocess.run, bar.zellij_action
bar.MY_PANE_ID, bar.FOCUS_WAIT = "5", 2.0


def patched(fz, fn, *a):
    bar._zellij_json, bar.subprocess.run, bar.zellij_action = fz.json, fz.run, fz.popen
    try:
        return fn(*a)
    finally:
        bar._zellij_json, bar.subprocess.run, bar.zellij_action = real_json, real_run, real_zaction


def run_restore(fz, plan="keep"):
    if plan != "keep":
        bar._focus_plan = plan
    patched(fz, bar.restore_focus)


LC, LP, FNP, GOTO, LT = "list-clients", "list-panes", "focus-next-pane", "go-to-tab-by-id", "list-tabs"
# cmux 기본 레이아웃 순서 (zellij focus-next-pane = 위→아래·왼→오른): 바 → claude → files → terminal
RING = [(5, "bar", 0, 0), (7, "claude", 0, 3), (8, "files", 130, 3), (6, "terminal", 130, 30)]

# 파서
eq("parse_clients: 헤더 + 1행", {"terminal_1"}, bar.parse_clients(LC_HEADER + "1          terminal_1      zsh -l\n"))
eq("parse_clients: 클라이언트 여러 개·plugin pane·명령 없음 행", {"terminal_3", "plugin_2"},
   bar.parse_clients(LC_HEADER + "1 plugin_2 zellij:session-manager\n2   terminal_3\n\n"))
eq("parse_clients: 헤더 없이 행만도 읽음", {"terminal_9"}, bar.parse_clients("4 terminal_9 vim\n"))
eq("parse_clients: 이상한 출력은 None (헤더만·빈 출력·오류 문구·id 이상·pane 이름 이상·None)", [None] * 6,
   [bar.parse_clients(s) for s in (LC_HEADER, "", "Error: x\n", LC_HEADER + "a terminal_1 zsh\n", LC_HEADER + "1 pane_1 zsh\n", None)])

# (a) 캐시 미스: list-clients(바 포커스 확인) → list-panes 1회 → focus-next-pane → list-clients(목표 확인)
fz = FakeZellij(RING, 0)
run_restore(fz, plan=None)
eq("(a) 캐시 미스: 호출 순서 list-clients → list-panes → focus-next-pane → list-clients", [LC, LP, FNP, LC], fz.calls)
eq("(a) 캐시 미스: list-panes(큰 응답) 1회·포커스 = claude(7)·캐시 (7, 1)", (1, 7, (7, 1)), (fz.n(LP), fz.focus(), bar._focus_plan))
# (b) 캐시 적중: list-panes 0회
fz = FakeZellij(RING, 0)
run_restore(fz)
eq("(b) 캐시 적중: 호출 순서 list-clients → focus-next-pane → list-clients (list-panes 0회)", ([LC, FNP, LC], 0), (fz.calls, fz.n(LP)))
eq("(b) 캐시 적중: 포커스 = claude(7), 캐시 유지", (7, (7, 1)), (fz.focus(), bar._focus_plan))
# 목표가 두 칸 뒤
ring2 = [(5, "bar", 0, 0), (6, "terminal", 0, 3), (7, "claude", 0, 20)]
fz = FakeZellij(ring2, 0)
run_restore(fz, plan=None)
eq("두 칸 뒤 목표, 캐시 미스: 단계마다 list-clients 확인 → 캐시 (7, 2), list-panes 1회", ([LC, LP, FNP, LC, FNP, LC], 7, (7, 2)), (fz.calls, fz.focus(), bar._focus_plan))
fz = FakeZellij(ring2, 0)
run_restore(fz)
eq("두 칸 뒤 목표, 캐시 적중: focus-next-pane 2회 + 검증 1회", ([LC, FNP, FNP, LC], 7), (fz.calls, fz.focus()))
# (c) 검증 불일치 → 캐시 폐기 + list-panes 교정
split = [(5, "bar", 0, 0), (9, "zsh", 0, 3), (7, "claude", 0, 20), (8, "files", 130, 3)]   # 캐시 (7, 1) 뒤에 pane 분할
fz = FakeZellij(split, 0)
run_restore(fz, plan=(7, 1))
eq("(c) 낡은 캐시(pane 분할): 1칸 이동 → 검증 불일치 → 캐시 폐기 → list-panes로 교정(per-step 루프)",
   ([LC, FNP, LC, LP, FNP, LP], 7, None), (fz.calls, fz.focus(), bar._focus_plan))
fz = FakeZellij(split, 0)
run_restore(fz)
eq("(c) 다음 클릭은 캐시 미스로 다시 배움 → (7, 2)", ([LC, LP, FNP, LC, FNP, LC], 7, (7, 2)), (fz.calls, fz.focus(), bar._focus_plan))
closed = [(5, "bar", 0, 0), (8, "files", 130, 3), (6, "terminal", 130, 30)]                # 캐시의 목표 claude(7)가 닫힘
fz = FakeZellij(closed, 0)
run_restore(fz, plan=(7, 1))
eq("(c) 캐시의 목표 pane이 닫힘: 검증 불일치 → 폐기 → list-panes로 새 목표 files(8)가 이미 포커스 → 추가 이동 없음",
   ([LC, FNP, LC, LP], 8, None), (fz.calls, fz.focus(), bar._focus_plan))
fz = FakeZellij(RING[:2], 0)
run_restore(fz, plan=(7, 2))
eq("(c) 캐시 횟수가 고리를 한 바퀴 돌아 바로 돌아옴: 폐기 → 교정 1칸 → claude(7)", ([LC, FNP, FNP, LC, LP, FNP, LP], 7, None), (fz.calls, fz.focus(), bar._focus_plan))
# (d) list-clients 판단 불가 → 기존 경로(list-panes만)
for mode in ("fail", "timeout", "garbage", "header"):
    fz = FakeZellij(RING, 0, clients=[mode])
    run_restore(fz, plan=(7, 1))
    eq("(d) 처음 list-clients가 %s → 캐시를 쓰지 않고 기존 경로 list-panes → focus-next-pane → list-panes, 포커스 claude(7)" % mode,
       ([LC, LP, FNP, LP], 7), (fz.calls, fz.focus()))
eq("(d) 처음부터 판단 불가면 캐시는 그대로 둔다 (쓰지 않았으므로)", (7, 1), bar._focus_plan)
fz = FakeZellij(RING, 0, clients=["ok", "fail"])
run_restore(fz, plan=(7, 1))
eq("(d) 캐시 적중 뒤 검증 list-clients 실패 → 캐시 폐기 → list-panes 1회로 확인 (이미 claude) → 추가 이동 없음",
   ([LC, FNP, LC, LP], 7, None), (fz.calls, fz.focus(), bar._focus_plan))
fz = FakeZellij(ring2, 0, clients=["ok", "garbage"])
run_restore(fz, plan=None)
eq("(d) 캐시 미스 단계 확인 중 list-clients 이상 → 캐시 안 만듦 → list-panes로 이어서 교정 → claude(7)",
   ([LC, LP, FNP, LC, LP, FNP, LP], 7, None), (fz.calls, fz.focus(), bar._focus_plan))
fz = FakeZellij(RING, 0, clients=["fail"], panes_fail=True)
run_restore(fz, plan=None)
eq("(d) list-clients·list-panes 모두 실패 → 기다리지 않고 조용히 끝남 (각 1회, 이동 없음)", [LC, LP], fz.calls)
# (e) 포커스가 늦게 옴 → list-clients로만 재확인
fz = FakeZellij(RING, 0, focus_after=3)
run_restore(fz, plan=None)
eq("(e) 클릭 직후 포커스가 늦게 와도(click-through) list-clients로 재확인 → 4번째에 포커스 → 이후 캐시 미스 경로",
   ([LC] * 4 + [LP, FNP, LC], 7), (fz.calls, fz.focus()))
fz = FakeZellij(RING, 0, focus_after=2)
run_restore(fz)
eq("(e) 늦은 포커스 + 캐시 적중: 재확인도 list-clients, list-panes 0회", ([LC] * 3 + [FNP, LC], 0, 7), (fz.calls, fz.n(LP), fz.focus()))
fz = FakeZellij([(5, "bar", 0, 0), (7, "claude", 0, 3)], 1)           # 포커스가 이미 본문 — 바가 포커스 상태가 아님
bar.FOCUS_WAIT = 0.25
t_start = time.monotonic()
run_restore(fz)
el = time.monotonic() - t_start
check("restore_focus: 바가 끝내 포커스를 못 받으면(다른 pane이 포커스) FOCUS_WAIT 안에서 포기, list-clients 재확인만·이동 없음",
      set(fz.calls) == {LC} and len(fz.calls) >= 2 and fz.focus() == 7 and 0.2 <= el < 1.5, "calls=%r el=%.2f" % (fz.calls, el))
bar.FOCUS_WAIT = 2.0
for bad_id in ("", "x"):
    bar.MY_PANE_ID = bad_id
    fz = FakeZellij(RING, 0)
    run_restore(fz)
    eq("restore_focus: ZELLIJ_PANE_ID %r 이면 zellij를 부르지 않음" % bad_id, [], fz.calls)
bar.MY_PANE_ID = "5"

# 클릭 1회 전체 (run_hit): go-to-tab-by-id 앞의 호출 = 클릭 지연, 뒤 = 표시 갱신
RAW_T = [{"position": 0, "name": "alpha", "active": True, "tab_id": 10, "panes_to_hide": 0},
         {"position": 1, "name": "beta", "active": False, "tab_id": 11, "has_bell_notification": True}]
cdh = os.path.join(TMP, "cache-hit")
fz = FakeZellij(RING, 0, raw_tabs=RAW_T)
src = bar.TabSource("sh", cdh, fetch=fz.fetch_tabs, pid=os.getpid())
src.poll(2.1)                                                       # 리더가 한 번 조회해 캐시를 쓴다 (준비)
bar._focus_plan = None
fz.calls = []
patched(fz, bar.run_hit, ("tab", 11), src, os.path.join(TMP, "rows-h"))
eq("(f) 탭 클릭(캐시 미스): list-clients → list-panes → focus-next-pane → list-clients → go-to-tab-by-id, list-tabs 0회",
   [LC, LP, FNP, LC, GOTO], fz.calls)
fz2 = FakeZellij(RING, 0, raw_tabs=RAW_T)
src.fetch = fz2.fetch_tabs
patched(fz2, bar.run_hit, ("tab", 10), src, os.path.join(TMP, "rows-h"))
eq("(f) 탭 클릭(캐시 적중): list-clients → focus-next-pane → list-clients → go-to-tab-by-id (큰 응답 0회, list-tabs 0회)",
   [LC, FNP, LC, GOTO], fz2.calls)
src.fetch = fz.fetch_tabs

# (f) A3 낙관적 갱신
scenario("A3", "탭 클릭 뒤 낙관적 갱신 (mark_active) — rc=0이면 캐시 활성만 고쳐 쓰고, 아니면 refresh_now 폴백")


def cache_active(cf):
    with open(cf, encoding="utf-8") as f:
        return [t["tab_id"] for t in json.load(f) if t.get("active")]


cda = os.path.join(TMP, "cache-a3")
fa3 = FakeZellij(RING, 0, raw_tabs=RAW_T)
la = bar.TabSource("a3", cda, fetch=fa3.fetch_tabs, pid=os.getpid())
fo3 = FakeZellij(RING, 0, raw_tabs=RAW_T)
fo = bar.TabSource("a3", cda, fetch=fo3.fetch_tabs, pid=os.getpid() + 1_000_000)
a0 = time.time()
la.poll(2.1, a0)
fo.poll(2.1, a0)
eq("(준비) 리더 1회 조회·팔로워 0회, 활성 = 10", (1, 0, [10]), (fa3.n(LT), fo3.n(LT), cache_active(la.cache_file)))
pid_file = os.path.join(la.lock_dir, "pid")
pid_before = (open(pid_file).read(), os.stat(pid_file).st_mtime_ns)
with open(la.cache_file, encoding="utf-8") as f:
    raw_before = json.load(f)
bar.MY_PANE_ID = ""                                                 # 포커스 복귀는 위에서 따로 봤다 — 여기선 탭 전환만
fo3.calls = []
patched(fo3, bar.run_hit, ("tab", 11), fo, os.path.join(TMP, "rows-a3"))
eq("(f) rc=0: go-to-tab-by-id만, list-tabs 0회", [GOTO], fo3.calls)
eq("(f) rc=0: 캐시 파일 활성 = 클릭한 탭(11)만", [11], cache_active(fo.cache_file))
eq("(f) rc=0: 팔로워 자신의 탭 목록도 즉시 반영", [False, True], [t["active"] for t in fo.tabs])
with open(fo.cache_file, encoding="utf-8") as f:
    raw_after = json.load(f)
eq("(f) rc=0: active 외 필드(이름·위치·벨·기타 키)는 그대로", [{k: v for k, v in t.items() if k != "active"} for t in raw_before],
   [{k: v for k, v in t.items() if k != "active"} for t in raw_after])
for rc in (1, "timeout"):
    fo3.goto_rc, fo3.calls = rc, []
    patched(fo3, bar.run_hit, ("tab", 10), fo, os.path.join(TMP, "rows-a3"))
    eq("(f) go-to-tab-by-id %s → refresh_now 폴백 (list-tabs 1회, 캐시 = 조회 결과 활성 10)" % ("종료코드 1" if rc == 1 else "시간 초과"),
       ([GOTO, LT], [10]), (fo3.calls, cache_active(fo.cache_file)))
fo3.goto_rc, fo3.calls = 0, []
patched(fo3, bar.run_hit, ("tab", 999), fo, os.path.join(TMP, "rows-a3"))
eq("(f) rc=0이어도 캐시에 그 탭이 없으면 refresh_now 폴백", [GOTO, LT], fo3.calls)
fo3.calls = []
eq("(f) source 없음(레거시)·탭 클릭: 예외 없이 go-to-tab만", (None, [GOTO]), (patched(fo3, bar.run_hit, ("tab", 11), None, os.path.join(TMP, "rows-a3")), fo3.calls))
nuz = bar.TabSource("a3x", os.path.join(blocker, "sub2"), fetch=fo3.fetch_tabs, pid=os.getpid())
eq("(f) 캐시 디렉터리를 못 쓰면 mark_active False (호출자가 refresh_now)", False, nuz.mark_active(11))
cdb = os.path.join(TMP, "cache-a3b")
os.makedirs(cdb)
nb = bar.TabSource("a3b", cdb, fetch=fo3.fetch_tabs, pid=os.getpid())
eq("(f) 캐시 파일이 아직 없으면 mark_active False", False, nb.mark_active(11))
with open(nb.cache_file, "w") as f:
    f.write("{not json")
eq("(f) 캐시 파일이 깨졌으면 mark_active False (예외 없음)", False, nb.mark_active(11))

# (g) 낙관적 갱신이 리더 선출·캐시 규약을 깨지 않음
eq("(g) 팔로워의 mark_active·폴백 뒤에도 리더 pid 파일 내용·mtime 그대로 (하트비트 위조 없음)", pid_before, (open(pid_file).read(), os.stat(pid_file).st_mtime_ns))
eq("(g) 팔로워는 리더가 되지 않음·락 디렉터리 1개", (False, True, 1),
   (fo.is_leader, la.is_leader, len([n for n in os.listdir(cda) if n.endswith(".lock")])))
eq("(g) 임시 파일 잔여 없음 (write_atomic)", [], [n for n in os.listdir(cda) if ".tmp." in n])
fo3.calls = []
patched(fo3, bar.run_hit, ("tab", 11), fo, os.path.join(TMP, "rows-a3"))
eq("(준비) 팔로워 낙관적 갱신 → 캐시 활성 11", [11], cache_active(la.cache_file))
fa3.calls = []
ch = la.poll(2.6, a0 + 0.5)
eq("(g) 리더: 다음 주기 전엔 조회 없이 팔로워가 쓴 캐시를 읽는다 (sig 변화 감지)", (True, [], [False, True]), (ch, fa3.calls, [t["active"] for t in la.tabs]))
la.poll(3.2, a0 + 1.1)
eq("(g) 리더: 1초 주기 조회가 진실(활성 10)로 교정해 캐시에 씀", ([LT], [10]), (fa3.calls, cache_active(la.cache_file)))
fo3.calls = []
fo.poll(3.3, a0 + 1.2)
eq("(g) 팔로워도 교정된 목록을 읽음 (조회 0회)", ([True, False], []), ([t["active"] for t in fo.tabs], fo3.calls))
fa3.calls = []
check("(g) 리더 자신의 mark_active: True", la.mark_active(11))
ch = la.poll(3.4, a0 + 1.3)
eq("(g) 리더: 자기 쓰기는 다시 읽지 않고(sig 기억) 조회 주기도 그대로 (조회 0회)", (False, []), (ch, fa3.calls))
# 죽은 리더 + 팔로워 낙관적 쓰기 → 인수는 그대로 된다
dead2 = subprocess.Popen([sys.executable, "-I", "-c", "pass"])
dead2.wait()
cdz = os.path.join(TMP, "cache-a3z")
zl = bar.TabSource("a3z", cdz, fetch=FakeZellij(RING, 0, raw_tabs=RAW_T).fetch_tabs, pid=dead2.pid)
zl.poll(2.1)
fzz = FakeZellij(RING, 0, raw_tabs=RAW_T)
zf = bar.TabSource("a3z", cdz, fetch=fzz.fetch_tabs, pid=os.getpid())
check("(준비) 죽은 pid가 리더, 팔로워 mark_active 성공", open(zl.pid_file).read().strip() == str(dead2.pid) and zf.mark_active(11))
zf.poll(4.5, time.time() + 2.0)
eq("(g) 팔로워 쓰기로 캐시가 신선해도, 보유자가 죽었으면 캐시 1.5초 뒤 인수·조회", (True, 1), (zf.is_leader, fzz.n(LT)))
zf.close()
bar.MY_PANE_ID = "5"

# ── E2: 조회 실패 백오프가 STALE_SECS보다 길어도 리더 유지 (하트비트) ──────
scenario("E2", "조회 실패 백오프 중 리더 하트비트 — 팔로워가 인수하지 않음")
cd6 = os.path.join(TMP, "cache6")
fl, ff = Fetcher(RAW), Fetcher(RAW)
L = bar.TabSource("s6", cd6, fetch=fl, pid=os.getpid())
F = bar.TabSource("s6", cd6, fetch=ff, pid=os.getpid() + 1_000_000)
b0 = time.time()
L.poll(2.1, b0)
F.poll(2.1, b0)
fl.raw = None
takeovers = 0
tt = 0.5
while tt < 30:                                # 30초 동안 조회 계속 실패 — 백오프 2·4·8·8초…
    L.poll(2.1 + tt, b0 + tt)
    F.poll(2.1 + tt, b0 + tt)
    if F.is_leader:
        takeovers += 1
    tt += 0.4
check("30초 연속 조회 실패(백오프 8초 상한): 팔로워가 한 번도 리더를 인수하지 않음", takeovers == 0 and L.is_leader and ff.calls == 0, "takeovers=%d leader=%s follower_calls=%d" % (takeovers, L.is_leader, ff.calls))
check("백오프가 실제로 STALE_SECS(3초)보다 길었다 (조회 시도 수가 적다: 30초에 10회 이하)", fl.calls <= 10 and L.next_fetch - (b0 + 29.9) > 0, "calls=%d" % fl.calls)
check("실패 중에도 마지막 탭 목록 유지", len(L.tabs or []) == 2 and len(F.tabs or []) == 2)

# ── A: 에이전트 상태 배지 ───────────────────────────────────────────────────
scenario("A", "에이전트 상태 배지 — 우선순위 · 폭 · 옛 캐시 호환 · 상태 파일 읽기 · 리더 주입")


def st_tab(name, state=None, bell=False, active=False, tid=0):
    d = tab(name, active, tid, bell)
    if state is not None:
        d["state"] = state
    return d


eq("배지 우선순위: blocked ! > 벨 * > working ~ > 없음",
   ["!", "!", "*", "*", "~", "", ""],
   [bar.tab_badge(st_tab("a", "blocked")), bar.tab_badge(st_tab("a", "blocked", bell=True)),
    bar.tab_badge(st_tab("a", "working", bell=True)), bar.tab_badge(st_tab("a", "idle", bell=True)),
    bar.tab_badge(st_tab("a", "working")), bar.tab_badge(st_tab("a", "idle")), bar.tab_badge(st_tab("a", ""))])
eq("state 필드가 없는 옛 탭 dict: 벨 없으면 배지 없음 / 벨이면 *", ["", "*"], [bar.tab_badge(st_tab("a")), bar.tab_badge(st_tab("a", bell=True))])
eq("라벨: 상태 배지는 끝 패딩 칸을 대신 차지 — blocked ' alpha!', working ' alpha~', idle ' alpha ' / 벨 ' alpha* ' (+1칸, 예전 그대로)",
   [" alpha!", " alpha~", " alpha ", " alpha* "],
   [bar.tab_label(st_tab("alpha", "blocked")), bar.tab_label(st_tab("alpha", "working")), bar.tab_label(st_tab("alpha", "idle")),
    bar.tab_label(st_tab("alpha", bell=True))])
# (1) 같은 이름·같은 벨 상태에서 idle / working / blocked 라벨 폭이 모두 같다 (벨 없음: 배지 없는 라벨과도 같음)
for nm in ("alpha", "x" * 40, "한글", "", "a" * 14, "한" * 7):
    base = bar.str_width(bar.tab_label(st_tab(nm)))
    wl = [bar.str_width(bar.tab_label(st_tab(nm, sv))) for sv in ("idle", "working", "blocked", "", None)]
    eq("(1) 벨 없음: idle/working/blocked/상태 없음 라벨 폭이 모두 같다 (이름 %r)" % nm[:6], [base] * 5, wl)
    bb = bar.str_width(bar.tab_label(st_tab(nm, None, True)))
    eq("(1) 벨 있음: idle/working/상태 없음 폭이 같고 벨 * 은 예전처럼 +1칸 (이름 %r)" % nm[:6], [base + 1] * 4,
       [bb] + [bar.str_width(bar.tab_label(st_tab(nm, sv, True))) for sv in ("idle", "working", "")])
eq("이름 14칸 자르기 + 상태 배지: 16칸 (배지 없는 라벨과 같음)", 16, bar.str_width(bar.tab_label(st_tab("y" * 40, "blocked"))))
# (3) 벨 + 상태 조합의 우선순위와 라벨 (blocked ! > 벨 * > working ~ > 없음)
combo = [("", False, "", " alpha "), ("idle", False, "", " alpha "), ("working", False, "~", " alpha~"), ("blocked", False, "!", " alpha!"),
         ("", True, "*", " alpha* "), ("idle", True, "*", " alpha* "), ("working", True, "*", " alpha* "), ("blocked", True, "!", " alpha!")]
eq("(3) 벨×상태 8조합: 배지와 라벨 (blocked가 벨을 이기면 라벨은 ' alpha!' 로 벨의 +1칸도 없음)",
   [(b, l) for _, _, b, l in combo], [(bar.tab_badge(st_tab("alpha", sv, bl)), bar.tab_label(st_tab("alpha", sv, bl))) for sv, bl, _, _ in combo])
# 상태가 전혀 없는 탭은 이 기능 이전 구현과 같다 (이름·벨 조합, 정규화 필드, 창 선택)
PRE_REV = os.environ.get("T_PRE_BAR_REV", "86c4ed8")      # 상태 배지 기능 직전 커밋 (cmux-bar의 tab_label·normalize_tabs·plan_tabs 기준)
PRE_BAR = os.path.join(TMP, "pre-feature-cmux-bar")
_gp = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(BAR_PATH)), "show", "%s:bin/cmux-bar" % PRE_REV],
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
if _gp.returncode == 0 and b"def tab_label" in _gp.stdout:
    with open(PRE_BAR, "wb") as _f:
        _f.write(_gp.stdout)
if os.path.exists(PRE_BAR):
    old_a = load(PRE_BAR, "cmux_bar_pre_feature")
    eq("상태 없는 탭: tab_label이 이전 구현과 같다 (벨 유무 × 이름 6종)", True,
       all(old_a.tab_label(tab(nm, False, 1, bl)) == bar.tab_label(st_tab(nm, None, bl)) for nm in ("alpha", "x" * 40, "한글", "", "a" * 14, "한" * 7) for bl in (False, True)))
    raw_old = [{"position": 1, "name": "b\nx", "active": True, "tab_id": 2, "has_bell_notification": True}, {"position": 0, "name": "a", "tab_id": 1}, "junk"]
    proj = lambda m: [(t["name"], t["active"], t["id"], t["bell"]) for t in m.normalize_tabs(raw_old)]
    eq("상태 없는 탭: normalize_tabs의 기존 필드가 이전 구현과 같다", proj(old_a), proj(bar))
    eq("상태 없는 탭: plan_tabs가 이전 구현과 같다 (28탭 × 폭 40~200 × 활성 위치)", True,
       all(old_a.plan_tabs([old_a.str_width(old_a.tab_label(t)) for t in mk_tabs(NAMES28, 5, {5, 9})], a, [w - 3, w - 11])
           == bar.plan_tabs(widths_of(mk_tabs(NAMES28, 5, {5, 9})), a, [w - 3, w - 11]) for w in (40, 80, 120, 200) for a in (0, 13, 27)))
else:
    print("SKIP\t기능 직전 커밋(%s)을 git에서 못 꺼냄 — 상태 없는 탭의 이전 구현 대조 생략" % PRE_REV)

# normalize_tabs — 옛 캐시(필드 없음)·정상·이상 값
n_old = bar.normalize_tabs([{"position": 0, "name": "a", "active": True, "tab_id": 1}, {"position": 1, "name": "b", "tab_id": 2, "has_bell_notification": True}])
eq("정규화: cmux_state 없는 옛 캐시 → state '' (예외 없음)", ["", ""], [t["state"] for t in n_old])
n_new = bar.normalize_tabs([{"position": i, "name": "t%d" % i, "tab_id": i, "cmux_state": v}
                            for i, v in enumerate(("blocked", "working", "idle", "bogus", 5, ["x"], None, {"a": 1}, True))])
eq("정규화: blocked/working/idle만 싣고 이상한 값(문자열·숫자·리스트·None·dict·bool)은 ''", ["blocked", "working", "idle", "", "", "", "", "", ""], [t["state"] for t in n_new])
eq("정규화: 기존 필드(name,active,id,bell)는 그대로", [("a", True, 1, False), ("b", False, 2, True)], [(t["name"], t["active"], t["id"], t["bell"]) for t in n_old])

# 그리기 — 클릭 영역이 라벨 폭과 일치하고, ! 는 빨간 배경 색 쌍·굵게로 덧그려진다 (활성/비활성 모두)
dt = [st_tab("alpha", "blocked", active=True, tid=1), st_tab("beta", "blocked", tid=2), st_tab("gamma", "working", tid=3),
      st_tab("delta", "idle", bell=True, tid=4), st_tab("eps", "idle", tid=5)]
scr = FakeScr(2, 120)
hits = []
bar.draw_strip(scr, 1, dt, False, hits)
th = [h for h in hits if h[3][0] == "tab"]
eq("배지 탭 5개: 클릭 영역 폭 = 라벨 폭", [bar.str_width(bar.tab_label(t)) for t in dt], [h[2] - h[1] + 1 for h in th])
check("배지 탭: 화면 셀이 라벨과 일치 (' alpha! ', ' gamma~ ' …)", all(scr.cells(h[0], h[1], h[2]) == bar.tab_label(dt[h[3][1] - 1]) for h in th), repr(scr.line(0)[:60]))
check("영역들이 겹치지 않고 이어진다 (x0[i+1] = x1[i]+1)", all(th[i + 1][1] == th[i][2] + 1 for i in range(len(th) - 1)), repr([(h[1], h[2]) for h in th]))
bang = [c for c in scr.calls if c[0] == "addstr" and c[3] == "!"]
want_bang = (bar.CP_BLOCKED << 8) | curses.A_BOLD
eq("! 덧그리기 2회 (활성 alpha·비활성 beta) 모두 빨간 배경 쌍 + 굵게", [want_bang, want_bang], [c[4] for c in bang])
eq("! 는 라벨 마지막 칸(끝 패딩 자리)에 덧그린다 = 그 탭 클릭 영역의 마지막 열", [th[0][2], th[1][2]], [c[2] for c in bang])
check("~ 는 덧그리지 않는다 (탭 본래 색 그대로)", not [c for c in scr.calls if c[0] == "addstr" and c[3] == "~"])
star = [c for c in scr.calls if c[0] == "addstr" and c[3] == "*"]
eq("벨 * 덧그리기는 기존 규칙(노란 CP_SESS + 굵게) 그대로", [(bar.CP_SESS << 8) | curses.A_BOLD], [c[4] for c in star])
eq("벨 * 은 예전 위치 그대로 (끝 패딩 공백 앞 칸 = 클릭 영역 마지막 열 - 1)", [th[3][2] - 1], [c[2] for c in star])
check("blocked 배지 색 쌍이 init_colors에 등록됨 (흰 글자·빨간 배경)", "CP_BLOCKED, curses.COLOR_WHITE, curses.COLOR_RED" in open(BAR_PATH, encoding="utf-8").read())

# (2) 탭 20개 · 폭 40~200 · 활성 위치 · 접힘/펼침: 상태(idle/working/blocked/섞임)가 바뀌어도 plan_tabs(lo,hi,줄 배치)와
#     클릭 영역(히트)·그려진 화면 배치가 완전히 같다 (벨 없음) — working↔idle 토글에 탭이 밀리지 않는다
N20 = ["proj-alpha-%02d" % i if i % 4 else "한글프로젝트이름-%02d" % i for i in range(20)]
MIX = ["idle", "working", "blocked"]


def state_tabs(pattern, active, bells=()):
    out = []
    for i, nm in enumerate(N20):
        sv = MIX[i % 3] if pattern == "mixed" else pattern
        out.append(st_tab(nm, sv, i in bells, i == active, 200 + i))
    return out


bad_w, bad_plan, bad_hits, bad_cells, runs = [], [], [], [], 0
for w in (40, 60, 80, 120, 188, 200):
    for rows in (1, 2):
        for act in (0, 7, 19):
            ref = None
            for pat in ("idle", "working", "blocked", "mixed"):
                tt = state_tabs(pat, act)
                widths = [bar.str_width(bar.tab_label(t)) for t in tt]
                plan = bar.plan_tabs(widths, bar.active_index(tt), bar.strip_caps(w, rows))
                scr_ = FakeScr(2, w)
                hh = []
                bar.draw_strip(scr_, rows, tt, False, hh)
                cur = (widths, plan, hh)
                if ref is None:
                    ref = cur
                    continue
                runs += 1
                tag = "w=%d rows=%d act=%d %s" % (w, rows, act, pat)
                if cur[0] != ref[0]:
                    bad_w.append(tag)
                if (cur[1]["lo"], cur[1]["hi"], cur[1]["lines"], cur[1]["left"], cur[1]["right"]) != (ref[1]["lo"], ref[1]["hi"], ref[1]["lines"], ref[1]["left"], ref[1]["right"]):
                    bad_plan.append(tag)
                if cur[2] != ref[2]:
                    bad_hits.append(tag)
                # 화면 셀: 배지 한 칸(끝 패딩 자리)만 다르고 나머지 글자 위치는 같다
                base_scr = FakeScr(2, w)
                bar.draw_strip(base_scr, rows, state_tabs("idle", act), False, [])
                diff = [(y, x) for y in range(2) for x in range(w) if scr_.grid[y][x] != base_scr.grid[y][x]]
                badge_cells = {(y, x1) for (y, x0, x1, a) in hh if a[0] == "tab"}
                if any(c not in badge_cells for c in diff):
                    bad_cells.append(tag)
eq("(2) 탭 20개 × 폭 6종 × 접힘/펼침 × 활성 3곳 × 상태 4패턴: 라벨 폭 목록 동일 (%d회 대조)" % runs, [], bad_w)
eq("(2) plan_tabs 결과(lo, hi, 줄 배치, ‹N N› 위치)가 idle/working/blocked/섞임 사이에서 동일", [], bad_plan)
eq("(2) draw_strip 클릭 영역(히트 목록)이 상태와 무관하게 동일", [], bad_hits)
eq("(2) 화면에서 달라지는 셀은 각 탭 라벨의 마지막 칸(끝 패딩 자리)뿐 — 이름·다른 탭 위치는 안 밀린다", [], bad_cells)
# 벨 있는 탭이 섞여도 idle ↔ working 은 같다 (벨 * 이 이기므로); blocked 만 벨 탭에서 1칸 줄어든다 (! 가 벨을 이김 — 설계 규칙)
wi = [bar.str_width(bar.tab_label(t)) for t in state_tabs("idle", 7, bells={2, 3})]
ww = [bar.str_width(bar.tab_label(t)) for t in state_tabs("working", 7, bells={2, 3})]
eq("(2) 벨 탭이 섞여도 idle ↔ working 라벨 폭 동일", wi, ww)

# 상태 파일 읽기 (read_agent_states)
SD = os.path.join(TMP, "agent-state")
os.environ["CMUX_AGENT_STATE_DIR"] = SD
NOW = 2_000_000


def wf(session, pane, state, ts, tab_name, raw=None):
    d = os.path.join(SD, session.replace("/", "_"))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, str(pane)), "w", encoding="utf-8") as f:
        f.write(raw if raw is not None else "state=%s\nts=%s\ntab=%s\n" % (state, ts, tab_name))


eq("상태 디렉터리 없음 → {} (예외 없음)", {}, bar.read_agent_states("nosuch", NOW))
wf("s1", 1, "working", NOW - 10, "a")
wf("s1", 2, "blocked", NOW - 5, "a")
wf("s1", 3, "working", NOW - 301, "b")
wf("s1", 4, "working", NOW - 300, "c")
wf("s1", 5, "blocked", NOW - bar.ABANDON_SECS - 1, "d")
wf("s1", 6, "idle", NOW - bar.ABANDON_SECS, "e")
wf("s1", 7, "blocked", "x", "f")
wf("s1", 8, "bogus", NOW, "g")
wf("s1", 9, "blocked", NOW, "")
wf("s1", 10, "working", NOW + 100, "h")
wf("s1", 11, "idle", NOW, "a]*b")
wf("s1", 12, "idle", NOW - 5, "a")
wf("s1", "x.tmp", "blocked", NOW, "zz")
wf("s1", 14, "x", 0, "x", raw="not a state file\n")
wf("s1", 15, "working", NOW - 20, "한글·codex")
wf("s1", 16, "blocked", NOW - 1, "w", raw="state=idle\nts=%d\ntab=w\nstate=blocked\n" % (NOW - 1))
want = {"a": "blocked", "b": "idle", "c": "working", "e": "idle", "h": "working", "a]*b": "idle", "한글·codex": "working", "w": "blocked"}
eq("롤업: blocked>working>idle · 300초 넘은 working→idle(300초 정각은 working) · 12시간 넘은 파일 무시 · 이상한 파일·.tmp 무시 · 미래 ts 허용 · 마지막 줄 우선",
   want, bar.read_agent_states("s1", NOW, prune=False))
check("prune=False: 12시간 넘은 파일을 지우지 않는다", os.path.exists(os.path.join(SD, "s1", "5")))
bar.read_agent_states("s1", NOW)
check("prune=True: 12시간 넘은 파일은 삭제, 나머지는 보존", not os.path.exists(os.path.join(SD, "s1", "5")) and os.path.exists(os.path.join(SD, "s1", "6")))
eq("세션 이름의 / 는 _ 로 (cmux-agent-state와 같은 규칙)", os.path.join(SD, "a_b"), bar.agent_state_dir("a/b"))
eq("탭 키: 줄바꿈·CR·TAB만 공백으로", "a b c d", bar.tab_key("a\nb\rc\td"))
eq("env 없으면 $HOME/.config/cmux/agent-state/<세션>", os.path.join(os.environ["HOME"], ".config", "cmux", "agent-state", "q"),
   (lambda: (os.environ.pop("CMUX_AGENT_STATE_DIR"), bar.agent_state_dir("q"))[1])())
os.environ["CMUX_AGENT_STATE_DIR"] = SD

# 리더 주입 — 리더가 list-tabs 직후 상태를 캐시에 싣고, 팔로워는 zellij 호출 0회로 캐시에서 읽는다. 옛 캐시도 읽힌다.
now_i = int(time.time())
wf("s9", 1, "blocked", now_i, "alpha")
wf("s9", 2, "working", now_i, "beta")
RAW9 = [{"position": 0, "name": "alpha", "active": True, "tab_id": 10}, {"position": 1, "name": "beta", "active": False, "tab_id": 11},
        {"position": 2, "name": "gamma", "active": False, "tab_id": 12}]


class CopyFetcher(Fetcher):
    """매번 새 객체를 돌려준다 (실제 list-tabs처럼 — 리더가 결과에 cmux_state를 싣는 것이 원본 RAW9를 오염시키지 않게)."""

    def __call__(self):
        self.calls += 1
        return None if self.raw is None else json.loads(json.dumps(self.raw))


cd9 = os.path.join(TMP, "cache9")
f9l, f9f = CopyFetcher(RAW9), CopyFetcher(RAW9)
L9 = bar.TabSource("s9", cd9, fetch=f9l, pid=os.getpid())
F9 = bar.TabSource("s9", cd9, fetch=f9f, pid=os.getpid() + 1_000_000)
b9 = time.time()
L9.poll(2.1, b9)
F9.poll(2.1, b9)
eq("리더: alpha=blocked, beta=working, gamma(기록 없음)=''", ["blocked", "working", ""], [t["state"] for t in L9.tabs])
eq("팔로워: 조회 0회, 같은 상태를 캐시에서 읽음", (0, ["blocked", "working", ""]), (f9f.calls, [t["state"] for t in F9.tabs]))
cache9 = json.load(open(L9.cache_file, encoding="utf-8"))
eq("캐시 JSON: cmux_state 필드 (기록 없는 탭엔 필드 없음)", ["blocked", "working", None], [t.get("cmux_state") for t in cache9])
check("원본 list-tabs 결과의 다른 필드는 그대로", [{k: v for k, v in t.items() if k != "cmux_state"} for t in cache9] == RAW9)
# 상태가 바뀌면 (다음 리더 조회에서) 캐시가 갱신되고 팔로워가 따라온다
wf("s9", 1, "idle", now_i, "alpha")
os.unlink(os.path.join(SD, "s9", "2"))
L9.poll(3.2, b9 + 1.1)
ch9 = F9.poll(3.2, b9 + 1.1)
eq("상태 변경: 리더·팔로워 모두 반영 (alpha idle, beta 기록 삭제 → '')", (["idle", "", ""], ["idle", "", ""], True),
   ([t["state"] for t in L9.tabs], [t["state"] for t in F9.tabs], ch9))
# 옛 캐시(cmux_state 없음)를 읽는 팔로워
cd10 = os.path.join(TMP, "cache10")
old_cache = bar.cache_paths(cd10, "s10")[0]
os.makedirs(cd10, mode=0o700, exist_ok=True)
json.dump(RAW9, open(old_cache, "w", encoding="utf-8"))
F10 = bar.TabSource("s10", cd10, fetch=Fetcher(None), pid=os.getpid() + 2_000_000)
F10.poll(2.1, time.time())
eq("옛 캐시(필드 없음): 예외 없이 읽고 state ''", ["", "", ""], [t["state"] for t in (F10.tabs or [])])
# mark_active(탭 이동 낙관적 갱신)가 캐시의 cmux_state를 지우지 않는다
L9.mark_active(11)
eq("mark_active 뒤에도 cmux_state 유지", ["idle", None, None], [t.get("cmux_state") for t in json.load(open(L9.cache_file, encoding="utf-8"))])
# 상태 읽기가 예외를 내도 탭 줄은 계속
orig_read = bar.read_agent_states
bar.read_agent_states = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
fx = CopyFetcher(RAW9)
LX = bar.TabSource("s11", os.path.join(TMP, "cache11"), fetch=fx, pid=os.getpid())
raises_nothing("상태 읽기 예외 → 탭 목록은 그대로 갱신", lambda: LX.poll(2.1, time.time()))
eq("상태 읽기 예외: 탭 3개 (state '')", ["", "", ""], [t["state"] for t in (LX.tabs or [])])
bar.read_agent_states = orig_read
os.environ.pop("CMUX_AGENT_STATE_DIR", None)

scenario("Z", "안전장치 — 이 시험 전체에서 실제 zellij 호출 0회")
eq("실제 zellij 호출(가짜로 바꾸지 않은 경로) 0회", [], REAL_ZELLIJ)
