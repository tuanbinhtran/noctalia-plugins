import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[2] / "herdr-core" / "event_stream.py"
CHILD = """
import json, os, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
prior = path.read_text().splitlines() if path.exists() else []
old_alive = bool(prior and pathlib.Path('/proc', prior[-1]).exists())
with path.open('a') as log:
    print(os.getpid(), file=log)
if sys.argv[2] == 'large':
    terminals = [{'address': f'terminal-{i}', 'labels': 'x' * 1000} for i in range(200)]
    print(json.dumps({'seq': 1, 'terminals': terminals}), flush=True)
elif sys.argv[2] == 'snapshot':
    terminals = [
        {'address': f'finished-{i}', 'created_ms': i, 'finished_ms': i + 1, 'state': 'finished',
         'status': {'state': 'done'}, 'status_ms': i + 2, 'title': 't' * 60, 'parent': None,
         'reason': 'complete', 'turn': i, 'labels': 'x' * 1000}
        for i in range(500)
    ]
    terminals += [
        {'address': f'live-{i}', 'created_ms': 1000 + i, 'state': 'working',
         'status': {'state': 'working'}, 'status_ms': 1000 + i, 'title': 't' * 60,
         'parent': None, 'reason': None, 'turn': i, 'labels': 'x' * 1000}
        for i in range(50)
    ]
    print(json.dumps({'seq': 1, 'terminals': terminals}), flush=True)
elif sys.argv[2] != 'silent':
    print(json.dumps({'seq': 1, 'terminals': [], 'pid': os.getpid(), 'old_alive': old_alive}), flush=True)
if sys.argv[2] in ('stall', 'silent') or prior:
    time.sleep(30)
"""
WRAPPER = """
import runpy, sys
supervise = runpy.run_path(sys.argv[1])['supervise']
supervise(sys.argv[2:], silence=0.75, heartbeat=0.1, max_backoff=0.2)
"""


class EventStreamTest(unittest.TestCase):
    def setUp(self):
        folder = self.enterContext(tempfile.TemporaryDirectory())
        self.child_log = Path(folder) / "children"
        self.buffer = bytearray()
        self.line_lengths = []

    def start(self, mode):
        self.proc = subprocess.Popen(
            [sys.executable, "-c", WRAPPER, str(HELPER), sys.executable, "-c", CHILD, str(self.child_log), mode],
            stdout=subprocess.PIPE,
        )
        self.addCleanup(self.stop)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdout.close()
        if self.child_log.exists():
            for pid in map(int, self.child_log.read_text().splitlines()):
                if Path("/proc", str(pid)).exists():
                    try:
                        os.kill(pid, 15)
                    except ProcessLookupError:
                        pass

    def next_frame(self, matches):
        deadline = time.monotonic() + 5
        with selectors.DefaultSelector() as selector:
            selector.register(self.proc.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                while (end := self.buffer.find(b"\n")) >= 0:
                    raw = bytes(self.buffer[:end])
                    frame = json.loads(raw)
                    self.line_lengths.append(len(raw))
                    del self.buffer[:end + 1]
                    if matches(frame):
                        return frame
                if selector.select(max(0, deadline - time.monotonic())):
                    chunk = os.read(self.proc.stdout.fileno(), 65536)
                    if not chunk:
                        self.fail("supervisor closed its stream before the expected frame")
                    self.buffer.extend(chunk)
        self.fail("supervisor did not emit the expected frame")

    def check_replacement(self, mode):
        self.start(mode)
        first = self.next_frame(lambda frame: "pid" in frame)
        self.next_frame(lambda frame: frame.get("plugin") == "feed-down")
        second = self.next_frame(lambda frame: "pid" in frame)
        self.assertNotEqual(second["pid"], first["pid"])
        self.assertFalse(second["old_alive"], "previous watcher still existed when replacement started")

    def test_eof_reaps_before_replacing_watcher(self):
        self.check_replacement("exit")

    def test_silent_watcher_is_reaped_before_replacement(self):
        self.check_replacement("stall")

    def test_large_snapshot_is_compacted_before_relay(self):
        self.start("large")
        snapshot = self.next_frame(lambda frame: "terminals" in frame)
        self.assertEqual(len(snapshot["terminals"]), 200)
        self.assertEqual([term["address"] for term in snapshot["terminals"]],
                         [f"terminal-{i}" for i in range(200)])
        self.assertTrue(all(length < 65536 for length in self.line_lengths))

    def test_snapshot_keeps_live_and_newest_finished_records_under_line_limit(self):
        self.start("snapshot")
        snapshot = self.next_frame(lambda frame: "terminals" in frame)
        terminals = snapshot["terminals"]
        kept_finished = [terminal for terminal in terminals if terminal["state"] == "finished"]
        dropped_finished = set(range(500)) - {
            int(terminal["address"].removeprefix("finished-")) for terminal in kept_finished
        }
        self.assertTrue(all(length < 65536 for length in self.line_lengths))
        self.assertEqual(
            {terminal["address"] for terminal in terminals if terminal["state"] != "finished"},
            {f"live-{i}" for i in range(50)},
        )
        self.assertTrue(kept_finished)
        self.assertTrue(dropped_finished)
        self.assertGreater(
            min(terminal["finished_ms"] for terminal in kept_finished),
            max(index + 1 for index in dropped_finished),
        )

    def test_silent_child_keeps_alive_during_failure_and_backoff(self):
        self.start("silent")
        alive_before_down = 0
        while True:
            frame = self.next_frame(lambda frame: frame.get("plugin") in ("alive", "feed-down"))
            if frame.get("plugin") == "feed-down":
                break
            alive_before_down += 1
        self.assertGreaterEqual(alive_before_down, 3)
        self.assertEqual(self.next_frame(lambda frame: frame.get("plugin") == "alive"),
                         {"plugin": "alive"})

    def test_cancellation_reaps_running_child(self):
        self.start("stall")
        child = self.next_frame(lambda frame: "pid" in frame)["pid"]
        self.proc.terminate()
        self.proc.wait(timeout=4)
        self.assertFalse(Path("/proc", str(child)).exists())

    def test_closed_output_pipe_reaps_running_child(self):
        self.start("stall")
        child = self.next_frame(lambda frame: "pid" in frame)["pid"]
        self.proc.stdout.close()
        self.proc.wait(timeout=4)
        self.assertFalse(Path("/proc", str(child)).exists())

    def test_no_argument_cli_subscribes_to_core_events(self):
        hc = self.child_log.parent / "hc"
        hc.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, pathlib, sys, time\n"
            "pathlib.Path(os.environ['CHILD_PID_LOG']).write_text(str(os.getpid()))\n"
            "print(json.dumps({'seq': 1, 'terminals': [], 'args': sys.argv[1:]}), flush=True)\n"
            "time.sleep(30)\n"
        )
        hc.chmod(0o700)
        self.proc = subprocess.Popen(
            [sys.executable, "-u", str(HELPER)],
            stdout=subprocess.PIPE,
            env={**os.environ, "PATH": str(hc.parent) + os.pathsep + os.environ["PATH"],
                 "CHILD_PID_LOG": str(self.child_log)},
        )
        self.addCleanup(self.stop)
        snapshot = self.next_frame(lambda frame: "terminals" in frame)
        self.assertEqual(snapshot["args"], ["events", "--json"])
