# Development

## Getting Started

First follow the [installation instructions](installation.md) to install the
required prerequisites.

To build Expert, run:

```sh
MIX_ENV=dev just release-local
```

>[!IMPORTANT]
> We set `MIX_ENV=dev` to disable Burrito's caching mechanisms. This provides a
> smoother development experience but expect server load times to be slightly
> longer.

You may point your editor's LSP configuration to path provided by Burrito, eg:

```sh
<your-repo>/apps/expert/burrito_out/expert_linux_amd64
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
