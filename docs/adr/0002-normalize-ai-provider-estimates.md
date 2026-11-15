# Normalize estimates behind a server-side provider interface

BiteLens supports explicit switching between OpenAI and Grok through one
authenticated Supabase Edge Function, with server-side credentials and adapters
that return a common Meal Estimate format. We normalize and validate provider
outputs instead of coupling the app or logged meal schema to either provider's
response format, allowing provider and model configuration to evolve without
rewriting historical meals. Unconfirmed estimates stay on the phone, while
confirmed structured records preserve provider/model provenance; switching is
explicit and does not automatically retry with another provider or replace
existing meal records.
