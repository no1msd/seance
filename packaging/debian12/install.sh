#!/usr/bin/env bash
#
# Séance — build & install on Debian 12 (bookworm).
#
# Debian 12 ships GTK 4.8 and libadwaita 1.2, which are older than séance's
# default target (GTK 4.12+, libadwaita 1.4/1.5+). This tree carries a
# compatibility patch that lets it build against those older libraries, so on
# Debian 12 you can build straight from source with this script.
#
# Works on arm64 (aarch64) and amd64 (x86_64). Run from the repository root:
#
#     ./packaging/debian12/install.sh
#
set -euo pipefail

ZIG_VERSION="0.15.2"
PREFIX="${PREFIX:-$HOME/.local}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f build.zig ] || die "run this from the séance repository root (build.zig not found)"

# ── 1. System build dependencies ───────────────────────────────────────────
log "Installing build dependencies (sudo apt)…"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git pkg-config gettext blueprint-compiler \
    libgtk-4-dev libadwaita-1-dev \
    libgl1-mesa-dev libegl1-mesa-dev \
    libnotify-dev libcanberra-dev libonig-dev

# ── 2. Fetch a pinned Zig toolchain (not packaged in Debian 12) ─────────────
case "$(uname -m)" in
    aarch64|arm64) ZIG_ARCH="aarch64" ;;
    x86_64|amd64)  ZIG_ARCH="x86_64"  ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

ZIG_DIR="$(pwd)/.zig-toolchain"
ZIG="$ZIG_DIR/zig"
if [ ! -x "$ZIG" ] || ! "$ZIG" version 2>/dev/null | grep -q "^${ZIG_VERSION}$"; then
    TARBALL="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
    log "Downloading Zig ${ZIG_VERSION} for ${ZIG_ARCH}…"
    rm -rf "$ZIG_DIR"; mkdir -p "$ZIG_DIR"
    curl -fSL "$URL" -o "/tmp/${TARBALL}"
    tar -xf "/tmp/${TARBALL}" -C "$ZIG_DIR" --strip-components=1
    rm -f "/tmp/${TARBALL}"
fi
log "Using $("$ZIG" version) at $ZIG"

# ── 3. Make sure the ghostty submodule is present ───────────────────────────
if [ ! -e ghostty/build.zig ]; then
    log "Fetching ghostty submodule…"
    git submodule update --init --recursive
fi

# ── 4. Build ────────────────────────────────────────────────────────────────
log "Building séance (ReleaseFast)… this compiles libghostty and takes a while."
"$ZIG" build -Doptimize=ReleaseFast

# ── 5. Install ────────────────────────────────────────────────────────────────
install -Dm755 zig-out/bin/seance "$PREFIX/bin/seance"
log "Installed séance to $PREFIX/bin/seance"

case ":$PATH:" in
    *":$PREFIX/bin:"*) : ;;
    *) printf '\033[1;33mnote:\033[0m add %s to your PATH (e.g. in ~/.bashrc): export PATH="%s:$PATH"\n' "$PREFIX/bin" "$PREFIX/bin" ;;
esac

cat <<'EOF'

Done. Launch with:  seance
Control a running instance with:  seance ctl <command>   (try: seance ctl tree)

GPU note: ghostty's terminal panes need an OpenGL context. On bare metal with
working GPU drivers this is automatic. In a VM without accelerated GL (e.g.
virtio-gpu with no virglrenderer), force Mesa's software renderer:

    LIBGL_ALWAYS_SOFTWARE=1 seance

EOF
