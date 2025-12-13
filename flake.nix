{
  description = "prise development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      zig-overlay,
      ...
    }:
    let
      overlays = [
        zig-overlay.overlays.default
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import nixpkgs { inherit overlays system; };
          }
        );
    in
    {
      devShells = forAllSystems (
        { pkgs }:
        let
          zigdoc = pkgs.stdenvNoCC.mkDerivation {
            pname = "zigdoc";
            version = "0.1.0";
            src = pkgs.fetchFromGitHub {
              owner = "rockorager";
              repo = "zigdoc";
              rev = "v0.1.0";
              hash = "sha256-nClG2L4ac0Bu+dGkanSFjoLHszeMoUFV9BdBEEKkdhA=";
            };

            nativeBuildInputs = [ pkgs.zigpkgs."0.15.2" ];

            dontConfigure = true;

            preBuild = ''
              export HOME=$TMPDIR
            '';

            buildPhase = ''
              runHook preBuild
              zig build --prefix $out -Doptimize=ReleaseSafe
              runHook postBuild
            '';

            dontInstall = true;
          };
        in
        {
          default = pkgs.mkShell {
            name = "prise-dev";

            packages =
              with pkgs;
              [
                zigpkgs."0.15.2"
                stylua
                zigdoc
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
                pkgs.darwin.DarwinTools
              ];

            shellHook = ''
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                # Expose system xcrun and Xcode SDK for Zig
                export PATH="/usr/bin:$PATH"
                unset SDKROOT
                unset DEVELOPER_DIR
              ''}

              echo "prise development environment"
              echo "zig version: $(zig version)"
              echo ""
              echo "Quick start:"
              echo "  zig build        - build the project"
              echo "  zig build test   - run tests"
              echo "  zig build fmt    - format code"
              echo "  zig build run    - run prise"
            '';
          };
        }
      );
    };
}
