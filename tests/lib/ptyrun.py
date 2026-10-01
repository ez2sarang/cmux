#!/usr/bin/env python3
"""ptyrun — 명령을 가상 터미널(pty)에서 실행하고 출력을 로그 파일에 저장한다 (cmux 테스트 전용).

zellij 클라이언트·에이전트 TUI는 tty가 있어야 뜨므로, 헤드리스 테스트에서 "터미널 창" 역할을 한다.
종료 시 master fd를 닫아 자식에게 SIGHUP을 보낸다 = 터미널 창을 닫는 것과 동일
(zellij 서버와 그 안의 pane 프로세스는 살아남는다 — "Ghostty를 닫았을 때" 시나리오).

안전장치: ZELLIJ* 환경변수를 항상 제거한다. 이 테스트를 라이브 zellij 세션 안 pane에서 실행해도
`zellij action ...`이 라이브 세션을 겨냥하지 못하게 하기 위함이다.

사용: ptyrun.py --log OUT.txt [--secs 10] [--until 문자열] [--send "SECS:텍스트\\r"]... -- 명령 인자...
종료 코드: 0(자식이 먼저 끝났거나 시간 초과·SIGTERM/SIGINT로 HUP 종료) / 2(--until 문자열이 끝내 안 나옴) / 3(실행 실패)
stderr 마지막 줄: ptyrun: exited rc=N | ptyrun: hup (timeout|until|signal)
SIGTERM/SIGINT를 받으면 즉시 HUP 경로로 종료한다 — 백그라운드로 띄운 "터미널 창"을 원하는 시점에 닫는 용도.
"""
import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--secs", type=float, default=10.0)
    ap.add_argument("--until", default=None, help="이 문자열이 출력에 나오면 조기 종료")
    ap.add_argument("--cols", type=int, default=200)
    ap.add_argument("--rows", type=int, default=50)
    ap.add_argument("--send", action="append", default=[], help='"SECS:텍스트" — 해당 시각에 입력 전송(\\r \\x03 해석)')
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        print("ptyrun: 명령이 없습니다", file=sys.stderr)
        return 3

    sends = []
    for s in a.send:
        t, _, txt = s.partition(":")
        sends.append((float(t), txt.encode().decode("unicode_escape").encode()))
    sends.sort(key=lambda x: x[0])

    env = {k: v for k, v in os.environ.items() if not k.startswith("ZELLIJ")}

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(cmd[0], cmd, env)
        except OSError as e:
            print(f"ptyrun: exec 실패: {e}", file=sys.stderr)
            os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))

    stop = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda signum, frame: stop.append(signum))

    buf = b""
    start = time.time()
    reason = "timeout"
    exited_rc = None
    with open(a.log, "wb") as log:
        while True:
            now = time.time() - start
            if stop:
                reason = "signal"
                break
            if now >= a.secs:
                break
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if data:
                    buf += data
                    log.write(data)
                    log.flush()
                    if a.until and a.until.encode() in buf:
                        reason = "until"
                        break
                else:
                    # 자식이 끝나 EOF
                    pass
            while sends and (time.time() - start) >= sends[0][0]:
                try:
                    os.write(fd, sends.pop(0)[1])
                except OSError:
                    break
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                exited_rc = os.waitstatus_to_exitcode(status)
                break

    if exited_rc is None:
        # 터미널 창 닫기 = master fd close → 자식에 SIGHUP
        try:
            os.close(fd)
        except OSError:
            pass
        for _ in range(30):
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                break
            time.sleep(0.1)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except OSError:
                pass
        print(f"ptyrun: hup ({reason})", file=sys.stderr)
        if a.until and reason == "timeout":
            return 2
        return 0
    try:
        os.close(fd)
    except OSError:
        pass
    print(f"ptyrun: exited rc={exited_rc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
