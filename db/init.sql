-- =============================================================================
-- digitalintimacy — initial PostgreSQL schema
-- Target: PostgreSQL 14+
--
-- This script establishes two independent-but-linked subsystems:
--
--   PART A — the 18 U.S.C. § 2257 Compliance Firewall
--            Record-keeping for every depiction, enforced declaratively so that
--            a video is structurally incapable of reaching status 'published'
--            while any performer record is incomplete, unverified, or missing.
--
--   PART B — the High-Velocity Micro-Ledger
--            Pre-paid wallets and per-clip unlocks. Every monetary value is a
--            BIGINT count of cents. The wallet balance is a trigger-maintained
--            materialization of an append-only journal, so the application
--            cannot mutate money without writing an audit row.
--
-- Design stance: constraints live in the database, not in application code.
-- An API bug, a retried HTTP request, or a rogue script must not be able to
-- publish an unverified performer or charge a user twice.
-- =============================================================================

BEGIN;

SET LOCAL client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email / alias
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- 2257 requires searchable title/name indexes


-- =============================================================================
-- 0. DOMAINS AND ENUMERATED TYPES
-- =============================================================================

-- ATOMIC-LEDGER RULE: money never touches FLOAT, DOUBLE PRECISION, or NUMERIC.
-- Every monetary column in this schema is declared money_cents. A signed 64-bit
-- cent count covers ±$92 quadrillion, which is comfortably beyond any balance
-- this platform will hold, and it is exact under addition.
CREATE DOMAIN money_cents AS BIGINT;
COMMENT ON DOMAIN money_cents IS
  'Signed integer count of minor currency units (cents). Never store money as a float or a decimal string.';

-- ISO 4217. Single-currency at launch, but the column exists so that a second
-- currency cannot be bolted on later by reinterpreting existing rows.
CREATE DOMAIN currency_code AS CHAR(3)
    CHECK (VALUE ~ '^[A-Z]{3}$');

-- ISO 3166-1 alpha-2, used for production locations and ID issuing authorities.
CREATE DOMAIN country_code AS CHAR(2)
    CHECK (VALUE ~ '^[A-Z]{2}$');

CREATE TYPE video_status AS ENUM (
    'draft',                -- creator is still uploading / editing metadata
    'pending_compliance',   -- submitted, 2257 record set incomplete
    'compliance_review',    -- complete record set, awaiting human sign-off
    'approved',             -- compliance cleared, creator has not published yet
    'published',            -- publicly purchasable — GATEKEEPER APPLIES
    'unpublished',          -- was live, withdrawn by creator
    'rejected',             -- compliance denied
    'takedown'              -- removed by platform / legal order
);

CREATE TYPE performer_role AS ENUM (
    'primary',              -- the account holder / principal performer
    'co_performer',         -- any other person depicted
    'body_double',
    'non_performing'        -- appears on camera but not in any depiction (crew, etc.)
);

CREATE TYPE verification_state AS ENUM (
    'unverified',
    'pending',
    'verified',
    'rejected',
    'expired',
    'revoked'
);

CREATE TYPE id_document_type AS ENUM (
    'passport',
    'drivers_license',
    'state_id',
    'national_id',
    'military_id',
    'residence_permit'
);

CREATE TYPE alias_kind AS ENUM (
    'stage_name',
    'maiden_name',
    'former_legal_name',
    'nickname',
    'screen_credit'
);

CREATE TYPE ledger_entry_type AS ENUM (
    'wallet_topup',           -- + external money in
    'video_unlock_debit',     -- - a per-clip unlock
    'unlock_refund_credit',   -- + reversal of an unlock
    'promotional_credit',     -- + platform-funded credit
    'chargeback_debit',       -- - card network pulled the funds back
    'manual_adjustment',      -- ± support action, always requires a reason
    'payout_debit'            -- - creator withdrawal
);

CREATE TYPE unlock_state AS ENUM (
    'active',
    'refunded',
    'revoked'                 -- e.g. underlying video hit takedown
);

CREATE TYPE idempotency_state AS ENUM (
    'in_flight',
    'completed',
    'failed'
);


-- =============================================================================
-- 1. IDENTITY
-- =============================================================================

CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email               CITEXT NOT NULL,
    email_verified_at   TIMESTAMPTZ,
    password_hash       TEXT NOT NULL,
    display_name        TEXT,

    -- Age attestation for the *consumer* side. Distinct from § 2257 performer
    -- verification, which is far stricter and lives in PART A.
    age_attested_at     TIMESTAMPTZ,

    is_creator          BOOLEAN NOT NULL DEFAULT FALSE,
    disabled_at         TIMESTAMPTZ,
    disabled_reason     TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT users_email_unique UNIQUE (email),
    CONSTRAINT users_disabled_reason_required
        CHECK (disabled_at IS NULL OR disabled_reason IS NOT NULL)
);

CREATE INDEX users_created_at_idx ON users (created_at DESC);

COMMENT ON TABLE users IS
  'Platform accounts. A user may be a viewer, a creator, or both. Performers are modelled separately — a co-performer need not hold an account.';


CREATE TABLE creator_profiles (
    user_id             UUID PRIMARY KEY REFERENCES users (id) ON DELETE RESTRICT,
    handle              CITEXT NOT NULL,
    bio                 TEXT,

    -- Payout identity. Deliberately separate from the § 2257 performer record:
    -- tax/banking data and compliance data have different retention rules and
    -- different access-control audiences.
    payout_country      country_code,
    tax_form_on_file    BOOLEAN NOT NULL DEFAULT FALSE,
    payouts_enabled     BOOLEAN NOT NULL DEFAULT FALSE,

    -- Every creator must be bound to a designated Custodian of Records before
    -- any of their videos can publish (see § 2257(e) posting requirement).
    records_custodian_id UUID,   -- FK added after records_custodians exists

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT creator_profiles_handle_unique UNIQUE (handle),
    CONSTRAINT creator_profiles_handle_format
        CHECK (handle ~ '^[a-z0-9_]{3,32}$')
);


-- =============================================================================
-- PART A — THE 2257 COMPLIANCE FIREWALL
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A.1  Custodian of Records
--      § 2257(e)(1) requires each depiction to carry a statement naming the
--      custodian and the address at which records are available for inspection,
--      and § 2257(c) requires those records be available at least 20 hours/week.
-- -----------------------------------------------------------------------------
CREATE TABLE records_custodians (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_entity_name       TEXT NOT NULL,
    custodian_full_name     TEXT NOT NULL,

    street_address_1        TEXT NOT NULL,
    street_address_2        TEXT,
    city                    TEXT NOT NULL,
    state_region            TEXT,
    postal_code             TEXT NOT NULL,
    country                 country_code NOT NULL,

    -- Inspection availability, stored so the § 2257(e) notice can be generated
    -- from data rather than hand-written per video.
    inspection_hours_text   TEXT NOT NULL,
    inspection_hours_per_week SMALLINT NOT NULL
        CHECK (inspection_hours_per_week >= 20),

    contact_email           CITEXT NOT NULL,
    contact_phone           TEXT,

    effective_from          DATE NOT NULL,
    effective_until         DATE,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT records_custodians_effective_range
        CHECK (effective_until IS NULL OR effective_until > effective_from)
);

ALTER TABLE creator_profiles
    ADD CONSTRAINT creator_profiles_custodian_fk
    FOREIGN KEY (records_custodian_id)
    REFERENCES records_custodians (id) ON DELETE RESTRICT;


-- -----------------------------------------------------------------------------
-- A.2  Performers — the legal identity of record
--
--      This is the § 2257 subject. It is intentionally NOT the same row as
--      `users`: a co-performer in someone else's scene may never create an
--      account, yet the platform is still obligated to hold their record.
--      Conversely a user account is not proof of anything.
--
--      PII WARNING: legal_* and date_of_birth are the most sensitive columns in
--      this database. They should be readable only by the compliance role
--      (see PART C) and encrypted at rest at the volume level.
-- -----------------------------------------------------------------------------
CREATE TABLE performers (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Nullable on purpose: a performer without a platform account is legal and
    -- common. ON DELETE RESTRICT because deleting a user must never orphan or
    -- destroy a compliance record.
    user_id                     UUID REFERENCES users (id) ON DELETE RESTRICT,

    legal_first_name            TEXT NOT NULL,
    legal_middle_name           TEXT,
    legal_last_name             TEXT NOT NULL,
    legal_name_suffix           TEXT,

    -- Normalized, generated, and indexed because § 2257(d)(2) requires records
    -- be indexed by every performer's legal name.
    legal_name_normalized       TEXT GENERATED ALWAYS AS (
        lower(
            btrim(
                regexp_replace(
                    coalesce(legal_first_name, '') || ' ' ||
                    coalesce(legal_middle_name, '') || ' ' ||
                    coalesce(legal_last_name, '')  || ' ' ||
                    coalesce(legal_name_suffix, ''),
                    '\s+', ' ', 'g'
                )
            )
        )
    ) STORED,

    date_of_birth               DATE NOT NULL,

    nationality                 country_code,

    identity_verification_state verification_state NOT NULL DEFAULT 'unverified',
    identity_verified_at        TIMESTAMPTZ,
    identity_verified_by        UUID REFERENCES users (id) ON DELETE RESTRICT,
    identity_rejection_reason   TEXT,

    -- § 2257 retention: records are kept for the statutory period even after the
    -- performer leaves the platform. Purge jobs must respect this date.
    records_retention_until     DATE,

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Nobody under 18 gets a performer record at all. This is the outermost
    -- ring; the per-depiction age check in A.6 is the one that actually matters,
    -- because age must be evaluated against the production date, not today.
    CONSTRAINT performers_dob_sane
        CHECK (date_of_birth > DATE '1900-01-01'
               AND date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),

    CONSTRAINT performers_verified_requires_timestamp
        CHECK (identity_verification_state <> 'verified'
               OR (identity_verified_at IS NOT NULL AND identity_verified_by IS NOT NULL)),

    CONSTRAINT performers_rejected_requires_reason
        CHECK (identity_verification_state <> 'rejected'
               OR identity_rejection_reason IS NOT NULL)
);

-- § 2257(d)(2) indexing obligations.
CREATE INDEX performers_legal_name_idx      ON performers (legal_name_normalized);
CREATE INDEX performers_legal_name_trgm_idx ON performers USING gin (legal_name_normalized gin_trgm_ops);
CREATE INDEX performers_dob_idx             ON performers (date_of_birth);
CREATE UNIQUE INDEX performers_user_id_uidx ON performers (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX performers_verification_idx    ON performers (identity_verification_state);

COMMENT ON TABLE performers IS
  '18 U.S.C. § 2257 identity record. One row per human being depicted, whether or not they hold a platform account.';


-- -----------------------------------------------------------------------------
-- A.3  Aliases — stage names, maiden names, prior legal names, nicknames
--      § 2257(d)(2) requires records be indexed by every name ever used by the
--      performer, not just the legal one. Hence a table, not a column.
-- -----------------------------------------------------------------------------
CREATE TABLE performer_aliases (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    performer_id        UUID NOT NULL REFERENCES performers (id) ON DELETE RESTRICT,
    alias               CITEXT NOT NULL,
    alias_normalized    TEXT GENERATED ALWAYS AS (
                            lower(btrim(regexp_replace(alias::text, '\s+', ' ', 'g')))
                        ) STORED,
    kind                alias_kind NOT NULL DEFAULT 'stage_name',

    -- The alias actually credited on-screen. Exactly one per performer may hold
    -- this flag (enforced by a partial unique index below).
    is_primary_credit   BOOLEAN NOT NULL DEFAULT FALSE,

    first_used_on       DATE,
    last_used_on        DATE,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT performer_aliases_unique UNIQUE (performer_id, alias),
    CONSTRAINT performer_aliases_alias_nonempty CHECK (btrim(alias::text) <> ''),
    CONSTRAINT performer_aliases_date_range
        CHECK (last_used_on IS NULL OR first_used_on IS NULL OR last_used_on >= first_used_on)
);

CREATE UNIQUE INDEX performer_aliases_one_primary_uidx
    ON performer_aliases (performer_id) WHERE is_primary_credit;

CREATE INDEX performer_aliases_normalized_idx ON performer_aliases (alias_normalized);
CREATE INDEX performer_aliases_trgm_idx       ON performer_aliases USING gin (alias_normalized gin_trgm_ops);


-- -----------------------------------------------------------------------------
-- A.4  Government-issued photo identification
--      § 2257(b)(1) requires a copy of the ID that was examined. The image never
--      lives in Postgres — only an object-store pointer, an integrity hash, and
--      the examination metadata. That keeps the blob under separate key
--      management and keeps this table cheap to replicate.
-- -----------------------------------------------------------------------------
CREATE TABLE performer_identity_documents (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    performer_id            UUID NOT NULL REFERENCES performers (id) ON DELETE RESTRICT,

    document_type           id_document_type NOT NULL,
    issuing_country         country_code NOT NULL,
    issuing_authority       TEXT,

    -- Never store the raw document number. Store a keyed hash for duplicate
    -- detection plus the last four for human-readable reconciliation.
    document_number_hash    BYTEA NOT NULL,
    document_number_last4   CHAR(4),

    issued_on               DATE,
    expires_on              DATE,

    -- Name and DOB exactly as printed, so a reviewer can confirm the document
    -- matches the performers row rather than trusting a typed form.
    name_on_document        TEXT NOT NULL,
    dob_on_document         DATE NOT NULL,

    -- Encrypted blob location. Bucket/key only; no signed URLs at rest.
    storage_bucket          TEXT NOT NULL,
    storage_key             TEXT NOT NULL,
    storage_sha256          BYTEA NOT NULL,
    encryption_key_id       TEXT NOT NULL,

    verification_state      verification_state NOT NULL DEFAULT 'pending',
    verified_at             TIMESTAMPTZ,
    verified_by             UUID REFERENCES users (id) ON DELETE RESTRICT,
    rejection_reason        TEXT,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pid_storage_unique UNIQUE (storage_bucket, storage_key),
    CONSTRAINT pid_number_hash_unique UNIQUE (issuing_country, document_type, document_number_hash),
    CONSTRAINT pid_date_range
        CHECK (expires_on IS NULL OR issued_on IS NULL OR expires_on > issued_on),
    CONSTRAINT pid_verified_requires_reviewer
        CHECK (verification_state <> 'verified'
               OR (verified_at IS NOT NULL AND verified_by IS NOT NULL)),
    CONSTRAINT pid_rejected_requires_reason
        CHECK (verification_state <> 'rejected' OR rejection_reason IS NOT NULL),
    CONSTRAINT pid_last4_format
        CHECK (document_number_last4 IS NULL OR document_number_last4 ~ '^[A-Za-z0-9]{4}$')
);

CREATE INDEX pid_performer_idx ON performer_identity_documents (performer_id);
CREATE INDEX pid_expiry_idx    ON performer_identity_documents (expires_on)
    WHERE verification_state = 'verified';

COMMENT ON COLUMN performer_identity_documents.document_number_hash IS
  'HMAC of the document number under a service-held key. Enables duplicate detection without storing the number.';


-- -----------------------------------------------------------------------------
-- A.5  Videos — the depiction
--
--      The compliance_* counters on this table are the mechanism that makes the
--      Gatekeeper a declarative CHECK constraint rather than application logic.
--      They are maintained exclusively by compliance_recompute_video() and are
--      not writable by the application role.
-- -----------------------------------------------------------------------------
CREATE TABLE videos (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_user_id             UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,

    title                       TEXT NOT NULL,
    description                 TEXT,
    duration_seconds            INTEGER CHECK (duration_seconds IS NULL OR duration_seconds > 0),

    status                      video_status NOT NULL DEFAULT 'draft',

    -- ---- § 2257 production facts ------------------------------------------
    -- The exact date of original production of the depiction, per § 2257(b)(2).
    production_date             DATE,
    production_city             TEXT,
    production_state_region     TEXT,
    production_country          country_code,
    production_venue_note       TEXT,

    records_custodian_id        UUID REFERENCES records_custodians (id) ON DELETE RESTRICT,

    compliance_reviewed_at      TIMESTAMPTZ,
    compliance_reviewed_by      UUID REFERENCES users (id) ON DELETE RESTRICT,

    -- ---- Gatekeeper counters (trigger-maintained, do not write directly) ----
    compliance_performer_count  INTEGER NOT NULL DEFAULT 0,
    compliance_verified_count   INTEGER NOT NULL DEFAULT 0,
    compliance_consent_count    INTEGER NOT NULL DEFAULT 0,
    compliance_recomputed_at    TIMESTAMPTZ,

    -- ---- Commerce ----------------------------------------------------------
    -- No default. Pricing tiers (mid → premium) are a product decision that has
    -- not been made yet, so every video must state its price explicitly rather
    -- than silently inheriting a placeholder. The upper bound is a typo guard
    -- (a $10,000 clip is a fat-finger, not a tier), not a business rule.
    price_cents                 money_cents NOT NULL,
    currency                    currency_code NOT NULL DEFAULT 'USD',

    published_at                TIMESTAMPTZ,
    unpublished_at              TIMESTAMPTZ,
    deleted_at                  TIMESTAMPTZ,   -- soft delete only; records survive

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT videos_title_nonempty CHECK (btrim(title) <> ''),
    CONSTRAINT videos_price_in_range CHECK (price_cents > 0 AND price_cents <= 1000000),

    CONSTRAINT videos_counters_sane CHECK (
        compliance_performer_count >= 0
        AND compliance_verified_count BETWEEN 0 AND compliance_performer_count
        AND compliance_consent_count  BETWEEN 0 AND compliance_performer_count
    ),

    CONSTRAINT videos_production_location_complete CHECK (
        (production_city IS NULL AND production_country IS NULL)
        OR (production_city IS NOT NULL AND production_country IS NOT NULL)
    ),

    -- =========================================================================
    -- THE GATEKEEPER
    --
    -- A row may not sit in status 'published' unless every § 2257 precondition
    -- is satisfied. Because this is a CHECK, it is re-evaluated on *every*
    -- UPDATE of the row — including the counter updates issued by the triggers
    -- below. Consequently, removing a performer from a published video, or
    -- revoking a performer's verification, aborts the transaction rather than
    -- silently leaving non-compliant content live.
    -- =========================================================================
    CONSTRAINT videos_2257_publish_gatekeeper CHECK (
        status <> 'published'
        OR (
                production_date            IS NOT NULL
            AND production_city            IS NOT NULL
            AND production_country         IS NOT NULL
            AND records_custodian_id       IS NOT NULL
            AND compliance_reviewed_at     IS NOT NULL
            AND compliance_reviewed_by     IS NOT NULL
            AND deleted_at                 IS NULL
            AND compliance_performer_count > 0
            AND compliance_verified_count  = compliance_performer_count
            AND compliance_consent_count   = compliance_performer_count
        )
    ),

    CONSTRAINT videos_published_requires_timestamp
        CHECK (status <> 'published' OR published_at IS NOT NULL)
);

CREATE INDEX videos_creator_idx      ON videos (creator_user_id, created_at DESC);
CREATE INDEX videos_status_idx       ON videos (status);
CREATE INDEX videos_published_idx    ON videos (published_at DESC)
    WHERE status = 'published' AND deleted_at IS NULL;
CREATE INDEX videos_production_date_idx ON videos (production_date);
-- § 2257(d)(2): records must also be indexed by title of the depiction.
CREATE INDEX videos_title_trgm_idx    ON videos USING gin (lower(title) gin_trgm_ops);

COMMENT ON CONSTRAINT videos_2257_publish_gatekeeper ON videos IS
  'Structural enforcement of the Gatekeeper rule: publication is impossible while any 2257 precondition is unmet.';


-- -----------------------------------------------------------------------------
-- A.6  Video ↔ Performer — the co-performer relationship
--
--      This is the heart of the compliance model. Every human depicted in a
--      video gets exactly one row here, linking the depiction to a fully
--      verified performers row. The primary performer is not privileged: a
--      co-performer's record is held to identical standards.
-- -----------------------------------------------------------------------------
CREATE TABLE video_performers (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id                UUID NOT NULL REFERENCES videos (id) ON DELETE RESTRICT,
    performer_id            UUID NOT NULL REFERENCES performers (id) ON DELETE RESTRICT,

    role                    performer_role NOT NULL DEFAULT 'co_performer',

    -- The alias actually credited in THIS depiction. § 2257 requires the record
    -- to tie the on-screen name to the legal identity, and a performer may use
    -- different stage names on different scenes.
    credited_alias_id       UUID REFERENCES performer_aliases (id) ON DELETE RESTRICT,

    -- Signed release / consent for this specific depiction. Nullable so a draft
    -- can be assembled incrementally; the Gatekeeper refuses to publish until
    -- every row here has one.
    consent_record_id       UUID,   -- FK added after performer_consent_records

    -- Age at production, snapshotted at insert time by the trigger below. Stored
    -- so an inspection can read the number without re-deriving it, and so that a
    -- later correction to date_of_birth is detectable rather than silent.
    age_at_production       SMALLINT,

    added_by                UUID REFERENCES users (id) ON DELETE RESTRICT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- One row per person per depiction. Prevents a performer being counted
    -- twice, which would otherwise let a single verified performer satisfy the
    -- Gatekeeper counters for a scene containing an unverified co-performer.
    CONSTRAINT video_performers_unique UNIQUE (video_id, performer_id),

    CONSTRAINT video_performers_age_at_production_sane
        CHECK (age_at_production IS NULL OR age_at_production >= 18)
);

CREATE INDEX video_performers_video_idx     ON video_performers (video_id);
CREATE INDEX video_performers_performer_idx ON video_performers (performer_id);

-- Exactly one primary performer per video.
CREATE UNIQUE INDEX video_performers_one_primary_uidx
    ON video_performers (video_id) WHERE role = 'primary';

COMMENT ON TABLE video_performers IS
  'Join between a depiction and every person in it. Co-performers are first-class: identical verification requirements to the primary performer.';


-- -----------------------------------------------------------------------------
-- A.7  Per-depiction consent / release records
-- -----------------------------------------------------------------------------
CREATE TABLE performer_consent_records (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    performer_id            UUID NOT NULL REFERENCES performers (id) ON DELETE RESTRICT,
    video_id                UUID NOT NULL REFERENCES videos (id) ON DELETE RESTRICT,

    signed_at               TIMESTAMPTZ NOT NULL,
    signature_method        TEXT NOT NULL,          -- 'wet_ink', 'esign', 'video_attestation'
    signer_ip               INET,
    document_version        TEXT NOT NULL,

    storage_bucket          TEXT NOT NULL,
    storage_key             TEXT NOT NULL,
    storage_sha256          BYTEA NOT NULL,

    -- Consent is revocable as a contractual matter; revocation must force the
    -- video out of 'published' rather than merely flagging it. The recompute
    -- trigger plus the Gatekeeper CHECK deliver exactly that.
    revoked_at              TIMESTAMPTZ,
    revocation_reason       TEXT,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pcr_unique_per_depiction UNIQUE (video_id, performer_id),
    CONSTRAINT pcr_storage_unique UNIQUE (storage_bucket, storage_key),
    CONSTRAINT pcr_revoked_requires_reason
        CHECK (revoked_at IS NULL OR revocation_reason IS NOT NULL),
    CONSTRAINT pcr_signature_method_known
        CHECK (signature_method IN ('wet_ink', 'esign', 'video_attestation'))
);

CREATE INDEX pcr_video_idx     ON performer_consent_records (video_id);
CREATE INDEX pcr_performer_idx ON performer_consent_records (performer_id);

ALTER TABLE video_performers
    ADD CONSTRAINT video_performers_consent_fk
    FOREIGN KEY (consent_record_id)
    REFERENCES performer_consent_records (id) ON DELETE RESTRICT;


-- -----------------------------------------------------------------------------
-- A.8  Append-only compliance audit log
--      An inspection asks "who verified this, and when". The answer must not be
--      reconstructible only from mutable columns.
-- -----------------------------------------------------------------------------
CREATE TABLE compliance_audit_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_user_id   UUID REFERENCES users (id) ON DELETE RESTRICT,
    entity_type     TEXT NOT NULL,      -- 'video' | 'performer' | 'identity_document' | ...
    entity_id       UUID NOT NULL,
    action          TEXT NOT NULL,      -- 'verified' | 'rejected' | 'revoked' | 'published' | ...
    detail          JSONB NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT compliance_audit_entity_type_known
        CHECK (entity_type IN ('video', 'performer', 'identity_document',
                               'consent_record', 'video_performer', 'custodian'))
);

CREATE INDEX compliance_audit_entity_idx ON compliance_audit_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX compliance_audit_actor_idx  ON compliance_audit_log (actor_user_id, occurred_at DESC);


-- =============================================================================
-- PART B — THE HIGH-VELOCITY MICRO-LEDGER
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B.1  Wallets
--      balance_cents is a materialized aggregate of ledger_entries, maintained
--      by trigger. The application never writes it directly; it inserts journal
--      rows and the balance follows. See B.7 for the reconciliation view.
-- -----------------------------------------------------------------------------
CREATE TABLE wallets (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    currency            currency_code NOT NULL DEFAULT 'USD',

    wallet_balance_cents money_cents NOT NULL DEFAULT 0,

    -- Monotonic counter bumped on every mutation. Gives the API layer an
    -- optimistic-concurrency token and makes lost updates detectable.
    version             BIGINT NOT NULL DEFAULT 0,

    frozen_at           TIMESTAMPTZ,
    frozen_reason       TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- One wallet per user per currency.
    CONSTRAINT wallets_user_currency_unique UNIQUE (user_id, currency),

    -- THE OVERDRAFT FLOOR. Even if every layer above this line is wrong, a
    -- wallet cannot go negative — the transaction aborts instead.
    CONSTRAINT wallets_no_overdraft CHECK (wallet_balance_cents >= 0),

    CONSTRAINT wallets_frozen_requires_reason
        CHECK (frozen_at IS NULL OR frozen_reason IS NOT NULL)
);

-- Composite target so child tables can pin currency declaratively (see B.3).
ALTER TABLE wallets ADD CONSTRAINT wallets_id_currency_unique UNIQUE (id, currency);

CREATE INDEX wallets_user_idx ON wallets (user_id);

COMMENT ON COLUMN wallets.wallet_balance_cents IS
  'Integer cents. Materialized from ledger_entries by trigger — never written by application code.';


-- -----------------------------------------------------------------------------
-- B.2  Wallet top-ups — external money entering the system
--      The unique constraint on the provider reference is what makes payment
--      webhooks safe to replay. Stripe et al. deliver at-least-once.
-- -----------------------------------------------------------------------------
CREATE TABLE wallet_topups (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id               UUID NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
    user_id                 UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,

    gross_amount_cents      money_cents NOT NULL CHECK (gross_amount_cents > 0),
    processor_fee_cents     money_cents NOT NULL DEFAULT 0 CHECK (processor_fee_cents >= 0),
    net_credited_cents      money_cents NOT NULL CHECK (net_credited_cents > 0),
    currency                currency_code NOT NULL DEFAULT 'USD',

    provider                TEXT NOT NULL,      -- 'stripe' | 'adyen' | ...
    provider_payment_id     TEXT NOT NULL,
    provider_status         TEXT NOT NULL,

    succeeded_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- WEBHOOK REPLAY GUARD: the same provider payment can only ever credit once.
    CONSTRAINT wallet_topups_provider_unique UNIQUE (provider, provider_payment_id),

    -- Integer arithmetic must close exactly. No rounding drift, ever.
    CONSTRAINT wallet_topups_amounts_balance
        CHECK (net_credited_cents = gross_amount_cents - processor_fee_cents)
);

CREATE INDEX wallet_topups_wallet_idx ON wallet_topups (wallet_id, created_at DESC);


-- -----------------------------------------------------------------------------
-- B.3  Video unlocks — THE DOUBLE-SPEND FIREWALL
--
--      One row per (user, video). Forever. The UNIQUE constraint below is the
--      single strongest guarantee in this schema: no matter how many concurrent
--      requests arrive, at most one of them can create the entitlement, and the
--      losers receive SQLSTATE 23505 rather than a second charge.
--
--      Refunds do NOT delete the row — they transition `state`. A re-purchase
--      is an UPDATE that bumps `purchase_count`, never a second INSERT. That
--      keeps the uniqueness guarantee absolute while still permitting the
--      refund→re-buy lifecycle.
-- -----------------------------------------------------------------------------
CREATE TABLE video_unlocks (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    video_id                UUID NOT NULL REFERENCES videos (id) ON DELETE RESTRICT,

    state                   unlock_state NOT NULL DEFAULT 'active',

    price_cents             money_cents NOT NULL CHECK (price_cents > 0),
    currency                currency_code NOT NULL DEFAULT 'USD',

    -- Generation counter. Starts at 1; incremented on each re-purchase after a
    -- refund. Pairs with the partial unique index on ledger_entries (B.4) to
    -- make a duplicate debit within one generation structurally impossible.
    purchase_count          INTEGER NOT NULL DEFAULT 1 CHECK (purchase_count >= 1),

    first_unlocked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    state_changed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_reason          TEXT,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- =========================================================================
    -- THE DOUBLE-SPEND GUARD
    -- =========================================================================
    CONSTRAINT video_unlocks_one_per_user_video UNIQUE (user_id, video_id),

    CONSTRAINT video_unlocks_revoked_requires_reason
        CHECK (state <> 'revoked' OR revoked_reason IS NOT NULL)
);

CREATE INDEX video_unlocks_user_idx  ON video_unlocks (user_id, first_unlocked_at DESC);
CREATE INDEX video_unlocks_video_idx ON video_unlocks (video_id);
CREATE INDEX video_unlocks_active_idx ON video_unlocks (user_id, video_id) WHERE state = 'active';

COMMENT ON CONSTRAINT video_unlocks_one_per_user_video ON video_unlocks IS
  'Prevents double-charging: concurrent unlock attempts for the same (user, video) serialize on this index; all but one fail with 23505.';


-- -----------------------------------------------------------------------------
-- B.4  Ledger entries — the append-only journal
--
--      Every cent that moves writes a row here. Rows are immutable: UPDATE and
--      DELETE are blocked by trigger. balance_after_cents is stamped by the
--      same trigger that applies the delta to the wallet, so the journal
--      carries a running balance that can be audited without replaying.
-- -----------------------------------------------------------------------------
CREATE TABLE ledger_entries (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id               UUID NOT NULL,
    user_id                 UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    currency                currency_code NOT NULL DEFAULT 'USD',

    entry_type              ledger_entry_type NOT NULL,

    -- Signed. Negative debits the wallet, positive credits it. Zero is never a
    -- legitimate ledger event and is rejected.
    amount_cents            money_cents NOT NULL CHECK (amount_cents <> 0),

    -- Wallet balance immediately after this entry was applied. Stamped by
    -- trigger inside the same row lock that performed the update.
    balance_after_cents     money_cents NOT NULL CHECK (balance_after_cents >= 0),

    -- ---- Provenance --------------------------------------------------------
    video_unlock_id         UUID REFERENCES video_unlocks (id) ON DELETE RESTRICT,
    purchase_sequence       INTEGER,          -- mirrors video_unlocks.purchase_count
    wallet_topup_id         UUID REFERENCES wallet_topups (id) ON DELETE RESTRICT,
    reverses_entry_id       UUID REFERENCES ledger_entries (id) ON DELETE RESTRICT,

    -- ---- Idempotency -------------------------------------------------------
    -- Second layer of double-charge defence, independent of video_unlocks. A
    -- retried API call carrying the same key cannot produce a second entry.
    idempotency_key         TEXT,

    reason                  TEXT,
    actor_user_id           UUID REFERENCES users (id) ON DELETE RESTRICT,
    metadata                JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Currency of the entry must equal currency of the wallet. Enforced
    -- declaratively via the composite key on wallets rather than in code.
    CONSTRAINT ledger_entries_wallet_currency_fk
        FOREIGN KEY (wallet_id, currency) REFERENCES wallets (id, currency) ON DELETE RESTRICT,

    CONSTRAINT ledger_entries_idempotency_unique UNIQUE (idempotency_key),

    -- Debits must be negative, credits positive. Sign errors are a classic
    -- source of silent money creation; make them unrepresentable.
    CONSTRAINT ledger_entries_sign_matches_type CHECK (
        CASE entry_type
            WHEN 'wallet_topup'         THEN amount_cents > 0
            WHEN 'promotional_credit'   THEN amount_cents > 0
            WHEN 'unlock_refund_credit' THEN amount_cents > 0
            WHEN 'video_unlock_debit'   THEN amount_cents < 0
            WHEN 'chargeback_debit'     THEN amount_cents < 0
            WHEN 'payout_debit'         THEN amount_cents < 0
            WHEN 'manual_adjustment'    THEN TRUE
        END
    ),

    CONSTRAINT ledger_entries_adjustment_requires_reason
        CHECK (entry_type <> 'manual_adjustment'
               OR (reason IS NOT NULL AND actor_user_id IS NOT NULL)),

    -- Unlock-related entries must name the unlock and its generation.
    CONSTRAINT ledger_entries_unlock_provenance CHECK (
        entry_type NOT IN ('video_unlock_debit', 'unlock_refund_credit')
        OR (video_unlock_id IS NOT NULL AND purchase_sequence IS NOT NULL)
    ),

    CONSTRAINT ledger_entries_topup_provenance CHECK (
        entry_type <> 'wallet_topup' OR wallet_topup_id IS NOT NULL
    )
);

CREATE INDEX ledger_entries_wallet_idx ON ledger_entries (wallet_id, created_at DESC, id);
CREATE INDEX ledger_entries_user_idx   ON ledger_entries (user_id, created_at DESC);
CREATE INDEX ledger_entries_type_idx   ON ledger_entries (entry_type, created_at DESC);

-- One debit and one refund per unlock generation. If a retry escapes both the
-- unique unlock row and the idempotency key, it still cannot land a second
-- charge for the same purchase.
CREATE UNIQUE INDEX ledger_entries_one_debit_per_purchase_uidx
    ON ledger_entries (video_unlock_id, purchase_sequence)
    WHERE entry_type = 'video_unlock_debit';

CREATE UNIQUE INDEX ledger_entries_one_refund_per_purchase_uidx
    ON ledger_entries (video_unlock_id, purchase_sequence)
    WHERE entry_type = 'unlock_refund_credit';

-- A reversal may only be issued once against a given entry.
CREATE UNIQUE INDEX ledger_entries_one_reversal_uidx
    ON ledger_entries (reverses_entry_id)
    WHERE reverses_entry_id IS NOT NULL;

-- One credit per top-up row.
CREATE UNIQUE INDEX ledger_entries_one_credit_per_topup_uidx
    ON ledger_entries (wallet_topup_id)
    WHERE wallet_topup_id IS NOT NULL;

COMMENT ON TABLE ledger_entries IS
  'Append-only financial journal. Immutable by trigger. wallets.wallet_balance_cents is derived from this table.';


-- -----------------------------------------------------------------------------
-- B.5  API-level idempotency keys
--      Guards non-ledger side effects and lets a retried request replay the
--      original response instead of re-executing.
-- -----------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
    key                     TEXT PRIMARY KEY,
    user_id                 UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    endpoint                TEXT NOT NULL,

    -- Hash of the request body. A key reused with different parameters is a
    -- client bug and must be rejected, not silently replayed.
    request_fingerprint     BYTEA NOT NULL,

    state                   idempotency_state NOT NULL DEFAULT 'in_flight',
    response_status         SMALLINT,
    response_body           JSONB,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at            TIMESTAMPTZ,
    expires_at              TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',

    CONSTRAINT idempotency_completed_requires_response
        CHECK (state <> 'completed' OR (response_status IS NOT NULL AND completed_at IS NOT NULL))
);

CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys (expires_at);


-- -----------------------------------------------------------------------------
-- B.6  Creator earnings — the revenue split
--      Split in integer cents with an exact-sum constraint, so no fraction of a
--      cent can be created or destroyed by rounding.
-- -----------------------------------------------------------------------------
CREATE TABLE creator_earnings (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_user_id         UUID NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    video_id                UUID NOT NULL REFERENCES videos (id) ON DELETE RESTRICT,
    video_unlock_id         UUID NOT NULL REFERENCES video_unlocks (id) ON DELETE RESTRICT,
    purchase_sequence       INTEGER NOT NULL,

    gross_cents             money_cents NOT NULL CHECK (gross_cents > 0),
    platform_fee_cents      money_cents NOT NULL CHECK (platform_fee_cents >= 0),
    creator_net_cents       money_cents NOT NULL CHECK (creator_net_cents >= 0),
    currency                currency_code NOT NULL DEFAULT 'USD',

    reversed_at             TIMESTAMPTZ,
    payout_batch_id         UUID,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Exact integer close. gross = fee + net, no remainder.
    CONSTRAINT creator_earnings_split_balances
        CHECK (gross_cents = platform_fee_cents + creator_net_cents),

    -- One earnings row per unlock generation — mirrors the ledger debit guard.
    CONSTRAINT creator_earnings_once_per_purchase
        UNIQUE (video_unlock_id, purchase_sequence)
);

CREATE INDEX creator_earnings_creator_idx ON creator_earnings (creator_user_id, created_at DESC);
CREATE INDEX creator_earnings_unpaid_idx  ON creator_earnings (creator_user_id)
    WHERE payout_batch_id IS NULL AND reversed_at IS NULL;


-- =============================================================================
-- PART C — FUNCTIONS AND TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C.0  updated_at maintenance
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_set_updated_at             BEFORE UPDATE ON users                        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER creator_profiles_set_updated_at  BEFORE UPDATE ON creator_profiles             FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER records_custodians_set_updated_at BEFORE UPDATE ON records_custodians          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER performers_set_updated_at        BEFORE UPDATE ON performers                   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER pid_set_updated_at               BEFORE UPDATE ON performer_identity_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER videos_set_updated_at            BEFORE UPDATE ON videos                       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER video_performers_set_updated_at  BEFORE UPDATE ON video_performers             FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER wallets_set_updated_at           BEFORE UPDATE ON wallets                      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER video_unlocks_set_updated_at     BEFORE UPDATE ON video_unlocks                FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- C.1  Compliance recompute — the engine behind the Gatekeeper
--
--      SECURITY DEFINER so it can write the compliance_* counters even though
--      the application role has those columns revoked (see PART D). This makes
--      the counters tamper-resistant: the only path to changing them is to
--      change the underlying compliance facts.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compliance_recompute_video(p_video_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_video_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE videos v
       SET compliance_performer_count = c.total,
           compliance_verified_count  = c.verified,
           compliance_consent_count   = c.consented,
           compliance_recomputed_at   = now()
      FROM (
        SELECT
            count(*)::int AS total,

            -- "Verified" means: the performer record is in state 'verified' AND
            -- at least one government ID has been examined, accepted, and has
            -- not expired. A verified flag with no surviving document is not a
            -- § 2257 record.
            count(*) FILTER (
                WHERE p.identity_verification_state = 'verified'
                  AND p.identity_verified_at IS NOT NULL
                  AND EXISTS (
                        SELECT 1
                          FROM performer_identity_documents d
                         WHERE d.performer_id = p.id
                           AND d.verification_state = 'verified'
                           AND d.verified_at IS NOT NULL
                           AND (d.expires_on IS NULL OR d.expires_on >= CURRENT_DATE)
                      )
            )::int AS verified,

            -- "Consented" means a release exists for this exact depiction and
            -- has not been revoked.
            count(*) FILTER (
                WHERE cr.id IS NOT NULL AND cr.revoked_at IS NULL
            )::int AS consented

          FROM video_performers vp
          JOIN performers p  ON p.id = vp.performer_id
          LEFT JOIN performer_consent_records cr
                 ON cr.id = vp.consent_record_id
        WHERE vp.video_id = p_video_id
      ) c
     WHERE v.id = p_video_id;
END;
$$;

REVOKE ALL ON FUNCTION compliance_recompute_video(UUID) FROM PUBLIC;

COMMENT ON FUNCTION compliance_recompute_video(UUID) IS
  'Recomputes the Gatekeeper counters for one video. Any resulting violation of videos_2257_publish_gatekeeper aborts the calling transaction.';


-- Recompute when the cast list changes.
CREATE OR REPLACE FUNCTION trg_video_performers_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM compliance_recompute_video(NEW.video_id);
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        IF TG_OP = 'DELETE' OR OLD.video_id IS DISTINCT FROM NEW.video_id THEN
            PERFORM compliance_recompute_video(OLD.video_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER video_performers_recompute
    AFTER INSERT OR UPDATE OR DELETE ON video_performers
    FOR EACH ROW EXECUTE FUNCTION trg_video_performers_recompute();


-- Recompute every affected video when a performer's verification changes.
-- Revoking a performer mid-flight will therefore attempt to drop the counters
-- on each of their published videos, and the Gatekeeper CHECK will abort the
-- transaction unless those videos are unpublished in the same statement.
CREATE OR REPLACE FUNCTION trg_performers_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id UUID;
BEGIN
    IF NEW.identity_verification_state IS DISTINCT FROM OLD.identity_verification_state
       OR NEW.identity_verified_at     IS DISTINCT FROM OLD.identity_verified_at
       OR NEW.date_of_birth            IS DISTINCT FROM OLD.date_of_birth
    THEN
        FOR v_id IN SELECT video_id FROM video_performers WHERE performer_id = NEW.id
        LOOP
            PERFORM compliance_recompute_video(v_id);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER performers_recompute
    AFTER UPDATE ON performers
    FOR EACH ROW EXECUTE FUNCTION trg_performers_recompute();


-- Recompute when an ID document is accepted, rejected, or expires.
CREATE OR REPLACE FUNCTION trg_identity_documents_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id UUID;
    v_performer UUID := COALESCE(NEW.performer_id, OLD.performer_id);
BEGIN
    FOR v_id IN SELECT video_id FROM video_performers WHERE performer_id = v_performer
    LOOP
        PERFORM compliance_recompute_video(v_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER identity_documents_recompute
    AFTER INSERT OR UPDATE OR DELETE ON performer_identity_documents
    FOR EACH ROW EXECUTE FUNCTION trg_identity_documents_recompute();


-- Recompute when consent is granted or revoked.
CREATE OR REPLACE FUNCTION trg_consent_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM compliance_recompute_video(COALESCE(NEW.video_id, OLD.video_id));
    RETURN NULL;
END;
$$;

CREATE TRIGGER consent_records_recompute
    AFTER INSERT OR UPDATE OR DELETE ON performer_consent_records
    FOR EACH ROW EXECUTE FUNCTION trg_consent_recompute();


-- -----------------------------------------------------------------------------
-- C.1b  Frozen cast list
--
--       The counter-equality test in the Gatekeeper cannot, on its own, stop the
--       most obvious bypass: deleting the unverified co-performer from the
--       record. After such a delete the counters read 1/1/1, which satisfies the
--       CHECK, and the video stays live while still depicting that person.
--
--       The database cannot see who is actually on screen, so it must refuse to
--       let the cast list drift while the depiction is publicly available. To
--       amend the cast, unpublish first — which forces the record back through
--       compliance review.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_video_performers_frozen_when_published()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_status video_status;
    v_video  UUID := COALESCE(NEW.video_id, OLD.video_id);
BEGIN
    SELECT status INTO v_status FROM videos WHERE id = v_video;

    IF v_status = 'published' THEN
        RAISE EXCEPTION
            '2257: the cast list of published video % is frozen (% attempted)',
            v_video, TG_OP
            USING ERRCODE = 'check_violation',
                  HINT = 'Set the video status to unpublished before adding or removing a performer.';
    END IF;

    -- On UPDATE the row may be moving between videos; guard the origin too.
    IF TG_OP = 'UPDATE' AND OLD.video_id IS DISTINCT FROM NEW.video_id THEN
        SELECT status INTO v_status FROM videos WHERE id = OLD.video_id;
        IF v_status = 'published' THEN
            RAISE EXCEPTION
                '2257: the cast list of published video % is frozen', OLD.video_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER video_performers_frozen_when_published
    BEFORE INSERT OR UPDATE OR DELETE ON video_performers
    FOR EACH ROW EXECUTE FUNCTION trg_video_performers_frozen_when_published();


-- -----------------------------------------------------------------------------
-- C.2  Age-at-production enforcement
--
--      The single most important rule in § 2257. Age is evaluated against the
--      production date, never against today: a performer who is 19 now was not
--      necessarily 18 when the scene was shot.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_video_performers_age_check()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_production_date DATE;
    v_dob             DATE;
    v_age             INT;
BEGIN
    SELECT production_date INTO v_production_date FROM videos     WHERE id = NEW.video_id;
    SELECT date_of_birth   INTO v_dob             FROM performers WHERE id = NEW.performer_id;

    IF v_production_date IS NULL THEN
        -- Draft with no production date yet. The Gatekeeper independently
        -- refuses to publish without one, so this is safe to defer.
        NEW.age_at_production := NULL;
        RETURN NEW;
    END IF;

    IF v_production_date > CURRENT_DATE THEN
        RAISE EXCEPTION
            'production_date % for video % is in the future', v_production_date, NEW.video_id
            USING ERRCODE = 'check_violation';
    END IF;

    v_age := date_part('year', age(v_production_date, v_dob))::int;

    IF v_age < 18 THEN
        RAISE EXCEPTION
            '2257 violation: performer % was % on the production date % for video %',
            NEW.performer_id, v_age, v_production_date, NEW.video_id
            USING ERRCODE = 'check_violation',
                  HINT = 'A performer must be at least 18 years old on the date of production.';
    END IF;

    NEW.age_at_production := v_age;
    RETURN NEW;
END;
$$;

CREATE TRIGGER video_performers_age_check
    BEFORE INSERT OR UPDATE OF video_id, performer_id ON video_performers
    FOR EACH ROW EXECUTE FUNCTION trg_video_performers_age_check();


-- Changing a video's production_date must re-run the age check across the whole
-- cast — otherwise a compliant video could be back-dated into non-compliance.
CREATE OR REPLACE FUNCTION trg_videos_production_date_age_check()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    r RECORD;
    v_age INT;
BEGIN
    IF NEW.production_date IS NULL
       OR NEW.production_date IS NOT DISTINCT FROM OLD.production_date THEN
        RETURN NULL;
    END IF;

    FOR r IN
        SELECT vp.id, vp.performer_id, p.date_of_birth
          FROM video_performers vp
          JOIN performers p ON p.id = vp.performer_id
         WHERE vp.video_id = NEW.id
    LOOP
        v_age := date_part('year', age(NEW.production_date, r.date_of_birth))::int;

        IF v_age < 18 THEN
            RAISE EXCEPTION
                '2257 violation: performer % would be % on the new production date % for video %',
                r.performer_id, v_age, NEW.production_date, NEW.id
                USING ERRCODE = 'check_violation';
        END IF;

        UPDATE video_performers SET age_at_production = v_age WHERE id = r.id;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER videos_production_date_age_check
    AFTER UPDATE OF production_date ON videos
    FOR EACH ROW EXECUTE FUNCTION trg_videos_production_date_age_check();


-- -----------------------------------------------------------------------------
-- C.3  § 2257 record retention — block hard deletes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_block_compliance_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        '2257 retention: rows in % may not be deleted (attempted on id %)',
        TG_TABLE_NAME, OLD.id
        USING ERRCODE = 'restrict_violation',
              HINT = 'Compliance records are retained for the statutory period. Use the state/revocation columns instead.';
END;
$$;

CREATE TRIGGER performers_block_delete
    BEFORE DELETE ON performers
    FOR EACH ROW EXECUTE FUNCTION trg_block_compliance_delete();

CREATE TRIGGER identity_documents_block_delete
    BEFORE DELETE ON performer_identity_documents
    FOR EACH ROW EXECUTE FUNCTION trg_block_compliance_delete();

CREATE TRIGGER consent_records_block_delete
    BEFORE DELETE ON performer_consent_records
    FOR EACH ROW EXECUTE FUNCTION trg_block_compliance_delete();

CREATE TRIGGER compliance_audit_block_delete
    BEFORE DELETE ON compliance_audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_block_compliance_delete();


-- -----------------------------------------------------------------------------
-- C.4  Ledger application — atomic balance mutation
--
--      This is where the money race is won. The UPDATE below takes an exclusive
--      row lock on the wallet, so concurrent debits against the same wallet are
--      serialized by Postgres rather than by application-level locking. The
--      resulting balance is stamped into the entry inside that same lock, and
--      wallets_no_overdraft aborts the transaction if the balance would go
--      negative.
--
--      Application code therefore never writes wallet_balance_cents. It inserts
--      a ledger row; the balance is a consequence.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_ledger_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_new_balance money_cents;
    v_frozen      TIMESTAMPTZ;
BEGIN
    -- Single statement: lock, check freeze, apply delta, read back. The row
    -- lock is held for the remainder of the transaction.
    UPDATE wallets
       SET wallet_balance_cents = wallet_balance_cents + NEW.amount_cents,
           version              = version + 1,
           updated_at           = now()
     WHERE id = NEW.wallet_id
    RETURNING wallet_balance_cents, frozen_at
      INTO v_new_balance, v_frozen;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ledger: wallet % does not exist', NEW.wallet_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- A frozen wallet may receive corrective credits but never new debits.
    IF v_frozen IS NOT NULL AND NEW.amount_cents < 0
       AND NEW.entry_type <> 'manual_adjustment' THEN
        RAISE EXCEPTION 'ledger: wallet % is frozen; debits are not permitted', NEW.wallet_id
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.balance_after_cents := v_new_balance;
    RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_entries_apply
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_apply();


-- The journal is append-only. Corrections are new reversing entries, never
-- edits — an edited ledger is not a ledger.
CREATE OR REPLACE FUNCTION trg_ledger_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'ledger_entries is append-only: % rejected on entry %',
        TG_OP, COALESCE(OLD.id, NEW.id)
        USING ERRCODE = 'restrict_violation',
              HINT = 'Issue a reversing entry with reverses_entry_id instead of modifying history.';
END;
$$;

CREATE TRIGGER ledger_entries_immutable
    BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_immutable();


-- -----------------------------------------------------------------------------
-- C.5  Unlocks may only be purchased against published, non-deleted videos.
--      Closes the loop between PART A and PART B: non-compliant content cannot
--      be published, and unpublished content cannot be sold.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_video_unlocks_saleable_check()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_status     video_status;
    v_deleted_at TIMESTAMPTZ;
    v_price      money_cents;
    v_currency   currency_code;
BEGIN
    SELECT status, deleted_at, price_cents, currency
      INTO v_status, v_deleted_at, v_price, v_currency
      FROM videos
     WHERE id = NEW.video_id
       FOR SHARE;   -- pin the video row so it cannot unpublish mid-purchase

    IF v_status <> 'published' OR v_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'video % is not available for purchase (status %)', NEW.video_id, v_status
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.price_cents <> v_price OR NEW.currency <> v_currency THEN
        RAISE EXCEPTION
            'price mismatch for video %: client sent %/%s, catalogue says %/%s',
            NEW.video_id, NEW.price_cents, NEW.currency, v_price, v_currency
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER video_unlocks_saleable_check
    BEFORE INSERT ON video_unlocks
    FOR EACH ROW EXECUTE FUNCTION trg_video_unlocks_saleable_check();


-- =============================================================================
-- PART D — VIEWS
-- =============================================================================

-- Ledger reconciliation. This must return zero rows at all times. Run it as a
-- scheduled invariant check; a non-empty result means the materialized balance
-- has diverged from the journal and payouts should halt.
CREATE VIEW wallet_reconciliation AS
SELECT w.id                              AS wallet_id,
       w.user_id,
       w.wallet_balance_cents            AS materialized_cents,
       COALESCE(SUM(le.amount_cents), 0) AS journal_cents,
       w.wallet_balance_cents - COALESCE(SUM(le.amount_cents), 0) AS drift_cents
  FROM wallets w
  LEFT JOIN ledger_entries le ON le.wallet_id = w.id
 GROUP BY w.id, w.user_id, w.wallet_balance_cents
HAVING w.wallet_balance_cents <> COALESCE(SUM(le.amount_cents), 0);

COMMENT ON VIEW wallet_reconciliation IS
  'INVARIANT: must always be empty. Any row indicates the wallet balance has diverged from the append-only journal.';


-- The § 2257 record-set for a depiction, in the shape an inspection asks for:
-- title, production date and location, custodian, and every performer with
-- their legal name, DOB, aliases, and age at production.
CREATE VIEW compliance_record_set AS
SELECT v.id                       AS video_id,
       v.title,
       v.status,
       v.production_date,
       v.production_city,
       v.production_state_region,
       v.production_country,
       rc.legal_entity_name       AS custodian_entity,
       rc.custodian_full_name,
       p.id                       AS performer_id,
       p.legal_first_name,
       p.legal_middle_name,
       p.legal_last_name,
       p.date_of_birth,
       vp.role,
       vp.age_at_production,
       ca.alias                   AS credited_as,
       (SELECT array_agg(pa.alias ORDER BY pa.alias)
          FROM performer_aliases pa
         WHERE pa.performer_id = p.id)          AS all_known_aliases,
       p.identity_verification_state,
       p.identity_verified_at,
       cr.signed_at               AS consent_signed_at,
       cr.revoked_at              AS consent_revoked_at
  FROM videos v
  JOIN video_performers vp ON vp.video_id = v.id
  JOIN performers p        ON p.id = vp.performer_id
  LEFT JOIN performer_aliases        ca ON ca.id = vp.credited_alias_id
  LEFT JOIN performer_consent_records cr ON cr.id = vp.consent_record_id
  LEFT JOIN records_custodians       rc ON rc.id = v.records_custodian_id;

COMMENT ON VIEW compliance_record_set IS
  'The § 2257 record set for each depiction, indexed by title, legal name, and alias. Restrict access to the compliance role.';


-- =============================================================================
-- PART E — ROLES AND PRIVILEGES
--
--   app_service     — the API. Can move money and read its own data, but cannot
--                     touch the Gatekeeper counters or read raw 2257 PII.
--   compliance_ops  — human reviewers. Read/write 2257 records, no ledger write.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_service') THEN
        CREATE ROLE app_service NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'compliance_ops') THEN
        CREATE ROLE compliance_ops NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO app_service, compliance_ops;

GRANT SELECT, INSERT, UPDATE ON
    users, creator_profiles, videos, wallets, wallet_topups,
    video_unlocks, idempotency_keys, creator_earnings
TO app_service;

-- Append-only from the application's perspective.
GRANT SELECT, INSERT ON ledger_entries      TO app_service;
GRANT SELECT, INSERT ON compliance_audit_log TO app_service;

-- THE COUNTERS ARE NOT APPLICATION-WRITABLE. Only compliance_recompute_video()
-- (SECURITY DEFINER, owned by the schema owner) may change them, which means
-- the only way to move a video toward publishable is to supply real records.
REVOKE UPDATE (compliance_performer_count,
               compliance_verified_count,
               compliance_consent_count,
               compliance_recomputed_at) ON videos FROM app_service;

-- Raw 2257 PII is not readable by the API role.
GRANT SELECT (id, user_id, identity_verification_state, identity_verified_at)
    ON performers TO app_service;

GRANT SELECT, INSERT, UPDATE ON
    performers, performer_aliases, performer_identity_documents,
    video_performers, performer_consent_records, records_custodians
TO compliance_ops;

GRANT SELECT ON videos, compliance_record_set TO compliance_ops;
GRANT SELECT, INSERT ON compliance_audit_log  TO compliance_ops;

GRANT SELECT ON wallet_reconciliation TO app_service;


COMMIT;

-- =============================================================================
-- INVARIANTS THIS SCHEMA GUARANTEES
--
--   1. No video can be 'published' with an unverified, undocumented, or
--      non-consenting performer.                    [videos_2257_publish_gatekeeper]
--   2. No performer under 18 on the production date can be attached to a
--      depiction.                                   [trg_video_performers_age_check]
--   3. Revoking a performer's verification, or a consent record, forces the
--      affected videos out of 'published' or aborts. [compliance_recompute_video]
--   4. 2257 records cannot be hard-deleted.          [trg_block_compliance_delete]
--   5. A user cannot be charged twice for one video. [video_unlocks_one_per_user_video]
--   6. A wallet cannot go negative.                  [wallets_no_overdraft]
--   7. Financial history cannot be rewritten.        [trg_ledger_immutable]
--   8. wallet_balance_cents always equals the journal sum. [wallet_reconciliation]
-- =============================================================================
