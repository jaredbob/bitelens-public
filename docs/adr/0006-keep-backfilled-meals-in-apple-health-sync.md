# Keep backfilled meals in Apple Health Sync

An Apple Health Backfill brings the selected local Logged Meals into ongoing
Apple Health Sync so that later corrections and deletions remain accurate after
the meals age out of the 30-day window. Reuse the sample identity and on-device
sync state from [ADR 0005](0005-export-nutrient-totals-from-the-iphone.md) so
reruns preserve deletions made in Apple Health and converge on one entry per
meal and metric.
