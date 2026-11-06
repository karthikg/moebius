@AGENTS.md

# Moebius in one screen

**What:** a functional query library for Elixir + PostgreSQL (v5.0.1 on Hex, MIT). Not an ORM: no schemas, no migrations, no structs. You pipe small builder functions into a command struct, a database module runs it, and you get plain maps back.

```elixir
import Moebius.Query
db(:users) |> filter(:order_count, gt: 5) |> sort(:last, :asc) |> limit(20) |> Moebius.Db.run()
```

**Two query styles**
- Relational, `Moebius.Query` → `%QueryCommand{}`: filter, sort, limit, insert/update/delete, `bulk_insert`, `ignore_conflict`, join, count/group/reduce, full-text `search`, `sql_file`, `function`.
- Documents, `Moebius.DocumentQuery` → `%DocumentCommand{}`: maps stored in a `jsonb` `body` column. The table and GIN indexes are created on first save, and an optional `tsvector` column is kept current for search.

**Running:** `use Moebius.Database` makes a module a database with its own pooler pool, giving it `run/first/find/save/transaction/stream/explain/copy`. `Moebius.Db` is the built-in one. Under it: epgsql (driver), pooler (pool), codecs for dates/numeric/JSON, and parameter type checks before anything is sent.

**Rules of the codebase**
- Builders do no I/O. Tests assert `cmd.sql` / `cmd.params` directly.
- Every name in SQL goes through `Moebius.Identifier`, and every value is a `$n` parameter.
- The public API returns `{:ok, result}` / `{:error, message}`.

**Where to look:** `.codemap/MAP.md` first, `.codemap/recipes.md` for "where do I change X", and `PROJECT.md` for how it works and the upgrade plan.

**Verify a change:** `MIX_ENV=test mix moebius.migrate && MIX_ENV=test mix moebius.seed && mix test && mix quality --strict` (needs Postgres on localhost:5432, db `moebius_test`, user/pass `postgres`; brew service `postgresql@17`). Pinned toolchain via mise: prefix with `mise exec --` unless mise is activated in the shell.

**After changing code:** `python3 ~/.claude/skills/codemap/scripts/index.py refresh --root .` and fix any `TODO` purposes.
