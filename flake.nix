{
  description = "Reimagined language server for Elixir";

  inputs.nixpkgs.url = "flake:nixpkgs";
  inputs.zigpkgs.url = "github:nixos/nixpkgs/12a55407652e04dcf2309436eb06fef0d3713ef3";
  inputs.xzpkgs.url = "github:nixos/nixpkgs/18dd725c29603f582cf1900e0d25f9f1063dbf11";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.systems.url = "github:nix-systems/default";

  outputs = {
    self,
    systems,
    zigpkgs,
    xzpkgs,
    ...
  } @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      flake = {
        lib = {
          mkExpert = {erlang}: erlang.callPackage ./nix/expert.nix {};
        };
      };

      systems = import systems;

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        erlang = pkgs.beam.packages.erlang_25;
        zpkgs = zigpkgs.legacyPackages.${system};
        xzpkgs' = xzpkgs.legacyPackages.${system};
        expert = self.lib.mkExpert {inherit erlang;};
      in {
        formatter = pkgs.alejandra;

        apps.update-hash = let
          script = pkgs.writeShellApplication {
            name = "update-hash";

            runtimeInputs = [pkgs.nixFlakes pkgs.gawk];

            text = ''
              nix --extra-experimental-features 'nix-command flakes' \
                build --no-link "${self}#__fodHashGen" 2>&1 | gawk '/got:/ { print $2 }' || true
            '';
          };
        in {
          type = "app";
          program = "${script}/bin/update-hash";
        };

        packages = {
          inherit expert;
          default = expert;

          __fodHashGen = expert.mixFodDeps.overrideAttrs (final: curr: {
            outputHash = pkgs.lib.fakeSha256;
          });
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            beam.packages.erlang_27.erlang
            beam.packages.erlang_27.elixir_1_17
            zpkgs.zig_0_14
            xzpkgs'.xz
            just
            _7zz
          ];
        };
      };
    };
}
