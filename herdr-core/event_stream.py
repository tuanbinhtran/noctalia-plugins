#!/usr/bin/env python3
"""Supervise `hc events --json` and relay its JSON lines to Noctalia."""
import json
import os
import selectors
import signal
import subprocess
import sys
import time


TERMINAL_FIELDS = (
    "address", "created_ms", "status", "parent", "name", "title", "state",
    "status_ms", "finished_ms", "exit_code", "signal", "reason", "keep",
    "pid", "turn",
)


def compact_frame(frame):
    terminals = None
    if not isinstance(frame, dict):
        return None
    if frame.get("method") is None and isinstance(frame.get("terminals"), list):
        terminals = frame["terminals"]
        target = frame
    elif frame.get("method") == "missed":
        params = frame.get("params")
        if isinstance(params, dict) and isinstance(params.get("terminals"), list):
            terminals = params["terminals"]
            target = params
    elif frame.get("method") == "event":
        params = frame.get("params")
        if (
            isinstance(params, dict)
            and params.get("type") in ("created", "restarted")
            and isinstance(params.get("data"), dict)
        ):
            params["data"] = compact_terminal(params["data"])
            return json.dumps(frame, separators=(",", ":")).encode()
    if terminals is not None:
        target["terminals"] = [
            compact_terminal(terminal) if isinstance(terminal, dict) else terminal
            for terminal in terminals
        ]
        encoded = json.dumps(frame, separators=(",", ":")).encode()
        if len(encoded) > 60000:
            finished = sorted(
                (
                    terminal for terminal in target["terminals"]
                    if isinstance(terminal, dict) and terminal.get("state") == "finished"
                ),
                key=lambda terminal: (
                    terminal.get("finished_ms") is not None,
                    terminal["finished_ms"] if isinstance(terminal.get("finished_ms"), (int, float)) else 0,
                ),
            )
            for terminal in finished:
                if len(encoded) <= 60000:
                    break
                target["terminals"] = [
                    kept for kept in target["terminals"] if kept is not terminal
                ]
                encoded = json.dumps(frame, separators=(",", ":")).encode()
        return encoded
    return None


def compact_terminal(terminal):
    result = {key: terminal[key] for key in TERMINAL_FIELDS if key in terminal}
    status = result.get("status")
    if isinstance(status, dict):
        result["status"] = {"state": status["state"]} if "state" in status else {}
    return result


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
                            try:
                                frame = json.loads(raw)
                                saw_snapshot = saw_snapshot or (
                                    isinstance(frame, dict)
                                    and isinstance(frame.get("seq"), int)
                                    and isinstance(frame.get("terminals"), list)
                                )
                                output = compact_frame(frame) or raw
                            except (UnicodeDecodeError, json.JSONDecodeError):
                                output = raw
                            if not emit_raw(output):
                                stopping = True
                                break
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
