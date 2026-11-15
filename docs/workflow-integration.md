# Meal workflow integration

`MealWorkflow` in `Sources/BiteLensCore/MealWorkflow.swift` is the public feature boundary.
It is `@MainActor` and `@Observable`; SwiftUI observes it directly. Capture, durable drafts,
and local photo retention extend that boundary in `MealDraft.swift`. Review, confirmation,
history, and the pending change outbox extend it in `MealReview.swift`. Only an explicit
confirmation moves a Meal Draft into Logged Meal history.

Current actions:

| Action | Observable result |
| --- | --- |
| `restoreSession()` | Reads the secure saved identity without waiting for the network. |
| `signIn(email:password:)` | Existing-account password sign-in; authorizes only the trusted Auth UUID. |
| `selectProvider(_:)` | Explicit OpenAI/Grok selection, persisted for future analyses. |
| `accessToken()` | Returns a current owner token, refreshing/coalescing as required. |
| `signOut()` | Removes credentials locally, then best-effort revokes this session only. |
| `resumeLocalWork()` | Reloads owner-visible meals and drafts and deletes expired/orphan photo files without network access. |
| `waitForPhotoExpiry(at:)` | The active scene waits for the next draft or logged photo deadline, then runs local cleanup. |
| `captureMeal(photoData:capturedAt:timeZone:)` | Atomically saves a new local Meal Draft and its private photo. Returns the saved draft. |
| `updateDraftNotes(_:notes:)` | Durably updates optional context; empty notes are valid. |
| `setMealTime(_:instant:timeZone:)` | Saves chosen meal instant, Gregorian local date, and time-zone identity. |
| `retakePhoto(for:photoData:capturedAt:)` | Before the first successful estimate, replaces the selected photo with a new immutable capture time, preserving draft identity, notes, and chosen meal time. |
| `photoData(for:)` | Owner-only photo read for preview or future analysis; throws `photoExpired` at the 168-hour cutoff. |
| `discardDraft(_:)` | Durably removes the draft and deletes its photo; foreground maintenance retries orphan cleanup if interrupted. |
| `updateDraftItems(_:items:)` | Durably replaces the reviewed item list and retains estimate provenance while at least one originating item ID survives. |
| `analyzeDraft(_:provider:)` | Analyzes the saved photo through the explicitly selected provider and saves a current result to the unconfirmed draft. |
| `applyEstimate(_:to:)` | Validates and saves a normalized `MealEstimate` to an unconfirmed draft. |
| `confirmMeal(_:)` | Removes the draft, adds its Logged Meal to local history, and queues one pending create in a single commit. Works offline. |
| `updateLoggedMeal(_:mealTime:notes:items:)` | Edits the meal and totals immediately; keeps the original photo and provenance. |
| `deleteLoggedMeal(_:)` | Removes the meal from history, queues its deletion, and removes its local photo. |
| `syncPendingMealChanges()` | Sends confirmed snapshots and deletions, then durably acknowledges accepted revisions. |
| `photoData(forLoggedMeal:)` | Uses the same expiry guard for a Logged Meal's original photo. |

`access` is signed out, owner, or denied. `selectedProvider` is initially nil; there is no
automatic default or fallback. `cloudStatus` distinguishes ready, refresh required,
offline, and reauthentication required. A restored owner remains authorized for local
features when cloud credentials expire; refresh failures and reauthentication never
clear provider preferences or local meal storage. Explicit sign-out does not delete local
meal data either. Pending sign-in/refresh results cannot undo a newer sign-out.

Use `access == .owner` to guard local meal actions. Use `accessToken()` for analysis and
sync, and the explicit `selectedProvider` for the next analysis. **Every server interface
must independently enforce the approved owner's Auth UUID.** A modified client can bypass
any local UI check. Do not authorize from client-editable user metadata.

Dependencies are narrow external boundaries: `AuthenticationClient`, `SessionStore`,
`ProviderPreferences`, a clock closure, and concrete `LocalMealDraftStorage`. Production uses `SupabaseAuthenticationClient`,
`KeychainSessionStore`, and `UserDefaultsProviderPreferences`. Core tests substitute only
external Auth/storage/time boundaries, exercise actual temporary files and UserDefaults,
and reopen the feature to verify persistence. The Keychain adapter compiles on macOS but
its device behavior remains part of physical-device acceptance.

`App/BiteLens/AppConfiguration.swift` holds only public configuration and the approved
owner UUID. AI keys, privileged Supabase keys, provider models, and provider adapters
belong on the server and are intentionally absent from this app. No analysis/data schema
is introduced by the onboarding ticket.

`drafts` is an observable collection, empty for signed-out or denied access. A UI resumes a
pending draft by selecting its stable ID from this collection; navigation itself has no persisted
side effects. Capture/retake accept an optional native shutter timestamp, defaulting to the
controlled workflow clock. Future capture times and already-expired deliveries are rejected.
`MealPhoto.capturedAt` cannot be edited. Only an explicit retake replaces the photo identity.
`MealTime` stores the chosen calendar date and zone instead of recomputing them in the current zone.

Production stores structured local work in `drafts.json` in private Application Support/BiteLens.
The installed #3 draft array opens in place. The first successful mutation writes the combined
record and outbox format atomically at the same path. Image bytes live in the `photos` subdirectory,
and local records reference opaque photo IDs. A new photo is written before its records commit.
A failed commit preserves the previous selected photo. Launch, foreground resume, unlock,
and guarded reads perform retention maintenance. The active scene schedules cleanup at
the nearest photo expiration, even while the camera or meal history is open.
Cleanup also runs signed out without exposing drafts. Parse failures block overwriting records.
Files request complete iOS Data Protection, directories are mode 0700, and files are mode 0600.
Both the photo directory and each written photo request backup exclusion. Structured records
are independent of photo cleanup and are not excluded from backup by this photo policy.

Analysis reads use `photoData(for:)` at execution time, including retries. Discard image data
after the request. A visible preview clears its UIImage at the deadline and when inactive.
Preview resumes through the relevant guarded read. Retention cleanup considers both draft
and confirmed photo references. Their deadline is always 168 hours after original capture.

### Confirmed meal sync

`loggedMeals` and `dailyMealSummaries` reflect local confirmation, editing, and
deletion immediately. Daily totals group by the recorded `MealTime.localDate`.
Each nutrient has an independent completeness flag: `nil` means no item has a
known amount, and zero is valid.

`pendingMealChanges` stores the latest intended change per meal. A save has a
full photo-free `MealRecord`; a deletion has only the stable meal ID, approved
owner UUID, and revision. The previous app's pending creates open at revision 1.
Each edit or deletion increments the revision. A deleted meal leaves history
immediately; a pending deletion count stays visible until acknowledgement.

When BiteLens is active and online, `syncPendingMealChanges()` drains the outbox
and retries every 15 seconds while pending changes remain. It refreshes the
access token and retries once after a 401 while the change remains current.
Changes superseded while awaiting a token stay queued at their newest revision
for the next drain. An acknowledgement removes only the
matching change from the current library. A delayed response cannot clear a
newer correction. Interrupted responses or local writes leave the change
eligible for replay.

`SupabaseMealSyncClient` uses the authenticated `bitelens_sync_meal` RPC.
See [the API and test instructions](testing/meal-sync.md).

### Analysis and portions

Analysis captures the selected provider, current photo, and notes when an attempt
starts. An explicit retry override takes precedence over Settings for that attempt. It rechecks owner access and the draft after obtaining a token, and uses
the guarded photo read for each attempt. An asynchronous result applies only
while the same draft, photo, notes, review, and owner session remain current.
A successful result uses the same local review and confirmation as manual entry.
See [the analysis function contract and testing guide](testing/meal-analysis.md).

`MealItem.portion.grams` and each value of `NutrientAmounts` are optional and accept a
known zero. The consumed portion also keeps a familiar serving description. Changing
`MealItem.portion.grams` scales known nutrients from their last positive reference
weight. With no usable reference, values stay as entered. Clearing the weight leaves
the amounts visible. Entering zero with a usable reference scales the known amounts
to zero, while retaining the reference for later corrections. Unknown amounts stay
unknown.

`MealItem.portion.count` is optional and accepts positive fractions. Replacing
one known count with another scales the item's known weight and nutrients.
Adding a first count leaves those amounts as entered.

`setNutrientAmount(_:for:)` applies a direct correction at the current weight.
Each correction replaces only that nutrient's reference. Local records retain the
references across reopen, and existing items establish them when first edited.
Persist corrected items through `updateDraftItems(_:items:)` with their existing IDs.
This updates draft totals without analysis. Confirmation uses the reviewed amounts
for logged meal and daily totals. For AI items, the workflow retains the
original estimate and uses it to identify corrections to the current values.
Sync includes both sets of structured values after confirmation.
