# Seance Terminal Multiplexer

You are running inside **Seance**, a GPU-accelerated scrolling terminal multiplexer with native AI agent integration. Built on [Ghostty](https://ghostty.org) for terminal emulation and rendering.

You can create panes, run commands in them, read their output, manage workspaces, send notifications, and more — all via the `seance ctl` CLI over a Unix domain socket.

## Detection

You are inside Seance if either of these environment variables is set:
- `$SEANCE_SOCKET_PATH` — path to the Seance Unix socket
- `$SEANCE_SURFACE_ID` — ID of the pane you're running in

## Architecture Overview

Seance uses a **horizontal scrolling column** layout (inspired by niri) instead of a fixed grid. Adding a pane never shrinks existing ones — you scroll to see more.

**Hierarchy:** Window > Workspace > Column > PaneGroup > Pane

- **Windows** contain multiple workspaces as tabs in a sidebar
- **Workspaces** are horizontal strips of columns you scroll through
- **Columns** are vertical stacks; each has an animated width and can be **stacked** (all panes visible) or **tabbed** (one pane + tab bar)
- **Panes** (surfaces) are individual terminal instances, each with its own PTY

Each pane has environment variables identifying it: `SEANCE_PANEL_ID`, `SEANCE_WORKSPACE_ID`, `SEANCE_SURFACE_ID`.

## CLI Reference

All commands use the form: `seance ctl [global-flags] <command> [args...]`

### Global Flags

| Flag | Description |
|------|-------------|
| `--socket PATH` | Override the Unix socket path |
| `--json` | Output results as JSON |
| `--workspace N` | Specify workspace context by ID |
| `--surface N` | Specify surface/pane context by ID |

### System Commands

```bash
seance ctl ping                    # Health check (returns "pong")
seance ctl identify                # Show your current pane, group, workspace, window
seance ctl capabilities            # List all supported API methods
seance ctl tree                    # Full hierarchy: windows > workspaces > groups > surfaces
```

### Window Commands

```bash
seance ctl list-windows            # List all open windows
seance ctl new-window              # Create a new window
seance ctl close-window [INDEX]    # Close a window (default: active)
```

### Workspace Commands

```bash
seance ctl list-workspaces [--window N]       # List workspaces
seance ctl new-workspace [--title TITLE]      # Create a new workspace
seance ctl select-workspace ID                # Focus/switch to a workspace
seance ctl close-workspace ID                 # Close a workspace
seance ctl rename-workspace ID TITLE          # Rename a workspace
seance ctl reorder-workspace ID --index N     # Reorder (also: --before ID, --after ID)
seance ctl move-workspace ID --window INDEX   # Move workspace to another window
seance ctl last-workspace                     # Switch to last-active workspace
```

### Column Commands

```bash
seance ctl move-column --direction left|right [--workspace N]    # Swap column position
seance ctl resize-column --wider|--narrower|--maximize           # Resize active column
```

### Surface (Pane) Commands

```bash
seance ctl list-surfaces [--workspace N]                  # List all panes
seance ctl split [--direction vertical|horizontal]        # Create new pane (default: vertical = side-by-side)
seance ctl close-surface ID                               # Close a pane
seance ctl send "TEXT" [--surface N]                       # Send text input to a pane
seance ctl send-key KEY [--surface N]                      # Send key: enter, ctrl+c, tab, etc.
seance ctl read-screen [--lines N] [--surface N]          # Read terminal output (default: 50 lines)
seance ctl --json read-screen [--surface N]               # JSON output with shell_state and cursor info
seance ctl expel-pane --direction left|right [--surface N] # Move pane to new/adjacent column
seance ctl resize-row --taller|--shorter [--surface N]    # Resize pane height in stacked column
seance ctl reorder-surface ID --index N                   # Reorder tab (also: --before ID, --after ID)
seance ctl last-pane [--workspace N]                      # Switch to last-focused pane
```

### Notification Commands

```bash
seance ctl notify --title "TITLE" --body "BODY" [--subtitle S] [--workspace N] [--surface N]
seance ctl list-notifications           # List all notifications
seance ctl clear-notifications          # Clear all notifications
```

## read-screen JSON Response

When using `--json`, `read-screen` returns:

| Field | Description |
|-------|-------------|
| `text` | Visible terminal text (last N lines) |
| `shell_state` | `"prompt"` (idle), `"running"` (command in progress), or `"unknown"` |
| `cursor_row` | Current cursor row position |
| `cursor_col` | Current cursor column position |
| `rows` | Terminal height in rows |
| `cols` | Terminal width in columns |

## split JSON Response

When using `--json`, `split` returns:

| Field | Description |
|-------|-------------|
| `surface_id` | ID of the newly created pane |

## Core Workflow Pattern

When you need to run a command in a separate pane and read its output:

```bash
# 1. Create a pane
SURFACE_ID=$(seance ctl --json split | python3 -c "import sys,json; print(json.load(sys.stdin)['surface_id'])")

# 2. Run your command
seance ctl send "your-command-here\n" --surface $SURFACE_ID

# 3. Poll until complete — check shell_state for "prompt"
seance ctl --json read-screen --surface $SURFACE_ID

# 4. Read the final output
seance ctl read-screen --surface $SURFACE_ID --lines 200

# 5. Clean up
seance ctl close-surface $SURFACE_ID
```

## Multi-Workspace Workflow

Use workspaces to organize related work. Each workspace is an independent scrolling strip of columns:

```bash
# Create a workspace for a separate concern
WS_ID=$(seance ctl --json new-workspace --title "tests" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Switch to it
seance ctl select-workspace $WS_ID

# Create panes within it
seance ctl split --direction vertical

# Switch back to previous workspace
seance ctl last-workspace
```

## Guidelines

- **Always target specific surfaces** with `--surface ID` — never send to the user's focused pane by accident.
- **Don't close the user's panes** — only close panes you created.
- **Clean up when done** — close panes you no longer need.
- **Poll with backoff** — when waiting for a command, check every 1-2 seconds, not in a tight loop.
- **Use `shell_state`** — it tells you whether the shell is idle (`prompt`) or busy (`running`). Wait for `prompt` before reading final output.
- **Include `\n`** when sending commands via `seance ctl send` to actually execute them.
- **Use `--json`** when you need to parse output programmatically.
- **Vertical split = side-by-side** (new column), **horizontal split = top/bottom** (stacked in same column).
- **Notifications** appear in the sidebar with unread tracking and can trigger desktop notifications — use them for important status updates.
