# Jido Bedrock

`jido_bedrock` provides Bedrock-backed persistence adapters for Jido runtimes.

## Alpha Status

`jido_bedrock` is still alpha-quality and is being published to preserve active
work, not as a production-ready package.

- Do not rely on this code for production systems yet.
- The persistence and recovery stack is still being actively stabilized.
- The upstream Bedrock fixes this project depends on have landed on `main`, but
  they are not yet available in a newer Hex release beyond `0.5.0`.
- For local development and integration verification, point `BEDROCK_PATH` at a
  Bedrock checkout on upstream `main`. In `:dev` and `:test`, `jido_bedrock`
  resolves Bedrock in this order: `BEDROCK_PATH`, then a sibling `../bedrock`
  checkout if present, then Hex `0.5.0`.
- Expect rough edges and breaking changes while the adapter and Bedrock runtime
  keep maturing together.

## Features

- `Jido.Bedrock.Storage` implementing `Jido.Storage`
- Durable checkpoints and thread journals via `Bedrock.Repo`
- Optimistic concurrency using `expected_rev` for thread appends

## Installation

Add `jido_bedrock` to your dependencies:

```elixir
def deps do
  [
    {:jido_bedrock, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Installation via Igniter

`jido_bedrock` v0.1.0 does not yet provide an Igniter installer module.

## Quick Start

Define a Bedrock repo:

```elixir
defmodule MyApp.BedrockRepo do
  use Bedrock.Repo, cluster: MyApp.BedrockCluster
end
```

Use the storage adapter in a Jido instance:

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    storage: {Jido.Bedrock.Storage, repo: MyApp.BedrockRepo}
end
```

## Development

```bash
mix setup
mix quality
mix test
```

To verify against a local Bedrock checkout on upstream `main`:

```bash
BEDROCK_PATH=/path/to/bedrock mix test
```

## License

Apache-2.0
