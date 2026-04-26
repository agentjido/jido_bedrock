# Getting Started with Jido Bedrock

`jido_bedrock` provides Bedrock-backed adapters for durable Jido checkpoints,
thread journals, and optional `jido_memory` records.

## 1. Add dependency

```elixir
def deps do
  [
    {:jido_bedrock, "~> 0.2.0-alpha"}
  ]
end
```

Version `0.2.0-alpha.0` does not read data written by `0.1.x`. Clear/reseed
old Bedrock data or run a one-off migration before upgrading an existing
environment.

## 2. Configure a Bedrock repo

Define a repo module backed by your Bedrock cluster:

```elixir
defmodule MyApp.BedrockRepo do
  use Bedrock.Repo, cluster: MyApp.BedrockCluster
end
```

## 3. Use as Jido storage

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    storage: {Jido.Bedrock.Storage, repo: MyApp.BedrockRepo}
end
```

## 4. Optional key prefix

```elixir
storage: {Jido.Bedrock.Storage, repo: MyApp.BedrockRepo, prefix: "my_app/jido/"}
```

Prefixes must be non-empty binaries ending in `/`.

## 5. Optional Jido.Memory store

When an agent uses `agentjido/jido_memory`, configure its basic memory plugin
with `Jido.Bedrock.Memory.Store`:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support_agent",
    default_plugins: %{
      __memory__:
        {Jido.Memory.BasicPlugin,
         %{
           store: {Jido.Bedrock.Memory.Store, repo: MyApp.BedrockRepo, prefix: "my_app/jido/"},
           namespace_mode: :per_agent
         }}
    }
end
```

The memory store uses the same `:repo` and `:prefix` rules as
`Jido.Bedrock.Storage`. It also accepts `:ttl` as a positive millisecond value.

## 6. Error and telemetry behavior

`Jido.Bedrock.Storage` keeps Jido's storage sentinels: missing values return
`:not_found`, and optimistic concurrency conflicts return `{:error, :conflict}`.
Other failures return Splode-backed exceptions from `Jido.Bedrock.Error`.

Telemetry events are emitted under `[:jido_bedrock, :storage, operation, event]`
for checkpoint, thread, and memory store operations.
