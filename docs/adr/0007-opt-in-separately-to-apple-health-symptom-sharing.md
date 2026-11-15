# Opt in separately to Apple Health symptom sharing

Symptoms have a separate Apple Health opt-in because they disclose different
health information from meal nutrient totals. A Symptom Entry becomes eligible
when it is first saved with sharing enabled, and its sample uses the chosen
observation time. BiteLens requests write access for all supported symptom types
in one request when sharing is enabled in Settings. It resumes pending changes
for eligible entries when sharing and write access are available, and honors
deletions made in Apple Health.

The same opt-in covers Binge-Eating Urges. Apple's symptom catalog includes
Appetite Changes and has no dedicated binge-eating urge category.
[HealthKit symptom types](https://developer.apple.com/documentation/healthkit/symptom-type-identifiers)

An urge first saved with sharing
enabled is eligible for one Increased Appetite sample at the urge time,
subject to Appetite Changes write access. The form tells the user that saving
with sharing enabled confirms increased appetite for Apple Health. The urge's
intensity, notes, and meal link stay in BiteLens.
