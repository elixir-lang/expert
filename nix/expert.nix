{
  beamPackages,
  callPackages,
  lib,
}:
let
  version = builtins.readFile ../version.txt;

  engineDeps = callPackages ../apps/engine/deps.nix {
    inherit lib beamPackages;
  };
in
beamPackages.mixRelease rec {
  pname = "expert";
  inherit version;

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ../apps
      ../mix_credo.exs
      ../mix_dialyzer.exs
      ../mix_includes.exs
      ../version.txt
    ];
  };

  mixNixDeps = callPackages ../apps/expert/deps.nix {
    inherit lib beamPackages;
  };

  mixReleaseName = "plain";

  preConfigure = ''
    # copy the logic from mixRelease to build a deps dir for engine
    mkdir -p apps/engine/deps
    ${lib.concatMapAttrsStringSep "\n" (name: dep: ''
      dep_path="apps/engine/deps/${name}"
      if [ -d "${dep}/src" ]; then
        ln -sv ${dep}/src $dep_path
      fi
    '') engineDeps}

    cd apps/expert
  '';

  postInstall = ''
    mv $out/bin/plain $out/bin/expert
    wrapProgram $out/bin/expert --add-flag "eval" --add-flag "System.no_halt(true); Application.ensure_all_started(:xp_expert)"
  '';

  removeCookie = false;

  passthru = {
    # not used by package, but exposed for repl and direct build access
    # e.g. nix build .#expert.mixNixDeps.jason
    inherit engineDeps mixNixDeps;
  };

  meta.mainProgram = "expert";
}
