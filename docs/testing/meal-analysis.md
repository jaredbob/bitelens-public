# Meal analysis

## Local verification

From the repository root, run the two fixture suites.

```bash
node --test supabase/tests/analyze-meal.test.ts
./scripts/test-core.sh
```

The backend suite needs Node 24 or later and uses the real request handler and
both provider adapters with deterministic Auth and Responses HTTP fixtures. It checks
authorization before body consumption, explicit provider routing, text-only
requests, original capture expiry, request limits, malformed images, the upstream
request contract, refusal, invalid output, and the provider deadline. The beta
checks cover approval, denial and revocation while the caller's token is valid,
shared allowance across providers, and consumed attempts after a provider times
out. No provider or Supabase credentials are needed. The
[disposable Supabase suite](meal-sync.md) checks that only the server can reserve
attempts, concurrent reservations stop at the limit, accounts are independent,
and an allowance rolls over at UTC midnight.

The Swift suite captures into private temporary storage, exercises the production
Edge Function client against an HTTP fixture, reopens the estimate, edits it and
confirms offline through the common review workflow. It covers unknown nutrients,
retry recovery, retained corrections, stale responses, and expiry. A retry
can explicitly choose the other provider without changing the Settings default.
Beta tests cover per-account and per-provider permissions, persistence and
withdrawal, and account changes while analysis prepares a request.

## Edge Function contract

`POST /functions/v1/analyze-meal` accepts a Supabase Auth user bearer token and
the project's public `apikey`. Keep the default gateway JWT verification enabled.
The handler independently asks Supabase Auth for the current user before
consuming the body. The personal deployment checks the configured owner's UUID. BiteLens Beta
checks live account approval through `bitelens_is_approved` with that same user
token. An unapproved beta account receives `403 approval_required`. The
deployment uses `SUPABASE_URL` to select the authorization check for its project.

The JSON body always contains `provider`. For an image, send `captured_at_ms`
(camera shutter, Photos import, or Share Sheet save time as integer Unix
milliseconds), `photo_base64` (one JPEG, up to 4 MiB and 1600 px on each side),
and optional `notes` (up to 2,000 UTF-16 code units). The app makes an oriented
JPEG from pixels in memory, omitting the original photo metadata. The backend
checks age against its own clock and rejects captures at or beyond 168 hours.
The timestamp comes from the app, whose guarded photo read
enforces retention against the immutable local capture or import time.

For a text-only draft, send a nonblank `description` of up to 2,000 UTF-16
code units. Omit `photo_base64`, `captured_at_ms`, and `notes`. A text
estimate has null `image_kind`, `order_time`, and item `purchased_quantity`
values. It can return an empty item list when the description identifies no
food or drink.

Success is an unconfirmed estimate with `items` and `provenance`. Items have
`name`, `description`, nullable `grams` and `count`, `serving_description`,
and nine nullable nutrient fields in `nutrients`. The keys are `calories_kcal`,
`protein_g`, `carbohydrates_g`, `fat_g`, `fiber_g`, `sodium_mg`, `alcohol_g`,
`caffeine_mg`, and `added_sugar_g`. Weight and nutrient amounts describe the
entire item. Both providers return every key and use null for unknown amounts
or a count that does not apply. V3 adds `image_kind`, nullable `order_time`
in `YYYY-MM-DDTHH:mm` or `HH:mm` local time with an optional explicit UTC offset, and
nullable `purchased_quantity` on each item. A known Purchased Quantity matches
the suggested count and stays in the draft. A readable receipt timestamp can
still be suggested when no items are identifiable. A time without a date uses
the import day. The app also accepts v1 and
v2 responses. The server adds the selected provider, response-reported model,
and schema and adapter version. The phone assigns item IDs when saving the estimate.

Errors return a status and a short error code. The app keeps the saved draft on
authorization, validation, provider, and timeout failures and offers another
attempt or manual entry. After approval and input validation, BiteLens Beta
reserves one attempt in Postgres immediately before calling the provider. The
reservation rechecks approval and the photo deadline. OpenAI and Grok share
the same per-account allowance, and a provider timeout still uses the attempt.
If the photo expires while the reservation is in flight, the function returns
`410` without calling the provider. It sends a refund and retries once with
the same reservation ID if necessary. If the reservation commits but its
response is lost, the function has no ID to refund. The attempt may still
count in that case or if neither refund call reaches the database. An
exhausted allowance returns `429` with
`{"error":"allowance_exhausted","reset_at":"2027-01-16T00:00:00.000Z"}`. The app
shows the UTC reset in local time. Manual entry and sync stay available.

Responses are marked `Cache-Control: no-store`. The function uses memory for
meal content and the result. The allowance table records only the account ID,
UTC date, and attempt count. The private photo reservation table keeps a random
ID with its account and UTC date for refund retries. A successful refund removes
that ID, and later photo reservations prune IDs older than the previous UTC day
for the account. OpenAI rejection diagnostics record the HTTP
status and known error labels. They exclude request content, provider error
messages, and credentials.

## Hosted setup

Apply the migrations for the intended variant using
[Supabase setup](../supabase-migrations.md). Set the following values in the
project's Edge Function environment.

- Personal deployment. Set `BITELENS_DEPLOYMENT=personal` and `BITELENS_OWNER_ID`
  to the Auth user UUID registered in the personal database.
- Beta deployment. Set `BITELENS_DEPLOYMENT=beta`. The optional
  `BITELENS_MEAL_ESTIMATE_DAILY_LIMIT` defaults to 10 requests per account
  per UTC day across the two providers.
- Enable OpenAI with `BITELENS_OPENAI_API_KEY` and `BITELENS_OPENAI_MODEL`.
  Enable Grok with `BITELENS_GROK_API_KEY` and `BITELENS_GROK_MODEL`.
  Choose models that support image input and structured output.
  Store the provider keys in the Edge Function environment.

From the repository root, deploy with Supabase CLI v3 and keep JWT verification
enabled.

```sh
supabase functions deploy analyze-meal --remote=YOUR_PROJECT_REF --use-api
```

Use the [provider evaluation checklist](provider-evaluation.md) to verify both
adapters with synthetic inputs.
