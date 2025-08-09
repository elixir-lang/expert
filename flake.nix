{
  description = "Reimagined language server for Elixir";

  inputs.nixpkgs.url = "flake:nixpkgs";
  inputs.beam-flakes.url = "github:elixir-tools/nix-beam-flakes";
  inputs.beam-flakes.inputs.flake-parts.follows = "flake-parts";

  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.systems.url = "github:nix-systems/default";

  outputs = {
    self,
    systems,
    beam-flakes,
    ...
  } @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [beam-flakes.flakeModule];
      flake = {
        lib = {
          mkExpert = {erlang}: erlang.callPackage ./nix/expert.nix {};
        };
      };

      systems = import systems;

      perSystem = {pkgs, ...}: let
        erlang = pkgs.beam.packages.erlang_25;
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
        beamWorkspace = {
          enable = true;
          devShell.languageServers.elixir = false;
          devShell.languageServers.erlang = false;
          versions = {
            elixir = "1.17.3";
            erlang = "27.3.4.1";
          };
          devShell.extraPackages = with pkgs; [
            zig
            xz
            just
            _7zz
          ];
        };
      };
    };
}
