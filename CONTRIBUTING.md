# Contributing to Séance

Thanks for considering a contribution. A few notes to save time.

## Filing issues

- Use one of the issue templates. Bug reports without a version, distro, and repro step are hard to act on.
- For feature ideas that are bigger than a single commit, open a Discussion first so we can talk about shape before anyone writes code.
- Agent support requests (new agents to auto-track) have their own template. The hook-system question is the important one.

## Building from source

```
git clone --recursive https://github.com/no1msd/seance.git
cd seance
zig build
./zig-out/bin/seance
```

You need Zig 0.15.2+, GTK4, libadwaita, OpenGL 4.3+, and Linux. The submodule (`ghostty`) must be checked out for libghostty to build.

## Code style

- Match existing style. Zig source uses the standard formatter (`zig fmt`).
- Keep functions small. If a function is growing past ~80 lines, look for a natural split.
- Comments should explain *why*, not *what*. Identifiers are for the what.
- Don't introduce dependencies without opening a Discussion first. The binary's "one file" feel matters.

## Pull requests

- One focused change per PR. Bundled refactors make reviewing slow.
- Include a short description that says what changed and why, not only what.
- If the change is user-visible, update the README if it's covered there.
- CI must pass before merge.

## Adding support for a new agent

The hook injection layer lives in a single file and is the main integration point. To add a new agent:

1. Identify the agent's hook or notification system. If it has one, write an injection routine that sets up config/env pointing at our hook commands.
2. Map its lifecycle events onto Séance's three states: working, waiting for permission, idle.
3. Add a detection check so Séance recognises when a new pane is running this agent.
4. Update the README's "Why Séance?" section and the bundled skill file if the agent exposes meaningful scriptable surface.

PR with the integration and a short note on how you tested it. I'll merge quickly if it's self-contained.

## Licensing

By contributing you agree that your contribution is MIT-licensed under the project's LICENSE.
