# Configuration

Expert supports the following configuration options.

## Settings Schema

```json
{
  "workspaceSymbols": {
    "minQueryLength": 2
  },
  "logLevel": "info",
  "fileLogLevel": "info",
  "elixirSourcePath": "/path/to/elixir/source",
  "elixirExecutablePath": "/absolute/path/to/elixir",
  "erlangExecutablePath": "/absolute/path/to/erl"
}
```

## Available Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `workspaceSymbols.minQueryLength` | integer | `2` | Minimum characters required before workspace symbol search returns results. Set to `0` to return all symbols with an empty query. |
| `logLevel` | string | `"info"` | Minimum severity of log messages forwarded to the editor. Valid values: `"error"`, `"warning"`, `"info"`, `"log"`. |
| `fileLogLevel` | string | `"debug"` | Minimum severity of log messages written to the log file (`.expert/expert.log`). Valid values: `"debug"`, `"info"`, `"warning"`, `"error"`, `null`. Sending `null` resets log level to default. |
| `elixirSourcePath` | string | `null` | Path to a local Elixir source directory. When set, go-to-definition on Elixir standard library modules will navigate to source files in this directory instead of returning no result. Should be an absolute path. |
| `elixirExecutablePath` | string | `null` | Path to the Elixir executable Expert should use for building and running project engines. Sending `null` clears the override. Expert uses the path as provided and does not validate it. |
| `erlangExecutablePath` | string | `null` | Path to the Erlang `erl` executable Expert should use when resolving the project Erlang runtime. Sending `null` clears the override. Expert uses the path as provided and does not validate it. |
