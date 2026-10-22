import { execFile } from "node:child_process";

// omp caps session_shutdown handlers at 2 s.
const SHUTDOWN_BUDGET_MS = 1500;
// How long after /new or /resume starts to look whether the old run stopped.
const SWITCH_SETTLE_MS = 1000;
// After an unfinished run, poll for omp to settle; while only omp's own
// streaming keeps it busy, give up after 30 s.
const SETTLE_POLL_MS = 200;
const SETTLE_TRIES = 150;
// How long a scheduled continuation gets to start before the pane goes idle.
const CONTINUE_GRACE_MS = 2000;
const NEEDS_INPUT = { hook: "pre-tool-use", payload: { tool_name: "Needs input" } };
// The fields Séance labels tool calls with; file contents and edits stay in omp.
const LABEL_FIELDS = ["path", "file_path", "command", "pattern", "query", "description"];

// One ordered queue: handlers enqueue and return without awaiting, so a tool
// call never waits on Séance while pre-/post-tool-use still arrive in order.
// An integration failure must never reject a handler: omp blocks a tool whose
// tool_call handler throws.
export default function seance(pi) {
  const env = { ...process.env };
  const binary = env.SEANCE_OMP_BIN;
  if (!binary || !env.SEANCE_SOCKET_PATH || !env.SEANCE_SURFACE_ID || !env.SEANCE_WORKSPACE_ID) return;

  let queue = Promise.resolve();

  function hook(command, payload) {
    return new Promise((resolve) => {
      const child = execFile(binary, ["ctl", "omp-hook", command], {
        env, timeout: 750, killSignal: "SIGKILL", maxBuffer: 4096,
      }, (error) => resolve(!error));
      child.stdin.on("error", () => {});
      // No shell interpolation: model text, paths and quotes are just JSON.
      child.stdin.end(JSON.stringify(payload));
    });
  }

  // While a plan review waits for the user, it outranks every other status:
  // a background job's turn, its completion, or an idle compaction can run
  // behind the open review, and the pane must still say Needs input.
  function enqueue(command, payload = {}) {
    queue = queue.then(() => hook(command, payload)).catch(() => {});
    if (payload !== NEEDS_INPUT.payload && command !== "notification" && command !== "session-end" && reviewOpen()) {
      queue = queue.then(() => hook(NEEDS_INPUT.hook, NEEDS_INPUT.payload)).catch(() => {});
    }
    return queue;
  }

  // Plan mode ends its turn before opening the review. The review stays open
  // until omp stops reporting it as pending (the user chose) and is finished
  // by plan_review_resolved; it lives outside `inflight`, which each run resets.
  let review;
  function reviewOpen() {
    if (!review) return false;
    const pending = review.ctx.getPendingPlanReview;
    return typeof pending === "function" ? pending.call(review.ctx)?.reviewId === review.id : true;
  }

  // omp runs independent tool calls concurrently and emits every tool_call
  // before any of them finishes. Track what is still running so the first
  // tool_result does not reset the status while a sibling (a long command, a
  // pending question or approval) is still going.
  const inflight = new Map();
  function showInflight() {
    const last = [...inflight.values()].pop();
    if (last) enqueue(last.hook, last.payload);
    else enqueue("post-tool-use");
  }

  // After session_shutdown starts nothing else may reach Séance: a late
  // agent_end would otherwise send a completion after the status was cleared.
  let shuttingDown = false;

  // Subagents run this extension too and fire their own session and tool
  // events; they, print mode and headless RPC have no UI and are not tracked.
  // An advisor shares the main session's UI but reports itself as a subagent,
  // so its tool calls are skipped too.
  function on(event, handler) {
    pi.on(event, async (data, ctx) => {
      try {
        if (ctx?.hasUI && ctx.agent?.kind !== "sub" && !shuttingDown) await handler(data ?? {}, ctx);
      } catch {}
      return undefined;
    });
  }

  // Idle without a completion notification: for runs that ended without
  // finishing (aborted, failed, replaced by /new or /resume).
  function idle() {
    inflight.clear();
    pendingStop = undefined;
    enqueue("state", { state: "Idle" });
  }

  on("session_start", () => quietNativeNotifications(pi));

  // Bumped by every run start and end and by a completed session switch, so a
  // later check can tell whether something newer already set the status.
  let epoch = 0;

  on("agent_start", () => {
    epoch++;
    inflight.clear();
    // A completion still held for the previous run is moot once a new run
    // starts; its agent_end may arrive late (other extensions run first).
    pendingStop = undefined;
    retrying = false;
    enqueue("prompt-submit");
  });

  on("tool_call", (event) => {
    if (event.toolName === "ask") {
      inflight.set(event.toolCallId, NEEDS_INPUT);
      enqueue("notification", { notification_type: "input", message: question(event.input) });
      return;
    }
    const entry = { hook: "pre-tool-use", payload: { tool_name: event.toolName, tool_input: toolInput(event.toolName, event.input) } };
    inflight.set(event.toolCallId, entry);
    enqueue(entry.hook, entry.payload);
  });

  on("tool_result", (event) => {
    inflight.delete(event.toolCallId);
    showInflight();
  });

  // A call blocked by another extension, rejected for invalid arguments or
  // aborted before it ran is finished by the agent loop alone: there is no
  // tool_result, only tool_execution_end. Completed tools emit both, so only
  // update the status when this call was still tracked.
  on("tool_execution_end", (event) => {
    if (inflight.delete(event.toolCallId)) showInflight();
  });

  // Approval events carry no agent identity: an advisor's approvals arrive
  // with the main session's context. Only follow approvals for tool calls this
  // session is tracking, which leaves out the advisor's (skipped above).
  on("tool_approval_requested", (event) => {
    if (!inflight.has(event.toolCallId)) return;
    inflight.set(`approval:${event.toolCallId}`, NEEDS_INPUT);
    enqueue("notification", { notification_type: "permission", message: `Approve ${event.toolName}` });
  });

  // A denied or aborted approval stops the tool before it runs, so no
  // tool_result follows: forget the tool along with its approval.
  on("tool_approval_resolved", (event) => {
    if (!inflight.delete(`approval:${event.toolCallId}`)) return;
    if (event.approved === false) inflight.delete(event.toolCallId);
    showInflight();
  });

  // session_stop supplies the final message: omp does not emit it for
  // subagent sessions. Another extension may still ask to continue, so the
  // completion waits for the agent_end that follows and is dropped when that
  // says willContinue. The handler must resolve to undefined; { continue: true }
  // would start another turn.
  //
  // omp hands agent_end to extensions without waiting for them, so a slow
  // extension ahead of this one can deliver an end after the next run began.
  // A held completion therefore keeps its run's final message object: omp
  // passes session_stop and the matching agent_end the same message objects,
  // so an end whose messages do not include it belongs to another run and
  // leaves the completion alone.
  let pendingStop;
  on("session_stop", (event, ctx) => {
    inflight.clear();
    pendingStop = {
      payload: { cwd: ctx.cwd, last_assistant_message: lastAssistantText(event) },
      last: lastMessage(event),
    };
  });

  on("agent_end", (event, ctx) => {
    const held = pendingStop;
    if (held && held.last !== undefined && Array.isArray(event.messages) && !event.messages.includes(held.last)) return;
    epoch++;
    pendingStop = undefined;
    if (event.willContinue) return idleWhenSettled(ctx, CONTINUE_GRACE_MS);
    if (held) return enqueue("stop", held.payload);
    idleWhenSettled(ctx, 0);
  });

  let retrying = false;
  on("auto_retry_start", () => { retrying = true; });
  on("auto_retry_end", () => { retrying = false; });

  on("plan_review_requested", (event, ctx) => {
    epoch++;
    review = { id: event.reviewId, ctx };
    enqueue("notification", { notification_type: "input", message: `Review plan: ${event.title || "plan"}` });
  });

  // "Approve and compact context" compacts behind the still-open overlay,
  // after the choice is made, so show the work as Running.
  on("session_before_compact", () => {
    if (!review || reviewOpen()) return;
    epoch++;
    enqueue("state", { state: "Running" });
  });

  // Resolved means the overlay closed: an approved plan starts its turn within
  // the continuation grace, a dismissed one settles to Idle.
  on("plan_review_resolved", (event, ctx) => {
    if (review?.id !== event.reviewId) return;
    review = undefined;
    epoch++;
    if (inflight.size) showInflight();
    else idleWhenSettled(ctx, CONTINUE_GRACE_MS);
  });

  // Automatic compaction while omp is otherwise idle runs a model call after
  // the turn already completed. Compaction inside a run is covered by that
  // run's own events.
  let compacting = false;
  on("auto_compaction_start", (event, ctx) => {
    if (ctx.isIdle?.() === false) return;
    compacting = true;
    epoch++;
    enqueue("state", { state: "Running" });
  });

  on("auto_compaction_end", (event, ctx) => {
    if (!compacting) return;
    compacting = false;
    epoch++;
    idleWhenSettled(ctx, CONTINUE_GRACE_MS);
  });

  // A run can stop without finishing: omp skips session_stop for aborts (Esc)
  // and errors mid tool batch, and a scheduled continuation (retry,
  // compaction, todo reminder) or background-work wake can be cancelled
  // without ever starting. omp is still streaming while a run's prompt unwinds
  // (isIdle() is false at an error's agent_end, true at an abort's), so wait
  // until it is idle, nothing is queued or retrying, and no background job is
  // running or awaiting delivery, then go idle without a notification. A
  // continuation gets `grace` ms to start first. Anything newer (a run start
  // or end, a switch) cancels the wait; a wait that sees only omp streaming
  // gives up after SETTLE_TRIES polls.
  function idleWhenSettled(ctx, grace) {
    const seen = epoch;
    const from = Date.now();
    const later = typeof ctx.setTimeout === "function" ? ctx.setTimeout.bind(ctx) : setTimeout;
    let tries = 0;
    const check = () => {
      if (shuttingDown || epoch !== seen) return;
      const jobs = ctx.getAsyncJobSnapshot?.();
      const background = (jobs?.running?.length ?? 0) > 0 || (jobs?.delivery?.queued ?? 0) > 0;
      const busy = background || retrying || ctx.hasPendingMessages?.() === true || ctx.isIdle?.() === false;
      if (Date.now() - from >= grace && !busy) return idle();
      if (background || ++tries < SETTLE_TRIES) later(check, SETTLE_POLL_MS)?.unref?.();
    };
    check();
  }

  // /new and /resume abort the running turn after detaching its listeners, so
  // that run never reports an agent_end. /fork keeps the run going.
  on("session_switch", (event) => {
    if (event.reason === "new" || event.reason === "resume") {
      epoch++;
      idle();
    }
  });

  // A switch that fails after omp aborted the run (a broken session file)
  // emits no session_switch, so look again shortly after it begins. A switch
  // another extension vetoes keeps the run streaming and is left alone.
  on("session_before_switch", (event, ctx) => {
    if (event.reason !== "new" && event.reason !== "resume") return;
    const seen = epoch;
    const later = typeof ctx.setTimeout === "function" ? ctx.setTimeout.bind(ctx) : setTimeout;
    const timer = later(() => {
      if (!shuttingDown && epoch === seen && ctx.isIdle?.() !== false) idle();
    }, SWITCH_SETTLE_MS);
    timer?.unref?.();
  });

  on("session_shutdown", async () => {
    shuttingDown = true;
    inflight.clear();
    pendingStop = undefined;
    let timer;
    await Promise.race([
      enqueue("session-end"),
      new Promise((resolve) => { timer = setTimeout(resolve, SHUTDOWN_BUDGET_MS); }),
    ]);
    clearTimeout(timer);
  });
}

function toolInput(name, raw) {
  const input = raw && typeof raw === "object" ? raw : {};
  const out = {};
  for (const key of LABEL_FIELDS) {
    if (typeof input[key] === "string") out[key] = input[key];
  }
  // Hashline edits carry their target inside the edit text as `[PATH#TAG]`.
  if (name === "edit" && !out.path && typeof input.input === "string") {
    const match = /^\[([^\]#]+)#/m.exec(input.input);
    if (match) out.path = match[1];
  }
  return out;
}

function question(input) {
  const first = Array.isArray(input?.questions) ? input.questions[0] : undefined;
  return typeof first?.question === "string" && first.question ? first.question : "Waiting for input";
}

function messageText(message) {
  if (!message || !Array.isArray(message.content)) return "";
  return message.content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("");
}

function lastMessage(event) {
  return Array.isArray(event.messages) ? event.messages.at(-1) : undefined;
}

function lastAssistantText(event) {
  if (event.last_assistant_message) return messageText(event.last_assistant_message);
  const messages = Array.isArray(event.messages) ? event.messages : [];
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]?.role === "assistant") return messageText(messages[i]);
  }
  return "";
}

// Séance sends the completion and question notifications for this session;
// silence omp's own unless the user chose a value explicitly.
async function quietNativeNotifications(pi) {
  const settings = pi.pi?.settings;
  if (!settings) return;
  let lookup;
  try {
    ({ lookup } = await import("@oh-my-pi/pi-coding-agent/config/registry"));
  } catch {
    return;
  }
  for (const id of ["completion.notify", "ask.notify"]) {
    const setting = lookup(id);
    if (setting && !setting.isConfigured(settings)) setting.override(settings, "off");
  }
}
