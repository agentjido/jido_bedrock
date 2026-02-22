# Jido Bedrock Agent Guide

## Commands

- `mix setup` - install dependencies and git hooks
- `mix test` - run test suite
- `mix coveralls` - run tests with coverage checks
- `mix quality` - run formatter, compile, credo, dialyzer, doctor
- `mix docs` - build docs

## Standards

- Target Elixir `~> 1.18`.
- Add `@moduledoc` for public modules.
- Add `@doc` and `@spec` for public functions.
- Prefer tagged tuple returns (`{:ok, value}` / `{:error, reason}`).
- Keep adapter behavior deterministic and testable.

## Testing

- Unit tests should mirror `lib/` structure.
- Include transactional conflict checks and durability semantics.

## Commit Style

Use Conventional Commits, for example:

- `feat(storage): add bedrock-backed append_thread implementation`
- `fix(storage): normalize rollback conflict handling`
- `test(storage): add expected_rev conflict coverage`
