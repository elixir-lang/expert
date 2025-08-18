# Architecture

## Project Structure

Expert is designed to keep your application isolated from Expert's code. Because of this, Expert is structured as an umbrella app, with the following sub-apps:

  * `forge`: Contains all code common to the other applications.
  * `engine`: The application that's injected into a project's code, which
     gives expert an API to do things in the context of your app.
  * `expert` The language server itself.

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
