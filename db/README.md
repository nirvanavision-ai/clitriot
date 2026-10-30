# Database schema

PostgreSQL schema for the wallet ledger and the § 2257 compliance records. It was written on 2026-08-14 for the earlier "Digital Intimacy" working name (repo `nirvanavision-ai/digitalintimacy`, branch `claude/database-schema-init-vrfjas`) and copied here unchanged.

| File | What it is |
|---|---|
| `init.sql` | One-shot schema, PostgreSQL 14+. Part A is the § 2257 firewall (performers, aliases, ID examinations, per-video consent, a publish gate enforced by CHECK constraints). Part B is the micro-ledger (integer-cent wallets, an append-only journal, idempotent top-ups and unlocks, creator earnings). |
| `test_invariants.sql` | 24 checks that each try an illegal operation (publishing with an unverified performer, double unlock, overdraft, editing the ledger, and so on) and assert the database refuses it. |

## Run the tests

```sh
createdb di_test
psql -d di_test -v ON_ERROR_STOP=1 -f db/init.sql
psql -d di_test -v ON_ERROR_STOP=1 -f db/test_invariants.sql
```

Every NOTICE line must read PASS. All 24 passed on PostgreSQL 16 on 2026-10-30.

## How this relates to the later design

This is not the 19-migration set from the later planning chats. That set is still to be recovered. This schema predates the Clitriot prototype, so it has single clip unlocks but no branching series, deposit lots, bundles, effective-dated revenue splits or messaging. Treat it as the starting point for the ledger and the compliance records, not as the finished data model.
