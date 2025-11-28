# Glossary
This project uses a considerable amount of jargon, some adopted from the Language Server Protocol and some specific to Expert.

This glossary attempts to define jargon used in this codebase.
Though it is not exhaustive, we hope it helps contributors more easily navigate and understand existing code and the goal, and that it provides some guidance for naming new things.

**You can help!** If you run across a new term while working on Expert and you think it should be defined here, please [open an issue](https://github.com/elixir-lang/expert/issues) suggesting it!

## Language Server Protocol (LSP)

This section covers features, names, and abstractions used by Expert that have a correspondence to the Language Server Protocol. For a definitive reference, see the [LSP Specification](https://microsoft.github.io/language-server-protocol/specifications/specification-current).

### Messages, Requests, Responses, and Notifications

LSP defines a general hierarchy of the types of messages language servers and clients and may exchange, and the expected behaviours associated with them.

There's 3 top-level types of messages: [Requests](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#requestMessage), [Responses](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage), and [Notifications](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#notificationMessage):

- [Requests](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#requestMessage) are sent from client to server and vice versa, and must always be answered with a [Response](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage).

- [Notifications](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#notificationMessage) are likewise bi-directional and work like events. They expressly do not receive responses per LSP's specification.

From these 3 top-level types, LSP defines more specific more concrete, actionable messages such as:
- [Completion Requests](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion)
- [Goto Definition Requests](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_definition)
- [WillSaveTextDocument Notifications](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_willSave)

... and many more. These can serve as good reference for the specific features you're working on.

Expert uses [GenLSP](https://github.com/elixir-tools/gen_lsp) to implement the LSP protocol, which defines all the 
necessary messages.

Finally, it's worth noting all messages are JSON, specifically [JSON-RPC version 2.0](https://www.jsonrpc.org/specification).

### Document(s)

A single file identified by a URI and contains textual content. Formally referred to as [Text Documents](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocuments) in LSP and modeled as `Expert.Document` structs in Expert.

### Diagnostics

Represents a diagnostic, such as a compiler error or warning. Diagnostic objects are only valid in the scope of a resource.

### Completions and Code Intelligence

Auto-completion suggestions that appear in an editor's IntelliSense. For example, a user that's typed `IO.in|` may be suggested `IO.inspect(|)` as one of a few possible completions.

### Code Actions

A code action represents a change that can be performed in code. In VSCode they typically appear as "quick fixes" next to an error or warning, but they aren't exclusive to that. In fact, VSCode frequently requests available code actions while users are browsing and editing code.

LSP defines a protocol for language servers to tell clients what actions they're capable of performing, and for clients to request those actions be taken. See for example LSP's [CodeActionClientCapabilities interface](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionClientCapabilities).

## Concepts exclusive to Expert

This section briefly summarizes abstractions introduced by Expert. Detailed information can be found in the respective moduledocs.

### The Project struct

An Elixir struct that represents the current state of an elixir project. See `Expert.Project`.

### The Project node

When you open an elixir project in Expert, it starts a new Elixir node that runs the `engine` application. This node is called the _Project node_ and it is isolated from the Expert node. The Project node is responsible for compiling the project's code, to gather code intelligence information with ElixirSense, and providing an API for the language server to interact with the project.

The logs for these nodes are stored in the `.expert/project.log` file in the root of the project.

### The Convertible protocol

Some LSP data structures cannot be trivially converted to Elixir terms.

The `Expert.Convertible` protocol helps centralize the necessary conversion logic where this is the case.

### The Translatable protocol and Translation modules

The `Expert.Completion.Translatable` protocol specifies how Elixir language constructs (such as behaviour callbacks) are converted into LSP constructs (such as [completion items](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItem)).

See `Expert.CodeIntelligence.Completion.Translations` for various implementations.

### Code Mods

A variety of modules that change existing code in some way. They take a document, modify it, and return diffs.

Examples of code mods include:
 * Formatting code in a file (`> Format Document`/`shift`+`alt`+`f` in VSCode).
 * Prefixing unused variables with an `_`.

Code mods are defined in the `engine` sub-app and are executed in the project's virtual machine.
