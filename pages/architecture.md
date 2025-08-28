# Architecture

## Project Structure

Expert is designed to keep your application isolated from Expert's code. Because of this, Expert is structured as an umbrella app, with the following sub-apps:

- `forge`: Contains all code common to the other applications.
- `engine`: The application that's injected into a project's code, which
  gives expert an API to do things in the context of your app.
- `expert` The language server itself.

By separating expert into sub-applications, each is built as a separate archive, and we can pick and choose which of these applications (and their dependencies) are injected into the project's VM, thus reducing how much contamination the project sees. If Expert was a standard application, adding dependencies to Expert would cause those dependencies to appear in the project's VM, which might cause build issues, version conflicts in mix or other inconsistencies.

Since the `engine` app only depends on `forge`, `path_glob` and `elixir_sense`, only those applications pollute the project's vm. Keeping `engine`'s dependencies to a minimum is a design goal of this architecture.

## Language Server

The language server (the `expert` app) is the entry point to Expert. When started, it sets up a transport via GenLSP that reads JsonRPC and responds to it. The default transport is Standard IO, but it can be configured to use TCP.

When a message is received, it is parsed into either a LSP Request or a LSP Notification and then it's handed to the [language server](https://github.com/elixir-lang/expert/blob/main/apps/expert/lib/expert.ex) to process.

The only messages the Expert server process handles directly are those related to the lifecycle of the language server itself:

- Synchronizing document states.
- Processing LSP configuration changes.
- Performing initialization and shutdown.

All other messages are delegated to a _Provider Handler_. A _Provider Handler_ is a module that defines a function of arity 2 that takes the request to handle and a `%Expert.Configuration{}`. These functions can reply to the request, ignore it, or do some other action.

## Project Versions

Expert releases are built on a specific version of Elixir and Erlang/OTP(specified at `.github/workflows/release.yml`). However, the project that Expert is being used in may be on a different version of Elixir and Erlang/OTP. This can lead to incompatibilities - one particular example is that the `quote` special form may call internal functions in elixir that are not present in the version of Elixir that Expert is built on and viceversa, leading to crashes.

For this reason, Expert compiles the `engine` application on the version of Elixir and Erlang/OTP that the project is using. At a high level the process is as follows:

1. Find the project's elixir executable, and spawn a vm with it that compiles the `engine` application.
2. Namespace the compiled `engine` app, return the path to the compiled `engine` to the `expert` manager node, and exit.
3. Gather the paths to the compiled `engine` app files, spawn a new vm with the project's elixir executable, and load the `engine` app into that vm.

We use two separate vms(one for compilation, one for actually running the `engine` app) to ensure that the engine node is not polluted by any engine code that might have been loaded during compilation. We currently use `Mix.install` to compile the `engine` app, which loads the `engine` code into the compilation vm. Spawning a new vm for the engine node ensures that the engine node is clean.

The compiled `engine` application will be stored in the user's "user data" directory - `~/.local/share/Expert/` on linux, `~/Library/Application Support/Expert/` on macOS, and `%appdata%/Expert` on Windows.
