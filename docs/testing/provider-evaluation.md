# Live provider evaluation

Use a test project with synthetic food images, receipts, and text descriptions.
Configure providers in the test project's Supabase Edge Function environment
using [the analysis setup](meal-analysis.md). Choose models that accept images
and support structured output.

1. Run each input with OpenAI and Grok from the same app build. Record elapsed
   time, whether the estimate completed, and portion or nutrient corrections
   needed before saving.
2. Verify the app retains the draft after an error or timeout. Switch providers
   explicitly and retry the same input.
3. Compare provider usage against current [OpenAI pricing](https://openai.com/api/pricing/)
   and [xAI pricing](https://docs.x.ai/developers/models).
4. Adjust a portion offline, confirm the meal, and check that it syncs after
   reconnecting. Verify the saved estimate records the provider and model used.
