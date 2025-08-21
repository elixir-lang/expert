# Development

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

## Development server

To start a development server with an interactive shell, you can run the
following command:

```sh
just start
```

This will launch an IEx session, and it will start Expert listening
in the TCP port `9000`.

You will need to configure your editor to connect to the Expert LSP
via TCP at that port. After that, opening you project in your editor
will connect it to the running dev server, and it will terminate it
when you close the editor.

In this dev server you can run `:observer.start()`, and call any
function from Expert to inspect the state of the server, or run
arbitrary code.

Since Expert needs namespacing to work, modules from the `forge`
application will be namespaced as `XPForge`; the same applies for
any module that is shared between the `expert` and `engine`
applications.

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
