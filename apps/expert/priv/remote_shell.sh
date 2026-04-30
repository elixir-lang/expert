#!/usr/bin/env bash

set -euo pipefail

node_name="$1"
port="$2"
epmd_module="$3"
epmd_ebin_path="$4"
cookie="${5:-expert}"
lib_dir=$(dirname "$(dirname "$epmd_ebin_path")")

export EXPERT_PARENT_PORT="$port"
export ERL_LIBS="$lib_dir${ERL_LIBS:+:$ERL_LIBS}"

exec iex \
  --erl "-start_epmd false -epmd_module ${epmd_module} -connect_all false" \
  --name "expert-remote-shell-$$@127.0.0.1" \
  --cookie "$cookie" \
  --remsh "$node_name"
