import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import seance from '../resources/omp/seance.mjs';

const WRAPPER_ENV = ['SEANCE_OMP_BIN', 'SEANCE_SOCKET_PATH', 'SEANCE_SURFACE_ID', 'SEANCE_WORKSPACE_ID'];

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "seance-omp-' "));
  // Calls queued behind a stalled Séance may still be writing here.
  t.after(() => rm(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }));
  const capture = join(root, 'events');
  const binary = join(root, 'seance');
  // A shell script starts well within the extension's 750 ms call timeout,
  // even on a loaded machine.
  await writeFile(binary, `#!/bin/sh
payload=$(cat)
printf '%s\\t%s\\t%s\\n' "$*" "$SEANCE_SURFACE_ID" "$payload" >> "$TEST_CAPTURE"
${options.hang ? 'exec sleep 60' : ''}
${options.fail ? 'exit 1' : ''}
`, { mode: 0o755 });
  const previous = { ...process.env };
  Object.assign(process.env, { SEANCE_OMP_BIN: binary, SEANCE_SOCKET_PATH: join(root, 'sock'),
    SEANCE_SURFACE_ID: '3', SEANCE_WORKSPACE_ID: '1', TEST_CAPTURE: capture, ...options.env });
  const handlers = new Map();
  const pi = { on: (name, handler) => handlers.set(name, handler), pi: options.pi };
  seance(pi);
  process.env = previous;
  const cwd = "/work/a 'project'";
  const emit = (name, event = {}, ctx = { hasUI: true, cwd }) => handlers.get(name)(event, ctx);
  const read = async () => {
    try {
      return (await readFile(capture, 'utf8')).trim().split('\n').filter(Boolean).map((line) => {
        const [args, surface, payload] = line.split('\t');
        return { args: args.split(' '), payload: JSON.parse(payload), surface };
      });
    } catch { return []; }
  };
  const events = async (count) => {
    const deadline = Date.now() + 5000;
    let seen = await read();
    while (seen.length < count && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      seen = await read();
    }
    assert.equal(seen.length, count, JSON.stringify(seen));
    return seen.map((e) => [e.args.at(-1), e.payload]);
  };
  return { handlers, emit, events, read, cwd };
}

test('inert outside a wrapper launch', async (t) => {
  const f = await fixture(t);
  assert.ok(f.handlers.size > 0);
  for (const key of WRAPPER_ENV) {
    const g = await fixture(t, { env: { [key]: '' } });
    assert.equal(g.handlers.size, 0, key);
  }
});

test('sessions without a UI (subagents, print mode) are not tracked', async (t) => {
  const f = await fixture(t);
  const headless = { hasUI: false, cwd: f.cwd };
  await f.emit('session_start', {}, headless);
  await f.emit('agent_start', {}, headless);
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'a', input: { path: '/x' } }, headless);
  await f.emit('tool_result', { toolCallId: 'a' }, headless);
  await f.emit('session_stop', { messages: [] }, headless);
  await f.emit('session_shutdown', {}, headless);
  await f.emit('agent_start');
  assert.deepEqual(await f.events(1), [['prompt-submit', {}]]);
});

test('advisor tool calls in the main UI are not tracked', async (t) => {
  const f = await fixture(t);
  const advisor = { hasUI: true, cwd: f.cwd, agent: { kind: 'sub', id: 'advisor', name: 'advisor', depth: 0 } };
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'a', input: { path: '/x' } }, advisor);
  await f.emit('tool_result', { toolCallId: 'a' }, advisor);
  const main = { hasUI: true, cwd: f.cwd, agent: { kind: 'main', id: 'Main', name: 'main', depth: 0 } };
  await f.emit('agent_start', {}, main);
  assert.deepEqual(await f.events(1), [['prompt-submit', {}]]);
});

test('approvals for an advisor tool are ignored even though they arrive with the main context', async (t) => {
  const f = await fixture(t);
  const advisor = { hasUI: true, cwd: f.cwd, agent: { kind: 'sub', id: 'advisor', name: 'advisor', depth: 0 } };
  const main = { hasUI: true, cwd: f.cwd, agent: { kind: 'main', id: 'Main', name: 'main', depth: 0 } };
  // omp passes the advisor identity to tool_call/tool_result only; approval
  // events go through the main runner without it.
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'adv', input: { command: 'ls' } }, advisor);
  await f.emit('tool_approval_requested', { toolName: 'bash', toolCallId: 'adv' }, main);
  await f.emit('tool_approval_resolved', { toolName: 'bash', toolCallId: 'adv', approved: true }, main);
  await f.emit('tool_result', { toolCallId: 'adv' }, advisor);
  await f.emit('agent_start', {}, main);
  assert.deepEqual(await f.events(1), [['prompt-submit', {}]]);
});

test('plain turn reports labels and the last assistant message', async (t) => {
  const f = await fixture(t);
  await f.emit('session_start');
  await f.emit('agent_start');
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'a', input: { path: '/a/b.txt', limit: 5 } });
  await f.emit('tool_result', { toolCallId: 'a' });
  await f.emit('tool_call', { toolName: 'write', toolCallId: 'b', input: { path: 'out.txt', content: 'secret file body' } });
  await f.emit('tool_result', { toolCallId: 'b' });
  await f.emit('tool_call', { toolName: 'edit', toolCallId: 'c', input: { input: 'intro\n[src/main.zig#1A2B]\nPUT 3:\n+x' } });
  await f.emit('tool_result', { toolCallId: 'c' });
  const reply = "Done: 'quoted' $(touch /tmp/never) `literal`";
  // omp passes session_stop and its agent_end the same messages.
  const messages = [
    { role: 'assistant', content: [{ type: 'text', text: 'earlier' }] },
    { role: 'user', content: [{ type: 'text', text: 'question' }] },
    { role: 'assistant', content: [{ type: 'thinking', thinking: 'hidden' }, { type: 'text', text: reply }] },
  ];
  await f.emit('session_stop', { messages });
  await f.emit('agent_end', { messages });
  assert.deepEqual(await f.events(8), [
    ['prompt-submit', {}],
    ['pre-tool-use', { tool_name: 'read', tool_input: { path: '/a/b.txt' } }],
    ['post-tool-use', {}],
    ['pre-tool-use', { tool_name: 'write', tool_input: { path: 'out.txt' } }],
    ['post-tool-use', {}],
    ['pre-tool-use', { tool_name: 'edit', tool_input: { path: 'src/main.zig' } }],
    ['post-tool-use', {}],
    ['stop', { cwd: f.cwd, last_assistant_message: reply }],
  ]);
});

test('a finished tool keeps a still running sibling on display', async (t) => {
  const f = await fixture(t);
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'long', input: { command: 'sleep 60' } });
  await f.emit('tool_call', { toolName: 'grep', toolCallId: 'quick', input: { pattern: 'x' } });
  await f.emit('tool_result', { toolCallId: 'quick' });
  await f.emit('tool_result', { toolCallId: 'long' });
  const bash = ['pre-tool-use', { tool_name: 'bash', tool_input: { command: 'sleep 60' } }];
  assert.deepEqual(await f.events(4), [
    bash,
    ['pre-tool-use', { tool_name: 'grep', tool_input: { pattern: 'x' } }],
    bash,
    ['post-tool-use', {}],
  ]);
});

test('questions and approvals notify, and stay on display while pending', async (t) => {
  const f = await fixture(t);
  await f.emit('tool_call', { toolName: 'ask', toolCallId: 'q', input: { questions: [{ id: 'db', question: 'Which database?', options: [] }] } });
  await f.emit('tool_result', { toolCallId: 'q' });
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'b', input: { command: 'rm -r build' } });
  await f.emit('tool_approval_requested', { toolName: 'bash', toolCallId: 'b' });
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'r', input: { path: 'a.txt' } });
  await f.emit('tool_result', { toolCallId: 'r' });
  await f.emit('tool_approval_resolved', { toolName: 'bash', toolCallId: 'b', approved: true });
  await f.emit('tool_result', { toolCallId: 'b' });
  const bash = ['pre-tool-use', { tool_name: 'bash', tool_input: { command: 'rm -r build' } }];
  assert.deepEqual(await f.events(8), [
    ['notification', { notification_type: 'input', message: 'Which database?' }],
    ['post-tool-use', {}],
    bash,
    ['notification', { notification_type: 'permission', message: 'Approve bash' }],
    ['pre-tool-use', { tool_name: 'read', tool_input: { path: 'a.txt' } }],
    ['pre-tool-use', { tool_name: 'Needs input' }],
    bash,
    ['post-tool-use', {}],
  ]);
});

test('a denied approval forgets the tool, which never reports a result', async (t) => {
  const f = await fixture(t);
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'b', input: { command: 'rm -r build' } });
  await f.emit('tool_approval_requested', { toolName: 'bash', toolCallId: 'b' });
  await f.emit('tool_approval_resolved', { toolName: 'bash', toolCallId: 'b', approved: false });
  assert.deepEqual(await f.events(3), [
    ['pre-tool-use', { tool_name: 'bash', tool_input: { command: 'rm -r build' } }],
    ['notification', { notification_type: 'permission', message: 'Approve bash' }],
    ['post-tool-use', {}],
  ]);
});

test('a tool the loop finishes without an extension tool_result is forgotten once', async (t) => {
  const f = await fixture(t);
  // Blocked by another extension, invalid arguments, or aborted: omp emits
  // only tool_execution_end. A normal tool emits tool_result, then tool_execution_end.
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'long', input: { command: 'sleep 60' } });
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'blocked', input: { path: 'a.txt' } });
  await f.emit('tool_execution_end', { toolCallId: 'blocked', toolName: 'read', isError: true });
  await f.emit('tool_result', { toolCallId: 'long' });
  await f.emit('tool_execution_end', { toolCallId: 'long', toolName: 'bash', isError: false });
  const bash = ['pre-tool-use', { tool_name: 'bash', tool_input: { command: 'sleep 60' } }];
  assert.deepEqual(await f.events(4), [
    bash,
    ['pre-tool-use', { tool_name: 'read', tool_input: { path: 'a.txt' } }],
    bash,
    ['post-tool-use', {}],
  ]);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal((await f.read()).length, 4, 'tool_execution_end after tool_result must not report again');
});

test('a new turn and a stop forget tools that never reported a result', async (t) => {
  const f = await fixture(t);
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'lost', input: { command: 'make' } });
  await f.emit('session_stop', { last_assistant_message: { content: [{ type: 'text', text: 'aborted' }] } });
  await f.emit('agent_end', { messages: [] });
  await f.emit('agent_start');
  await f.emit('tool_call', { toolName: 'grep', toolCallId: 'g', input: { pattern: 'x' } });
  await f.emit('tool_result', { toolCallId: 'g' });
  const seen = await f.events(5);
  assert.deepEqual(seen[1], ['stop', { cwd: f.cwd, last_assistant_message: 'aborted' }]);
  assert.deepEqual(seen.at(-1), ['post-tool-use', {}]);
});

// omp passes a run's session_stop and agent_end the same message objects.
const run = (text, n) => ({ messages: Array.from({ length: n }, (_, i) =>
  ({ role: i % 2 ? 'assistant' : 'user', content: [{ type: 'text', text: i === n - 1 ? text : 'x' }] })) });

test('a stop that another extension continues is not a completion', async (t) => {
  const f = await fixture(t);
  const first = run('first', 2);
  const continued = { messages: [...first.messages, ...run('continued', 2).messages] };
  await f.emit('agent_start');
  await f.emit('session_stop', first);
  await f.emit('agent_end', { ...first, willContinue: true });
  await f.emit('agent_start');
  await f.emit('session_stop', continued);
  await f.emit('agent_end', continued);
  assert.deepEqual(await f.events(3), [
    ['prompt-submit', {}],
    ['prompt-submit', {}],
    ['stop', { cwd: f.cwd, last_assistant_message: 'continued' }],
  ]);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal((await f.read()).length, 3);
});

test('a continuation that never starts goes idle after a grace period', async (t) => {
  const f = await fixture(t);
  await f.emit('agent_start');
  await f.emit('agent_end', { ...run('x', 2), willContinue: true });
  // A scheduled continuation that does start cancels it.
  const g = await fixture(t);
  await g.emit('agent_end', { ...run('x', 2), willContinue: true });
  await new Promise((resolve) => setTimeout(resolve, 500));
  await g.emit('agent_start');
  await new Promise((resolve) => setTimeout(resolve, 1500));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)), ['prompt-submit'], 'not before the grace ends');
  assert.deepEqual(await f.events(2), [['prompt-submit', {}], ['state', { state: 'Idle' }]]);
  assert.deepEqual((await g.read()).map((e) => e.args.at(-1)), ['prompt-submit']);
});

test('a background wait stays Running while jobs run, then goes idle when they drain', async (t) => {
  const f = await fixture(t);
  let running = [{ id: 'job' }];
  const ctx = { hasUI: true, cwd: f.cwd, isIdle: () => true, getAsyncJobSnapshot: () => ({ running, delivery: { queued: 0 } }) };
  await f.emit('agent_start');
  await f.emit('agent_end', { ...run('x', 2), willContinue: true, awaitingAsyncWork: true }, ctx);
  await new Promise((resolve) => setTimeout(resolve, 2400));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)), ['prompt-submit'], 'job still running');
  running = [];
  assert.deepEqual((await f.events(2)).at(-1), ['state', { state: 'Idle' }]);
});

test('an open plan review needs input; resolving it starts the plan or settles idle', async (t) => {
  const notification = ['notification', { notification_type: 'input', message: 'Review plan: Ship it' }];
  // Plan mode aborts its turn, then opens the review.
  const f = await fixture(t);
  await f.emit('agent_start');
  await f.emit('agent_end', { messages: [] });
  await f.emit('plan_review_requested', { reviewId: 'r', title: 'Ship it' });
  await new Promise((resolve) => setTimeout(resolve, 2400));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)).at(-1), 'notification', 'still waiting after the grace');
  // Approved: the plan's turn starts within the grace, so no Idle in between.
  await f.emit('plan_review_resolved', { reviewId: 'r', choice: 'approve' });
  await f.emit('agent_start');
  await new Promise((resolve) => setTimeout(resolve, 2400));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)).slice(-2), ['notification', 'prompt-submit']);

  // Dismissed: nothing starts, so it settles to Idle once.
  const g = await fixture(t);
  await g.emit('plan_review_requested', { reviewId: 'r', title: 'Ship it' });
  await g.emit('plan_review_resolved', { reviewId: 'r', choice: undefined });
  await g.emit('plan_review_resolved', { reviewId: 'r', choice: undefined });
  assert.deepEqual(await g.events(2), [notification, ['state', { state: 'Idle' }]]);
});

test('an unanswered plan review stays Needs input through background turns and idle compaction', async (t) => {
  const needsInput = ['pre-tool-use', { tool_name: 'Needs input' }];
  const reviewing = (f, state) => ({ hasUI: true, cwd: f.cwd, isIdle: () => true,
    getPendingPlanReview: () => (state.open ? { reviewId: 'r' } : undefined) });
  const f = await fixture(t);
  const state = { open: true };
  const ctx = reviewing(f, state);
  await f.emit('plan_review_requested', { reviewId: 'r', title: 'Ship it' }, ctx);
  // A background job's delivery wakes the session behind the open review.
  const bg = run('background result handled', 2);
  await f.emit('agent_start', {}, ctx);
  await f.emit('session_stop', bg, ctx);
  await f.emit('agent_end', bg, ctx);
  // Opt-in idle compaction fires while the user is still reading.
  await f.emit('auto_compaction_start', {}, ctx);
  await f.emit('auto_compaction_end', {}, ctx);
  await new Promise((resolve) => setTimeout(resolve, 2400));
  const seen = (await f.read()).map((e) => [e.args.at(-1), e.payload]);
  assert.equal(seen.filter(([hook]) => hook === 'notification').length, 1, JSON.stringify(seen));
  assert.deepEqual(seen.at(-1), needsInput, JSON.stringify(seen));
  // Answered and closed with nothing to run: one Idle, no Needs input after it.
  state.open = false;
  await f.emit('plan_review_resolved', { reviewId: 'r', choice: undefined }, ctx);
  await new Promise((resolve) => setTimeout(resolve, 2400));
  assert.deepEqual((await f.read()).map((e) => [e.args.at(-1), e.payload]).slice(seen.length), [['state', { state: 'Idle' }]]);
});

test('"approve and compact" shows Running while it compacts behind the review', async (t) => {
  const f = await fixture(t);
  const state = { open: true };
  const ctx = { hasUI: true, cwd: f.cwd, isIdle: () => true,
    getPendingPlanReview: () => (state.open ? { reviewId: 'r' } : undefined) };
  await f.emit('plan_review_requested', { reviewId: 'r', title: 'Ship it' }, ctx);
  // Compaction before the choice is made does not override the review.
  await f.emit('session_before_compact', {}, ctx);
  state.open = false;
  await f.emit('session_before_compact', {}, ctx);
  await f.emit('plan_review_resolved', { reviewId: 'r', choice: 'approve_compact' }, ctx);
  await f.emit('agent_start', {}, ctx);
  await new Promise((resolve) => setTimeout(resolve, 2400));
  assert.deepEqual((await f.read()).map((e) => [e.args.at(-1), e.payload]), [
    ['notification', { notification_type: 'input', message: 'Review plan: Ship it' }],
    ['state', { state: 'Running' }],
    ['prompt-submit', {}],
  ]);
});

test('automatic compaction while idle shows Running until it settles', async (t) => {
  const f = await fixture(t);
  await f.emit('auto_compaction_start', {}, { hasUI: true, cwd: f.cwd, isIdle: () => true });
  await new Promise((resolve) => setTimeout(resolve, 300));
  await f.emit('auto_compaction_end', {});
  assert.deepEqual(await f.events(2), [['state', { state: 'Running' }], ['state', { state: 'Idle' }]]);
  // Compaction inside a run is left to that run's own events.
  const g = await fixture(t);
  await g.emit('auto_compaction_start', {}, { hasUI: true, cwd: g.cwd, isIdle: () => false });
  await g.emit('auto_compaction_end', {});
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual(await g.read(), []);
});

test('a newer continuation end cancels an older pending idle check', async (t) => {
  const f = await fixture(t);
  let streaming = true;
  const ctx = { hasUI: true, cwd: f.cwd, isIdle: () => !streaming };
  await f.emit('agent_start');
  // A stale end without a completion starts polling while another run streams...
  await f.emit('agent_end', { messages: [] }, ctx);
  // ...then that run pauses for a continuation, and omp is briefly idle.
  await f.emit('agent_end', { ...run('x', 2), willContinue: true }, ctx);
  streaming = false;
  await new Promise((resolve) => setTimeout(resolve, 1000));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)), ['prompt-submit'], 'the old poll must not idle inside the grace');
  assert.deepEqual(await f.events(2), [['prompt-submit', {}], ['state', { state: 'Idle' }]]);
});

test('an aborted or failed run goes idle without a completion', async (t) => {
  const f = await fixture(t);
  // Esc: omp ends the run with agent_end and skips session_stop.
  await f.emit('agent_start');
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'b', input: { command: 'make' } });
  await f.emit('agent_end', { messages: [] });
  await f.emit('tool_call', { toolName: 'read', toolCallId: 'r', input: { path: 'a' } });
  await f.emit('tool_result', { toolCallId: 'r' });
  assert.deepEqual(await f.events(5), [
    ['prompt-submit', {}],
    ['pre-tool-use', { tool_name: 'bash', tool_input: { command: 'make' } }],
    ['state', { state: 'Idle' }],
    ['pre-tool-use', { tool_name: 'read', tool_input: { path: 'a' } }],
    ['post-tool-use', {}],
  ]);
});

test('/new and /resume idle the pane, /fork keeps the running turn', async (t) => {
  const f = await fixture(t);
  await f.emit('agent_start');
  await f.emit('session_switch', { reason: 'fork' });
  await f.emit('session_switch', { reason: 'new' });
  await f.emit('agent_start');
  await f.emit('session_stop', { messages: [] });
  await f.emit('session_switch', { reason: 'resume' });
  // Even a stray agent_end from the replaced run must not complete it.
  await f.emit('agent_end', { messages: [] });
  const seen = await f.events(5);
  assert.deepEqual(seen.slice(0, 4), [
    ['prompt-submit', {}],
    ['state', { state: 'Idle' }],
    ['prompt-submit', {}],
    ['state', { state: 'Idle' }],
  ]);
  assert.ok(!seen.some(([hook]) => hook === 'stop'), JSON.stringify(seen));
});

test('a late agent_end from the previous run leaves the new run alone', async (t) => {
  const f = await fixture(t);
  const streaming = { hasUI: true, cwd: f.cwd, isIdle: () => false };
  // Run A completes, but its agent_end is delayed past run B's start.
  await f.emit('agent_start');
  await f.emit('session_stop', { messages: [] });
  await f.emit('agent_start');
  await f.emit('tool_call', { toolName: 'bash', toolCallId: 'b', input: { command: 'sleep 30' } });
  await f.emit('agent_end', { messages: [] }, streaming);
  // An aborted run's late end while B streams is dropped as well.
  await f.emit('agent_end', { messages: [] }, streaming);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)), ['prompt-submit', 'prompt-submit', 'pre-tool-use']);
  // B's own abort, with omp idle, still goes idle.
  await f.emit('agent_end', { messages: [] }, { hasUI: true, cwd: f.cwd, isIdle: () => true });
  assert.deepEqual((await f.events(4)).at(-1), ['state', { state: 'Idle' }]);
});

test('an error end goes idle once omp settles, unless a newer run starts first', async (t) => {
  // An error mid tool batch skips session_stop, and omp is still streaming at its agent_end.
  const settling = () => {
    let streaming = true;
    setTimeout(() => { streaming = false; }, 500);
    return { isIdle: () => !streaming };
  };
  const f = await fixture(t);
  await f.emit('agent_start');
  await f.emit('agent_end', { messages: [] }, { hasUI: true, cwd: f.cwd, ...settling() });
  assert.deepEqual(await f.events(2), [['prompt-submit', {}], ['state', { state: 'Idle' }]]);

  const g = await fixture(t);
  await g.emit('agent_end', { messages: [] }, { hasUI: true, cwd: g.cwd, ...settling() });
  await g.emit('agent_start');
  await new Promise((resolve) => setTimeout(resolve, 900));
  assert.deepEqual((await g.read()).map((e) => e.args.at(-1)), ['prompt-submit']);
});

test('a delayed end from an earlier run never takes the next run\'s completion', async (t) => {
  for (const willContinue of [true, false]) {
    const f = await fixture(t);
    // Both runs have two messages: first turns on each side of a /new.
    const a = run('A', 2);
    const b = run('B', 2);
    await f.emit('agent_start');
    await f.emit('session_stop', a);
    await f.emit('session_switch', { reason: 'new' });
    // A's agent_end is held back by a slow extension until B has stopped too.
    await f.emit('agent_start');
    await f.emit('session_stop', b);
    await f.emit('agent_end', { ...a, willContinue });
    await f.emit('agent_end', b);
    // A later handler appending to the shared array does not unmatch the run.
    const c = run('C', 2);
    await f.emit('agent_start');
    await f.emit('session_stop', c);
    await f.emit('agent_end', { messages: [...c.messages, { role: 'custom' }] });
    assert.deepEqual((await f.events(6)).filter(([hook]) => hook !== 'prompt-submit'), [
      ['state', { state: 'Idle' }],
      ['stop', { cwd: f.cwd, last_assistant_message: 'B' }],
      ['stop', { cwd: f.cwd, last_assistant_message: 'C' }],
    ], `A willContinue=${willContinue}`);
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal((await f.read()).length, 6, `no Idle after the completions (A willContinue=${willContinue})`);
  }
});

test('a /new or /resume that fails after aborting the run still goes idle; a vetoed one does not', async (t) => {
  const idleCtx = (f) => ({ hasUI: true, cwd: f.cwd, isIdle: () => true });
  const failed = await fixture(t);
  await failed.emit('agent_start');
  await failed.emit('session_before_switch', { reason: 'resume' }, idleCtx(failed));
  assert.deepEqual(await failed.events(2), [['prompt-submit', {}], ['state', { state: 'Idle' }]]);

  const vetoed = await fixture(t);
  await vetoed.emit('agent_start');
  await vetoed.emit('session_before_switch', { reason: 'new' }, { hasUI: true, cwd: vetoed.cwd, isIdle: () => false });
  // A successful switch idles at once; its delayed check must not repeat it.
  const ok = await fixture(t);
  await ok.emit('session_before_switch', { reason: 'new' }, idleCtx(ok));
  await ok.emit('session_switch', { reason: 'new' });
  await new Promise((resolve) => setTimeout(resolve, 1400));
  assert.deepEqual((await vetoed.read()).map((e) => e.args.at(-1)), ['prompt-submit']);
  assert.deepEqual((await ok.read()).map((e) => e.args.at(-1)), ['state']);
});

test('nothing reaches Séance after shutdown starts', async (t) => {
  const f = await fixture(t);
  await f.emit('session_stop', { messages: [] });
  await f.emit('session_shutdown');
  await f.emit('agent_end', { messages: [] });
  await f.emit('agent_end', { messages: [], willContinue: true });
  await f.emit('agent_start');
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual((await f.read()).map((e) => e.args.at(-1)), ['session-end']);
});

test('shutdown clears the status and drains within its budget', async (t) => {
  const f = await fixture(t);
  await f.emit('agent_start');
  assert.equal(await f.emit('session_shutdown'), undefined);
  assert.deepEqual(await f.read(), [
    { args: ['ctl', 'omp-hook', 'prompt-submit'], payload: {}, surface: '3' },
    { args: ['ctl', 'omp-hook', 'session-end'], payload: {}, surface: '3' },
  ]);

  const stalled = await fixture(t, { hang: true });
  for (let i = 0; i < 4; i++) await stalled.emit('agent_start');
  const start = Date.now();
  assert.equal(await stalled.emit('session_shutdown'), undefined);
  assert.ok(Date.now() - start < 1900, `shutdown took ${Date.now() - start} ms`);
});

test('broken and stalled Séance calls never reject or delay omp handlers', async (t) => {
  for (const options of [{ fail: true }, { hang: true }]) {
    const f = await fixture(t, options);
    const start = Date.now();
    for (const [name, event] of [['agent_start', {}],
      ['tool_call', { toolName: 'bash', toolCallId: 'a', input: { command: 'ls' } }],
      ['tool_approval_requested', { toolName: 'bash', toolCallId: 'a' }],
      ['tool_approval_resolved', { toolName: 'bash', toolCallId: 'a' }],
      ['tool_result', { toolCallId: 'a' }],
      ['session_stop', {}]]) {
      assert.equal(await f.emit(name, event), undefined, name);
    }
    assert.ok(Date.now() - start < 500, JSON.stringify(options));
  }
  const missing = await fixture(t, { env: { SEANCE_OMP_BIN: '/nonexistent/seance' } });
  assert.equal(await missing.emit('tool_call', { toolName: 'read', toolCallId: 'r', input: null }), undefined);
  assert.equal(await missing.emit('session_shutdown'), undefined);
});

test('malformed events and settings never throw out of a handler', async (t) => {
  const f = await fixture(t, { pi: { settings: {} } });
  assert.equal(await f.emit('session_start'), undefined);
  assert.equal(await f.emit('tool_call', undefined), undefined);
  assert.equal(await f.emit('tool_call', { toolName: 'ask', toolCallId: 'q', input: { questions: 'x' } }), undefined);
  assert.equal(await f.emit('session_stop', { messages: 'nope' }), undefined);
  assert.equal(await f.emit('agent_end', undefined), undefined);
  assert.equal(await f.emit('agent_start', {}, null), undefined);
  await f.emit('tool_result', { toolCallId: 'sentinel' });
  const seen = await f.events(4);
  assert.deepEqual(seen[1], ['notification', { notification_type: 'input', message: 'Waiting for input' }]);
  assert.deepEqual(seen[2], ['stop', { cwd: f.cwd, last_assistant_message: '' }]);
  assert.deepEqual(seen[3], ['post-tool-use', {}]);
});
