"""Antigravity configuration, wrapper, and socket-boundary regressions.

Build first, then run python3 -m unittest discover -s tests -p test_antigravity.py -v.
The normal suite uses a fake agent and the real Séance binary; no model calls.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SEANCE_TEST_BINARY', ROOT / 'zig-out/bin/seance')).resolve()


@unittest.skipUnless(BINARY.is_file(), 'build Séance first')
class AntigravityFixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='seance-agy-test-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.requests = []
        self.focused = False
        owner = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                owner.requests.append(request)
                result = {'workspace_id': 7 if owner.focused else 99}
                self.wfile.write((json.dumps({'id': request['id'], 'ok': True, 'result': result}) + '\n').encode())

        self.server = socketserver.ThreadingUnixStreamServer(str(self.root / 'socket'), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()

        def close_server():
            self.server.shutdown()
            self.server.server_close()
            thread.join(timeout=5)
        self.addCleanup(close_server)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SEANCE_')}
        self.env.update(HOME=str(self.root), SEANCE_SOCKET_PATH=str(self.root / 'socket'),
                        SEANCE_WORKSPACE_ID='7', SEANCE_SURFACE_ID='3')
        self.settings = self.root / '.gemini/antigravity-cli/settings.json'
        self.settings.parent.mkdir(parents=True)

    def ctl(self, command, *args, payload=None, env=None, success=True):
        result = subprocess.run([str(BINARY), 'ctl', command, *map(str, args)],
                                env=env or self.env, input=json.dumps(payload or {}),
                                text=True, capture_output=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, '')
        return result

    def install(self):
        self.ctl('antigravity-config', self.settings)
        return json.loads(self.settings.read_text())

    def session(self, name='session'):
        directory = self.root / name
        directory.mkdir()
        (directory / 'state.json').write_text('{}')
        return {**self.env, 'SEANCE_AGY_SESSION_DIR': str(directory), 'SEANCE_AGY_BIN': str(BINARY)}

    def callback(self, config, payload, env=None):
        return subprocess.run(['/bin/sh', '-c', config['statusLine']['command']],
                              env=env or self.env, input=json.dumps(payload),
                              text=True, capture_output=True, timeout=10, cwd=self.root)

    def statuses(self):
        return [r['params'] for r in self.requests if r['method'] == 'workspace.set_status']

    def notifications(self):
        return [r['params'] for r in self.requests if r['method'] == 'notification.create']


class AntigravityTests(AntigravityFixture):
    def test_install_preserves_settings_callback_output_and_exit_status(self):
        original = {'model': 'user-model', 'permissions': {'ask': ['command(*)']},
                    'future-setting': {'preserve': True}, 'statusLine': {
                        'type': 'command', 'command': 'cat; printf "\\nuser \'quoted\' output"; exit 17',
                        'padding': 2, 'stack_with_default': False}}
        source = json.dumps(original) + '\n'
        self.settings.write_text(source)
        config = self.install()
        for key in ('model', 'permissions', 'future-setting'):
            self.assertEqual(config[key], original[key])
        for key in ('padding', 'stack_with_default'):
            self.assertEqual(config['statusLine'][key], original['statusLine'][key])
        payload = {'agent_state': 'working', 'conversation_id': 'a', 'literal': "$(touch injected) 'quoted'"}
        for env in (self.env, self.session()):
            result = self.callback(config, payload, env)
            self.assertEqual(result.returncode, 17)
            self.assertEqual(result.stdout, json.dumps(payload) + "\nuser 'quoted' output")
            self.assertEqual(result.stderr, '')
        self.assertFalse((self.root / 'injected').exists())
        self.assertEqual(self.settings.with_name('settings.json.seance-backup').read_text(), source)
        self.assertEqual(len(self.statuses()), 1)

    def test_install_is_idempotent_concurrent_and_preserves_symlink(self):
        target = self.root / "settings with 'quotes'.json"
        target.write_text('{"model":"keep"}')
        self.settings.symlink_to(target)
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            list(pool.map(lambda _: self.install(), range(5)))
        self.assertTrue(self.settings.is_symlink())
        config = json.loads(target.read_text())
        self.assertEqual(config['statusLine']['command'].count('# seance-antigravity-v1'), 1)
        stamp = target.stat().st_mtime_ns
        self.install()
        self.assertEqual(target.stat().st_mtime_ns, stamp)
        self.assertEqual(target.with_name(target.name + '.seance-backup').read_text(), '{"model":"keep"}')

    def test_empty_profile_retains_default_status_and_is_inert_outside_wrapper(self):
        for status in (None, {}, {'type': 'command', 'command': ''}):
            with self.subTest(status=status):
                self.settings.write_text(json.dumps({'statusLine': status}))
                config = self.install()
                self.assertTrue(config['statusLine']['stack_with_default'])
                result = self.callback(config, {'agent_state': 'working'})
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
                self.assertEqual(self.requests, [])

    def test_invalid_and_disabled_config_is_untouched(self):
        for source in ('', '{broken', '[]', '{"statusLine":17}',
                       '{"statusLine":{"command":17}}', '{"statusLine":{"enabled":false}}',
                       '{"statusLine":{"type":"unsupported"}}'):
            with self.subTest(source=source):
                self.settings.write_text(source)
                result = self.ctl('antigravity-config', self.settings, success=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.settings.read_text(), source)
                self.assertFalse(self.settings.with_name('settings.json.seance-backup').exists())

    def test_readonly_configuration_is_not_replaced(self):
        self.settings.write_text('{"model":"keep"}')
        self.settings.chmod(0o444)
        result = self.ctl('antigravity-config', self.settings, success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.settings.read_text(), '{"model":"keep"}')
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o444)

    def test_dangling_settings_symlink_is_not_replaced(self):
        target = self.root / 'not-created.json'
        self.settings.symlink_to(target)
        result = self.ctl('antigravity-config', self.settings, success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertFalse(target.exists())

    def test_real_callback_maps_approvals_idle_and_background_work_once(self):
        config = self.install()
        env = self.session()
        for payload in (
            {'agent_state': 'idle'},
            {'agent_state': 'working'},
            {'agent_state': 'tool_use'},  # a tool by itself is not a permission request
            {'agent_state': 'tool_use', 'tool_confirmation_pending': True},
            {'agent_state': 'tool_use', 'tool_confirmation_pending': True},
            {'agent_state': 'working'},  # approved
            {'agent_state': 'idle', 'task_count': 1},
            {'agent_state': 'idle', 'task_count': 0},
            {'agent_state': 'idle'},
        ):
            result = self.callback(config, {'conversation_id': 'a', 'cwd': '/project', **payload}, env)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
        self.assertEqual([s['value'] for s in self.statuses()], ['Idle', 'Running', 'Needs input', 'Running', 'Idle'])
        self.assertTrue(all(s['is_agent'] and s['key'] == 'antigravity-3' and s['workspace_id'] == 7
                            and s['display_name'] == 'Antigravity' for s in self.statuses()))
        self.assertEqual([n['title'] for n in self.notifications()], ['Antigravity needs input', 'Antigravity is idle'])
        self.assertTrue(all(n['surface_id'] == 3 and n['workspace_id'] == 7 and 'read' not in n
                            for n in self.notifications()))

    def test_denial_cancellation_errors_resume_and_unknown_states(self):
        env = self.session()
        def update(state, session='a', **fields):
            self.ctl('antigravity-hook', 'state', payload={'agent_state': state, 'conversation_id': session, **fields}, env=env)
        update('idle')
        update('working')
        update('tool_use', tool_confirmation_pending=True)
        update('idle')  # rejected, no claim of successful completion
        update('working')
        update('idle')  # cancelled
        update('working')
        update('error')
        update('idle')  # failure must not generate another completion notification
        update('working')
        update('idle', 'resumed-session')
        count = len(self.requests)
        update('a-future-state')
        self.assertEqual(len(self.requests), count)
        self.assertEqual([n['title'] for n in self.notifications()],
                         ['Antigravity needs input', 'Antigravity is idle', 'Antigravity is idle'])

    def test_concurrent_callbacks_notify_once_and_panes_are_independent(self):
        env = self.session()
        other = {**self.session('other'), 'SEANCE_SURFACE_ID': '4'}
        payload = {'agent_state': 'tool_use', 'tool_confirmation_pending': True, 'session_id': 'same-conversation'}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda _: self.ctl('antigravity-hook', 'state', payload=payload, env=env), range(6)))
        self.focused = True
        self.ctl('antigravity-hook', 'state', payload=payload, env=other)
        self.assertEqual([s['key'] for s in self.statuses()], ['antigravity-3', 'antigravity-4'])
        self.assertEqual(len(self.notifications()), 2)
        self.assertNotIn('read', self.notifications()[0])
        self.assertTrue(self.notifications()[1]['read'])

    def test_exit_and_late_callbacks_cannot_resurrect_status(self):
        env = self.session()
        self.ctl('antigravity-hook', 'state', payload={'agent_state': 'working'}, env=env)
        self.ctl('antigravity-hook', 'session-end', env=env)
        self.assertEqual(self.requests[-1]['method'], 'workspace.clear_status')
        self.assertEqual(self.requests[-1]['params'], {'workspace_id': 7, 'key': 'antigravity-3'})
        count = len(self.requests)
        self.ctl('antigravity-hook', 'state', payload={'agent_state': 'working'}, env=env)
        shutil.rmtree(env['SEANCE_AGY_SESSION_DIR'])
        self.ctl('antigravity-hook', 'state', payload={'agent_state': 'working'}, env=env)
        self.assertEqual(len(self.requests), count)
        self.assertFalse(Path(env['SEANCE_AGY_SESSION_DIR']).exists())

    def test_failed_socket_update_is_retried_on_next_snapshot(self):
        env = self.session()
        unavailable = {**env, 'SEANCE_SOCKET_PATH': str(self.root / 'unavailable')}
        payload = {'agent_state': 'working', 'conversation_id': 'a'}
        result = self.ctl('antigravity-hook', 'state', payload=payload, env=unavailable, success=False)
        self.assertNotEqual(result.returncode, 0)
        self.ctl('antigravity-hook', 'state', payload=payload, env=env)
        self.assertEqual([s['value'] for s in self.statuses()], ['Running'])


class AntigravityWrapperTests(AntigravityFixture):
    def setUp(self):
        super().setUp()
        self.prefix = self.root / "prefix with 'quotes'"
        self.wrapper = self.prefix / 'share/seance/bin/agy'
        self.wrapper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'resources/bin/agy', self.wrapper)
        (self.prefix / 'bin').mkdir()
        (self.prefix / 'bin/seance').symlink_to(BINARY)
        real_bin = self.root / 'real-bin'
        real_bin.mkdir()
        self.capture = self.root / 'capture.json'
        agent = real_bin / 'agy'
        agent.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({'args':sys.argv[1:], 'env':dict(os.environ)}))
if os.environ.get('SEANCE_AGY_SESSION_DIR'):
    config=json.loads((Path.home()/'.gemini/antigravity-cli/settings.json').read_text())
    subprocess.run(['/bin/sh','-c',config['statusLine']['command']], input='{"agent_state":"working"}', text=True, check=True)
print('agent output')
if os.environ.get('TEST_WAIT'): time.sleep(60)
sys.exit(int(os.environ.get('TEST_EXIT','0')))
''')
        agent.chmod(0o755)
        self.env.update(PATH=f'{self.wrapper.parent}:{real_bin}:/usr/bin:/bin',
                        TEST_CAPTURE=str(self.capture), XDG_RUNTIME_DIR=str(self.root))

    def invoke(self, *args, success=True):
        result = subprocess.run([str(self.wrapper), *args], env=self.env, cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.stdout, 'agent output\n')
        if success:
            self.assertEqual(result.stderr, '')
        return result, json.loads(self.capture.read_text())

    def test_wrapper_preserves_profile_arguments_exit_status_and_cleans_up(self):
        self.settings.write_text('{"model":"unchanged","permissions":{"ask":["command(*)"]}}')
        self.env['TEST_EXIT'] = '42'
        args = ['--model', 'test-model', '-i', "a 'prompt' $(literal)"]
        result, call = self.invoke(*args)
        self.assertEqual(result.returncode, 42)
        self.assertEqual(call['args'], args)
        self.assertEqual(call['env']['HOME'], self.env['HOME'])
        self.assertEqual(json.loads(self.settings.read_text())['permissions'], {'ask': ['command(*)']})
        self.assertFalse(Path(call['env']['SEANCE_AGY_SESSION_DIR']).exists())
        self.assertEqual([r['method'] for r in self.requests], ['system.ping', 'workspace.set_status', 'workspace.clear_status'])

    def test_wrapper_passes_through_management_print_and_disabled_launches(self):
        for args in (['--help'], ['models'], ['plugin', 'list'], ['--model', 'test', 'mcp', 'list'],
                     ['-p', 'hello'], ['-p=hello'], ['--print=hello'], ['--output-format', 'stream-json']):
            with self.subTest(args=args):
                _, call = self.invoke(*args)
                self.assertEqual(call['args'], args)
                self.assertNotIn('SEANCE_AGY_SESSION_DIR', call['env'])
                self.assertFalse(self.settings.exists())
        for key, value in (('SEANCE_ANTIGRAVITY_HOOKS_DISABLED', '1'), ('SEANCE_SURFACE_ID', ''),
                           ('SEANCE_SOCKET_PATH', str(self.root / 'missing'))):
            with self.subTest(key=key):
                original = self.env.copy()
                self.env.update({key: value, 'SEANCE_AGY_SESSION_DIR': 'inherited-parent'})
                _, call = self.invoke()
                self.assertNotIn('SEANCE_AGY_SESSION_DIR', call['env'])
                self.assertFalse(self.settings.exists())
                self.env = original

    def test_wrapper_handles_help_as_prompt_and_symlinks_without_recursion(self):
        links = self.root / 'links'
        links.mkdir()
        (links / 'agy').symlink_to(self.wrapper)
        self.env['PATH'] = f"{links}:{self.env['PATH']}"
        _, call = self.invoke('-i', '--help')
        self.assertEqual(call['args'], ['-i', '--help'])
        self.assertIn('SEANCE_AGY_SESSION_DIR', call['env'])

    def test_wrapper_config_failure_does_not_block_agent_or_rewrite_config(self):
        self.settings.write_text('{broken')
        self.env['TEST_EXIT'] = '17'
        result, call = self.invoke(success=False)
        self.assertEqual(result.returncode, 17)
        self.assertNotIn('SEANCE_AGY_SESSION_DIR', call['env'])
        self.assertEqual(self.settings.read_text(), '{broken')
        self.assertIn('could not enable Antigravity tracking', result.stderr)

    def test_wrapper_termination_reaches_child_and_clears_status(self):
        self.env['TEST_WAIT'] = '1'
        process = subprocess.Popen([str(self.wrapper)], env=self.env, cwd=self.root,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not self.statuses() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.statuses(), 'agent must start before termination')
            call = json.loads(self.capture.read_text())
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stderr)
            self.assertFalse(Path(call['env']['SEANCE_AGY_SESSION_DIR']).exists())
            self.assertEqual(self.requests[-1]['method'], 'workspace.clear_status')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
