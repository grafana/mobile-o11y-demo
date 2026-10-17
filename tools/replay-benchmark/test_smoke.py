"""Failure-path coverage for the local handoff's owned-process cleanup."""
import io
import subprocess
import unittest
from unittest.mock import Mock, patch

from smoke import cleanup


class CleanupTest(unittest.TestCase):
    def test_disconnected_adb_still_stops_both_servers_and_closes_logs(self):
        servers = [Mock(), Mock()]
        for server in servers:
            server.poll.return_value = None
        logs = [io.StringIO(), io.StringIO()]
        with patch("smoke.subprocess.run", side_effect=subprocess.TimeoutExpired("adb", 30)) as adb:
            errors = cleanup(["adb", "-s", "emulator-5554"], True, True, servers, logs)
        self.assertEqual(2, adb.call_count)
        self.assertEqual(2, len(errors))
        for server in servers:
            server.terminate.assert_called_once()
            server.wait.assert_called_once_with(timeout=5)
        self.assertTrue(all(log.closed for log in logs))

    def test_stuck_server_is_killed_and_other_server_still_stops(self):
        stopped, stuck = Mock(), Mock()
        stopped.poll.return_value = stuck.poll.return_value = None
        stuck.wait.side_effect = [subprocess.TimeoutExpired("receiver", 5), 0]
        errors = cleanup([], False, False, [stopped, stuck], [])
        self.assertEqual([], errors)
        stuck.kill.assert_called_once()
        self.assertEqual(2, stuck.wait.call_count)
        stopped.terminate.assert_called_once()
        stopped.wait.assert_called_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
