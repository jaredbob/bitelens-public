# BiteLens design

This document records the accepted v1 design and subsequent design decisions.
See [workflow integration](workflow-integration.md) for the current behavior.

## Confirmed requirements

- BiteLens is a personal iPhone app restricted to its owner's account.
- Meal ownership uses the existing email-based Supabase account that owns the
  health data. BiteLens offers sign-in without a public signup flow and enforces
  access through its own owner-specific rules. Shared project signup settings
  are left unchanged.
- The app will be native, using SwiftUI and Apple's camera APIs.
- V1 targets iOS 18 or newer and includes a Lock Screen/Control Center action
  opening the camera after device authentication.
- One-time setup signs into the existing email account and lets the owner choose
  the initial AI provider. The session and provider selection are remembered.
- Opening the app goes directly to the camera, with no menus or required typing
  before capture after setup. Unlocking before opening the camera is acceptable.
- V1 uses one photo per meal, with retakes available before analysis. A photo
  can contain multiple Meal Items, and further details can be entered manually.
- Photos can be captured offline and kept as Meal Drafts. Analysis resumes when
  BiteLens is open and online.
- Cloud AI describes the food and drink and estimates portions and nutrients.
  These are editable estimates suitable for everyday personal food tracking.
- V1 obtains nutrient estimates directly from the AI provider; a separate
  food-composition database is deferred. OpenAI and Grok must be easy to switch
  between. Provider changes are explicit in Settings or when retrying an
  analysis, apply to new analyses, and do not rewrite past meal records. There
  is no automatic fallback to another provider.
- Optional notes can supply ingredients or serving details before analysis or
  retry. There are no mandatory AI follow-up questions.
- Failed or timed-out analysis preserves the draft and existing edits, offering
  retry, an explicitly selected alternative provider, or manual entry.
- The user reviews and confirms the contents, Consumed Portions, and nutrients
  before a draft becomes a Logged Meal. A Meal includes snacks and drinks.
- Nutrients include calories, protein, carbohydrates, fat, fiber, sodium,
  alcohol, caffeine, and added sugar, with per-item values and meal totals.
  Show the new amounts in item review, meal details, and daily totals. Keep
  history rows compact.
  Alcohol, caffeine, and added sugar are unknown for older records that did not
  track them. Saturated fat and potassium are deferred.
- Consumed Portions use estimated grams and familiar serving descriptions, with
  an optional Consumed Count for interchangeable pieces. Weight and nutrients
  describe the whole Meal Item. Foods that need separate review remain separate
  items. Existing items are not merged automatically.
- Calories are displayed in kcal, sodium and caffeine in milligrams, and other
  tracked nutrients in grams. Alcohol means grams of pure alcohol; standard
  drinks can be derived from that amount.
- Changing an item's consumed weight scales its known nutrient values.
  A Consumed Count can be fractional. Changing one known count to another scales
  the item's known weight and nutrients by the same ratio. Adding the first
  count preserves the existing amounts. The owner can edit weight and nutrient
  amounts directly.
- Incomplete Estimates may be confirmed. Unknown values are preserved, and
  dependent meal and daily totals are clearly marked incomplete.
- Meal time defaults to capture time and is editable. Each meal retains its
  local date and time zone for daily totals, including during travel.
- Meal history and daily nutrient totals support editing and deletion; edits
  update the totals.
- Meal Photos are kept only inside BiteLens for the past seven days. BiteLens
  does not save them in the Photos library or Supabase Storage.
- Photos expire 168 hours after capture. They become unavailable in the app at
  expiry and are physically deleted whenever the app next gets execution time.
  Edits do not extend retention. Backup exclusion is requested, with iOS's
  documented limitations accepted.
- Cloud analysis is permitted. OpenAI's default API retention policy is accepted,
  including possible content retention for up to 30 days subject to documented
  exceptions, with saved responses disabled. Grok's standard API retention
  policy is also accepted, normally 30 days for abuse auditing subject to
  documented exceptions, with saved response history disabled. Zero Data
  Retention is not required for Grok.
- Meal Drafts and unconfirmed textual estimates remain on the phone. Confirmed
  structured meals sync to Supabase.
- Confirmed structured meal records belong in dedicated meal tables in the
  existing Supabase project containing Apple Health and other health data.
- Structured meal records remain until explicitly deleted, even after their
  photos expire.
- An already analyzed meal can be confirmed offline. It appears immediately in
  local history and totals with pending sync status, then syncs when BiteLens is
  open and online.
- Supabase records when it first saves a Logged Meal and when it accepts a new
  revision, including an item-only edit. Replaying an identical revision does
  not change these times. Meal time and confirmation time are separate.
  Missing legacy server timestamps use confirmation time as a fallback. New
  deletion records carry the time the server first accepted the deletion.
- Photo expiry also applies to unanalyzed Meal Drafts. After expiry, manual
  entry or discarding the draft is available; existing textual estimates remain.
- Apple Health Sync is opt-in. The iPhone exports complete, authorized nutrient
  totals and alcohol intake for eligible meals independently of Supabase uploads.
  Meals become eligible at confirmation while sync is on or through an explicit
  Apple Health Backfill in Settings.
- Ongoing personal installation is planned through Xcode with a paid Apple
  Developer account. This is a distribution decision, not a membership purchase.
- Initial AI usage targets are $5 per month combined across providers and
  10-20 seconds per analysis, with the photo saved immediately. These targets
  need measurement with real meal photos and the selected models.
- Both AI providers run through an authenticated Supabase Edge Function and
  return the same Meal Estimate format. Credentials stay server-side, and each
  estimate records its provider and model.

## Decision tree

- Personal access
  - Settled: only the owner's account can use the app.
  - Settled: reuse the existing email-based Supabase account; no public signup
    flow in BiteLens.
  - Settled: BiteLens-specific access rules; shared project signup settings remain
    unchanged.
  - Settled: one-time email sign-in and initial provider selection, with the
    session and selection remembered.
  - Implementation verification: existing email sign-in configuration.
  - Settled: direct Xcode installation with a paid developer account.
- Capture
  - Settled: camera first, after unlocking; offline capture is supported.
  - Settled: native SwiftUI and Apple camera APIs.
  - Settled: iOS 18+ with a Lock Screen/Control Center launch action after unlock.
  - Implementation verification: actual device and Xcode compatibility.
  - Settled: one photo per meal with retakes before analysis.
- Photo lifecycle
  - Settled: seven days of local photo history, with no Photos-library or
    Supabase photo copies.
  - Settled: OpenAI and Grok standard API retention policies are accepted;
    Grok ZDR is optional. Saved response history is disabled for both providers.
  - Settled: 168-hour expiry from capture, access cutoff, and physical deletion
    when the app can next execute; device-backup limitations are accepted.
  - Settled: expiry applies to unanalyzed drafts, with manual entry or discard
    afterward; existing text estimates remain available.
- Estimation and review
  - Settled: approximate, editable food, portion, and nutrient estimates;
    confirmation is required before logging.
  - Settled: easy switching between OpenAI and Grok; direct AI nutrient estimates;
    grams plus serving descriptions; unknown values remain unknown.
  - Settled: explicit provider changes for new analyses; no automatic fallback;
    past meal values remain unchanged.
  - Settled: initial provider chosen during setup; the session and selection
    persist.
  - Settled: optional notes, no mandatory follow-up questions, and draft-preserving
    retry/provider selection/manual entry on failure.
  - Settled: proportional nutrient scaling for weight edits, with direct nutrient
    editing available.
  - Settled: one server-side provider interface, shared Meal Estimate format,
    and provider/model provenance.
  - Settled: optional Consumed Count, with whole-item weights and nutrients;
    scale known amounts on count edits. Cross-meal food rankings are deferred.
  - Settled: track alcohol, caffeine, and added sugar as nullable values in
    item review, meal details, and daily totals.
  - Settled: retain the Original Item Estimate for AI-derived items in a Logged
    Meal. An item is corrected while its current values differ from the
    original. Item provenance stays unknown when it cannot be verified.
  - Settled: $5/month combined usage target and 10-20-second analysis target.
  - Implementation verification: model choice and measured cost/latency.
- Meal record
  - Settled: history, daily totals, editing, and deletion.
  - Settled: structured records remain until explicitly deleted.
  - Settled: editable capture-based time, recorded local date/time zone for daily
    totals, and offline confirmation followed by foreground online sync.
  - Settled: unconfirmed structured estimates stay on the device.
  - Settled: server creation and update times describe the whole Logged Meal.
    Downstream sync can detect new and edited meals. Privileged database readers
    can also detect recent deletions through the private deletion records.
    Mirroring deletions in downstream systems is deferred.
- Existing health-data project
  - Settled: reuse the existing Supabase project with dedicated meal tables.
  - Verified: existing schema and ownership conventions are documented below.
  - The initial scope covered sharing the Supabase project. Apple Health Sync
    exports from the iPhone as described in
    [ADR 0005](adr/0005-export-nutrient-totals-from-the-iphone.md).
  - Settled: use the existing email-based Supabase identity for meal ownership.

## Workflow

1. Complete one-time email sign-in and select the initial provider.
2. Launch BiteLens directly or through its system action, unlock if needed,
   and capture a photo. Save the photo locally immediately.
3. Keep offline captures as Meal Drafts; start analysis when the app is open,
   online, and authenticated. Optional notes can accompany the photo.
4. Send the photo through the Edge Function to the explicitly selected provider.
   Validate and return a shared Meal Estimate without persisting the draft on
   the backend.
5. Review food identities, Consumed Portions, and nutrients; make corrections
   or use manual entry. Unknown values remain unknown.
6. Confirm to create a Logged Meal in local history and daily totals. Queue
   structured data for Supabase when offline and show its pending sync state.
7. Sync confirmed creates, edits, and deletions when the app is open and online.
   Retries must not produce duplicate meals.
8. Expire photo access after 168 hours and delete expired files whenever the app
   next has execution time. Keep structured meal history until explicitly deleted.

## Architecture

- **iPhone app:** SwiftUI and Apple camera APIs; private photo files separate
  from structured local data; durable drafts, confirmed meals, and pending sync
  operations; history, daily totals, review/editing, and provider settings.
- **AI interface:** a user-authenticated Supabase Edge Function checks the
  approved owner's identity and dispatches to an OpenAI or Grok adapter. Both
  adapters validate and normalize output into the same Meal Estimate format.
  Credentials and per-provider model configuration remain on the server.
- **Persistence:** dedicated meal and Meal Item tables in the configured Supabase project,
  with the existing Supabase user UUID as owner. Apply explicit operation grants
  and owner-specific RLS. Save confirmed descriptions, portions, nutrients,
  notes, meal timing, and estimate provenance; leave existing health tables and
  shared signup settings unchanged.
- **Photo handling:** use app-private files with device protection and requested
  backup exclusion. Do not save images in Photos, Supabase Storage, structured
  database fields, pending sync payloads, or application logs. Transmit image
  bytes only for the selected provider's analysis under its accepted policy.
- **Estimate provenance:** retain provider/model and estimate version metadata
  with the structured result. Retain the Original Item Estimate for AI-derived
  items in a Logged Meal and distinguish untouched, corrected, and manually
  added items. Manual items do not claim an AI provider. Do not store a model
  confidence score. See [ADR 0003](adr/0003-retain-original-item-estimates.md).

## Implementation checks

These are setup and verification work, not unresolved product choices:

- Establish a usable Xcode/iOS SDK installation, verify the actual phone's
  compatibility, and configure paid-team signing.
- Verify the existing email sign-in and delivery configuration. Reuse the
  existing account and avoid signup or changes that disrupt other apps.
- Configure provider credentials securely and select compatible image-input,
  structured-output models through backend configuration.
- Measure estimation usefulness, latency, and cost against real meal photos;
  the $5/month and 10-20-second figures are targets to validate.
- Check photo expiry independently of edits to meal time, offline confirmation
  and sync retries, unknown-value propagation, proportional portion corrections,
  daily grouping during travel, and denial of access by unapproved users.

## Related documents

- [Implementation specification](spec.md)
- [Glossary](../GLOSSARY.md)
- [Keep meal photos in short-lived local storage](adr/0001-keep-meal-photos-local.md)
- [Normalize estimates behind a server-side provider interface](adr/0002-normalize-ai-provider-estimates.md)
- [Retain original item estimates for confirmed meals](adr/0003-retain-original-item-estimates.md)
