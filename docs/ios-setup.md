# iPhone setup and installation

## Configure and build

1. Install full Xcode with iOS platform support and run
   `scripts/verify-ios-environment.sh`.
2. Set up your own [Supabase project](supabase-migrations.md) for the scheme
   you plan to use. Keep the personal and beta deployments separate.
3. Copy `App/Config/Local.xcconfig.example` to `App/Config/Local.xcconfig`.
   Supply the chosen project's hostname without the scheme and its publishable
   key. For the personal scheme, also set `BITELENS_OWNER_ID` to the Auth user UUID
   registered in the database. The unconfigured app displays setup instructions.
4. For a signed build, set `DEVELOPMENT_TEAM` and set `BITELENS_IDENTIFIER_PREFIX`
   to a reverse-DNS prefix you control. Enable the App Group for the app and
   Share extension and enable HealthKit for the personal app. For example, the
   prefix `com.example` generates the personal bundle ID `com.example.BiteLens`
   and group `group.com.example.BiteLens`.
   [Apple App Groups setup](https://developer.apple.com/documentation/xcode/configuring-app-groups)
5. Open `BiteLens.xcodeproj` in Xcode, select the **BiteLens** or **BiteLens Beta**
   scheme and run on your device. For test commands, see
   [iOS UI smoke tests](testing/ui-smoke.md).

## Physical-device checks

- Sign in using the approved account. Try an incorrect password and verify
  the error and successful retry.
- In a test deployment, verify access is denied for an unapproved account.
- Choose a provider, restart the app, and verify the choice is retained.
- Confirm local access offline after sign-in. Verify expired or revoked
  sessions prompt for reauthentication when online.
- Sign out, restart, and verify that sign-in is required.

## Add the Capture Meal control

Open BiteLens once after installing the signed build that includes its control extension.

- In **Control Center**, tap **+**, choose **Add a Control**, and search for **Capture Meal**.
  [Apple’s Control Center guide](https://support.apple.com/guide/iphone/iph59095ec58/ios)
- On the **Lock Screen**, touch and hold the wallpaper and choose **Customize**. Tap **−**
  on a bottom shortcut, then **+** in the same spot. Search for **BiteLens** or **Capture Meal**.
  The bottom shortcuts and the widgets under the clock have separate pickers.
  [Apple’s Lock Screen guide](https://support.apple.com/guide/iphone/iph4d0e6c351/ios)
