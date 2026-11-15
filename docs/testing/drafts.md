# Capture and draft validation

The preapproved seam is the composed public `MealWorkflow`, using a controlled clock,
an offline Auth/network boundary, and actual temporary disk/photo files. No camera mock
is used to establish device behavior. Simulator launch and manual-draft navigation are
covered by [UI smoke tests](ui-smoke.md); camera permission, capture, and retake stay on
the physical checks below. The capture/draft ticket adds 12 workflow tests;
all 25 core tests pass with `scripts/test-core.sh` on Xcode 27.2 / Swift 6.4.

## Automated evidence (2026-11-08)

- Offline capture and optional notes reopen from disk, with original photo capture time,
  chosen meal time, local date, and time zone.
- Photo reads succeed at 604799 seconds and fail at exactly 604800 seconds (168 hours).
  Restart/foreground maintenance physically removes expired files while retaining drafts.
- Chosen meal-time and travel-zone edits survive restart and do not extend retention.
- Retakes keep one selected image, preserve draft identity/context, and record the new
  photograph's capture time; discarded files do not accumulate in the normal case.
- Expired and active drafts remain discardable without affecting other drafts.
- Corrupt/unreadable metadata cannot be overwritten by a new capture; recovery retains
  the original draft/photo. Empty capture data does not destroy a selected photo.
- Delayed camera delivery uses the native shutter timestamp for retention and meal defaults.
- The actual file contents and metadata show separate structured records and image bytes,
  file mode 0600, directory mode 0700, and backup-exclusion flags on photos and their directory,
  including after a retake. The directory test initially failed on an existing mode-0755
  directory, then passed after explicitly resetting directory permissions.
- Owner access is required for photo reads and draft mutations; sign-out hides drafts
  without deleting them. Expiry maintenance still runs signed out.
- Foreground maintenance removes unaccessed expired files and simulated interrupted-write
  orphans without deleting draft metadata.

The persistence/notes, boundary expiry, chosen meal time, retake, discard, corrupt-record
protection, failed-capture recovery, delayed shutter time, signed-out cleanup, and existing
directory protection checks each failed before the corresponding implementation change.
Metadata and owner checks exercise the same public workflow and real files.

Native compile checks pass using the generated project:

```sh
xcodebuild -project BiteLens.xcodeproj -scheme BiteLens -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/bitelens-drafts-build \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project BiteLens.xcodeproj -scheme BiteLens -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bitelens-drafts-build \
  CODE_SIGNING_ALLOWED=NO build
```

These compile checks do not prove camera operation, device file protection, or signing.
The auto-exposed `BiteLensCore` scheme was also attempted with an iOS Simulator test
destination; Xcode reports that it is not configured for the test action. The existing
metadata test contains an iOS-only `.protectionKey == .complete` assertion, but that
automated test has not run on iOS. The on-device diagnostic below verified the
same protection setting on a photo captured in BiteLens.

The final integration tests drive the foreground cleanup task with a controlled
clock. They verify cleanup at the next draft and logged photo deadlines, that
a save at the deadline still allows cleanup, and that a cancelled foreground
task leaves expired files for the next resume.

## Remaining physical checks

- [ ] Verify existing drafts remain accessible while camera permission is denied.
- [ ] Cancel a retake and verify the selected photo and notes stay saved.
- [ ] Trigger an interrupted/unavailable capture where practical and verify retry/restart
      recovers without destroying a saved draft.
- [ ] Edit meal time/time zone, reopen, and observe the selected local meal date remains.
- [ ] Discard a draft and confirm it stays absent after relaunch.
- [x] Verify the photo's complete protection attribute on the unlocked device.
- [ ] Check the Photos library for unintended copies.
- [ ] With an isolated test clock/build, keep a preview open through its deadline, then
      background/resume: the image disappears, bytes are denied, files are cleaned, and
      notes/meal time remain available. Do not change the phone's system clock for this check.

The implementation uses AVFoundation photo capture only, with `NSCameraUsageDescription`.
It imports no Photos API, requests no library permission, and makes no photo upload or
application logging calls. Drafts do not enter logged history, totals, or Supabase. Analysis, textual estimates,
confirmed meals, and manual recovery belong to dependent tickets. Their later tests must
reuse the same photo guard and retention metadata, including after confirmation/retry.

Complete protection uses Apple's [file writing option](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotection).
Backup-exclusion flags are reapplied to each file because writes can reset resource values;
[Apple documents backup exclusion as guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup),
not an absolute guarantee. Physical deletion while iOS does not execute the app is not promised.
