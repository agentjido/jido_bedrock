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
  checkout if present, then `bedrock-kv/bedrock` on GitHub `main`.
- Version `0.2.0-alpha.0` hard-breaks the `0.1.x` storage format. Existing
  raw-term data written by `0.1.x` is not readable by `0.2`; clear/reseed that
  data or run a one-off migration before upgrading.
- Expect rough edges and breaking changes while the adapter and Bedrock runtime
  keep maturing together.

## Features

- `Jido.Bedrock.Storage` implementing `Jido.Storage`
- `Jido.Bedrock.Memory.Store` implementing `Jido.Memory.Store` when `jido_memory`
  is installed
- Durable checkpoints and thread journals via `Bedrock.Repo`
- Durable basic memory records for `Jido.Memory.BasicPlugin`
- Optimistic concurrency using `expected_rev` for thread appends
- Versioned storage envelopes with corruption and invariant checks
- Splode-backed error structs for config, validation, execution, and internal failures
- Telemetry events for storage operations

## Installation

Add `jido_bedrock` to your dependencies:

```elixir
def deps do
  [
    {:jido_bedrock, "~> 0.2.0-alpha"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Installation via Igniter

`jido_bedrock` v0.2.0-alpha.0 does not yet provide an Igniter installer module.

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

Storage prefixes must be non-empty binaries ending in `/`:

```elixir
storage: {Jido.Bedrock.Storage, repo: MyApp.BedrockRepo, prefix: "my_app/jido/"}
```

## Jido.Memory Store

`jido_bedrock` also exposes `Jido.Bedrock.Memory.Store` for the
`agentjido/jido_memory` package. Because `jido_memory` is not currently a Hex
package, add it separately when you want Bedrock-backed agent memory:

```elixir
def deps do
  [
    {:jido_bedrock, "~> 0.2.0-alpha"},
    {:jido_memory, github: "agentjido/jido_memory", branch: "main"}
  ]
end
```

Then configure `Jido.Memory.BasicPlugin` with the Bedrock store:

```elixir
defmodule MyApp.SupportAgent do
  use Jido.Agent,
    name: "support_agent",
    default_plugins: %{
      __memory__:
        {Jido.Memory.BasicPlugin,
         %{
           store: {Jido.Bedrock.Memory.Store, repo: MyApp.BedrockRepo, prefix: "my_app/jido/"},
           namespace_mode: :per_agent,
           auto_capture: true
         }}
    }
end
```

The memory store supports `put/get/delete/query/prune_expired`, structured
queries by namespace, class, kind, tag, time range, and text substring, plus an
optional store-level `:ttl` in milliseconds.

## Storage Format

`0.2.0-alpha.0` stores all values as versioned Erlang-term envelopes:

| Data | Key | Envelope |
| --- | --- | --- |
| Checkpoint | `<prefix>checkpoints/<encoded-key>` | `%{version: 1, type: :checkpoint, data: checkpoint}` |
| Thread metadata | `<prefix>threads/<encoded-thread-id>/meta` | `%{version: 1, type: :thread_meta, data: meta}` |
| Thread entry | `<prefix>threads/<encoded-thread-id>/entries/<64-bit-seq>` | `%{version: 1, type: :thread_entry, data: entry}` |
| Memory record | `<prefix>memory/records/<encoded-namespace>/<encoded-id>` | `%{version: 1, type: :memory_record, data: record}` |
| Memory metadata | `<prefix>memory/meta/<encoded-namespace>/<encoded-id>` | `%{version: 1, type: :memory_meta, data: meta}` |
| Memory index | `<prefix>memory/indexes/...` | `%{version: 1, type: :memory_index, data: %{namespace: ns, id: id}}` |

Thread loads validate envelope version/type, metadata shape, entry structs,
contiguous entry sequence numbers, and agreement between metadata `rev` and
stored entries.

Memory reads and queries validate envelope version/type, canonical
`Jido.Memory.Record` structs, index metadata, and index pointer shape. Legacy
raw memory terms are not accepted.

## Error Semantics

The adapter preserves `Jido.Storage` control-flow sentinels:

- Missing checkpoints and empty/missing threads return `:not_found`.
- Expected-revision conflicts return `{:error, :conflict}`.

Other failures return Splode-backed exceptions from `Jido.Bedrock.Error`, such as
`Jido.Bedrock.Error.ConfigError`, `InvalidInputError`,
`ExecutionFailureError`, or `InternalError`.

For `Jido.Bedrock.Memory.Store`, missing records return `:not_found`, queries
without a namespace return `{:error, :namespace_required}`, and non-contract
failures use the same Splode-backed error structs.

## Telemetry

Storage operations emit telemetry events under
`[:jido_bedrock, :storage, operation, event]`, where operation is one of
`:checkpoint_get`, `:checkpoint_put`, `:checkpoint_delete`, `:thread_load`,
`:thread_append`, `:thread_delete`, `:memory_ensure_ready`, `:memory_put`,
`:memory_get`, `:memory_delete`, `:memory_query`, or
`:memory_prune_expired`.

The adapter emits `:start` and `:stop` events for operations, `:exception` for
raised failures, `[:jido_bedrock, :storage, :thread_append, :conflict]` for
optimistic concurrency conflicts, and
`[:jido_bedrock, :storage, :thread_load, :corruption]` for detected thread
invariant failures.

## Development

```bash
mix setup
mix quality
mix test
```

`mix test` includes the single-node real Bedrock integration suite. To verify
against a specific local Bedrock checkout on upstream `main`:

```bash
BEDROCK_PATH=/path/to/bedrock mix test
```

To verify against a local `jido_memory` checkout:

```bash
JIDO_MEMORY_PATH=/path/to/jido_memory mix test
```

## License

Apache-2.0
