# Server dependency compilation check

This is a dependency-only compatibility check, not a server scaffold, test of
messaging, or acceptance of the candidate stack. It has no application functions,
network listener, database schema, secrets or deployment command. There is no
behavioral implementation to subject to RED/GREEN testing.

```sh
cargo check --locked --manifest-path spikes/003-server-dependency-check/Cargo.toml
```

The lockfile records the exact transitive graph. The server-only dependencies
must not be linked into the future shared mobile crypto core. Neither Android
nor iOS portability is demonstrated by compiling this Linux dependency graph.

See the [bounded evidence](../../docs/research/2026-09-08-server-stack-check.md).
