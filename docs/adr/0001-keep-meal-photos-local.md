# Keep Meal Images in short-lived local storage

BiteLens will retain only seven days of Meal Image copies in private app storage,
without saving them to the Photos library or Supabase Storage. Confirmed meal
records will live in dedicated meal tables within the existing Supabase project
that holds other health data, allowing the food record to outlive its photos.
This limits app-managed photo copies and gives up cloud recovery and cross-device
photo history.

## Expiry and processing

Images expire 168 hours after capture or import into BiteLens. The import time
starts a fresh window for the private copy, so older receipts and photos can be
used for earlier meals. The original stays in the source app. A Share Sheet
image waits in an App Group accessible to BiteLens and its Share extension until
the app creates the draft. The original share time starts the retention clock.
The copy becomes unavailable at the cutoff and is deleted when the app next gets
execution time. Edits to the meal time leave the retention clock unchanged.
BiteLens requests exclusion from device backups,
with iOS's documented limitations accepted. Cloud analysis is allowed under the
accepted standard OpenAI and Grok API retention policies, which can retain
processing copies beyond the local seven-day photo window; saved response
history is disabled, and Grok Zero Data Retention is optional. The draft shows
the selected image before analysis and tells the owner that visible receipt
details are sent with it.

Provider retention is distinct from app-managed photo history. The accepted
policies include normally 30-day content retention subject to documented
exceptions: [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)
and [xAI security guidance](https://docs.x.ai/developers/faq/security).
