# iOS UI smoke tests

The generated `BiteLensUITests` target checks that the app launches and that a manual
draft can move through review to confirmation and a symptom note can be opened from
History. It runs on an iPhone simulator. It does
not sign in, call Supabase, call an AI provider, request HealthKit, or open the camera.
`scripts/test-core.sh` and the Supabase job remain the fast default suite.

## What the suite covers

- A normal launch stays on email sign-in and does not open capture.
- With UI-test mode on, launch opens capture without a sign-in or provider screen.
- The capture control is present and stays disabled. The suite does not pretend the camera is ready.
- **Enter meal manually** opens the draft. Notes, **Analyze with OpenAI**, and a disabled **Confirm meal** are visible.
- Analysis returns the in-process fixture item "Scrambled eggs" from model `ui-test-fixture`.
- **Confirm meal** returns to capture. History shows the Logged Meal and the draft queue is empty.
- In a Logged Meal, pressing and holding notes or serving text shows **Copy**. Swiping right on the History row copies the meal into a draft with its notes and items. Leaving the draft unconfirmed keeps History at one meal.
- The **+** menu in History opens the camera with **Choose from Photos**, starts a manual meal draft, or opens **Log symptom**. The **Log symptom** button on Capture opens the same searchable list, which includes **Binge Eating Urge**. Saving a Headache with a note shows its chip in History. Tapping the chip opens the note.

Camera permission, a real shutter capture, retake, launch after unlock, and the Lock Screen /
Control Center action stay on a device. Those checks are listed in
[capture and draft validation](drafts.md) and [iPhone setup](../ios-setup.md).

## UI-test mode

The suite passes the launch argument `-BiteLensUITesting`. `BITELENS_UI_TESTING=1` is the
environment equivalent. `App/BiteLens/UITestMode.swift` honors either switch only in Debug.
Release compiles the gate to off and does not include the stub workflow.

When the switch is on, the app:

- restores an approved-owner session from memory, with no Keychain and no network
- selects OpenAI locally and returns one fixed meal estimate, with no provider request
- acknowledges meal and observation sync in memory, with no Supabase call
- stores the draft in a temporary directory that is cleared on each launch
- leaves HealthKit and the shared-image inbox disconnected
- skips camera startup and shows "Camera checks stay on a device."

A Release build ignores the argument. Product > Run without the argument still opens sign-in.

## Run locally

From the repository root, with a full Xcode and an iOS Simulator runtime:

```sh
scripts/test-ui.sh
```

The script picks the newest available iPhone simulator, preferring a standard iPhone over
SE, mini, Plus, or Pro. It does not read `App/Config/Local.xcconfig`. Simulator builds are
unsigned and use an empty entitlements file so the gitignored team ID is not required.
Device and Release builds keep `App/Config/BiteLens.entitlements`.

In Xcode, open `BiteLens.xcodeproj`, select the `BiteLens` scheme, and choose Product > Test.
That uses your normal signing. The team ID stays in the ignored `App/Config/Local.xcconfig`.

Regenerate the project after changing the UI-test target membership:

```sh
scripts/generate-xcode-project.py
```

CI runs this suite on `macos-26` for pull requests. The existing core and Supabase jobs are unchanged.
