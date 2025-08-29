# Expert

Expert is the official language server implementation for the Elixir programming language.

## Installation

You can download Expert from the [releases page](https://github.com/elixir-lang/expert/releases) for your
operating system and architecture. Put the executable somewhere on your `$PATH`, like `~/.local/bin/expert`

For editor specific installation instructions, please refer to the [Installation Instructions](pages/installation.md)

### Nightly Builds

If you want to try out the latest features, you can download a nightly build.

Using the GH CLI, you can run the following command to download the latest nightly build:

```shell
gh release download nightly --pattern 'expert_linux_amd64' --repo elixir-lang/expert
```

Then point your editor to the downloaded binary.

### Building from source

To build Expert from source, you need Zig `0.14.1` installed on your system.

Then you can run the following command or follow the instructions in the [Installation Instructions](pages/installation.md):

```sh
just release-local
```

This will build the Expert binary and place it in the `apps/expert/burrito_out` directory. You can then point your
editor to this binary.

## Sponsorship

Thank you to our corporate sponsors! If you'd like to start sponsoring the project, please read more below.

<div>
  <img height="100" src="./assets/sponsors/fly.png">
</div>
<div>
  <img height="100" src="./assets/sponsors/tauspace.png">
</div>
<div>
  <img height="100" src="./assets/sponsors/river.png">
</div>

### Corporate

For companies wanting to directly sponsor full time work on Expert, please reach out to Dan Janowski: EEF Chair of Sponsorship WG at danj@erlef.org.

### Individual

Individuals can donate using GitHub sponsors. Team members are listed in the sidebar.

## Other resources

- [Architecture](pages/architecture.md)
- [Development Guide](pages/development.md)
- [Glossary](pages/glossary.md)
- [Installation Instructions](pages/installation.md)

## LICENSE

Expert source code is released under Apache License 2.0.

Check LICENSE file for more information.
