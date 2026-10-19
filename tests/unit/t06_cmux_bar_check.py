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
eq("파일 없음 → 1", 1, bar.read_rows(sf))
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
eq("상위 디렉터리가 없어도 토글이 만든다", 2, bar.toggle_rows(nested))
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
eq("run_hit(toggle) → 2", 2, bar.run_hit(("toggle", None), None, sf2))
eq("run_hit(toggle) 한 번 더 → 1", 1, bar.run_hit(("toggle", None), None, sf2))

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

# restore_focus: focus-next-pane을 목표 pane이 포커스될 때까지 반복 (focus-pane-id는 click-through에서 실제 포커스를 못 옮김, 실측)
# 클릭 직후 자기 pane이 아직 포커스가 없으면 기다렸다가 복귀 / 끝내 없으면 아무것도 안 함
class FakeZellij:
    """탭 하나의 pane 고리 [(id, title, x, y)] 와 포커스 인덱스를 가진 가짜 zellij."""

    def __init__(self, ring, focus_idx, focus_after_polls=0):
        self.ring, self.idx, self.polls, self.focus_after = ring, focus_idx, 0, focus_after_polls
        self.actions = []

    def json(self, args, timeout):
        self.polls += 1
        out = []
        for i, (pid, title, x, y) in enumerate(self.ring):
            foc = (i == self.idx) and not (pid == 5 and self.polls <= self.focus_after)
            out.append(pane(pid, title, x, y, focused=foc))
        return out

    def run(self, cmd, **kw):
        self.actions.append(cmd[2:])
        if cmd[2:] == ["focus-next-pane"]:
            self.idx = (self.idx + 1) % len(self.ring)


real_json, real_run = bar._zellij_json, bar.subprocess.run
bar.MY_PANE_ID, bar.FOCUS_WAIT = "5", 2.0


def run_restore(fz):
    bar._zellij_json, bar.subprocess.run = fz.json, fz.run
    try:
        bar.restore_focus()
    finally:
        bar._zellij_json, bar.subprocess.run = real_json, real_run


fz = FakeZellij([(5, "bar", 0, 1), (7, "claude", 0, 4), (8, "files", 122, 4), (6, "terminal", 122, 27)], 0)
run_restore(fz)
eq("restore_focus: 바 다음이 claude → focus-next-pane 1회, 포커스 = claude(7)", ([["focus-next-pane"]], 7), (fz.actions, fz.ring[fz.idx][0]))
fz = FakeZellij([(5, "bar", 0, 1), (6, "terminal", 122, 27), (7, "claude", 0, 4)], 0)
run_restore(fz)
eq("restore_focus: 목표가 두 칸 뒤면 focus-next-pane 2회 → claude(7)", ([["focus-next-pane"]] * 2, 7), (fz.actions, fz.ring[fz.idx][0]))
fz = FakeZellij([(5, "bar", 0, 1), (7, "claude", 0, 4), (8, "files", 122, 4)], 0, focus_after_polls=3)
run_restore(fz)
eq("restore_focus: 클릭 직후 포커스가 늦게 와도(click-through) 기다렸다가 복귀 (조회 3회 이상, 이동 1회)", (True, [["focus-next-pane"]], 7), (fz.polls >= 4, fz.actions, fz.ring[fz.idx][0]))
fz = FakeZellij([(5, "bar", 0, 1), (7, "claude", 0, 4)], 1)           # 포커스가 이미 본문 — 바가 포커스 상태가 아님
bar.FOCUS_WAIT = 0.25
t_start = time.monotonic()
run_restore(fz)
el = time.monotonic() - t_start
check("restore_focus: 바가 끝내 포커스를 못 받으면(다른 pane이 포커스) FOCUS_WAIT 안에서 포기, 아무 동작도 안 함", fz.actions == [] and fz.ring[fz.idx][0] == 7 and 0.2 <= el < 1.5, "actions=%r el=%.2f" % (fz.actions, el))
bar.FOCUS_WAIT = 2.0
calls = {"n": 0}
bar._zellij_json = lambda a, t: (calls.__setitem__("n", calls["n"] + 1) or None)
bar.restore_focus()
check("restore_focus: 조회 실패(None)면 기다리지 않고 조용히 끝남", calls["n"] == 1)
bar.MY_PANE_ID = ""
calls["n"] = 0
bar.restore_focus()
check("restore_focus: ZELLIJ_PANE_ID 없으면 zellij를 부르지 않음", calls["n"] == 0)
bar._zellij_json, bar.subprocess.run = real_json, real_run

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
