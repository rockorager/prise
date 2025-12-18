{
  description = "prise development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = {
    nixpkgs,
    zig,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems f;
  in {
    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        zig-pkg = zig.packages.${system}."0.15.2";

        zigdoc = pkgs.stdenvNoCC.mkDerivation {
          pname = "zigdoc";
          version = "0.1.0";
          src = pkgs.fetchFromGitHub {
            owner = "rockorager";
            repo = "zigdoc";
            rev = "v0.1.0";
            hash = "sha256-nClG2L4ac0Bu+dGkanSFjoLHszeMoUFV9BdBEEKkdhA=";
          };
          nativeBuildInputs = [zig-pkg];
          dontConfigure = true;
          preBuild = "export HOME=$TMPDIR";
          buildPhase = ''
            runHook preBuild
            zig build --prefix $out -Doptimize=ReleaseSafe
            runHook postBuild
          '';
          dontInstall = true;
        };
      in {
        default = pkgs.mkShell {
          name = "prise-dev";
          packages =
            [
              zig-pkg
              zigdoc
              pkgs.stylua
              pkgs.lua-language-server
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.DarwinTools
            ];

          shellHook = ''
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
              export PATH="/usr/bin:$PATH"
              unset SDKROOT
              unset DEVELOPER_DIR
            ''}
          '';
        };
      }
    );

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
  };
}
