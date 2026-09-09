"""OpenCode wrapper, plugin, and optional installed-CLI regressions.

Node runs the plugin unit tests; the integration itself uses OpenCode's runtime.
Set SEANCE_TEST_OPENCODE and SEANCE_TEST_BINARY for the isolated server test.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class OpenCodeWrapperTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="seance-opencode-test-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.prefix = self.root / "prefix with 'quotes'"
        self.bin = self.root / 'real-bin'
        self.bin.mkdir()
        self.wrappers = self.prefix / 'share/seance/bin'
        self.wrappers.mkdir(parents=True)
        self.wrapper = self.wrappers / 'opencode'
        shutil.copy2(ROOT / 'resources/bin/opencode', self.wrapper)
        plugin = self.wrappers.parent / 'opencode/seance.mjs'
        plugin.parent.mkdir()
        shutil.copy2(ROOT / 'resources/opencode/seance.mjs', plugin)
        (self.prefix / 'bin').mkdir()
        self.capture = self.root / 'capture.json'
        self.events = self.root / 'events'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('SEANCE_', 'OPENCODE_'))}
        self.env.update(PATH=f'{self.wrappers}:{self.bin}:/usr/bin:/bin',
                        HOME=str(self.root), SEANCE_WORKSPACE_ID='1', SEANCE_SURFACE_ID='3',
                        SEANCE_SOCKET_PATH=str(self.root / 'socket'),
                        TEST_CAPTURE=str(self.capture), TEST_EVENTS=str(self.events))
        self.script(self.bin / 'opencode', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({'args': sys.argv[1:], 'env': dict(os.environ)}))
print('agent output')
sys.exit(int(os.environ.get('TEST_EXIT', '0')))
''')
        self.script(self.prefix / 'bin/seance', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[-1] == 'ping':
    sys.exit(int(os.environ.get('TEST_PING_EXIT', '0')))
if sys.argv[2] == 'opencode-config':
    if os.environ.get('TEST_CONFIG_FAIL'): sys.exit(1)
    config = json.loads(os.environ.get('OPENCODE_CONFIG_CONTENT', '{}'))
    config.setdefault('plugin', []).append(sys.argv[3])
    print(json.dumps(config))
    sys.exit(0)
with Path(os.environ['TEST_EVENTS']).open('a') as out:
    out.write(json.dumps({'args': sys.argv[1:], 'input': sys.stdin.read()}) + '\\n')
print('hook output must be hidden')
sys.exit(int(os.environ.get('TEST_CLEANUP_EXIT', '0')))
''')

    def script(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def invoke(self, *args):
        result = subprocess.run([str(self.wrapper), *args], env=self.env, cwd=self.root,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.stdout, 'agent output\n')
        self.assertEqual(result.stderr, '')
        return result, json.loads(self.capture.read_text())

    def test_preserves_config_paths_inline_plugins_arguments_and_auth_home(self):
        self.env.update(OPENCODE_CONFIG='/custom/opencode.jsonc', OPENCODE_CONFIG_DIR='/custom/config',
                        XDG_CONFIG_HOME=str(self.root / 'config'),
                        OPENCODE_CONFIG_CONTENT=json.dumps({'model': 'test/model', 'plugin': ['user-plugin']}))
        result, call = self.invoke('run', '--model', 'test/model', "a 'prompt' $(literal)")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(call['args'], ['run', '--model', 'test/model', "a 'prompt' $(literal)"])
        for key in ('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'HOME'):
            self.assertEqual(call['env'][key], self.env[key])
        config = json.loads(call['env']['OPENCODE_CONFIG_CONTENT'])
        self.assertEqual(config['model'], 'test/model')
        self.assertEqual(config['plugin'][0], 'user-plugin')
        self.assertTrue(Path(config['plugin'][1]).is_file())
        self.assertTrue(Path(call['env']['SEANCE_OPENCODE_BIN']).samefile(self.prefix / 'bin/seance'))
        self.assertFalse((self.root / '.config/opencode').exists())
        self.assertEqual(json.loads(self.events.read_text())['args'], ['ctl', 'opencode-hook', 'session-end'])

    def test_failure_cleans_up_once_preserves_status_and_hides_hook_output(self):
        self.env.update(TEST_EXIT='42', TEST_CLEANUP_EXIT='7')
        result, _ = self.invoke()
        self.assertEqual(result.returncode, 42)
        self.assertTrue(self.events.exists(), 'agent failure must still clear its status')
        self.assertEqual(len(self.events.read_text().splitlines()), 1)

    def test_passthrough_outside_seance_disabled_or_failed_setup(self):
        for key, value in [('SEANCE_SURFACE_ID', ''), ('SEANCE_WORKSPACE_ID', ''),
                           ('SEANCE_SOCKET_PATH', ''), ('SEANCE_OPENCODE_HOOKS_DISABLED', '1'),
                           ('TEST_PING_EXIT', '1'), ('TEST_CONFIG_FAIL', '1')]:
            with self.subTest(key=key):
                previous = self.env.copy()
                self.env.update({key: value, 'TEST_EXIT': '17'})
                result, call = self.invoke('run', 'hello')
                self.assertEqual(result.returncode, 17)
                self.assertNotIn('SEANCE_OPENCODE_PID', call['env'])
                self.assertNotIn('OPENCODE_CONFIG_CONTENT', call['env'])
                self.assertFalse(self.events.exists())
                self.env = previous

    def test_missing_bundle_passes_through(self):
        (self.wrappers.parent / 'opencode/seance.mjs').unlink()
        self.invoke()
        self.assertFalse(self.events.exists())

    def test_management_remote_and_pure_commands_pass_through(self):
        for args in [('models',), ('--version',), ('debug', 'config'), ('session', 'list'),
                     ('providers',), ('attach', 'http://localhost:1234'), ('serve',), ('web',),
                     ('run', '--attach=http://localhost:1234', 'hello'), ('--pure',), ('run', '--help')]:
            with self.subTest(args=args):
                _, call = self.invoke(*args)
                self.assertEqual(call['args'], list(args))
                self.assertNotIn('SEANCE_OPENCODE_PID', call['env'])
                self.assertFalse(self.events.exists())

    def test_symlinked_wrapper_in_path_does_not_recurse(self):
        links = self.root / 'links'
        links.mkdir()
        (links / 'opencode').symlink_to(self.wrapper)
        self.env['PATH'] = f'{links}:{self.wrappers}:{self.bin}:/usr/bin:/bin'
        result, _ = self.invoke('run', 'hello')
        self.assertEqual(result.returncode, 0)

    def test_plugin_behavior(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node is required to run plugin regression tests')
        result = subprocess.run([node, '--test', str(ROOT / 'tests/opencode_plugin.test.mjs')],
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(os.environ.get('SEANCE_TEST_OPENCODE') and os.environ.get('SEANCE_TEST_BINARY'),
                     'set SEANCE_TEST_OPENCODE and SEANCE_TEST_BINARY for installed OpenCode validation')
class OpenCodeInstalledTests(unittest.TestCase):
    def test_installed_cli_loads_bundled_and_user_plugins_without_changing_config(self):
        with tempfile.TemporaryDirectory(prefix='seance-opencode-installed-') as tmp:
            root = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith(('SEANCE_', 'OPENCODE_', 'XDG_'))}
            for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
                directory = root / key.lower()
                directory.mkdir()
                env[key] = str(directory)
            config_dir = Path(env['XDG_CONFIG_HOME']) / 'opencode'
            config_dir.mkdir()
            marker = root / 'user-loaded'
            user_plugin = root / 'user-plugin.mjs'
            user_plugin.write_text("import { writeFileSync } from 'node:fs'; export const UserPlugin = async () => { writeFileSync(" + json.dumps(str(marker)) + ", 'loaded'); return {}; };\n")
            config_file = config_dir / 'opencode.jsonc'
            original = '// user configuration\n' + json.dumps({'plugin': [str(user_plugin)], 'username': 'fixture-user'})
            config_file.write_text(original)
            capture = root / 'bridge-events'
            bridge = root / 'bridge'
            bridge.write_text('#!/usr/bin/env python3\nimport json, sys\nwith open(' + repr(str(capture)) + ", 'a') as out: out.write(json.dumps({'args':sys.argv[1:], 'body':json.load(sys.stdin)}) + '\\n')\n")
            bridge.chmod(0o755)
            env.update(SEANCE_OPENCODE_BIN=str(bridge), SEANCE_SOCKET_PATH=str(root / 'sock'),
                       SEANCE_SURFACE_ID='3', SEANCE_WORKSPACE_ID='1',
                       OPENCODE_DISABLE_DEFAULT_PLUGINS='1', OPENCODE_DISABLE_MODELS_FETCH='1',
                       OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"ask"},"plugin":[]}')
            config = subprocess.run([os.environ['SEANCE_TEST_BINARY'], 'ctl', 'opencode-config',
                                     str(ROOT / 'resources/opencode/seance.mjs')], env=env,
                                    capture_output=True, text=True, check=True, timeout=5)
            env['OPENCODE_CONFIG_CONTENT'] = config.stdout
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            with (root / 'server.log').open('w+') as log:
                process = subprocess.Popen([os.environ['SEANCE_TEST_OPENCODE'], 'serve', '--hostname', '127.0.0.1', '--port', str(port)],
                                           env=env, cwd=root, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 40
                    while time.monotonic() < deadline:
                        try:
                            with urllib.request.urlopen(f'http://127.0.0.1:{port}/config', timeout=2) as response:
                                resolved = json.load(response)
                            if marker.exists() and capture.exists():
                                break
                            # Config alone doesn't initialize the plugin subsystem.
                            request = urllib.request.Request(f'http://127.0.0.1:{port}/session', data=b'{}', headers={'Content-Type': 'application/json'})
                            with urllib.request.urlopen(request, timeout=5):
                                pass
                        except (OSError, ValueError):
                            pass
                        time.sleep(0.2)
                    else:
                        log.seek(0)
                        self.fail('OpenCode startup failed: ' + log.read()[-8000:])
                    self.assertEqual(resolved['username'], 'fixture-user')
                    self.assertEqual(resolved['permission']['bash'], 'ask')
                    self.assertEqual(len(resolved['plugin']), 2)
                    self.assertEqual(config_file.read_text(), original)
                    self.assertFalse((config_dir / 'plugins/seance-opencode.ts').exists())
                    self.assertEqual(json.loads(capture.read_text().splitlines()[0])['body']['state'], 'Idle')
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


BINARY = Path(os.environ.get('SEANCE_TEST_BINARY', ROOT / 'zig-out/bin/seance')).resolve()


@unittest.skipUnless(BINARY.is_file(), 'build seance to validate its OpenCode socket bridge')
class OpenCodeHookTests(unittest.TestCase):
    def test_native_bridge_routes_state_notifications_and_cleanup_to_the_right_pane(self):
        import socketserver
        import threading
        with tempfile.TemporaryDirectory(prefix='seance-opencode-hook-') as tmp:
            requests = []
            class Handler(socketserver.StreamRequestHandler):
                def handle(self):
                    request = json.loads(self.rfile.readline())
                    requests.append(request)
                    result = {'workspace_id': 99} if request['method'] == 'system.identify' else {}
                    self.wfile.write((json.dumps({'id': request['id'], 'ok': True, 'result': result}) + '\n').encode())
            path = str(Path(tmp) / 'socket')
            with socketserver.UnixStreamServer(path, Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    env = {**os.environ, 'HOME': tmp, 'SEANCE_SOCKET_PATH': path,
                           'SEANCE_WORKSPACE_ID': '7', 'SEANCE_SURFACE_ID': '3'}
                    env.pop('SEANCE_CLAUDE_HOOK_STATE_PATH', None)
                    def invoke(event, payload):
                        result = subprocess.run([str(BINARY), 'ctl', 'opencode-hook', event],
                                                env=env, input=json.dumps(payload), text=True,
                                                capture_output=True, timeout=5)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    invoke('state', {'state': 'Needs input', 'title': 'OpenCode',
                                     'message': "Choose 'red' or blue? $(literal)"})
                    state = requests[0]['params']
                    self.assertEqual((state['workspace_id'], state['key'], state['value']), (7, 'opencode-3', 'Needs input'))
                    self.assertTrue(state['is_agent'])
                    self.assertEqual(state['display_name'], 'OpenCode')
                    notification = [r['params'] for r in requests if r['method'] == 'notification.create'][0]
                    self.assertEqual(notification['workspace_id'], 7)
                    self.assertEqual(notification['surface_id'], 3)
                    self.assertEqual(notification['body'], "Choose 'red' or blue? $(literal)")
                    self.assertNotIn('read', notification)
                    env['SEANCE_SURFACE_ID'] = '4'
                    invoke('state', {'state': 'Running', 'title': 'Completed in project', 'message': 'Other task finished'})
                    self.assertEqual(requests[-3]['params']['value'], 'Running')
                    self.assertEqual(requests[-3]['params']['key'], 'opencode-4')
                    env['SEANCE_SURFACE_ID'] = '3'
                    invoke('session-end', {})
                    self.assertEqual(requests[-1]['method'], 'workspace.clear_status')
                    self.assertEqual(requests[-1]['params'], {'workspace_id': 7, 'key': 'opencode-3'})
                    self.assertFalse((Path(tmp) / '.seance/claude-hook-sessions.json').exists())
                finally:
                    server.shutdown()
                    thread.join(timeout=5)
