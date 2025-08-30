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

[doc('Build a release for the local system')]
[unix]
release-local: (deps "engine") (deps "expert")
  #!/usr/bin/env bash
  cd apps/expert

  set -euxo pipefail

  if [ "{{ local_target }}" == "unsupported" ]; then
    echo "unsupported OS/Arch combination: {{ local_target }}"
    exit 1
  fi
  MIX_ENV={{ env('MIX_ENV', 'prod')}} EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="{{ local_target }}" mix release --overwrite

[windows]
release-local: (deps "engine") (deps "expert")
    # idk actually how to set env vars like this on windows, might crash
    EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="windows_amd64" MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release --overwrite

[doc('Build releases for all target platforms')]
release-all: (deps "engine") (deps "expert")
    #!/usr/bin/env bash
    cd apps/expert

    set -euxo pipefail

    EXPERT_RELEASE_MODE=burrito MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release --overwrite

[doc('Build a plain release without burrito')]
release-plain: (deps "engine") (deps "expert")
    #!/usr/bin/env bash
    cd apps/expert
    MIX_ENV={{ env('MIX_ENV', 'prod')}} mix release plain --overwrite

[doc('Compiles .github/matrix.json')]
compile-ci-matrix:
  elixir matrix.exs

[doc('Build and install binary locally')]
[unix]
install: release-local
  #!/usr/bin/env bash
  cp ./apps/expert/burrito_out/expert_{{ local_target }} ~/.local/bin/expert

default: release-local
