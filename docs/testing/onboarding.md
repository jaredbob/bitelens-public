# Onboarding validation

The agreed primary test seam is the composed public `MealWorkflow`, not view models or
helper internals. The existing specification approves this seam and network boundaries.
This implementation used the TDD skill's one-slice red/green loop.

## Automated evidence

Run `scripts/test-core.sh` from any directory. All 13 Swift Testing scenarios also pass
with full Xcode 27.2 selected, using the script's ordinary `swift test` path:

- Approved owner sign-in.
- Authenticated unapproved identity denied.
- Explicit provider selection retained using the production UserDefaults adapter.
- Expired cached owner session reopens locally without a network connection.
- Failed sign-in can be retried successfully.
- Refreshed credentials survive reopening with real temporary-file persistence.
- Revoked cloud credentials request reauthentication without removing local access or preference.
- Offline sign-out removes persisted identity and retains provider preference.
- Workflow against a deterministic Supabase Auth HTTP boundary: password grant and refresh.
- Sign-out wins over a suspended sign-in response, including after reopen.
- Sign-out wins over a suspended refresh response, including after reopen.
- Concurrent cloud access shares rotating-token refresh and both requests succeed.
- Unapproved sign-in denies a prior owner even when secure deletion fails.

The first owner test failed with signed-out access; the unapproved account test failed
with owner access. Missing selection/restore/recovery/refresh APIs failed before their
implementations. Suspended sign-in/refresh tests demonstrated stale completion restoring
access or credentials before the generation guard. Concurrent token access failed with
sign-in-required before refresh coalescing. The secure-deletion regression was added
after inspection identified and corrected the ordering; it passes with the other tests.

Swift 6.4 CLT's default SwiftBuild test runner intermittently omits TestingMacros when
compiling tests. Native SwiftPM needs the CLT Testing framework paths supplied explicitly.
The script contains that local workaround; when full Xcode is selected it runs ordinary
`swift test`. The CLT runner emits a native-build-system deprecation warning. This does
not establish that an iOS SDK or Xcode is available.

Additional static validation performed:

- `plutil -lint` succeeds for the generated Xcode project and app Info.plist.
- Regenerating the project and shared scheme produces identical bytes.
- The shared scheme parses as XML.
- `git diff --check` reports no whitespace errors.

## Limits

The 13 automated workflow tests are local macOS core tests. Their HTTP responses are deterministic fixtures,
not live Supabase authentication or email delivery. File-backed test sessions are
nonproduction fixtures, not a claim about iOS Keychain protection. Provider APIs were
not called and no AI credentials were created. No remote project configuration was
changed.
See [the iPhone setup checklist](../ios-setup.md) for signing instructions, device session
and account authorization checks.
