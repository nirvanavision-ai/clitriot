---
name: atomic-ledger
description: Enforces integer-cent money handling, ACID transaction boundaries, row-level locking, idempotency, and double-spend prevention for the internal pre-paid wallet and per-clip video unlocks. Use whenever code touches wallets, balances, unlocks, refunds, payouts, or any monetary value.
allowed-tools: [Read, Edit, Write, Grep, Glob, Bash]
---

# Atomic Ledger

You are the financial-correctness authority for the internal micro-transaction
ledger. The rules here are absolute. A ledger that is *usually* correct is not a
ledger.

## 1. Money is always an integer count of cents

> **Never** `float`, `double`, `REAL`, `NUMERIC`, `Number` with decimals, or a
> decimal string. Ever. In any language, in any layer.

- Postgres: the `money_cents` domain (`BIGINT`). Column names end in `_cents`.
- TypeScript/JavaScript: `bigint`, or `number` **only** while provably under
  `Number.MAX_SAFE_INTEGER` and only ever holding whole cents.
- JSON: integers. Never `0.99`. The wire format for ninety-nine cents is `99`.
- Display formatting (`$0.99`) happens in the presentation layer at the last
  possible moment, and never round-trips back into a calculation.

`0.1 + 0.2 !== 0.3`. At a few hundred thousand transactions a day, floating-point
money produces balances that cannot be reconciled and payouts that cannot be
defended. If you see a float touching money anywhere, fix it — treat it as a
production bug, not a style preference.

### Splits must close exactly

Any division of money (revenue share, fees, taxes) must sum back to the original
integer with zero remainder. Compute the fee, then derive the remainder by
subtraction:

```ts
const platformFeeCents = Math.floor(grossCents * FEE_BPS / 10_000);
const creatorNetCents  = grossCents - platformFeeCents;  // never a second rounding
```

`creator_earnings_split_balances` enforces `gross = fee + net` at the DB level.
Never compute both sides independently and hope they agree.

## 2. External gateway vs. internal ledger

These are different systems with different guarantees. Never blur them.

| | External gateway | Internal ledger |
|---|---|---|
| What | Bulk top-ups via high-risk processor | Per-clip unlocks |
| Where | Network call to CCBill/SegPay/Epoch | Postgres transaction, no network |
| Latency | Seconds | Single-digit ms |
| Failure | Retries, webhooks, at-least-once | ACID, all-or-nothing |
| Trust | Untrusted until signature-verified | Fully controlled |

An unlock **never** makes a network call to a payment processor. The entire
economic model depends on the unlock being a local DB transaction. If you
find yourself calling a gateway during unlock, the design is wrong.

## 3. The wallet balance is derived, never written

`wallets.wallet_balance_cents` is a materialization of the `ledger_entries`
journal, maintained by the `ledger_entries_apply` trigger.

- Application code **inserts a ledger entry**. The balance follows.
- Application code **never** issues `UPDATE wallets SET wallet_balance_cents`.
- The trigger's single `UPDATE ... RETURNING` takes the row lock, applies the
  delta, and stamps `balance_after_cents` inside that lock.
- `wallets_no_overdraft` (`CHECK balance >= 0`) is the floor. Even if every
  layer above is wrong, the wallet cannot go negative — the transaction aborts.

The `wallet_reconciliation` view must always return zero rows. Run it as a
scheduled invariant check. A non-empty result means the materialized balance has
diverged from the journal: halt payouts and page someone.

## 4. The journal is append-only

`ledger_entries` rejects `UPDATE` and `DELETE` at the trigger level. Corrections
are new reversing entries carrying `reverses_entry_id`. An editable ledger is
not a ledger — it is a mutable table that happens to contain numbers.

Every entry records: signed amount, resulting balance, type, provenance
(which unlock, which top-up, which reversal), and an idempotency key.

Sign discipline is enforced by `ledger_entries_sign_matches_type`: debit types
must be negative, credit types positive. A sign inversion is how you silently
mint money.

## 5. Double-spend prevention — four independent layers

Any one of these would mostly work. Together they make a duplicate charge
structurally impossible. Never remove a layer because another one covers it.

1. **`video_unlocks_one_per_user_video`** — `UNIQUE (user_id, video_id)`.
   Concurrent unlock attempts serialize on this index; exactly one wins, the
   rest get SQLSTATE `23505`. This is the primary guarantee.
2. **`ledger_entries_one_debit_per_purchase_uidx`** — partial unique index on
   `(video_unlock_id, purchase_sequence)`. Blocks a second debit for the same
   purchase generation even if `video_unlocks` is bypassed entirely.
3. **`ledger_entries_idempotency_unique`** — a retried API call carrying the
   same key cannot create a second entry.
4. **`wallets_no_overdraft`** — the balance floor catches anything that escapes
   the first three.

**Refunds do not delete the unlock row.** They transition `state`. A re-purchase
is an `UPDATE` that bumps `purchase_count`, never a second `INSERT`. This keeps
the uniqueness guarantee absolute across the full refund → re-buy lifecycle.

Verified empirically: 12 concurrent workers attempting the same unlock against a
wallet holding exactly 99 cents produced 1 success, 11 × `23505`, one debit row,
and zero reconciliation drift.

## 6. Transaction discipline

Every money-moving operation is one transaction with an explicit boundary.

**Consistent lock ordering — always `wallets` before `video_unlocks`.** Deadlocks
come from inconsistent ordering across code paths. Fix the order once and never
deviate.

```sql
BEGIN;
  -- 1. Pin the wallet. FOR UPDATE serializes concurrent spends on this wallet.
  SELECT wallet_balance_cents FROM wallets WHERE user_id = $1 FOR UPDATE;

  -- 2. Claim the entitlement. Unique violation here = already owned, not an error.
  INSERT INTO video_unlocks (user_id, video_id, price_cents) VALUES ($1, $2, $3);

  -- 3. Write the journal entry. The trigger applies the delta and stamps balance.
  INSERT INTO ledger_entries (...) VALUES (...);
COMMIT;
```

Rules:

- **Never** hold a transaction open across a network call, an `await` on an HTTP
  request, or a queue publish. Row locks block every other spend on that wallet.
- **Never** read a balance, decide in application code, then write. That is a
  TOCTOU race. Either lock with `FOR UPDATE` or let the constraint decide.
- Keep transactions short. This is a high-velocity path.
- `SELECT ... FOR SHARE` on `videos` during purchase pins the row so it cannot
  unpublish mid-transaction.

## 7. Handle constraint violations as expected control flow

At this transaction volume, `23505` is a normal outcome, not an exception to log
and alert on. Map SQLSTATEs to real API semantics:

| SQLSTATE | Meaning | Response |
|---|---|---|
| `23505` on `video_unlocks_one_per_user_video` | Already owned | `200` + existing entitlement (idempotent) |
| `23505` on idempotency key | Retried request | `200` + replayed original response |
| `23514` on `wallets_no_overdraft` | Insufficient funds | `402` + top-up prompt |
| `23514` on price mismatch | Stale/tampered client price | `409` + refresh catalogue |
| `40001` serialization failure | Contention | Retry with jitter, bounded attempts |

A duplicate unlock must return success with the entitlement, never a 500. Users
double-tap; that is not an error condition.

## 8. Never trust a client-supplied amount

Prices come from `videos.price_cents`, server-side, every time.
`trg_video_unlocks_saleable_check` re-reads the catalogue price and rejects any
mismatch. Never accept an amount from a request body and use it to move money.

## 9. Webhook and replay safety

External processors deliver at-least-once. Every ingestion path must be
idempotent:

- `wallet_topups` has `UNIQUE (provider, provider_payment_id)`. A replayed
  webhook hits `23505` and credits nothing.
- `ledger_entries_one_credit_per_topup_uidx` allows exactly one credit per
  top-up row.
- Verify the payload signature **before** any database work.

## Review checklist

Before returning code that touches money:

- [ ] Every monetary value is an integer count of cents; no floats anywhere.
- [ ] No `UPDATE wallets SET wallet_balance_cents` in application code.
- [ ] Balances are never read-then-written without `FOR UPDATE`.
- [ ] Lock order is `wallets` → `video_unlocks`, consistently.
- [ ] No network call inside a transaction.
- [ ] Amounts are read from the catalogue, never from the request.
- [ ] `23505` on a duplicate unlock returns success, not an error.
- [ ] Every externally-triggered credit path is idempotent.
- [ ] Splits close exactly by subtraction, not double rounding.
- [ ] Corrections are reversing entries, never edits.
