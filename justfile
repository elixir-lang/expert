mix_env := env('MIX_ENV', 'dev')
namespaced_dir := "_build" / mix_env + "_ns"
os := if os() == "macos" { "darwin" } else { os() }
arch := if arch() =~ "(arm|aarch64)" { "arm64" } else { if arch() =~ "(x86|x86_64)" { "amd64" } else { "unsupported" } }
local_target := if os =~ "(darwin|linux|windows)" { os + "_" + arch } else { "unsupported" }
apps := "expert engine forge expert_credo"

[doc('Run mix deps.get for the given project')]
deps project:
    #!/usr/bin/env bash
    cd apps/{{ project }}
    mix deps.get

[doc('Run an arbitrary command inside the given project directory')]
run project +ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    cd apps/{{ project }}
    eval "{{ ARGS }}"

[doc('Compile the given project.')]
compile project *args="": (deps project)
  cd apps/{{ project }} && mix compile {{ args }}

[doc('Run tests in the given project')]
test project="all" *args="":
  @just mix {{ project }} test {{args}}

[doc('Run a mix command in one or all projects. Use `just test` to run tests.')]
mix project="all" *args="":
    #!/usr/bin/env bash
    set -euxo pipefail

    case {{ project }} in
      all)
        for proj in {{ apps }}; do
          (cd "apps/$proj" && mix {{args}})
        done
      ;;
      *)
         (cd "apps/{{ project }}" && mix {{args}})
      ;;
    esac

[doc('Lint all projects or just a single project')]
lint *project="all":
  #!/usr/bin/env bash
  set -euxo pipefail

  just mix {{ project }} format --check-formatted
  just mix {{ project }} credo
  just mix {{ project }} dialyzer

build project *args: (compile project)
  #!/usr/bin/env bash
  set -euo pipefail
  cd apps/{{ project }}
  mix build --directory "{{ namespaced_dir }}" {{ args }}

[private]
build-engine:
  #!/usr/bin/env bash
  set -euxo pipefail

  cd apps/engine
  MIX_ENV=dev mix compile
  namespaced_dir=_build/dev_ns/
  rm -rf $namespaced_dir
  mkdir -p $namespaced_dir

  cp -a _build/dev/. "$namespaced_dir"

  MIX_ENV=dev mix namespace --directory "$namespaced_dir" --include-app engine --include-root Engine --include-root Future --dot-apps

namespace-expert directory="_build/prod":
  #!/usr/bin/env bash
  set -euxo pipefail

  cd apps/expert
  mix namespace --directory {{ directory }} --include-app expert --exclude-root Expert --exclude-app burrito --exclude-app req --exclude-app finch --exclude-app nimble_options --exclude-app nimble_pool --exclude-root Jason --include-root Engine --include-app engine

[private]
build-expert:
  #!/usr/bin/env bash
  cd apps/expert
  MIX_ENV=prod mix compile
  just namespace-expert

[doc('Start the local development server')]
start *opts="--port 9000": build-engine
  #!/usr/bin/env bash
  set -euxo pipefail

  cd apps/expert
  MIX_ENV=dev mix compile
  namespaced_dir=_build/dev_ns
  rm -rf $namespaced_dir
  mkdir -p $namespaced_dir

  cp -r _build/dev/ $namespaced_dir

  just namespace-expert $namespaced_dir

  MIX_BUILD_PATH="$namespaced_dir" EXPERT_ENGINE_PATH="{{ "../engine" / namespaced_dir }}" iex -S mix run \
    --no-compile \
    --no-halt \
    -e "Application.ensure_all_started(:expert)" \
    -- {{ opts }}

[doc('Build a release for the local system')]
[unix]
release-local: (deps "expert") (compile "engine") build-engine build-expert
  #!/usr/bin/env bash
  set -euxo pipefail

  cd apps/expert

  if [ "{{ local_target }}" == "unsupported" ]; then
    echo "unsupported OS/Arch combination: {{ local_target }}"
    exit 1
  fi

  MIX_ENV={{ env('MIX_ENV', 'prod')}}EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="{{ local_target }}" mix release --no-compile --overwrite

[windows]
release-local: (deps "expert") (compile "engine") build-engine build-expert
    cd apps/expert

    # idk actually how to set env vars like this on windows, might crash
    EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="windows_amd64" MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release --no-compile

[doc('Build releases for all target platforms')]
release-all: (deps "expert") (compile "engine") build-engine build-expert
    #!/usr/bin/env bash
    cd apps/expert
    EXPERT_RELEASE_MODE=burrito MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release --no-compile

[doc('Build a plain release without burrito')]
release-plain: (compile "engine") build-engine build-expert
    #!/usr/bin/env bash
    cd apps/expert
    MIX_ENV={{ env('MIX_ENV', 'prod')}}mix release plain --no-compile --overwrite

[doc('Compiles .github/matrix.json')]
compile-ci-matrix:
  elixir matrix.exs

default: release-local
