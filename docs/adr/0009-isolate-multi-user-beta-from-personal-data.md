# Isolate the multi-user beta from personal data

Use a separate app and Supabase project for BiteLens Beta so external testers
can use it without sharing a backend with the personal app's owner account
and history. The beta has its own bundle ID, Keychain storage, and Share Sheet
inbox so both apps can run on the same iPhone.

Keep each beta account's local library, photos, preferences, and pending uploads
through sign-out. Only the same account can reopen that library and resume its
uploads. A shared image belongs to the account active when it was shared. It
waits for that account, subject to the existing image expiry.

Use one server-side approval list for record reads, sync writes, and meal
analysis. Removing approval blocks subsequent cloud requests even while the
account's token is valid and preserves its records for possible reinstatement.
A tester with an active session can still use their local record until sign-out.
A fresh sign-in requires current approval.

See [BiteLens Beta accounts](../beta-accounts.md) for provisioning and revocation.
