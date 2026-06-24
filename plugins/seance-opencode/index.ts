// Séance plugin for OpenCode
// Copy to ~/.config/opencode/plugins/seance-opencode.ts
// @seance-version 1

export const SeancePlugin = async ({ $ }) => {
  const socket = process.env.SEANCE_SOCKET_PATH;
  if (!socket) return {};
  if (process.env.SEANCE_OPENCODE_HOOKS_DISABLED === "1") return {};

  // Find seance binary: SEANCE_BIN_DIR is {prefix}/share/bin, binary is at {prefix}/bin/seance
  const binDir = process.env.SEANCE_BIN_DIR;
  const seanceBin = binDir
    ? binDir.replace(/\/share\/bin$/, "/bin/seance")
    : "seance"; // fallback to PATH

  const surfaceId = process.env.SEANCE_SURFACE_ID;
  const workspaceId = process.env.SEANCE_WORKSPACE_ID;
  let currentSessionId: string | undefined;
  const shEscape = (s: string) => s.replace(/'/g, "'\\''");

  async function hook(event: string, extra: Record<string, unknown> = {}) {
    const payload = JSON.stringify({
      session_id: currentSessionId,
      workspace_id: workspaceId,
      surface_id: surfaceId,
      ...extra,
    });
    await $`echo '${shEscape(payload)}' | ${seanceBin} ctl opencode-hook ${event} >/dev/null`;
  }

  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.created":
          currentSessionId = event.properties.sessionID;
          await hook("session-start");
          break;
        case "session.idle":
          await hook("stop");
          break;
        case "session.status":
          if (event.properties.status.type === "busy") {
            await hook("prompt-submit");
          }
          break;
        case "permission.asked":
          await hook("notification", {
            message: "OpenCode needs your permission",
          });
          break;
      }
    },
    "tool.execute.before": async (input) => {
      await hook("pre-tool-use", { tool_name: input.tool });
    },
    "tool.execute.after": async (input) => {
      await hook("post-tool-use", { tool_name: input.tool });
    },
  };
};
