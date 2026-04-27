# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0-alpha.0] - 2026-04-26

### Changed

- Hard-break the `0.1.x` storage format with versioned envelopes for
  checkpoints, thread metadata, and thread entries.
- Tighten runtime dependencies to the Jido 2.2 and Splode 0.3 lines.
- Resolve the Bedrock fallback dependency from `bedrock-kv/bedrock` on GitHub
  `main` because the latest Hex release, `0.5.0`, is missing persisted
  single-node restart recovery fixes.
- Run real single-node Bedrock integration tests in the default test suite.

### Added

- `Jido.Bedrock.Memory.Store`, a Bedrock-backed `Jido.Memory.Store` adapter for
  `agentjido/jido_memory`'s basic provider and plugin path.
- Durable memory record indexes for namespace/time, class/time, tags, and
  expiration pruning.
- Storage option validation for repo, prefix, expected revision, and metadata.
- Stored thread invariant validation for metadata, entry shape, contiguous
  sequence numbers, and revision agreement.
- Splode-backed config, validation, execution, and internal errors for
  non-sentinel storage failures.
- Telemetry events for checkpoint and thread operations, conflicts, corruption,
  memory store operations, and raised exceptions.

## [0.1.0] - 2026-02-22

### Added

- Initial `jido_bedrock` package structure.
- `Jido.Bedrock.Storage` adapter implementing `Jido.Storage`.
- QA-aligned package metadata, docs, and CI/release workflows.
