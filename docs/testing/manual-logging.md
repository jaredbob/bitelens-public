# Manual review and confirmation

Run `scripts/test-core.sh` for the local workflow tests. They use actual temporary files,
an offline Auth client, and a controlled clock. Coverage includes the installed draft
array format, a failed atomic confirmation and retry, confirmation after a day boundary,
grouping across time zones, distinct unknown and zero values, incomplete subtotals,
owner-only history, estimate provenance, and photo expiry after confirmation.

## iPhone acceptance

1. Update the installed app and open a draft made with the previous camera build.
   Check its notes, photo, and original meal date. Keep a draft open for the next step.
2. Enable Airplane Mode. Open the draft and add a food and a drink. Supply a
   description, a serving and weight in grams. Enter some nutrient values, use 0
   for one known value, and leave other fields blank. Save both items and correct one.
3. Edit the meal time and time zone. Check the displayed local date. Close and reopen
   the draft and verify the items and notes are still there. Open history and confirm
   that the draft has not contributed a meal or changed a daily total.
4. Tap **Confirm meal**. Open **Meal history**. Check that the meal is grouped under
   the chosen date and marked **Pending sync**. Open its details and check the
   photo, items, notes, amounts, and time zone. Open **Daily nutrient totals** and
   check that a known zero reads as zero and every affected subtotal is incomplete.
5. Force-quit and reopen while offline. Check the logged meal, pending status, and
   totals again. Confirm the logged meal no longer appears in **Pending drafts**.
6. When a test draft's original photo is 168 hours old, open it and confirm that the
   photo is unavailable and manual entry still works. A logged meal's photo expires
   on the same schedule while its structured details remain available. The controlled
   clock tests cover the exact cutoff without changing the iPhone's clock.
