"""Control-socket numeric regressions. Run under Xvfb with SEANCE_TEST_BINARY set."""
import json
import math
import socket

from test_ghostty_integration import GhosttyTestCase


class SocketNumberTests(GhosttyTestCase):
    def request(self, request):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(3)
            conn.connect(str(self.socket_path))
            conn.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while b"\n" not in reply:
                part = conn.recv(65536)
                self.assertTrue(part, "application closed the socket without a reply")
                reply += part
        return json.loads(reply)

    def test_numeric_ids_are_echoed_without_integer_conversion(self):
        for request_id in (1e100, -1e100, 1.7976931348623157e308,
                           -1.7976931348623157e308, float(2**63),
                           -float(2**63), 1.25, -1.25, 0, 42, "client-42"):
            with self.subTest(request_id=request_id):
                reply = self.request({"id": request_id, "method": "system.ping"})
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["id"], request_id)
                self.assertEqual(reply["result"], {"pong": True})
        self.call("system.ping")

    def test_integer_parameters_handle_float_boundaries(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        for lines in (1e100, -1e100, float(2**64),
                      math.nextafter(float(2**64), 0), float(2**63),
                      -1.0, 0.0, 1.0, 1.75, 50.0, "50"):
            with self.subTest(lines=lines):
                reply = self.request({"id": "lines", "method": "surface.read_screen",
                                      "params": {"lines": lines}})
                self.assertTrue(reply["ok"], reply)
                self.assertIsInstance(reply["result"]["text"], str)
                self.assertEqual(reply["id"], "lines")
        self.call("system.ping")
