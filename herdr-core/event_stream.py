#!/usr/bin/env python3
"""Supervise `hc events --json` and relay its JSON lines to Noctalia."""
import json
import os
import selectors
import signal
import subprocess
import sys
import time


def supervise(argv, *, silence=45, heartbeat=10, max_backoff=15):
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    previous = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        previous[sig] = signal.signal(sig, stop)

    def emit(record):
        try:
            sys.stdout.buffer.write(
                (json.dumps(record, separators=(",", ":")) + "\n").encode()
            )
            sys.stdout.buffer.flush()
            return True
        except (BrokenPipeError, OSError):
            return False

    backoff = 1.0
    next_alive = time.monotonic() + heartbeat
    try:
        while not stopping:
            child = None
            selector = selectors.DefaultSelector()
            try:
                child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                selector.register(child.stdout, selectors.EVENT_READ)
                last_line = time.monotonic()
                pending = b""
                saw_snapshot = False
                failed = False
                while not stopping and not failed:
                    now = time.monotonic()
                    if now - last_line >= silence:
                        failed = True
                        break
                    if now >= next_alive:
                        if not emit({"plugin": "alive"}):
                            stopping = True
                            break
                        next_alive = now + heartbeat
                    timeout = max(0, min(next_alive - now, silence - (now - last_line), 0.5))
                    if child.poll() is not None and not selector.select(0):
                        failed = True
                        break
                    for key, _ in selector.select(timeout):
                        try:
                            chunk = os.read(key.fd, 65536)
                        except OSError:
                            chunk = b""
                        if not chunk:
                            failed = True
                            break
                        last_line = time.monotonic()
                        pending += chunk
                        pieces = pending.split(b"\n")
                        pending = pieces.pop()
                        for raw in pieces:
                            if raw.endswith(b"\r"):
                                raw = raw[:-1]
                            if raw and not emit_raw(raw):
                                stopping = True
                                break
                            try:
                                frame = json.loads(raw)
                                saw_snapshot = saw_snapshot or (
                                    isinstance(frame, dict)
                                    and isinstance(frame.get("seq"), int)
                                    and isinstance(frame.get("terminals"), list)
                                )
                            except (UnicodeDecodeError, json.JSONDecodeError):
                                pass
                        if stopping:
                            break
                if saw_snapshot:
                    backoff = 1.0
            except (OSError, ValueError):
                pass
            finally:
                selector.close()
                if child is not None:
                    if child.poll() is None:
                        try:
                            child.terminate()
                        except ProcessLookupError:
                            pass
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                    if child.stdout:
                        child.stdout.close()
            if stopping:
                break
            if not emit({"plugin": "feed-down"}):
                break
            until = time.monotonic() + backoff
            while not stopping and time.monotonic() < until:
                time.sleep(min(0.1, until - time.monotonic()))
                if time.monotonic() >= next_alive:
                    if not emit({"plugin": "alive"}):
                        stopping = True
                        break
                    next_alive = time.monotonic() + heartbeat
            backoff = min(backoff * 2, max_backoff)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)

def emit_raw(raw):
    try:
        sys.stdout.buffer.write(raw + b"\n")
        sys.stdout.buffer.flush()
        return True
    except (BrokenPipeError, OSError):
        return False


if __name__ == "__main__":
    supervise(["hc", "events", "--json"])
