{
  description = "GPU-accelerated terminal multiplexer with AI agent support";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;

    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: lib.genAttrs supportedSystems (system: f legacyPackages.${system});

    revision = self.shortRev or self.dirtyShortRev or "dirty";
  in {
    packages = forAllSystems (pkgs: rec {
      seance = pkgs.callPackage ./pkg/nix/package.nix {inherit revision;};
      default = seance;
    });

    overlays.default = final: prev: {
      seance = final.callPackage ./pkg/nix/package.nix {inherit revision;};
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = [
          zig.packages.${pkgs.stdenv.hostPlatform.system}."0.15.2"
          pkgs.pkg-config
          pkgs.ncurses
        ];

        buildInputs =
          (import ./ghostty/nix/build-support/build-inputs.nix {
            inherit pkgs;
            inherit (pkgs) lib stdenv;
          })
          ++ [
            pkgs.libnotify
            pkgs.libcanberra
          ];
      };
    });
  };
}
