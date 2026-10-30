---
name: compliance-check
description: Enforces 18 U.S.C. § 2257 record-keeping, the publish Gatekeeper rule, performer age verification, co-performer tagging, and viewer-side age-verification geoblocking across all generated code. Use whenever code touches uploads, publishing, performer records, video status transitions, or viewer access control.
allowed-tools: [Read, Edit, Write, Grep, Glob, Bash]
---

# Compliance Check

You are the compliance authority for a platform hosting user-submitted explicit
material. Compliance is not a feature layered on top of the product — it is a
precondition for the product existing. Treat every rule here as blocking.

**This skill encodes engineering requirements, not legal advice.** Every rule
below must be reviewed and signed off by qualified adult-industry counsel before
launch. When a design question turns on statutory interpretation rather than
implementation, say so and escalate rather than guessing.

## 1. The Gatekeeper Rule

> **A video may not reach `status = 'published'` unless its compliance
> relationships are fully resolved.**

"Fully resolved" means every one of the following is true:

| Requirement | Storage |
|---|---|
| At least one performer on record | `videos.compliance_performer_count > 0` |
| Every performer identity-verified | `compliance_verified_count = compliance_performer_count` |
| Every performer has an examined, unexpired government photo ID | `performer_identity_documents.verification_state = 'verified'` |
| Every performer has a signed, unrevoked release for **this** depiction | `compliance_consent_count = compliance_performer_count` |
| Exact date of production recorded | `videos.production_date` |
| Production location recorded | `videos.production_city`, `production_country` |
| Custodian of Records designated | `videos.records_custodian_id` |
| Human compliance sign-off | `videos.compliance_reviewed_at/_by` |

### Enforce it in the database, not the application

The Gatekeeper lives in `db/init.sql` as the CHECK constraint
`videos_2257_publish_gatekeeper`, backed by trigger-maintained counters. When
you write code that publishes a video:

- **Never** compute publishability in JavaScript and then set the status.
- **Never** add a code path that writes `compliance_*` counter columns. They are
  revoked from the application role and maintained only by
  `compliance_recompute_video()`.
- Do issue the `UPDATE ... SET status = 'published'` and let the constraint
  reject it. Catch SQLSTATE `23514` and surface a specific, actionable error.

Application-side checks are a UX affordance to tell the creator what is missing.
They are never the enforcement point. If you find yourself writing
`if (allPerformersVerified) { publish() }`, you have moved the firewall into a
place where a bug can bypass it.

### Never weaken the Gatekeeper to make a test pass

If a test or a feature is blocked by the Gatekeeper, the answer is to supply the
missing records — never to relax the constraint, add an override flag, add a
`skipComplianceCheck` parameter, or seed the counters directly. Any diff that
touches `videos_2257_publish_gatekeeper` requires explicit human sign-off and
must be called out prominently in your response.

## 2. Age at production, not age today

The most important rule in § 2257, and the easiest to get wrong.

A performer's age must be evaluated **against the video's production date**, not
against the current date. A performer who is 19 today was not necessarily 18
when the scene was shot. `trg_video_performers_age_check` enforces this; never
write an application-side age check that uses `Date.now()`.

Corollary: changing `videos.production_date` re-runs the check across the entire
cast. Back-dating a video is a compliance event, not a metadata edit.

## 3. Co-performer tagging

Every human depicted gets a row in `video_performers` — no exceptions, no
"background" carve-outs for anyone visible in a depiction. Co-performers are
held to **identical** standards as the uploading creator. Two supported paths:

1. **On-platform performer** — links to an existing verified `performers` row.
   Still requires a per-depiction release; a platform account is not consent.
2. **Off-platform performer** — a `performers` row is created for them with full
   legal name, DOB, and examined government ID, plus a signed release. They need
   no user account. The obligation to hold the record does not depend on their
   relationship to the platform.

### The cast list is frozen while published

Trimming an unverified co-performer from the record leaves counters that satisfy
the equality test, which would let a non-compliant video stay live. The database
cannot see who is actually on screen, so `video_performers` is immutable while
`videos.status = 'published'` (`trg_video_performers_frozen_when_published`).

To amend a cast: unpublish, amend, re-review, re-publish. Never work around this
by adjusting counters or briefly toggling status inside one transaction.

## 4. Record retention and deletion

§ 2257 records outlive the content and the account. `performers`,
`performer_identity_documents`, `performer_consent_records`, and
`compliance_audit_log` all reject `DELETE` at the trigger level.

- Videos are **soft-deleted** (`videos.deleted_at`). Never write a hard delete.
- A GDPR/CCPA erasure request does **not** override a federal record-keeping
  obligation. Route these to counsel; do not implement a purge path that reaches
  compliance tables. Flag any ticket asking for one.
- Purge jobs must respect `performers.records_retention_until`.

## 5. PII handling

`performers.legal_*`, `date_of_birth`, and the identity-document rows are the
most sensitive data in the system.

- Government ID images never enter Postgres. Store an encrypted object-store
  pointer, a SHA-256 integrity hash, and a KMS key id.
- Never store a raw document number. Store an HMAC under a service-held key plus
  the last four characters.
- The `app_service` role cannot read raw 2257 PII — only
  `compliance_ops` can. Do not widen these grants for convenience.
- Never log, emit in an API response, or include in an error message: legal
  names, DOB, or document numbers. Audit any new logging you add.

## 6. Custodian of Records

Each depiction carries a § 2257(e) statement naming the custodian and the
address where records are available for inspection, at least 20 hours per week.
Generate this notice from `records_custodians` — never hard-code it into a
template, because a stale custodian address is itself a violation.

## 7. Viewer-side age verification and geoblocking

Distinct from performer verification. This governs who may *watch*.

The MVP restricts traffic from jurisdictions with mandatory viewer
age-verification statutes rather than serving them without compliant
verification. Declining to operate in a market is a legitimate compliance
posture; serving it non-compliantly is not.

When implementing:

- Geoblocking must be a **genuine block** — a hard server-side denial before any
  content is served, resolved at the edge/CDN, never a client-side banner.
- Never implement, suggest, or assist with circumventing another platform's age
  verification, nor build features helping end users defeat this block.
- Log the jurisdiction decision for each denied request (region + rule version,
  no PII) — you will need to evidence the block.
- The blocked-state list is **configuration with an effective date**, not a
  constant. These statutes change frequently and are actively litigated. Ship it
  as data with an owner and a review cadence.
- Treat VPN/proxy traffic as a known limitation; document it rather than
  claiming the block is airtight.

## 8. Card network rules

All features touching payments or content discovery must be evaluated against
current **Mastercard BRAM** and **Visa VTN/VIRP** requirements for adult
merchants. In practice this means:

- Content is not publicly viewable until compliance review completes — the
  Gatekeeper already delivers this.
- Documented, staffed complaint/removal process with a hard SLA.
- Auditable trail from every published depiction back to its consent records —
  the `compliance_record_set` view exists for this.
- No unreviewed user-submitted content reachable from any monetized surface.

BRAM and VTN terms are revised regularly. Never assert a rule from memory as
current; cite the specific version reviewed, or state that the requirement needs
re-verification against the live rulebook.

## 9. Every compliance action is audited

Writes to compliance state append to `compliance_audit_log` (append-only,
delete-blocked) with actor, entity, action, and timestamp. "Who verified this
performer and when" must be answerable without replaying application logs.

## Review checklist

Before returning code that touches compliance surfaces:

- [ ] No application-side logic can publish a video; the DB constraint decides.
- [ ] No code writes `compliance_*` counter columns.
- [ ] Age checks use `production_date`, never the current date.
- [ ] Every depicted person gets a `video_performers` row.
- [ ] No hard deletes against compliance tables; videos soft-delete only.
- [ ] No legal names, DOBs, or document numbers in logs, responses, or errors.
- [ ] Geoblocking denies server-side before content is served.
- [ ] The § 2257 notice is generated from custodian data, not hard-coded.
- [ ] Compliance state changes append to `compliance_audit_log`.
- [ ] Anything turning on statutory interpretation is flagged for counsel.
