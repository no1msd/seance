"""Sidebar labels for agent tool calls, checked through the real Séance binary.

Build first, then run python3 -m unittest discover -s tests -p test_tool_description.py -v.
"""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SEANCE_TEST_BINARY', ROOT / 'zig-out/bin/seance')).resolve()


@unittest.skipUnless(BINARY.is_file(), 'build Séance first')
class ToolDescriptionTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='seance-tool-label-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.requests = []
        owner = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                owner.requests.append(request)
                self.wfile.write((json.dumps({'id': request['id'], 'ok': True, 'result': {}}) + '\n').encode())

        server = socketserver.ThreadingUnixStreamServer(str(root / 'socket'), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def close_server():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.addCleanup(close_server)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SEANCE_')}
        self.env.update(HOME=str(root), SEANCE_SOCKET_PATH=str(root / 'socket'),
                        SEANCE_WORKSPACE_ID='7', SEANCE_SURFACE_ID='3')

    def label(self, hook, tool_name, tool_input):
        self.requests.clear()
        result = subprocess.run([str(BINARY), 'ctl', hook, 'pre-tool-use'], env=self.env,
                                input=json.dumps({'tool_name': tool_name, 'tool_input': tool_input}),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        statuses = [r['params'] for r in self.requests if r['method'] == 'workspace.set_status']
        self.assertEqual(len(statuses), 1, self.requests)
        return statuses[0]['value']

    def test_lowercase_tool_names_are_described(self):
        cases = [
            ('read', {'path': '/a/b.txt'}, 'Reading b.txt'),
            ('write', {'path': 'src/new.zig', 'content': 'x'}, 'Writing new.zig'),
            ('edit', {'path': '/repo/main.c'}, 'Editing main.c'),
            ('edit', {'file_path': '/repo/other.c'}, 'Editing other.c'),
            ('bash', {'command': 'zig build test --summary all && echo done'}, 'Running zig build test --summary all &'),
            ('bash', {}, 'Running command'),
            ('grep', {'pattern': 'toolDescription'}, 'Searching toolDescription'),
            ('glob', {'pattern': '**/*.zig'}, 'Searching **/*.zig'),
            ('web_search', {'query': 'zig 0.16 release notes'}, 'Search: zig 0.16 release notes'),
            ('task', {'tasks': [{'id': 'One'}]}, 'Agent'),
            ('find', {'pattern': 'x'}, 'find'),
        ]
        for tool_name, tool_input, expected in cases:
            with self.subTest(tool=tool_name, input=tool_input):
                self.assertEqual(self.label('pi-hook', tool_name, tool_input), expected)

    def test_claude_tool_names_are_unchanged(self):
        cases = [
            ('Read', {'file_path': '/a/b.txt'}, 'Reading b.txt'),
            ('Write', {'file_path': '/a/c.txt'}, 'Writing c.txt'),
            ('Bash', {'command': 'ls'}, 'Running ls'),
            ('Grep', {'pattern': 'foo'}, 'Searching foo'),
            ('Agent', {'description': 'Explore the repo'}, 'Explore the repo'),
            ('WebSearch', {'query': 'gtk4'}, 'Search: gtk4'),
            ('WebFetch', {'url': 'https://example.com'}, 'Fetching URL'),
        ]
        for tool_name, tool_input, expected in cases:
            with self.subTest(tool=tool_name):
                self.assertEqual(self.label('claude-hook', tool_name, tool_input), expected)
