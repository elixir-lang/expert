{
  lib,
  mixRelease,
  fetchMixDeps,
  elixir,
  hash ? builtins.readFile ./hash,
  writeScript,
  makeWrapper,
  zig,
  xz,
  _7zz,
  system,
}:
mixRelease rec {
  MIX_ENV = "prod";
  EXPERT_RELEASE_MODE = "burrito";

  pname = "expert";
  version = "development";
  src = lib.cleanSource ./..;

  mixFodDeps = fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit src version hash;
    mixEnv = "prod";

    installPhase = ''
      runHook preInstall
      cd apps/expert; mix deps.get ''${MIX_ENV:+--only $MIX_ENV}; cd -;
      find "$TEMPDIR/deps" -path '*/.git/*' -a ! -name HEAD -exec rm -rf {} +
      cp -r --no-preserve=mode,ownership,timestamps $TEMPDIR/deps $out
      runHook postInstall
    '';
  };

  nativeBuildInputs = [makeWrapper zig xz _7zz];

  configurePhase = ''
    runHook preConfigure
    export MIX_HOME=$TEMPDIR/.mix
    export HEX_HOME=$TEMPDIR/.hex
    cd apps/expert
    mix deps.compile --no-deps-check
    runHook postConfigure
  '';

  buildPhase = let
    burritoTarget =
      {
        "aarch64-darwin" = "darwin_arm64";
        "x86_64-darwin" = "darwin_amd64";
        "aarch64-linux" = "linux_arm64";
        "x86_64-linux" = "linux_amd64";
      }."${system}" or (throw "Unsupported system: ${system}");
  in ''
    runHook preBuild
    export BURRITO_TARGET=${burritoTarget}
    export HOME=$TMPDIR/home
    export XDG_CACHE_HOME=$TMPDIR/cache
    mkdir -p $HOME $XDG_CACHE_HOME
    ln -sf ../../deps ../engine/deps
    ln -sf ../../deps ../forge/deps
    mix compile --no-deps-check
    mix release expert --overwrite --path ./release_build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r release_build/* $out/

    if [ -d "burrito_out" ]; then
      mkdir -p $out/burrito_out
      cp -r burrito_out/* $out/burrito_out/
    fi

    find $out -type l -exec test ! -e {} \; -delete

    runHook postInstall
  '';

  preFixup = let
    activate_version_manager = writeScript "activate_version_manager.sh" ''
      #!/usr/bin/env bash
      true
    '';

    burritoBinary =
      {
        "aarch64-darwin" = "expert_darwin_arm64";
        "x86_64-darwin" = "expert_darwin_amd64";
        "aarch64-linux" = "expert_linux_arm64";
        "x86_64-linux" = "expert_linux_amd64";
      }."${system}" or null;
  in ''
    # Fix paths in start script
    if [ -f "$out/bin/start_expert.sh" ]; then
      substituteInPlace "$out/bin/start_expert.sh" \
        --replace 'elixir_command=' 'elixir_command="${elixir}/bin/"'

      rm -f "$out/bin/activate_version_manager.sh"
      ln -s ${activate_version_manager} "$out/bin/activate_version_manager.sh"

      mv "$out/bin" "$out/binsh"
      makeWrapper "$out/binsh/start_expert.sh" "$out/bin/expert" \
        --set RELEASE_COOKIE expert
    fi

    # Use Burrito binary if it exists for this system
    if [ -n "${burritoBinary}" ] && [ -f "$out/burrito_out/${burritoBinary}" ]; then
      mkdir -p $out/bin
      cp "$out/burrito_out/${burritoBinary}" "$out/bin/expert"
      chmod +x "$out/bin/expert"
    fi

    # Copy Erlang cookie so distributed mode works
    if [ -f "$out/releases/COOKIE" ]; then
      mkdir -p $out/var
      cp "$out/releases/COOKIE" "$out/var/COOKIE"
      chmod 600 "$out/var/COOKIE"
    fi
  '';

  meta = with lib; {
    description = "Official Elixir Language Server Protocol implementation";
    repository = "https://github.com/elixir-lang/expert";
    homepage = "https://expert-lsp.org";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
