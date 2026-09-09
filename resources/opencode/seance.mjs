import { execFile } from "node:child_process";
import { basename } from "node:path";

// OpenCode invokes event hooks concurrently. Keep lifecycle changes and socket
// writes ordered; an integration failure must never reject an agent/tool hook.
export const SeancePlugin = async ({ client, directory }) => {
  const env = { ...process.env };
  const binary = env.SEANCE_OPENCODE_BIN;
  if (!binary || !env.SEANCE_SOCKET_PATH || !env.SEANCE_SURFACE_ID ||
      !env.SEANCE_WORKSPACE_ID || env.SEANCE_OPENCODE_HOOKS_DISABLED === "1") return {};

  const sessions = new Map();
  let queue = Promise.resolve();
  let lastState;
  let disposed = false;

  function enqueue(action) {
    queue = queue.then(action).catch(() => {});
    return queue;
  }

  function hook(command, payload = {}) {
    return new Promise((resolve) => {
      const child = execFile(binary, ["ctl", "opencode-hook", command], {
        env, timeout: 750, killSignal: "SIGKILL", maxBuffer: 4096,
      }, (error) => resolve(!error));
      child.stdin.on("error", () => {});
      // No shell interpolation: model text, paths and quotes are just JSON.
      child.stdin.end(JSON.stringify(payload));
    });
  }

  function session(id) {
    if (!sessions.has(id)) sessions.set(id, {
      busy: false, pending: new Set(), parent: undefined, text: "", error: null,
    });
    return sessions.get(id);
  }

  async function identify(id, state) {
    if (state.parent !== undefined) return;
    try {
      const result = await client.session.get({ path: { id }, signal: AbortSignal.timeout(750) });
      if (result.data) state.parent = result.data.parentID ?? null;
    } catch {}
    // If the lookup fails, still track activity but don't claim this is a
    // completed top-level task. Resumed sessions need no session.created event.
  }

  async function publish(notice) {
    const all = [...sessions.values()];
    const state = all.some((s) => s.pending.size) ? "Needs input" :
      all.some((s) => s.busy) ? "Running" : "Idle";
    const notices = notice ? [{ notice }] : [];
    for (const [id, s] of sessions) {
      if (s.completion && !hasActiveDescendant(id)) notices.push({ notice: s.completion, session: s });
    }
    if (!notices.length && state === lastState) return;
    if (!notices.length) notices.push({});
    for (const item of notices) {
      const payload = { state };
      if (item.notice) {
        payload.title = String(item.notice.title).slice(0, 100);
        payload.message = String(item.notice.message ?? "").slice(0, 200);
      }
      if (await hook("state", payload)) {
        lastState = state;
        if (item.session) item.session.completion = undefined;
      }
    }
  }

  function hasActiveDescendant(root) {
    for (const [id, s] of sessions) {
      if (!s.busy && !s.pending.size) continue;
      let ancestor = id;
      const seen = new Set();
      while (ancestor !== null) {
        if (ancestor === root || seen.has(ancestor)) return true;
        seen.add(ancestor);
        ancestor = sessions.get(ancestor)?.parent;
        // Unknown ancestry must not announce completion ahead of a child.
        if (ancestor === undefined) return true;
      }
    }
    return false;
  }

  async function idle(id, state) {
    const wasBusy = state.busy;
    state.busy = false;
    state.pending.clear();
    if (wasBusy) {
      await identify(id, state);
      if (state.parent === null) {
        if (state.error?.name !== "MessageAbortedError") {
          state.completion = state.error ? {
            title: "OpenCode error",
            message: state.error.data?.message ?? state.error.message ?? state.error.name ?? "Task failed",
          } : {
            title: `Completed${directory ? ` in ${basename(directory)}` : ""}`,
            message: state.text,
          };
        }
      }
    }
    await publish();
  }

  async function event({ type, properties: p = {} }) {
    if (disposed) return;
    const id = p.sessionID ?? p.info?.id;
    if (!id) return;
    const state = session(id);
    switch (type) {
      case "session.created":
      case "session.updated":
        if (p.info) state.parent = p.info.parentID ?? null;
        return;
      case "session.deleted":
        sessions.delete(id);
        return publish();
      case "session.status":
        if (p.status?.type === "idle") return idle(id, state);
        if (p.status?.type !== "busy" && p.status?.type !== "retry") return;
        if (!state.busy) {
          state.error = null;
          state.text = "";
          state.completion = undefined;
        }
        state.busy = true;
        return publish();
      case "session.idle":
        // OpenCode emits both status:idle and session.idle. idle() only
        // notifies on a busy -> idle transition, so they cannot notify twice.
        return idle(id, state);
      case "session.error":
        state.error = p.error ?? { message: "Task failed" };
        return;
      case "permission.asked":
      case "question.asked":
      case "question.v2.asked": {
        if (!p.id || state.pending.has(p.id)) return;
        state.pending.add(p.id);
        const message = type === "permission.asked" ?
          `Permission required: ${p.permission ?? "tool"}${p.patterns?.length ? ` (${p.patterns.join(", ")})` : ""}` :
          p.questions?.map((q) => q.question).filter(Boolean).join("\n") || "OpenCode needs your input";
        return publish({ title: "OpenCode", message: message.slice(0, 200) });
      }
      case "permission.replied":
      case "question.replied":
      case "question.rejected":
      case "question.v2.replied":
      case "question.v2.rejected":
        state.pending.delete(p.requestID);
        return publish();
    }
  }

  await publish(); // Show a newly launched, waiting TUI without a completion alert.
  return {
    event: ({ event: e }) => {
      if (!/^(session\.(created|updated|deleted|status|idle|error)|permission\.(asked|replied)|question\.(v2\.)?(asked|replied|rejected))$/.test(e.type))
        return Promise.resolve();
      return enqueue(() => event(e));
    },
    "experimental.text.complete": async (input, output) => {
      // Save only the final assistant text; streaming token events are ignored.
      // Queue the update without delaying model execution on the status bridge.
      enqueue(() => {
        if (input.sessionID && !disposed)
          session(input.sessionID).text = String(output.text ?? "").replace(/\s+/g, " ").slice(0, 200);
      });
    },
    dispose: () => enqueue(async () => {
      disposed = true;
      await hook("session-end");
    }),
  };
};
