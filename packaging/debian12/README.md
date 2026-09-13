# Séance on Debian 12 (bookworm)

Séance targets recent GNOME libraries (GTK 4.12+, libadwaita 1.4/1.5+). Debian
12 "bookworm" ships **GTK 4.8.3** and **libadwaita 1.2.2**, which predate
several APIs séance uses. This directory documents a compatibility layer that
lets séance build and run on those older libraries — useful for Debian 12 and
other long-term-support distributions that haven't moved to libadwaita 1.4+ yet.

Verified on Debian 12 **arm64** (aarch64) and applicable to amd64.

## Quick start

```bash
git clone --recursive https://github.com/no1msd/seance.git
cd seance
./packaging/debian12/install.sh
```

The script installs the system build dependencies, fetches a pinned Zig
toolchain (Zig is not packaged in Debian 12), builds with `zig build
-Doptimize=ReleaseFast`, and installs the binary to `~/.local/bin/seance`.

## What the compatibility patch changes

Each substitution uses an API that already exists in GTK 4.8 / libadwaita 1.2
and is behaviourally equivalent to the newer call:

| Upstream API (min version) | Debian 12 replacement |
| --- | --- |
| `gtk_gl_area_set_allowed_apis` (GTK 4.12) | `gtk_gl_area_set_use_es(area, FALSE)` — keeps the desktop-GL request |
| `gtk_css_provider_load_from_string` (GTK 4.12) | `gtk_css_provider_load_from_data(p, data, -1)` |
| `gtk_search_entry_set_placeholder_text` (GTK 4.10) | placeholder set on the entry's `GtkText` editable delegate |
| `GtkFontDialogButton` (GTK 4.10) | `GtkFontButton` (uses the `GtkFontChooser` `font-desc` property) |
| `AdwAlertDialog` (libadwaita 1.5) | `AdwMessageDialog` (libadwaita 1.2) |
| `AdwDialog` (libadwaita 1.5) | `AdwWindow` + `GtkWindow` (modal, transient-for, present) |
| `AdwToolbarView` (libadwaita 1.4) | a vertical `GtkBox` (header on top, content below) |
| `AdwBanner` (libadwaita 1.4) | a `GtkRevealer` wrapping a label + optional action button |
| `AdwSpinRow` (libadwaita 1.4) | `AdwActionRow` + `GtkSpinButton` suffix |
| `AdwSwitchRow` (libadwaita 1.4) | `AdwActionRow` + `GtkSwitch` suffix |
| `adw_combo_row_set_enable_search` (libadwaita 1.4) | omitted (search box is optional) |

All changes are source-level only; no new runtime dependencies are introduced.

## Dependencies

Build: `git pkg-config gettext blueprint-compiler libgtk-4-dev libadwaita-1-dev
libgl1-mesa-dev libegl1-mesa-dev libnotify-dev libcanberra-dev libonig-dev`,
plus Zig 0.15.2 (downloaded by the install script).

## GPU / OpenGL note

Ghostty's terminal panes render through an OpenGL context (`GtkGLArea`). On bare
metal with working GPU drivers this is automatic. In a VM **without** accelerated
GL — e.g. `virtio-gpu` with no `virglrenderer` on the host — desktop-GL context
creation fails with `Unable to create a GL context`. Force Mesa's software
renderer in that case:

```bash
LIBGL_ALWAYS_SOFTWARE=1 seance
```

## Verified (Debian 12 arm64)

- Builds cleanly from source (libghostty + séance).
- Launches; `seance ctl ping` → `pong`; `seance ctl tree` / `identify` work.
- OpenGL context succeeds (software renderer on the virtio-gpu test VM).
- **Interactive pane rendering confirmed.** Against a painting display, the
  `GtkGLArea` renders and ghostty spawns the pane's shell: a live `sh` child
  process and pty appear, the pane title tracks the shell prompt
  (`debian@debian: ~`), and the header bar, sidebar, and terminal all draw
  correctly.

Note: panes only initialise once the compositor actually paints the window, so
a purely headless session that never composites a frame won't start them.

## Known warnings (benign)

At startup you may see this logged once:

```
Adwaita-CRITICAL **: adw_tab_view_close_page: assertion 'page_belongs_to_this_view (self, page)' failed
```

It is **non-fatal and cosmetic** — the terminal pane spawns and renders normally.

- **Source:** séance's stacked-mode layout. Each column defaults to stacked mode
  on creation (`workspace.zig`), so `PaneGroup.enterStackedMode` immediately moves
  the pane out of its `AdwTabView` by unparenting the widget directly (intentional —
  it avoids an unrealize→realize cycle that would destroy the GLArea's GL context),
  then closes the now child-less pages.
- **Why it surfaces here:** on libadwaita 1.2, `adw_tab_view_close_page` rejects a
  page whose child was unparented behind the view's back. libadwaita logs the
  assertion and returns; the cleanup loop's guard then exits cleanly. Upstream
  targets libadwaita 1.4+, where this path doesn't trip the assertion.
- **Not introduced by this compatibility patch** — the stacked-mode code is
  unchanged; only the older library is stricter.

Left as-is intentionally: the safe-looking fixes would either reintroduce the
GL-context loss the stacked-mode code is engineered to avoid, or the moved-widget
disposal issue its comments describe.
