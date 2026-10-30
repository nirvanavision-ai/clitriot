-- =============================================================================
-- Invariant tests for db/init.sql
--
-- Each block asserts that an ILLEGAL operation is REJECTED by the database.
-- Run against a database freshly loaded with init.sql:
--
--   psql -d di_test -v ON_ERROR_STOP=1 -f db/init.sql
--   psql -d di_test -v ON_ERROR_STOP=1 -f db/test_invariants.sql
--
-- Any 'FAIL' line, or an unhandled exception, means an invariant has regressed.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
INSERT INTO users (id, email, password_hash, is_creator) VALUES
    ('00000000-0000-0000-0000-0000000000c1', 'creator@example.test', 'x', TRUE),
    ('00000000-0000-0000-0000-0000000000b1', 'buyer@example.test',   'x', FALSE),
    ('00000000-0000-0000-0000-0000000000a1', 'admin@example.test',   'x', FALSE);

INSERT INTO records_custodians
    (id, legal_entity_name, custodian_full_name, street_address_1, city,
     postal_code, country, inspection_hours_text, inspection_hours_per_week,
     contact_email, effective_from)
VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Example Media LLC', 'Jordan Reyes',
     '1 Example Way', 'Las Vegas', '89101', 'US', 'Mon-Fri 09:00-17:00', 40,
     'records@example.test', DATE '2024-01-01');

-- Two adult performers and one who was underage at the production date.
INSERT INTO performers (id, legal_first_name, legal_last_name, date_of_birth) VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'Alex',  'Stone',  DATE '1995-03-01'),
    ('00000000-0000-0000-0000-0000000000e2', 'Sam',   'Rivera', DATE '1998-07-15'),
    ('00000000-0000-0000-0000-0000000000e3', 'Riley', 'Chen',   DATE '2007-01-01');

INSERT INTO videos (id, creator_user_id, title, price_cents, production_date,
                    production_city, production_country, records_custodian_id)
VALUES
    ('00000000-0000-0000-0000-0000000000f1',
     '00000000-0000-0000-0000-0000000000c1', 'Test Depiction', 99,
     DATE '2024-06-01', 'Las Vegas', 'US',
     '00000000-0000-0000-0000-0000000000d1');

INSERT INTO wallets (id, user_id) VALUES
    ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1');


-- ---------------------------------------------------------------------------
-- TEST 1 — Gatekeeper: cannot publish with zero performers on record.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    UPDATE videos SET status = 'published', published_at = now()
     WHERE id = '00000000-0000-0000-0000-0000000000f1';
    RAISE EXCEPTION 'FAIL test 1: published a video with no 2257 performer records';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 1: publish blocked — no performer records';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 2 — Age at production: an underage performer cannot be attached.
--          Riley Chen (b. 2007-01-01) was 17 on the 2024-06-01 shoot date.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO video_performers (video_id, performer_id, role)
    VALUES ('00000000-0000-0000-0000-0000000000f1',
            '00000000-0000-0000-0000-0000000000e3', 'co_performer');
    RAISE EXCEPTION 'FAIL test 2: attached a performer who was 17 on the production date';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 2: underage-at-production performer rejected';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 3 — Gatekeeper: performers attached but unverified => still not publishable.
-- ---------------------------------------------------------------------------
INSERT INTO video_performers (id, video_id, performer_id, role) VALUES
    ('00000000-0000-0000-0000-000000000d01', '00000000-0000-0000-0000-0000000000f1',
     '00000000-0000-0000-0000-0000000000e1', 'primary'),
    ('00000000-0000-0000-0000-000000000d02', '00000000-0000-0000-0000-0000000000f1',
     '00000000-0000-0000-0000-0000000000e2', 'co_performer');

DO $$
DECLARE t INT; v INT; c INT;
BEGIN
    SELECT compliance_performer_count, compliance_verified_count, compliance_consent_count
      INTO t, v, c FROM videos WHERE id = '00000000-0000-0000-0000-0000000000f1';

    IF t <> 2 OR v <> 0 OR c <> 0 THEN
        RAISE EXCEPTION 'FAIL test 3a: counters wrong, expected 2/0/0 got %/%/%', t, v, c;
    END IF;
    RAISE NOTICE 'PASS test 3a: counters recomputed to %/%/% on cast insert', t, v, c;

    UPDATE videos SET status = 'published', published_at = now()
     WHERE id = '00000000-0000-0000-0000-0000000000f1';
    RAISE EXCEPTION 'FAIL test 3b: published with unverified performers';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 3b: publish blocked — performers unverified';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 4 — Verification alone is insufficient: an examined government ID is
--          required before a performer counts as verified.
-- ---------------------------------------------------------------------------
UPDATE performers
   SET identity_verification_state = 'verified',
       identity_verified_at = now(),
       identity_verified_by = '00000000-0000-0000-0000-0000000000a1'
 WHERE id IN ('00000000-0000-0000-0000-0000000000e1',
              '00000000-0000-0000-0000-0000000000e2');

DO $$
DECLARE v INT;
BEGIN
    SELECT compliance_verified_count INTO v
      FROM videos WHERE id = '00000000-0000-0000-0000-0000000000f1';
    IF v <> 0 THEN
        RAISE EXCEPTION 'FAIL test 4: performer counted as verified with no ID document on file (got %)', v;
    END IF;
    RAISE NOTICE 'PASS test 4: verified flag without an ID document does not satisfy the gatekeeper';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 5 — Full record set => publishable.
-- ---------------------------------------------------------------------------
INSERT INTO performer_identity_documents
    (performer_id, document_type, issuing_country, document_number_hash,
     name_on_document, dob_on_document, storage_bucket, storage_key,
     storage_sha256, encryption_key_id, verification_state, verified_at, verified_by)
VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'passport', 'US', '\x01'::bytea,
     'Alex Stone', DATE '1995-03-01', 'ids', 'p1.enc', '\xaa'::bytea, 'kms-1',
     'verified', now(), '00000000-0000-0000-0000-0000000000a1'),
    ('00000000-0000-0000-0000-0000000000e2', 'drivers_license', 'US', '\x02'::bytea,
     'Sam Rivera', DATE '1998-07-15', 'ids', 'p2.enc', '\xbb'::bytea, 'kms-1',
     'verified', now(), '00000000-0000-0000-0000-0000000000a1');

INSERT INTO performer_consent_records
    (id, performer_id, video_id, signed_at, signature_method, document_version,
     storage_bucket, storage_key, storage_sha256)
VALUES
    ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-0000000000e1',
     '00000000-0000-0000-0000-0000000000f1', now(), 'esign', 'v1', 'rel', 'r1.pdf', '\xcc'::bytea),
    ('00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-0000000000e2',
     '00000000-0000-0000-0000-0000000000f1', now(), 'esign', 'v1', 'rel', 'r2.pdf', '\xdd'::bytea);

UPDATE video_performers SET consent_record_id = '00000000-0000-0000-0000-000000000c01'
 WHERE id = '00000000-0000-0000-0000-000000000d01';
UPDATE video_performers SET consent_record_id = '00000000-0000-0000-0000-000000000c02'
 WHERE id = '00000000-0000-0000-0000-000000000d02';

UPDATE videos
   SET compliance_reviewed_at = now(),
       compliance_reviewed_by = '00000000-0000-0000-0000-0000000000a1',
       status = 'published',
       published_at = now()
 WHERE id = '00000000-0000-0000-0000-0000000000f1';

DO $$
DECLARE s video_status; t INT; v INT; c INT;
BEGIN
    SELECT status, compliance_performer_count, compliance_verified_count, compliance_consent_count
      INTO s, t, v, c FROM videos WHERE id = '00000000-0000-0000-0000-0000000000f1';
    IF s <> 'published' OR v <> 2 OR c <> 2 THEN
        RAISE EXCEPTION 'FAIL test 5: expected published 2/2/2, got % %/%/%', s, t, v, c;
    END IF;
    RAISE NOTICE 'PASS test 5: complete 2257 record set permits publication (%/%/%)', t, v, c;
END $$;


-- ---------------------------------------------------------------------------
-- TEST 6 — A co-performer cannot be silently dropped from a published video.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    DELETE FROM video_performers WHERE id = '00000000-0000-0000-0000-000000000d02';
    RAISE EXCEPTION 'FAIL test 6: removed a co-performer from a published video';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 6: cannot remove a co-performer while the video is published';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 7 — Revoking a performer's verification forces the video off-air.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    UPDATE performers SET identity_verification_state = 'revoked'
     WHERE id = '00000000-0000-0000-0000-0000000000e2';
    RAISE EXCEPTION 'FAIL test 7: revoked a performer while their video stayed published';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 7: revoking verification aborts unless the video is unpublished first';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 8 — Revoking consent forces the video off-air.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    UPDATE performer_consent_records
       SET revoked_at = now(), revocation_reason = 'performer withdrew'
     WHERE id = '00000000-0000-0000-0000-000000000c02';
    RAISE EXCEPTION 'FAIL test 8: consent revoked while the video stayed published';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 8: consent revocation aborts unless the video is unpublished first';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 9 — 2257 records cannot be hard-deleted.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    DELETE FROM performers WHERE id = '00000000-0000-0000-0000-0000000000e1';
    RAISE EXCEPTION 'FAIL test 9: deleted a 2257 performer record';
EXCEPTION WHEN restrict_violation THEN
    RAISE NOTICE 'PASS test 9: 2257 record deletion blocked by retention trigger';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 10 — Ledger: balance is materialized from the journal, not written.
-- ---------------------------------------------------------------------------
INSERT INTO wallet_topups
    (id, wallet_id, user_id, gross_amount_cents, processor_fee_cents,
     net_credited_cents, provider, provider_payment_id, provider_status, succeeded_at)
VALUES
    ('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-00000000ac01',
     '00000000-0000-0000-0000-0000000000b1', 2000, 0, 2000, 'ccbill', 'pay_abc', 'succeeded', now());

INSERT INTO ledger_entries
    (wallet_id, user_id, entry_type, amount_cents, wallet_topup_id, idempotency_key)
VALUES
    ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
     'wallet_topup', 2000, '00000000-0000-0000-0000-000000000b01', 'topup-1');

DO $$
DECLARE b money_cents; ba money_cents;
BEGIN
    SELECT wallet_balance_cents INTO b FROM wallets WHERE id = '00000000-0000-0000-0000-00000000ac01';
    SELECT balance_after_cents  INTO ba FROM ledger_entries WHERE idempotency_key = 'topup-1';
    IF b <> 2000 OR ba <> 2000 THEN
        RAISE EXCEPTION 'FAIL test 10: expected balance 2000/2000, got %/%', b, ba;
    END IF;
    RAISE NOTICE 'PASS test 10: wallet balance materialized to % cents from the journal', b;
END $$;


-- ---------------------------------------------------------------------------
-- TEST 11 — Webhook replay cannot double-credit a top-up.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO wallet_topups
        (wallet_id, user_id, gross_amount_cents, processor_fee_cents,
         net_credited_cents, provider, provider_payment_id, provider_status)
    VALUES ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
            2000, 0, 2000, 'ccbill', 'pay_abc', 'succeeded');
    RAISE EXCEPTION 'FAIL test 11: same provider payment credited twice';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS test 11: duplicate provider payment id rejected (webhook replay safe)';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 12 — The $0.99 unlock debits the wallet.
-- ---------------------------------------------------------------------------
INSERT INTO video_unlocks (id, user_id, video_id, price_cents)
VALUES ('00000000-0000-0000-0000-000000000a01',
        '00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000f1', 99);

INSERT INTO ledger_entries
    (wallet_id, user_id, entry_type, amount_cents, video_unlock_id,
     purchase_sequence, idempotency_key)
VALUES
    ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
     'video_unlock_debit', -99, '00000000-0000-0000-0000-000000000a01', 1, 'unlock-1');

DO $$
DECLARE b money_cents;
BEGIN
    SELECT wallet_balance_cents INTO b FROM wallets WHERE id = '00000000-0000-0000-0000-00000000ac01';
    IF b <> 1901 THEN RAISE EXCEPTION 'FAIL test 12: expected 1901, got %', b; END IF;
    RAISE NOTICE 'PASS test 12: unlock debited 99 cents, balance now %', b;
END $$;


-- ---------------------------------------------------------------------------
-- TEST 13 — DOUBLE-SPEND: the same user cannot unlock the same video twice.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO video_unlocks (user_id, video_id, price_cents)
    VALUES ('00000000-0000-0000-0000-0000000000b1',
            '00000000-0000-0000-0000-0000000000f1', 99);
    RAISE EXCEPTION 'FAIL test 13: user charged twice for the same video';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS test 13: duplicate unlock rejected (23505) — double-spend blocked';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 14 — A second debit against the same purchase generation is impossible,
--           even if the caller bypasses video_unlocks entirely.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO ledger_entries
        (wallet_id, user_id, entry_type, amount_cents, video_unlock_id,
         purchase_sequence, idempotency_key)
    VALUES ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
            'video_unlock_debit', -99, '00000000-0000-0000-0000-000000000a01', 1, 'unlock-1-retry');
    RAISE EXCEPTION 'FAIL test 14: second debit landed for the same purchase generation';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS test 14: duplicate debit for purchase generation 1 rejected';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 15 — A retried request reusing an idempotency key cannot re-charge.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO ledger_entries
        (wallet_id, user_id, entry_type, amount_cents, idempotency_key)
    VALUES ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
            'promotional_credit', 500, 'unlock-1');
    RAISE EXCEPTION 'FAIL test 15: idempotency key reused successfully';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS test 15: reused idempotency key rejected';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 16 — Overdraft floor: a wallet cannot go negative.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO ledger_entries
        (wallet_id, user_id, entry_type, amount_cents, idempotency_key)
    VALUES ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
            'payout_debit', -999999, 'overdraft-attempt');
    RAISE EXCEPTION 'FAIL test 16: wallet went negative';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 16: overdraft rejected by wallets_no_overdraft';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 17 — Ledger history is immutable.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    UPDATE ledger_entries SET amount_cents = -1 WHERE idempotency_key = 'unlock-1';
    RAISE EXCEPTION 'FAIL test 17: ledger entry was mutated';
EXCEPTION WHEN restrict_violation THEN
    RAISE NOTICE 'PASS test 17: ledger UPDATE blocked (append-only)';
END $$;

DO $$
BEGIN
    DELETE FROM ledger_entries WHERE idempotency_key = 'unlock-1';
    RAISE EXCEPTION 'FAIL test 17b: ledger entry was deleted';
EXCEPTION WHEN restrict_violation THEN
    RAISE NOTICE 'PASS test 17b: ledger DELETE blocked (append-only)';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 18 — Sign discipline: a debit type cannot carry a positive amount.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO ledger_entries
        (wallet_id, user_id, entry_type, amount_cents, video_unlock_id,
         purchase_sequence, idempotency_key)
    VALUES ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-0000000000b1',
            'video_unlock_debit', 99, '00000000-0000-0000-0000-000000000a01', 2, 'sign-bug');
    RAISE EXCEPTION 'FAIL test 18: a debit created money';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 18: positive-signed debit rejected';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 19 — Revenue split must close exactly in integer cents.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO creator_earnings
        (creator_user_id, video_id, video_unlock_id, purchase_sequence,
         gross_cents, platform_fee_cents, creator_net_cents)
    VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1',
            '00000000-0000-0000-0000-000000000a01', 1, 99, 30, 70);  -- 30+70 = 100 <> 99
    RAISE EXCEPTION 'FAIL test 19: revenue split did not close and was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 19: non-closing revenue split rejected (no rounding drift)';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 20 — Reconciliation invariant: the view must be empty.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n INT;
BEGIN
    SELECT count(*) INTO n FROM wallet_reconciliation;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FAIL test 20: % wallet(s) diverged from the journal', n;
    END IF;
    RAISE NOTICE 'PASS test 20: wallet_reconciliation empty — balances match the journal';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 21 — Unpublished / non-compliant content cannot be sold.
-- ---------------------------------------------------------------------------
INSERT INTO videos (id, creator_user_id, title, price_cents)
VALUES ('00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000c1', 'Unpublished Draft', 99);

DO $$
BEGIN
    INSERT INTO video_unlocks (user_id, video_id, price_cents)
    VALUES ('00000000-0000-0000-0000-0000000000b1',
            '00000000-0000-0000-0000-0000000000f2', 99);
    RAISE EXCEPTION 'FAIL test 21: sold a video that was never published';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 21: purchase of a non-published video rejected';
END $$;


-- ---------------------------------------------------------------------------
-- TEST 22 — Client-supplied price must match the catalogue price.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO video_unlocks (user_id, video_id, price_cents)
    VALUES ('00000000-0000-0000-0000-0000000000c1',
            '00000000-0000-0000-0000-0000000000f1', 1);
    RAISE EXCEPTION 'FAIL test 22: accepted a client-supplied price of 1 cent';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS test 22: price tampering rejected';
END $$;


ROLLBACK;

\echo ''
\echo '======================================================'
\echo ' All invariant tests completed. Review NOTICE output:'
\echo ' every line must read PASS.'
\echo '======================================================'
