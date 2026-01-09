# Configuration

Expert supports the following configuration options.

## Settings Schema

```json
{
  "workspaceSymbols": {
    "minQueryLength": 2
  }
}
```

## Available Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `workspaceSymbols.minQueryLength` | integer | `2` | Minimum characters required before workspace symbol search returns results. Set to `0` to return all symbols with an empty query. |
