# BiteLens Beta accounts

Use the **BiteLens Beta** Xcode scheme. It connects to the separate Supabase project
configured for beta builds and installs alongside BiteLens.
Register `com.example.BiteLens.Beta`, `com.example.BiteLens.Beta.Share`, and
`com.example.BiteLens.Beta.Controls` for the paid development team. Enable
the App Groups capability for the app and Share extension with
`group.com.example.BiteLens.Beta`. Replace the example prefix with the identifier prefix in your local
Xcode configuration. Enable HealthKit on the Beta app App ID and use a signing
profile that includes it.
Set the approved tester contact with `BITELENS_BETA_SUPPORT_EMAIL` in
`App/Config/Local.xcconfig`. Without an email setting, the sign-in screen
directs testers to Send Beta Feedback in TestFlight.

## Provision a tester

In **BiteLens Beta**, disable new user signup in Supabase Auth. Keep email
and password authentication enabled. Create individual users in
Authentication → Users, including a separate beta identity for the owner.
Set and share the initial password privately. The same admin contact can
verify a tester's identity and reset access if needed.

Use the verified Auth user UUID displayed in the dashboard. In the Beta SQL
editor, approve the user once the approval migration is installed.

```sql
insert into bitelens_private.approved_accounts (user_id)
values ('<auth-user-uuid>')
on conflict (user_id) do nothing;
```

Remove the approval to revoke future cloud access. This preserves the user
and their records. Run the approval statement again to restore access.

```sql
delete from bitelens_private.approved_accounts
where user_id = '<auth-user-uuid>';
```

An approved tester must be online for a new sign-in. An existing local session
can continue logging offline or after revocation until the tester signs out.
The same tester can reopen their local record after signing back in with
current approval. A new installation starts with an empty record.

## Apple Health Connection

The first account to opt in to Apple Health Sync or Apple Health Symptom Sharing
in Settings can share from that installation. Each feature has its own toggle.
An account can keep logging on a shared iPhone when another account is connected.
Sign-out and switching accounts pause the connected account’s Apple Health work.
Existing samples stay in Apple Health, and enabled exports resume on return to
the connected account. See [ADR 0010](adr/0010-connect-one-beta-account-to-apple-health.md).
