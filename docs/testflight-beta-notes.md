# BiteLens Beta TestFlight metadata

## Beta app description

BiteLens Beta is a private meal and observation log for iPhone. Sign in with the account provided by the beta administrator, then log meals, symptoms, or binge-eating urges. You can add meals manually or choose to request a Meal Estimate from OpenAI or Grok. Review and correct an estimate before saving it. The app keeps a local record and uploads changes to your private BiteLens Account.

## What to Test

- Log a meal offline, reconnect, and confirm that its upload completes. Edit a portion or delete a test meal and check the result in History.
- Record a symptom and link a binge-eating urge to a meal you logged. Confirm they appear on the recorded day in History.
- In Settings, separately opt in to Apple Health Sync and symptom sharing on an iPhone with a Health record you can use for testing. Log a meal and a symptom, then check for the authorized entries in Health. Use **Sync Last 30 Days** to include recent meals you logged before opting in.
- Request a Meal Estimate from each provider using synthetic food descriptions or photos. Review what will be sent, then try declining or withdrawing permission in Settings. You can still log manually and sync.
- Share a synthetic meal image into BiteLens Beta. Try sharing while signed out and follow the instruction to sign in and share again. If you have two approved test accounts, check that the image stays with the account active when you shared it.

## Notes for App Review

Sign in with the dedicated email and password under Beta App Review Information. The account has current beta approval. It opens an empty record on a fresh installation. You can exercise Capture, History, and Settings with synthetic records immediately after sign-in. For optional meal analysis, start with a food photo or enter a description such as “one bowl of oatmeal and a banana,” choose a provider, and grant permission. The account has a daily allowance shared across the providers. To try optional Apple Health export, use either toggle in Settings and confirm the connection. The first account to opt in is the only account that can share with Apple Health from that installation. Meal sync and symptom sharing request separate permissions.

## Contact and credentials

Collect the support email and the App Review contact's name, email, and international-format phone number from the account holder. Enter the separate approved review credentials directly in App Store Connect. Use a feedback address that can receive tester requests for account setup, password recovery, support, and deletion.
