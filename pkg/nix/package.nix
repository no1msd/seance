{
  lib,
  stdenv,
  callPackage,
  wrapGAppsHook4,
  git,
  ncurses,
  pkg-config,
  zig_0_15,
  libnotify,
  libcanberra,
  adwaita-icon-theme,
  pkgs,
  revision ? "dirty",
  optimize ? "ReleaseSafe",
}: let
  ghosttyBuildInputs = import ../../ghostty/nix/build-support/build-inputs.nix {
    inherit pkgs lib stdenv;
  };
  gi_typelib_path = import ../../ghostty/nix/build-support/gi-typelib-path.nix {
    inherit pkgs lib stdenv;
  };
  strip = optimize != "Debug" && optimize != "ReleaseSafe";

  baseVersion = let
    zon = builtins.readFile ../../build.zig.zon;
    flat = builtins.replaceStrings ["\n"] [" "] zon;
    match = builtins.match ".*\\.version = \"([^\"]+)\".*" flat;
  in
    builtins.head match;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "seance";
    version = "${baseVersion}-${revision}";

    src = lib.fileset.toSource {
      root = ../../.;
      fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../../.)) (
        lib.fileset.unions [
          ../../ghostty
          ../../resources/icons
          ../../resources
          ../../src
          ../../build.zig
          ../../build.zig.zon
        ]
      );
    };

    deps = callPackage ../../ghostty/build.zig.zon.nix {
      name = "seance-zig-cache-${finalAttrs.version}";
    };

    nativeBuildInputs = [
      git
      ncurses
      pkg-config
      zig_0_15
      wrapGAppsHook4
    ];

    buildInputs =
      ghosttyBuildInputs
      ++ [
        libnotify
        libcanberra
        adwaita-icon-theme
      ];

    dontConfigure = true;
    dontStrip = !strip;

    preBuild = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
      export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
    '';

    preFixup = ''
      gappsWrapperArgs+=(
        --prefix XDG_DATA_DIRS : "${adwaita-icon-theme}/share"
      )
    '';

    GI_TYPELIB_PATH = gi_typelib_path;

    dontSetZigDefaultFlags = true;

    zigBuildFlags = [
      "--system"
      "${finalAttrs.deps}"
      "-Dcpu=baseline"
      "-Doptimize=${optimize}"
      "-Dstrip=${lib.boolToString strip}"
    ];

    meta = {
      description = "GPU-accelerated terminal multiplexer with AI agent support";
      homepage = "https://github.com/no1msd/seance";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      mainProgram = "seance";
    };
  })
