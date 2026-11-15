# TestFlight releases

GitHub runs the same checks on pull requests, pushes to main, and published releases. The release run also checks that the tagged commit belongs to main and that its version matches every Xcode target. Hosted jobs use read-only repository access, pinned actions, a credential scan, and a disposable Supabase database for the meal-sync security tests.

## Check the release before publishing

From a current bitelens-public checkout with GitHub CLI signed in, pass the proposed
tag and the full commit SHA you intend to release:

```sh
scripts/check-release-ready.sh v0.5.0 FULL_COMMIT_SHA
```

The command checks that the commit is on protected `main`, its push to `main`
passed BiteLens CI, and the tag matches the Xcode marketing version at that
commit. It also checks the target of the tag if the tag already exists. The
command only reads from GitHub. If it succeeds, use the same tag and exact SHA
when creating the GitHub prerelease.

## Publish and archive an internal beta

1. Update every target's marketing version in `scripts/generate-xcode-project.py` and regenerate the Xcode project when preparing a new version. Merge the release changes into main, then run the pre-publish check above on the release commit.
2. In GitHub Releases, create an immutable prerelease using the checked tag and full SHA.
3. Wait for the release-triggered **BiteLens CI** run to pass. On the Mac, sign in to GitHub CLI and to the paid Apple team in Xcode. Choose an unused, increasing build number for the version shown in TestFlight.
4. From a BiteLens checkout run `scripts/archive-testflight.sh v0.1.0 1 YOUR_APPLE_TEAM_ID`. It checks GitHub's immutable release, verifies that its exact commit is on main and passed release CI, then makes a signed Release archive from that commit. The archive path is printed on success. Signing stays in the Mac's Keychain and Xcode account.
5. Open the archive in Xcode Organizer and choose **Distribute App → TestFlight Internal Only** for the current owner-only build. Wait for processing in App Store Connect, resolve any export-compliance prompts, then assign it to an internal group for your Apple account. Install it from TestFlight on your iPhone and verify sign-in, camera, meal logging, sync, and the Share and Control Center extensions.

Use the App Store Connect record registered for the bundle ID in your build. Configure signing and the target backend in `App/Config/Local.xcconfig`. BiteLens uses iOS-provided HTTPS and Keychain APIs for encryption and declares no non-exempt encryption in its Info.plist. The Share extension and app require the shared App Group in their provisioning profiles. The personal app also needs HealthKit enabled on its App ID and a provisioning profile with the HealthKit entitlement. [Configuring HealthKit access](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)

## Privacy manifests

Apple requires a `PrivacyInfo.xcprivacy` in an app or extension bundle that uses a required-reason API, collects data, or tracks people. The file declares only what that bundle does. [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) · [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files/describing-use-of-required-reason-api)

`App/BiteLens/PrivacyInfo.xcprivacy` declares file timestamps (`C617.1`) and UserDefaults (`CA92.1`). `SharedMealImageInbox` writes the share time as the modification date of files in the app group container and reads `contentModificationDate` for the local retention window. The app reads and writes the selected AI provider with `UserDefaults.standard`, which is visible only to the app. `App/BiteLensShare/PrivacyInfo.xcprivacy` declares file timestamps (`C617.1`) because the Share extension calls `SharedMealImageInbox.enqueue`. That target does not call UserDefaults. Both declarations still match those call paths. The simulator smoke stub in `App/BiteLens/UITestMode.swift` is compiled only for Debug, so its `FileManager` and `ProcessInfo` use is absent from the Release archive. `ProcessInfo.processInfo` is not the system-boot-time API.

The Control Center / Lock Screen extension (`PREFIX.BiteLens.Controls`) ships without a privacy manifest. Its target compiles `App/BiteLensControls/BiteLensControls.swift` and `App/BiteLens/OpenMealCameraIntent.swift`, links no package product, and copies `Assets.xcassets`. The code builds a WidgetKit control button whose App Intent opens BiteLens. `BITELENS_CONTROL_EXTENSION` leaves the intent's `perform()` as a return, so the extension copy does not touch app state. Reviewed against Apple's current required-reason categories, that code does not call:

- UserDefaults, including `@AppStorage`
- file timestamps (`modificationDate`, `contentModificationDateKey`, `creationDate`, `stat`, `getattrlist`, and the related calls)
- system boot time (`ProcessInfo.systemUptime`, `mach_absolute_time`)
- disk space (`volumeAvailableCapacity`, `volumeTotalCapacity`, `statfs`, and the related keys)
- active keyboards (`UITextInputMode.activeInputModes`)

The extension collects no data and contacts no tracking domains. It does not link BiteLensCore, which is where the UserDefaults and file-timestamp calls live. WidgetKit, SwiftUI, and AppIntents are system frameworks, so their own use of those APIs is outside this binary. Add `App/BiteLensControls/PrivacyInfo.xcprivacy` through `scripts/generate-xcode-project.py`, then regenerate the Xcode project, if this target later calls one of those APIs, links BiteLensCore, collects data, or tracks.

## External testing with BiteLens Beta

Use a separate App Store Connect record for BiteLens Beta and the **BiteLens Beta** scheme. TestFlight controls who can install a build. A BiteLens admin controls which individually provisioned accounts can use it. Verify public signup is disabled in the beta project's Auth settings. Follow [BiteLens Beta accounts](beta-accounts.md) to provision accounts, configure signing, and provide a tester support address. See [the beta isolation decision](adr/0009-isolate-multi-user-beta-from-personal-data.md) for the boundaries between the beta and personal app.

### Prepare the beta services

Apply the full migration chain to your beta project and verify the applied migrations. Use a disposable stack for automated database checks and use synthetic accounts and records for hosted acceptance. Configure separate beta OpenAI and Grok keys and models. Set `BITELENS_MEAL_ESTIMATE_DAILY_LIMIT` in the beta function environment to override the default of 10 attempts per approved account per UTC day. Both providers share the same account allowance. [Supabase setup](supabase-migrations.md)

Deploy the public privacy policy to BiteLens Beta. This function serves plain text and needs no API key or user session. From the release source, run this command with Supabase CLI 3.0.0.

```bash
supabase functions deploy beta-privacy --remote=YOUR_BETA_PROJECT_REF --no-verify-jwt --use-api
```

Append `/functions/v1/beta-privacy` to your beta project URL and open it in a signed-out browser and from the beta's sign-in and Settings screens. Enter the same public URL in App Store Connect. Review the beta's App Privacy responses against its actual account, meal, observation, and optional analysis data collection. [App Review privacy guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy) · [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)

### Verify the hosted beta and the iPhone build

- Use two separately approved accounts. For each account, sign in and exercise meal and observation logging, edits, deletes, and sync. Confirm that records stay private, including the meal linked from a binge-eating urge. Try to read, edit, delete, and link to the other account's records with a signed-in token.
- With both providers, verify permission before sending a Meal Estimate and after withdrawal in Settings. Check that manual logging and sync work without AI permission and at the limit. Exercise the shared daily allowance, concurrent requests, and the UTC reset.
- With valid tokens for an unapproved and a revoked account, verify that cloud reads, writes, and analysis are blocked. Check that approval revocation preserves records and an active local record remains available until sign-out. Fresh sign-in requires approval.
- Install the beta alongside the personal app on an iPhone. Switch between the two beta accounts and verify that drafts, images, history, preferences, and pending uploads stay with their original account, including through offline use and sign-out. Check that a fresh beta installation starts with an empty local history.
- Share a synthetic Meal Image into the beta. Check that it stays with the account active during sharing, follows the existing seven-day expiry, and cannot be claimed after switching accounts. Share while signed out to verify the instruction to sign in and share again. Check that the beta offers no Apple Health export.

### Archive, upload, and submit

1. Merge the release changes to main and run the pre-publish check above on the release commit. Publish an immutable prerelease using the checked tag and full SHA, then wait for the release-triggered **BiteLens CI** to pass.
2. Confirm the App Group is assigned to the beta app and Share extension App IDs. Choose an unused build number for the version. To archive the exact verified release with a public-facing support address, run the command below with the paid team ID and the approved support address. The support address is visible in the beta app. With no support address configured, the app directs testers to Send Beta Feedback in TestFlight.
3. Open the archive in Xcode Organizer and use **Distribute App → TestFlight & App Store** to upload a build eligible for external TestFlight. Wait for processing and resolve any export-compliance questions. [Xcode distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/)
4. Create an external TestFlight group on the BiteLens Beta record. Fill in the [beta metadata](testflight-beta-notes.md) and provide a feedback email. Enter the App Review contact name, email, international-format phone number, and credentials for a separate approved reviewer account with an empty record. Keep those credentials in App Store Connect.
5. Add the build to the group, enter What to Test, and submit it for TestFlight App Review. Wait for approval before adding or notifying external testers. [Apple's external testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)

```bash
BITELENS_BETA_SUPPORT_EMAIL=beta-support@example.com \
  scripts/archive-testflight.sh --beta v0.5.0 1 YOUR_APPLE_TEAM_ID
```
