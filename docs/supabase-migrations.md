# Set up a BiteLens Supabase project

Use a new project for each app variant you plan to deploy. The hosted database
requires email/password Auth, the Data API for the BiteLens tables and RPCs in
`public`, and the `bitelens_private` schema kept outside the Data API. For the
beta, turn off public signup and provision accounts as an administrator.

## Apply migrations

Run `supabase init` and use Supabase CLI v3. Apply migrations in timestamp order.

- **Personal:** Apply the migrations through
  `20261113000624_bitelens_observations.sql` and exclude the
  `*_bitelens_beta_*.sql` files from the migration work directory.
- **Beta:** Apply all migrations, including the beta migrations.

Run `supabase db push --dry-run --remote=YOUR_PROJECT_REF` from the work directory
to confirm the target and selection. Run the same command with `--dry-run`
omitted to apply them. CI tests the two variants on a disposable database.

## Configure the personal owner

Create an Auth user with email and password. In the deployment's SQL editor,
register that returned Auth UUID. Use the same UUID for `BITELENS_OWNER_ID`
in the personal app's local configuration and in the analysis function's
environment. An empty owner table denies access.

```sql
insert into bitelens_private.approved_owner (user_id)
values ('YOUR_AUTH_USER_UUID')
on conflict (singleton) do update set user_id = excluded.user_id;
```

For beta accounts, follow [BiteLens Beta accounts](beta-accounts.md).
For app configuration and optional AI analysis, see [iPhone setup](ios-setup.md)
and [meal analysis](testing/meal-analysis.md).
