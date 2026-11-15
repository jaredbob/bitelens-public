# Apple Health Sync on an iPhone

Use a signed build on a physical iPhone and disposable meals. Enable HealthKit
for the BiteLens app identifier and use a development provisioning profile that
includes the capability. Install and launch the BiteLens or BiteLens Beta scheme
with Xcode. Use the corresponding app name in the Health app. For Beta, sign in
and confirm the Apple Health Connection when turning on the first toggle.
[Configuring HealthKit access](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)

## Confirming a meal

1. Open BiteLens Settings and verify Apple Health Sync starts off on a fresh
   local library. Confirm a disposable meal while sync is off.
2. Turn on Apple Health Sync. On the first request, verify iOS offers write
   access for the eight categories below, then allow each one. In BiteLens
   Settings, verify all eight rows under **Apple Health write access** say
   **Allowed**.
3. Capture another meal and edit its Meal Time to yesterday at a recognizable
   time. Enter the two items below. Before confirmation, check that there
   are no entries from BiteLens at that time.
4. Confirm the meal. In Health, find each category below and open
   **Show All Data**. Check that each category has
   one entry from BiteLens with the expected amount at the chosen Meal Time.
   Check that the meal confirmed with sync off has no entries.
5. Quit and reopen BiteLens. Check that each category still has exactly one
   entry from the confirmed meal.
6. In Health, open your profile and select BiteLens under **Apps** in the
   Privacy section. Turn off write access for Caffeine and return to BiteLens.
   Check that Settings shows **No access** for Caffeine. Confirm another meal
   with a distinct Meal Time, using the same values except leave the second
   item's protein blank and enter 0 mg sodium for both items. Health should
   show 0 mg sodium and the other complete, authorized totals for this meal.
   Protein and Caffeine should have no entry for this meal.
7. Check that **Sync status** says **Changes pending** in BiteLens Settings.
   Tap **Retry Sync** with Caffeine still denied and verify the status stays
   pending and Health still has one entry per authorized, complete total.
   Restore Caffeine write access in Health and return to BiteLens. Verify
   the Caffeine row says **Allowed**, status says **No changes pending**, and
   Health has exactly one Caffeine entry for this meal.

| Health category | Item 1 | Item 2 | Expected total |
| --- | ---: | ---: | ---: |
| Dietary Energy | 225 kcal | 50 kcal | 275 kcal |
| Protein | 16 g | 0 g | 16 g |
| Carbohydrates | 20 g | 12 g | 32 g |
| Total Fat | 9 g | 0 g | 9 g |
| Fiber | 3 g | 0 g | 3 g |
| Sodium | 410 mg | 10 mg | 420 mg |
| Caffeine | 0 mg | 35 mg | 35 mg |
| Alcohol Consumption | 21 g pure alcohol | 0 g pure alcohol | 1.5 standard drinks |

## Backfilling meals

1. With sync off, confirm two disposable meals with positive alcohol totals
   and distinct Meal Times, one 29 days ago and one 30 days ago by local date.
2. Enable sync and tap **Sync Last 30 Days**. Allow write access to Alcohol
   Consumption if upgrading an existing opt-in. Verify Health shows one sample
   per authorized complete total for the meal from 29 days ago.
3. Run **Sync Last 30 Days** again and verify the older meal stays absent and
   the eligible meal's entries remain unique. Delete the eligible meal's
   alcohol sample in Health, edit the meal in BiteLens and run backfill again.
   Verify the alcohol sample stays absent and the other corrected totals update.

## Editing and deleting meals

1. With sync enabled and Dietary Energy write access granted, edit a synced
   disposable meal in BiteLens. Change the calorie total and Meal Time. In
   Health, verify that the one BiteLens entry has the new amount and time.
2. Clear a Meal Item's calorie amount so the total becomes incomplete. Verify
   the BiteLens energy entry disappears. Enter a known amount again and verify
   the complete total returns as a single entry.

## Pausing and resuming

1. With sync on, confirm a second disposable meal with a complete calorie
   total and check that its entry appears in Health. Turn Apple Health Sync
   off in BiteLens. Verify the existing entries stay in Health.
2. In Health, delete the energy entry for the meal you edited earlier. In
   BiteLens, correct that meal's calories and another complete nutrient.
   Delete the second meal in BiteLens, then confirm a third disposable meal
   while sync is off. Check that the second meal's Health entry stays
   present, the other nutrient has its old amount, and the third meal has
   no Health entries.
3. Quit and reopen BiteLens. Verify the toggle is still off, Settings shows
   **Changes pending**, and **Retry Sync** is disabled. Turn sync back on.
   Verify the other nutrient updates once and the second meal's Health
   entry disappears. The first meal's energy entry remains absent and the
   third meal still has no Health entries. Other sources' entries remain in
   Health.

## Recovering an interrupted write

If a first write loses its acknowledgment, BiteLens checks HealthKit's recent
deletion records for that sample's identifier and attempted revision before
retrying. HealthKit retains these records temporarily. After a deletion record
expires, BiteLens can no longer distinguish a write that never reached Health
from an unacknowledged write that was later deleted, so a retry may restore
that entry. The same ambiguity applies to a pending first write saved by an
older BiteLens build that did not record its attempted revision.
[HealthKit deletion records](https://developer.apple.com/documentation/healthkit/hkdeletedobject)


## Symptoms and binge-eating urges

Use a fresh install or an iPhone that has never granted BiteLens symptom write
access. Use test observations at distinct times so they are easy to identify
under **Health → Browse → Symptoms → Show All Data**.

1. Leave meal Apple Health Sync off. Verify **Share symptoms with Apple Health**
   starts off. Save a Headache and a Binge-Eating Urge. Neither should prompt
   for permission or appear in Health. Enable symptom sharing and verify that
   Health Access opens immediately and offers write access for all 39 supported
   symptoms. Allow Headache and Appetite Changes and leave Nausea off. Verify
   that the two earlier entries are still absent from Health.
2. Save a new Moderate Headache at a recognizable time yesterday. Verify that
   saving does not prompt for access and that Health has one BiteLens Headache
   sample with Moderate severity and equal start and end times matching the
   chosen instant. Verify the entry
   remains in BiteLens with its note. Save another Headache and confirm that
   it produces a second sample without a permission prompt.
3. Save a new Nausea entry. Verify the entry remains in BiteLens without a
   permission prompt and Headache continues to export. Grant Nausea write
   access in Health under **Privacy → Apps → BiteLens** and return to
   BiteLens. The pending Nausea should appear once in Health.
4. With symptom sharing enabled, open the urge form and verify it explains
   that saving confirms increased appetite for Apple Health. Save an urge
   with a past time, intensity, and note. Verify there is one
   **Increased Appetite** sample at the urge time and that the Health entry
   contains no intensity, note, or meal
   details. Link a meal, then delete the meal. The urge and its Health
   sample should remain. A directly logged Appetite Changes symptom should
   appear as **Unspecified** at its own time.
5. Edit the time and severity of an exported Headache. Verify Health shows
   one updated entry at the new time. Delete the entry from BiteLens and
   verify its sample is removed from Health.
6. Delete a different BiteLens Headache directly in Health. Return to
   BiteLens and verify the underlying entry remains. Edit its time and
   severity, quit and reopen BiteLens, and verify the sample stays absent.
7. Turn symptom sharing off. Edit an exported symptom, delete an exported
   urge, and save a new symptom. Verify existing Health samples stay as they
   were. Quit and reopen BiteLens, then turn sharing back on. Verify the
   eligible edit and deletion apply and the new symptom stays private.
8. Enable meal Apple Health Sync with symptom sharing off. Confirm a meal
   and save a symptom. Verify that only the meal nutrient totals appear.
   With meal sync off and symptom sharing on, verify that a newly eligible
   symptom still exports.

## BiteLens Beta account switching

1. On a fresh Beta installation, sign in to the first of two approved test
   accounts. Verify both toggles start off. Cancel the connection prompt and
   confirm both toggles stay off. Connect and enable both exports, then log a
   meal and a symptom offline. Verify their authorized samples appear from
   BiteLens Beta in Health.
2. Turn off both toggles. Edit the exported meal and delete the exported symptom.
   Sign out, then sign in to the second account. Verify Settings says another
   account is connected to Apple Health. Log a meal and a symptom and verify
   the new entries are absent in Health and the first account’s samples persist.
3. Sign back in to the first account. Verify both toggles are still off and
   turn them on. Check that the pending meal correction and symptom deletion
   appear in Health. Run **Sync Last 30 Days** and verify it only backfills
   the first account’s recent Logged Meals.
4. With the personal build installed alongside Beta, check that changing a
   Beta meal only updates the Beta sample. Each app has its own source in Health.
