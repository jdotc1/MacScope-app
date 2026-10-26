import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope  # noqa: E402


class FakeTransport:
    """Stands in for the pipe transport: records written lines, replays canned replies."""

    def __init__(self, replies):
        self.written = []
        self.lines = [json.dumps(r).encode("utf-8") for r in replies]

    def write_line(self, data, deadline):
        self.written.append(data)

    def read_line(self, deadline):
        return self.lines.pop(0) if self.lines else None


def client_with(replies):
    return macscope._MCPClient._over(FakeTransport(replies))


class ProtocolErrorTests(unittest.TestCase):
    def test_null_id_error_raises_instead_of_waiting_forever(self):
        client = client_with([{"jsonrpc": "2.0", "id": None,
                               "error": {"code": -32700, "message": "Parse error"}}])
        with self.assertRaises(macscope.MacScopeError) as raised:
            client._request("tools/call", {"name": "functions"})
        self.assertIn("-32700", str(raised.exception))

    def test_unrelated_notifications_are_still_skipped(self):
        client = client_with([{"jsonrpc": "2.0", "method": "notifications/progress"},
                              {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}])
        self.assertEqual(client._request("ping"), {"ok": True})

    def test_nan_argument_is_rejected_before_it_is_sent(self):
        client = client_with([])
        with self.assertRaises(macscope.MacScopeError):
            client._request("tools/call", {"name": "x", "arguments": {"v": float("nan")}})
        self.assertEqual(client._transport.written, [])


if __name__ == "__main__":
    unittest.main()
