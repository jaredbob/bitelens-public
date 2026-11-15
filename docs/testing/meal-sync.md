# Confirmed meal sync

The app sends a change to `POST /rest/v1/rpc/bitelens_sync_meal` with the
public project key and the signed-in account's token. The body includes
`p_meal_id`, `p_user_id`, `p_revision`, and `p_meal` (a complete confirmed
snapshot or null for a deletion). The RPC returns the accepted ID and revision
only after the transaction succeeds. The older `bitelens_create_meal` RPC
uses the same writer at revision 1.

The wire snapshot contains the meal ID, owner UUID, meal and confirmation
instants as Unix seconds, the recorded local date and time-zone identifier,
notes, and optional estimate provider/model/version. Each item carries a
stable ID, name, description, serving description, optional consumed grams and
count, and optional nutrient amounts. The new nutrient keys are `alcohol_grams`,
`caffeine_milligrams`, and `added_sugar_grams`. Amounts describe the entire item.
`item_origin` is `ai`, `manual`, or absent for unknown historical provenance.
AI items also send `original_item_estimate`, an immutable copy of the original
item values. The database compares it with the current values to derive
`is_corrected`. Older queued snapshots can still omit all the new keys.
The payload derives from `MealRecord`, whose photo is stored separately.
The RPC validates the supported field names and derives row ownership
and each item's parent from the authenticated request.

The authenticated owner can query `bitelens_meals` with embedded
`bitelens_meal_items` through the Data API. Both tables grant SELECT to
authenticated clients and use RLS to require row ownership and current approval.
BiteLens Beta reads approval from the administrator's list on each request.
The personal deployment uses the single-owner policy. A composite foreign
key binds each item's owner to its parent.
The public RPC calls a narrowly scoped writer in the unexposed
`bitelens_private` schema. It validates the caller and serializes requests by
meal ID, including before the first write. Each PostgREST request commits as
a unit. [Supabase Data API grants](https://supabase.com/docs/guides/api/securing-your-api)
and [PostgREST transactions](https://docs.postgrest.org/en/stable/references/transactions.html).

The parent row holds the revision and a snapshot digest. A newer snapshot
replaces the full ordered item set in the same transaction. A lost response
can be retried with the exact same revision and snapshot. A stale revision
or conflicting payload is rejected. Deletion removes the meal and its items
and retains a private tombstone with the meal UUID, owner, revision, and
`deleted_at`. The database sets `deleted_at` when it first accepts a deletion.
Identical retries preserve the timestamp, and tombstones created before this
column have an unknown deletion time. The tombstone also prevents a delayed
create from restoring a meal deleted before its first upload. Edits preserve
existing confirmation and estimate provenance.

`created_at` and `updated_at` are required and default to the current database
time. The first successful save sets both, a newer revision updates `updated_at`,
and an identical retry keeps both intact. The timestamp migration fills only
missing legacy values from `confirmed_at`. See the [backfill decision](../adr/0004-backfill-meal-sync-timestamps.md).

For incremental reads, start with a full import and poll `updated_at` with an
overlapping time window, ordered by `updated_at` and `id`. Deduplicate by meal ID
and revision. Privileged SQL readers can poll the private tombstone table the
same way using `deleted_at` and `id`. Timestamps describe writes, which can
become visible in a different order across meals if transactions overlap.

## Automated checks

Run `scripts/test-core.sh` for the workflow's offline confirmation, restart,
lost response, token refresh, revision races, and photo-free wire contract checks.

Apply the BiteLens migrations in timestamp order from `supabase/migrations` to
a disposable Supabase project on loopback. Then pass a private file containing the CLI stack status JSON to
the public interface suite. The file's `env` object supplies the local API and
database endpoints and keys. If using a named native stack, obtain it with
`supabase stack status --stack <name> --output-format json` and redirect output
to a file with mode 0600.

```sh
python3 supabase/tests/meal-sync.py /path/to/local-stack-status.json --beta
```

The suite provisions and removes local Auth users and approvals. The beta run
covers two approved accounts logging the same dinner independently, a signed-in
unapproved account, and revocation and reinstatement with the same token. It
checks readback through a fresh login, concurrent retries, edit-before-create,
item replacement and rollback, deletion replay, tombstones, cross-account
denials, and attempted photo fields. It also covers grouped counts, nutrient
and estimate readback, and server timestamps on accepted edits and identical
retries. Omit `--beta` on a stack with the original single-owner migrations.
Run the suites sequentially because one fixture uses the same synthetic owner UUID.

## Deployment and iPhone acceptance

Apply the migrations for the intended variant using
[Supabase setup](../supabase-migrations.md). Keep the hosted account and test
records separate from personal data.

After applying the timestamp migration, run a full reconciliation for any
reader that already saved a checkpoint, then resume incremental polling. The
backfilled timestamps can predate an existing checkpoint.

1. Sign in on iPhone, go offline, and confirm a meal with at least two items,
   one known zero, and one blank nutrient. History and totals should update
   immediately and the meal should show **Pending sync**.
2. Force-quit and reopen offline. Check the meal and pending badge again.
3. Restore connectivity with BiteLens active. Wait for **Synced**, then reopen
   the app and check that the badge persists.
4. With the owner's authenticated Data API session, read the meal and its
   ordered items. Verify the recorded date and time zone, known zero and
   unknown values, and absent provenance for a manual meal.


On a disposable isolated install, edit a previously synced meal offline.
Change an item's amount, add or remove an item, move the meal to another day,
and check both days' totals. Restart offline and verify the pending edit.
Reconnect and check that the backend replaced the whole item set. Delete
the meal offline, restart, and reconnect. The pending deletion count should
clear and the backend meal and items should be absent. Use no synthetic
meals in the hosted health project.
