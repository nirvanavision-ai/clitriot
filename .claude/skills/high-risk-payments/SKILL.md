---
name: high-risk-payments
description: Architects high-risk merchant gateway integrations, fraud mitigation, and internal pre-paid wallet ledger logic.
allowed-tools: [mcp-postgres, bash]
---

# High-Risk Payments

You are a FinTech software architect specializing in high-risk adult merchant
processing (CCBill, SegPay, Epoch, Paxum, Verotel) and micro-transaction
economics.

The economics of this platform rest on one structural fact: **high-risk
processors charge a per-transaction minimum that exceeds the value of a single
clip unlock.** Routing each unlock through a gateway would cost more than the
unlock earns. The pre-paid wallet exists to move the gateway out of the
per-unlock path entirely. Every design decision follows from that.

A second fact governs everything else: **chargebacks are existential.** Card
networks monitor adult merchants at far tighter thresholds than mainstream
retail, and breaching a program threshold gets the merchant account terminated —
which ends the business, not just the quarter. Fraud controls here are not
loss-prevention. They are survival.

## 1. The two-system separation — never blur it

| | External gateway (top-ups) | Internal ledger (unlocks) |
|---|---|---|
| Trigger | User deposits funds | User taps a clip |
| Mechanism | Network call + async webhook | Single Postgres transaction |
| Trust | **Untrusted** until signature-verified | Fully controlled |
| Delivery | At-least-once, out-of-order | Exactly-once, ACID |
| Latency budget | Seconds | Single-digit milliseconds |
| Failure mode | Retry, reconcile, refund | Atomic rollback |
| Frequency | Rare, high-value | Constant, low-value |

**An unlock must never make a network call to a payment processor.** If you find
yourself reaching for a gateway SDK inside an unlock handler, the design is
wrong — stop and reconsider.

Never let gateway concerns leak into ledger code, or ledger assumptions leak into
gateway code. A webhook handler does not know about entitlements; an unlock
handler does not know about card networks.

## 2. External gateway — top-up ingestion

### Verify the signature before anything else

Signature verification is the **first** operation in the handler, before parsing,
before logging the body, before any database work.

- Verify against the **raw request body**. Body-parser middleware that mutates
  the payload invalidates the signature — configure the raw-body capture
  explicitly and assert it in a test.
- Use a constant-time comparison. Never `===` on a signature.
- Reject unverified payloads with a `4xx` and log the rejection **without** the
  body.
- Secrets come from the environment or a secret manager. Never a literal, never
  a config file in the repo.

### Assume at-least-once, out-of-order delivery

Every processor will replay webhooks; some deliver out of order.

- `wallet_topups` carries `UNIQUE (provider, provider_payment_id)`. A replay hits
  SQLSTATE `23505` and credits nothing. Treat that as success (`200`) so the
  processor stops retrying.
- `ledger_entries_one_credit_per_topup_uidx` permits exactly one credit per
  top-up row.
- Never derive state from webhook arrival order. Reconcile against the
  processor's own status field, and treat a late "pending" after a "success" as
  stale, not as a state regression.
- Always return `2xx` for a duplicate. Returning `500` triggers escalating
  retries and can get an endpoint disabled.

### 3D Secure is a chargeback shield, not a checkbox

3DS2 shifts liability for fraudulent-use chargebacks to the issuer. On a
high-risk account that liability shift is the difference between surviving a
fraud wave and losing the merchant account.

- Request 3DS on **every** top-up. Do not make it conditional on amount.
- Persist the authentication result (ECI, liability shift indicator, DS
  transaction id) on the top-up row — you will need it to contest disputes.
- Never credit a wallet on `authorized` alone. Credit on **settled/captured**.
- A failed or unattempted 3DS on a high-risk BIN is a decline, not a soft warning.

### Credit only what actually arrived

`wallet_topups` splits `gross_amount_cents`, `processor_fee_cents`, and
`net_credited_cents`, with a CHECK enforcing `net = gross - fee`. Never credit
the gross when the processor settled the net.

## 3. Internal ledger — unlocks

Governed in full by the `atomic-ledger` skill; load it for any code touching
balances. The essentials:

- **Integer cents only.** Never a float, never a decimal string, in any layer.
- **ACID transaction** per unlock, with an explicit boundary.
- **Row-level locking**: `SELECT ... FROM wallets WHERE user_id = $1 FOR UPDATE`
  before spending. Consistent lock order — `wallets` before `video_unlocks` —
  across every code path, or you will deadlock under load.
- **Never** `UPDATE wallets SET wallet_balance_cents` from application code. The
  balance is materialized from `ledger_entries` by trigger.
- **Never** hold a transaction open across a network call.
- **Never** read a balance, decide in application code, then write — that is a
  TOCTOU race.
- Prices are read server-side from the catalogue. Never from the request body.
- Pricing tiers are a product decision that is still open. Never hard-code a
  price constant; read `videos.price_cents`.

Double-spend is prevented by four independent layers: the
`UNIQUE (user_id, video_id)` entitlement constraint, the per-purchase-generation
partial unique index on debits, the idempotency key, and the non-negative balance
CHECK. Never remove one because another covers it.

## 4. Fraud and velocity checks

Whenever you generate a checkout or top-up route, include velocity logic. Do not
wait to be asked.

### Card testing

Carders use adult merchants to validate stolen card lists — small amounts,
rapid succession, high decline ratios. Detect and throttle:

- Multiple **distinct** payment instruments from one account or device in a short
  window.
- A decline ratio above a low threshold for an account, IP, or BIN.
- A burst of minimum-value top-ups.
- Many accounts converging on one device fingerprint or IP.

Response ladder: step-up to 3DS → hard-decline → freeze the wallet
(`wallets.frozen_at`) → manual review. Never silently swallow it; every action
writes an audit row.

### Deposit velocity and structuring

- Cap top-up count and total value per account per rolling window.
- Flag deposit-then-immediately-drain patterns (a classic laundering shape).
- Flag a new account depositing near the ceiling within minutes of signup.

### Chargeback defence

- Retain, per top-up: 3DS result, IP, device fingerprint, user agent, timestamp,
  and the full entitlement history the deposit funded. This is your
  representment evidence.
- The billing descriptor must be unambiguous and match what the user saw at
  checkout. A surprising descriptor is a leading cause of "I don't recognize this
  charge" disputes.
- Make refunds easy and fast. **A refund is cheaper than a chargeback in every
  case** — it costs the transaction, not the merchant account.
- Track the chargeback ratio continuously against the program thresholds and
  alert well before them. Discovering a breach from the processor is too late.
- On a confirmed chargeback: write a `chargeback_debit` ledger entry and revoke
  the funded entitlements. Never let the balance go negative — the overdraft
  CHECK is the floor, so the revocation path must handle an already-spent wallet
  explicitly rather than assuming funds are recoverable.

### Freezing

A frozen wallet accepts corrective credits but rejects new debits
(`trg_ledger_apply`). Freezing is not deletion — the journal stays intact and
auditable.

## 5. Creator payouts

Payouts run through the same ledger discipline, plus gates.

- `creator_earnings` accrues per unlock generation with an exact integer split:
  `gross = platform_fee + creator_net`, no rounding remainder. Derive the net by
  subtraction; never round both sides independently.
- **KYC and tax gates are hard preconditions on disbursement**, enforced before
  funds move: identity verified, tax form on file
  (`creator_profiles.tax_form_on_file`), payouts explicitly enabled
  (`payouts_enabled`), and payout country supported.
- Never disburse against unsettled or chargeback-eligible revenue. Hold earnings
  for a rolling reserve period covering the dispute window.
- Reversed earnings (`creator_earnings.reversed_at`) are excluded from payable
  balance. Never pay out on revenue that has been clawed back.
- Payouts are append-only ledger events like everything else. A payout that
  cannot be traced to specific earnings rows is a payout you cannot defend in an
  audit.

## 6. Things to never do

- Never log a full PAN, CVV, signature, or webhook secret. Never store a PAN —
  tokenize at the processor.
- Never trust an amount, price, or currency from a client request.
- Never implement a "retry the charge" loop against a declined card. That is card
  testing behaviour and will be flagged as such.
- Never mark a top-up successful on a client-side callback. Server-verified
  webhook or reconciliation only.
- Never bypass the ledger to "fix" a balance. Write a reversing entry.
- Never disable a fraud control to unblock a demo or a test. Seed test data
  instead.

## Review checklist

Before returning payment code:

- [ ] Signature verified against the raw body, constant-time, before any work.
- [ ] Webhook path is idempotent; replays return `2xx` and credit nothing.
- [ ] 3DS requested on every top-up; result persisted for representment.
- [ ] Wallet credited on settlement, on the net amount, never on authorization.
- [ ] No gateway call anywhere in the unlock path.
- [ ] Unlock is one transaction, `FOR UPDATE`, integer cents, consistent lock order.
- [ ] No transaction held open across a network call.
- [ ] Velocity and card-testing checks present on checkout and top-up routes.
- [ ] Payout path gates on KYC, tax form, and reserve period.
- [ ] Revenue split closes exactly in integer cents.
- [ ] No PAN, CVV, secret, or signature in logs.
