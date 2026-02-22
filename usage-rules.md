# Usage Rules for LLM Agents

- Keep public APIs stable and document breaking changes.
- Prefer explicit error tuples over silent failures.
- Preserve deterministic key derivation and transactional semantics.
- Add tests for conflict behavior (`expected_rev`) and rollback paths.
- Do not introduce implicit global configuration; prefer explicit options.
