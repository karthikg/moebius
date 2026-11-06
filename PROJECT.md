# Moebius: Project Brief

## What it is

A pipe-first query library for Elixir and PostgreSQL. It's about 3,400 lines in `lib/` (docs included), MIT-licensed, and v5.0.1 is on Hex. It is **not an ORM**: no schemas, no migrations, no structs for your data. Builders produce SQL plus parameters, a database module runs them, and results come back as plain maps.

- **Origin:** a 2015 port of MassiveJS by Rob Conery (maintainers: Rob Conery, Chase Pursley).
- **History:** most commits are from 2015–2017. A 4.x refresh landed in 2024, and the 5.0 rewrite of the driver layer in Sept–Oct 2026.
- **This checkout:** `karthikg/moebius`, a fork of `robconery/moebius`; the default branch is `master`.

Two ways to query:

| | Module | Struct | Stores |
|---|---|---|---|
| Relational | `Moebius.Query` | `%QueryCommand{}` | ordinary tables |
| Documents | `Moebius.DocumentQuery` | `%DocumentCommand{}` | maps in a `jsonb` `body` column; table + GIN indexes created on first save; optional `tsvector` search column |

Postgres features exposed directly: JSONB, full-text search, binary `COPY` (`copy/3`), cursor streams (`stream/2`), savepoint-nested transactions, `EXPLAIN` (`explain/2`), SQL files (`sql_file`) and stored functions (`function`).

## How it works

```
db(:users)                          %QueryCommand{table_name: "users"}
  |> filter / sort / limit / join   fill where / order / params  (pure; no I/O)
  |> insert / update / delete       write cmd.sql, set cmd.type
  |> MyDb.run | first | find        select() builds SQL if none yet
     → Moebius.Database.execute
     → Moebius.Pool.checkout        pooler; connection pinned to the process while held
     → Moebius.Connection.query     epgsql parse → Moebius.Params.check → bind + execute
     → Moebius.Transformer          %Moebius.Result{} → maps (to_list / to_single / from_json)
```

- **`use Moebius.Database`** (`lib/moebius/database.ex`) turns a module into a database with its own pool, which you start as one child in *your* supervision tree. It adds `run/first/find/save/transaction/rollback/stream/explain/copy/run_batch/transact_batch/pool_status/create_document_table`. `Moebius.Db` is the built-in one; tests use `TestDb`.
- **Safety:**
  - Every table/column/function/file name goes through `Moebius.Identifier`, and every value is a `$n` parameter.
  - `Params.check` validates each value against the type Postgres parsed, because a bad value crashes an epgsql connection process.
- **Transactions:** `MyDb.transaction(fn tx -> ... end)`. Nested calls become savepoints. A failed statement rolls back and returns `{:error, message}`; other exceptions roll back and re-raise.
- **Types:** `lib/moebius/codec/` handles date/time/timestamp(tz) as Elixir structs (exact µs), numeric as `Decimal`, and JSON via Jason.
- **Config:** `config :moebius, connection: [url: ... | host:, database:, ...]`, read by `Moebius.get_connection/0`. Explicit options win over the parts of a url.
- **Mix tasks:** `moebius.create|drop|migrate|seed` (aliases `moebius.setup`, `moebius.reset`) run through `Moebius.run_script/2`, so no `psql` is needed. migrate/seed are test-env only.

### Layout

| Path | Holds |
|---|---|
| `lib/moebius.ex` | `Moebius` (connection config, `run_script`), `Moebius.Db` |
| `lib/moebius/query.ex`, `query_filter.ex` | relational builders, where clauses |
| `lib/moebius/document_query.ex` | JSONB builders |
| `lib/moebius/database.ex` | the `use` macro, `execute` |
| `lib/moebius/pool.ex`, `connection.ex`, `params.ex`, `copy.ex`, `codec/` | driver layer |
| `lib/moebius/identifier.ex`, `transformer.ex` | name checks, result → maps |
| `lib/mix/tasks/` | mix tasks |
| `test/moebius/` (25 files, 268 tests + 9 doctests), `test/db/*.sql`, `test/support/` | tests, schema/seeds, `TestDb` |
| `.codemap/` | MAP / symbols / recipes / glossary; read `MAP.md` first |
| `.claude/` | project skills (postgres-sql, erlang-otp, elixir-testing, FTS), `elixir-reviewer` agent, git commands, format hook |

## Current state (2026-11-05)

| Check | State |
|---|---|
| Version | `5.0.1` in `mix.exs` and on Hex. `CHANGELOG.md` "Unreleased" has `ignore_conflict` (feature) and the `search` + sort/limit/offset fix |
| Driver | epgsql 4.8.0 + pooler 1.7.0 (both stable, no deps); Postgrex removed in 5.0 |
| Deps | ✅ all current (2026-11-05: decimal 3.1.1 → 3.2.0, sobelow 0.15.0 → 0.18.1; lock-only, within existing `~>` ranges) |
| Security | ✅ `mix hex.audit` clean. CVE-2026-97853 (MEDIUM, DoS via `Decimal.round/3`, fixed in decimal 3.1.2) is fixed in our lock by decimal 3.2.0. Moebius never calls `Decimal.round`. A library's lock doesn't reach users, but `{:decimal, "~> 3.0"}` still lets an app keep 3.1.1 in *its* lock. (The 3 Postgrex-era CVEs are closed.) |
| Pinned toolchain | `.tool-versions`: Erlang 29.0.5 / Elixir 1.20.4; CI uses the same file |
| Local loop | ✅ Phase 3 done 2026-11-05: Postgres 17.11 (brew service), pinned toolchain via mise. **277 passed** (268 tests + 9 doctests) on both 1.20.4/OTP 29 and 1.18.4/OTP 27; `compile --warnings-as-errors` and `mix quality --strict` clean |
| Git | **no tags** (`v5.0.0`/`v5.0.1` missing; ExDoc `source_ref: "v#{@version}"` links break); no CI runs visible on the fork |
| Links | `mix.exs` `source_url`/`links` and the README badges point at `robconery/moebius`, not the fork |

## Upgrade plan

**Done:**
- **Phase 1:** builds on current tooling (see `plan.md`).
- **Phase 2:** Postgrex → epgsql + pooler, defect fixes, tests 104 → 209 (see `plan.md`, `CHANGELOG.md`).

**Phase 3: working local loop** ✅ Done 2026-11-05
1. `brew install mise postgresql@17`; `mise install` (prebuilt Erlang 29.0.5 + Elixir 1.20.4, ~15s); `mise exec -- mix local.hex --force && mise exec -- mix local.rebar --force`.
2. `brew services start postgresql@17` (starts at login); `create role postgres login superuser password 'postgres'`; `MIX_ENV=test mix moebius.create`.
3. Baseline: 277 passed, compile/quality clean. Run with `mise exec -- mix ...`, or add `eval "$(mise activate zsh)"` to `~/.zshrc` so `.tool-versions` applies automatically.

**Phase 4: housekeeping**

4. ✅ Deps: `mix deps.update decimal sobelow` done 2026-11-05 (audit clean, 277 passed over 4 seeds, quality clean; sobelow 0.18 added no findings). Open: raising the requirement to `{:decimal, "~> 3.1 and >= 3.1.2"}` would stop apps resolving the vulnerable version; that changes `mix.exs`, so decide before 5.1.0.
5. Decide whose repo this is. If the fork is the home, point `source_url`, `links` and the README badges at `karthikg/moebius`; if not, upstream the work to `robconery/moebius`.
6. CI: confirm Actions are enabled on the fork, push, and check the workflow (`.github/workflows/elixir.yml`) passes on the pinned toolchain.
7. Tags: tag `v5.0.1` at `08395c0`, and `v5.0.0` at `e0c3446` (the last commit before the 5.0.1 bump; check it against the Hex tarball first), so doc source links resolve.

**Phase 5: release 5.1.0**

8. Move "Unreleased" in `CHANGELOG.md` to `5.1.0` (minor: `ignore_conflict` is new API), bump `@version`, tag `v5.1.0`, `mix hex.publish` (needs Hex owner rights).

**Backlog (known limits, pick by need)**
- `search/2` uses `to_tsquery`, which errors on plain user input ("red shoes"); `websearch_to_tsquery` is kinder but changes semantics, so it's a major or opt-in change.
- Typespecs on the public builder API (none yet).
- Opt-in prepared-statement cache (one round-trip per repeated query instead of two).
- `bulk_insert` is ~24% slower than on Postgrex; steer big loads to `copy/3` (4.6× faster).
- Column names/document keys become atoms (bounded set; documented).

After each change: `python3 ~/.claude/skills/codemap/scripts/index.py refresh --root .`.
