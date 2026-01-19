# Development

## Getting Started

First follow the [installation instructions](installation.md) to install the
required prerequisites.

To build Expert, run:

```sh
just release
```

You may point your editor's LSP configuration to the `start_expert` executable
in the generated release:

```sh
<your-repo>/apps/expert/_build/prod/rel/plain/bin/start_expert --stdio
```

## Parser Configuration

Expert uses [Spitfire](https://github.com/elixir-tools/spitfire) as the default
parser. To use the built-in Elixir parser instead, set the `EXPERT_PARSER` env
variable to `elixir` when building the release:

```sh
EXPERT_PARSER=elixir just release
```

## Logging

When expert starts up, it creates a `.expert` directory in the root
directory of a project. Inside that directory are two log files,
`expert.log` and `project.log`. The `.expert.log` log file contains
logging and OTP messages from the language server, while the
`project.log` file contains logging and OTP messages from the
project's node. While developing expert, it's helpful to open up a
terminal and tail both of these log files so you can see any errors
and messages that expert emits. To do that, run the following in a
terminal while in the project's root directory:

```sh
tail -f .expert/*.log
```

Note: These log files roll over when they reach 1 megabyte, so after a
time, it will be necessary to re-run the above command.

## Debugging

Expert supports a debug shell, which will connect a remote shell to a
currently-running language server process. To use it, `cd` into your expert
installation directory and run

```sh
./apps/expert/bin/debug_server.sh <name of project>
```

For example, if I would like to run the debug server for a server running in
your `my_project` project, run:

```sh
./apps/expert/bin/debug_server.sh my_project
```

...and you will be connected to a remote IEx session _inside_ the language
server for `my_project`. This allows you to investigate processes, make changes
to the running code, or run `:observer`.
