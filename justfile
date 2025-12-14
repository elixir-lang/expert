os := if os() == "macos" { "darwin" } else { os() }
arch := if arch() =~ "(arm|aarch64)" { "arm64" } else { if arch() =~ "(x86|x86_64)" { "amd64" } else { "unsupported" } }
local_target := if os =~ "(darwin|linux|windows)" { os + "_" + arch } else { "unsupported" }
apps := "expert engine forge expert_credo"
expert_erl_flags := "-start_epmd false -epmd_module Elixir.Forge.EPMD"
engine_erl_flags := "-start_epmd false -epmd_module Elixir.Forge.EPMD"

[doc('Run mix deps.get for the given project')]
[unix]
deps project:
    #!/usr/bin/env bash
    cd apps/{{ project }}
    mix deps.get

[windows]
deps project:
    cd apps/{{ project }} && \
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
          case $proj in
            expert)
              (cd "apps/$proj" && elixir --erl "{{ expert_erl_flags }}" -S mix {{args}})
            ;;
            engine)
              (cd "apps/$proj" && elixir --erl "{{ engine_erl_flags }}" -S mix {{args}})
            ;;
            *)
              (cd "apps/$proj" && mix {{args}})
            ;;
          esac
        done
      ;;
      expert)
        (cd "apps/expert" && elixir --erl "{{ expert_erl_flags }}" -S mix {{args}})
      ;;
      engine)
        (cd "apps/engine" && elixir --erl "{{ engine_erl_flags }}" -S mix {{args}})
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

[doc('Build a burrito release for the local system')]
[unix]
burrito-local: (deps "engine") (deps "expert")
  #!/usr/bin/env bash
  cd apps/expert

  set -euxo pipefail

  if [ "{{ local_target }}" == "unsupported" ]; then
    echo "unsupported OS/Arch combination: {{ local_target }}"
    exit 1
  fi
  MIX_ENV={{ env('MIX_ENV', 'prod')}} EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="{{ local_target }}" mix release --overwrite

[windows]
burrito-local: (deps "engine") (deps "expert")
    export EXPERT_RELEASE_MODE=burrito && \
    export BURRITO_TARGET="windows_amd64" && \
    export MIX_ENV={{ env('MIX_ENV', 'prod')}} && \
    cd apps/expert && \
    mix release --overwrite

[doc('Build releases for all target platforms')]
burrito: (deps "engine") (deps "expert")
    #!/usr/bin/env bash
    cd apps/expert

    set -euxo pipefail

    EXPERT_RELEASE_MODE=burrito MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release --overwrite

[doc('Build a plain release for the local system')]
[unix]
release: (deps "engine") (deps "expert")
    #!/usr/bin/env bash
    cd apps/expert
    MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release plain --overwrite

[windows]
release: (deps "engine") (deps "expert")
    cd apps/expert && export MIX_ENV={{ env('MIX_ENV', 'prod')}} && mix release plain --overwrite

[doc('Compiles .github/matrix.json')]
compile-ci-matrix:
  elixir matrix.exs

[doc('Build and install binary locally')]
[unix]
install: burrito-local
  #!/usr/bin/env bash
  set -euxo pipefail

  mkdir -p ~/.local/bin
  cp ./apps/expert/burrito_out/expert_{{ local_target }} ~/.local/bin/expert
  chmod +x ~/.local/bin/expert

clean-engine:
  elixir -e ':filename.basedir(:user_data, "Expert") |> File.rm_rf!() |> IO.inspect()'

default: burrito-local

