{
  description = "Reimagined language server for Elixir";

  inputs.nixpkgs.url = "flake:nixpkgs";
  inputs.beam-flakes.url = "github:elixir-tools/nix-beam-flakes";

  outputs = {
    self,
    nixpkgs,
    beam-flakes,
    ...
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (
        system: let
          pkgs = import nixpkgs {inherit system;};
        in
          f pkgs
      );
  in {
    imports = [beam-flakes.flakeModule];

    lib = {
      mkExpert = {
        erlang,
        system,
        elixir ? erlang.elixir,
        hash ? builtins.readFile ./nix/hash,
      }:
        erlang.callPackage ./nix/expert.nix {inherit elixir hash;};
    };

    formatter = forAllSystems ({alejandra}: alejandra);

    apps.update-hash = forAllSystems (pkgs: let
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
    });

    overlays = {
      default = final: _prev: {
        expert-lsp = self.packages.${final.system}.expert;
      };
    };

    packages = forAllSystems (pkgs: let
      # burrito doesnt have newest OTP26 releases version
      erlang_26 = pkgs.beam.interpreters.erlang.override rec {
        version = "26.2.5.9";
        src = pkgs.fetchFromGitHub {
          owner = "erlang";
          repo = "otp";
          rev = "OTP-${version}";
          sha256 = "sha256-FRNVmaeBUCFLmfhE9JVb1DgC/MIoryDV7lvh+YayRNA=";
        };
      };
      expert = self.lib.mkExpert {
        erlang = pkgs.beam.packagesWith erlang_26;
        system = pkgs.system;
      };
    in {
      inherit expert;
      default = expert;

      __fodHashGen = expert.mixFodDeps.overrideAttrs (final: curr: {
        outputHash = pkgs.lib.fakeSha256;
      });
    });
    beamWorkspace = forAllSystems (pkgs: {
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
    });
  };
}
