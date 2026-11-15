# Share symptom and urge storage

Store Symptom Entries and Binge-Eating Urges in one new BiteLens Supabase table
so both use the same ownership, revisions, soft deletes, and changed-since
feed. An explicit entry kind lets database constraints require a catalog
symptom for symptom entries and restrict optional meal links to urges. Each
urge can link to one meal, several urges can link to the same meal, and deleting
the meal clears those links while preserving the urge records.
