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
compile project: (deps project)
  cd apps/{{ project }} && mix compile

[doc('Run tests in the given project')]
test project="all" *args="":
    #!/usr/bin/env bash
    set -euo pipefail

    case {{ project }} in
      all)
        for proj in {{ apps }}; do
          (cd "apps/$proj" && mix test {{args}})
        done
      ;;
      *)
         (cd "apps/{{ project }}" && mix test {{args}})
      ;;
    esac

[doc('Run a mix command in one or all projects. Use `just test` to run tests.')]
mix cmd *project:
    #!/usr/bin/env bash

    if [ -n "{{ project }}" ]; then
      cd apps/{{ project }}
      mix {{ cmd }}
    else
      for project in {{ apps }}; do
      (
        cd apps/"$project"

        mix {{ cmd }}
      )
      done
    fi

[doc('Lint all projects or just a single project')]
lint *project:
  #!/usr/bin/env bash
  set -euxo pipefail

  just mix "format --check-formatted" {{ project }}
  just mix credo {{ project }}
  just mix dialyzer {{ project }}

build-engine:
  #!/usr/bin/env bash

  cd apps/engine
  mix build


[doc('Build a release for the local system')]
[unix]
release-local: (deps "expert") (compile "engine") build-engine
  #!/usr/bin/env bash
  cd apps/expert

  if [ "{{ local_target }}" == "unsupported" ]; then
    echo "unsupported OS/Arch combination: {{ local_target }}"
    exit 1
  fi
  MIX_ENV=prod EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="{{ local_target }}" mix release --overwrite

[windows]
release-local: (deps "expert") (compile "engine") build-engine
    # idk actually how to set env vars like this on windows, might crash
    EXPERT_RELEASE_MODE=burrito BURRITO_TARGET="windows_amd64" MIX_ENV=prod mix release --no-compile

[doc('Build releases for all target platforms')]
release-all: (compile "engine")
    #!/usr/bin/env bash
    cd apps/expert
    EXPERT_RELEASE_MODE=burrito MIX_ENV=prod mix release --no-compile

[doc('Build a plain release without burrito')]
release-plain: (compile "engine")
    #!/usr/bin/env bash
    cd apps/expert
    MIX_ENV=prod mix release plain --overwrite

default: release-local

