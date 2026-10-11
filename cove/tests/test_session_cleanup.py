#!/usr/bin/env python3
import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mcp"))
import cove_mcp  # noqa: E402


class SessionCleanupCliTest(unittest.TestCase):
    def test_cli_rejects_non_session_names(self) -> None:
        with mock.patch.object(cove_mcp, "_kill_session") as kill, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123;kill 1"]), 2)
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session"]), 2)
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123", "extra"]), 2)
            kill.assert_not_called()

        with mock.patch.object(cove_mcp, "_kill_session", return_value=True) as kill:
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123"]), 0)
            kill.assert_called_once_with("cove-123")

    def test_cli_reports_unverified_cleanup_failure(self) -> None:
        with mock.patch.object(cove_mcp, "_kill_session", return_value=False):
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123"]), 1)

    def test_dispatch_preserves_relay_cleanup_and_stdio_modes(self) -> None:
        relay_result = object()
        with mock.patch.object(cove_mcp, "run_relayed", return_value=relay_result) as relay, \
                mock.patch.object(cove_mcp, "_kill_session_cli") as cleanup, \
                mock.patch.object(cove_mcp, "main") as stdio:
            self.assertIs(cove_mcp._dispatch(["--call"]), relay_result)
            relay.assert_called_once_with()
            cleanup.assert_not_called()
            stdio.assert_not_called()

        with mock.patch.object(cove_mcp, "run_relayed") as relay, \
                mock.patch.object(cove_mcp, "_kill_session_cli", return_value=7) as cleanup, \
                mock.patch.object(cove_mcp, "main") as stdio:
            self.assertEqual(cove_mcp._dispatch(["--kill-session", "cove-123"]), 7)
            cleanup.assert_called_once_with(["--kill-session", "cove-123"])
            relay.assert_not_called()
            stdio.assert_not_called()

        stdio_result = object()
        with mock.patch.object(cove_mcp, "run_relayed") as relay, \
                mock.patch.object(cove_mcp, "_kill_session_cli") as cleanup, \
                mock.patch.object(cove_mcp, "main", return_value=stdio_result) as stdio:
            self.assertIs(cove_mcp._dispatch([]), stdio_result)
            stdio.assert_called_once_with()
            relay.assert_not_called()
            cleanup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
