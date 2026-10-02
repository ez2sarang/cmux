#!/usr/bin/env python3
"""t91_live_restore — 라이브 zellij 세션을 종료하고 `cmux -k`로 복원되는지 직접 확인하는 수동 E2E.

  verify  읽기 전용: 지금 떠 있는 세션의 탭·에이전트 프로세스를 탭 기록·transcript 오라클과 대조
  run     세션 서버 종료(재부팅 모사) → `cmux -k`(가상 터미널) → 복원 검증 → (선택) 이어쓰기 프롬프트 주입 → 리포트
          --dry-run 이면 종료·복원 없이 나머지 단계만 현재 상태로 연습한다. 세션 `claude`는 --yes 없이는 종료하지 않는다.
          --daemonize 로 띄우면 터미널·zellij가 죽어도 살아남아 끝까지 진행한다(이 스크립트를 실행한 pane도 같이 죽는다).

안전 규칙: 세션명은 claude 또는 cmuxt<숫자>만. 서버 PID는 명령줄(zellij --server …/<세션>)로 확정하고
--expect-server-pid 와 일치해야 한다(실제 종료 시 필수). 이 프로세스가 서버의 자손이면 --daemonize 없이는 종료하지 않는다.
환경변수는 값을 출력하지 않는다. 표준 라이브러리만 사용(Python 3.9).
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PTYRUN = os.path.join(REPO, "tests", "lib", "ptyrun.py")
HOME = os.path.expanduser("~")
TABS_DEFAULT = os.path.join(HOME, ".config/cmux/session-tabs")
PROJECT_AGENTS = os.path.join(HOME, ".config/cmux/project-agents")
KNOWN_AGENTS = ("claude", "codex", "opencode")
SESSION_RE = re.compile(r"^(claude|cmuxt[0-9]+)$")
UI_RE = re.compile(r"bypass permissions|\? for shortcuts|shift\+tab to cycle|esc to interrupt")
ENTRY_RE = re.compile(r'"entrypoint"\s*:\s*"([^"]*)"')
CACHE_ROOT = os.path.join(HOME, "Library/Caches/org.Zellij-Contributors.Zellij/contract_version_1/session_info")
NOISE_ENV = {"_", "dyld_file", "executable_boothash", "executable_cdhash", "executable_file", "executable_path",
             "main_stack", "ptr_munge", "security_config", "th_port"}


def run(cmd, env=None, timeout=15):
    """시간 제한 래퍼 — 멈춘 zellij 호출이 스크립트를 붙잡지 못하게 한다. 시간 초과 rc=124.
    출력은 바이트로 받아 UTF-8 replace 디코딩 — ps 명령줄 등의 비UTF-8 바이트로 예외가 나지 않게 한다."""
    try:
        r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError as e:
        return 127, str(e)


def md5(path):
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except OSError:
        return None


def procargs(pid):
    """macOS KERN_PROCARGS2 → (argv, env 딕셔너리). 값은 호출자가 출력하지 않는다."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, int(pid))
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buf.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:]
    _, _, rest = rest.partition(b"\0")
    rest = rest.lstrip(b"\0")
    parts = [p.decode("utf-8", "replace") for p in rest.split(b"\0")]
    argv = parts[:argc]
    env = {}
    for e in parts[argc:]:
        if e == "":
            break  # envp 끝 — 그 뒤는 커널이 붙이는 apple 문자열
        k, _, v = e.partition("=")
        if k and k not in NOISE_ENV:
            env[k] = v
    return argv, env


def ps_table():
    rc, out = run(["ps", "-axo", "pid=,ppid=,command="], timeout=20)
    table = {}
    for line in out.splitlines():
        t = line.split(None, 2)
        if len(t) == 3 and t[0].isdigit() and t[1].isdigit():
            table[int(t[0])] = (int(t[1]), t[2])
    return table


def find_servers(session, table):
    res = []
    for pid, (_, cmd) in table.items():
        t = cmd.split()
        if len(t) >= 3 and os.path.basename(t[0]) == "zellij" and t[1] == "--server" and os.path.basename(t[2]) == session:
            res.append(pid)
    return sorted(res)


def descendants(root, table):
    kids = {}
    for pid, (ppid, _) in table.items():
        kids.setdefault(ppid, []).append(pid)
    out, stack = set(), [root]
    while stack:
        for k in kids.get(stack.pop(), []):
            if k not in out:
                out.add(k)
                stack.append(k)
    return out


def alive(pid, cmd=None):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    if cmd is None:
        return True
    rc, out = run(["ps", "-p", str(pid), "-o", "command="], timeout=5)
    return rc == 0 and out.strip() == cmd


def kill(pid, sig):
    """os.kill 래퍼 — 대상이 이미 없거나(ProcessLookupError) 권한이 없으면(PermissionError) False. 예외를 전파하지 않는다."""
    try:
        os.kill(pid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def cwds(pids):
    if not pids:
        return {}
    rc, out = run(["lsof", "-a", "-d", "cwd", "-Fpn", "-p", ",".join(str(p) for p in pids)], timeout=30)
    res, cur = {}, None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            cur = int(line[1:])
        elif line.startswith("n") and cur is not None:
            res[cur] = line[1:]
    return res


def zj(env, session, *args, **kw):
    return run(["zellij", "-s", session, "action"] + list(args), env=env, timeout=kw.get("timeout", 8))


def tab_names(env, session):
    rc, out = zj(env, session, "query-tab-names")
    if rc != 0:
        return None
    return [n for n in out.split("\n") if n != ""]


def client_count(env, session):
    """`list-clients` 헤더 제외 행 수 — 조회 실패면 None."""
    rc, out = zj(env, session, "list-clients")
    if rc != 0:
        return None
    return len([l for l in out.splitlines()[1:] if l.strip()])


def load_specs(tabs_file):
    """탭 기록 → [(경로, 에이전트)]. 읽기 실패·UTF-8 아님이면 None (빈 목록과 구분 — 호출자가 중단)."""
    specs, seen = [], set()
    try:
        with open(tabs_file, encoding="utf-8") as f:
            data = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    for line in data.split("\n"):
        if not line:
            continue
        p, a = line, "claude"
        if "\t" in line:
            head, tail = line.rsplit("\t", 1)
            if tail in KNOWN_AGENTS:
                p, a = head, tail
        if not os.path.isdir(p) or (p, a) in seen:
            continue
        seen.add((p, a))
        specs.append((p, a))
    return specs


def tab_name(path, agent):
    base = os.path.basename(path.rstrip("/")) or path
    return base if agent == "claude" else base + "·" + agent


def is_sdk_cli(fp):
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= 30:
                    break
                m = ENTRY_RE.search(line)
                if m:
                    return m.group(1) == "sdk-cli"
    except OSError:
        pass
    return False


def oracle_history(path, cfgdir):
    """cmux와 독립 구현 — 폴더 키(논리·물리 경로)를 대소문자 무시로 찾고, sdk-cli 아닌 jsonl이 있으면 이력 있음."""
    proj = os.path.join(cfgdir, "projects")
    try:
        entries = os.listdir(proj)
    except OSError:
        return False, "projects 폴더 없음"
    keys = set(re.sub(r"[^A-Za-z0-9]", "-", p) for p in (path, os.path.realpath(path)))
    for key in sorted(keys):
        for d in [e for e in entries if e.lower() == key.lower()]:
            try:
                files = sorted(f for f in os.listdir(os.path.join(proj, d)) if f.endswith(".jsonl"))
            except OSError:
                continue
            for f in files:
                if not is_sdk_cli(os.path.join(proj, d, f)):
                    return True, d + "/" + f[:8]
    return False, "비-sdk-cli 세션 없음"


def pane_agents(server, table, agent_bin):
    """탭의 에이전트 프로세스 — 서버 직계(옛 exec 방식) 또는 `cmux launch` 자식(새 방식). `-p`/`--print` 보조 호출 제외."""
    out = []
    for pid in descendants(server, table):
        ppid, cmd = table[pid]
        argv = cmd.split()
        if not argv or argv[0] != agent_bin or "-p" in argv or "--print" in argv:
            continue
        pcmd = table.get(ppid, (0, ""))[1].split()
        if ppid == server or ("launch" in pcmd and any(os.path.basename(x) == "cmux" for x in pcmd)):
            out.append((pid, argv))
    return sorted(out)


def same_dir(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def evaluate(session, server, env, specs, cfgdir, agent_bin, baseline=None, oracle=None):
    """현재 상태를 기록·오라클과 대조 → (rows, names, procs, checks). oracle={경로: (이력, 사유)}가 있으면 재계산하지 않고 그 값을 쓴다."""
    rows = []
    for p, a in specs:
        if a != "claude":
            hist, why = None, "claude 외 에이전트는 이번 검증 범위 밖"
        elif oracle is not None and p in oracle:
            hist, why = oracle[p]
        else:
            hist, why = oracle_history(p, cfgdir)
        rows.append({"path": p, "agent": a, "name": tab_name(p, a), "history": hist, "why": why})
    table = ps_table()
    procs = pane_agents(server, table, agent_bin) if server else []
    cw = cwds([p for p, _ in procs])
    names = tab_names(env, session)
    checks = []
    exp_names = [r["name"] for r in rows]
    checks.append(("탭 이름·순서 = 탭 기록", names == exp_names, "%s탭 / 기록 %s개" % (len(names) if names is not None else "조회 실패", len(exp_names))))
    claimed = set()
    for r in rows:
        if r["agent"] != "claude":
            r["proc"] = None
            continue
        hit = [(pid, argv) for pid, argv in procs if pid in cw and same_dir(cw[pid], r["path"])]
        r["proc"] = hit[0] if len(hit) == 1 else None
        claimed.update(pid for pid, _ in hit)
        ok1 = len(hit) == 1
        checks.append(("%s: 에이전트 프로세스 정확히 1개" % r["name"], ok1, "%d개" % len(hit)))
        if ok1:
            argv = hit[0][1]
            has_c = "--continue" in argv
            checks.append(("%s: --continue %s (이력 %s)" % (r["name"], "있음" if has_c else "없음", "있음" if r["history"] else "없음"),
                           has_c == bool(r["history"]), " ".join(argv[1:])))
            if baseline is not None and r["path"] in baseline:
                checks.append(("%s: 인자 = 종료 전(옛 cmux)과 동일" % r["name"], argv[1:] == baseline[r["path"]],
                               " ".join(argv[1:]) + " ← " + " ".join(baseline[r["path"]])))
    extra = [pid for pid, _ in procs if pid not in claimed]
    checks.append(("탭 기록에 없는 에이전트 프로세스 0개", not extra, "%s" % extra))
    return rows, names, procs, checks


def show(checks):
    ok = sum(1 for _, v, _ in checks if v)
    for label, v, detail in checks:
        print("  [%s] %s — %s" % ("OK" if v else "FAIL", label, detail))
    print("  => %d/%d" % (ok, len(checks)))
    return ok == len(checks)


def base_env(server):
    pa = procargs(server) if server else None
    src = pa[1] if pa else dict(os.environ)
    return {k: v for k, v in src.items() if not k.startswith("ZELLIJ")}


def claude_bin_from_cmux(env, cmux):
    """cmux가 실제로 쓰는 claude 경로 — `cmux -h`의 'Claude:' 줄. PATH의 which는 cmux 선택과 다를 수 있다(nvm 등)."""
    rc, out = run([cmux, "-h"], env=env, timeout=15)
    m = re.search(r"^Claude:\s+(\S+)", out, re.M)
    return m.group(1) if m else "/opt/homebrew/bin/claude"


def cmd_verify(a):
    table = ps_table()
    servers = find_servers(a.session, table)
    if len(servers) != 1:
        print("서버 %d개 — 중단" % len(servers))
        return 2
    env = base_env(servers[0])
    a.agent_bin = a.agent_bin or claude_bin_from_cmux(env, os.path.join(HOME, ".local/bin/cmux"))
    cfgdir = env.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
    specs = load_specs(a.tabs_file)
    if specs is None:
        print("탭 기록 읽기 실패(없음·권한·UTF-8 아님): %s — 중단" % a.tabs_file)
        return 2
    rows, names, procs, checks = evaluate(a.session, servers[0], env, specs, cfgdir, a.agent_bin)
    print("서버 PID %d · 탭 기록 %d개 · 에이전트 프로세스 %d개" % (servers[0], len(specs), len(procs)))
    ok = show(checks)
    if a.json:
        json.dump({"rows": [{k: v for k, v in r.items() if k != "proc"} for r in rows], "names": names}, open(a.json, "w"), ensure_ascii=False, indent=1)
    return 0 if ok else 1


# ── run ──────────────────────────────────────────────────
def daemonize(logpath):
    pid = os.fork()
    if pid > 0:
        os.waitpid(pid, 0)
        return False
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    # setsid+2차 fork 손자는 제어 터미널이 없어 HUP을 받지 않으며, SIG_IGN은 exec 후에도 상속되므로(zellij 서버·claude까지) 설정하지 않는다.
    fd = os.open(logpath, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    dn = os.open(os.devnull, os.O_RDONLY)
    os.dup2(dn, 0)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.closerange(3, 256)
    return True


def reset_child_signals():
    # ptyrun 자식(exec 전): 런처(nohup 등)가 물려준 SIG_IGN·신호 마스크는 exec 후에도 상속돼 복원된 zellij·claude까지 내려가므로 기본값으로 되돌린다.
    for s in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU):
        signal.signal(s, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, [])


class Run(object):
    def __init__(self, a):
        self.a = a
        self.out = a.out
        self.t = {}
        self.steps = []   # (단계, 판정, 상세)
        self.checks_post = []
        self.t_start = time.time()
        self.busy = None          # 종료 직전 작업 중으로 추정된 탭 이름 (정보용)
        self.pa_before = "미기록"  # project-agents md5 앞 8자 / "없음"

    def log(self, msg):
        print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)

    def step(self, name, ok, detail=""):
        detail = str(detail)
        if len(detail) > 500:  # 예외 repr에 명령 출력 전체가 실려 리포트가 수 MB가 되는 것 방지
            detail = detail[:500] + "…(+%d자)" % (len(detail) - 500)
        self.steps.append((name, ok, detail))
        self.log("%s %s — %s" % ("OK  " if ok else ("WARN" if ok is None else "FAIL"), name, detail))

    def report(self, final=False):
        L = ["# cmux 라이브 실복원 리포트", "", "- 시작: %s · 세션 `%s` · %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.t_start)), self.a.session, "DRY-RUN" if self.a.dry_run else "실제 종료·복원"),
             "- 상태: %s" % ("**종료 (FINAL)**" if final else "진행 중 — FINAL 표시가 나올 때까지 다시 읽을 것")]
        if self.busy is not None:
            L.append("- 종료 시점 작업 중 탭(자식 caffeinate/sleep/셸 -c 기준 추정, 차단 안 함): %s" % (", ".join(self.busy) or "없음"))
        L.append("")
        L += ["## 단계", "", "| 단계 | 판정 | 상세 |", "|---|---|---|"]
        for n, ok, d in self.steps:
            L.append("| %s | %s | %s |" % (n, "PASS" if ok else ("WARN" if ok is None else "**FAIL**"), d.replace("|", "/")))
        if self.checks_post:
            L += ["", "## 복원 후 탭별 검증 (오라클 = transcript 직접 파싱, 기준 = 종료 전 옛 cmux 인자)", "", "| 항목 | 판정 | 상세 |", "|---|---|---|"]
            for l, v, d in self.checks_post:
                L.append("| %s | %s | %s |" % (l, "PASS" if v else "**FAIL**", d.replace("|", "/")))
        if self.t:
            L += ["", "## 소요 시간(초)", "", "| 구간 | 초 |", "|---|---|"] + ["| %s | %.1f |" % (k, v) for k, v in self.t.items()]
        L += ["", "## 롤백", "", "`~/.config/cmux/backup-20261001/ROLLBACK.txt` · 탭 기록 백업 `session-tabs.pre-restore-test`", ""]
        pa_now = (md5(PROJECT_AGENTS) or "없음")[:8]
        L += ["## 사용자 조치", "",
              "- " + ("DRY-RUN — 종료하지 않았으므로 조치 없음" if self.a.dry_run else
                      "Ghostty 등 기존 터미널의 zellij 클라이언트는 끊긴다 — 프롬프트에서 `cmux` 입력"),
              "- `~/.config/cmux/project-agents`: 종료 전 %s → 리포트 작성 시점 %s (%s)" % (
                  self.pa_before, pa_now, "비교 불가" if self.pa_before == "미기록" else
                  ("변경 없음" if pa_now == self.pa_before else "**생성·변경됨 — 확인 필요**")), ""]
        with open(os.path.join(self.out, "REPORT.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(L) + "\n")


def screen_has_ui(env, session, name, tmpdir):
    """탭 화면에 에이전트 UI 표식이 있는지 → (판정, 사유, 화면 전체 텍스트). 표식은 비어 있지 않은 마지막 4줄에서만 찾는다."""
    rc, _ = zj(env, session, "go-to-tab-name", name)
    if rc != 0:
        return None, "탭 이동 실패 rc=%s" % rc, ""
    time.sleep(0.5)
    fp = os.path.join(tmpdir, "screen.txt")
    if os.path.exists(fp):
        os.remove(fp)
    rc, _ = zj(env, session, "dump-screen", fp)
    if rc != 0 or not os.path.exists(fp):
        return None, "dump-screen 실패 rc=%s" % rc, ""
    with open(fp, encoding="utf-8", errors="replace") as f:
        text = f.read()
    os.remove(fp)
    tail = [l for l in text.splitlines() if l.strip()][-4:]  # 대화 이력 속 같은 문자열 오탐 방지 — 입력창·상태줄 쪽만
    m = UI_RE.search("\n".join(tail))
    return (m is not None), (m.group(0) if m else "에이전트 UI 표식 없음(마지막 4줄)"), text


def cmd_run(a):
    if not SESSION_RE.match(a.session):
        print("허용되지 않는 세션명:", a.session)
        return 2
    if not a.dry_run and (a.session != "claude" or os.path.abspath(os.path.expanduser(a.tabs_file)) != TABS_DEFAULT):
        print("실제 종료는 세션 claude + 기본 탭 기록(%s)에서만 허용 — 이 스크립트는 cmux -k에 CMUX_SESSION/CMUX_TABS_FILE을 넘기지 않아 "
              "다른 세션·탭 기록 지정 시 라이브 claude를 죽일 수 있음 (지정: 세션 %s · 탭 기록 %s) — 아무것도 하지 않음" % (TABS_DEFAULT, a.session, a.tabs_file))
        return 2
    if a.session == "claude" and not a.dry_run and not a.yes:
        print("라이브 세션 종료는 --yes 필요")
        return 2
    if not a.dry_run and not a.expect_server_pid:
        print("실제 종료는 --expect-server-pid 필수 (verify 출력의 서버 PID) — 아무것도 하지 않음")
        return 2
    if not a.dry_run and not a.daemonize:
        # 자손 여부 판정(ps)에 기대지 않고 무조건 요구한다 — ps 실패·이중 fork 우회로 가드가 풀리면 서버를 죽인 뒤 복원에 도달하지 못한다
        print("실제 종료는 --daemonize 필수 — 서버(PID %s)를 죽이면 터미널·pane에 묶인 스크립트도 같이 죽어 복원(cmux -k)에 도달하지 못함 — 아무것도 하지 않음" % a.expect_server_pid)
        return 2
    os.makedirs(a.out, exist_ok=True)
    if a.daemonize:
        info = os.path.join(a.out, "helper.log")
        if not daemonize(info):
            print("데몬 시작 — 로그 %s · 리포트 %s/REPORT.md" % (info, a.out))
            return 0
    R = Run(a)
    rc = 1
    try:
        rc = do_run(R)
    except Exception as e:  # 마지막 방어선 — 실패도 리포트에 남긴다
        import traceback
        R.step("스크립트 예외", False, repr(e))
        tb = traceback.format_exc().splitlines()[-40:]  # 마지막 40줄 · 줄당 300자
        R.log("\n".join(l if len(l) <= 300 else l[:300] + "…(+%d자)" % (len(l) - 300) for l in tb))
    R.report(final=True)
    open(os.path.join(a.out, "DONE"), "w").write("rc=%s\n" % rc)
    R.log("FINAL rc=%s" % rc)
    return rc


def do_run(R):
    a = R.a
    sess = a.session
    table = ps_table()
    servers = find_servers(sess, table)
    if len(servers) != 1 or (a.expect_server_pid and servers[0] != a.expect_server_pid):
        R.step("서버 확정", False, "서버 %s (기대 %s) — 아무것도 종료하지 않음" % (servers, a.expect_server_pid))
        return 2
    server = servers[0]
    pa = procargs(server)  # run 모드는 os.environ 폴백 금지
    if not pa:
        R.step("서버 확정·환경 캡처", False, "PID %d 환경 읽기(procargs) 실패 — 아무것도 종료하지 않음" % server)
        return 2
    env = {k: v for k, v in pa[1].items() if not k.startswith("ZELLIJ")}
    a.agent_bin = a.agent_bin or claude_bin_from_cmux(env, a.cmux)
    R.step("에이전트 실행 파일(cmux -h 기준)", os.path.exists(a.agent_bin), a.agent_bin)
    sensitive = [k for k in env if k.startswith(("CLAUDE", "ANTHROPIC", "OMC"))]
    R.step("서버 확정·환경 캡처", "TMPDIR" in env and not sensitive,
           "PID %d · env %d개(값 비공개) · TMPDIR %s · CLAUDE/ANTHROPIC/OMC 이름 %s" % (server, len(env), "있음" if "TMPDIR" in env else "없음", sensitive or "없음"))
    cfgdir = env.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
    specs = load_specs(a.tabs_file)
    if specs is None:
        R.step("탭 기록", False, "읽기 실패(없음·권한·UTF-8 아님) — 아무것도 종료하지 않음")
        return 2
    R.step("탭 기록", len(specs) > 0, "%d개 (md5 %s)" % (len(specs), (md5(a.tabs_file) or "?")[:8]))
    if not specs:
        return 2
    tabs_md5 = md5(a.tabs_file)
    guard_files = {p: md5(os.path.expanduser(p)) for p in ("~/.config/zellij/config.kdl", "~/.config/cmux/projects")}
    layout_kdl = os.path.expanduser("~/.config/zellij/layouts/cmux-session.kdl")
    layout_before = md5(layout_kdl)

    rows0, names0, procs0, checks0 = evaluate(sess, server, env, specs, cfgdir, a.agent_bin)
    base = {r["path"]: r["proc"][1][1:] for r in rows0 if r.get("proc")}
    R.step("종료 전 상태", None if not all(v for _, v, _ in checks0) else True,
           "탭 %s개 · 에이전트 %d개 · 종료 전 점검 %d/%d" % (len(names0 or []), len(procs0), sum(1 for _, v, _ in checks0 if v), len(checks0)))
    old_tree = {pid: table[pid][1] for pid in descendants(server, table)}
    old_tree.pop(os.getpid(), None)   # 이 스크립트와 부모(셸)는 정리 대상에서 제외
    old_tree.pop(os.getppid(), None)
    server_cmd = table[server][1]
    log_path = os.path.join(env.get("TMPDIR") or "/tmp", "zellij-%d" % os.getuid(), "zellij-log", "zellij.log")
    panic0 = count_panics(log_path)
    # 종료 직전 작업 중 탭(정보용, 차단 안 함): claude pane 프로세스의 자식에 caffeinate/sleep/셸 -c가 있으면 작업 중으로 추정
    kids = {}
    for pid, (ppid, cmd) in ps_table().items():
        kids.setdefault(ppid, []).append(cmd.split())
    R.busy = [r["name"] for r in rows0 if r.get("proc") and any(
        c and (os.path.basename(c[0]) in ("caffeinate", "sleep") or
               (os.path.basename(c[0]).lstrip("-") in ("zsh", "bash", "sh") and "-c" in c[1:]))
        for c in kids.get(r["proc"][0], []))]
    R.pa_before = (md5(PROJECT_AGENTS) or "없음")[:8]
    R.report()

    if a.dry_run:
        R.step("DRY-RUN", True, "종료·복원 생략 — 현재 상태로 검증 단계만 연습")
        R.checks_post = checks0
        return 0 if all(v for _, v, _ in checks0) else 1

    R.log("종료까지 %ss 대기" % a.delay)
    time.sleep(a.delay)
    pre = [("TMPDIR", "TMPDIR" in env), ("CLAUDE/ANTHROPIC/OMC 이름 없음", not sensitive), ("에이전트 실행 파일", os.path.exists(a.agent_bin)),
           ("cmux 실행 가능", os.access(a.cmux, os.X_OK)), ("ptyrun.py", os.path.exists(PTYRUN))]
    bad = [n for n, v in pre if not v]
    if bad:
        R.step("종료 사전조건", False, "미충족 %s — 아무것도 종료하지 않음" % bad)
        return 2
    # ── 1) 서버 종료 (재부팅 모사: SIGTERM → 안 죽으면 SIGKILL)
    if not alive(server, server_cmd):
        R.step("서버 종료", False, "대기 중 서버가 이미 사라지거나 명령줄이 바뀜 — 중단")
        return 2
    # 오라클 폴백 = 종료 전 값. 아래에서 종료 후·cmux -k 전 값으로 고정하고, 복원 후에는 재계산하지 않는다.
    oracle = oracle0 = {r["path"]: (r["history"], r["why"]) for r in rows0 if r["agent"] == "claude"}
    t0 = time.time()
    kill(server, signal.SIGTERM)
    # 신호 이후 cmux -k 실행 직전까지는 무슨 예외가 나도 복원에 도달한다 — 의도한 중단은 '서버 미종료'·'다른 서버 이미 존재'뿐
    gone = False
    try:
        for _ in range(120):
            if not alive(server, server_cmd):
                break
            time.sleep(0.1)
        else:
            kill(server, signal.SIGKILL)
            end = time.time() + 10  # SIGKILL 후 최대 10초 폴링
            while time.time() < end and alive(server, server_cmd):
                time.sleep(0.2)
        gone = not alive(server, server_cmd)
    except Exception as e:
        gone = not kill(server, 0)  # 확인 자체가 실패 — 신호 0 탐침(대상 없음이면 종료됨)
        R.step("서버 종료 대기 예외", None, "%r — 신호 0 탐침 결과 종료=%s" % (e, gone))
    R.t["서버 종료"] = time.time() - t0
    try:  # 여기서 무슨 예외가 나도 cmux -k(복원)에는 반드시 도달한다
        # 옛 pane 프로세스 정리 대기 (PID·명령줄이 그대로인 것만 신호) — 벽시계 20초 마감, 반복마다 ps 1회로 생존 판정
        end = time.time() + 20
        while True:
            t = ps_table()
            left = [p for p, c in old_tree.items() if t.get(p, (0, None))[1] == c]
            if not left or time.time() >= end:
                break
            time.sleep(0.5)
        killed = set()
        for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 10)):  # SIGKILL 후 최대 10초 폴링
            t = ps_table()
            for p in left:
                if t.get(p, (0, None))[1] == old_tree[p] and kill(p, sig):
                    killed.add(p)
            end = time.time() + wait
            while True:
                t = ps_table()
                left = [p for p in left if t.get(p, (0, None))[1] == old_tree[p]]
                if not left or time.time() >= end:
                    break
                time.sleep(0.3)
        kb = {}  # 직접 정리한 프로세스 — 명령 basename별 집계(탭 추정 없음)
        for p in killed:
            n = os.path.basename((old_tree[p].split() or ["?"])[0])
            kb[n] = kb.get(n, 0) + 1
        R.step("라이브 서버 종료", gone and not left, "PID %d 종료 %.1fs · 옛 pane 프로세스 %d개 중 직접 정리 %d개(%s) · 잔존 %d개" % (
            server, R.t["서버 종료"], len(old_tree), len(killed), ", ".join("%s×%d" % kv for kv in sorted(kb.items())) or "없음", len(left)))
        rc, out = run(["zellij", "list-sessions", "--no-formatting"], env=env, timeout=10)
        still = [l for l in out.splitlines() if re.match(r"^%s( |$)" % re.escape(sess), l)]
        R.step("종료 직후 zellij 세션 목록", not still or all("EXITED" in l for l in still), "%s" % (still or "없음"))
        R.step("탭 기록 불변", md5(a.tabs_file) == tabs_md5, "종료 후 md5 %s" % (md5(a.tabs_file) or "?")[:8])
        oracle = {p: oracle_history(p, cfgdir) for p, a2 in specs if a2 == "claude"}
        drift = [tab_name(p, "claude") for p in oracle if oracle[p][0] != oracle0.get(p, (None,))[0]]
        if drift:
            R.step("오라클 고정(종료 후·cmux -k 전)", None, "종료 전과 이력 판정이 다름: %s" % drift)
        R.report()
    except Exception as e:
        R.step("종료 후 관찰 예외 — 복원은 계속", False, repr(e))
    if not gone:
        return 1

    # ── 2) cmux -k 를 가상 터미널에서 실행 (재부팅 뒤 사용자가 하는 일)
    s, err = None, None
    for i in range(2):  # 확인 실패는 1회 재시도 — 그래도 실패면 WARN 후 복원 계속(확인 실패가 복원 생략 사유가 되면 안 된다)
        try:
            s = find_servers(sess, ps_table())
            break
        except Exception as e:
            err = e
            time.sleep(1)
    if s is None:
        R.step("cmux -k 실행 전 세션 비어 있음", None, "확인 실패 2회(%r) — 복원은 계속" % err)
    elif s:
        R.step("cmux -k 실행 전 세션 비어 있음", False, "서버 %s 이미 존재(사용자가 먼저 띄움?) — cmux -k가 그 세션을 다시 죽이지 않도록 복원 생략" % s)
        return 1
    client_log = os.path.join(a.out, "client.log")
    t1 = time.time()
    client = subprocess.Popen([sys.executable, PTYRUN, "--log", client_log, "--secs", "1800", "--cols", "200", "--rows", "50", "--", a.cmux, "-k"],
                              env=env, cwd=REPO, stdin=subprocess.DEVNULL, stdout=open(os.path.join(a.out, "ptyrun.out"), "w"),
                              stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=reset_child_signals)
    new_server = None
    try:
        deadline = t1 + a.ready_timeout
        while time.time() < deadline:
            s = find_servers(sess, ps_table())
            if len(s) == 1:
                new_server = s[0]
                break
            time.sleep(0.3)
        R.t["새 서버 기동"] = time.time() - t1
        R.step("새 서버 기동", new_server is not None and new_server != server, "PID %s" % new_server)
        if not new_server:
            return 1
        meta = os.path.join(CACHE_ROOT, sess, "session-metadata.kdl")
        while time.time() < deadline and not os.path.exists(meta):  # #5632: 클라이언트 초기화 전에는 소켓을 건드리지 않는다
            time.sleep(0.3)
        names = None
        while time.time() < deadline:
            names = tab_names(env, sess)
            if names is not None and len(names) >= len(specs):
                break
            time.sleep(0.5)
        R.t["탭 %d개 확인" % len(specs)] = time.time() - t1
        R.step("탭 복원", names == [tab_name(p, g) for p, g in specs], "%s탭 (기록 %d개)" % (len(names) if names else "조회 실패", len(specs)))
        # 에이전트 프로세스가 다 뜰 때까지 (최대 ready_timeout)
        rows, procs, checks = rows0, None, None
        while time.time() < deadline:
            rows, names, procs, checks = evaluate(sess, new_server, env, specs, cfgdir, a.agent_bin, baseline=base, oracle=oracle)
            if all(v for _, v, _ in checks):
                break
            time.sleep(2)
        R.t["에이전트 %d개 기동 확인" % len(procs or [])] = time.time() - t1
        R.checks_post = checks or []
        R.step("복원 후 점검", bool(checks) and all(v for _, v, _ in checks), "%d/%d 통과" % (sum(1 for _, v, _ in checks or [] if v), len(checks or [])))
        # 환경·파일 위생
        new_env = base_env(new_server)
        R.step("새 서버 환경 위생", set(new_env) == set(env) and "TMPDIR" in new_env, "이름 집합 %s (종료 전 %d개 / 후 %d개)" % ("동일" if set(new_env) == set(env) else "다름: +%s -%s" % (sorted(set(new_env) - set(env)), sorted(set(env) - set(new_env))), len(env), len(new_env)))
        R.step("탭 기록·설정 파일", md5(a.tabs_file) == tabs_md5 and all(md5(os.path.expanduser(p)) == m for p, m in guard_files.items()),
               "session-tabs 동일=%s · zellij config/projects 동일=%s" % (md5(a.tabs_file) == tabs_md5, all(md5(os.path.expanduser(p)) == m for p, m in guard_files.items())))
        lk = md5(layout_kdl)
        R.step("cmux-session.kdl", None if lk != layout_before else True, "복원 전후 %s (재생성 파일 — 내용 차이는 정보용)" % ("동일" if lk == layout_before else "다름"))
        p1 = count_panics(log_path)
        R.step("zellij 서버 초기화 panic(#5632) 증가", p1 - panic0 == 0, "+%d" % (p1 - panic0))
        R.report()
        # 화면 확인 (정보용) + 주입
        screens = []
        nc = None if a.no_screen else client_count(env, sess)
        if not a.no_screen and nc != 1:
            R.step("탭 화면 확인(에이전트 UI 표식)", None, "클라이언트 %s개(1개 아님) — 탭 이동이 다른 클라이언트 화면을 바꿀 수 있어 생략" % nc)
        elif not a.no_screen:
            tmpd = os.path.join(a.out, "tmp")
            os.makedirs(tmpd, exist_ok=True)
            for r in rows:
                ok, why, _ = screen_has_ui(env, sess, r["name"], tmpd)
                screens.append((r["name"], ok, why))
            shutil.rmtree(tmpd, ignore_errors=True)
            R.step("탭 화면 확인(에이전트 UI 표식)", None if not all(o for _, o, _ in screens) else True,
                   "%d/%d (%s)" % (sum(1 for _, o, _ in screens if o), len(screens), "; ".join("%s:%s" % (n, w) for n, o, w in screens if not o) or "전부 표식 확인"))
            zj(env, sess, "go-to-tab-name", rows[0]["name"])
        if a.inject_tab and a.inject_text:
            cnt = (tab_names(env, sess) or []).count(a.inject_tab)
            nc = client_count(env, sess)
            if cnt != 1 or nc != 1:
                R.step("이어쓰기 프롬프트 주입", False, "탭 %s 이름 일치 %d개 · 클라이언트 %s개 (둘 다 1이어야 함) — 주입 생략" % (a.inject_tab, cnt, nc))
                R.report()
            else:
                injected = False  # True=전송·화면 확인 / None=전송했으나 확인 못 함(WARN) / False=실패
                why = "표식 대기 시간 초과"
                end = time.time() + 120
                tmpd = os.path.join(a.out, "tmp")
                os.makedirs(tmpd, exist_ok=True)
                while time.time() < end:
                    ok, why, _ = screen_has_ui(env, sess, a.inject_tab, tmpd)
                    if ok:
                        rc1, _ = zj(env, sess, "write-chars", a.inject_text)
                        time.sleep(0.5)
                        rc2 = zj(env, sess, "write", "13")[0] if rc1 == 0 else None  # 글자 전송 실패면 Enter 생략
                        if rc1 != 0 or rc2 != 0:
                            why = "write-chars rc=%s · write(Enter) rc=%s" % (rc1, "생략" if rc2 is None else rc2)
                            break
                        nc2 = client_count(env, sess)
                        time.sleep(3)
                        _, _, text = screen_has_ui(env, sess, a.inject_tab, tmpd)
                        seen = a.inject_text.strip()[:20] in text or "esc to interrupt" in text
                        injected = True if (seen and nc2 == 1) else None
                        why = "%s · 주입 후 클라이언트 %s개 · 화면에 주입 텍스트/esc to interrupt %s" % (why, nc2, "보임" if seen else "안 보임")
                        break
                    time.sleep(3)
                shutil.rmtree(tmpd, ignore_errors=True)
                R.step("이어쓰기 프롬프트 주입", injected, "탭 %s — %s" % (a.inject_tab, why))
                R.report()
                time.sleep(8)
    finally:
        # 가상 터미널 닫기 = 창 닫기(HUP) — 서버·탭은 남아야 한다
        client.send_signal(signal.SIGTERM)
        try:
            client.wait(timeout=15)
        except subprocess.TimeoutExpired:
            client.kill()
    time.sleep(3)
    names = tab_names(env, sess)
    R.step("클라이언트 HUP 뒤 세션 유지", new_server is not None and alive(new_server) and names is not None and len(names) >= len(specs),
           "서버 %s 생존=%s · 탭 %s개" % (new_server, bool(new_server and alive(new_server)), len(names) if names is not None else "조회 실패"))
    rc, out = run(["zellij", "list-sessions", "--no-formatting"], env=env, timeout=10)
    live = [l for l in out.splitlines() if re.match(r"^%s( |$)" % re.escape(sess), l) and "EXITED" not in l]
    R.step("최종 세션 목록", bool(live), out.strip().replace("\n", " / ")[:120])
    return 0 if all(ok is not False for _, ok, _ in R.steps) else 1


def count_panics(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return sum(1 for line in f if "zellij-server/src/lib.rs:1462" in line)
    except OSError:
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("verify", "run"):
        p = sub.add_parser(name)
        p.add_argument("--session", default="claude")
        p.add_argument("--tabs-file", default=TABS_DEFAULT)
        p.add_argument("--agent-bin", default=None, help="기본: `cmux -h`가 보여 주는 Claude 경로")
        if name == "verify":
            p.add_argument("--json")
        else:
            p.add_argument("--cmux", default=os.path.join(HOME, ".local/bin/cmux"))
            p.add_argument("--out", default=os.path.join("/tmp/cmux-live-restore", time.strftime("%Y%m%d-%H%M%S")))
            p.add_argument("--expect-server-pid", type=int)
            p.add_argument("--delay", type=float, default=6.0)
            p.add_argument("--ready-timeout", type=float, default=180.0)
            p.add_argument("--daemonize", action="store_true")
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--yes", action="store_true")
            p.add_argument("--no-screen", action="store_true")
            p.add_argument("--inject-tab")
            p.add_argument("--inject-text")
    a = ap.parse_args()
    if a.cmd == "run" and a.dry_run:
        a.no_screen, a.inject_tab = True, None
    return cmd_verify(a) if a.cmd == "verify" else cmd_run(a)


if __name__ == "__main__":
    sys.exit(main())
