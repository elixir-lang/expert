# Expert

Expert is a next-generation language server for the Elixir programming language.

## Installation

You can download Expert from the [releases page](https://github.com/elixir-lang/expert/releases) for your
operating system and architecture.

For editor specific installation instructions, please refer to the [Installation Instructions](pages/installation.md)

### Nightly Builds

If you want to try out the latest features, you can download a nightly build.

Using the GH CLI, you can run the following command to download the latest nightly build:

```shell
gh release download nightly --pattern 'expert_linux_amd64'
```

Then point your editor to the downloaded binary.

### Building from source

To build Expert from source, you need Zig `1.14.1` installed on your system.

Then you can run the following command:

```sh
just release-local
```

This will build the Expert binary and place it in the `apps/expert/burrito_out` directory. You can then point your
editor to this binary.

### Other resources

- [Architecture](pages/architecture.md)
- [Development Guide](pages/development.md)
- [Glossary](pages/glossary.md)
- [Installation Instructions](pages/installation.md)
