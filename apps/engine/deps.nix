{
  pkgs,
  lib,
  beamPackages,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ pkgs.beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        ...
      }:
      old:
      let
        extendedPkgs = pkgs.extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/056c9393c821a4df356df6ce7f14c722dc8717ec.tar.gz";
                sha256 = "sha256:1cdfh6nj81gjmn689snigidyq7w98gd8hkl5rvhly6xj7vyppmnd";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (extendedPkgs.makeRustPlatform {
            inherit (fenix) cargo rustc;
          }).buildRustPackage
            {
              pname = "${old.packageName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [
                extendedPkgs.cmake
              ];
              doCheck = false;
            };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            ln -s "$lib" "priv/native/$(basename "$lib")"
          done
        '';

        buildPhase = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.packageName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
          ${old.buildPhase}
        '';
      };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2024-11-01";
              sha256 = "sha256-wq7bZ1/IlmmLkSa3GUJgK17dTWcKyf5A+ndS9yRwB88=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      briefly =
        let
          version = "0.5.1";
          drv = buildMix {
            inherit version;
            name = "briefly";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "briefly";
              sha256 = "bd684aa92ad8b7b4e0d92c31200993c4bc1469fc68cd6d5f15144041bd15cb57";
            };
          };
        in
        drv;

      elixir_sense =
        let
          version = "e3ddc403554050221a2fd19a10a896fa7525bc02";
          drv = buildMix {
            inherit version;
            name = "elixir_sense";
            appConfigPath = ./config;

            src = pkgs.fetchFromGitHub {
              owner = "elixir-lsp";
              repo = "elixir_sense";
              rev = "e3ddc403554050221a2fd19a10a896fa7525bc02";
              hash = "sha256-Rs/c6uduC2xauSwO7FGEVYWiyhNbhSsIcw5s04d+A8M=";
            };
          };
        in
        drv;

      gen_lsp =
        let
          version = "0.11.3";
          drv = buildMix {
            inherit version;
            name = "gen_lsp";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "gen_lsp";
              sha256 = "a674de4b06cbc56311d13a0fdf69066837785ba9c90da54984e58f485fd019cb";
            };

            beamDeps = [
              jason
              nimble_options
              schematic
              typed_struct
            ];
          };
        in
        drv;

      jason =
        let
          version = "1.4.4";
          drv = buildMix {
            inherit version;
            name = "jason";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b";
            };
          };
        in
        drv;

      nimble_options =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "nimble_options";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
            };
          };
        in
        drv;

      nimble_parsec =
        let
          version = "1.2.3";
          drv = buildMix {
            inherit version;
            name = "nimble_parsec";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_parsec";
              sha256 = "c8d789e39b9131acf7b99291e93dae60ab48ef14a7ee9d58c6964f59efb570b0";
            };
          };
        in
        drv;

      path_glob =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "path_glob";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "path_glob";
              sha256 = "be2594cb4553169a1a189f95193d910115f64f15f0d689454bb4e8cfae2e7ebc";
            };

            beamDeps = [
              nimble_parsec
            ];
          };
        in
        drv;

      refactorex =
        let
          version = "0.1.52";
          drv = buildMix {
            inherit version;
            name = "refactorex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "refactorex";
              sha256 = "4927fe6c3acd1f4695d6d3e443380167d61d004d507b1279c6084433900c94d0";
            };

            beamDeps = [
              sourceror
            ];
          };
        in
        drv;

      schematic =
        let
          version = "0.2.1";
          drv = buildMix {
            inherit version;
            name = "schematic";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "schematic";
              sha256 = "0b255d65921e38006138201cd4263fd8bb807d9dfc511074615cd264a571b3b1";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      snowflake =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "snowflake";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "snowflake";
              sha256 = "badb07ebb089a5cff737738297513db3962760b10fe2b158ae3bebf0b4d5be13";
            };
          };
        in
        drv;

      sourceror =
        let
          version = "1.10.0";
          drv = buildMix {
            inherit version;
            name = "sourceror";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "sourceror";
              sha256 = "29dbdfc92e04569c9d8e6efdc422fc1d815f4bd0055dc7c51b8800fb75c4b3f1";
            };
          };
        in
        drv;

      telemetry =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "7015fc8919dbe63764f4b4b87a95b7c0996bd539e0d499be6ec9d7f3875b79e6";
            };
          };
        in
        drv;

      typed_struct =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "typed_struct";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "typed_struct";
              sha256 = "c50bd5c3a61fe4e198a8504f939be3d3c85903b382bde4865579bc23111d1b6d";
            };
          };
        in
        drv;

    };
in
self
