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
    # Create deps dir in writable location instead of source tree
    mkdir -p $TMPDIR/engine-deps
    ${lib.concatMapStringsSep "\n" (dep: ''
      dep_name=$(basename ${dep} | cut -d '-' -f2)
      if [ -d "${dep}/src" ]; then
        rm -rf $TMPDIR/engine-deps/$dep_name 2>/dev/null || true
        ln -s ${dep}/src $TMPDIR/engine-deps/$dep_name
      fi
    '') (builtins.attrValues engineDeps)}
    
    # Link from source tree to the writable deps location
    mkdir -p apps/engine/deps
    for dep in $TMPDIR/engine-deps/*; do
      if [ -L "$dep" ]; then
        rm -rf apps/engine/deps/$(basename "$dep") 2>/dev/null || true
        ln -s $(readlink "$dep") apps/engine/deps/$(basename "$dep")
      fi
    done

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
