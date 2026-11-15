# Symptom and urge sync

The signed-in BiteLens owner writes both kinds of observation through
`POST /rest/v1/rpc/bitelens_sync_observation`. A write sends `p_observation_id`,
`p_user_id`, `p_revision`, and `p_observation`. Use a full snapshot for saves and
an explicit JSON null for deletions. The snapshot includes `id`, `user_id`,
`kind` (`symptom` or `bingeEatingUrge`), `observed_at_epoch_seconds`, `local_date`,
and `time_zone`. It can include `level` (`mild`, `moderate`, or `severe`) and
`notes`. A symptom requires a catalog `symptom_id`. An urge can include a
`meal_id` for an active Logged Meal owned by the caller.

A successful transaction returns `id` and `revision`. A retry of the same
revision and snapshot succeeds without changing timestamps. The server rejects
stale or conflicting revisions, saves against a tombstone, and links to a
missing or foreign meal. Meal deletion clears every linked urge in the same
transaction. Each affected urge keeps its identity, time, notes, and revision,
and its `updated_at` advances. Retrying the original accepted payload returns
its acknowledgment and leaves the urge unlinked.

The authenticated owner reads through `GET /rest/v1/bitelens_observations`.
Start with a full read, then poll `updated_at` with an overlapping window,
ordered by `updated_at` and `id`. Keep the latest row per ID by `updated_at`,
since an unlink can have the same `revision` as the preceding state. A non-null
`deleted_at` marks a tombstone, which retains the ID, owner, revision, and server
timestamps. Timestamps describe writes and can become visible in a different
order when transactions overlap.

## Automated checks

Apply the migrations in timestamp order to a disposable loopback Supabase stack.
With the full migration chain, use the beta mode of the [meal sync integration
suite](meal-sync.md).

```sh
python3 supabase/tests/meal-sync.py /path/to/local-stack-status.json --beta
```

To verify the original single-owner access model, apply the migrations through
`20261113000624_bitelens_observations.sql` and omit `--beta`. CI runs the single-owner
suite first, applies the beta migrations on the same stack, then runs the beta suite.

The suite checks owner-only reads and writes, catalog and entry-kind validation,
revision ordering, server timestamps, exact retries, same-owner links, changed-
since tombstones, and link state when a meal deletion races an observation edit.

## Hosted verification

Apply the migrations for the intended variant using
[Supabase setup](../supabase-migrations.md). Verify that an approved account can
read its own observations and call the observation sync RPC. Verify account
isolation with synthetic records in a separate test project.
