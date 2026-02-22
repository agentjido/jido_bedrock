# Getting Started with Jido Bedrock

`jido_bedrock` provides a Bedrock-backed `Jido.Storage` adapter for durable agent checkpoints and thread journals.

## 1. Add dependency

```elixir
def deps do
  [
    {:jido_bedrock, "~> 0.1.0"}
  ]
end
```

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
