"""oh-my-pi (omp) wrapper, extension, and socket-boundary regressions.

Node runs the extension unit tests; the integration itself uses omp's runtime.
Set SEANCE_TEST_OMP to a real omp binary for the installed-CLI test.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SEANCE_TEST_BINARY', ROOT / 'zig-out/bin/seance')).resolve()


def install(prefix):
    """Lay out the wrapper and extension as `zig build install` does."""
    wrappers = prefix / 'share/seance/bin'
    wrappers.mkdir(parents=True)
    shutil.copy2(ROOT / 'resources/bin/omp', wrappers / 'omp')
    extension = prefix / 'share/seance/omp/seance.mjs'
    extension.parent.mkdir()
    shutil.copy2(ROOT / 'resources/omp/seance.mjs', extension)
    (prefix / 'bin').mkdir()
    return wrappers / 'omp', extension


def script(path, source):
    path.write_text(source)
    path.chmod(0o755)


class OmpWrapperTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='seance-omp-test-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.prefix = self.root / "prefix with 'quotes'"
        self.wrapper, self.extension = install(self.prefix)
        self.bin = self.root / 'real-bin'
        self.bin.mkdir()
        self.capture = self.root / 'capture.json'
        self.events = self.root / 'events'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SEANCE_')}
        self.env.update(PATH=f'{self.wrapper.parent}:{self.bin}:/usr/bin:/bin',
                        HOME=str(self.root), SEANCE_WORKSPACE_ID='1', SEANCE_SURFACE_ID='3',
                        SEANCE_SOCKET_PATH=str(self.root / 'socket'),
                        TEST_CAPTURE=str(self.capture), TEST_EVENTS=str(self.events))
        script(self.bin / 'omp', '''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGINT, signal.SIG_DFL)
Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({'args': sys.argv[1:], 'env': dict(os.environ),
                                                        'pid': os.getpid(), 'ppid': os.getppid()}))
print('agent output', flush=True)
if os.environ.get('TEST_SLEEP'): time.sleep(30)
sys.exit(int(os.environ.get('TEST_EXIT', '0')))
''')
        # Shell, not Python: the wrapper gives `ctl ping` 0.75 s, even on a loaded machine.
        script(self.prefix / 'bin/seance', '''#!/bin/sh
case "$*" in *' ping') exit "${TEST_PING_EXIT:-0}" ;; esac
{ printf '%s\\t' "$*"; cat; echo; } >> "$TEST_EVENTS"
echo 'hook output must be hidden'
exit "${TEST_CLEANUP_EXIT:-0}"
''')

    def invoke(self, *args):
        result = subprocess.run([str(self.wrapper), *args], env=self.env, cwd=self.root,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.stdout, 'agent output\n')
        self.assertEqual(result.stderr, '')
        return result, json.loads(self.capture.read_text())

    def hook_calls(self):
        if not self.events.exists():
            return []
        return [dict(zip(('args', 'input'), (args.split(' '), payload)))
                for args, payload in (line.split('\t', 1) for line in self.events.read_text().splitlines() if line)]

    def assert_tracked(self, call, args):
        self.assertEqual(call['args'][0], '-e')
        self.assertTrue(Path(call['args'][1]).samefile(self.extension))
        self.assertEqual(call['args'][2:], list(args))
        self.assertTrue(Path(call['env']['SEANCE_OMP_BIN']).samefile(self.prefix / 'bin/seance'))
        self.assertEqual(call['env']['SEANCE_OMP_PID'], str(call['ppid']))
        self.assertEqual(call['env']['SEANCE_OMP_HOOKS_DISABLED'], '1')
        self.assertEqual(self.hook_calls(), [{'args': ['ctl', 'omp-hook', 'session-end'], 'input': '{}'}])

    def assert_passed_through(self, call, args):
        self.assertEqual(call['args'], list(args))
        self.assertNotIn('SEANCE_OMP_PID', call['env'])
        self.assertNotIn('SEANCE_OMP_BIN', call['env'])
        self.assertEqual(self.hook_calls(), [])

    def test_injects_extension_and_clears_status_on_exit(self):
        args = ['--model', 'test/model', '--mode', 'text', "a 'prompt' $(literal)"]
        result, call = self.invoke(*args)
        self.assertEqual(result.returncode, 0)
        self.assert_tracked(call, args)
        self.events.unlink()
        result, call = self.invoke('--mode=text', '--continue')
        self.assert_tracked(call, ['--mode=text', '--continue'])

    def test_failure_cleans_up_once_and_preserves_status(self):
        self.env.update(TEST_EXIT='42', TEST_CLEANUP_EXIT='7')
        result, call = self.invoke()
        self.assertEqual(result.returncode, 42)
        self.assert_tracked(call, [])

    def run_until_started(self):
        self.env['TEST_SLEEP'] = '1'
        process = subprocess.Popen([str(self.wrapper)], env=self.env, cwd=self.root, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(process.stdout.close)
        self.addCleanup(lambda: process.poll() is None and os.killpg(process.pid, signal.SIGKILL))
        self.assertEqual(process.stdout.readline(), 'agent output\n')
        return process, json.loads(self.capture.read_text())

    def test_terminal_hangup_and_interrupt_clear_status(self):
        for sig, code in [(signal.SIGTERM, 143), (signal.SIGHUP, 129), (signal.SIGINT, 130)]:
            with self.subTest(signal=sig.name):
                self.events.unlink(missing_ok=True)
                process, call = self.run_until_started()
                os.killpg(process.pid, sig)
                self.assertEqual(process.wait(timeout=10), code)
                self.assert_tracked(call, [])

    def test_killed_agent_still_clears_status(self):
        process, call = self.run_until_started()
        os.kill(call['pid'], signal.SIGKILL)
        self.assertEqual(process.wait(timeout=10), 137)
        self.assert_tracked(call, [])

    def test_passthrough_outside_seance_disabled_or_unreachable(self):
        for key, value in [('SEANCE_SURFACE_ID', ''), ('SEANCE_WORKSPACE_ID', ''),
                           ('SEANCE_SOCKET_PATH', ''), ('SEANCE_OMP_HOOKS_DISABLED', '1'),
                           ('TEST_PING_EXIT', '1')]:
            with self.subTest(key=key):
                self.events.unlink(missing_ok=True)
                previous = self.env.copy()
                self.env.update({key: value, 'TEST_EXIT': '17'})
                try:
                    result, call = self.invoke('hello')
                finally:
                    self.env = previous
                self.assertEqual(result.returncode, 17)
                self.assert_passed_through(call, ['hello'])
                self.assertEqual(call['env'].get('SEANCE_OMP_HOOKS_DISABLED'), value if key == 'SEANCE_OMP_HOOKS_DISABLED' else None)

    def test_missing_bundle_or_binary_passes_through(self):
        self.extension.unlink()
        _, call = self.invoke('hello')
        self.assert_passed_through(call, ['hello'])
        shutil.copy2(ROOT / 'resources/omp/seance.mjs', self.extension)
        (self.prefix / 'bin/seance').unlink()
        _, call = self.invoke('hello')
        self.assert_passed_through(call, ['hello'])

    def test_print_export_machine_modes_and_subcommands_pass_through(self):
        for args in [('-p', 'hi'), ('--print', 'hi'), ('-h',), ('--help',), ('-v',), ('--version',),
                     ('--export', 'session.jsonl'), ('--export=session.jsonl',), ('--alias', 'work'),
                     ('--trusted-extension', 'ext.ts'), ('--trusted-extension=ext.ts',),
                     ('--mode', 'json', 'hi'), ('--mode=rpc',), ('--mode', 'rpc-ui'),
                     ('commit',), ('completions', 'bash'), ('config', 'list'), ('plugin', 'list'),
                     ('stats',), ('session', 'pack'), ('anonymize', 'x'), ('update',), ('acp',)]:
            with self.subTest(args=args):
                self.events.unlink(missing_ok=True)
                _, call = self.invoke(*args)
                self.assert_passed_through(call, args)

    def test_options_after_separator_are_message_text(self):
        for args in [('--', '--help'), ('--', '-p', 'hi'), ('--', '--trusted-extension', 'x')]:
            with self.subTest(args=args):
                self.events.unlink(missing_ok=True)
                _, call = self.invoke(*args)
                self.assert_tracked(call, args)

    def test_symlinked_wrapper_in_path_does_not_recurse(self):
        links = self.root / 'links'
        links.mkdir()
        (links / 'omp').symlink_to(self.wrapper)
        self.env['PATH'] = f'{links}:{self.wrapper.parent}:{self.bin}:/usr/bin:/bin'
        result, call = self.invoke('hello')
        self.assertEqual(result.returncode, 0)
        self.assert_tracked(call, ['hello'])

    def test_missing_real_omp(self):
        (self.bin / 'omp').unlink()
        result = subprocess.run([str(self.wrapper)], env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stderr), (127, 'omp: command not found\n'))

    def test_extension_behavior(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node is required to run extension regression tests')
        result = subprocess.run([node, '--test', str(ROOT / 'tests/omp_extension.test.mjs')],
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(os.environ.get('SEANCE_TEST_OMP'), 'set SEANCE_TEST_OMP for installed omp validation')
class OmpInstalledTests(unittest.TestCase):
    """Drive a real omp in RPC mode, whose main session has a UI like the TUI.

    The model-free checks run with SEANCE_TEST_OMP alone. Set SEANCE_TEST_OMP_MODEL
    (e.g. a small, cheap model) to also run prompted turns; those spend tokens.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='seance-omp-installed-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.omp = os.environ['SEANCE_TEST_OMP']
        self.prefix = self.root / "prefix with 'quotes'"
        self.wrapper, self.extension = install(self.prefix)
        self.cwd = self.root / 'project'
        self.cwd.mkdir()
        self.log = self.root / 'calls.jsonl'
        script(self.prefix / 'bin/seance', '''#!/usr/bin/env python3
import json, os, sys
if sys.argv[-1] == 'ping':
    sys.exit(0)
with open(os.environ['TEST_EVENTS'], 'a') as out:
    out.write(json.dumps({'args': sys.argv[1:], 'input': json.loads(sys.stdin.read() or 'null')}) + '\\n')
''')
        # Reports what omp's own notifications resolve to once the session ends.
        self.probe = self.root / 'probe.mjs'
        self.probe.write_text('''import { appendFileSync } from "node:fs";
export default function probe(pi) {
  pi.on("session_shutdown", async () => {
    const { lookup } = await import("@oh-my-pi/pi-coding-agent/config/registry");
    const values = Object.fromEntries(["completion.notify", "ask.notify"].map((id) => [id, lookup(id).get(pi.pi.settings)]));
    appendFileSync(process.env.TEST_EVENTS, JSON.stringify({ probe: values }) + "\\n");
  });
}
''')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SEANCE_')}
        self.env.update(SEANCE_OMP_BIN=str(self.prefix / 'bin/seance'), SEANCE_SOCKET_PATH=str(self.root / 'socket'),
                        SEANCE_SURFACE_ID='3', SEANCE_WORKSPACE_ID='1', TEST_EVENTS=str(self.log))

    def calls(self):
        if not self.log.exists():
            return []
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.log.unlink()
        return calls

    def hooks(self, calls):
        return [c['args'][2] for c in calls if 'args' in c]

    def rpc(self, commands, env=None, extra=('--no-session',)):
        args = [self.omp, '--no-extensions', '-e', str(self.extension), *extra, '--mode', 'rpc']
        if os.environ.get('SEANCE_TEST_OMP_MODEL'):
            args += ['--model', os.environ['SEANCE_TEST_OMP_MODEL']]
        process = subprocess.Popen(args, cwd=self.cwd, env=env or self.env, text=True, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            for command in commands:
                process.stdin.write(json.dumps(command) + '\n')
            process.stdin.flush()
            prompted = any(c['type'] == 'prompt' for c in commands)
            responses = 0
            for line in process.stdout:
                try:
                    frame = json.loads(line)
                except ValueError:
                    continue
                if frame.get('type') == 'response':
                    self.assertIsNot(frame.get('success'), False, frame)
                    responses += 1
                    if not prompted and responses == len(commands):
                        break
                if frame.get('type') == 'session_settled':
                    break
            process.stdin.close()
            process.wait(timeout=300)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
        return self.calls()

    def test_session_lifecycle_without_a_model(self):
        state = [{'type': 'get_state'}]
        self.assertCountEqual(self.rpc(state, extra=('--no-session', '-e', str(self.probe))), [
            {'args': ['ctl', 'omp-hook', 'session-end'], 'input': {}},
            {'probe': {'completion.notify': 'off', 'ask.notify': 'off'}},
        ])
        # /new and /fork switch sessions inside one process, so neither ends the pane's session
        # (only the shutdown's session-end). /new abandons any running turn and goes idle
        # silently; /fork keeps the run. fork is a no-op under --no-session, so these need a
        # session directory.
        for command, hooks in (('new_session', ['state', 'session-end']), ('fork', ['session-end'])):
            with self.subTest(command=command):
                calls = self.rpc(state + [{'type': command}], extra=('--session-dir', str(self.root / 'sessions')))
                self.assertEqual(self.hooks(calls), hooks)
        self.assertEqual(self.rpc(state, extra=('--no-session', '--no-ui')), [], 'headless sessions are untracked')
        outside = {k: v for k, v in self.env.items() if k != 'SEANCE_OMP_BIN'}
        self.assertEqual(self.rpc(state, env=outside), [], 'inert outside the wrapper')

    def test_wrapper_passes_management_commands_to_real_omp(self):
        env = {**self.env, 'PATH': f'{self.wrapper.parent}:{Path(self.omp).resolve().parent}:/usr/bin:/bin'}
        env.pop('SEANCE_OMP_BIN')
        result = subprocess.run([str(self.wrapper), '--version'], env=env, cwd=self.cwd, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('omp', result.stdout)
        self.assertEqual(self.calls(), [])

    @unittest.skipUnless(os.environ.get('SEANCE_TEST_OMP_MODEL'), 'set SEANCE_TEST_OMP_MODEL for prompted turns')
    def test_prompted_turns(self):
        token = 'seance-probe-' + os.urandom(4).hex()
        (self.cwd / 'note.txt').write_text(token + '\n')
        calls = self.rpc([{'type': 'prompt', 'message':
                           'Use the read tool on note.txt in the current directory, then reply with exactly its contents.'}])
        hooks = self.hooks(calls)
        self.assertEqual((hooks[0], hooks[-2:], hooks.count('stop')), ('prompt-submit', ['stop', 'session-end'], 1), calls)
        self.assertEqual(hooks[hooks.index('stop') - 1], 'post-tool-use', calls)
        reads = [c['input'] for c in calls if c['args'][2] == 'pre-tool-use' and c['input'].get('tool_name') == 'read']
        self.assertTrue(any(r['tool_input'].get('path', '').endswith('note.txt') for r in reads), calls)
        stop = next(c['input'] for c in calls if c['args'][2] == 'stop')
        self.assertEqual(stop['cwd'], str(self.cwd))
        self.assertIn(token, stop['last_assistant_message'])

        # A subagent runs this extension too; its own session must not reach the pane.
        calls = self.rpc([{'type': 'prompt', 'message':
                           'Use the task tool to spawn exactly one subagent whose only job is to read note.txt in the '
                           'current directory and report its contents. Do not read the file yourself. Then reply with '
                           'exactly its contents.'}])
        hooks = self.hooks(calls)
        names = [c['input'].get('tool_name') for c in calls if c['args'][2] == 'pre-tool-use']
        self.assertIn('task', names, calls)
        self.assertNotIn('yield', names, calls)
        self.assertEqual((hooks.count('session-end'), hooks[-2:], hooks.count('stop'), hooks.count('prompt-submit')),
                         (1, ['stop', 'session-end'], 1, 1), calls)

        subprocess.run([self.omp, '--no-extensions', '-e', str(self.extension), '--no-session', '--model',
                        os.environ['SEANCE_TEST_OMP_MODEL'], '-p', 'Reply with just: pong'], cwd=self.cwd, env=self.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300, check=True)
        self.assertEqual(self.calls(), [], 'print mode is untracked')


@unittest.skipUnless(BINARY.is_file(), 'build Séance to validate its omp socket bridge')
class OmpHookTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='seance-omp-hook-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.requests = []
        owner = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                owner.requests.append(request)
                result = {'workspace_id': 99} if request['method'] == 'system.identify' else {}
                self.wfile.write((json.dumps({'id': request['id'], 'ok': True, 'result': result}) + '\n').encode())

        server = socketserver.ThreadingUnixStreamServer(str(self.root / 'socket'), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def close_server():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.addCleanup(close_server)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SEANCE_')}
        self.env.update(HOME=str(self.root), SEANCE_SOCKET_PATH=str(self.root / 'socket'),
                        SEANCE_WORKSPACE_ID='7', SEANCE_SURFACE_ID='3')

    def hook(self, event, payload=None):
        self.requests.clear()
        result = subprocess.run([str(BINARY), 'ctl', 'omp-hook', event], env=self.env,
                                input=json.dumps(payload or {}), text=True, capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, 'OK\n', ''))
        return self.requests

    def status(self, requests):
        statuses = [r['params'] for r in requests if r['method'] == 'workspace.set_status']
        self.assertEqual(len(statuses), 1, requests)
        status = statuses[0]
        self.assertEqual((status['workspace_id'], status['key'], status['display_name']), (7, 'omp-3', 'omp'))
        self.assertTrue(status['is_agent'])
        return status['value']

    def notifications(self, requests):
        return [r['params'] for r in requests if r['method'] == 'notification.create']

    def test_tool_turn_status(self):
        self.assertEqual(self.status(self.hook('prompt-submit')), 'Running')
        self.assertEqual(self.status(self.hook('pre-tool-use', {'tool_name': 'read', 'tool_input': {'path': '/a/b.txt'}})), 'Reading b.txt')
        self.assertEqual(self.status(self.hook('pre-tool-use', {'tool_name': 'bash', 'tool_input': {'command': 'make'}})), 'Running make')
        self.assertEqual(self.status(self.hook('pre-tool-use', {'tool_name': 'Needs input'})), 'Needs input')
        self.assertEqual(self.status(self.hook('post-tool-use')), 'Running')
        requests = self.hook('stop', {'cwd': "/work/a 'project'", 'last_assistant_message': "All done: 'x' $(y)"})
        self.assertEqual(self.status(requests), 'Idle')
        notification = self.notifications(requests)[0]
        self.assertEqual((notification['title'], notification['body']), ("Completed in a 'project'", "All done: 'x' $(y)"))

    def test_questions_and_approvals_need_input_and_notify(self):
        for kind, message, body in [('input', 'Which database?', 'Waiting: Which database?'),
                                    ('permission', 'Approve bash', 'Permission: Approve bash')]:
            with self.subTest(kind=kind):
                requests = self.hook('notification', {'notification_type': kind, 'message': message})
                self.assertEqual(self.status(requests), 'Needs input')
                notification = self.notifications(requests)[0]
                self.assertEqual((notification['title'], notification['body']), ('oh-my-pi', body))
                self.assertEqual((notification['workspace_id'], notification['surface_id']), (7, 3))

    def test_session_end_clears_this_panes_status(self):
        requests = self.hook('session-end')
        self.assertEqual(requests[-1]['method'], 'workspace.clear_status')
        self.assertEqual(requests[-1]['params'], {'workspace_id': 7, 'key': 'omp-3'})

    def test_state_idle_sets_idle_without_a_notification(self):
        requests = self.hook('state', {'state': 'Idle'})
        self.assertEqual(self.status(requests), 'Idle')
        self.assertEqual(self.notifications(requests), [])

    def test_usage(self):
        result = subprocess.run([str(BINARY), 'ctl', 'omp-hook'], env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn('usage: omp-hook <', result.stderr)
