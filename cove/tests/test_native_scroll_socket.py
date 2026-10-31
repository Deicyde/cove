#!/usr/bin/env python3
"""Smoke-test Cove's fast history-scroll and native scrollbar pointer messages."""

from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
KITTY = REPO / "kitty" / "launcher" / "kitty"
KITTEN = REPO / "kitty" / "launcher" / "kitty.app" / "Contents" / "MacOS" / "kitten"


class NativeScrollSocketTest(unittest.TestCase):
    def test_scroll_and_scrollbar_drag(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cove-scroll-socket-", dir="/tmp") as tdir:
            root = Path(tdir)
            runtime = root / "runtime"
            control = root / "kitty.sock"
            opened_url = root / "opened-url"
            opener = root / "record-url.py"
            opener.write_text(
                "#!/usr/bin/python3\n"
                "import os, pathlib, sys\n"
                "pathlib.Path(os.environ['COVE_URL_RECORD']).write_text(sys.argv[1])\n"
            )
            opener.chmod(0o755)
            env = {
                **os.environ,
                "COVE": "1",
                "COVE_URL_RECORD": str(opened_url),
                "KITTY_COVE": "1",
                "KITTY_COVE_DIR": str(runtime),
            }
            cmd = [
                str(KITTY), "--title", "cove-scroll-test",
                "--listen-on", f"unix:{control}",
                "-o", "allow_remote_control=yes", "-o", "sync_to_monitor=no",
                "-o", f"open_url_with={opener}",
                "-o", "remember_window_size=no", "-o", "initial_window_width=80c",
                "-o", "initial_window_height=20c", "/bin/sh", "-c",
                "for i in $(seq 1 200); do printf 'scroll-line-%03d\\n' \"$i\"; done; "
                "printf '\\033]8;;https://example.com/cove-link\\033\\\\COVE-LINK"
                "\\033]8;;\\033\\\\\\n'; exec sleep 60",
            ]
            proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            assert proc.stderr is not None
            self.addCleanup(proc.stderr.close)
            self.addCleanup(lambda: proc.poll() is None and proc.kill())
            try:
                listing = self._wait_listing(control, proc)
                os_window = int(listing[0]["id"])
                window = listing[0]["tabs"][0]["windows"][0]
                pane = int(window["id"])
                frame = runtime / f"term-{os_window}.rgba"
                self._wait_path(runtime / "input.sock", proc)
                self._wait_path(frame, proc)
                time.sleep(0.3)

                latest = self._screen(control, pane)
                self.assertIn("COVE-LINK", latest)
                header = frame.read_bytes()[:64]
                _, width, height = struct.unpack_from("<III", header)
                cols, rows = struct.unpack_from("<II", header, 32)
                link_row = next(i for i, line in enumerate(latest.splitlines()) if "COVE-LINK" in line)
                link_x = max(1, int(4.5 * width / cols))
                link_y = max(1, int((link_row + 0.5) * height / rows))
                click = [
                    struct.pack("<BQBIII", 9, os_window, 0, link_x, link_y, 0),
                    struct.pack("<BQBIII", 9, os_window, 2, link_x, link_y, 0),
                ]
                self._send(runtime, b"".join(click))
                self._wait_file_contains(opened_url, "https://example.com/cove-link")

                self._send(runtime, struct.pack("<BQi", 7, pane, 10))
                older = self._wait_screen_change(control, pane, latest)
                self.assertNotEqual(older, latest)

                # Press the visible scrollbar track, drag its thumb to the
                # bottom, and release. Native kitty hit-testing owns the drag.
                x = max(0, width - 2)
                messages = [
                    struct.pack("<BQBII", 8, os_window, 0, x, height // 2),
                    struct.pack("<BQBII", 8, os_window, 1, x, height - 2),
                    struct.pack("<BQBII", 8, os_window, 2, x, height - 2),
                ]
                self._send(runtime, b"".join(messages))
                newest = self._wait_screen_contains(control, pane, "scroll-line-200")
                self.assertIn("scroll-line-200", newest)

                # General pointer cancel is a separate OS-window-targeted message.
                messages = [
                    struct.pack("<BQBIII", 9, os_window, 0, width // 2, height // 2, 0),
                    struct.pack("<BQBIII", 9, os_window, 1, width // 2 + 20, height // 2, 0),
                    struct.pack("<BQBIII", 9, os_window, 3, width // 2 + 20, height // 2, 0),
                ]
                self._send(runtime, b"".join(messages))
                time.sleep(0.05)
                self.assertIsNone(proc.poll(), "native pointer cancel crashed kitty")
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)

    def _kitten(self, control: Path, *args: str) -> str:
        return subprocess.check_output(
            [str(KITTEN), "@", "--to", f"unix:{control}", *args],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )

    def _wait_listing(self, control: Path, proc: subprocess.Popen[bytes]) -> list[dict]:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                assert proc.stderr is not None
                self.fail(f"test kitty exited during startup: {proc.stderr.read().decode(errors='replace')}")
            try:
                return json.loads(self._kitten(control, "ls"))
            except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
                time.sleep(0.05)
        self.fail("test kitty never exposed remote control")

    def _wait_path(self, path: Path, proc: subprocess.Popen[bytes]) -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                assert proc.stderr is not None
                self.fail(f"test kitty exited before creating {path}: {proc.stderr.read().decode(errors='replace')}")
            if path.exists():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {path}")

    def _screen(self, control: Path, pane: int) -> str:
        return self._kitten(control, "get-text", "--match", f"id:{pane}", "--extent", "screen")

    def _wait_screen_change(self, control: Path, pane: int, before: str) -> str:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            now = self._screen(control, pane)
            if now != before:
                return now
            time.sleep(0.02)
        self.fail("scroll message did not change the visible history")

    def _wait_screen_contains(self, control: Path, pane: int, needle: str) -> str:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            now = self._screen(control, pane)
            if needle in now:
                return now
            time.sleep(0.02)
        self.fail(f"scrollbar drag did not reveal {needle!r}")

    def _wait_file_contains(self, path: Path, needle: str) -> None:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and needle in path.read_text():
                return
            time.sleep(0.02)
        self.fail(f"native link click did not record {needle!r}")

    @staticmethod
    def _send(runtime: Path, payload: bytes) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(str(runtime / "input.sock"))
            sock.sendall(payload)


if __name__ == "__main__":
    unittest.main()
