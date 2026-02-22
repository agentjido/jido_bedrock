# Jido Bedrock

`jido_bedrock` provides Bedrock-backed persistence adapters for Jido runtimes.

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

## License

Apache-2.0
