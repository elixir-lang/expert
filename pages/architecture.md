# Architecture

## Project Structure

Expert is designed to keep your application isolated from Expert's code. Because of this, Expert is structured as a poncho app, with the following sub-apps:

- `forge`: Contains all code common to the other applications.
- `engine`: The application that's injected into a project's code, which
  gives expert an API to do things in the context of your app.
- `expert` The language server itself.

## Overview

In order to provide accurate completions, diagnostics and other features, Expert needs to analyze your code. Due to Elixir's metaprogramming capabilities, just analyzing the source code is not enough. We need to compile your project first to allow Elixir to expand macros and perform other compile-time transformations, and then analyze the compiled code.

Loading the project code alongside the code Expert needs to run itself presents several issues:
- Version conflicts: If Expert depends on a different version of a library than the project, it can cause conflicts that lead to crashes or incorrect behavior.
- Expert modules and your project modules become indistinguishable, which can lead to Expert specific code showing up in completions.
- We need to build Expert for each version of Elixir and Erlang/OTP that we want to support, which is a maintenance burden. Editor integrations can download the expert source and compile it on the fly for each particular project, but the rest of the problems still remain.

To deal with these issues, Expert is split into two main components:
- The server or "manager" node, which handles the LSP communication and manages the lifecycle of the language server.
- The proejct or "engine" node, which is built on the fly for each project and is responsible for tasks that require compiling and analyzing the project code.

### Namespacing
That solves version conflicts, but we still have the problem of Engine modules showing up in completions. To solve this, Expert performs "namespacing" on expert's and the engine code.

At a high level, namespacing takes the compiled beam files of the engine and expert applications, and adds a prefix like `XP` or `xp_` to all module names and atoms referencing applications.

Then whenever we provide completions, we filter out any modules that start with the prefix, hiding the engine and expert modules from the user.

Despite completions happening on the engine node, the expert code is also namespacing. This is to ensure there's no mismatch for the shared datastructures in the `Forge` application. For example, the `Expert.Configuration` struct is used both in the engine and expert code, so it needs to be namespaced to ensure that the engine node can read the configuration sent by the expert node.

## Language Server

The language server (the `expert` app) is the entry point to Expert. When started, it sets up a transport via [GenLSP](https://github.com/elixir-tools/gen_lsp) that reads JsonRPC and responds to it. The default transport is Standard IO, but it can be configured to use TCP.

When a message is received, it is parsed into either a LSP Request or a LSP Notification and then it's handed to the [language server](https://github.com/elixir-lang/expert/blob/main/apps/expert/lib/expert.ex) to process.

The only messages the Expert server process handles directly are those related to the lifecycle of the language server itself:

- Synchronizing document states.
- Processing LSP configuration changes.
- Performing initialization and shutdown.

All other messages are delegated to a _Provider Handler_. A _Provider Handler_ is a module that defines a function of arity 2 that takes the request to handle and a `%Expert.Configuration{}`. These functions can reply to the request, ignore it, or do some other action.

### GenLSP

GenLSP is a library that provides a generic interface to implement LSP servers in Elixir. It defines all the data structures needed for the protocol, and handles the entirety of the transport layer.

## Project Versions

Expert releases are built on a specific version of Elixir and Erlang/OTP(specified at `.github/workflows/release.yml`). However, the project that Expert is being used in may be on a different version of Elixir and Erlang/OTP. This can lead to incompatibilities - one particular example is that the `quote` special form may call internal functions in elixir that are not present in the version of Elixir that Expert is built on and viceversa, leading to crashes.

For this reason, Expert compiles the `engine` application on the version of Elixir and Erlang/OTP that the project is using. At a high level the process is as follows:

1. Find the project's elixir executable, and spawn a vm with it that compiles the `engine` application.
2. Namespace the compiled `engine` app, return the path to the compiled `engine` to the `expert` manager node, and exit.
3. Gather the paths to the compiled `engine` app files, spawn a new vm with the project's elixir executable, and load the `engine` app into that vm.

We use two separate vms(one for compilation, one for actually running the `engine` app) to ensure that the engine node is not polluted by any engine code that might have been loaded during compilation. We currently use `Mix.install` to compile the `engine` app, which loads the `engine` code into the compilation vm. Spawning a new vm for the engine node ensures that the engine node is clean.

The compiled `engine` application will be stored in the user's "user data" directory - `~/.local/share/Expert/` on linux, `~/Library/Application Support/Expert/` on macOS, and `%appdata%/Expert` on Windows.

## Code analysis

Expert performs analysis of your code at two main levels:

- Parsing and indexing of the source code. This is done by the "indexer" component of the `engine` app. It will walk all the source files in your project and its dependencies, and extract all the relevant information about modules, functions, macros, structs, types, etc. This information is cached in an index file, and is loaded into memory to power features such as Workspace Symbols and Go to Definition.

- Analysis of code after compilation. This is done via [ElixirSense](https://github.com/elixir-lsp/elixir_sense). This powers features like completions, and generally acts as a fallback when the indexer is not able to provide an answer.


## Other relevant tools

- Parsing of source code is done via [Spitfire](https://github.com/elixir-tools/spitfire), an Elixir parser capable of recovering from syntax errors. Spitfire is also able to provide some environmental information about the code, like scopes or modules defined, which can be used to provide contextual information without having to compile the code. The fault tolerance of Spitfire allows us to provide features like Document Outline even in the prsence of syntax errors, which is not possible with the standard Elixir parser.

- Manipulation of AST and extraction of range information is done via [Sourceror](https://github.com/doorgan/sourceror). This tool provides utilities to manipulate Elixir AST while preserving formatting and comments, and is usually a main component of Code Action implementations.
