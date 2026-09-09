import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SeancePlugin } from '../resources/opencode/seance.mjs';

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "seance-plugin-' "));
  t.after(() => rm(root, { recursive: true, force: true }));
  const capture = join(root, 'events');
  const binary = join(root, 'seance');
  await writeFile(binary, `#!/usr/bin/env node
const { appendFileSync } = require('node:fs');
(async () => {
let text = '';
for await (const chunk of process.stdin) text += chunk;
appendFileSync(${JSON.stringify(capture)}, JSON.stringify({args: process.argv.slice(2), payload: JSON.parse(text), surface: process.env.SEANCE_SURFACE_ID}) + '\\n');
${options.hang ? 'setInterval(() => {}, 1000);' : ''}
${options.fail ? 'process.exitCode = 1;' : ''}
})();
`, { mode: 0o755 });
  const previous = { ...process.env };
  Object.assign(process.env, { SEANCE_OPENCODE_BIN: binary, SEANCE_SOCKET_PATH: join(root, 'sock'),
    SEANCE_SURFACE_ID: options.surface ?? '3', SEANCE_WORKSPACE_ID: '1' });
  delete process.env.SEANCE_OPENCODE_HOOKS_DISABLED;
  const lookups = [];
  const hooks = await SeancePlugin({ directory: "/tmp/a 'project'", client: { session: { get: async ({ path }) => {
    lookups.push(path.id);
    if (options.lookupFailure) throw Error('unavailable');
    return { data: { id: path.id, parentID: options.parents?.[path.id] } };
  } } } });
  process.env = previous;
  const events = async () => (await readFile(capture, 'utf8')).trim().split('\n').map(JSON.parse);
  const emit = (type, properties) => hooks.event({ event: { type, properties } });
  const status = (id, type) => emit('session.status', { sessionID: id, status: { type } });
  const notices = async () => (await events()).filter((e) => e.payload.title);
  const last = async () => (await events()).at(-1).payload;
  return { hooks, events, emit, status, notices, last, lookups, root, binary };
}

test('starts idle, tracks resumed sessions, and emits one completion with literal text', async (t) => {
  const f = await fixture(t);
  assert.deepEqual(await f.last(), { state: 'Idle' });
  await f.status('resumed', 'busy');
  await f.hooks['experimental.text.complete']({ sessionID: 'resumed' }, { text: "It’s done: 'quoted' $(touch /tmp/never) `literal`\nnext" });
  await f.status('resumed', 'idle');
  await f.emit('session.idle', { sessionID: 'resumed' });
  assert.deepEqual(f.lookups, ['resumed']);
  assert.equal((await f.notices()).length, 1);
  assert.deepEqual(await f.last(), { state: 'Idle', title: "Completed in a 'project'", message: "It’s done: 'quoted' $(touch /tmp/never) `literal` next" });
});

test('subagent idle cannot hide a working parent or announce task completion', async (t) => {
  const f = await fixture(t);
  await f.emit('session.created', { info: { id: 'root' } });
  await f.status('root', 'busy');
  await f.emit('session.created', { info: { id: 'child', parentID: 'root' } });
  await f.status('child', 'busy');
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 0);
  await f.status('root', 'idle');
  assert.equal((await f.notices()).length, 1);
  assert.deepEqual(f.lookups, []);
});

test('completion waits for a still running background child', async (t) => {
  const f = await fixture(t, { parents: { child: 'root' } });
  await f.status('root', 'busy');
  await f.status('child', 'busy');
  await f.status('root', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 0);
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 1);
});

test('independent sessions each notify without hiding another session activity', async (t) => {
  const f = await fixture(t);
  for (const id of ['first', 'second']) {
    await f.emit('session.created', { info: { id } });
    await f.status(id, 'busy');
  }
  await f.status('first', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 1);
  await f.status('second', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 2);
});

test('pending permissions dominate concurrent activity until every request is answered', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'busy');
  await f.emit('permission.asked', { sessionID: 'root', id: 'a', permission: 'bash', patterns: ['echo hello'] });
  await f.emit('permission.asked', { sessionID: 'root', id: 'b', permission: 'edit' });
  await f.emit('permission.asked', { sessionID: 'root', id: 'b', permission: 'edit' });
  await f.status('root', 'busy');
  await f.status('child', 'busy');
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Needs input');
  assert.equal((await f.notices()).filter((e) => e.payload.title === 'OpenCode').length, 2);
  await f.emit('permission.replied', { sessionID: 'root', requestID: 'a', reply: 'once' });
  assert.equal((await f.last()).state, 'Needs input');
  await f.emit('permission.replied', { sessionID: 'root', requestID: 'b', reply: 'reject' });
  assert.equal((await f.last()).state, 'Running');
});

test('questions use the actual question text and clear on reply or rejection', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'busy');
  for (const prefix of ['question', 'question.v2']) {
    await f.emit(`${prefix}.asked`, { sessionID: 'root', id: 'q', questions: [{ question: 'Which file?' }] });
    assert.equal((await f.last()).message, 'Which file?');
    assert.equal((await f.last()).state, 'Needs input');
    await f.emit(`${prefix}.rejected`, { sessionID: 'root', requestID: 'q' });
    assert.equal((await f.last()).state, 'Running');
  }
});

test('retry stays busy, errors are not reported as successful completion, aborts are quiet', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'retry');
  assert.equal((await f.last()).state, 'Running');
  await f.emit('session.error', { sessionID: 'root', error: { name: 'APIError', data: { message: 'Request failed' } } });
  await f.status('root', 'idle');
  assert.equal((await f.last()).title, 'OpenCode error');
  assert.equal((await f.last()).message, 'Request failed');
  await f.status('root', 'busy');
  await f.emit('session.error', { sessionID: 'root', error: { name: 'MessageAbortedError' } });
  await f.status('root', 'idle');
  assert.equal((await f.notices()).length, 1);
});

test('concurrent event callbacks preserve order', async (t) => {
  const f = await fixture(t);
  await Promise.all([f.status('root', 'busy'),
    f.emit('permission.asked', { sessionID: 'root', id: 'a', permission: 'bash' }),
    f.status('root', 'busy')]);
  assert.equal((await f.last()).state, 'Needs input');
  assert.deepEqual((await f.events()).map((e) => e.payload.state), ['Idle', 'Running', 'Needs input']);
});

test('unknown ancestry cannot cause false subagent completion notices', async (t) => {
  const f = await fixture(t, { lookupFailure: true });
  await f.status('unknown', 'busy');
  await f.status('unknown', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 0);
});

test('plugin captures pane context, filters streaming traffic, and disposes', async (t) => {
  const a = await fixture(t, { surface: '3' });
  const b = await fixture(t, { surface: '4' });
  for (let i = 0; i < 100; i++) await a.emit('message.part.delta', { sessionID: 'root' });
  assert.equal((await a.events()).length, 1);
  await a.status('root', 'busy');
  await b.status('root', 'busy');
  await a.hooks.dispose();
  await a.status('root', 'busy');
  assert.equal((await a.events()).at(-1).args.at(-1), 'session-end');
  assert.ok((await a.events()).every((e) => e.surface === '3'));
  assert.ok((await b.events()).every((e) => e.surface === '4'));
  assert.equal((await b.last()).state, 'Running');
});

test('broken and stalled bridge commands never reject OpenCode hooks', async (t) => {
  const f = await fixture(t, { fail: true });
  await f.status('root', 'busy');
  await f.status('root', 'idle');
  await f.hooks.dispose();
  const start = Date.now();
  const stalled = await fixture(t, { hang: true });
  await stalled.status('root', 'busy');
  await stalled.hooks.dispose();
  assert.ok(Date.now() - start < 4000);
});

test('plugin is inert outside a wrapper launch and when disabled', async () => {
  const previous = { ...process.env };
  try {
    delete process.env.SEANCE_OPENCODE_BIN;
    assert.deepEqual(await SeancePlugin({}), {});
    process.env.SEANCE_OPENCODE_BIN = '/missing';
    process.env.SEANCE_OPENCODE_HOOKS_DISABLED = '1';
    assert.deepEqual(await SeancePlugin({}), {});
  } finally { process.env = previous; }
});
