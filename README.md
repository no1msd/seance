<p align="center">
  <img src="resources/icons/hicolor/scalable/apps/com.seance.app.svg" width="128" alt="Séance logo">
</p>

<h1 align="center">Séance</h1>

<p align="center">
  A scrolling terminal multiplexer that tracks your AI coding agents.
</p>

<p align="center">
  <img src="demo.gif" alt="Séance demo" width="800">
</p>

---

## Why Séance?

Running multiple AI coding agents at once means constantly checking which one finished, which one is stuck waiting for permission, and which one needs your attention.

Séance automatically injects hooks into [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), and [Pi](https://github.com/badlogic/pi-mono) sessions with zero configuration so it can track what each one is doing. Agent status (working, waiting for permission, idle) is shown in the sidebar in real time, and events like permission requests or task completions are delivered as desktop notifications with unread tracking.

### Scrolling layout

Panes are arranged in a horizontal strip that you scroll through, borrowing the layout model from [niri](https://github.com/YaLTeR/niri).

### Scriptable

Every action is available through `seance ctl`, which talks to the running instance over a Unix domain socket. Scripts and AI agents can create workspaces, open panes, send input, read terminal output, and query the full session hierarchy. All commands support JSON output.

A bundled [skill file](skills/seance-skill.md) provides AI agents with a complete reference for the `seance ctl` API, so they can use the multiplexer on their own.

### And also

Workspaces, session persistence across restarts, tabs within columns, a command palette, blur and transparency on X11 and Wayland, focus-follows-mouse, and GPU-accelerated rendering via [libghostty](https://ghostty.org).

## Installation

### Arch Linux (AUR)

```bash
yay -S seance
```

### Nix (flake)

To run it directly without installing:

```bash
nix run "git+https://github.com/no1msd/seance?submodules=1"
```

To install it persistently into your profile:

```bash
nix profile install "git+https://github.com/no1msd/seance?submodules=1"
```

Both commands compile from source on the first run and cache the result in
the Nix store.

> **Non-NixOS users:** EGL won't initialize without a GL wrapper.
> On Intel/AMD use [`nixGL`](https://github.com/nix-community/nixGL):
>
> ```bash
> nix run --impure github:nix-community/nixGL#nixGLIntel -- \
>   nix run "git+https://github.com/no1msd/seance?submodules=1"
> ```
>
> On Nvidia use [`nix-gl-host`](https://github.com/numtide/nix-gl-host), since
> nixGL's Nvidia wrapper breaks on recent drivers:
>
> ```bash
> nix run github:numtide/nix-gl-host -- \
>   $(nix build --no-link --print-out-paths \
>     "git+https://github.com/no1msd/seance?submodules=1")/bin/seance
> ```

### AppImage

Download the latest `seance-*-x86_64.AppImage` from [GitHub Releases](https://github.com/no1msd/seance/releases), make it executable, and run it:

```bash
chmod +x seance-*-x86_64.AppImage
./seance-*-x86_64.AppImage
```

Requires `libfuse2` on the host. Uses the host's `libGL`/`libEGL`, so Mesa or proprietary GPU drivers must be installed.

To use `seance ctl` from your shell, move the AppImage onto your `PATH`:

```bash
mv seance-*-x86_64.AppImage ~/.local/bin/seance
```

### Building from source

Requires Zig **0.15.2+**, GTK4, libadwaita, OpenGL 4.3+, and Linux (X11 or Wayland).

```bash
git clone --recursive https://github.com/no1msd/seance.git
cd seance
zig build
```

The binary is at `zig-out/bin/seance`.

## License

[MIT](LICENSE)

## Acknowledgements

- [Ghostty](https://ghostty.org) for terminal emulation
- [cmux](https://github.com/manaflow-ai/cmux) and [niri](https://github.com/YaLTeR/niri) as key inspirations for layout and interaction model
- Built with [Zig](https://ziglang.org), [GTK4](https://gtk.org), and [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/)
